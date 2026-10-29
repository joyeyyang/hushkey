import Foundation
import UIKit

/// 會議紀錄: 摘要／決議／待辦 for a block of transcript.
///
/// The structure is the core's, not this file's. `LLM_Summarize` runs each section
/// as its own call (`SECTION_SUMMARY`, `SECTION_DECISIONS`, `SECTION_ACTIONS`), so
/// the layout does not depend on a 2B model following a format, and a long
/// transcript is reduced by map-reduce first. What is left for this side is the
/// input: which sentences, in what order.
///
/// **What is missing on a phone is the recording, not the summary.** The Mac's
/// meeting mode captures system audio as well as the microphone, which is what puts
/// 我：/對方： in front of the sentences — iOS cannot read another app's audio
/// without a ReplayKit broadcast extension, and there is none in this build. So a
/// phone's 會議紀錄 is a summary of transcripts that exist here already, and the
/// speaker split is not offered rather than faked.
enum MeetingMinutes {

    enum Failure: LocalizedError {
        case empty
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "這裡還沒有可以整理的句子。"
            case .engine(let detail): return detail
            }
        }
    }

    /// The transcript the model reads: oldest first, one sentence per line.
    ///
    /// Oldest first because a summary of a meeting has to read in the order it
    /// happened — a list of decisions is not order-free, and "which came first" is
    /// usually the last thing needed to tell them apart.
    static func transcript(_ entries: [HistoryEntry]) -> String {
        entries.reversed().map(\.text).joined(separator: "\n")
    }

    /// Blocking, and deliberately not cancellable: the core has no cancellation
    /// point inside a generation, so a 取消 button would either lie or leave the
    /// model running. Call from a background queue.
    static func minutes(of entries: [HistoryEntry]) throws -> String {
        let text = transcript(entries)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.empty
        }
        do {
            return try Core.summarize(text)
        } catch {
            throw Failure.engine(error.localizedDescription)
        }
    }
}

/// `-OVC_MINUTES_PROBE`: the summary pass over the history on this device.
///
/// The interesting question is not "does the model answer" — `RefineProbe`
/// answers that — but whether three sections over a real, unordered block of
/// dictations come out as a meeting record at all, and how long a phone takes.
/// Written to `Documents/meeting-minutes.md` and to stdout, which is what
/// `devicectl … --console` captures: `simctl launch --console` does not deliver
/// stdout on the simulator this was checked on.
enum MeetingMinutesProbe {
    static func run() {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "requestedModel": LLMPolicy.requestedName,
            ]
            let entries = History.all()
            // Newest first is the stored order; `MeetingMinutes.transcript` puts
            // them back in time order, which is the whole point of the probe.
            out["entries"] = entries.count
            out["transcript"] = MeetingMinutes.transcript(entries)

            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                let started = Date()
                let minutes = try MeetingMinutes.minutes(of: entries)
                out["seconds"] = Date().timeIntervalSince(started)
                out["minutes"] = minutes
                out["servedModel"] = Core.lastModelName()
                let path = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                )[0].appendingPathComponent("meeting-minutes.md")
                try? minutes.write(to: path, atomically: true, encoding: .utf8)
                out["path"] = path.path
            } catch {
                out["error"] = error.localizedDescription
            }

            let json = (try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            print("OVC_MINUTES_BEGIN")
            print(String(data: json, encoding: .utf8) ?? "{}")
            print("OVC_MINUTES_END")
            Diagnostics.log.notice("minutes probe done: \(out["seconds"].map { "\($0)s" } ?? "no result", privacy: .public)")
        }
    }
}
