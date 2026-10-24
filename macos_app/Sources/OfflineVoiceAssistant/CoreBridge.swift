import Foundation
import COfflineVoiceCore

/// Swift wrapper over the Rust core's C ABI. All calls are serialized by the core.
enum CoreError: Error, CustomStringConvertible {
    case status(Int32, String)

    var description: String {
        switch self {
        case let .status(code, msg): return "core error \(code): \(msg)"
        }
    }
}

enum Core {
    static func lastError() -> String {
        guard let p = Core_GetLastError() else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    static func check(_ rc: Int32) throws {
        if rc != 0 { throw CoreError.status(rc, lastError()) }
    }

    static func initialize(modelsDir: String) throws {
        try check(Core_Initialize(modelsDir))
    }

    static func shutdown() {
        _ = Core_Shutdown()
    }

    static func loadASR() throws { try check(Agent_Load("asr")) }
    static func unloadASR() throws { try check(Agent_Unload("asr")) }

    static func startASR() throws { try check(ASR_Start()) }

    /// samples: mono float32 at 16 kHz.
    static func submit(_ samples: [Float]) throws {
        try submit(samples, speaker: .me)
    }

    /// Append audio tagged with the route it came from. Meeting mode feeds the
    /// microphone as `.me` and the system-audio tap as `.other`; the engine
    /// segments the two routes separately so each sentence keeps its speaker.
    static func submit(_ samples: [Float], speaker: Speaker) throws {
        let tag: UInt32 = speaker == .me ? 0 : 1
        try samples.withUnsafeBufferPointer { buf in
            try check(ASR_SubmitTagged(buf.baseAddress, buf.count, 16_000, tag))
        }
    }

    /// Wire shape of one segment from `ASR_TakeSegments`.
    private struct SegmentPayload: Decodable {
        let index: Int
        let speaker: Int
        let start: Double
        let end: Double
        let text: String
    }

    /// Utterances the engine has decoded since the previous call.
    ///
    /// This decodes synchronously inside the engine (a few hundred milliseconds
    /// per utterance), so call it from a timer on a background queue, never from
    /// the audio callback and never on the main thread in a tight loop.
    static func takeSegments() throws -> [TranscriptSegment] {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_TakeSegments(&out))
        guard let p = out else { return [] }
        defer { Core_FreeString(p) }
        let json = String(cString: p)
        guard let data = json.data(using: .utf8), json != "[]" else { return [] }
        let payload = try JSONDecoder().decode([SegmentPayload].self, from: data)
        return payload.map {
            TranscriptSegment(
                index: $0.index,
                speaker: $0.speaker == 1 ? .other : .me,
                start: $0.start,
                end: $0.end,
                text: $0.text
            )
        }
    }

    /// Polish a transcript with the LLM, with an optional keywords hint injected
    /// into the prompt. `stages` picks how many model passes to run: 0 = decide
    /// by transcript length, 1 = condense once, 2 = understand the speech first,
    /// then condense it. Throws if the LLM is unavailable or fails; callers
    /// decide the fallback (the raw transcript).
    static func refineWithKeywords(_ text: String, keywordsHint: String, stages: UInt32 = 0) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        let hintC = keywordsHint.isEmpty ? nil : keywordsHint
        try check(LLM_RefineTextWithKeywordsStages(text, hintC, stages, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Structured meeting summary (摘要 / 決策 / 待辦) via the LLM worker.
    static func summarize(_ transcript: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_Summarize(transcript, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    static func stopASR() throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_Stop(&out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Live preview of the transcript so far. `stopASR` finishes the session;
    /// this only looks, so it is safe to poll while recording. The cost grows
    /// with the audio buffered, so poll it slowly rather than per frame.
    static func peekASR() throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(ASR_Peek(&out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }

    /// Translate a finished line into "en" or "zh". Runs as its own model pass,
    /// after the refine pass.
    static func translate(_ text: String, to target: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_Translate(text, target, &out))
        guard let p = out else { return "" }
        defer { Core_FreeString(p) }
        return String(cString: p)
    }
}
