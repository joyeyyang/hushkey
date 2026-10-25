import Foundation

/// The whole voice-input method, behind one object.
///
/// Lifecycle is deliberately explicit and cheap to repeat:
///
/// 1. `init(config:)` — validates the config, touches nothing.
/// 2. `prepare()` — `Core_Initialize` (points the engine at the model tree),
///    publishes the model selection into the process environment, and loads the
///    ASR model.
/// 3. `transcribe(fileAt:)` or `makeSession()` — do the work.
/// 4. `shutdown()` — release the engine.
///
/// The class is a thin coordinator: it holds no audio and no transcript itself,
/// so one engine can serve many files and one session at a time.
public final class VoiceInputEngine {

    public let config: VoiceInputConfig

    private let lock = NSLock()
    private var prepared = false

    public init(config: VoiceInputConfig) throws {
        let allowedTargets = ["auto", "off", "en", "zh"]
        guard allowedTargets.contains(config.translateTarget) else {
            throw VoiceInputError.badConfig(
                "translateTarget must be one of \(allowedTargets.joined(separator: "/")), got \"\(config.translateTarget)\"")
        }
        guard !config.modelsDirectory.path.isEmpty else {
            throw VoiceInputError.badConfig("modelsDirectory is empty")
        }
        self.config = config
    }

    /// Points the engine at the models and loads ASR.
    ///
    /// The model selection is published as environment variables rather than
    /// passed anywhere, because the core spawns its LLM worker with
    /// `Command::new` (state.rs) and that child inherits *this* process's
    /// environment — a dictionary handed to a spawn call here would reach
    /// nothing. `OVC_LLM_MODEL` is the engine's own override; `OVC_EMBED_MODEL`
    /// is set for symmetry and future use, but see `Retrieval.swift`: the
    /// current engine has no embed entry point, so nothing reads it yet.
    public func prepare() throws {
        try CoreABI.initialize(modelsDir: config.modelsDirectory.path)
        if let llm = config.llmModel, !llm.isEmpty {
            _ = setenv("OVC_LLM_MODEL", llm, 1)
        }
        if let embed = config.embedModel, !embed.isEmpty {
            _ = setenv("OVC_EMBED_MODEL", embed, 1)
        }
        // The engine looks for its worker next to its own executable, which is
        // right inside the app bundle; a tool or another host has to say where.
        if let worker = config.workerExecutable {
            _ = setenv("OVC_LLM_WORKER", worker.path, 1)
        }
        try CoreABI.loadASR()
        lock.lock()
        prepared = true
        lock.unlock()
    }

    /// Pre-computes the retrieval model's vectors so the next dictation does not
    /// pay for them.
    ///
    /// Roughly two dozen short embeddings happen the first time a screening pass
    /// runs; measured, that is seconds of CPU sitting on the user's critical
    /// path. Call this from a background queue after `prepare()` (or right after
    /// the model finishes downloading) and the dictation itself stays cheap.
    /// Returns the number of vectors computed; 0 means it was already warm.
    @discardableResult
    public func warmRetrievalCache() -> Int {
        ensurePrepared()
        return (try? Int(CoreABI.warmRetrieval(terms: config.keywords))) ?? 0
    }

    /// Convenience over `makeSession` + `start` for callers that only want file
    /// input. Decodes the file with the same ASR session the live path uses, so
    /// a file and a microphone recording produce the same shape of result.
    public func transcribe(
        fileAt url: URL,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> VoiceInputResult {
        ensurePrepared()
        return try FileTranscriber.transcribe(url: url, config: config, progress: progress)
    }

    /// Creates a live session. The caller drives it through `VoiceInputSession`;
    /// only one session may exist at a time, which the engine enforces.
    public func makeSession() throws -> VoiceInputSession {
        ensurePrepared()
        return VoiceInputSession(config: config)
    }

    /// Releases the engine. Safe to call more than once; a later `prepare()`
    /// brings it back.
    public func shutdown() {
        CoreABI.shutdown()
        lock.lock()
        prepared = false
        lock.unlock()
    }

    private func ensurePrepared() {
        lock.lock()
        let ready = prepared
        lock.unlock()
        if !ready { try? prepare() }
    }
}

/// A live dictation: microphone in, result out.
///
/// The session owns the audio capture and the polling timer, and hands the
/// caller three optional callbacks. `finish()` is the only way to get the
/// transcript — it stops the mic, ends the ASR session, and runs the same
/// raw → refine → translate chain the file path runs.
public final class VoiceInputSession {

