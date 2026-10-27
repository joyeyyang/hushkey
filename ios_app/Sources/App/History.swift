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
        // The same sentence twice in a row is the same dictation replayed (a
        // recovery, a re-run): keeping both makes 全部清空 the only way to tidy up.
        if let first = list.first, first.text == trimmed,
           abs(first.date.timeIntervalSinceNow) < 60 {
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
