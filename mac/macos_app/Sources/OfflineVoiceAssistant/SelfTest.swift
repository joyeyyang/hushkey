import AppKit
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

    // MARK: - Theme self-test

    /// Renders every palette's capsule and checks the one property a picture
    /// cannot prove: contrast of the ink against its own paper.
    ///
    /// Each PNG is written where `OVC_SELFTEST_THEMES` says (a temp folder by
    /// default) so the themes can be looked at rather than argued about.
    /// Renders every screen of the main window, offscreen, for visual review.
    ///
    /// This is how the redesign is checked without a window server: a PNG per
    /// tab plus one of the whole window, for one or more themes. Runs against
    /// the real models directory and history, so the pictures show this machine.
    static func runWindowSelfTest(outDir: String, themeIDs: [String]) -> Never {
        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures: [String] = []
        for id in themeIDs {
            let theme = ThemeCatalog.theme(id: id)
            let window = MainWindow(keywords: Keywords(), history: HistoryStore())
            window.applyTheme(theme)
            let tabs = ["轉錄", "歷史", "關鍵字", "模型", "設定"]
            for (index, name) in tabs.enumerated() {
                let url = dir.appendingPathComponent("\(theme.id)-\(index)-\(name).png")
                if window.snapshotTab(name, to: url), let data = try? Data(contentsOf: url), data.count > 3_000 {
                    print("ok \(theme.id) \(name) \(data.count)B")
                } else {
                    failures.append("\(theme.id) \(name)")
                }
                // The first tab is the one the window opens on, so the whole
                // window shot is worth taking once, with the header and strip.
                if index == 0 {
                    let full = dir.appendingPathComponent("\(theme.id)-window.png")
                    if window.snapshotWindow(to: full) {
                        print("ok \(theme.id) window")
                    } else {
                        failures.append("\(theme.id) window")
                    }
                }
            }
        }
        // The floating window is where a recording is watched, and it is the
        // surface a person stares at while talking, so it is reviewed in the same
        // pass -- in each of the three shapes the merge produced: the live
        // controls with the words arriving under them, the confirm-before-insert
        // card, and the finished line over the same transcript.
        let dictationSegments = [
            TranscriptSegment(index: 1, speaker: .me, start: 0, end: 3.2,
                              text: "那我們先確認一下這週的進度，簡報的初稿你覺得還缺什麼？"),
            TranscriptSegment(index: 2, speaker: .other, start: 3.4, end: 7.8,
                              text: "主要是第二段的數字還沒更新，我明天早上補給你。"),
            TranscriptSegment(index: 3, speaker: .me, start: 8.0, end: 9.6,
                              text: "好，那週三之前給客戶看。"),
        ]
        for id in themeIDs {
            let theme = ThemeCatalog.theme(id: id)
            // One window, re-skinned across the three shots: a fresh one per
            // shape would install another pair of Escape monitors for nothing.
            let window = DictationWindow()
            window.applyTheme(theme)
            window.snapshotTranscript(
                to: dir.appendingPathComponent("\(theme.id)-dictation-recording.png"),
                title: "會議逐字稿 · 10:42",
                status: "辨識中…",
                segments: dictationSegments,
                showSpeaker: true
            )
            window.snapshotEdit(
                to: dir.appendingPathComponent("\(theme.id)-dictation-edit.png"),
                text: "那我們先確認一下這週的進度，簡報的初稿還缺第二段的數字。"
            )
            window.snapshotResult(
                to: dir.appendingPathComponent("\(theme.id)-dictation-result.png"),
                text: "下週三上線，其他頁面之後再排。"
            )
            // The step between the mic and the paste: the capsule has to stay,
            // and say what it is doing. This is also the shot that catches a
            // status line drawn through the microphone: the glyph is on screen and
            // the label is visible at the same time.
            window.snapshotProcessing(
                to: dir.appendingPathComponent("\(theme.id)-dictation-processing.png"),
                status: "整理中…",
                segments: Array(dictationSegments.prefix(2))
            )
            // The second before the first word lands, which is the only shape that
            // puts two things in the meter's slot.
            window.snapshotLivePartial(
                to: dir.appendingPathComponent("\(theme.id)-dictation-partial.png"),
                partial: "那我們先確認一下這週的進度"
            )
            for shape in ["dictation-recording", "dictation-edit", "dictation-result", "dictation-processing", "dictation-partial"] {
                let url = dir.appendingPathComponent("\(theme.id)-\(shape).png")
                if let data = try? Data(contentsOf: url), data.count > 3_000 {
                    print("ok \(theme.id) \(shape) \(data.count)B")
                } else {
                    failures.append("\(theme.id) \(shape)")
                }
            }
            window.hide()
        }

        if failures.isEmpty {
            print("WINDOW SELFTEST PASS \(dir.path)")
            exit(0)
        }
        print("WINDOW SELFTEST FAIL: \(failures.joined(separator: ", "))")
        exit(1)
    }

    static func runThemeSelfTest() -> Never {
        let dir = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["OVC_SELFTEST_THEMES"]
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("ovc-themes", isDirectory: true).path,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var failures: [String] = []
        // One window, re-skinned: a fresh DictationWindow per palette would
        // install five pairs of Escape monitors and five panels for no reason.
        let hud = DictationWindow()

        for theme in ThemeCatalog.all {
            let body = contrast(theme.textPrimary, on: theme.background)
            let quiet = contrast(theme.textSecondary, on: theme.background)
            let accent = contrast(theme.accent, on: theme.surface)
            // 4.5:1 is the WCAG AA floor for body text; the accent is used at
            // label weight and as the mic glyph, where 3:1 is the floor.
            if body < 4.5 { failures.append("\(theme.id): body \(fmt(body)):1 < 4.5") }
            if quiet < 4.5 { failures.append("\(theme.id): secondary \(fmt(quiet)):1 < 4.5") }
            if accent < 3.0 { failures.append("\(theme.id): accent \(fmt(accent)):1 < 3.0") }

            hud.applyTheme(theme)
            let url = dir.appendingPathComponent("\(theme.id).png")
            hud.snapshotPreview(text: "會議逐字稿已開始 · \(theme.name)", to: url)
            guard let data = try? Data(contentsOf: url), data.count > 2_000 else {
                failures.append("\(theme.id): no image written")
                continue
            }
            print(
                "ok \(theme.id) \(theme.name) body \(fmt(body)):1 quiet \(fmt(quiet)):1 "
                    + "accent \(fmt(accent)):1 \(data.count)B"
            )
        }

        // The recording capsule in the three states this batch added: live (with
        // the new pause button), paused, and folded to a dot. Rendered offscreen
        // on one palette so the controls can be looked at without recording.
        hud.applyTheme(ThemeCatalog.theme(id: "paper"))
        for (name, paused, folded) in [
            ("rec-live", false, false),
            ("rec-paused", true, false),
            ("rec-folded", false, true),
        ] {
            let url = dir.appendingPathComponent("\(name).png")
            hud.snapshotRecording(to: url, paused: paused, folded: folded)
            guard let data = try? Data(contentsOf: url), data.count > 2_000 else {
                failures.append("\(name): no image written")
                continue
            }
            print("ok \(name) \(data.count)B")
        }

        // The palettes must actually differ, or the picker is a placebo.
        let unique = Set(ThemeCatalog.all.map { "\($0.background)" })
        if unique.count != ThemeCatalog.all.count {
            failures.append("two themes share a background")
        }

        if failures.isEmpty {
            print("THEME SELFTEST PASS \(dir.path)")
            exit(0)
        }
        for failure in failures { print("FAIL \(failure)") }
        exit(1)
    }

    /// WCAG relative luminance, sRGB. `NSColor` has to be resolved first:
    /// a calibrated or catalog colour has no components until it is.
    private static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let s = Double(value)
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private static func contrast(_ foreground: NSColor, on background: NSColor) -> Double {
        let a = luminance(foreground)
        let b = luminance(background)
        return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05)
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}
