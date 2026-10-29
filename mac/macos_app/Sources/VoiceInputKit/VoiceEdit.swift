import Foundation

// The spoken-edit feature: the user says what to change about text that is
// already on screen, and the line is applied instead of pasted.
//
// Two halves, deliberately apart. `isVoiceEditInstruction` is a pure predicate
// over the recognised line and decides whether to *try* an edit at all;
// `applyVoiceEdit` is the model call that performs one. Keeping the decision
// free of the model is what makes it reviewable — the cost of getting it wrong
// is written down on the predicate itself.

/// Whether a recognised line is an instruction to EDIT something rather than
/// text to paste.
///
/// The gate requires BOTH an edit verb and a reference to the thing being
/// edited, and that conjunction is the entire safety property. A false positive
/// is expensive: the user's words would be applied as an edit to whatever came
/// before instead of being inserted where they are speaking. A false negative
/// costs almost nothing, because the refine prompt already applies a spoken
/// instruction it finds inside a draft. So this errs towards missing.
///
/// Samples this was built against. The CLI's `--is-edit` prints the verdict for
/// a line, and the test target (`VoiceEditInstructionTests`) holds the same
/// samples, so they can be re-checked without a run:
///
///   accepted: 把第二點改成禮拜五下午兩點
///             第三句刪掉
///             delete the second one
///             把最後一句改短一點
///             把地點改成三樓會議室
///             把小林改成大衛
///             把三點改成四點
///             第二句改短一點
///   rejected: 顏色改成藍色
///             我把檔案刪掉了
///             這個會議改成線上開
///             我用英文寫了一封信
///             第一點要改善
///             最後一段需要修改
///
/// Of the rejections, 顏色改成藍色 and 我把檔案刪掉了 each carry a verb but name no
/// target at all. 這個會議改成線上開 names a thing, but with 這個 rather than one of
/// the edit targets: a whole sentence's subject is not the line under discussion.
/// 我用英文寫了一封信 has neither half. The predicate is a pure function of its
/// argument on purpose — it is the one piece of this feature that can be argued
/// about instead of run.
///
/// The content form (把地點改成…) has to be accepted, because the core resolves
/// it and the app would otherwise never ask: the core looks the word up in the
/// draft, and the app's gate cannot see the draft, so the gate has to be the
/// stricter of the two. It requires the imperative frame at the FRONT of the
/// line, which is what separates 把地點改成三樓會議室 (an order) from 我把檔案刪掉了
/// (a report of something already done) and from 顏色改成藍色 (a fact about a
/// colour).
public func isVoiceEditInstruction(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return containsEditVerb(trimmed) && containsEditTarget(trimmed)
}

/// The verb half. Latin verbs match whole words only, so "change" does not fire
/// inside "exchange". The Chinese list is substring matching, which is what
/// Chinese allows — there are no token boundaries to anchor to — and it includes
/// bare 改 as a stem so 改短／改一下 all count; a bare stem is safe here precisely
/// because the verb alone is never enough.
private func containsEditVerb(_ text: String) -> Bool {
    let chinese = ["改成", "改為", "換成", "刪掉", "刪除", "拿掉", "去掉", "移除",
                   "縮短", "精簡", "重寫", "變成", "移到", "調順序", "加一句", "補一句",
                   // The verb can carry what it does to the target: "改短" (make it
                   // shorter), "改長", "改小", "改大", "改多", "改少". These are
                   // verbs of their own, not the bare 改, so they need no
                   // imperative frame to be recognised -- "第二句改短一點" says
                   // what it wants without saying 把.
                   "改短", "改長", "改小", "改大", "改多", "改少", "改簡", "改複"]
    if chinese.contains(where: { text.contains($0) }) { return true }
    // The bare stem 改 only counts inside an imperative frame. On its own it is a
    // substring of 改善／修改／改天, so "第一點要改善" -- an ordinary sentence about
    // text, complete with a pointer at 第一點 -- read as an instruction and the
    // whole dictation was swallowed by the edit path instead of being inserted.
    // With 把／請／幫 in front of it, "把第二點改短" is unambiguous.
    if text.contains("改") && ["把", "請", "幫", "將", "給我"].contains(where: { text.contains($0) }) {
        return true
    }

    let latin = ["change", "replace", "delete", "remove", "shorten", "rewrite", "make it"]
    let lower = text.lowercased()
    return latin.contains { containsWord(lower, $0) }
}

