//! The last gate before a model's answer is treated as something the user wrote.
//!
//! A 2B model fails in a small number of recognisable ways, and every one of
//! them was seen in a real dictation before it was written down here:
//!
//! * it answers the INSTRUCTIONS instead of the text ("以下是整理後的版本…",
//!   "不要摘要" appearing in the pasted sentence);
//! * it answers a different language (a Chinese draft comes back in English
//!   because the draft mentioned an English product);
//! * it rewrites the text into something else entirely (a 40-character sentence
//!   becomes an 8-character summary);
//! * it echoes one of the prompt's own rules ("重複講的同一件事只留一次").
//!
//! None of these can be detected by asking the model again -- that is a second
//! inference, it doubles the latency, and a small model is no better at judging
//! its own answer than at producing one. So the gate is arithmetic: lengths,
//! character sets, prefixes. It is deliberately PERMISSIVE about deletion
//! (condensing away filler and repetition is the whole point of the cleanup) and
//! about rewording (the cleanup is a rewrite); it only catches a rewrite into
//! something else.
//!
//! The rules used to live twice, once in `VoiceInputKit/TextPostprocess.swift`
//! and once in the iOS `RefineChain.swift`, with a comment asking the two to
//! stay the same. They are here now so that "both platforms the same" is a fact
//! instead of a promise: the C entry point is `LLM_CheckOutput`.

use crate::llm::Tone;

/// Which job produced the text being checked.
///
/// The cleanup rewrites a transcript into one line; a spoken edit applies an
/// instruction to text the app already produced. The length rules differ -- an
/// edit may legitimately DELETE lines, a cleanup may not drop the sentence --
/// so the two cannot share one floor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Refine,
    Edit,
}

impl Kind {
    /// "edit" for the spoken-edit path, anything else for the cleanup. Same
    /// reason `Tone::parse` is lenient: the value crosses a C string.
    pub fn parse(raw: &str) -> Kind {
        match raw.trim().to_ascii_lowercase().as_str() {
            "edit" => Kind::Edit,
            _ => Kind::Refine,
        }
    }
}

/// What the gate decided. `reason` is empty when `ok`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub ok: bool,
    pub reason: String,
}

impl Verdict {
    fn ok() -> Verdict {
        Verdict { ok: true, reason: String::new() }
    }

    fn reject(reason: impl Into<String>) -> Verdict {
        Verdict { ok: false, reason: reason.into() }
    }
}

/// Phrases a model says when it answers the prompt rather than the draft.
///
/// Short and prefix-anchored on purpose: an answer that merely CONTAINS "以下是"
/// is fine ("以下是本週的進度" is a legitimate sentence), while one that STARTS
/// with it is the model introducing its own output.
const META_PREFIXES: [&str; 8] = [
    "以下是", "很抱歉", "抱歉", "對不起", "總結：", "原文：", "Here is", "Sure,",
];

/// Distinctive phrases from the prompts in `llm.rs`.
///
/// If the answer repeats one of these and the speaker never said it, the model
/// answered US instead of cleaning the draft. The list grows with the prompts:
/// a longer prompt is a longer thing for a small model to answer instead of the
/// text, so the tone paragraphs are named here too.
const INSTRUCTION_PHRASES: [&str; 16] = [
    "不要摘要",
    "不要漏掉任何一件事",
    "重複講的同一件事只留一次",
    "刪掉口頭禪",
    "多餘的字",
    "照原樣保留",
    "問句保持問句",
    "預設用繁體中文輸出",
    "把使用者的口語改寫成通順的書面文字",
    // Added with the formal-register rule: a longer prompt is a longer thing
    // for a small model to answer instead of the draft.
    "像寫給客戶或同事的信",
    "像自言自語",
    "換成正式而具體的詞",
    // The tone paragraphs (see `REFINE_SYSTEM_CASUAL` / `_FORMAL`).
    "像傳訊息給熟識的同事",
    "好讀的口語文字",
    "像對外發的正式書信或公文",
    "不要自己補上新的事實",
];

/// The casual particles the formal prompt forbids.
///
/// Only checked for `Tone::Formal`: `Normal` has forbidden them since before the
/// tone feature existed and its measured answers are the baseline, so rejecting
/// a particle there would change behaviour that was already accepted. For a
/// formal line, a particle is the register failing, which is exactly what the
/// user asked not to get.
const CASUAL_PARTICLES: [char; 5] = ['喔', '啦', '耶', '欸', '嘛'];

