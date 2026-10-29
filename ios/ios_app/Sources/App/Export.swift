import SwiftUI
import UIKit

/// Writing a transcript out, in the formats the Mac offers.
///
/// The Mac's export is a folder plus a file per session, because a Mac records
/// meetings into documents. On a phone the useful verb is "hand this to another
/// app" — Files, Mail, a chat — so the same three renderings are written to one
/// temporary file and put behind the system share sheet. Same content, different
/// last step, and the formats are deliberately identical so an export from either
/// device opens the same way.
enum Export {

    enum Format: String, CaseIterable, Identifiable {
        case markdown
        case txt
        case json
        /// Subtitles. Not a differently shaped document: an SRT of the same
        /// sentences, each cue carrying the dictation it came from.
        case srt

        var id: String { rawValue }

        var title: String {
            switch self {
            case .markdown: return "Markdown"
            case .txt: return "純文字"
            case .json: return "JSON"
            case .srt: return "SRT 字幕"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .txt: return "txt"
            case .json: return "json"
            case .srt: return "srt"
            }
        }
    }

    /// Writes `entries` to a fresh file in `tmp` and returns it.
    ///
    /// A fresh name every time: the share sheet caches by URL, and handing it the
    /// same path twice made a second export show the first one's contents.
    static func file(_ format: Format, entries: [HistoryEntry]) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("逐字稿-\(stamp).\(format.fileExtension)")
        let text: String
        switch format {
        case .markdown: text = History.markdown(entries)
        case .txt: text = History.plainText(entries)
        case .json: text = History.json(entries)
        case .srt: text = History.srt(entries)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Diagnostics.log.error("export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func file(_ format: Format, text: String) -> URL? {
        file(format, entries: [HistoryEntry(id: UUID(), text: text, date: Date(),
                                            detail: "", model: "", seconds: 0)])
    }
}

/// The system share sheet. SwiftUI's `ShareLink` needs its item at build time;
/// the export is written on demand, so the sheet is presented with a URL instead.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
