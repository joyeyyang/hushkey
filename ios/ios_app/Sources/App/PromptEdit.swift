import Foundation

/// Which part of the sentence a 修改提示詞 is about.
///
/// The three shapes the user asked for, and they are not decoration: each one
/// reaches the core differently, and the core does different work for each.
///
/// * `whole` — the whole sentence. The core's `locate_edit_target` finds no
///   position in the instruction, so the whole-draft prompt runs. This is the
///   path for a transformation ("改短一點").
/// * `line(n)` — one numbered line. The UI writes the line number into the
///   instruction the way a person says it ("第2點…"), because that is exactly
///   what the core's `locate_by_position` reads. The number the user picked is
///   therefore the number the core resolves; it is not a hint.
/// * `selection` — the text the user selected in the transcript. The core is
///   handed that slice as the whole text and the result is spliced back, so the
///   untouched parts cannot be rewritten by a model that felt like it.
enum PromptEditRegion: Equatable {
    case whole
    case line(Int)
    case selection

    var title: String {
        switch self {
        case .whole: return "整段"
        case .line(let n): return "第 \(n) 行"
        case .selection: return "選取範圍"
        }
    }
}

/// Turns the user's 修改提示詞 plus a region into the instruction the core
/// reads, and applies the answer.
///
/// The 修改的提示詞 is never concatenated into the text being edited: the core's
/// `edit_prompt` puts the instruction on the FIRST line, a blank line after it,
/// and the numbered draft below — and `EDIT_SYSTEM` says so. Mixing the two
/// here would give the model a draft that begins with an instruction, which is
/// the failure this whole split exists to avoid.
enum PromptEdit {

    /// The instruction string handed to `LLM_EditText`.
    ///
    /// Only the line region is rewritten, and only by PREPENDING a position. The
    /// user's own words are left byte-identical: they are the 修改的提示詞, and
    /// paraphrasing them here would make the button do something other than what
    /// was typed.
    static func instruction(_ typed: String, region: PromptEditRegion) -> String {
        let spoken = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .line(let number) = region else { return spoken }
        // Arabic digits, then 點: the core's `chinese_position` reads Chinese
        // numerals, and its digit branch accepts a digit followed by 點. Both
        // reach the same line, and "第2點" is what the picker shows.
        return "第\(max(1, number))點\(spoken)"
    }

    /// Applies one 修改提示詞 to `text`.
    ///
    /// - Parameter selection: the transcript's selected range, needed only for
    ///   `.selection`. Empty or missing is an error rather than a silent
    ///   fallback to the whole text: "只改我選的那段" must never rewrite the
    ///   rest.
    static func apply(to text: String,
                      instruction typed: String,
                      region: PromptEditRegion,
                      selection: Range<String.Index>?) throws -> String {
        let spoken = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw PromptEditError.emptyInstruction }
        switch region {
        case .whole, .line:
            return try Core.edit(text, instruction: instruction(spoken, region: region))
        case .selection:
            guard let selection, !selection.isEmpty else {
                throw PromptEditError.noSelection
            }
            let slice = String(text[selection])
            guard !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PromptEditError.noSelection
            }
            // The slice is the whole text as far as the core is concerned, so a
            // model that answers with more than the slice edited is refused by
            // the core's own shape checks instead of leaking into the rest.
            let edited = try Core.edit(slice, instruction: spoken)
            return text.replacingCharacters(in: selection, with: edited)
        }
    }

    /// The lines the line picker can offer, in the same order the core numbers
    /// them: non-empty lines, trimmed, with any bullet or existing number
    /// stripped the way `numbered_items` strips them.
    ///
    /// The app's own numbering is only for showing the user WHICH line is line
    /// 3. The core numbers the draft itself, and it does so the same way, so the
    /// preview and the edit cannot disagree about what "第 3 行" is.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                var body = line
                for bullet in ["• ", "- ", "・"] where body.hasPrefix(bullet) {
                    body = String(body.dropFirst(bullet.count))
                }
                // "1. 先確認規格" and "3、排時程" are already numbered; the core
                // strips that number before numbering again, and so does the
                // preview.
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
}

enum PromptEditError: LocalizedError {
    case emptyInstruction
    case noSelection

    var errorDescription: String? {
        switch self {
        case .emptyInstruction: return "先輸入修改的提示詞。"
        case .noSelection: return "先在文字上選取要改的那一段。"
        }
    }
}

/// Runs one 修改提示詞 off the main thread, with a deadline.
///
/// The deadline is the same lesson the recorder button taught: a busy flag that
/// only the model can clear is a button that can stay disabled for the life of
/// the process. `Core.edit` is one blocking call into llama.cpp and cannot be
/// interrupted, so the flag is cleared here and the abandoned answer is
/// discarded by `generation`. The work queue stays busy until the call returns,
/// which is logged rather than hidden.
@MainActor
final class PromptEditRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?

    /// Foreground work, so the bound is about "the model never answered", not
    /// about the ~30 seconds iOS gives a backgrounded app. The first pass after
    /// an install pays a ~18-second Metal compile on top of the generation.
    private static let limit: TimeInterval = 120

    private let work = DispatchQueue(label: "ovc.prompt-edit", qos: .userInitiated)
    private var deadline: DispatchWorkItem?
    private var generation = 0

    /// A message the panel raises before the core is called at all (an empty
    /// instruction). One channel for every failure, so the panel reads one
    /// property rather than guessing which of two is current.
    func reject(_ message: String) {
        guard !running else { return }
        notice = nil
        error = message
    }

    /// - Parameter completion: the edited text, on the main thread. Never called
    ///   after the deadline has already reported a failure.
    func run(text: String,
             instruction typed: String,
             region: PromptEditRegion,
             selection: Range<String.Index>?,
             completion: @escaping (String) -> Void) {
        guard !running else { return }
        error = nil
        notice = nil
        let g = generation + 1
        generation = g
        running = true

        let bound = DispatchWorkItem { [weak self] in
            guard let self, self.generation == g, self.running else { return }
            Diagnostics.log.error("prompt edit overran its deadline")
            self.running = false
            self.error = "模型沒有回應（超過 \(Int(Self.limit)) 秒）。文字沒有變動。"
            self.notice = "那次修改還占著模型，下一次可能會慢一點。"
        }
        deadline = bound
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit, execute: bound)

        work.async {
            let result = Result {
                try PromptEdit.apply(to: text, instruction: typed, region: region, selection: selection)
            }
            DispatchQueue.main.async {
                guard self.generation == g else { return }
                self.deadline?.cancel()
                self.deadline = nil
                self.running = false
                switch result {
                case .success(let edited):
                    guard edited != text else {
                        // Not a success: the core refuses an answer that changed
                        // nothing, so this is a model that repeated the draft.
                        // Measured: a transformation ("改短一點") on 整段 is the
                        // case that comes back unchanged -- the core's whole-draft
                        // path is the fallback, and a 2B model mostly echoes there.
                        // Naming a line routes the same instruction to the
                        // per-line rewrite, which is the path that works.
                        self.error = "AI 這次沒有改到任何字。把要改的地方指成「第 N 行」或選取起來，再試一次。"
                        return
                    }
                    completion(edited)
                case .failure(let failure):
                    self.error = (failure as? LocalizedError)?.errorDescription
                        ?? failure.localizedDescription
                }
            }
        }
    }
}
