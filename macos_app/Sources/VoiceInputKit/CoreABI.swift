import Foundation
import COfflineVoiceCore

/// A throwing façade over the Rust core's C ABI.
///
/// This is the same bridge the app uses (`CoreBridge.swift`), reduced to the
/// calls this kit needs and kept internal so the public surface stays small.
/// Two details are load-bearing and copied from there unchanged:
///
///  * Every call reports failure as a non-zero status plus a message that lives
///    only until the *next* core call, so the message must be read immediately,
///    and
///  * `ASR_TakeSegments` returns only segments not yet handed over, which is
///    what lets callers append rather than diff.
///
/// All C entry points serialize on the core's own mutex, so these are safe from
/// any thread; callers only have to keep their own ordering (notably: never let
/// `ASR_Stop` race an in-flight `ASR_Submit*`).
enum CoreABI {

    /// Fetches and frees the per-thread last-error string. Empty when the core
    /// has nothing to say, which is the normal state after a success.
    static func lastError() -> String {
        guard let p = Core_GetLastError() else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Turns a status into a Swift error, capturing the message before anything
    /// else can overwrite it.
    static func check(_ rc: Int32) throws {
        if rc != 0 { throw VoiceInputError.core(rc, lastError()) }
    }

    // MARK: - Core lifecycle

    static func initialize(modelsDir: String) throws {
        try check(Core_Initialize(modelsDir))
    }

    static func shutdown() {
        _ = Core_Shutdown()
    }

    // MARK: - ASR lifecycle

    /// Idempotent in the core, so calling it again on an already-loaded model is
    /// a cheap no-op rather than an error.
    static func loadASR() throws { try check(Agent_Load("asr")) }

    static func unloadASR() throws { try check(Agent_Unload("asr")) }

    static func startASR() throws { try check(ASR_Start()) }

    /// Appends 16 kHz mono float32 audio. `speaker` is 0 for the microphone and
    /// 1 for a system-audio tap; the two routes are segmented separately, which
    /// is what makes a two-route meeting transcript possible.
    static func submit(_ samples: [Float], speaker: UInt32 = 0) throws {
        try samples.withUnsafeBufferPointer { buf in
            try check(ASR_SubmitTagged(buf.baseAddress, buf.count, 16_000, speaker))
        }
    }

    /// Decodes whatever is left, ends the session, and returns the full text.
    /// Callers must stop feeding audio first — this is not safe to interleave
    /// with `submit`.
    static func stopASR() throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_Stop(&out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Live preview only; consumes nothing and is cheap enough to poll while
    /// recording. The cost still grows with the audio buffered, so poll slowly.
    static func peekASR() throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_Peek(&out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Wire shape of one segment from `ASR_TakeSegments`.
    private struct SegmentPayload: Decodable {
        let index: Int
        let speaker: Int
        let start: Double
        let end: Double
        let text: String
    }

    /// Utterances decoded since the previous call. Decoding is synchronous
    /// inside the engine (a few hundred ms per utterance), so call it from a
    /// timer on a background queue — never the audio callback.
    static func takeSegments() throws -> [Utterance] {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_TakeSegments(&out))
        guard let p = out else { return [] }
        defer { Core_FreeString(p) }
        let json = String(cString: p)
        guard json != "[]", let data = json.data(using: .utf8) else { return [] }
        let payload = try JSONDecoder().decode([SegmentPayload].self, from: data)
        return payload.map {
            Utterance(
                index: $0.index,
                source: $0.speaker == 1 ? .systemAudio : .microphone,
                start: $0.start,
                end: $0.end,
                text: $0.text
            )
        }
    }

    // MARK: - LLM

    /// Cleanup pass with a keywords hint. `stages` is passed straight through to
    /// the engine, which owns the single-vs-two-pass rule. Throws when the LLM
    /// worker is unavailable; callers fall back to the raw transcript.
    static func refine(_ text: String, keywordsHint: String, stages: UInt32) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        let hintC = keywordsHint.isEmpty ? nil : keywordsHint
        try check(LLM_RefineTextWithKeywordsStages(text, hintC, stages, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Separate translate pass, run after refine. `target` is "en" or "zh".
    static func translate(_ text: String, to target: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_Translate(text, target, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }
}
