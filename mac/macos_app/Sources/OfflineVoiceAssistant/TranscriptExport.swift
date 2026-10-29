import Foundation

// MARK: - Format

/// The four shapes a finished meeting can be written out as.
///
/// The raw values are what `ExportSettings` persists, so they are part of the
/// on-disk contract: rename a case only behind a migration.
enum ExportFormat: String, CaseIterable, Codable {
    case markdown
    case txt
    case srt
    case json

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .txt: return "txt"
        case .srt: return "srt"
        case .json: return "json"
        }
    }

    var displayName: String {
        switch self {
        case .markdown: return "Markdown 文件"
        case .txt: return "純文字"
        case .srt: return "SRT 字幕"
        case .json: return "JSON 資料"
        }
    }
}

// MARK: - Input

/// Everything one export needs: the raw transcript, the model's answer, and —
/// when translation was on — the translated text.
///
/// A value type so the exporter never holds a reference to the live session;
/// the window can keep recording while the file is being written.
struct ExportBundle {
    var title: String
    var transcript: TranscriptDocument
    var summaryMarkdown: String
    var translation: String?

    init(
        title: String,
        transcript: TranscriptDocument,
        summaryMarkdown: String,
        translation: String? = nil
    ) {
        self.title = title
        self.transcript = transcript
        self.summaryMarkdown = summaryMarkdown
        self.translation = translation
    }
}

// MARK: - Errors

enum ExportError: Error, CustomStringConvertible {
    /// Text could not be turned into UTF-8 — practically unreachable, kept so
    /// the caller has one error type to catch.
    case encodingFailed(String)
    /// Neither an explicit destination nor `ExportSettings.folder` was given.
    case folderUnavailable
    case writeFailed(path: String, reason: String)

    var description: String {
        switch self {
        case let .encodingFailed(reason):
            return "匯出編碼失敗：\(reason)"
        case .folderUnavailable:
            return "尚未設定自動儲存資料夾"
        case let .writeFailed(path, reason):
            return "無法寫入 \(path)：\(reason)"
        }
    }
}

// MARK: - JSON mirror

/// The JSON export, as a type.
///
/// Dates are ISO-8601 strings rather than decoder configuration, so a plain
/// `JSONDecoder()` can read a file this app wrote — the format belongs to the
/// document, not to whoever happens to decode it. Times are rounded to the
/// millisecond before encoding, which is what makes encode → decode an exact
/// round trip.
struct ExportDocument: Codable, Equatable {
    struct Segment: Codable, Equatable {
        var index: Int
        var speaker: Speaker
        /// Seconds from the start of the session.
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    var title: String
    var startedAt: Date
    var endedAt: Date
    var segments: [Segment]
    var summary: String
    var translation: String?

    init(
        title: String,
        startedAt: Date,
        endedAt: Date,
        segments: [Segment],
        summary: String,
        translation: String?
    ) {
        self.title = title
        self.startedAt = Self.millisecond(startedAt)
        self.endedAt = Self.millisecond(endedAt)
        self.segments = segments
        self.summary = summary
        self.translation = translation
    }

    private enum CodingKeys: String, CodingKey {
        case title, startedAt, endedAt, segments, summary, translation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        segments = try container.decode([Segment].self, forKey: .segments)
        summary = try container.decode(String.self, forKey: .summary)
        translation = try container.decodeIfPresent(String.self, forKey: .translation)

        let startText = try container.decode(String.self, forKey: .startedAt)
        let endText = try container.decode(String.self, forKey: .endedAt)
        guard let start = ISODate.date(from: startText), let end = ISODate.date(from: endText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startedAt,
                in: container,
                debugDescription: "日期不是 ISO-8601 格式：\(startText) / \(endText)"
            )
        }
        startedAt = start
        endedAt = end
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(ISODate.string(from: startedAt), forKey: .startedAt)
        try container.encode(ISODate.string(from: endedAt), forKey: .endedAt)
        try container.encode(segments, forKey: .segments)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(translation, forKey: .translation)
    }

