import Foundation
import CoreFoundation

/// Text surgery shared by the file and live paths.
///
/// All of this used to live privately in the app's `main.swift`; it is lifted
/// here verbatim (same transforms, same thresholds) because it is what turns a
/// raw ASR line into something worth pasting, and every caller of the kit wants
/// the same behaviour. The thresholds are deliberately not tunable — they were
/// each moved to their measured value once, and exposing them would invite
/// regressions.
enum Text {

    /// Simplified → Traditional using macOS's built-in ICU transform.
    /// Deterministic and offline; a no-op for text without Han characters.
    static func toTraditional(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        // The return value is "did the transform apply"; a no-op for pure
        // English is expected, so it is deliberately ignored.
        _ = CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
        return mutable as String
    }

    /// Housekeeping on model output before it is pasted: one newline style,
    /// plain "• " bullets instead of Markdown dashes or asterisks (the text goes
    /// into any app, so it must not depend on a Markdown renderer), and no bold
    /// markers.
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

    /// Joins speech parts language-aware: Chinese segments must not be separated
    /// by spaces, English ones must. The rule is per boundary, so a mixed
    /// sentence still comes out readable.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if out.isEmpty {
                out = piece
            } else if usesCJK(out.last!), usesCJK(piece.first!) {
                out += piece
            } else {
                out += " " + piece
            }
        }
        return out
    }

    static func usesCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Distinctive phrases from the refine instructions in
    /// `core_engine/src/llm.rs` (`REFINE_SYSTEM`). If the answer repeats one of
    /// these and the user never said it, the model answered US instead of
    /// cleaning the draft.
    private static let instructionPhrases = [
        "不要摘要", "不要漏掉任何一件事", "重複講的同一件事只留一次", "刪掉口頭禪",
        "多餘的字", "照原樣保留", "問句保持問句", "預設用繁體中文輸出",
        "把使用者的口語改寫成通順的書面文字",
        // Added with the formal-register rule: a longer prompt is a longer thing
        // for a small model to answer instead of the draft. Kept identical to the
        // iOS copy on purpose -- two lists that drift are two products.
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
    /// transcript instead of cleaning it (empty output, meta phrasing, a
    /// different language), and inventing content that was never said.
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
                // Losing the Chinese is only legitimate when the dictation asked
                // for another language; the refine prompt is told to honour that
                // request and drop the instruction.
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
                // Condensing to ~30% is normal; the legitimate worst case
                // measured 0.26, so 0.18 only catches a rewrite into something
                // else entirely.
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
/// Kept as free functions over a config rather than methods on the engine so
/// both the file path and the live session can share one implementation.
enum Refiner {

    /// The whole chain. `polishEnabled == false` returns the script-normalised
    /// raw text untouched, which is the "raw mode" the app exposes.
    static func refine(raw: String, config: VoiceInputConfig) -> String {
        let base = Text.toTraditional(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard config.polishEnabled, !base.isEmpty else { return base }
        let polished = polish(base, config: config)
        return translateIfNeeded(polished, config: config)
    }

    /// One refine pass with a keywords hint, then the sanity guard. Falls back
    /// to the raw transcript whenever the model is unavailable or its answer
    /// looks wrong, so a dictation is never lost to a bad generation.
    static func polish(_ raw: String, config: VoiceInputConfig) -> String {
        // No keyword hint. Proper nouns are the model's own job: it reads the
        // draft and spells what it hears, which avoids the failure mode of a list
        // -- a name that is on the list but was NOT said this time gets pulled
        // into the sentence. The keyword tab keeps its list, but nothing is
        // injected from it any more.
        let hint = ""
        guard let refined = try? CoreABI.refine(raw, keywordsHint: hint, stages: config.refineStages) else {
            return fallback(raw)
        }
        // Convert again after the model: it may echo Simplified even when asked
        // not to.
        let candidate = Text.normalizeOutput(
            Text.toTraditional(Text.stripLabel(refined.trimmingCharacters(in: .whitespacesAndNewlines))))
        let verdict = Text.sanityCheck(candidate, comparedTo: raw)
        guard verdict.ok else { return fallback(raw) }
        return candidate
    }

    /// The raw transcript, tidied just enough to paste. Used whenever the
    /// model's answer is thrown away, so a rejected refine still yields one
    /// consistent bullet style instead of whatever the recogniser emitted.
    static func fallback(_ raw: String) -> String {
        Text.normalizeOutput(Text.toTraditional(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The transcript with no model involved at all.
    ///
    /// This is what a meeting ends with: the words as they were spoken, with
    /// only the script normalised (the recogniser emits Simplified) and the
    /// bullet style made consistent. Nothing is rewritten, condensed or
    /// reordered, because the meeting's own summary is a separate step that
    /// reads this text and applies its own rules.
    ///
    /// The difference from `fallback` is the intent rather than the result:
    /// `fallback` is a degraded dictation (the model was there and its answer
    /// was rejected), this is a meeting transcript that was never meant to go
    /// through the model at all.
    static func tidy(_ raw: String) -> String {
        Text.normalizeOutput(Text.toTraditional(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Translate the finished line when the user asked for it. Runs AFTER the
    /// refine pass on purpose (see `VoiceInputConfig.translateTarget`). A
    /// translation that fails, or that comes back as a note instead of a
    /// translation, falls back to the cleaned text so the dictation is never
    /// lost.
    static func translateIfNeeded(_ text: String, config: VoiceInputConfig) -> String {
        let target = config.translateTarget
        guard target == "en" || target == "zh" else { return text }
        guard let raw = try? CoreABI.translate(text, to: target) else { return text }
        let translated = Text.normalizeOutput(
            Text.toTraditional(Text.stripLabel(raw.trimmingCharacters(in: .whitespacesAndNewlines))))
        // The model sometimes answers with an explanation instead of a
        // translation; the target script must actually be present, and a
        // translation five times the original is a note, not a line.
        let hasLatin = translated.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        let plausible = (target == "en") ? hasLatin : translated.containsCJK
        guard !translated.isEmpty, plausible, translated.count <= text.count * 5 else {
            return text
        }
        return translated
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
    /// back without a single Chinese character is a bug *unless* it asked for
    /// one. A short list rather than a parser — a false positive costs one
    /// unchecked line, a false negative throws away a correct answer.
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