/// The target half: a pointer at the line the instruction is about.
///
/// The core resolves the target in one of two ways, and this gate has to
/// recognise the same two, or it turns away instructions the core can carry
/// out: a POSITION ("第二句", "the third one") and a CONTENT WORD ("把地點改成
/// 三樓會議室"). The gate used to know only about positions, which left the
/// content form unreachable from the app -- the core could do it and nothing
/// ever asked it to.
private func containsEditTarget(_ text: String) -> Bool {
    // 第 + a number + a unit: 第二點, 第3句, 第十段, 最後一句 is handled below.
    if text.range(of: "第[0-9一二三四五六七八九十兩]+[段句點行條個]",
                  options: .regularExpression) != nil { return true }
    // The line or paragraph just written.
    if ["這句", "這段", "這一段"].contains(where: { text.contains($0) }) { return true }
    // A positional pointer. 那 is optional: 最後一句 and 最後那句 mean the same, and
    // the user says whichever comes out; requiring the 那 would miss half of them.
    if text.range(of: "(前面|最後|後面|上面|下面)(那|一)?[段句點行條個]",
                  options: .regularExpression) != nil { return true }

    // Latin pointers: a bare "that line", or an ordinal acting as a determiner.
    let lower = text.lowercased()
    if ["that line", "that sentence", "that paragraph"].contains(where: { lower.contains($0) }) {
        return true
    }
    for ordinal in ["the first", "the second", "the last"] {
        var search = lower.startIndex..<lower.endIndex
        while let range = lower.range(of: ordinal, range: search) {
            if ordinalFollowedByNoun(lower, after: range.upperBound) { return true }
            search = range.upperBound..<lower.endIndex
        }
    }
    // A CONTENT WORD: the thing named before the change verb ("把地點改成…" names
    // 地點). The same extraction the core does, so the gate agrees with what
    // the core can actually resolve.
    if editContentWord(text) != nil { return true }
    return false
}

/// The word an instruction names as the thing to change, if it names one.
///
/// This mirrors the core's `content_words`: take what comes BEFORE the change
/// verb (that is the target; what comes after is the replacement), strip the
/// framing words, and keep what is left. A Chinese target is one run of
/// characters -- "把地點改成三樓會議室" leaves 地點 intact, because Chinese has
/// no spaces to split on.
///
/// The instruction has to READ as an instruction, not as a sentence about
/// changing something. That is what the frame at the front is for: "把地點改成…"
/// is an order, and "顏色改成藍色" / "我把檔案刪掉了" / "這個會議改成線上開" are
/// statements -- the first says a fact about a colour, the second reports an
/// action already done, the third proposes a change of a meeting. All three
/// name a word and carry a verb, and without the frame every one of them would
/// be taken for an edit of the text the app pasted last.
///
/// The core does not need this rule, because it looks the word up in the draft
/// and finds nothing: a colour that is not in the text cannot be the target.
/// This gate cannot see the draft, so it has to be the stricter of the two.
///
/// An empty result means the instruction named no content word: either there
/// was no verb, or everything before the verb was framing.
private func editContentWord(_ text: String) -> String? {
    // The target must be the subject of an order, not of a statement.
    guard hasImperativeFrame(text) else { return nil }
    let verbs = ["改成", "換成", "改為", "換", "改", "刪掉", "刪除", "拿掉", "去掉"]
    var head = text
    for verb in verbs {
        if let at = head.range(of: verb) {
            head = String(head[head.startIndex..<at.lowerBound])
            break
        }
    }
    // The framing words are the ones that say nothing about WHAT is changing.
    let framing = ["請幫我", "幫我", "請", "幫", "把", "給我", "我要", "我想", "要", "的", "了"]
    for word in framing {
        head = head.replacingOccurrences(of: word, with: " ")
    }
    let parts = head.split(whereSeparator: { $0.isWhitespace || "，,。.、；;：:！!？?「」『』".contains($0) })
    for part in parts {
        let candidate = part.trimmingCharacters(in: .whitespaces)
        // A single character is too short to be a target on its own ("把 A 改…"),
        // and a bare number is a position, which is handled above.
        guard candidate.count >= 2 else { continue }
        if candidate.allSatisfy({ $0.isNumber }) { continue }
        return candidate
    }
    return nil
}