    /// Truncates to whole milliseconds so the ISO string is lossless.
    static func millisecond(_ date: Date) -> Date {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

// MARK: - ISO-8601

private enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    /// Accepts both forms: our own writer emits milliseconds, hand-edited files
    /// often drop them.
    static func date(from text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: - Exporter

enum Exporter {
    /// The bytes to hand to a save panel or to disk.
    static func data(_ bundle: ExportBundle, as format: ExportFormat) throws -> Data {
        let text: String
        switch format {
        case .markdown:
            text = markdownDocument(bundle)
        case .txt:
            text = plainDocument(bundle)
        case .srt:
            text = srtDocument(bundle)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                // A final newline keeps the file line-oriented like the others;
                // JSONDecoder ignores trailing whitespace.
                return try encoder.encode(document(bundle)) + Data("\n".utf8)
            } catch {
                throw ExportError.encodingFailed("JSON 編碼失敗：\(error)")
            }
        }

        guard let encoded = text.data(using: .utf8) else {
            throw ExportError.encodingFailed("文字無法轉為 UTF-8")
        }
        return encoded
    }

    /// The JSON export as a value — also the round-trip target for decoding.
    static func document(_ bundle: ExportBundle) -> ExportDocument {
        let translation = bundle.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExportDocument(
            title: fallbackTitle(bundle.title),
            startedAt: bundle.transcript.startedAt,
            endedAt: bundle.transcript.endedAt,
            segments: bundle.transcript.segments.map {
                ExportDocument.Segment(
                    index: $0.index,
                    speaker: $0.speaker,
                    start: $0.start,
                    end: $0.end,
                    text: $0.text
                )
            },
            summary: bundle.summaryMarkdown,
            translation: (translation?.isEmpty ?? true) ? nil : bundle.translation
        )
    }

    static func decodeJSON(_ data: Data) throws -> ExportDocument {
        try JSONDecoder().decode(ExportDocument.self, from: data)
    }

    // MARK: Saving

    /// Writes `bundle` into `directory` (or `settings.folder`), creating the
    /// folder if needed and never replacing an existing file.
    ///
    /// Returns the URL actually written, which carries the `-2`/`-3` suffix when
    /// the plain name was taken.
    @discardableResult
    static func save(
        _ bundle: ExportBundle,
        as format: ExportFormat,
        to directory: URL? = nil,
        settings: ExportSettings
    ) throws -> URL {
        guard let folder = directory ?? settings.folderURL else {
            throw ExportError.folderUnavailable
        }

        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw ExportError.writeFailed(
                    path: folder.path,
                    reason: "無法建立資料夾：\(error.localizedDescription)"
                )
            }
        }

        let name = Naming.filename(
            title: bundle.title,
            date: bundle.transcript.startedAt,
            format: format
        )
        let target = availableURL(in: folder, filename: name, fileExtension: format.fileExtension)
        let payload = try data(bundle, as: format)
        do {
            try payload.write(to: target, options: .atomic)
        } catch {
            throw ExportError.writeFailed(path: target.path, reason: error.localizedDescription)
        }
        return target
    }

