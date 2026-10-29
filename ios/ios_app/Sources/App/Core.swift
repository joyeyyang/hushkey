import AVFoundation
import Foundation

/// One decoded utterance from the core.
struct Segment {
    let text: String
    let speaker: Int
}

enum CoreError: LocalizedError {
    case failed(Int32, String)
    var errorDescription: String? {
        switch self {
        case .failed(let code, let message):
            return message.isEmpty ? "核心錯誤 \(code)" : message
        }
    }
}

/// The C ABI, reduced to what dictation needs.
///
/// The recogniser and the LLM both live here. On macOS the model runs in a
/// separate worker process; iOS cannot fork one, so the core runs it in-process
/// and the app decides when it is loaded (`prewarmModel` / `releaseModel`).
enum Core {
    private static var initialized = false
    /// One report per launch for each silent failure path: the poll runs four
    /// times a second, so logging every rejected buffer would bury the log.
    private static var didReportSubmitFailure = false
    private static var didReportSegmentFailure = false

    static func lastError() -> String {
        guard let p = Core_GetLastError() else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    private static func check(_ rc: Int32) throws {
        if rc != 0 { throw CoreError.failed(rc, lastError()) }
    }

    static func initialize(models: URL) throws {
        guard !initialized else { return }
        try check(Core_Initialize(models.path))
        // A model that could not keep up on this device stays downgraded until
        // the user asks otherwise, so the choice has to be in the environment
        // before the first LLM task.
        LLMPolicy.apply()
        // The core ships two recognisers and prefers SenseVoice (240 MB) unless
        // `OVC_ASR_MODEL` says otherwise. There is no shell on iOS, so the app
        // states the choice itself -- but only when SenseVoice is genuinely
        // unusable, so an install that has it keeps the core's own preference.
        //
        // "Usable" is the exact pair `state.rs` loads: `model.int8.onnx` or
        // `model.onnx` *with* `tokens.txt` beside it. Testing only the int8 file
        // sent an fp32 install down the Dolphin path; testing the model without
        // the tokens would select a folder that fails at load time -- with nothing
        // small enough left to retry.
        let manager = FileManager.default
        let sense = ["asr/model.int8.onnx", "asr/model.onnx"].contains {
            manager.fileExists(atPath: models.appendingPathComponent($0).path)
        }
        let senseTokens = manager.fileExists(
            atPath: models.appendingPathComponent("asr/tokens.txt").path
        )
        let dolphin = models.appendingPathComponent("asr/dolphin/model.int8.onnx")
        let dolphinTokens = manager.fileExists(
            atPath: models.appendingPathComponent("asr/dolphin/tokens.txt").path
        )
        // Selecting a SenseVoice folder that is missing its tokens would fail at
        // load time, so a Dolphin install that is complete wins over one that is
        // not. The Dolphin model is held to the same pair as the one above, because
        // `hasModels` and `state.rs` both do -- a model-only test here would point
        // the engine at a folder the other two call incomplete.
        if !(sense && senseTokens), manager.fileExists(atPath: dolphin.path), dolphinTokens {
            setenv("OVC_ASR_MODEL", "dolphin", 1)
        }
        // `Core_Initialize` only points the engine at the model tree; nothing is
        // loaded until an agent is named. On macOS the app loads "asr" the same
        // way, and skipping it is why `ASR_Start` answered "model not loaded".
        try check(Agent_Load("asr"))
        initialized = true
    }

    static func start() throws { try check(ASR_Start()) }

    static func submit(_ samples: [Float]) {
        let rc = samples.withUnsafeBufferPointer {
            ASR_SubmitAudio($0.baseAddress, $0.count, 16_000)
        }
        // Once, not per buffer: a rejected buffer means the recogniser is not in a
        // state to accept audio, and the sentence will come back empty. Saying so
        // here is what separates "the microphone was quiet" from "the engine
        // refused the audio" -- otherwise both arrive as 沒有聽到聲音.
        if rc != 0, !didReportSubmitFailure {
            didReportSubmitFailure = true
            Diagnostics.log.error(
                "asr rejected audio: \(lastError(), privacy: .public)"
            )
        }
    }

    static func segments() -> [Segment] {
        var out: UnsafeMutablePointer<CChar>?
        let rc = ASR_TakeSegments(&out)
        if rc != 0 {
            if !didReportSegmentFailure {
                didReportSegmentFailure = true
                Diagnostics.log.error(
                    "asr segment fetch failed: \(lastError(), privacy: .public)"
                )
            }
            return []
        }
        guard let p = out else { return [] }
        defer { Core_FreeString(p) }
        let json = String(cString: p)
        guard json != "[]", let data = json.data(using: .utf8) else { return [] }
        struct Payload: Decodable { let text: String; let speaker: Int }
        let payload = (try? JSONDecoder().decode([Payload].self, from: data)) ?? []
        return payload.map { Segment(text: $0.text, speaker: $0.speaker) }
    }

    /// The words in the utterance that is still open. Cheap enough to poll.
    static func peek() -> String {
        var out: UnsafeMutablePointer<CChar>?
        guard ASR_Peek(&out) == 0, let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    static func stop() throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_Stop(&out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// The cleanup pass: punctuation, no filler, the speaker's own words.
    ///
    /// Same C ABI the desktop calls, but a different place underneath. macOS hands
    /// the work to `ovc-llm-worker`; iOS cannot fork, so the core runs the model in
    /// this process and KEEPS it there -- the load and the prompt's shared prefix
    /// are paid once per session, not once per sentence (see `prewarmModel` and
    /// `releaseModel` for when it comes and goes). The caller sees no difference.
    ///
    /// `keywords` stays empty: the product decided a stored keyword list fed to the
    /// model made it invent terms rather than spell them better.
    ///
    /// `stages` is the Mac's `OVC_REFINE_STAGES`: 0 lets the engine pick by
    /// transcript length, 1 condenses once, 2 understands then condenses. It
    /// only applies to the "normal" register -- the other two are single-pass by
    /// design (their prompt carries the register, and the two-stage shape's first
    /// pass has no notion of it).
    ///
    /// `tone` is "casual" / "normal" / "formal". The core treats anything else as
    /// "normal", so a stale setting cannot cost the user a sentence.
    static func refine(_ text: String, stages: UInt32 = 0, tone: String = "normal") throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_RefineTextWithTone(text, "", tone, stages, &out))
        guard let p = out else { return text }
        defer { Core_FreeString(p) }
        let refined = String(cString: p).trimmingCharacters(in: .whitespacesAndNewlines)
        return refined.isEmpty ? text : refined
    }

    /// The guardrail, in the core: may this answer be treated as the user's own
    /// text? Returns an EMPTY string when it may, or a short reason when it may
    /// not (for a log, not for the user).
    ///
    /// `mode` is "edit" for the spoken-edit path and "refine" otherwise; `tone`
    /// adds the register rule. The rules themselves live in
    /// `rust/core_engine/src/guardrail.rs`, which the Mac's `Text.sanityCheck`
    /// calls too -- one implementation, not two that are supposed to agree.
    static func checkOutput(raw: String, refined: String, mode: String, tone: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_CheckOutput(raw, refined, mode, tone, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// A dedicated translate pass, run after the cleanup.
    ///
    /// Separate from `refine` on purpose, exactly as on the Mac: one prompt asked
    /// to both clean and translate produced half-translated drafts. `target` is
    /// "en" or "zh"; the caller has already decided that a pass is wanted.
    static func translate(_ text: String, to target: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_Translate(text, target, &out))
        guard let p = out else { return text }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Applies a spoken edit instruction to text this app last handed over.
    ///
    /// The core numbers the lines itself and does positional replacement and
    /// deletion without the model; only a transformation ("改短一點") reaches
    /// llama.cpp. Same call the Mac's `VoiceEdit` makes.
    static func edit(_ text: String, instruction: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_EditText(text, instruction, &out))
        guard let p = out else { return text }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// 摘要／決議／待辦 for a finished meeting transcript.
    ///
    /// A different chain from the dictation cleanup, and deliberately so: the
    /// dictation prompt compresses a transcript into one line, which is exactly
    /// what a meeting must not do with "who promised what".
    static func summarize(_ transcript: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_Summarize(transcript, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Loads the model now instead of on the next task.
    ///
    /// Called when a recording starts. The load is 1.3 GB of weights and the app
    /// has seconds of speaking to hide it in; without this it happens after the
    /// user stops, in the middle of the pause they are waiting out. Best-effort:
    /// a failure here is not reported, because the next real task will fail with
    /// the same reason and a message the user can act on.
    static func prewarmModel() {
        _ = LLM_Prewarm()
    }

    /// Gives the model's memory back: background, or a memory warning.
    ///
    /// The next dictation loads again. Nothing is left half-initialised, so this
    /// is safe to call at any time; it is the counterpart of `prewarmModel`, and
    /// the reason the app does not sit on a gigabyte while it is not being used.
    static func releaseModel() {
        _ = LLM_ReleaseModel()
    }

    /// The file that actually answered the last LLM task.
    ///
    /// Not what was asked for: the core retries with a smaller model when the
    /// preferred one cannot run, and returns that model's text without saying so.
    /// Empty before any task.
    static func lastModelName() -> String {
        var out: UnsafeMutablePointer<CChar>?
        guard LLM_LastModelName(&out) == 0, let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// What the engine holds, for the on-device measurement.
    ///
    /// `peak` is the process peak, not the current footprint: iOS reports the
    /// number a memory-pressure kill would look at, which is the figure M6 is
    /// actually asking about.
    static func memoryUsage() -> (models: UInt64, peak: UInt64) {
        var usage = OvcMemoryUsage(model_bytes: 0, peak_rss_bytes: 0)
        guard Memory_GetUsage(&usage) == 0 else { return (0, 0) }
        return (usage.model_bytes, usage.peak_rss_bytes)
    }
}

/// Microphone in, 16 kHz mono float32 out.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    var onSamples: (([Float]) -> Void)?

    func start(keepAlive: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        // `keepAlive` is Mode 2: the PiP window is only held open by an active
        // audio session, so deactivating it here (or ducking everyone else into
        // silence) would drop the window the app is living inside.
        if keepAlive {
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
        } else {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CoreError.failed(-1, "沒有可用的麥克風")
        }
        converter = AVAudioConverter(from: format, to: target)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = self.target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity),
                  let channel = out.floatChannelData else { return }
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: out, error: &error) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return }
            self.onSamples?(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
        }

        engine.prepare()
        try engine.start()
    }

    func stop(keepAlive: Bool = false) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Deactivating tears down the PiP keep-alive too, so a caller inside
        // Mode 2 leaves the session up on purpose.
        guard !keepAlive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
