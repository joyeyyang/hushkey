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

    /// Whether this macOS version can capture system audio at all.
    ///
    /// Exposed so a caller can name the macOS 14.2 reason — and grey the control
    /// out — before a recording starts, instead of surfacing it as an
    /// `onSystemAudioFailure` in the middle of one. Independent of any engine
    /// instance, so it can be read before one is built.
    public static var systemAudioSupported: Bool { SystemAudioTap.isSupported }

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
    /// nothing. `OVC_LLM_MODEL` is the engine's own override.
    public func prepare() throws {
        try CoreABI.initialize(modelsDir: config.modelsDirectory.path)
        if let llm = config.llmModel, !llm.isEmpty {
            _ = setenv("OVC_LLM_MODEL", llm, 1)
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
    public func makeSession(mode: VoiceInputSession.Mode = .dictation) throws -> VoiceInputSession {
        ensurePrepared()
        return VoiceInputSession(config: config, mode: mode)
    }

    /// The meeting-summary entry point: a finished transcript in, the reduced
    /// 摘要／待辦／決議 sections out.
    ///
    /// Deliberately separate from `transcribe(fileAt:)` and from the session's
    /// cleanup chain — summarising is a second, explicit step on text the caller
    /// already has, not part of turning speech into a line. Throws when the LLM
    /// worker is unavailable; the caller keeps showing the transcript then.
    public func summarize(_ transcript: String) throws -> String {
        ensurePrepared()
        return try CoreABI.summarize(transcript)
    }

    /// One cleanup pass in the configured register, THROWING when the model
    /// cannot answer.
    ///
    /// The product path is `refineTranscript`, which falls back to the raw
    /// transcript so a dictation is never lost. A caller that is measuring the
    /// cleanup — the command-line tool comparing the three registers — needs the
    /// failure instead of the fallback: with the fallback, a broken install and a
    /// working one that returned the input look identical, and the comparison
    /// would "pass" on three copies of the transcript.
    public func refine(_ text: String) throws -> String {
        ensurePrepared()
        return try CoreABI.refine(
            text, keywordsHint: "", stages: config.refineStages, tone: config.refineTone)
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

    /// What the recording is FOR, which decides what happens to the text when
    /// it ends.
    ///
    /// A DICTATION is one sentence the user is typing somewhere, so it goes
    /// through the cleanup chain before it is pasted.
    ///
    /// A MEETING is a record of what was said. The transcript is kept as it was
    /// spoken -- summarised separately afterwards -- so the cleanup chain must
    /// NOT run over it: that chain is a dictation prompt (one tidy line, no
    /// invented content), and a meeting transcript run through it comes back
    /// rewritten, condensed, and wrong about what was actually said. The
    /// meeting's own summary is a different prompt with its own rules, and it
    /// reads the raw transcript.
    public enum Mode {
        case dictation
        case meeting
    }

    /// 0…1 microphone level, for a meter. Delivered on the main queue.
    public var onLevel: ((Float) -> Void)?
    /// Live partial transcript so far. Delivered on the main queue.
    public var onPartial: ((String) -> Void)?
    /// Utterances finalised since the previous call. Delivered on the main queue.
    public var onSegments: (([Utterance]) -> Void)?
    /// Called when system-audio capture could not start. The recording continues
    /// on the microphone alone -- a meeting transcript missing the far end is
    /// still worth having, and refusing to record would be worse.
    public var onSystemAudioFailure: ((String) -> Void)?

    /// Whether this macOS version can capture system audio at all — the session's
    /// spelling of `VoiceInputEngine.systemAudioSupported`.
    public static var systemAudioSupported: Bool { VoiceInputEngine.systemAudioSupported }

    private let config: VoiceInputConfig
    /// What this recording is for. Decides whether the cleanup chain runs when
    /// the session ends.
    public let mode: Mode
    /// Serial queue for everything that talks to the core and touches
    /// `segments`. The audio tap hops onto it per buffer; polling and finishing
    /// run on it too, so ordering is `submit` → poll → `stop` with no gaps.
    private let queue = DispatchQueue(label: "voiceinputkit.session", qos: .userInitiated)
    private let stateLock = NSLock()

    private var capture: MicrophoneCapture?
    /// The process tap carrying what the Mac is playing, when a meeting asked for it.
    private var systemTap: SystemAudioTap?
    private var timer: DispatchSourceTimer?
    private var segments: [Utterance] = []
    private var started = false
    private var finished = false
    private var paused = false

    init(config: VoiceInputConfig, mode: Mode) {
        self.config = config
        self.mode = mode
    }

    /// Opens the ASR session, starts the microphone, and begins polling.
    ///
    /// The engine holds exactly one ASR session, so a second `start()` (or a
    /// leftover session from a previous recording) surfaces as an error, not a
    /// silent mix of two streams.
    public func start() throws {
        try start(audioSource: nil)
    }

    /// Opens the ASR session with the audio coming from somewhere other than
    /// the microphone.
    ///
    /// `audioSource` is handed the samples instead of the microphone, and the
    /// microphone is not opened at all. That is what a scripted check needs: it
    /// can run the real session -- the real ASR, the real segments, the real
    /// cleanup decision -- without a microphone and without a permission
    /// prompt, and the audio it feeds is the audio it has.
    ///
    /// `source` is 0 for the microphone and 1 for system audio, so a scripted
    /// check can stand in for either.
    public func start(audioSource: ((@escaping ([Float]) -> Void) -> Void)?) throws {
        guard !started else { throw VoiceInputError.badConfig("session already started") }
        // A substitute source means no microphone, so the permission is not
        // needed -- and asking for it would put a system prompt in front of a
        // headless check.
        if audioSource == nil {
            guard MicrophoneCapture.microphoneAuthorized() else { throw VoiceInputError.microphoneDenied }
        }

        try CoreABI.startASR()
        if let audioSource {
            audioSource { [weak self] samples in self?.feed(samples) }
        } else {
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
        }
        started = true
        if config.captureSystemAudio {
            startSystemAudio()
        }
        startPolling()
    }

    /// Creates the process tap that carries the far end of a call and starts it,
    /// unless the session is currently paused.
    ///
    /// Deliberately best-effort: the permission is separate from the microphone's,
    /// it can be refused, and the version gate is 14.2. Any of those failing
    /// leaves a working microphone-only session and reports why.
    ///
    /// A paused session must stay paused. Enabling system audio while paused --
    /// the app pauses both routes together -- creates the tap but leaves it
    /// stopped, so the setting is remembered without undoing the pause; `resume()`
    /// starts it like any other tap.
    private func startSystemAudio() {
        guard SystemAudioTap.isSupported else {
            onSystemAudioFailure?("這個 macOS 版本不支援系統音訊擷取（需要 macOS 14.2 以上）")
            return
        }
        guard let tap = try? SystemAudioTap(onSamples: { [weak self] samples in
            self?.feed(samples, speaker: 1)
        }) else {
            onSystemAudioFailure?("無法建立系統音訊擷取")
            return
        }
        stateLock.lock()
        let isPaused = paused
        stateLock.unlock()
        if isPaused {
            systemTap = tap
            return
        }
        do {
            try tap.start()
            systemTap = tap
        } catch {
            onSystemAudioFailure?(error.localizedDescription)
        }
    }

    /// Stops feeding audio without ending the session, so the transcript
    /// continues where it stopped instead of opening a second one.
    public func pause() {
        setSystemTapPaused(true)
        stateLock.lock()
        paused = true
        stateLock.unlock()
    }

    public func resume() {
        setSystemTapPaused(false)
        stateLock.lock()
        paused = false
        stateLock.unlock()
    }

    /// Turns the system-audio tap on or off part-way through a recording.
    ///
    /// Turning it on starts the same tap `start()` would have — created stopped
    /// instead when the session is paused, so the pause survives the toggle — and
    /// a failure travels the same way, through `onSystemAudioFailure`, because
    /// the reason (permission, a version gate) is a fact about the machine, not
    /// about when the user asked. Turning it off stops and drops the tap so a
    /// later `resume()` has nothing stale to restart, and the microphone keeps
    /// going either way.
    public func setSystemAudioEnabled(_ enabled: Bool) {
        // A tap belongs to a recording that is running. On a session that never
        // started, or one that already finished, starting a tap would record the
        // system's audio with nothing left that could stop it -- `finish()` and
        // `cancel()` have both returned by then.
        guard started, !finished else { return }
        if enabled {
            // Already recording the far end: leaving the existing tap alone keeps
            // the utterance numbering continuous, which a restart would not.
            guard systemTap == nil else { return }
            startSystemAudio()
        } else {
            systemTap?.stop()
            systemTap = nil
        }
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
        systemTap?.stop()
        systemTap = nil
        stopPolling()

        return try queue.sync {
            segments.append(contentsOf: (try? CoreABI.takeSegments()) ?? [])
            let stopText = try CoreABI.stopASR()
            // `ASR_Stop` decodes the final utterance itself; one more drain puts
            // the closing sentence in.
            segments.append(contentsOf: (try? CoreABI.takeSegments()) ?? [])
            let joined = Text.join(segments.map(\.text))
            let raw = joined.isEmpty ? stopText.trimmingCharacters(in: .whitespacesAndNewlines) : joined
            // A meeting keeps the transcript as it was spoken, so the cleanup
            // chain does not run over it. It is the dictation prompt, and a
            // meeting transcript run through it comes back rewritten and
            // condensed -- wrong about what was said, which is the one thing a
            // record of a meeting cannot be. The summary is a separate, explicit
            // step over the raw text.
            //
            // It was not only wrong: it was also wasted. Every meeting paid for
            // a full model refinement and threw the answer away, which on a
            // long meeting is minutes of wall-clock and a second worker job
            // contending with the summary that the user actually wanted.
            let refined = mode == .dictation
                ? Refiner.refine(raw: raw, config: config)
                : Refiner.tidy(raw)
            return VoiceInputResult(raw: raw, refined: refined, segments: segments)
        }
    }

    /// Abandons the recording without producing a result.
    ///
    /// Built for termination paths — the app calls it from
    /// `applicationWillTerminate`. Two things have to happen there and neither can
    /// wait for a `finish()`: the microphone and the Core Audio process tap must
    /// be closed (the tap lights the system-audio indicator for as long as it
    /// exists), and the core's single ASR session must be released, since the
    /// recording is being thrown away and cannot run a cleanup pass. So nothing
    /// is decoded, nothing is delivered, and whatever was decoded is discarded.
    ///
    /// Marks the session finished, exactly as a normal `finish()` does, so a later
    /// `finish()` throws rather than reading half a session. A no-op, and never a
    /// throw, on a session that never started.
    public func cancel() {
        guard !finished else { return }
        finished = true

        capture?.stop()
        capture = nil
        systemTap?.stop()
        systemTap = nil
        stopPolling()

        guard started else { return }
        // Same ordering rule as `finish()`: no submit may race the stop, so the
        // stop rides the queue. The decoded text is deliberately dropped.
        queue.sync { _ = try? CoreABI.stopASR() }
    }


// MARK: - Private

    /// The one place audio enters the engine, from either route. Pause gates this
    /// and nothing else, which is what keeps the ASR session open across a pause.
    ///
    /// `speaker` is 0 for the microphone and 1 for system audio; the core tags
    /// each utterance with it, which is what lets the transcript say 我／對方.
    private func feed(_ samples: [Float], speaker: UInt32 = 0) {
        stateLock.lock()
        let isPaused = paused
        stateLock.unlock()
        guard !isPaused else { return }
        queue.async { try? CoreABI.submit(samples, speaker: speaker) }
    }

    /// System audio keeps arriving while paused unless it is stopped too, and the
    /// point of a pause is that nothing is transcribed.
    private func setSystemTapPaused(_ paused: Bool) {
        guard let tap = systemTap else { return }
        if paused {
            tap.stop()
        } else {
            try? tap.start()
        }
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

/// The cleanup chain, for a caller that already has text.
///
/// Exactly what `VoiceInputEngine.transcribe(fileAt:)` runs between the
/// transcript and the result: Traditional-Chinese normalisation, the refine pass
/// with the engine's own keyword narrowing and spoken-edit detection, the sanity
/// guard, and the optional translation. It is public so a host that owns its own
/// capture and ASR — the app does — still uses one implementation of the
/// cleanup rather than a second copy that drifts from this one.
///
/// Never throws and never returns nothing: a failure falls back to the
/// script-normalised transcript, because losing a dictation to a bad generation
/// is worse than pasting a rough one.
public func refineTranscript(_ raw: String, config: VoiceInputConfig) -> String {
Refiner.refine(raw: raw, config: config)
}
