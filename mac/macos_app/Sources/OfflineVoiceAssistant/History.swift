import Foundation

/// One finished dictation: what was said, what came out, and when.
struct HistoryEntry: Codable {
    var id: UUID = UUID()
    var date: Date
    /// What actually got pasted.
    var polished: String
    /// The raw transcript, kept so the original wording is never lost.
    var raw: String
    /// "dictation" or "meeting".
    var kind: String = "dictation"

    /// Single-line form for the list.
    var preview: String {
        polished
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Local history of everything dictated, kept as JSON beside the log.
///
/// Deliberately a plain file rather than Core Data: the list is small, it is
/// easy to inspect and back up, and a corrupt file degrades to an empty history
/// instead of a crash.
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let url: URL

    /// Newest first, capped so the file cannot grow without bound.
    private static let limit = 500

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        load()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("OfflineVoiceAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        // A file written by an older shape simply yields an empty history.
        guard let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func add(_ entry: HistoryEntry) {
        // Ignore empty results rather than storing blank rows.
        guard !entry.polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    /// Newest first, filtered by a case-insensitive substring of the text.
    func search(_ query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.polished.localizedCaseInsensitiveContains(q) }
    }
}
