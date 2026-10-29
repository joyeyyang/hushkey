import CoreFoundation
import Foundation

/// Simplified → Traditional, the way the Mac has always done it.
///
/// The recogniser answers Taiwanese Mandarin in Simplified characters, and the
/// cleanup model copies whatever script it is handed -- so a dictation that never
/// passes through here reaches the keyboard in the wrong script, or, worse,
/// half-converted: the model rewrites the clauses it paraphrases and leaves the
/// rest alone, and one sentence comes out with 「我們明天我們班來開個會」 next to
/// 「下礼拜和校庆」. That is exactly what a real device dictation produced.
///
/// ICU's `Hans-Hant` transform is part of the system: offline, no data file, no
/// model. A no-op for text without Han characters. Deterministic, unlike asking
/// the model again -- which is why this is not a second prompt.
enum TextScript {
    static func traditional(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text) as CFMutableString
        // The return value is "did the transform apply"; a no-op for pure English
        // is expected, so it is deliberately ignored.
        _ = CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
        return mutable as String
    }
}

/// Text surgery shared by every iOS path that produces a sentence.
///
/// This is the Mac's `TextPostprocess.swift`/`Text` walked across to the phone
/// rather than re-invented: the same thresholds, the same label list, the same
/// bullet style. The reason is not tidiness. The iPhone shipped without the
/// sanity guard for months, so a small model that answered *the instruction*
/// instead of the transcript ("不要摘要" appearing in the pasted sentence) was
/// published verbatim. "Both platforms the same" is only worth anything if it is
/// the same rules.
///
/// Named `TextRules` rather than `Text` because SwiftUI already owns that name:
/// the Mac's copy lives in `VoiceInputKit`, where AppKit has no such view and the
/// collision cannot happen.
enum TextRules {

