import Foundation

/// Every finished sentence, kept so it can be found again.
///
/// The Mac has a 歷史 tab and it is not decoration: dictation lands in whatever
/// field had focus, and the field is gone the moment the user switches apps. On a
/// phone that is worse, not better -- the keyboard types into a chat box the user
/// may have already sent, or the app may be killed before they read it. Without a
/// copy the sentence is simply lost, which is the one failure a voice input tool
/// must not have.
///
/// Stored as one JSON file in the App Group container rather than in defaults: it
/// grows with use, and a defaults blob that size is read on every keyboard refresh.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    /// How the sentence arrived ("已整理 · 靜音", "已辨識", "整理被退回").
    let detail: String
    /// The model that actually answered — `LLMPolicy`'s lesson: "which model ran"
    /// is a fact worth keeping next to the text it produced.
    let model: String
    /// Wall-clock seconds from the first microphone buffer to the published text.
    let seconds: Double

    var day: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

enum History {

    /// A cap, not a policy. Old enough to be unread is old enough to drop, and an
    /// unbounded file eventually costs the keyboard a slow first read.
    private static let limit = 500

    private static var file: URL {
        SharedStore.container.appendingPathComponent("history.json")
    }

    private static var cache: [HistoryEntry]?

    /// Newest first.
    static func all() -> [HistoryEntry] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else {
            cache = []
            return []
        }
        cache = list
        return list
    }

    static func matching(_ query: String) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all() }
        return all().filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    static func add(
        text: String,
        detail: String,
        model: String = "",
        seconds: Double = 0
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = all()
        // The same sentence twice *within seconds* is the same dictation published
        // twice -- a recovery that ran after the text had already been handed over.
        // Five seconds, not a minute: saying "好" twice in a row is something people
        // do, and a window that eats it is worse than a duplicate. The pipeline
        // already prevents a double publish per dictation (`publishedGeneration`),
        // so this is the second line of defence, not the first.
        if let first = list.first, first.text == trimmed,
           abs(first.date.timeIntervalSinceNow) < 5 {
            return
        }
        list.insert(
            HistoryEntry(id: UUID(), text: trimmed, date: Date(),
                         detail: detail, model: model, seconds: seconds),
            at: 0
        )
        if list.count > limit { list = Array(list.prefix(limit)) }
        write(list)
    }

    static func delete(_ id: UUID) {
        write(all().filter { $0.id != id })
    }

    static func clear() {
        write([])
    }

    private static func write(_ list: [HistoryEntry]) {
        cache = list
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: file, options: .atomic)
        } catch {
            Diagnostics.log.error("history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One export document, in the format the Mac offers first.
    static func markdown(_ entries: [HistoryEntry] = all()) -> String {
        var out = "# 逐字稿\n\n"
        for entry in entries.reversed() {
            out += "## \(entry.day)\n\n\(entry.text)\n\n"
        }
        return out
    }

    static func plainText(_ entries: [HistoryEntry] = all()) -> String {
        entries.reversed().map(\.text).joined(separator: "\n\n")
    }

    /// SubRip (`.srt`), one cue per dictation.
    ///
    /// The Mac's SRT comes out of a meeting, where every segment carries the start
    /// and end the recorder measured. iOS has no meeting mode yet, and the one
    /// interval it does know is the dictation itself: `HistoryEntry.seconds` is the
    /// wall-clock time from the first microphone buffer to the published text, so a
    /// cue runs from the moment the sentence started to the moment it was
    /// finished. That is the whole truth a phone has here, and it is enough for the
    /// file to line up with the audio it came from.
    ///
    /// `0` seconds is not zero length: it is "nobody measured", which is what an
    /// entry written before the duration was recorded, or an export of one pasted
    /// string, looks like. Those get the Mac's half-second floor -- a cue the eye
    /// can see, rather than a start and an end that are the same instant.
    static func srt(_ entries: [HistoryEntry] = all()) -> String {
        // Oldest first: subtitles are read in time order, and so is a video
        // player, whichever way this list happens to be stored.
        var spans: [(start: Date, end: Date, text: String)] = []
        for entry in entries.reversed() {
            var start = entry.date
            var end = entry.date.addingTimeInterval(0.5)
            if entry.seconds > 0 {
                start = entry.date.addingTimeInterval(-entry.seconds)
                end = entry.date
            }
            // An SRT cue is one line: a newline inside it ends the cue, and the
            // rest of the sentence is then read as a malformed index.
            let text = entry.text
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            spans.append((start, end, text))
        }
        // An SRT counts from the start of the media, not from the epoch -- so the
        // first sentence is 00:00:00,000 and the rest follow it. The origin is the
        // earliest cue rather than the first entry's `date`, which is a *finish*
        // time: using it would put the opening sentence at a negative timecode.
        guard let origin = spans.map(\.start).min() else { return "" }
        let cues = spans.enumerated().map { offset, span in
            // Numbered by position, never by anything stored: 1…n with no gaps is
            // what the format requires.
            let start = timecode(span.start.timeIntervalSince(origin))
            let end = timecode(span.end.timeIntervalSince(origin))
            return "\(offset + 1)\n\(start) --> \(end)\n\(span.text)"
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    /// `HH:MM:SS,mmm`, clamped at zero. Same shape as the Mac's `timecode`. The
    /// comma is the format, not a locale.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = total % 1000
        let whole = total / 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            whole / 3600, (whole / 60) % 60, whole % 60, milliseconds
        )
    }

    static func json(_ entries: [HistoryEntry] = all()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}