    /// `name.ext`, then `name-2.ext`, `name-3.ext`, …
    ///
    /// `filename` is a complete name, extension included (`Naming.filename`
    /// decides both halves), so the suffix is inserted before that extension
    /// rather than appended after it.
    static func availableURL(in folder: URL, filename: String, fileExtension: String) -> URL {
        let manager = FileManager.default
        let suffix = ".\(fileExtension)"
        let base = filename.hasSuffix(suffix) ? String(filename.dropLast(suffix.count)) : filename

        var candidate = folder.appendingPathComponent("\(base)\(suffix)")
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(index)\(suffix)")
            index += 1
        }
        return candidate
    }

    // MARK: Markdown

    private static func markdownDocument(_ bundle: ExportBundle) -> String {
        var parts: [String] = []
        parts.append("# \(fallbackTitle(bundle.title))")
        parts.append(dateLine(bundle.transcript))

        let summary = trimBlankEdges(bundle.summaryMarkdown)
        if !summary.isEmpty { parts.append(summary) }

        let transcript = bundle.transcript.labelledText()
        if !transcript.isEmpty {
            parts.append("## 逐字稿\n\n\(transcript)")
        }

        let translation = trimBlankEdges(bundle.translation)
        if !translation.isEmpty {
            parts.append("## 翻譯\n\n\(translation)")
        }

        return finish(parts.joined(separator: "\n\n"))
    }

    // MARK: Plain text

    private static func plainDocument(_ bundle: ExportBundle) -> String {
        var parts: [String] = []
        parts.append(fallbackTitle(bundle.title))
        parts.append(dateLine(bundle.transcript))

        let summary = stripMarkdown(bundle.summaryMarkdown)
        if !summary.isEmpty { parts.append(summary) }

        let transcript = bundle.transcript.labelledText()
        if !transcript.isEmpty {
            parts.append("逐字稿\n\n\(transcript)")
        }

        let translation = stripMarkdown(bundle.translation ?? "")
        if !translation.isEmpty {
            parts.append("翻譯\n\n\(translation)")
        }

        return finish(parts.joined(separator: "\n\n"))
    }

    /// Markdown markers off, words kept.
    ///
    /// Scoped to the summary and the translation — the transcript is speech and
    /// is never rewritten.
    static func stripMarkdown(_ markdown: String) -> String {
        var lines: [String] = []
        var pendingBlank = false

        for rawLine in markdown.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                pendingBlank = !lines.isEmpty
                continue
            }
            // Horizontal rules and table separators carry no words.
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) {
                pendingBlank = !lines.isEmpty
                continue
            }

            while line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Heading level goes, heading text stays.
            while line.hasPrefix("#") {
                line = String(line.dropFirst())
            }
            line = line.trimmingCharacters(in: .whitespaces)
            line = removingListMarker(from: line)
            line = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "~~", with: "")
            line.removeAll { $0 == "#" || $0 == "*" || $0 == "`" }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if pendingBlank {
                lines.append("")
                pendingBlank = false
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    /// "- ", "* ", "+ ", "• ", "1. ", "2) " — the marker only, not the text.
    private static func removingListMarker(from line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ")
            || line.hasPrefix("+ ") || line.hasPrefix("• ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        var digits = 0
        for character in line {
            guard character.isNumber else { break }
            digits += 1
        }
        guard digits > 0 else { return line }

        let rest = line.dropFirst(digits)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if rest.hasPrefix("、") || rest.hasPrefix("．") {
            return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    // MARK: SRT

    private static func srtDocument(_ bundle: ExportBundle) -> String {
        var cues: [String] = []
        // Numbering comes from position, not `segment.index`: indices are not
        // renumbered after an edit, and an SRT needs 1…n with no gaps.
        for (offset, segment) in bundle.transcript.segments.enumerated() {
            let start = max(0, segment.start)
            let end = segment.end > segment.start ? segment.end : start + 0.5
            let text = segment.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            cues.append(
                "\(offset + 1)\n\(timecode(start)) --> \(timecode(end))\n[\(segment.speaker.label)] \(text)"
            )
        }
        guard !cues.isEmpty else { return "" }
        return cues.joined(separator: "\n\n") + "\n"
    }

    /// `HH:MM:SS,mmm`, clamped at zero.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = total % 1000
        let whole = total / 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            whole / 3600,
            (whole / 60) % 60,
            whole % 60,
            milliseconds
        )
    }

    // MARK: Shared text helpers

    private static func dateLine(_ transcript: TranscriptDocument) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var line = formatter.string(from: transcript.startedAt)

        let seconds = Int(transcript.duration.rounded())
        if seconds > 0 {
            line += " · 長度 \(clock(seconds))"
        }
        return line
    }

    private static func clock(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// One line, never empty: a title is a filename component downstream.
    private static func fallbackTitle(_ raw: String) -> String {
        let flattened = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.isEmpty ? "會議紀錄" : flattened
    }

    private static func trimBlankEdges(_ text: String?) -> String {
        guard let text else { return "" }
        return text
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops trailing spaces on every line and leaves exactly one final
    /// newline — editors and `diff` both dislike padded lines.
    private static func finish(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            var trimmed = line
            while let last = trimmed.last, last == " " || last == "\t" {
                trimmed.removeLast()
            }
            lines.append(trimmed)
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Settings

/// Where auto-saved exports go, and in which shape.
///
/// `folder` is kept as a string because that is what the settings field holds:
/// empty means "ask me every time", and a leading `~` is expanded at use time
/// so a moved home directory does not strand the setting.
struct ExportSettings: Codable {
    var folder: String
    var format: ExportFormat
    var autoSave: Bool

    static let defaultsKey = "settings.export"

    init(folder: String = "", format: ExportFormat = .markdown, autoSave: Bool = false) {
        self.folder = folder
        self.format = format
        self.autoSave = autoSave
    }

    private enum CodingKeys: String, CodingKey {
        case folder, format, autoSave
    }

    /// Missing keys fall back to the defaults rather than failing the load, so a
    /// blob written by an older build still yields usable settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        autoSave = try container.decodeIfPresent(Bool.self, forKey: .autoSave) ?? false
        if let stored = try? container.decodeIfPresent(ExportFormat.self, forKey: .format) {
            format = stored
        } else {
            format = .markdown
        }
    }

    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data)
        else { return ExportSettings() }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// `nil` when the user has not chosen a folder — the caller asks.
    var folderURL: URL? {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
