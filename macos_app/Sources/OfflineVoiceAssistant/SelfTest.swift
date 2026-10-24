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

    // MARK: - Export self-test

    /// Exercises every export format against one synthetic transcript.
    ///
    /// The point is not to check the wording: it is that all four formats are
    /// written, that the JSON round-trips through its own decoder, that the SRT
    /// carries usable timecodes, and that a second save of the same name does
    /// not overwrite the first. Exits non-zero on the first failure, so a build
    /// script can gate on it.
    static func runExportSelfTest() -> Never {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segments = [
            TranscriptSegment(index: 1, speaker: .me, start: 0, end: 2.5, text: "我們今天要決定上線時間。"),
            TranscriptSegment(index: 2, speaker: .other, start: 2.6, end: 6.0, text: "好，那就下週三上線，其他頁面之後再排。"),
            TranscriptSegment(index: 3, speaker: .me, start: 6.4, end: 9.25, text: "怡君你下週五以前把客服 SOP 生出來。"),
        ]
        let document = TranscriptDocument(startedAt: start, endedAt: start.addingTimeInterval(9.25), segments: segments)
        let bundle = ExportBundle(
            title: "測試會議",
            transcript: document,
            summaryMarkdown: "## 摘要\n\n決定下週三上線。\n\n## 決議\n\n下週三上線，其他頁面稍後。\n\n## 待辦\n\n- 怡君：下週五前生出客服 SOP",
            translation: nil
        )

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ovc-export-selftest", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)

        var failures: [String] = []
        var settings = ExportSettings(folder: folder.path, format: .markdown, autoSave: true)

        for format in ExportFormat.allCases {
            settings.format = format
            do {
                let url = try Exporter.save(bundle, as: format, settings: settings)
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else {
                    failures.append("\(format.rawValue): empty file")
                    continue
                }
                let text = String(decoding: data, as: UTF8.self)
                switch format {
                case .json:
                    let decoded = try Exporter.decodeJSON(data)
                    if decoded.segments.count != segments.count { failures.append("json: segment count") }
                    if decoded.summary.isEmpty { failures.append("json: empty summary") }
                case .srt:
                    if !text.contains("00:00:00,000 --> 00:00:02,500") {
                        failures.append("srt: missing first timecode")
                    }
                    if !text.contains("下週三上線") { failures.append("srt: missing text") }
                case .markdown:
                    if !text.contains("# 測試會議") { failures.append("md: missing title") }
                    if !text.contains("## 逐字稿") { failures.append("md: missing transcript") }
                    if !text.contains("我：") || !text.contains("對方：") {
                        failures.append("md: missing speaker labels")
                    }
                case .txt:
                    if text.contains("## 摘要") { failures.append("txt: markdown leaked") }
                }
                print("ok \(format.rawValue) \(url.lastPathComponent) \(data.count)B")
            } catch {
                failures.append("\(format.rawValue): \(error)")
            }
        }

        // Same name twice must produce -2, never overwrite.
        settings.format = .markdown
        do {
            let first = try Exporter.save(bundle, as: .markdown, settings: settings)
            let second = try Exporter.save(bundle, as: .markdown, settings: settings)
            if first == second { failures.append("save: second write replaced the first") }
            else { print("ok collision \(second.lastPathComponent)") }
        } catch {
            failures.append("collision: \(error)")
        }

        if failures.isEmpty {
            print("EXPORT SELFTEST PASS")
            exit(0)
        }
        for failure in failures { print("FAIL \(failure)") }
        exit(1)
    }
}