/// True when the instruction opens like an order rather than like a statement.
///
/// The frame has to be at the FRONT, not merely somewhere in the line: "把地點
/// 改成三樓會議室" is an order, and "我把檔案刪掉了" has the same 把 with 我 in
/// front of it, which makes it a report of something already done. A marker
/// before the frame settles it either way.
private func hasImperativeFrame(_ text: String) -> Bool {
    var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // The politeness that can come first: 請 / 幫我 / 麻煩 / 能不能.
    let lead = ["請幫我", "幫我", "請", "麻煩", "能不能", "可以"]
    var changed = true
    while changed {
        changed = false
        for word in lead {
            if rest.hasPrefix(word) {
                rest = String(rest.dropFirst(word.count))
                rest = rest.trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
    }
    // The Chinese order frame.
    if ["把", "將"].contains(where: { rest.hasPrefix($0) }) { return true }
    // The English one: the verb opens the sentence. "I deleted the file" has
    // the verb in the middle and is a statement.
    let lower = rest.lowercased()
    let verbs = ["change", "replace", "delete", "remove", "shorten", "rewrite", "make it"]
    return verbs.contains { lower.hasPrefix($0) }
}

/// True when an ordinal is a determiner for a following word: "the second one"
/// is a target, a trailing "the second" is not, and "the second-guess" is not
/// either — a hyphen is not the space a noun needs. Only spaces are skipped
/// before the noun, which covers "one" and "item" and nothing more exotic.
private func ordinalFollowedByNoun(_ lower: String, after index: String.Index) -> Bool {
    var i = index
    var sawSpace = false
    while i < lower.endIndex {
        let character = lower[i]
        if character.isLetter { return sawSpace }
        guard character == " " else { return false }
        sawSpace = true
        i = lower.index(after: i)
    }
    return false
}

/// Whole-word lookup in already-lowercased text: neither character flanking the
/// match may be a letter. Latin gets this and Chinese does not because only
/// Latin writes words without spaces between them.
private func containsWord(_ lower: String, _ needle: String) -> Bool {
    var search = lower.startIndex..<lower.endIndex
    while let range = lower.range(of: needle, range: search) {
        let beforeIsBoundary = range.lowerBound == lower.startIndex
            || !lower[lower.index(before: range.lowerBound)].isLetter
        let afterIsBoundary = range.upperBound == lower.endIndex
            || !lower[range.upperBound].isLetter
        if beforeIsBoundary && afterIsBoundary { return true }
        search = range.upperBound..<lower.endIndex
    }
    return false
}

/// Applies a spoken edit to a draft, or nil when there is nothing to apply.
///
/// The numbering and the parsing are the core's: `LLM_EditText` numbers the
/// lines, asks for the whole text back, and refuses an answer that is commentary
/// rather than text. This wrapper only normalises the script and trims, so an
/// edited line lands in the same shape as a pasted one.
///
/// The caller MUST have called `VoiceInputEngine.prepare()` first. That is where
/// the model selection and the worker path are published into the process
/// environment, and the core's LLM worker inherits this process's environment
/// rather than taking them as arguments — without `prepare()` the worker cannot
/// be found, the call fails, and this returns nil.
///
/// Never throws. nil means "leave the text alone": the engine was unavailable,
/// the model answered with commentary, or its answer was identical to the input
/// (an edit that changed nothing is not an edit). The caller's fallback is to
/// keep the draft it already had, so a failed edit never costs the user text.
///
/// `config` is taken for symmetry with `refineTranscript` and to keep the run's
/// engine settings in one place; the core reads the model from the environment
/// `prepare()` published, so no field is consulted here.
///
/// The register (`config.refineTone`) is deliberately NOT applied. An edit says
/// what to change, and rewriting the untouched lines into another register would
/// be changing text the user did not ask about -- the whole-draft path would
/// rewrite every line the instruction did not name. The three registers belong
/// to `refineTranscript` (and to `LLM_RefineTextWithTone`). The segmented
/// control next to 修改的提示詞 in the main window writes that same setting, so the
/// register can be changed where the user is working; this path ignores it.
public func applyVoiceEdit(_ instruction: String, to text: String,
                           config: VoiceInputConfig) -> String? {
    let current = Text.toTraditional(text.trimmingCharacters(in: .whitespacesAndNewlines))
    // Only the core's numbering makes an instruction like 第二點 mean anything,
    // which is why the workspace is a whole-text call and not a line swap here.
    guard let answer = try? CoreABI.edit(current, instruction: instruction) else { return nil }
    let edited = Text.toTraditional(answer.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !edited.isEmpty, edited != current else { return nil }
    // Which lines survived is the core's business -- it numbered them, so it is
    // the only thing that can check them. What is added here is the guardrail
    // the cleanup already has, on the same rules: an answer that introduces
    // itself ("以下是修改後的版本") or runs three times the length of the draft is
    // not an edit. `applyVoiceEdit` then returns nil and the caller keeps its
    // draft.
    let verdict = Text.sanityCheck(edited, comparedTo: current, mode: "edit")
    guard verdict.ok else {
        HallucinationLog.record(
            mode: "edit", tone: config.refineTone,
            raw: current, refined: edited, reason: verdict.reason
        )
        return nil
    }
    return edited
}

/// Applies one 修改的提示詞 to the region the caller named.
///
/// Same call as `applyVoiceEdit(_:to:config:)` -- `LLM_EditText`, the core's
/// numbering and its shape checks -- with the region made explicit:
///
/// * `.whole` / `.line(n)` — the whole draft goes to the core and the line
///   number rides in the instruction, which is how `locate_edit_target` resolves
///   it. The 修改的提示詞 is never concatenated into the draft.
/// * `.selection` — the selected slice IS the draft as far as the core is
///   concerned, and the answer is spliced back into the same range, so the
///   untouched text cannot be rewritten.
///
/// - Parameter selection: a range in `text`, required only for `.selection`. An
///   empty or missing range is a refusal rather than a silent fallback to the
///   whole draft: "只改我選的那段" must never rewrite the rest.
/// - Returns: nil when nothing usable came back. The caller keeps its draft.
public func applyVoiceEdit(_ instruction: String, to text: String,
                           region: PromptEditRegion,
                           selection: Range<String.Index>?,
                           config: VoiceInputConfig) -> String? {
    let current = Text.toTraditional(text.trimmingCharacters(in: .whitespacesAndNewlines))
    switch region {
    case .whole, .line:
        return applyVoiceEdit(region.instruction(instruction), to: current, config: config)
    case .selection:
        guard let selection, !selection.isEmpty, selection.upperBound <= current.endIndex else {
            return nil
        }
        let slice = String(current[selection])
        guard !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let answer = try? CoreABI.edit(slice, instruction: instruction) else { return nil }
        let edited = Text.toTraditional(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !edited.isEmpty, edited != slice else { return nil }
        let verdict = Text.sanityCheck(edited, comparedTo: slice, mode: "edit")
        guard verdict.ok else {
            HallucinationLog.record(
                mode: "edit", tone: config.refineTone,
                raw: slice, refined: edited, reason: verdict.reason
            )
            return nil
        }
        return current.replacingCharacters(in: selection, with: edited)
    }
}