    /// 0…1 microphone level, for a meter. Delivered on the main queue.
    public var onLevel: ((Float) -> Void)?
    /// Live partial transcript so far. Delivered on the main queue.
    public var onPartial: ((String) -> Void)?
    /// Utterances finalised since the previous call. Delivered on the main queue.
    public var onSegments: (([Utterance]) -> Void)?

    private let config: VoiceInputConfig
    /// Serial queue for everything that talks to the core and touches
    /// `segments`. The audio tap hops onto it per buffer; polling and finishing
    /// run on it too, so ordering is `submit` → poll → `stop` with no gaps.
    private let queue = DispatchQueue(label: "voiceinputkit.session", qos: .userInitiated)
    private let stateLock = NSLock()

    private var capture: MicrophoneCapture?
    private var timer: DispatchSourceTimer?
    private var segments: [Utterance] = []
    private var started = false
    private var finished = false
    private var paused = false

    init(config: VoiceInputConfig) {
        self.config = config
    }

    /// Opens the ASR session, starts the microphone, and begins polling.
    ///
    /// The engine holds exactly one ASR session, so a second `start()` (or a
    /// leftover session from a previous recording) surfaces as an error, not a
    /// silent mix of two streams.
    public func start() throws {
        guard !started else { throw VoiceInputError.badConfig("session already started") }
        guard MicrophoneCapture.microphoneAuthorized() else { throw VoiceInputError.microphoneDenied }

        try CoreABI.startASR()
        let cap = MicrophoneCapture(
            onSamples: { [weak self] in self?.feed($0) },
            onLevel: { [weak self] in self?.deliverLevel($0) })
        do {
            try cap.start()
        } catch {
            // The session was opened by this call, so ending it is ours to do:
            // leaving it open would make every later start fail with "session
            // already active".
            try? CoreABI.stopASR()
            throw VoiceInputError.decoderUnavailable("microphone: \(error.localizedDescription)")
        }
        capture = cap
        started = true
        startPolling()
    }

    /// Stops feeding audio without ending the session, so the transcript
    /// continues where it stopped instead of opening a second one.
    public func pause() {
        stateLock.lock()
        paused = true
        stateLock.unlock()
    }

    public func resume() {
        stateLock.lock()
        paused = false
        stateLock.unlock()
    }

    /// Stops the microphone, drains the last utterances, ends the session, and
    /// runs the cleanup chain. Throws only if the engine's own stop fails; the
    /// cleanup always degrades to the raw transcript.
    public func finish() throws -> VoiceInputResult {
        guard started else { throw VoiceInputError.notStarted }
        guard !finished else { throw VoiceInputError.badConfig("session already finished") }
        finished = true

        // Stop feeding first: `ASR_Stop` must not race an in-flight submit. The
        // queue hop below waits for every submit already enqueued.
        capture?.stop()
        capture = nil
        stopPolling()

        return try queue.sync {
            segments.append(contentsOf: (try? CoreABI.takeSegments()) ?? [])
            let stopText = try CoreABI.stopASR()
            // `ASR_Stop` decodes the final utterance itself; one more drain puts
            // the closing sentence in.
            segments.append(contentsOf: (try? CoreABI.takeSegments()) ?? [])
            let joined = Text.join(segments.map(\.text))
            let raw = joined.isEmpty ? stopText.trimmingCharacters(in: .whitespacesAndNewlines) : joined
            let refined = Refiner.refine(raw: raw, config: config)
            return VoiceInputResult(raw: raw, refined: refined, segments: segments)
        }
    }

    // MARK: - Private

    /// The one place microphone audio enters the engine. Pause gates this and
    /// nothing else, which is what keeps the ASR session open across a pause.
    private func feed(_ samples: [Float]) {
        stateLock.lock()
        let isPaused = paused
        stateLock.unlock()
        guard !isPaused else { return }
        queue.async { try? CoreABI.submit(samples) }
    }

    private func deliverLevel(_ level: Float) {
        // The tap runs on a real-time thread; callbacks are promised on main.
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    private func startPolling() {
        stopPolling()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    private func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    /// One poll tick: pull newly-finalised utterances and the live preview.
    /// Runs on `queue`, so it can touch `segments` without a lock and is
    /// naturally serialised against `finish()`.
    private func poll() {
        let fresh = (try? CoreABI.takeSegments()) ?? []
        if !fresh.isEmpty {
            segments.append(contentsOf: fresh)
            DispatchQueue.main.async { [weak self] in self?.onSegments?(fresh) }
        }
        if let partial = try? CoreABI.peekASR() {
            DispatchQueue.main.async { [weak self] in self?.onPartial?(partial) }
        }
    }
}
