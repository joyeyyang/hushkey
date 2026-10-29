import Foundation

/// Turns a summary into a title and a title into a filename.
///
/// The summary is the model's markdown, so its first line is usually a heading
/// ("## 摘要") rather than a sentence — the title has to be found, not taken.
enum Naming {
    /// 40 characters fits the menu bar, the export heading and a filename
    /// without truncation in Finder's list view.
    static let maxTitleLength = 40
    /// Kept below the usual 255-byte filename limit even when every character
    /// is three bytes of Chinese.
    private static let maxNameLength = 60

    static let fallbackName = "未命名"

    /// First usable sentence of the summary, else the calendar event title,
    /// else a date-based fallback.
    ///
    /// Never empty, never longer than 40 characters.
    /// The calendar event wins. Reading the calendar only pays off if the file is
    /// then called "週五產品會議" rather than the first sentence of a summary
    /// that may describe one slide. The summary line is the fallback for
    /// recordings made outside a meeting, and `fallback` covers the rest -- the
    /// date lives in the stem, so repeating it here would print it twice.
    static func title(summary: String, eventTitle: String?, fallback: String = "逐字稿") -> String {
        if let eventTitle {
            let candidate = cap(cutAtSentenceEnd(cleanInline(eventTitle)))
            if !candidate.isEmpty { return candidate }
        }
        if let line = firstSummaryLine(summary) {
            let candidate = cap(line)
            if !candidate.isEmpty { return candidate }
        }
        return cap(fallback)
    }

    /// Filesystem-safe: drops `/ : \ ? * | " < >` and control characters,
    /// collapses whitespace, trims leading dots, caps length.
    ///
    /// Never returns "".
    static func sanitize(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)

        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", ":", "\\", "?", "*", "|", "\"", "<", ">":
                continue
            case "\n", "\r", "\t", "\u{0B}", "\u{0C}":
                output.append(" ")
            default:
                if CharacterSet.controlCharacters.contains(scalar) { continue }
                output.unicodeScalars.append(scalar)
            }
        }

        var text = output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        // A leading dot hides the file; a trailing one makes Finder complain.
        while text.hasPrefix(".") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        while let last = text.last, last == "." || last == " " {
            text.removeLast()
        }

        if text.count > maxNameLength {
            text = String(text.prefix(maxNameLength))
            while let last = text.last, last == "." || last == " " {
                text.removeLast()
            }
        }

        return text.isEmpty ? fallbackName : text
    }

    /// "2026-10-20 1430 週五產品會議" — one stem per session, shared by every
    /// file that session produces. The auto-saved meeting note and a later export
    /// must agree, or the same meeting lands in the folder twice under two names.
    static func stem(title: String, date: Date) -> String {
        "\(stampFormatter.string(from: date)) \(sanitize(title))"
    }

    /// "2026-10-20 1430 <title>.<ext>"
    static func filename(title: String, date: Date, format: ExportFormat) -> String {
        "\(stem(title: title, date: date)).\(format.fileExtension)"
    }

    // MARK: Summary → sentence

    /// The first line that carries prose: not a heading, not a bullet, not a
    /// rule, and long enough to mean something.
    private static func firstSummaryLine(_ summary: String) -> String? {
        for rawLine in summary.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !isDecoration(line) else { continue }

            line = cleanInline(line)
            line = cutAtSentenceEnd(line)
            guard line.count >= 4 else { continue }
            return line
        }
        return nil
    }

    private static func isDecoration(_ line: String) -> Bool {
        if line.hasPrefix("#") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        if line.hasPrefix("•") || line.hasPrefix("· ") { return true }
        if line.hasPrefix(">") { return true }
        if line.hasPrefix("|") { return true }
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }

        // Ordered bullet: "1. ", "2) ", "3、".
        var digits = 0
        for character in line {
            guard character.isNumber else { break }
            digits += 1
        }
        if digits > 0 {
            let rest = line.dropFirst(digits)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest.hasPrefix("、") {
                return true
            }
        }

        // Rules such as "---" or "***".
        if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
            return true
        }
        return false
    }

    /// Strips the inline marks that would otherwise leak into a filename.
    private static func cleanInline(_ text: String) -> String {
        var line = text
        if line.hasPrefix("- ") || line.hasPrefix("* ")
            || line.hasPrefix("+ ") || line.hasPrefix("• ") {
            line = String(line.dropFirst(2))
        }
        line = line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
        line.removeAll { $0 == "#" || $0 == "*" || $0 == "`" }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One sentence, not a paragraph.
    private static func cutAtSentenceEnd(_ text: String) -> String {
        let stops: Set<Character> = ["。", "！", "？", "!", "?", "\n", "\r"]
        var out = ""
        for character in text {
            if stops.contains(character) { break }
            out.append(character)
        }
        // A full-width period is often left behind after the cut above; a
        // trailing comma reads as a truncation too.
        return out
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,、；;：:—"))
    }

    /// Hard limit, preferring a word boundary so an English title does not end
    /// mid-word.
    private static func cap(_ text: String, limit: Int = maxTitleLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        var head = String(trimmed.prefix(limit))
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) >= limit / 2 {
            head = String(head[head.startIndex..<space])
        }
        return head
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,、；;：:—"))
    }

    // MARK: Formatters

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()
}