    /// Housekeeping on model output before it is pasted: one newline style, plain
    /// "• " bullets instead of Markdown dashes or asterisks (the text goes into any
    /// app, so it must not depend on a Markdown renderer), and no bold markers.
    static func normalizeOutput(_ text: String) -> String {
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "・", "· ", "•"] where trimmed.hasPrefix(marker) {
                trimmed = "• " + trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                break
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "**", with: "")
    }

    /// Removes a leading "潤飾：" / "Output:"-style label the small model may echo
    /// from the prompt examples.
    static func stripLabel(_ text: String) -> String {
        for label in ["整理：", "整理:", "潤飾：", "潤飾:", "草稿：", "草稿:", "輸出：", "Output:", "Polished:",
                      "翻譯：", "翻譯:", "Translation:", "英文：", "中文："] {
            if text.hasPrefix(label) {
                return String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// One-line excerpt, for callers that log a rejection reason.
    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 160 ? flat : String(flat.prefix(160)) + "…"
    }

    /// Guards against the ways a small model betrays us: answering the
    /// instructions instead of the text, translating it, shrinking it into a
    /// summary, or echoing one of the prompt's own rules.
    ///
    /// The rules live in the CORE (`rust/core_engine/src/guardrail.rs`, reached
    /// through `LLM_CheckOutput`). They used to be written out twice -- here and
    /// in the Mac's `TextPostprocess.swift` -- with a comment asking the two to
    /// stay the same. The iPhone shipped without the guard for months and
    /// published a model's remark verbatim, which is what "two copies that are
    /// supposed to agree" costs; there is one copy now.
    ///
    /// - Parameter mode: "edit" for the spoken-edit path, "refine" for the
    ///   cleanup. An edit may delete lines; a cleanup may not drop the sentence.
    /// - Parameter tone: adds the register rule (a 正式 line may not carry
    ///   喔／啦／耶).
    ///
    /// Fails CLOSED: if the core cannot answer, the answer is not used and the
    /// transcript is. Losing the polish is cheaper than pasting a remark.
    static func sanityCheck(_ refined: String, comparedTo raw: String,
                            mode: String = "refine",
                            tone: String = "normal") -> (ok: Bool, reason: String) {
        guard let reason = try? Core.checkOutput(
            raw: raw, refined: refined, mode: mode, tone: tone
        ) else {
            return (false, "the guard could not run")
        }
        return reason.isEmpty ? (true, "ok") : (false, reason)
    }
}

/// The cleanup chain: raw transcript → Traditional → refine → translate.
///
/// Same order as the Mac, and the order matters. Refine must never change the
/// language and translate must; asking one prompt to do both produced
/// half-translated drafts. Each step also falls back instead of failing, because
/// a rough sentence is still the user's sentence and a rejected answer must not
/// cost them the dictation.
enum Refiner {

    /// The whole chain. `polish == false` returns the script-normalised raw text
    /// untouched, which is the "AI 整理 off" mode.
    ///
    /// `tone` is the register the cleanup writes in. It reaches the prompt AND
    /// the guard: the guard's only register rule is that a 正式 line may not
    /// carry 喔／啦／耶, which is the register failing rather than a style choice.
    static func refine(raw: String, polish: Bool, translateTarget: String, tone: String) -> Result {
        let base = TextRules.normalizeOutput(
            TextScript.traditional(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        guard polish, !base.isEmpty else { return Result(text: base, note: nil) }
        let polished = polishOnce(base, tone: tone)
        let translated = translateIfNeeded(polished.text, target: translateTarget)
        return Result(text: translated.text, note: polished.note ?? translated.note)
    }

    /// What the chain produced, and (when it had to guess) why.
    struct Result {
        var text: String
        /// Non-nil when a step was rejected or skipped, so the UI can say so
        /// instead of silently pretending the model did its job.
        var note: String?
    }

    /// One refine pass, the sanity guard, and the fallback.
    private static func polishOnce(_ raw: String, tone: String) -> Result {
        guard let answer = try? Core.refine(raw, tone: tone) else {
            return Result(text: fallback(raw), note: "整理失敗")
        }
        // Convert again after the model: it may echo Simplified even when asked
        // not to.
        let candidate = TextRules.normalizeOutput(
            TextScript.traditional(TextRules.stripLabel(answer.trimmingCharacters(in: .whitespacesAndNewlines)))
        )
        let verdict = TextRules.sanityCheck(candidate, comparedTo: raw, tone: tone)
        guard verdict.ok else {
            Diagnostics.log.error("refine rejected: \(verdict.reason, privacy: .public) — \(TextRules.preview(candidate), privacy: .public)")
            return Result(text: fallback(raw), note: "整理被退回")
        }
        return Result(text: candidate, note: nil)
    }

    /// The raw transcript, tidied just enough to hand over. Used whenever the
    /// model's answer is thrown away, so a rejected refine still yields one
    /// consistent bullet style instead of whatever the recogniser emitted.
    static func fallback(_ raw: String) -> String {
        TextRules.normalizeOutput(
            TextScript.traditional(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// Translate the finished line when the user asked for it.
    ///
    /// `target` is "en" or "zh"; "auto" and "off" mean the refine prompt already
    /// decided and no second pass runs. A translation that fails, or that comes
    /// back as a note instead of a translation, keeps the cleaned text so the
    /// dictation is never lost.
    static func translateIfNeeded(_ text: String, target: String) -> Result {
        guard target == "en" || target == "zh" else { return Result(text: text, note: nil) }
        guard let raw = try? Core.translate(text, to: target) else {
            return Result(text: text, note: "翻譯失敗")
        }
        let translated = TextRules.normalizeOutput(
            TextScript.traditional(TextRules.stripLabel(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        )
        // The model sometimes answers with an explanation instead of a
        // translation; the target script must actually be present, and a
        // translation five times the original is a note, not a line.
        let plausible = (target == "en") ? translated.containsLatinLetter : translated.containsCJK
        guard !translated.isEmpty, plausible, translated.count <= text.count * 5 else {
            Diagnostics.log.error("translate rejected: \(TextRules.preview(translated), privacy: .public)")
            return Result(text: text, note: "翻譯被退回")
        }
        return Result(text: translated, note: nil)
    }
}

extension String {

    var containsCJK: Bool { unicodeScalars.contains { $0.isCJK } }

    var containsLatinLetter: Bool {
        unicodeScalars.contains {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
    }
}

extension Unicode.Scalar {
    var isCJK: Bool {
        (0x4E00...0x9FFF).contains(Int(value)) || (0x3400...0x4DBF).contains(Int(value))
    }
}
