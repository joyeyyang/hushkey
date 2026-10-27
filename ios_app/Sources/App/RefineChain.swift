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

    /// Distinctive phrases from the refine instructions in `core_engine/src/llm.rs`
    /// (`REFINE_SYSTEM`). If the answer repeats one of these and the user never said
    /// it, the model answered US instead of cleaning the draft.
    private static let instructionPhrases = [
        "不要摘要", "不要漏掉任何一件事", "重複講的同一件事只留一次", "刪掉口頭禪",
        "多餘的字", "照原樣保留", "問句保持問句", "預設用繁體中文輸出",
        "把使用者的口語改寫成通順的書面文字",
        // Added with the formal-register rule: a longer prompt is a longer thing
        // for a small model to answer instead of the draft.
        "像寫給客戶或同事的信", "像自言自語", "換成正式而具體的詞",
    ]

    /// Returns the leaked phrase, or nil when the answer looks like a real edit.
    static func leakedInstruction(_ refined: String, raw: String) -> String? {
        for phrase in instructionPhrases where refined.contains(phrase) && !raw.contains(phrase) {
            return phrase
        }
        return nil
    }

    /// One-line excerpt, for callers that log a rejection reason.
    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 160 ? flat : String(flat.prefix(160)) + "…"
    }

    /// Guards against the two ways a small model betrays us: answering the
    /// transcript instead of cleaning it (empty output, meta phrasing, a different
    /// language), and inventing content that was never said.
    ///
    /// Deliberately permissive about DELETION: condensing away filler and
    /// repetition is the entire point of the cleanup, so the length floor only
    /// catches a rewrite-into-something-else.
    static func sanityCheck(_ refined: String, comparedTo raw: String) -> (ok: Bool, reason: String) {
        guard !refined.isEmpty else { return (false, "empty output") }

        let rawLen = max(raw.count, 1)
        let refinedLen = refined.count
        if refinedLen < Int(Double(rawLen) * 0.15) {
            return (false, "far too short: \(refinedLen)/\(rawLen) chars")
        }
        if refinedLen > Int(Double(rawLen) * 2.0) {
            return (false, "far too long: \(refinedLen)/\(rawLen) chars")
        }
        for prefix in ["以下是", "很抱歉", "抱歉", "對不起", "總結：", "原文：", "Here is", "Sure,"]
        where refined.hasPrefix(prefix) {
            return (false, "meta phrasing: \(prefix)")
        }
        if let leaked = leakedInstruction(refined, raw: raw) {
            return (false, "echoed the instructions: \(leaked)")
        }

        if raw.containsCJK {
            if !refined.containsCJK {
                // Losing the Chinese is only legitimate when the dictation asked for
                // another language; the refine prompt is told to honour that request
                // and drop the instruction.
                guard raw.namesAnotherLanguage else {
                    return (false, "no Chinese left in the output")
                }
                guard refined.containsLatinLetter else {
                    return (false, "asked for another language but wrote none")
                }
                return (true, "ok")
            }
            let rawCJK = Set(raw.unicodeScalars.filter(\.isCJK))
            if !rawCJK.isEmpty {
                let refinedSet = Set(refined.unicodeScalars)
                let kept = rawCJK.filter { refinedSet.contains($0) }.count
                let ratio = Double(kept) / Double(rawCJK.count)
                // Condensing to ~30% is normal; the legitimate worst case measured
                // 0.26, so 0.18 only catches a rewrite into something else entirely.
                if ratio < 0.18 {
                    return (false, "only kept \(Int(ratio * 100))% of the words used")
                }
            }
        } else if raw.containsLatinLetter {
            // A non-Chinese transcript must not be translated away.
            guard refined.containsLatinLetter else { return (false, "translated away") }
        }
        return (true, "ok")
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
    static func refine(raw: String, polish: Bool, translateTarget: String) -> Result {
        let base = TextRules.normalizeOutput(
            TextScript.traditional(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        guard polish, !base.isEmpty else { return Result(text: base, note: nil) }
        let polished = polishOnce(base)
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
    private static func polishOnce(_ raw: String) -> Result {
        guard let answer = try? Core.refine(raw) else {
            return Result(text: fallback(raw), note: "整理失敗")
        }
        // Convert again after the model: it may echo Simplified even when asked
        // not to.
        let candidate = TextRules.normalizeOutput(
            TextScript.traditional(TextRules.stripLabel(answer.trimmingCharacters(in: .whitespacesAndNewlines)))
        )
        let verdict = TextRules.sanityCheck(candidate, comparedTo: raw)
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

    /// True when the speaker named a language to answer in. Used only to let a
    /// non-Chinese result through `sanityCheck`: a Chinese dictation that comes
    /// back without a single Chinese character is a bug *unless* it asked for one.
    /// A short list rather than a parser — a false positive costs one unchecked
    /// line, a false negative throws away a correct answer.
    var namesAnotherLanguage: Bool {
        let needles = [
            "英文", "英語", "英语", "日文", "日語", "日语", "韓文", "韓語", "韩文",
            "法文", "德文", "西班牙文", "義大利文", "越南文", "泰文",
            "English", "Japanese", "Korean", "Spanish", "French", "German",
        ]
        return needles.contains { localizedCaseInsensitiveContains($0) }
    }
}

extension Unicode.Scalar {
    var isCJK: Bool {
        (0x4E00...0x9FFF).contains(Int(value)) || (0x3400...0x4DBF).contains(Int(value))
    }
}
