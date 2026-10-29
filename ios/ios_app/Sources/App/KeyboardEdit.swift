import Foundation

/// The app's half of the keyboard's 修改的提示詞 panel.
///
/// The keyboard cannot run the model -- an app extension gets tens of megabytes
/// before the system kills it -- so the panel writes a request into the App
/// Group and this answers it. What the answer contains is the core's
/// `LLM_EditText` result, run through the same guardrail the app's own panel
/// uses (`TextRules.sanityCheck(mode: "edit")`): a model that answers with a
/// remark, or with three times the draft, is refused here rather than typed
/// into somebody's document.
///
/// One request at a time, on one serial queue. Two edits interleaved would be
/// two model loads on a phone that can barely afford one, and the keyboard only
/// ever waits on a single sequence.
enum KeyboardEdit {

    /// Foreground work: the bound is "the model never answered", not the ~30
    /// seconds iOS gives a backgrounded app.
    private static let work = DispatchQueue(label: "ovc.keyboard-edit", qos: .userInitiated)

    /// Called from the three channels that can carry the request: the Darwin
    /// notification (Mode 2, app kept alive), the `ovc://edit` URL (app was not
    /// running), and becoming active (iOS refused the open while it was).
    ///
    /// - Parameter freshOnly: true for the channels that are not evidence of a
    ///   new tap -- a launch, coming back to the app. Those honour a request
    ///   only while it is recent, so a request the app never got to does not
    ///   fire an edit days later.
    static func handlePending(channel: String, freshOnly: Bool = false) {
        guard let request = SharedStore.pendingEditRequest else { return }
        if freshOnly, !SharedStore.hasFreshEditRequest() { return }
        // Consumed before the model is called: a second channel delivering the
        // same request must not run a second generation.
        SharedStore.consumeEditRequest(request.seq)
        // Acknowledged before the model is called too. This is the difference
        // between "the app is not running" (the keyboard says so and offers to
        // open it) and "the app is thinking for twenty seconds" (the keyboard
        // waits).
        SharedStore.ackEditRequest(request.seq)
        Diagnostics.log.notice(
            "edit request via \(channel, privacy: .public): \(request.draft.count) chars, instruction \(request.instruction.count) chars"
        )
        work.async { run(request) }
    }

    private static func run(_ request: SharedStore.EditRequest) {
        guard SharedStore.hasModels else {
            SharedStore.publishEditResult(
                seq: request.seq, text: nil,
                error: "App 裡還沒有可用的模型。"
            )
            return
        }
        // The region decides what the core is handed. "line" prepends the
        // position the core resolves ("第3點…") and leaves the user's words
        // untouched; "selection" hands the selected slice over as if it were the
        // whole draft, so the rest of the text cannot be rewritten; anything
        // else is the whole draft.
        let region = request.region ?? "whole"
        var target = request.draft
        var instruction = request.instruction
        var slice: Range<String.Index>?
        switch region {
        case "line":
            instruction = "第\(max(1, request.line ?? 0))點" + instruction
        case "selection":
            let selected = (request.selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty, let found = target.range(of: selected) else {
                SharedStore.publishEditResult(
                    seq: request.seq, text: nil,
                    error: "選取範圍不在剛才插入的文字裡，原文沒有變動。"
                )
                return
            }
            slice = found
            target = selected
        default:
            break
        }
        do {
            // Idempotent in `Core`, and required before any `LLM_*` call: it is
            // what points the engine at the model tree.
            try Core.initialize(models: SharedStore.modelsRoot)
            let edited = TextScript.traditional(
                try Core.edit(target, instruction: instruction)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !edited.isEmpty else {
                SharedStore.publishEditResult(
                    seq: request.seq, text: nil, error: "AI 這次沒有回覆。原文沒有變動。"
                )
                return
            }
            guard edited != target else {
                // The core refuses an answer that changed nothing, so this is a
                // model that repeated the draft -- measured as the common
                // outcome for a vague instruction.
                SharedStore.publishEditResult(
                    seq: request.seq, text: nil,
                    error: "AI 這次沒有改到任何字。把要改的地方說清楚一點，再試一次。"
                )
                return
            }
            let verdict = TextRules.sanityCheck(edited, comparedTo: target, mode: "edit")
            guard verdict.ok else {
                Diagnostics.log.error("keyboard edit rejected: \(verdict.reason, privacy: .public)")
                HallucinationLog.record(
                    mode: "edit", tone: SharedStore.refineTone,
                    raw: target, refined: edited, reason: verdict.reason
                )
                SharedStore.publishEditResult(
                    seq: request.seq, text: nil,
                    error: "AI 這次的回覆不像修改後的文字，原文沒有變動。"
                )
                return
            }
            // The slice goes back where it came from; the whole-draft path has
            // no slice and returns the answer as it stands.
            let result = slice.map { request.draft.replacingCharacters(in: $0, with: edited) } ?? edited
            SharedStore.publishEditResult(seq: request.seq, text: result, error: nil)
        } catch {
            Diagnostics.log.error("keyboard edit failed: \(error.localizedDescription, privacy: .public)")
            SharedStore.publishEditResult(
                seq: request.seq, text: nil, error: "修改失敗：\(error.localizedDescription)"
            )
        }
    }
}
