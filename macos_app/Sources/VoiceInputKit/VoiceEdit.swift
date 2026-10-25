import Foundation

/// The spoken-edit feature: the user says what to change about text that is
/// already on screen, and the line is applied instead of pasted.
///
/// Two halves, deliberately apart. `isVoiceEditInstruction` is a pure predicate
/// over the recognised line and decides whether to *try* an edit at all;
/// `applyVoiceEdit` is the model call that performs one. Keeping the decision
/// free of the model is what makes it reviewable — the cost of getting it wrong
/// is described on the predicate itself.

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
/// Samples this was built against (the CLI's `--is-edit` prints the verdict for
/// exactly these, so they can be re-checked without a test target):
///
///   accepted: 把第二點改成禮拜五下午兩點
///             第三句刪掉
///             delete the second one
///             把最後一句改短一點
///   rejected: 顏色改成藍色
///             我把檔案刪掉了
///             這個會議改成線上開
///             我用英文寫了一封信
///
/// The two 改成 rejections each carry a verb but name no target — 顏色 and a
/// 把-sentence's object are not "this line", which is what an edit needs. 這個會議
/// names a thing, but with 這個 rather than one of the edit targets: a whole
/// sentence's subject is not the line under discussion. 我用英文寫了一封信 has
/// neither half. The predicate is a pure function of its argument on purpose —
/// it is the one piece of this feature that can be argued about instead of run.
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
                   "縮短", "精簡", "重寫", "變成", "移到", "調順序", "加一句", "補一句", "改"]
    if chinese.contains(where: { text.contains($0) }) { return true }

    let latin = ["change", "replace", "delete", "remove", "shorten", "rewrite", "make it"]
    let lower = text.lowercased()
    return latin.contains { containsWord(lower, $0) }
}

/// The target half: a pointer at the line the instruction is about.
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
    return false
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
public func applyVoiceEdit(_ instruction: String, to text: String,
                           config: VoiceInputConfig) -> String? {
    let current = Text.toTraditional(text.trimmingCharacters(in: .whitespacesAndNewlines))
    // Only the core's numbering makes an instruction like 第二點 mean anything,
    // which is why the workspace is a whole-text call and not a line swap here.
    guard let answer = try? CoreABI.edit(current, instruction: instruction) else { return nil }
    let edited = Text.toTraditional(answer.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !edited.isEmpty, edited != current else { return nil }
    return edited
}