/// Simplified characters that have no Traditional reading of their own.
///
/// A detector, not a converter: the product converts with ICU (`Hans-Hant`) on
/// the Swift side, deterministically, and that is the actual fix for the
/// recogniser's Simplified output. This list exists for the other failure --
/// a model that CONVERTS a Traditional draft into Simplified, or mixes scripts
/// inside one sentence -- and it only fires when the draft did not already carry
/// those characters (see `introduced_simplified`).
const SIMPLIFIED_ONLY: &[char] = &[
    '这', '个', '会', '说', '时', '门', '问', '间', '学', '对', '应', '开', '关', '长', '现', '发',
    '经', '过', '还', '进', '样', '电', '话', '认', '为', '从', '来', '后', '里', '点', '儿', '头',
    '见', '觉', '听', '写', '读', '语', '让', '给', '与', '专', '业', '东', '车', '马', '鸟', '鱼',
    '龙', '岁', '万', '书', '买', '卖', '贝', '页', '风', '飞', '食', '们', '吗', '呢', '办', '动',
    '务', '员', '单', '双', '变', '号', '场', '处', '备', '复', '够', '头', '夺', '妇', '妈', '孙',
    '宁', '实', '宝', '审', '层', '师', '带', '帮', '广', '庆', '库', '废', '张', '归', '当',
];

/// Check one model answer against the text it was produced from.
///
/// `raw` is the input the model saw (the transcript for `Refine`, the draft for
/// `Edit`), `refined` is its answer after the caller's own normalisation.
pub fn check(kind: Kind, raw: &str, refined: &str, tone: Tone) -> Verdict {
    if refined.trim().is_empty() {
        return Verdict::reject("empty output");
    }
    let raw_len = raw.chars().count().max(1);
    let refined_len = refined.chars().count();

    match kind {
        Kind::Refine => {
            if refined_len < raw_len * 15 / 100 {
                return Verdict::reject(format!("far too short: {refined_len}/{raw_len} chars"));
            }
            if refined_len > raw_len * 2 {
                return Verdict::reject(format!("far too long: {refined_len}/{raw_len} chars"));
            }
        }
        Kind::Edit => {
            // No floor: deleting lines is what half the instructions ask for,
            // and the line-level fidelity (which line, how many) is checked by
            // the parser that numbered the draft, because only it knows the
            // numbering. What is left here is the shape a remark has.
            if refined_len > raw_len * 3 {
                return Verdict::reject(format!("far too long: {refined_len}/{raw_len} chars"));
            }
        }
    }

    for prefix in META_PREFIXES {
        if refined.starts_with(prefix) {
            return Verdict::reject(format!("meta phrasing: {prefix}"));
        }
    }

    if kind == Kind::Refine {
        if let Some(phrase) = INSTRUCTION_PHRASES
            .iter()
            .find(|phrase| refined.contains(**phrase) && !raw.contains(**phrase))
        {
            return Verdict::reject(format!("echoed the instructions: {phrase}"));
        }
        if introduced_simplified(raw, refined) {
            return Verdict::reject("the model introduced simplified characters");
        }
        if tone == Tone::Formal {
            if let Some(particle) = CASUAL_PARTICLES.iter().find(|p| refined.contains(**p)) {
                return Verdict::reject(format!("casual particle in a formal line: {particle}"));
            }
        }
        return check_language(raw, refined);
    }
    Verdict::ok()
}

/// The two ways the language can go wrong: Chinese lost, or Chinese invented.
///
/// A Chinese draft that comes back without a single Chinese character is a bug
/// UNLESS the speaker named a language to answer in (the refine prompt is told
/// to honour that request and drop the instruction). The same in reverse: an
/// English draft must not come back translated.
fn check_language(raw: &str, refined: &str) -> Verdict {
    if contains_cjk(raw) {
        if !contains_cjk(refined) {
            if !names_another_language(raw) {
                return Verdict::reject("no Chinese left in the output");
            }
            if !contains_latin(refined) {
                return Verdict::reject("asked for another language but wrote none");
            }
            return Verdict::ok();
        }
        let raw_chars: Vec<char> = raw.chars().filter(|c| is_ideograph(*c)).collect();
        if !raw_chars.is_empty() {
            let kept = raw_chars.iter().filter(|c| refined.contains(**c)).count();
            let ratio = kept as f32 / raw_chars.len() as f32;
            // Condensing to ~30% is normal; the legitimate worst case measured
            // 0.26, so 0.18 only catches a rewrite into something else entirely.
            if ratio < 0.18 {
                return Verdict::reject(format!(
                    "only kept {}% of the words used",
                    (ratio * 100.0) as i32
                ));
            }
        }
    } else if contains_latin(raw) && !contains_latin(refined) {
        return Verdict::reject("translated away");
    }
    Verdict::ok()
}

