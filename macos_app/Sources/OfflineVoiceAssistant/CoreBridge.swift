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
        try samples.withUnsafeBufferPointer { buf in
            try check(ASR_SubmitAudio(buf.baseAddress, buf.count, 16_000))
        }
    }

    /// Polish a transcript with the LLM. Throws if the LLM is unavailable or fails;
    /// callers decide the fallback (the raw transcript).
    static func refine(_ text: String) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        try check(LLM_RefineText(text, &out))
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
}
