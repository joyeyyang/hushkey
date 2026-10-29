import Foundation

/// Which part of a draft a 修改的提示詞 is about.
///
/// The twin of the iOS app's `PromptEditRegion`, and it exists for the same
/// reason: the region is not decoration. Each case reaches the core differently.
///
/// * `whole` — the whole draft. `locate_edit_target` finds no position in the
///   instruction, so the whole-draft prompt runs. The path for a transformation
///   ("改短一點").
/// * `line(n)` — one numbered line. The number is written into the instruction
///   the way a person says it ("第2點…"), which is exactly what the core's
///   `locate_by_position` reads, so the line the user picked is the line the
///   core resolves.
/// * `selection` — the selected text. The core is handed that slice as the
///   whole draft and the answer is spliced back, so the rest cannot be rewritten
///   by a model that felt like it.
public enum PromptEditRegion: Equatable {
    case whole
    case line(Int)
    case selection

    public var title: String {
        switch self {
        case .whole: return "整段"
        case .line(let n): return "第 \(n) 行"
        case .selection: return "選取範圍"
        }
    }

    /// The instruction the core receives.
    ///
    /// Only the line case is rewritten, and only by PREPENDING a position. The
    /// user's own words are the 修改的提示詞 and are left byte-identical: this
    /// function decides WHERE, never WHAT.
    public func instruction(_ typed: String) -> String {
        let spoken = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .line(let number) = self else { return spoken }
        // Arabic digits followed by 點: the core's digit branch accepts that,
        // and its Chinese-numeral branch is left to the spoken form.
        return "第\(max(1, number))點\(spoken)"
    }

    /// The lines a picker can offer, in the order the core numbers them.
    ///
    /// Same rules as the core's `numbered_items`: non-empty lines, trimmed, with
    /// a leading bullet or an existing "1." stripped. The preview and the edit
    /// therefore cannot disagree about which line is line 3.
    public static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                var body = line
                for bullet in ["• ", "- ", "・"] where body.hasPrefix(bullet) {
                    body = String(body.dropFirst(bullet.count))
                }
                if let dot = body.firstIndex(where: { $0 == "." || $0 == "、" || $0 == ")" }) {
                    let head = body[body.startIndex..<dot]
                    if !head.isEmpty, head.allSatisfy({ $0.isNumber }) {
                        body = String(body[body.index(after: dot)...])
                    }
                }
                return body.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    /// `--region` on the command line: "whole", "line:3", "selection".
    public static func parse(_ text: String) -> PromptEditRegion? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "whole" { return .whole }
        if trimmed == "selection" { return .selection }
        if trimmed.hasPrefix("line:"), let n = Int(trimmed.dropFirst(5)), n >= 1 {
            return .line(n)
        }
        return nil
    }
}