/// True when the answer carries Simplified-only characters the input did not.
///
/// Relative, not absolute, on purpose. The recogniser emits Simplified for
/// Taiwanese Mandarin, so a Simplified input producing a Simplified answer is
/// the normal state of the world -- the caller converts it. What this catches is
/// the model changing the script on its own, which is the failure the prompt
/// rule and the ICU conversion were added for.
fn introduced_simplified(raw: &str, refined: &str) -> bool {
    SIMPLIFIED_ONLY
        .iter()
        .any(|c| refined.contains(*c) && !raw.contains(*c))
}

fn contains_cjk(text: &str) -> bool {
    text.chars().any(is_ideograph)
}

fn contains_latin(text: &str) -> bool {
    text.chars().any(|c| c.is_ascii_alphabetic())
}

fn is_ideograph(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x4dbf | 0x4e00..=0x9fff)
}

/// True when the speaker named a language to answer in.
///
/// A short list rather than a parser, same trade as everywhere else here: a
/// false positive costs one unchecked line, a false negative throws away a
/// correct answer.
fn names_another_language(text: &str) -> bool {
    const NEEDLES: [&str; 19] = [
        "英文", "英語", "英语", "日文", "日語", "日语", "韓文", "韓語", "韩文", "法文", "德文",
        "西班牙文", "義大利文", "越南文", "泰文", "English", "Japanese", "Korean", "Spanish",
    ];
    let lowered = text.to_lowercase();
    NEEDLES.iter().any(|needle| lowered.contains(&needle.to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(raw: &str, refined: &str) -> bool {
        check(Kind::Refine, raw, refined, Tone::Normal).ok
    }

    #[test]
    fn a_faithful_cleanup_passes() {
        let raw = "嗯那個明天下午三點跟小林開會，討論第四季時程，地點還沒確定";
        let refined = "明天下午三點與小林開會，討論第四季時程，地點尚未確定";
        assert!(ok(raw, refined));
    }

    #[test]
    fn empty_output_is_never_usable() {
        for refined in ["", "   ", "\n"] {
            let verdict = check(Kind::Refine, "明天開會", refined, Tone::Normal);
            assert!(!verdict.ok);
            assert_eq!(verdict.reason, "empty output");
        }
    }

    #[test]
    fn a_rewrite_into_something_else_is_rejected() {
        let raw = "明天下午三點跟小林開會，討論第四季時程，地點還沒確定，記得帶合約";
        // A summary, not a cleanup: the words the speaker used are gone.
        let short = check(Kind::Refine, raw, "開會", Tone::Normal);
        assert!(!short.ok);
        assert!(short.reason.starts_with("far too short"));
        // A model that explains itself instead of answering.
        let long = check(Kind::Refine, raw, &raw.repeat(3), Tone::Normal);
        assert!(!long.ok);
        assert!(long.reason.starts_with("far too long"));
    }

    #[test]
    fn answering_the_instructions_is_rejected() {
        let raw = "明天下午三點跟小林開會";
        for answer in ["以下是整理後的版本：明天下午三點開會", "很抱歉，我無法處理這段文字"] {
            let verdict = check(Kind::Refine, raw, answer, Tone::Normal);
            assert!(!verdict.ok, "{answer}");
            assert!(verdict.reason.starts_with("meta phrasing"));
        }
        // The same words INSIDE a sentence are the speaker's, not the model's.
        assert!(ok(raw, "明天下午三點跟小林開會，以下是重點"));
    }

    #[test]
    fn echoing_a_prompt_rule_is_rejected() {
        let raw = "明天下午三點跟小林開會，地點還沒確定";
        let verdict = check(
            Kind::Refine,
            raw,
            "明天下午三點跟小林開會，地點還沒確定，重複講的同一件事只留一次",
            Tone::Normal,
        );
        assert!(!verdict.ok);
        assert!(verdict.reason.starts_with("echoed the instructions"));
        // If the speaker actually said it, it is content and must survive.
        assert!(ok(
            "重複講的同一件事只留一次，這是我們的原則",
            "重複講的同一件事只留一次，這是我們的原則"
        ));
    }

    #[test]
    fn language_may_only_change_when_it_was_asked_for() {
        let raw = "明天下午三點跟小林開會";
        let translated = check(Kind::Refine, raw, "Meeting at 3 tomorrow", Tone::Normal);
        assert!(!translated.ok);
        assert_eq!(translated.reason, "no Chinese left in the output");

        // The speaker asked for English: a non-Chinese answer is the point.
        assert!(ok("明天下午三點開會，整理成英文", "Meeting at 3 tomorrow"));

        // An English draft must not come back translated.
        let away = check(Kind::Refine, "meeting at 3 tomorrow", "明天下午三點開會", Tone::Normal);
        assert!(!away.ok);
        assert_eq!(away.reason, "translated away");
    }

    #[test]
    fn keeping_a_fifth_of_the_words_is_enough_but_not_less() {
        // 40 ideographs, 20 kept = 50%: a normal condensation.
        let raw = "明天下午三點跟小林開會討論第四季時程地點還沒確定記得帶合約和報價單還有名片";
        let kept: String = raw.chars().take(20).collect();
        assert!(ok(raw, &kept));
        // 5 of 37 = 14%: above the length floor (15% of 37 rounds down to 5),
        // below the retention floor -- a fragment made of the opening words.
        let fragment: String = raw.chars().take(5).collect();
        let verdict = check(Kind::Refine, raw, &fragment, Tone::Normal);
        assert!(!verdict.ok);
        assert!(verdict.reason.starts_with("only kept"));
    }

    #[test]
    fn introducing_simplified_characters_is_rejected() {
        // Traditional draft, Simplified answer: the model changed the script.
        let verdict = check(
            Kind::Refine,
            "這個會議記錄要寄給客戶",
            "这个会议记录要寄给客户",
            Tone::Normal,
        );
        assert!(!verdict.ok);
        assert_eq!(verdict.reason, "the model introduced simplified characters");
        // A Simplified draft that stays Simplified is the recogniser's own
        // output, and the caller converts it; the gate must not reject that.
        assert!(ok("这个会议记录要寄给客户", "这个会议记录要寄给客户"));
    }

    #[test]
    fn formal_rejects_casual_particles_but_normal_does_not() {
        let raw = "明天下午三點開會喔，記得帶合約啦";
        let refined = "明天下午三點開會喔，請記得攜帶合約啦";
        assert!(check(Kind::Refine, raw, refined, Tone::Normal).ok);
        let formal = check(Kind::Refine, raw, refined, Tone::Formal);
        assert!(!formal.ok);
        assert!(formal.reason.starts_with("casual particle"));
        // And a formal answer without particles passes.
        assert!(check(Kind::Refine, raw, "明天下午三點開會，請記得攜帶合約", Tone::Formal).ok);
    }

    #[test]
    fn an_edit_may_delete_lines_but_may_not_be_a_remark() {
        let draft = "明天下午三點跟小林開會\n討論第四季時程\n地點還沒確定";
        // Two of three lines gone: a deletion, which is the point.
        assert!(check(Kind::Edit, draft, "明天下午三點跟小林開會\n地點還沒確定", Tone::Normal).ok);
        // A remark that introduces itself IS caught. A bare "好的，我改好了"
        // is not judged here: which lines survived is the numbering parser's
        // business (`llm::check_edited_shape`), and only it knows the numbers.
        let remark = check(Kind::Edit, draft, "以下是修改後的版本", Tone::Normal);
        assert!(!remark.ok);
        assert!(remark.reason.starts_with("meta phrasing"));
        assert!(check(Kind::Edit, draft, "好的，我已經幫你改好了", Tone::Normal).ok);
        let essay = check(Kind::Edit, draft, &draft.repeat(4), Tone::Normal);
        assert!(!essay.ok);
        assert!(essay.reason.starts_with("far too long"));
    }

    #[test]
    fn kind_parsing_is_lenient() {
        assert_eq!(Kind::parse("edit"), Kind::Edit);
        assert_eq!(Kind::parse(" EDIT "), Kind::Edit);
        for raw in ["", "refine", "cleanup", "eidt"] {
            assert_eq!(Kind::parse(raw), Kind::Refine, "{raw:?}");
        }
    }
}
