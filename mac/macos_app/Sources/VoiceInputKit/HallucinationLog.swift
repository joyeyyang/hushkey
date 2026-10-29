import Foundation

/// Every model answer the guardrail refused, kept in `Documents/hallucination_log.json`.
///
/// The gate in `rust/core_engine/src/guardrail.rs` is arithmetic, so it can say
/// exactly why an answer was thrown away but not what the model was trying to
/// do. That needs the text, and the text is the only place the next prompt fix
/// can come from: every rule in the guard started as a rejected sample.
///
/// The iOS twin lives in `RefineChain.swift` (same format, same file name in
/// the app's Documents directory) so one reader can compare the two platforms.
///
/// The file is capped and rewritten as a whole. Rejections are rare -- they are
/// the exception the guard exists for -- so an append-only log would grow
/// without ever being read; 200 entries is enough to see a pattern and small
/// enough that reading it costs nothing. Failure to write is swallowed on
/// purpose: this is diagnostics, and a dictation must not fail because a log
/// file could not be opened.
public enum HallucinationLog {

    public struct Entry: Codable {
        public let timestamp: String
        public let mode: String
        public let tone: String
        public let reason: String
        public let raw: String
        public let refined: String
    }

    /// Serial, so two rejections on different threads cannot lose one another's
    /// entry to a read-modify-write race.
    private static let queue = DispatchQueue(label: "ovc.hallucination-log")

    private static let limit = 200

    /// `~/Documents/hallucination_log.json`. The app is not sandboxed, so this
    /// is the user's real Documents folder; the iOS file sits in the app
    /// container's Documents under the same name.
    ///
    /// `OVC_HALLUCINATION_LOG` overrides the path for tests and for
    /// `scripts/verify.sh`, which must not write into the user's Documents.
    public static var fileURL: URL? {
        if let override = ProcessInfo.processInfo.environment["OVC_HALLUCINATION_LOG"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("hallucination_log.json")
    }

    /// - Parameter mode: "refine" or "edit", the same word `LLM_CheckOutput`
    ///   took, so a log line can be replayed against the guard.
    /// - Parameter raw: what the model saw (the transcript, or the draft).
    /// - Parameter refined: what it answered, before the caller's fallback.
    /// - Parameter reason: the guard's own reason string, verbatim.
    public static func record(mode: String, tone: String, raw: String,
                              refined: String, reason: String) {
        queue.async {
            guard let url = fileURL else { return }
            var entries = read(url)
            entries.append(Entry(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                mode: mode,
                tone: tone,
                reason: reason,
                raw: raw,
                refined: refined
            ))
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(entries) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Blocks until every queued entry has been written. Exists for tests and
    /// for a clean shutdown; the record path itself stays asynchronous so a
    /// rejection never blocks the thread that already waited for the model.
    public static func flush() {
        queue.sync {}
    }

    /// The entries on disk, newest last. Exposed for diagnostics and tests; an
    /// unreadable or half-written file is treated as empty.
    public static func entries() -> [Entry] {
        guard let url = fileURL else { return [] }
        return read(url)
    }

    private static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
