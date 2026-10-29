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
    /// through `LLM_CheckOutput`), not here. They used to be written out twice --
    /// once in this file and once in the iOS `RefineChain.swift` -- with a
    /// comment asking the two to stay the same; they are one implementation now,
    /// so "both platforms the same" is a fact instead of a promise.
    ///
    /// - Parameter mode: "edit" for the spoken-edit path, "refine" (the default)
    ///   for the cleanup. An edit may delete lines, a cleanup may not drop the
    ///   sentence, so the two have different floors.
    /// - Parameter tone: adds the register rule -- a 正式 line may not carry
    ///   喔／啦／耶. The other registers have no extra rule.
    ///
    /// Fails CLOSED when the check cannot run. The caller's fallback is the
    /// transcript, and losing the model's polish is cheaper than pasting the
    /// remark it made about the instructions.
    static func sanityCheck(_ refined: String, comparedTo raw: String,
                            mode: String = "refine",
                            tone: String = "normal") -> (ok: Bool, reason: String) {
        guard let reason = try? CoreABI.checkOutput(
            raw: raw, refined: refined, mode: mode, tone: tone
        ) else {
            return (false, "the guard could not run")
        }
        return reason.isEmpty ? (true, "ok") : (false, reason)
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
        guard let refined = try? CoreABI.refine(
            raw, keywordsHint: hint, stages: config.refineStages, tone: config.refineTone
        ) else {
            return fallback(raw)
        }
        // Convert again after the model: it may echo Simplified even when asked
        // not to.
        let candidate = Text.normalizeOutput(
            Text.toTraditional(Text.stripLabel(refined.trimmingCharacters(in: .whitespacesAndNewlines))))
        let verdict = Text.sanityCheck(candidate, comparedTo: raw, tone: config.refineTone)
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
}

extension Unicode.Scalar {
    var isCJK: Bool {
        (0x4E00...0x9FFF).contains(Int(value)) || (0x3400...0x4DBF).contains(Int(value))
    }
}
