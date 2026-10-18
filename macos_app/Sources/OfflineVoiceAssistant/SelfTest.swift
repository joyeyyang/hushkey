import Foundation

/// Test-only input source. When OVC_SELFTEST_WAV is set, the app feeds a WAV file through the
/// same ASR path the microphone uses, instead of the microphone. It stops at the
/// transcript (no LLM polish, no paste) so it can run headless and exit with a status.
/// Supported input: 16 kHz, mono, 16-bit PCM. Anything else is rejected, not converted.
enum SelfTest {
    static var wavPath: String? { ProcessInfo.processInfo.environment["OVC_SELFTEST_WAV"] }

    /// With OVC_SELFTEST_POLISH set, a WAV run continues past ASR into refine and
    /// paste (the whole pipeline) and exits when the text has been delivered,
    /// instead of stopping at the transcript.
    static var runsFullPipeline: Bool { ProcessInfo.processInfo.environment["OVC_SELFTEST_POLISH"] != nil }

    /// Set once a full-pipeline run has delivered its text, so the app exits
    /// cleanly rather than sitting in the menu bar.
    static var exitsWhenDone = false

    enum WavError: Error, CustomStringConvertible {
        case notRiffWave
        case unsupported(String)
        case noData

        var description: String {
            switch self {
            case .notRiffWave: return "not a RIFF/WAVE file"
            case let .unsupported(what): return "unsupported WAV: \(what) (need 16 kHz mono 16-bit PCM)"
            case .noData: return "WAV has no data chunk"
            }
        }
    }

    /// Returns float samples in [-1, 1].
    static func readWav(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        guard d.count >= 12, String(data: d[0..<4], encoding: .ascii) == "RIFF",
              String(data: d[8..<12], encoding: .ascii) == "WAVE" else {
            throw WavError.notRiffWave
        }
        var offset = 12
        var sampleRate: UInt32 = 0, channels: UInt16 = 0, bits: UInt16 = 0, format: UInt16 = 0
        var pcm: Data?
        while offset + 8 <= d.count {
            let id = String(data: d[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(d.subdata(in: offset + 4 ..< offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let body = offset + 8
            let end = min(body + size, d.count)
            if id == "fmt " {
                format = d.subdata(in: body ..< body + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                channels = d.subdata(in: body + 2 ..< body + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                sampleRate = d.subdata(in: body + 4 ..< body + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                bits = d.subdata(in: body + 14 ..< body + 16).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            } else if id == "data" {
                pcm = d.subdata(in: body ..< end)
            }
            offset = body + size + (size % 2)
        }
        guard format == 1 || format == 0xFFFE else { throw WavError.unsupported("format \(format)") }
        guard sampleRate == 16_000 else { throw WavError.unsupported("sample rate \(sampleRate)") }
        guard channels == 1 else { throw WavError.unsupported("\(channels) channels") }
        guard bits == 16 else { throw WavError.unsupported("\(bits)-bit") }
        guard let data = pcm else { throw WavError.noData }
        var out = [Float](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<out.count { out[i] = Float(Int16(littleEndian: s[i])) / 32768.0 }
        }
        return out
    }
}
