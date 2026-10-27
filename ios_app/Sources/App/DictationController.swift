import AVFoundation
import SwiftUI
import UIKit

/// One dictation, from the first buffer to the text the keyboard types.
///
/// The keyboard cannot record -- iOS refuses a microphone inside an app extension
/// in CoreMedia, before any permission prompt -- so every dictation happens here,
/// in the containing app, and reaches the keyboard through the App Group. That
/// makes this class the product's whole pipeline:
///
///   mic -> spool to disk -> recogniser -> publish -> keyboard inserts at cursor
///
/// Two details make it feel fast rather than just work. The phase is set to
/// `.recording` before the microphone opens, so the first frame the user sees is
/// already the recording state. And stopping is *automatic* on silence, so the
/// user never has to press stop and then find the back button: they speak, stop,
/// and leave -- the decode runs in the background time they just freed up.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var phase: SharedStore.Phase = .idle
    /// Settled words, accumulated as the recogniser closes utterances.
    @Published private(set) var transcript = ""
    /// The utterance still open, shown while it is being spoken.
    @Published private(set) var live = ""
    /// A failure worth showing on the app's own screen.
    @Published private(set) var error: String?

    /// What the user should read right now, in one string.
    var display: String { transcript + live }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .recording || phase == .transcribing || phase == .refining }

    private let work = DispatchQueue(label: "ovc.dictation", qos: .userInitiated)

    private var mic: MicCapture?
    private var spool: AudioSpool?
    private var gate: SilenceGate?
    private var pollTimer: Timer?
    private var background: UIBackgroundTaskIdentifier = .invalid
    /// The transcript as heard, kept while the cleanup pass runs so a timeout can
    /// publish it instead of losing it.
    private var pendingRaw: String?
    /// Bounds the cleanup pass. A model that never returns would otherwise leave
    /// the keyboard on "整理中…" forever, and the sentence -- already decoded and
    /// sitting in `pendingRaw` -- would never be handed over.
    private var refineTimer: Timer?
    /// A spool file inherited from a killed run. Removed once its words are
    /// published, so a second crash does not lose the sentence.
    private var orphanSource: URL?
    /// Set when the audio came back from disk after the system killed the app.
    /// That sentence has already cost the user one attempt, so it is published as
    /// heard rather than risking the slow path again.
    private var skipRefine = false
    /// Which dictation the pending work belongs to.
    ///
    /// Every completion -- decode, cleanup pass, the background deadline, the
    /// live-word poll -- checks this before touching state. Without it, "clear"
    /// followed by a decode that was already in flight still published the
    /// previous sentence to the keyboard, and a second dictation's cleanup pass
    /// could land in the middle of the first one's.
    private var generation = 0
    /// The generation whose result has already been handed over. One dictation
    /// publishes once, whichever deadline gets there first.
    private var publishedGeneration = -1
    /// The recogniser is loaded once per launch. `onAppear` can run twice, and a
    /// second `Core_Initialize` would reload a 100 MB model for nothing.
    private var prewarmed = false

    @discardableResult
    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    // MARK: start

    /// Loads the recogniser before the first dictation.
    ///
    /// The keyboard's microphone tap opens the app and expects it to be recording
    /// on the first frame. Waiting for a 100 MB model to map would show a second of
    /// "待機" first, so the load happens while the user is still in the app they
    /// were typing in.
    func prewarm() {
        guard SharedStore.hasModels, !prewarmed else { return }
        prewarmed = true
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                Diagnostics.log.notice("recogniser ready")
            } catch {
                DispatchQueue.main.async { self.prewarmed = false }
                Diagnostics.log.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Begins a dictation from the microphone. Safe to call when one is already
    /// running: the keyboard reopens the app on every microphone tap.
    func start() {
        guard !isBusy else { return }
        let g = nextGeneration()
        reset()
        phase = .recording
        SharedStore.setPhase(.recording, detail: "錄音中…")

        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                guard granted else {
                    self.fail("需要麥克風權限。請到 設定 › 語音輸入 開啟「麥克風」。")
                    return
                }
                self.openMicrophone(g: g)
            }
        }
    }

    private func openMicrophone(g: Int) {
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                try Core.start()
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription, g: g) }
                return
            }
            DispatchQueue.main.async { self.attach(g: g) }
        }
    }

    private func attach(g: Int) {
        guard phase == .recording, g == generation else { return }
        do {
            let spool = try AudioSpool()
            let mic = MicCapture()
            let gate = SilenceGate()

            gate.onFire = { [weak self] reason in
                DispatchQueue.main.async { self?.stop(reason: reason) }
            }
            mic.onSamples = { samples in
                spool.append(samples)
                Core.submit(samples)
                gate.consume(samples)
            }

            do {
                try mic.start(keepAlive: SharedStore.mode == .pip)
            } catch {
                // The spool file exists as soon as it is created. Dropping the
                // reference would leave it for `recoverOrphan` to find on every
                // later launch, decode to nothing, and fail on again, for ever.
                spool.discard()
                throw error
            }
            self.spool = spool
            self.mic = mic
            self.gate = gate
            startPolling(g: g)
            Diagnostics.log.notice("dictation started")
        } catch {
            fail(error.localizedDescription, g: g)
        }
    }

    // MARK: stop

    /// Ends the dictation and decodes what is left. `reason` is shown to the user
    /// ("靜音" when they simply stopped talking).
    func stop(reason: String = "") {
        guard phase == .recording else { return }
        pollTimer?.invalidate()
        pollTimer = nil

        mic?.onSamples = nil
        mic?.stop(keepAlive: SharedStore.mode == .pip)
        mic = nil
        gate = nil

        decode(accumulated: transcript, reason: reason, g: generation)
    }

    private func decode(accumulated: String, reason: String, g: Int) {
        phase = .transcribing
        SharedStore.setPhase(.transcribing, detail: "辨識中…")
        // The user is about to leave for the app they were typing in. This keeps
        // the process alive for the seconds the decode needs.
        beginBackground(g: g)

        work.async {
            let final = (try? Core.stop()) ?? ""
            let out = Self.merge(accumulated, final)
            DispatchQueue.main.async {
                self.complete(out, reason: reason, g: g)
            }
        }
    }

    private func complete(_ raw: String, reason: String, g: Int) {
        guard g == generation else { return }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spool?.discard()
            spool = nil
            endBackground()
            fail("沒有聽到聲音。再說一次，靠近一點。", g: g)
            return
        }

        transcript = raw
        live = ""

        guard SharedStore.refineEnabled, !skipRefine else {
            publish(raw, detail: reason.isEmpty ? "已辨識" : "已辨識 · \(reason)", g: g)
            return
        }

        // The cleanup pass, on the same background time the decode started. If it
        // does not finish, the transcript is published as heard rather than
        // dropped: a rough sentence is still the user's sentence.
        pendingRaw = raw
        phase = .refining
        SharedStore.setPhase(.refining, detail: "整理中…")
        startRefineDeadline(g: g)

        work.async {
            var failure: String?
            let refined: String
            do {
                refined = try Core.refine(raw)
            } catch {
                refined = raw
                failure = error.localizedDescription
            }
            let served = Core.lastModelName()
            DispatchQueue.main.async {
                guard g == self.generation, self.phase == .refining else { return }
                if let failure {
                    Diagnostics.log.error("refine failed: \(failure, privacy: .public)")
                    self.publish(refined, detail: "已辨識 · 整理失敗", g: g)
                } else {
                    // Which model answered is a fact the core reports, not
                    // something to infer from how long the pass took.
                    LLMPolicy.recordIfDowngraded(
                        served: served,
                        reason: "整理時 \(LLMPolicy.preferredName) 無法執行，改用 \(served)"
                    )
                    self.publish(refined, detail: reason.isEmpty ? "已整理" : "已整理 · \(reason)", g: g)
                }
            }
        }
    }

    /// Hands over the unedited transcript if the cleanup pass overruns.
    ///
    /// Below the ~30 seconds iOS allows a backgrounded app, so the app decides
    /// what happens rather than racing the system's own deadline: a phone that is
    /// busy gives the user their words a few seconds early instead of losing the
    /// pass to a kill it cannot log.
    private func startRefineDeadline(g: Int) {
        refineTimer?.invalidate()
        refineTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, g == self.generation, self.phase == .refining,
                  let raw = self.pendingRaw
            else { return }
            Diagnostics.log.error("refine overran its deadline; publishing as heard")
            // Twenty-five seconds is already inside the window iOS gives a
            // backgrounded app, so this is the device saying the model is too slow
            // -- for good, not once. Recorded so the next launch starts on the
            // smaller one instead of losing the pass again.
            LLMPolicy.recordDowngrade(reason: "整理超過 25 秒，未在背景時間內完成")
            // The pass itself cannot be interrupted -- it is one blocking call
            // into llama.cpp -- so it keeps the work queue busy and the next
            // dictation waits behind it. The result is discarded by generation,
            // but the wait is real: logged, not hidden.
            Diagnostics.log.notice("the abandoned cleanup pass still occupies the work queue")
            self.publish(raw, detail: "已辨識 · 未整理", g: g)
        }
    }

    private func publish(_ text: String, detail: String, g: Int) {
        guard g == generation, publishedGeneration != g else { return }
        publishedGeneration = g
        pendingRaw = nil
        refineTimer?.invalidate()
        refineTimer = nil
        endBackground()
        // Only now is the audio no longer needed: the words are on their way to
        // the keyboard. Until this point the file is the only copy, and the system
        // can still kill the app mid-pass.
        spool?.discard()
        spool = nil
        if let orphanSource {
            try? FileManager.default.removeItem(at: orphanSource)
            self.orphanSource = nil
        }
        transcript = text
        live = ""
        phase = .done
        SharedStore.publish(text, detail: detail)
        Diagnostics.log.notice("dictation done: \(text.count, privacy: .public) chars")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func clear() {
        let wasBusy = isBusy
        // `stop()` hands the tail of the recording to the decode, which belongs
        // to this generation. Bumping after it, so that decode is discarded
        // instead of publishing the sentence the user just cleared.
        if wasBusy { stop() }
        nextGeneration()
        reset()
        phase = .idle
        SharedStore.clear()
    }

    private func reset() {
        transcript = ""
        live = ""
        error = nil
        pendingRaw = nil
        refineTimer?.invalidate()
        refineTimer = nil
        skipRefine = false
        orphanSource = nil
    }

    private func fail(_ message: String, g: Int? = nil) {
        if let g, g != generation { return }
        pollTimer?.invalidate()
        pollTimer = nil
        mic?.onSamples = nil
        mic?.stop()
        mic = nil
        gate = nil
        spool?.discard()
        spool = nil
        if let orphanSource {
            // The file is the only copy of that sentence, but a spool that cannot
            // be decoded will fail identically on every future launch. Keeping it
            // turns one bad file into a permanent failure at startup.
            try? FileManager.default.removeItem(at: orphanSource)
            self.orphanSource = nil
        }
        pendingRaw = nil
        refineTimer?.invalidate()
        refineTimer = nil
        endBackground()
        phase = .failed
        error = message
        SharedStore.setPhase(.failed, detail: message)
        Diagnostics.log.error("dictation failed: \(message, privacy: .public)")
        // The recogniser session may have been opened and then abandoned -- the
        // microphone failed, or the user stopped before it attached. Rust refuses
        // a second `start` while a session is open, so without this the next
        // dictation fails the same way and only a relaunch clears it.
        work.async { _ = try? Core.stop() }
    }

    // MARK: live words

    private func startPolling(g: Int) {
        pollTimer?.invalidate()
        // Decoding happens on `work`, never on the audio thread: `segments()`
        // closes utterances synchronously and takes a few hundred milliseconds.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.work.async {
                let closed = Core.segments()
                let open = Core.peek()
                guard !closed.isEmpty || !open.isEmpty else { return }
                DispatchQueue.main.async {
                    guard g == self.generation, self.phase == .recording else { return }
                    for segment in closed { self.transcript += segment.text }
                    self.live = open
                    SharedStore.setPartial(self.transcript + open)
                }
            }
        }
    }

    // MARK: background time

    private func beginBackground(g: Int) {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "ovc.decode") { [weak self] in
            // Out of time: publishing what is finished beats being killed with
            // nothing. In particular a sentence still waiting on the cleanup pass
            // goes out exactly as it was heard.
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                if let raw = self.pendingRaw {
                    self.publish(raw, detail: "已辨識 · 未整理", g: g)
                } else if !self.transcript.isEmpty {
                    self.publish(self.transcript, detail: "已辨識", g: g)
                }
                self.endBackground()
            }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: injected audio

    /// Runs the whole pipeline over a file instead of the microphone.
    ///
    /// The simulator has no usable microphone, and the pipeline is the part worth
    /// testing anyway: everything after the sample buffer is identical. Reached
    /// with `-OVC_AUDIO_FILE <path.wav>`, which is also how the regression check
    /// drives a known sentence end to end.
    func runInjected(url: URL, detail: String = "測試音", skipRefine: Bool = false) {
        guard !isBusy else { return }
        let g = nextGeneration()
        reset()
        self.skipRefine = skipRefine
        phase = .recording
        SharedStore.setPhase(.recording, detail: "錄音中…")
        Diagnostics.log.notice("dictation injected: \(url.lastPathComponent, privacy: .public)")

        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                try Core.start()
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription, g: g) }
                return
            }

            let samples: [Float]
            do {
                samples = try Self.readMono16k(url)
            } catch {
                DispatchQueue.main.async { self.fail("讀不到測試音：\(error.localizedDescription)", g: g) }
                return
            }
            guard !samples.isEmpty else {
                DispatchQueue.main.async { self.fail("測試音是空的", g: g) }
                return
            }

            // Consumed once the words reach the keyboard, not here: until then the
            // file is the only copy of that sentence. `orphanSource` carries it to
            // `publish`.
            if url.deletingLastPathComponent().standardizedFileURL
                == AudioSpool.directory.standardizedFileURL {
                DispatchQueue.main.async { self.orphanSource = url }
            }

            // Written through the same spool as live audio, so the disk path is
            // exercised too -- a bug there would otherwise only show on a phone.
            let spool = try? AudioSpool()
            var index = 0
            let chunk = 1_600  // 100 ms
            while index < samples.count {
                let end = min(index + chunk, samples.count)
                let slice = Array(samples[index..<end])
                spool?.append(slice)
                Core.submit(slice)
                index = end
                if index % (chunk * 10) == 0 {
                    let open = Core.peek()
                    DispatchQueue.main.async {
                        guard g == self.generation, self.phase == .recording else { return }
                        self.live = open
                        SharedStore.setPartial(open)
                    }
                }
            }
            spool?.close()

            DispatchQueue.main.async {
                guard g == self.generation, self.phase == .recording else {
                    // Cleared or failed while the file was being fed: the spool
                    // was created here, so removing it is this side's job.
                    spool?.discard()
                    return
                }
                self.spool = spool
                self.decode(accumulated: "", reason: detail, g: g)
            }
        }
    }

    /// Finishes a run the system killed before it could publish.
    ///
    /// This is the other half of the spool's promise. The file exists because iOS
    /// can reclaim the app mid-transcription; on the next launch the pipeline runs
    /// over that audio and hands the text to the keyboard as usual, so the
    /// sentence is late rather than lost.
    func recoverOrphan() {
        guard !isBusy, Diagnostics.injectedAudio == nil else { return }
        AudioSpool.prune()
        let orphans = AudioSpool.orphans()
        guard let newest = orphans.last else { return }
        for stale in orphans.dropLast() {
            try? FileManager.default.removeItem(at: stale)
        }
        Diagnostics.log.notice("recovering spool \(newest.lastPathComponent, privacy: .public)")
        // Straight to the keyboard, no cleanup pass. Whatever killed the app last
        // time happened with a sentence already decoded, so this path spends its
        // one shot on delivering rather than on polishing.
        runInjected(url: newest, detail: "補回上次的錄音", skipRefine: true)
    }

    /// Any WAV/CAF/M4A at any rate, as 16 kHz mono float32.
    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        // A spool whose process was killed mid-recording may still be headerless
        // in practice: AVAudioFile writes the WAV header's length when the file is
        // closed, and a killed process never closes it. The audio is all there;
        // only the claim about how much there is was never made. Reading the data
        // chunk directly is what turns "the sentence is on disk" into "the
        // sentence comes back".
        if file.length == 0, let salvaged = salvageRawWAV(url), !salvaged.isEmpty {
            Diagnostics.log.notice("spool had no usable header; read the data chunk directly")
            return salvaged
        }
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioSpool.sampleRate,
            channels: 1, interleaved: false
        )!
        let input = file.processingFormat

        guard let source = AVAudioPCMBuffer(
            pcmFormat: input, frameCapacity: AVAudioFrameCount(max(file.length, 1))
        ) else { throw CoreError.failed(-1, "無法配置讀取緩衝") }
        try file.read(into: source)

        if input.commonFormat == .pcmFormatFloat32,
           input.sampleRate == target.sampleRate,
           input.channelCount == 1,
           let channel = source.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(source.frameLength)))
        }

        guard let converter = AVAudioConverter(from: input, to: target) else {
            throw CoreError.failed(-1, "無法轉換測試音的格式")
        }
        let capacity = AVAudioFrameCount(
            Double(source.frameLength) * (target.sampleRate / input.sampleRate)
        ) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CoreError.failed(-1, "無法配置轉換緩衝")
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, failure == nil, let channel = out.floatChannelData else {
            throw CoreError.failed(-1, failure?.localizedDescription ?? "轉換失敗")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    /// Reads the `data` chunk of a WAV straight off disk.
    ///
    /// The payload is little-endian float32, which is exactly what the spool
    /// writes, so no conversion is needed -- and none is possible, because the
    /// point of this path is that the file's own description of itself is wrong.
    private static func salvageRawWAV(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let marker = data.range(of: Data("data".utf8)),
              marker.upperBound + 4 < data.count
        else { return nil }
        let start = marker.upperBound + 4          // skip the chunk's declared size
        let payload = data[start...]
        let count = payload.count / 4
        guard count > 0 else { return nil }
        var samples = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in 0..<count {
                let bits = base.loadUnaligned(
                    fromByteOffset: index * 4, as: UInt32.self
                )
                samples[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return samples
    }

    // MARK: pieces

    /// `ASR_Stop` returns the whole session, while `transcript` already holds the
    /// utterances closed before it. They usually overlap; keep the longer one.
    private static func merge(_ accumulated: String, _ final: String) -> String {
        if final.isEmpty { return accumulated }
        if accumulated.isEmpty { return final }
        if final.hasPrefix(accumulated) { return final }
        if accumulated.hasPrefix(final) { return accumulated }
        return accumulated + final
    }
}

/// Decides when the user has finished speaking.
///
/// Called from the audio thread on every buffer, so it holds no reference to the
/// controller and does the arithmetic under a lock. Two thresholds: the noise
/// floor measured during the first half second, and a hard silence window. The
/// floor matters -- a quiet room and a train both work without a settings screen.
final class SilenceGate {
    /// Fired once, on the audio thread. The caller hops to main.
    var onFire: ((String) -> Void)?

    private let lock = NSLock()
    private var elapsed: Double = 0
    private var spoken: Double = 0
    private var quiet: Double = 0
    private var floorSample: Double = 1
    private var floorWindow: Double = 0
    private var didFire = false

    private let sampleRate: Double = AudioSpool.sampleRate
    private let silenceWindow: Double = 1.2
    private let minimumSpeech: Double = 0.35
    private let maximumLength: Double = 60

    func consume(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let seconds = Double(samples.count) / sampleRate

        var sum: Double = 0
        for sample in samples { sum += Double(sample * sample) }
        let rms = (sum / Double(samples.count)).squareRoot()

        lock.lock()
        guard !didFire else { lock.unlock(); return }

        elapsed += seconds
        // Learn the room for the first half second, before anything is said.
        if floorWindow < 0.5 {
            floorSample = min(floorSample, rms)
            floorWindow += seconds
        }
        let threshold = min(max(floorSample * 3.0, 0.0045), 0.02)

        if rms > threshold {
            spoken += seconds
            quiet = 0
        } else {
            quiet += seconds
        }

        var reason: String?
        if elapsed >= maximumLength {
            reason = "60 秒上限"
        } else if spoken >= minimumSpeech, quiet >= silenceWindow {
            reason = "靜音"
        }
        if reason != nil { didFire = true }
        lock.unlock()

        // Outside the lock: the callback hops to the main queue, and a lock held
        // across that hop is how a debugger session ends in a mystery hang.
        if let reason { onFire?(reason) }
    }
}
