//! Qwen2.5-Instruct (GGUF Q4_K_M, currently 1.5B) text refinement via llama.cpp.
//! Loaded on demand and dropped after each call so idle memory stays low.
//!
//! Refinement goal (Typeless-style):
//!  - Remove filler words and disfluencies.
//!  - Resolve self-corrections: keep only the final intended text.
//!  - Obey spoken editing instructions ("delete that sentence") and leave no
//!    trace of the instruction in the result.
//!  - Auto-format lists, steps, and key points into clean structure.
//!  - Keep the original language; switch only on an explicit translation request.
//!  - Deliver no trailing full stop: the text is inserted at a cursor, where one
//!    is noise. Interior punctuation and a question's `？` stay.

use std::num::NonZeroU32;
use std::path::Path;
use std::sync::OnceLock;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::sampling::LlamaSampler;

use crate::error::{EngineError, ErrorCode};

type Result<T, E = EngineError> = std::result::Result<T, E>;

const N_CTX: u32 = 2048;
const MAX_NEW_TOKENS: usize = 512;
/// Stage 1 of a two-stage refine rewrites the text, so it can need more room
/// than a condensed result does. Must stay under `N_CTX` with the prompt.
const STAGE1_MAX_TOKENS: usize = 1024;
/// Summaries run longer than refinement output and need the same context budget.
pub const SUMMARY_MAX_TOKENS: usize = 400;

static BACKEND: OnceLock<std::result::Result<LlamaBackend, String>> = OnceLock::new();

fn backend() -> Result<&'static LlamaBackend> {
    BACKEND
        .get_or_init(|| LlamaBackend::init().map_err(|e| e.to_string()))
        .as_ref()
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("llama backend init: {e}")))
}

/// Stage 1 of the two-stage refine: pull the meaning out of the spoken words
/// BEFORE touching structure. Deliberately tiny -- a 1.5B model follows two or
/// three rules far more reliably than a long rule list.
const UNDERSTAND_SYSTEM: &str = "把下面這段口語改寫成通順、完整的書面語。只輸出改寫後的內容。\n\
- 保留所有資訊：不要漏掉，也不要新增。\n\
- 省略的主詞，依上下文補上。\n\
- 明顯聽錯的詞，改成合理的詞。\n\
- 語言跟原文相同，不要翻譯。";

/// Stage 2 (and the single-pass) prompt. It says "rewrite this spoken text into
/// written text", NOT "summarize it" -- "整理成重點" made the model drop whole
/// requirements and emit a one-line summary of what the speaker wanted. Short on
/// purpose: the worked examples teach the format better than a longer rule list,
/// and a small model imitates them more reliably than it follows a rule.
/// Traditional Chinese is enforced afterwards in code, not here.
///
/// The three rules that follow from reported failures, each stated once:
/// * a spoken instruction inside the draft is APPLIED and then removed;
/// * the language is the speaker's, and only an explicit translation request
///   changes it -- a Chinese draft that mentions an English product is still
///   Chinese, and a question is not a reason to switch either (the old wording
///   only said "explicitly asks for another language", and a question with
///   English terms in it was read as such a request);
/// * no full stop at the very end. Only the final character is spoken about, so
///   interior punctuation is not touched.
const REFINE_SYSTEM: &str = "把使用者的口語改寫成通順的書面文字，只輸出改寫後的內容。\
不要摘要、不要漏掉任何一件事；重複的只留一次；刪掉口頭禪和多餘的字；\
只有一個重點就寫一句，多個重點就一行一個、行首加「• 」；\
數字、時間、名字照原樣保留；問句保持問句。\
話裡夾的指令要照著做（「把前面那句刪掉」「時間改成四點」這種刪掉、換掉、調順序的要求），\
指令本身不要出現在結果裡。\
語言跟使用者講的一樣，講中文就整段中文，中間的英文產品名照留；\
不要因為句子裡有英文、或因為是問句，就換成別的語言。\
只有明確要求翻譯時才換語言（例如「翻成英文」「用日文寫」），而且要整段都換，不要只換一半。\
最後不要加句號（。或 .），問句結尾的？要保留，句子中間的標點照常。";

/// Worked pairs for translation. Same reasoning as the refine examples: two
/// short rules plus the shape, because a 1.5B model copies what it sees far
/// more reliably than it follows grammar notes.
const TRANSLATE_SYSTEM_TO_EN: &str =
    "把下面這段話翻譯成自然、道地的英文。只輸出翻譯結果，不要解釋，也不要加註。\
     數字、時間、人名與專有名詞照原樣保留。";

const TRANSLATE_SYSTEM_TO_ZH: &str =
    "把下面這段話翻譯成自然、道地的繁體中文。只輸出翻譯結果，不要解釋，也不要加註。\
     數字、時間、人名與專有名詞照原樣保留。";

const TRANSLATE_EXAMPLES_TO_EN: [(&str, &str); 2] = [
    (
        "明天早上十點開會，記得帶筆電，不要遲到。",
        "There's a meeting at 10 tomorrow morning. Remember to bring your laptop, and don't be late.",
    ),
    (
        "這個功能先做 A/B test，再決定要不要上線。",
        "Let's A/B test this feature first, then decide whether to ship it.",
    ),
];

const TRANSLATE_EXAMPLES_TO_ZH: [(&str, &str); 2] = [
    (
        "We should ship this next week because the client is waiting.",
        "我們應該下週上線，因為客戶在等。",
    ),
    (
        "Can you send me the report before the meeting?",
        "你可以在開會前把報告寄給我嗎？",
    ),
];

/// Worked pairs for the few-shot turns: (spoken draft, cleaned result).
///
/// They are split by LANGUAGE and selected per draft: a small model copies the
/// output language of the example nearest the real input, so a Chinese draft
/// next to an English answer comes back fully translated into English (observed,
/// deterministically -- decoding is greedy). Each pair teaches the same shape:
/// keep every fact, drop the filler, keep the question a question.
///
/// Two further conventions are taught by the pairs rather than by the rules,
/// because a 1.5B model imitates what it sees:
/// * A spoken editing instruction ("把前面那句刪掉", "時間改成四點") is applied,
///   and the output is the edited text with no trace of the instruction. One
///   pair per shape: a deletion and a replacement.
/// * No pair ends in a full stop, and the pair that is a question keeps its `？`.
///   `tidy_output` enforces the same shape in code, so the examples only have to
///   agree with it rather than carry the rule alone. The English deletion pair
///   keeps an INTERIOR period on purpose, so "no full stop" is not learned as
///   "no periods at all".
///
/// What is NOT here on purpose: a translation pair. An English answer inside the
/// Chinese set is exactly the pairing that flips a Chinese draft into English;
/// translation has its own prompt (`TRANSLATE_EXAMPLES_*`, reached only when the
/// app is asked to translate).
const REFINE_EXAMPLES_ZH: [(&str, &str); 5] = [
    (
        "嗯那個下週三下午三點半你有空嗎，我要跟你討論那個八十萬的案子，然後記得帶合約，喔對你有空嗎",
        "下週三下午三點半你有空嗎？我要跟你討論八十萬的案子，記得帶合約",
    ),
    // A repeated clause followed by a DIFFERENT short clause: the repeat goes,
    // the new clause stays. Without this pair the model treated the whole
    // repeated sentence -- including the fresh demand hanging off its end -- as
    // one repeat and dropped it ("不要遲到" was silently lost in testing).
    (
        "嗯我明天下午要去拜訪客戶然後記得帶名片喔對我明天下午要去拜訪客戶不要忘記",
        "我明天下午要去拜訪客戶，記得帶名片，不要忘記",
    ),
    // The instruction names the clause to drop ("把地點那句刪掉") and the rest
    // is kept, including the reason that follows it. The instruction itself is
    // gone from the answer.
    (
        "下週三下午三點半開會，地點在二樓會議室，把地點那句刪掉，我還沒確定",
        "下週三下午三點半開會，地點還沒確定",
    ),
    // Replacement: the old value does not survive anywhere, and the English term
    // the speaker used stays English inside an otherwise Chinese answer.
    ("明天下午兩點跟客戶 sync，時間改成四點", "明天下午四點跟客戶 sync"),
    // A Chinese sentence carrying English product names is still Chinese. This
    // pair exists because the model answered such a draft in English; the rule
    // alone did not stop it.
    (
        "那個 Slack 的通知先關掉，還有 Figma 的連結記得更新",
        "Slack 的通知先關掉，Figma 的連結記得更新",
    ),
];

const REFINE_EXAMPLES_EN: [(&str, &str); 4] = [
    (
        "um so I think uh we should probably ship this you know next week because the client is waiting",
        "We should ship this next week because the client is waiting",
    ),
    // Teaches that a question comes back as a question. Without it the model
    // turned "can you send the report before then?" into "Please send the
    // report before then." -- an ask came back as an order (observed).
    (
        "um can you uh send me the report before the meeting? the report before the meeting",
        "Can you send me the report before the meeting?",
    ),
    // Deletion, with an interior period kept: the room clause goes, the fact the
    // speaker added afterwards stays, and only the END of the answer is bare.
    (
        "um the kickoff is Wednesday at 3:30 in the second-floor room, actually delete the room bit, I haven't confirmed it, so the room is still open",
        "The kickoff is Wednesday at 3:30. The room is still open",
    ),
    // Replacement.
    (
        "uh the client meeting is at 2 tomorrow, make that 4",
        "The client meeting is at 4 tomorrow",
    ),
];

/// System line for the voice-edit pass: the user dictates an instruction that
/// has to be applied to text the app already produced, which is a different job
/// from refinement (there is no speech to clean, and the text already has the
/// shape the user is looking at).
///
/// The draft arrives NUMBERED, and the model is told to keep the numbers it was
/// given instead of renumbering its answer. Two reasons, both structural:
/// * The numbering is the one thing the code and the user agree on. "把第二點改
///   成…" is only checkable against lines the code numbered itself, so the model
///   is not allowed to invent a numbering of its own that the code cannot verify.
/// * A deletion only stays identifiable this way. If the model renumbered, the
///   survivors of a deletion would come back shifted (`1. a\n2. c` for a deleted
///   `b`) and look exactly like an edit that rewrote every line, so a mangled
///   answer could not be told from a correct one.
///
/// The delete rule is stated with the number: the deleted line simply disappears
/// from the answer (there is no blank numbered line to parse).
const EDIT_SYSTEM: &str = "使用者已經打好一份文字，每一行都編好號了。\
使用者會說一句要怎麼改的指令，你要照著改寫整份文字，只輸出改寫後的內容。\
輸出要保留原本的編號：改哪一行就只動那一行，沒改到的行照原樣輸出、不要重新編號，\
也不要只輸出改過的那一行；被刪掉的那一行整行都不要出現。\
不要加說明、不要加標題、不要翻譯。\
使用者的訊息裡，第一行是指令，空一行之後才是要改的文字。";

/// Worked pairs for the voice-edit pass: `(instruction + blank line + numbered
/// draft, edited result)`. Few-shot for the same reason as everywhere else in
/// this file -- a 1.5B model copies the shape it just saw far more reliably than
/// it follows a rule list -- and split by language because a Chinese draft next
/// to an English answer comes back translated.
///
/// Each set carries the two shapes a reader would otherwise have to guess: a
/// replacement that keeps the untouched lines byte-identical, and a deletion
/// whose line is gone rather than blanked. The pairs also show that the answer
/// repeats EVERY line and not just the changed one, which the rule alone was not
/// enough to carry.
const EDIT_EXAMPLES_ZH: [(&str, &str); 2] = [
    (
        "把第二點改成禮拜五下午兩點\n\n1. 跟客戶確認規格\n2. 下週三下午三點開會\n3. 把報價單寄出去",
        "1. 跟客戶確認規格\n2. 禮拜五下午兩點\n3. 把報價單寄出去",
    ),
    // The deleted item's number disappears with it: the answer is two lines, not
    // three with a hole where the third was.
    (
        "第三句刪掉\n\n1. 先確認規格\n2. 再找供應商\n3. 最後排時程",
        "1. 先確認規格\n2. 再找供應商",
    ),
];

const EDIT_EXAMPLES_EN: [(&str, &str); 2] = [
    (
        "change the second one to Friday at 2 pm\n\n1. Confirm the spec with the client\n2. Meeting on Wednesday at 3 pm\n3. Send the quote",
        "1. Confirm the spec with the client\n2. Friday at 2 pm\n3. Send the quote",
    ),
    (
        "delete the third one\n\n1. Confirm the spec\n2. Find a supplier\n3. Set the schedule",
        "1. Confirm the spec\n2. Find a supplier",
    ),
];

/// True for the CJK ranges that decide "this draft is Chinese".
pub(crate) fn has_cjk(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(c as u32,
            0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x3040..=0x30ff | 0xac00..=0xd7af)
    })
}

/// Each section is a separate model call; the program owns the structure.
/// Two system lines, picked by the transcript's language: an English system line
/// makes a 1.5B model answer in English even when every worked example is
/// Chinese and the transcript is Chinese (measured), and the reverse holds. The
/// section instructions stay English in both cases -- what flips the output
/// language is this line, not the instruction.
const SUMMARY_SYSTEM: &str = "You summarize meeting transcripts written in Chinese or English. \
Answer in the same language as the transcript. Use only facts from the transcript. Keep the answer short.";
const SUMMARY_SYSTEM_ZH: &str = "用繁體中文回答。只能使用逐字稿裡有的事實，不要編造或補充。回答要簡短。";

pub const SECTION_SUMMARY: &str = "Write a short summary of this meeting in up to 3 sentences.";
pub const SECTION_DECISIONS: &str = "Write the main decision this meeting made, in one or two \
sentences. Write the decision itself only: no names and no assignments of work. Use only what \
the transcript says. If there are none, reply with exactly: none";
/// The Chinese form of the 決議 instruction. Kept separate for a measured reason,
/// not for its own sake: with the English instruction, a Chinese transcript that
/// is mostly imperatives leaked the assignments into the decision
/// (`珮婷整理使用者訪談紀錄`, `問設計公司報價`) with the very examples that are
/// clean under the Chinese wording. The system line still decides the OUTPUT
/// language; this decides what the model thinks it is being asked for.
///
/// The English instruction's "nothing here" marker is `none` while this one is
/// `无`, and that is not cosmetic: with `无` there Qwen3.5-2B answered an English
/// transcript's 決議 in Simplified Chinese (`会议决定将新首页…`), because that one
/// Chinese character was the only non-English text in the whole prompt. `none`
/// puts the answer back in English. (An English example pair was tried instead
/// and reverted: it made the same model list the meeting's assignments under
/// 決議.) `parse_no_decision` accepts both markers, so either wording is read
/// correctly downstream.
///
/// The English instruction's "nothing here" marker stays `无` on purpose. Making
/// it `none` so an English chat could answer the marker was tried and reverted:
/// the same one-word change made a real English meeting (migration transcript)
/// start listing its assignments under 決議. A single-parameter change moving a
/// 1.5B model's output like that is the reason each section's wording here is
/// pinned as measured rather than as written.
pub const SECTION_DECISIONS_ZH: &str = "用一到兩句話寫出這場會議最後作成的主要決定。只寫\
決定本身，不要提到人，也不要寫誰要做什麼。只能根據逐字稿。如果沒有決定，只回答：無";
pub const SECTION_ACTIONS: &str = "List the action items as '- owner: task (deadline)'. One per \
line, each starting with '- '. Leave the owner or the deadline out when the transcript does not \
give one; never invent either. Use only what the transcript says. If there are none, reply with \
exactly: 无";

/// Worked pairs `(transcript, answer)` for each section, split by language and
/// selected per transcript: a 1.5B model copies the output language of the
/// example nearest the input, so a Chinese transcript next to an English answer
/// comes back fully translated into English (observed -- decoding is greedy).
/// The worked shape also teaches far more than the wording of the instruction,
/// which is the same reason the refine prompt is few-shot.
///
/// The 待辦 pairs carry an item with no stated deadline, and one with no named
/// owner, so neither gets invented to fit the pattern.
const SUMMARY_EXAMPLES_ZH: [(&str, &str); 1] = [(
    "今天會議主要討論上線時間跟客服準備。大家討論之後決定下週三上線，由小明負責部署。怡君要在下週五以前把客服的 SOP 生出來。行銷的部分先不動，等產品穩定再說。",
    "會議決定下週三上線，由小明負責部署。怡君負責在下週五前完成客服 SOP。行銷活動暫緩，等產品穩定後再討論。",
)];

const SUMMARY_EXAMPLES_EN: [(&str, &str); 1] = [(
    "Most of the meeting was about the launch date and support readiness. We decided to ship next Wednesday, with Xiao Ming on deployment. Yi Jun will write the support SOP by Friday. Marketing stays on hold until the product is stable.",
    "The team decided to ship next Wednesday, with Xiao Ming handling deployment. Yi Jun will finish the support SOP by Friday. Marketing stays on hold until the product is stable.",
)];

/// The 決議 pairs are deliberately made of decisions ONLY -- no assignment appears
/// anywhere in them -- and are used for Chinese transcripts only. Both properties
/// are measured, not stylistic:
///
/// * With no example at all the model answers the single most salient decision
///   and stops; a meeting that made two loses one. Two decision-only pairs fix
///   that (`決定廣告預算砍三成、人員不新增正職改用約聘，行銷先不動。`).
/// * Any example at all -- including a decision-only one, and including one whose
///   answer shows an assignment being left out -- puts a 1.5B model into
///   "enumerate the meeting" mode on an ENGLISH transcript, and it then lists the
///   assignments too (measured: Sarah/Tom/Everyone leaked, three for three, with
///   two different English example sets). With no English example it returns the
///   decision alone, both of them, every time. Hence the empty set.
/// * A Chinese example also leaks on a transcript that is mostly imperatives,
///   but two excerpts beat none there overall, so Chinese keeps them.
///
/// The earlier design kept the assignments IN the 決議 examples and subtracted the
/// 待辦 list afterwards. That was abandoned: the subtraction deleted genuine
/// decisions (a decision and its action item share too many characters to tell
/// apart), and it could empty the section outright.
const DECISION_EXAMPLES_ZH: [(&str, &str); 2] = [
    (
        "早上先討論預算，最後決定廣告預算砍三成。人員的部分也決定不新增正職，改用約聘。行銷的部分決定先不動，等產品穩定再說。",
        "決定廣告預算砍三成、人員不新增正職改用約聘，行銷先不動。",
    ),
    (
        "我們討論了客服準備，決定先補兩個人。另外也決定客服的服務時間延長到晚上九點。",
        "決定先補兩個人，客服服務時間延長到晚上九點。",
    ),
    // A pair for "nothing was decided" was tried here and REMOVED: it did not
    // stop a chat about the weather from producing a decision, and it made the
    // mixed case leak people back into 決議 ("…整理由珮婷負責"). The model cannot
    // be taught "no decision exists" without giving up the rest; see the note on
    // the section in state::tests and the known limitation in the summary docs.
];

/// Empty on purpose -- an English example pair was measured twice and both
/// times it made the model enumerate the meeting's assignments under 決議. The
/// output-language problem that the empty set used to cause is fixed in the
/// instruction's marker instead (see SECTION_DECISIONS): the prompt for an
/// English transcript now contains no Chinese characters at all, so the 決議
/// comes back in English without an example teaching it to list tasks.
const DECISION_EXAMPLES_EN: [(&str, &str); 0] = [];

const ACTION_EXAMPLES_ZH: [(&str, &str); 4] = [
    (
        "小華你明天把報價單寄給客戶，然後我下週一以前把合約草稿給法務。",
        "- 小華：明天把報價單寄給客戶\n- 我：下週一以前把合約草稿給法務",
    ),
    (
        "那上線時間就定下週三，小明負責部署。怡君你下週五以前把客服的 SOP 生出來。",
        "- 小明：下週三負責部署上線\n- 怡君：下週五以前生出客服的 SOP",
    ),
    // No stated deadline and no named owner for the second item: neither gets
    // invented to match the first line's shape. The second item is written so
    // that no individual is addressed -- "everyone, please..." reads as an
    // owner to a 1.5B model and it starts prefixing topics with a colon.
    (
        "測試的部分要麻煩怡君盯一下，這個到下週三。另外上週的週報要補上，這個沒有期限。",
        "- 怡君：盯測試進度，到下週三\n- 補上上週的週報",
    ),
    // Nothing is assigned here: the first line is the meeting's subject, the
    // second a decision no one was given -- neither is an action item, and the
    // two real items get no "owner:" prefix when no owner was named. Without
    // this the model reads the first lines' shape as mandatory and promotes the
    // subject to an owner, a topic becoming a person ("首頁：今天先上線",
    // "每月：固定開一次檢討會") -- an invented owner rather than a missing one.
    (
        "官網改版討論。首頁今天先上線，其他頁面之後再說。珮婷你整理一下使用者的訪談紀錄。另外首頁的文案今天要換掉。",
        "- 珮婷：整理使用者的訪談紀錄\n- 換掉首頁的文案",
    ),
];

const ACTION_EXAMPLES_EN: [(&str, &str); 4] = [
    (
        "Xiao Ming, send the quote to the client tomorrow. And I'll get the contract draft to legal by Monday.",
        "- Xiao Ming: send the quote to the client tomorrow\n- Me: get the contract draft to legal by Monday",
    ),
    (
        "So the launch date is next Wednesday, with Xiao Ming on deployment. Yi Jun, get me the support SOP by Friday.",
        "- Xiao Ming: handle the launch deployment on Wednesday\n- Yi Jun: write the support SOP by Friday",
    ),
    (
        "Could you keep an eye on the testing, Yi Jun? That one's due Wednesday. And last week's reports still need catching up -- no deadline for that.",
        "- Yi Jun: keep an eye on testing progress, due Wednesday\n- Catch up on last week's reports",
    ),
    (
        "The website relaunch came up. The homepage ships today and the rest of the pages later. Yi Ting, could you sort out the user interviews? And the homepage copy needs replacing today.",
        "- Yi Ting: sort out the user interviews\n- Replace the homepage copy",
    ),
];

fn chatml(system: &str, user: &str) -> String {
    format!("<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n")
}

/// ChatML for a few-shot exchange: the worked pairs arrive as previous
/// user/assistant turns and the real draft is the LAST user turn, so the model
/// continues from a pattern it just saw instead of from a rule list it can
/// parrot back. (Greedy decoding made that echo reproducible, not random.)
fn chatml_few_shot(system: &str, examples: &[(&str, &str)], user: &str) -> String {
    let mut out = String::with_capacity(1024);
    out.push_str("<|im_start|>system\n");
    out.push_str(system);
    out.push_str("<|im_end|>\n");
    for (draft, answer) in examples {
        out.push_str("<|im_start|>user\n");
        out.push_str(draft);
        out.push_str("<|im_end|>\n<|im_start|>assistant\n");
        out.push_str(answer);
        out.push_str("<|im_end|>\n");
    }
    out.push_str("<|im_start|>user\n");
    out.push_str(user);
    out.push_str("<|im_end|>\n<|im_start|>assistant\n");
    out
}

/// Appends a vocabulary hint to the system line. It goes in the system message
/// and not the user turn so the model cannot mistake it for the draft.
fn system_with_hint(base: &str, keywords_hint: &str) -> String {
    if keywords_hint.trim().is_empty() {
        base.to_string()
    } else {
        format!("{base}\n{keywords_hint}")
    }
}

/// Prompt for cleaning one transcript chunk. `keywords_hint` adds preferred
/// vocabulary (names, products, jargon) so the model spells them the user's way.
pub fn refine_prompt_with_hint(text: &str, keywords_hint: &str) -> String {
    let examples: &[(&str, &str)] = if has_cjk(text) {
        &REFINE_EXAMPLES_ZH
    } else {
        &REFINE_EXAMPLES_EN
    };
    chatml_few_shot(&system_with_hint(REFINE_SYSTEM, keywords_hint), examples, text)
}

/// Prompt for cleaning one transcript chunk.
pub fn refine_prompt(text: &str) -> String {
    refine_prompt_with_hint(text, "")
}

/// Prompt for the "understand the spoken words first" pass.
pub fn understand_prompt(text: &str) -> String {
    chatml(UNDERSTAND_SYSTEM, text)
}

/// Prompt for one summary section over a transcript (or a chunk of notes during map-reduce).
///
/// Every section gets few-shot turns, with the example set picked by the
/// transcript's own language -- see the examples for why both matter.
pub fn summary_prompt(instruction: &str, text: &str) -> String {
    let chinese = has_cjk(text);
    // Only the 決議 instruction changes with the transcript's language -- see
    // SECTION_DECISIONS_ZH.
    let instruction = if chinese && instruction == SECTION_DECISIONS {
        SECTION_DECISIONS_ZH
    } else {
        instruction
    };
    let examples: &[(&str, &str)] =
        if instruction == SECTION_DECISIONS || instruction == SECTION_DECISIONS_ZH {
            if chinese { &DECISION_EXAMPLES_ZH } else { &DECISION_EXAMPLES_EN }
        } else if instruction == SECTION_ACTIONS {
            if chinese { &ACTION_EXAMPLES_ZH } else { &ACTION_EXAMPLES_EN }
        } else if chinese {
            &SUMMARY_EXAMPLES_ZH
        } else {
            &SUMMARY_EXAMPLES_EN
        };
    let system = if chinese { SUMMARY_SYSTEM_ZH } else { SUMMARY_SYSTEM };
    chatml_summary_few_shot(system, instruction, examples, text)
}

/// ChatML for a summary section, with worked `(transcript, answer)` pairs under
/// the SAME instruction the real transcript is given -- so the model learns the
/// output shape and language rather than the instruction's wording.
fn chatml_summary_few_shot(system: &str, instruction: &str, examples: &[(&str, &str)], text: &str) -> String {
    let mut out = String::with_capacity(2048);
    out.push_str("<|im_start|>system\n");
    out.push_str(system);
    out.push_str("<|im_end|>\n");
    for (transcript, answer) in examples {
        out.push_str("<|im_start|>user\n");
        out.push_str(instruction);
        out.push_str("\n\nTranscript:\n");
        out.push_str(transcript);
        out.push_str("<|im_end|>\n<|im_start|>assistant\n");
        out.push_str(answer);
        out.push_str("<|im_end|>\n");
    }
    out.push_str("<|im_start|>user\n");
    out.push_str(instruction);
    out.push_str("\n\nTranscript:\n");
    out.push_str(text);
    out.push_str("<|im_end|>\n<|im_start|>assistant\n");
    out
}

/// Load the model, run greedy generation on `prompt`, and return the decoded text.
pub fn generate(model_path: &Path, prompt: &str) -> Result<String> {
    generate_with(model_path, prompt, MAX_NEW_TOKENS)
}

/// Like `generate`, with an explicit cap on generated tokens.
pub fn generate_with(model_path: &Path, prompt: &str, max_new_tokens: usize) -> Result<String> {
    let be = backend()?;
    let model = LlamaModel::load_from_file(be, model_path, &LlamaModelParams::default())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", model_path.display())))?;
    generate_in(&model, prompt, max_new_tokens)
}

/// The assistant turn we end every prompt with.
const ASSISTANT_TURN: &str = "<|im_start|>assistant\n";
/// An empty reasoning block, already closed. Generation continues after it.
///
/// This is byte-for-byte what the Qwen3.5 chat template emits when thinking is
/// off, so the model treats it as the prefill it was trained on and answers
/// straight away. The markers are `<think>`/`</think>` -- an earlier version
/// used a bare " thinking" that the template never contained, so the block was
/// never inserted and the model emitted its own reasoning into the answer.
const EMPTY_THINK_BLOCK: &str = "<think>\n\n</think>\n\n";

/// Qwen3/Qwen3.5 chat templates open a reasoning block. We build prompts by
/// hand rather than applying the template, so nothing closes that block for us:
/// the model opens `<think>` itself and streams its reasoning into the answer.
/// Pre-filling a closed, empty block keeps generation inside the answer.
fn insert_think_block(prompt: &str) -> std::borrow::Cow<'_, str> {
    match prompt.rfind(ASSISTANT_TURN) {
        Some(i) => {
            let at = i + ASSISTANT_TURN.len();
            let mut out = String::with_capacity(prompt.len() + EMPTY_THINK_BLOCK.len());
            out.push_str(&prompt[..at]);
            out.push_str(EMPTY_THINK_BLOCK);
            out.push_str(&prompt[at..]);
            std::borrow::Cow::Owned(out)
        }
        None => std::borrow::Cow::Borrowed(prompt),
    }
}

/// Whether this model's own chat template has a reasoning block.
///
/// Read from the GGUF metadata instead of a filename, so Qwen2.5 -- which has
/// none, and would echo the tags back as text -- is left alone. The test looks
/// for the two things the template actually contains: the `enable_thinking`
/// switch and the `<think>` marker.
fn template_uses_thinking(model: &LlamaModel) -> bool {
    model
        .meta_val_str("tokenizer.chat_template")
        .map(|t| t.contains("enable_thinking") || t.contains("<think>"))
        .unwrap_or(false)
}

/// Remove a reasoning block the model emitted anyway, and the blank lines it
/// leaves behind.
///
/// The prefill normally prevents this, but the model can still open a block
/// when the prefill did not apply, and a stray `<think>` in a meeting summary
/// is worse than a useless paragraph.
pub fn strip_reasoning(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find("<think>") {
        out.push_str(&rest[..open]);
        rest = match rest[open..].find("</think>") {
            Some(close) => &rest[open + close + "</think>".len()..],
            // Unclosed block: everything after it was reasoning.
            None => return out.trim().to_string(),
        };
    }
    out.push_str(rest);
    out.trim().to_string()
}

fn with_thinking_disabled<'a>(model: &LlamaModel, prompt: &'a str) -> std::borrow::Cow<'a, str> {
    if template_uses_thinking(model) {
        insert_think_block(prompt)
    } else {
        std::borrow::Cow::Borrowed(prompt)
    }
}

/// Generate on an already-loaded model. A fresh context per call keeps the two
/// stages of a two-stage refine from sharing a KV cache.
fn generate_in(model: &LlamaModel, prompt: &str, max_new_tokens: usize) -> Result<String> {
    let be = backend()?;
    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(NonZeroU32::new(N_CTX))
        .with_n_batch(N_CTX);
    let mut ctx = model
        .new_context(be, ctx_params)
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("llama context: {e}")))?;

    // parse_special = true so "<|im_start|>" etc. become control tokens, not text.
    let vocab = model.vocab();
    let prompt = with_thinking_disabled(model, prompt);
    let tokens = vocab.tokenize(prompt.as_bytes(), false, true);
    if tokens.len() >= N_CTX as usize {
        return Err(EngineError::new(ErrorCode::InvalidArg, "transcript too long for one LLM pass"));
    }

    let mut batch = LlamaBatch::new(N_CTX as usize, 1);
    let last = tokens.len() as i32 - 1;
    for (i, t) in tokens.iter().enumerate() {
        batch
            .add(*t, i as i32, &[0], i as i32 == last)
            .map_err(|e| EngineError::new(ErrorCode::Inference, format!("batch add: {e}")))?;
    }
    ctx.decode(&mut batch)
        .map_err(|e| EngineError::new(ErrorCode::Inference, format!("prompt decode: {e}")))?;

    let mut sampler = LlamaSampler::greedy();
    let mut pos = tokens.len() as i32;
    let mut out = Vec::new();
    for _ in 0..max_new_tokens {
        let token = sampler.sample(&ctx, batch.n_tokens() - 1);
        sampler.accept(token);
        if vocab.is_eog(token) {
            break;
        }
        out.extend_from_slice(&vocab.token_to_piece(token, false, None));

        batch.clear();
        batch
            .add(token, pos, &[0], true)
            .map_err(|e| EngineError::new(ErrorCode::Inference, format!("batch add: {e}")))?;
        ctx.decode(&mut batch)
            .map_err(|e| EngineError::new(ErrorCode::Inference, format!("decode: {e}")))?;
        pos += 1;
    }
    Ok(strip_reasoning(&String::from_utf8_lossy(&out)))
}

/// Characters a model may wrap its whole answer in. Both halves of each pair are
/// listed so a mismatched pair (a `"` opened and a `」` closed) is cleaned too.
fn is_wrapping_quote(c: char) -> bool {
    matches!(c, '"' | '\'' | '“' | '”' | '「' | '」' | '『' | '』')
}

/// Drop wrapping quotation marks, and the whitespace around them. Looped, so a
/// doubly-wrapped answer is unwrapped as far as it goes; a lone quote character
/// is left alone instead of being eaten.
fn strip_wrapping_quotes(text: &str) -> &str {
    let mut rest = text.trim();
    loop {
        let trimmed = rest.trim();
        let (first, last) = match (trimmed.chars().next(), trimmed.chars().next_back()) {
            (Some(first), Some(last)) => (first, last),
            _ => return trimmed,
        };
        // `trimmed.len() <= first.len_utf8()` covers a single-character answer
        // that happens to be a quote.
        if !is_wrapping_quote(first) || !is_wrapping_quote(last) || trimmed.len() <= first.len_utf8() {
            return trimmed;
        }
        rest = &trimmed[first.len_utf8()..trimmed.len() - last.len_utf8()];
    }
}

/// Strip ONE trailing full stop: `。`, `.` or `．`.
///
/// Deliberately literal -- only the last character is judged, so an interior
/// period stays, and an ellipsis (`…`), a question mark, a bang, a colon or a
/// semicolon is left as the speaker's punctuation. No abbreviation lookup and no
/// `...` detection: the model emits `…` for an ellipsis, and the product rule is
/// about the final character, not about guessing words.
fn strip_trailing_full_stop(text: &str) -> &str {
    match text.chars().next_back() {
        Some(c @ ('。' | '.' | '．')) => text[..text.len() - c.len_utf8()].trim_end(),
        _ => text,
    }
}

/// At most one blank line between blocks: a run of three or more newlines
/// becomes two. Single newlines (the line-per-point form) are untouched.
fn collapse_blank_lines(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run = 0usize;
    for c in text.chars() {
        if c == '\n' {
            run += 1;
            if run <= 2 {
                out.push(c);
            }
        } else {
            run = 0;
            out.push(c);
        }
    }
    out
}

/// Drop a bullet marker from an answer that is a single line.
///
/// The model likes to answer a plain dictated sentence with "• 下週三開會". One
/// line is not a list, so the marker is noise; a real list (two or more lines)
/// keeps its bullets.
fn strip_lone_bullet(text: &str) -> &str {
    let trimmed = text.trim();
    if trimmed.contains('\n') {
        return trimmed;
    }
    for marker in ["• ", "- ", "* ", "・"] {
        if let Some(rest) = trimmed.strip_prefix(marker) {
            return rest.trim_start();
        }
    }
    trimmed
}

/// Formatting pass over a refinement result: belt and braces beside the prompt
/// rule, because a 1.5B model does not reliably obey a formatting instruction.
///
/// Refine output only. A summary is a document whose bullets may legitimately end
/// in a period, and it is not inserted at a cursor, so it is NOT tidied.
fn tidy_output(text: &str) -> String {
    let unquoted = strip_wrapping_quotes(text);
    let single = strip_lone_bullet(unquoted);
    collapse_blank_lines(strip_trailing_full_stop(single))
}

/// Ways a speaker asks for another language, and the target `translate_prompt`
/// can actually deliver. `weak` marks phrases that are ordinary words as often
/// as they are instructions ("我用英文寫"), so those also need a cue next to them.
const TRANSLATION_TRIGGERS: &[(&str, &str, bool)] = &[
    ("翻成英文", "en", true),
    ("翻譯成英文", "en", true),
    ("翻成英語", "en", true),
    ("譯成英文", "en", true),
    ("轉成英文", "en", true),
    ("改成英文", "en", true),
    ("整理成英文", "en", true),
    ("翻成中文", "zh", true),
    ("翻譯成中文", "zh", true),
    ("翻成繁體", "zh", true),
    ("譯成中文", "zh", true),
    ("轉成中文", "zh", true),
    ("改成中文", "zh", true),
    ("整理成中文", "zh", true),
    ("translate into english", "en", true),
    ("translate to english", "en", true),
    ("translate into chinese", "zh", true),
    ("用英文", "en", false),
    ("in english", "en", false),
    ("用中文", "zh", false),
    ("in chinese", "zh", false),
];

/// Words that make a weak trigger read as an instruction rather than content.
const TRANSLATION_CUES: &[&str] = &[
    "請", "幫", "把", "這句", "這段", "上面", "下面", "剛剛", "整理", "回答", "翻譯", "改成",
];

fn clause_bounds(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, c) in text.char_indices() {
        if matches!(c, '，' | ',' | '。' | '！' | '!' | '？' | '?' | '；' | ';' | '：' | ':' | '\n') {
            out.push(&text[start..i]);
            start = i + c.len_utf8();
        }
    }
    out.push(&text[start..]);
    out
}

fn has_translation_cue(clause: &str) -> bool {
    TRANSLATION_CUES.iter().any(|cue| clause.contains(cue))
}

/// Split a draft into (what to refine, language to translate into).
///
/// A translation request is obeyed by two deterministic steps -- refine in the
/// speaker's own language, then translate the result -- instead of by asking the
/// model to switch language mid-answer. The model did exactly that when the rule
/// was left to it: a Chinese question containing an English product name stayed
/// English, and the reverse request was ignored. Only `en` and `zh` are handled
/// here because those are the directions `translate_prompt` has examples for.
fn detect_translation_request(text: &str) -> Option<(&'static str, String)> {
    let mut target: Option<&'static str> = None;
    let mut kept: Vec<&str> = Vec::new();
    for clause in clause_bounds(text) {
        let lowered = clause.to_lowercase();
        let mut is_instruction = false;
        for (phrase, lang, strong) in TRANSLATION_TRIGGERS {
            if !lowered.contains(phrase) {
                continue;
            }
            if !strong && (!has_translation_cue(clause) || clause.chars().count() > 16) {
                continue;
            }
            target = Some(*lang);
            is_instruction = true;
            break;
        }
        if !is_instruction && !clause.trim().is_empty() {
            kept.push(clause.trim());
        }
    }
    let target = target?;
    if kept.is_empty() {
        // Nothing left to translate, so this was not a request about a draft.
        return None;
    }
    let cjk = kept.iter().any(|c| c.chars().any(|ch| ('\u{4e00}'..='\u{9fff}').contains(&ch)));
    let joiner = if cjk { "，" } else { ", " };
    Some((target, kept.join(joiner)))
}

/// Refine one transcript chunk with optional keywords hint.
pub fn refine(model_path: &Path, text: &str) -> Result<String> {
    refine_with_keywords(model_path, text, "")
}

/// Refine with a keywords hint, which is added to the system line so the model
/// can spell names and jargon the way the user does.
///
/// The result is passed through `tidy_output`: the delivery formatting rules
/// (no wrapping quotes, no trailing full stop) hold even when the model ignores
/// the prompt.
pub fn refine_with_keywords(model_path: &Path, text: &str, keywords_hint: &str) -> Result<String> {
    let Some((target, source)) = detect_translation_request(text) else {
        let raw = generate(model_path, &refine_prompt_with_hint(text, keywords_hint))?;
        return Ok(tidy_output(&raw));
    };
    // One load for both passes: refine in the speaker's language, then translate.
    let be = backend()?;
    let model = LlamaModel::load_from_file(be, model_path, &LlamaModelParams::default())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", model_path.display())))?;
    let refined = tidy_output(&generate_in(&model, &refine_prompt_with_hint(&source, keywords_hint), MAX_NEW_TOKENS)?);
    translate_in(&model, &refined, target)
}

/// Translate with an already-loaded model, falling back to the refined text when
/// the translation comes back empty.
fn translate_in(model: &LlamaModel, text: &str, target: &str) -> Result<String> {
    let raw = generate_in(model, &translate_prompt(text, target), MAX_NEW_TOKENS)?;
    let out = tidy_output(&raw);
    if out.trim().is_empty() {
        return Ok(text.to_string());
    }
    Ok(out)
}

/// Two-stage refine: first understand the speech, then tidy it.
///
/// Both stages run against ONE loaded model, so the extra quality costs a second
/// generation rather than a second model load. Stage 1 is skipped as an input if
/// it comes back empty, and stage 2 falls back to stage 1's output. Both returns
/// go through `tidy_output`.
pub fn refine_two_stage(model_path: &Path, text: &str, keywords_hint: &str) -> Result<String> {
    let be = backend()?;
    let model = LlamaModel::load_from_file(be, model_path, &LlamaModelParams::default())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", model_path.display())))?;

    let (target, source) = match detect_translation_request(text) {
        Some((target, source)) => (Some(target), source),
        None => (None, text.to_string()),
    };

    // Stage 1 rewrites at roughly the input's own length, so its cap scales;
    // stage 2 only condenses, so the normal cap is plenty.
    let stage1_max = (source.chars().count() * 2).clamp(MAX_NEW_TOKENS, STAGE1_MAX_TOKENS);
    let understood = generate_in(&model, &understand_prompt(&source), stage1_max)?;
    let middle = if understood.trim().is_empty() { source.clone() } else { understood };

    let condensed = generate_in(&model, &refine_prompt_with_hint(&middle, keywords_hint), MAX_NEW_TOKENS)?;
    let refined = if condensed.trim().is_empty() { tidy_output(&middle) } else { tidy_output(&condensed) };
    match target {
        Some(target) => translate_in(&model, &refined, target),
        None => Ok(refined),
    }
}

/// One entry point for both refine shapes. `stages` is 1 (single pass), 2
/// (understand then condense), or 0 for "decide by length" -- see
/// `state::refine_text_with_keywords_stages`.
///
/// It has no generation of its own: both branches are the functions above, which
/// already end in `tidy_output`, so the result is formatted either way.
pub fn refine_stages(model_path: &Path, text: &str, keywords_hint: &str, stages: u32) -> Result<String> {
    match stages {
        1 => refine_with_keywords(model_path, text, keywords_hint),
        2 => refine_two_stage(model_path, text, keywords_hint),
        // Callers pass 0 when they want the length rule; anything else is a bug.
        _ => refine_with_keywords(model_path, text, keywords_hint),
    }
}

/// Prompt for translating one finished line. `target` is "en" or "zh"; anything
/// else translates into Chinese, which is the app's default direction.
pub fn translate_prompt(text: &str, target: &str) -> String {
    match target {
        "en" => chatml_few_shot(TRANSLATE_SYSTEM_TO_EN, &TRANSLATE_EXAMPLES_TO_EN, text),
        _ => chatml_few_shot(TRANSLATE_SYSTEM_TO_ZH, &TRANSLATE_EXAMPLES_TO_ZH, text),
    }
}

/// Run one summary instruction over a text block. Used by the worker's `summarize` task.
pub fn summarize_one(model_path: &Path, instruction: &str, text: &str) -> Result<String> {
    generate_with(model_path, &summary_prompt(instruction, text), SUMMARY_MAX_TOKENS)
}

/// Translate one line into `target` ("en" or "zh"). Used by the worker's
/// `translate` task, where the target arrives as the instruction argument.
pub fn translate(model_path: &Path, text: &str, target: &str) -> Result<String> {
    generate(model_path, &translate_prompt(text, target))
}

/// Split text into the items the edit pass numbers.
///
/// The item boundaries are decided HERE and not by the model, because the text
/// is the app's own output and its shape is the app's business: a spoken draft
/// arrives as one run-on line, while a refine result may already be a bullet
/// list. Numbering it in code is what makes "把第二點改成…" mean the same line to
/// the user and to the model.
///
/// A single line is treated as a spoken sentence rather than a one-item list and
/// split at its own sentence ends, so "第三句刪掉" can name one; a multi-line
/// text already carries its structure, and splitting inside its lines would
/// renumber lines the user can see.
fn numbered_items(text: &str) -> Vec<String> {
    let mut items: Vec<String> = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let body = strip_bullet(trimmed).trim();
        if !body.is_empty() {
            items.push(body.to_string());
        }
    }
    if items.len() == 1 && items[0].chars().any(is_sentence_end) {
        let sentences = split_sentences(&items[0]);
        if !sentences.is_empty() {
            items = sentences;
        }
    }
    items
}

/// A bullet marker a refine result may carry. The same markers `strip_lone_bullet`
/// knows, listed again because that one fires only on a whole answer and this one
/// on each line of a draft.
fn strip_bullet(line: &str) -> &str {
    for marker in ["• ", "- ", "* "] {
        if let Some(rest) = line.strip_prefix(marker) {
            return rest;
        }
    }
    line
}

/// Punctuation that ends a sentence in either language the app handles.
fn is_sentence_end(c: char) -> bool {
    matches!(c, '。' | '！' | '？' | '!' | '?')
}

/// Split at sentence ends, keeping each sentence's own punctuation: the edit
/// pass must be able to answer with a sentence that still ends in `。` when it
/// did not touch that sentence.
fn split_sentences(text: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        current.push(c);
        if is_sentence_end(c) {
            items.push(current.trim().to_string());
            current.clear();
        }
    }
    let tail = current.trim();
    if !tail.is_empty() {
        items.push(tail.to_string());
    }
    items.retain(|item| !item.is_empty());
    items
}

/// Render items as the numbered lines the edit prompt shows the model.
fn number_lines(items: &[String]) -> String {
    let mut out = String::new();
    for (i, item) in items.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        out.push_str(&format!("{}. {item}", i + 1));
    }
    out
}

/// The text of one numbered line of the model's answer, if that line is one.
///
/// Strict on purpose: a line is an item only when it OPENS with an optional
/// bullet, a run of digits, one of `.` `、` `)` and whitespace. That is what
/// keeps a trailing remark ("(我把第二點改掉了)", "done!") out of the result --
/// see `parse_edited_items`.
fn strip_item_number(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    let body = strip_bullet(trimmed);
    let digits = body.len() - body.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 {
        return None;
    }
    let rest = body[digits..].strip_prefix(['.', '、', ')'])?;
    let item = match rest.strip_prefix(char::is_whitespace) {
        Some(after_space) => after_space,
        // The space after the marker is the model's habit, not a rule: "1. 甲"
        // and "2、甲" are the same item, and a line dropped here costs the user
        // the edit. Only a dot is refused without one, because that is the
        // marker a fraction borrows -- "3.14" must stay a remark rather than
        // become an item named "14".
        None if !body[digits..].starts_with('.') => rest,
        None => return None,
    }
    .trim();
    if item.is_empty() {
        return None;
    }
    Some(item)
}

/// Read the model's numbered lines back, in answer order.
///
/// Anything that is not a numbered line is dropped: the answer often carries a
/// closing remark, and a remark is not part of the user's text. An answer with no
/// numbered line at all leaves this EMPTY, which the caller turns into an error.
fn parse_edited_items(answer: &str) -> Vec<String> {
    answer.lines().filter_map(strip_item_number).map(str::to_string).collect()
}

/// Rejoin the edited items using the ORIGINAL text's layout.
///
/// The model was asked for numbered lines because they are unambiguous to edit,
/// but the user never asked for a list: a text that was one line has to come back
/// as one line, or a dictated sentence returns looking like a bullet list. So a
/// multi-line original keeps newlines, and a single-line original is rejoined the
/// way it was written -- no space inside CJK, one space between Latin words.
fn join_edited_items(original: &str, items: &[String]) -> String {
    let multiline = original.lines().filter(|line| !line.trim().is_empty()).count() > 1;
    let separator = if multiline {
        "\n"
    } else if has_cjk(original) {
        ""
    } else {
        " "
    };
    items.join(separator)
}

/// Prompt for one voice edit: the instruction and the numbered draft, with one
/// worked pair per edit shape for the draft's language.
fn edit_prompt(instruction: &str, text: &str) -> String {
    let examples: &[(&str, &str)] = if has_cjk(text) {
        &EDIT_EXAMPLES_ZH
    } else {
        &EDIT_EXAMPLES_EN
    };
    let user = format!("{}\n\n{}", instruction.trim(), number_lines(&numbered_items(text)));
    chatml_few_shot(EDIT_SYSTEM, examples, &user)
}

/// Apply a spoken edit instruction to text the app already produced. Used by the
/// worker's `edit` task, where the instruction arrives as the command-line
/// argument and the text on stdin.
///
/// The result is passed through `tidy_output` like every other text inserted at
/// the cursor (no wrapping quotes, no trailing full stop), and it is the WHOLE
/// text: the numbered lines exist only inside the prompt, so the caller replaces
/// the text rather than asking the user to accept a diff.
pub fn edit_with_instruction(model_path: &Path, text: &str, instruction: &str) -> Result<String> {
    let answer = generate(model_path, &edit_prompt(instruction, text))?;
    let items = parse_edited_items(&answer);
    // No numbered line means the model answered conversationally -- a sentence
    // like "好的，我改好了" about the edit rather than the edited text. That is an
    // ERROR and deliberately not a success: what came back is commentary, and
    // returning it would replace the user's own text with that remark. A failure
    // leaves the user with the text they already have, which is the harmless
    // outcome of the two.
    if items.is_empty() {
        return Err(EngineError::new(ErrorCode::Inference, "the model did not answer with numbered lines"));
    }
    Ok(tidy_output(&join_edited_items(text, &items)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn think_block_lands_before_the_answer() {
        let prompt = format!("{ASSISTANT_TURN}你好");
        let out = insert_think_block(&prompt);
        assert_eq!(out, format!("{ASSISTANT_TURN}{EMPTY_THINK_BLOCK}你好"));
        assert!(out.ends_with("你好"), "the transcript must stay after the block");
    }

    #[test]
    fn think_block_only_touches_the_last_turn() {
        // Few-shot prompts repeat the assistant turn. Prefilling an earlier one
        // would leave the real answer open, so the last turn is the only target.
        let prompt = format!("{ASSISTANT_TURN}one{ASSISTANT_TURN}two");
        let out = insert_think_block(&prompt);
        assert_eq!(
            out,
            format!("{ASSISTANT_TURN}one{ASSISTANT_TURN}{EMPTY_THINK_BLOCK}two")
        );
    }

    #[test]
    fn think_block_is_a_no_op_without_an_assistant_turn() {
        let prompt = "not a chat prompt";
        assert_eq!(insert_think_block(prompt), prompt);
    }

    #[test]
    fn prefill_matches_the_real_qwen35_template() {
        // Excerpt of the chat template of unsloth/Qwen3.5-2B-GGUF, copied
        // verbatim out of the GGUF metadata.
        //
        // The block in the template is a Jinja string literal, so the newlines
        // are written as the two characters \ and n and only become real
        // newlines when the template is rendered. Rendering it here is what
        // makes the comparison meaningful: the prefill has to be byte-identical
        // to what the model would have been given by its own template.
        let template = "{%- if add_generation_prompt %}\n    {{- '<|im_start|>assistant\\n' }}\n    {%- if enable_thinking is defined and enable_thinking is true %}\n        {{- '<think>\\n' }}\n    {%- else %}\n        {{- '<think>\\n\\n</think>\\n\\n' }}\n    {%- endif %}\n{%- endif %}";
        assert!(
            template.contains("enable_thinking") || template.contains("<think>"),
            "the detection must match this template"
        );
        let rendered = template.replace("\\n", "\n");
        assert!(
            rendered.contains(EMPTY_THINK_BLOCK),
            "the prefill must be byte-identical to the template's own block: {EMPTY_THINK_BLOCK:?}"
        );
        assert!(rendered.contains(ASSISTANT_TURN), "the turn marker must match too");
    }

    #[test]
    fn reasoning_is_stripped_from_the_answer() {
        assert_eq!(strip_reasoning("<think>\n\n</think>\n\n答案"), "答案");
        assert_eq!(strip_reasoning("<think>推理過程</think>答案"), "答案");
        // An unclosed block means everything after it was reasoning.
        assert_eq!(strip_reasoning("答案<think>還在推理"), "答案");
        assert_eq!(strip_reasoning("沒有推理"), "沒有推理");
    }

    #[test]
    fn tidy_drops_one_trailing_full_stop() {
        assert_eq!(tidy_output("下週三開會。"), "下週三開會");
        assert_eq!(tidy_output("開會．"), "開會");
        assert_eq!(tidy_output("Ship it next week."), "Ship it next week");
        // Only the last character is judged: an interior period is not a
        // "trailing full stop" and stays.
        assert_eq!(tidy_output("下週三開會。記得帶合約"), "下週三開會。記得帶合約");
        assert_eq!(tidy_output("Line one.\nLine two."), "Line one.\nLine two");
    }

    #[test]
    fn tidy_keeps_ellipsis_question_and_other_punctuation() {
        assert_eq!(tidy_output("我再想想……"), "我再想想……");
        assert_eq!(tidy_output("你有空嗎？"), "你有空嗎？");
        assert_eq!(tidy_output("Can you send it?"), "Can you send it?");
        assert_eq!(tidy_output("太好了！"), "太好了！");
        assert_eq!(tidy_output("備註："), "備註：");
    }

    #[test]
    fn tidy_strips_wrapping_quotes() {
        assert_eq!(tidy_output("「下週三開會」"), "下週三開會");
        assert_eq!(tidy_output("『備註』"), "備註");
        assert_eq!(tidy_output("\"Ship it next week.\""), "Ship it next week");
        assert_eq!(tidy_output("'ok'"), "ok");
        // Whitespace outside the quotes goes too, and the quote unwrap runs
        // before the full stop is looked at.
        assert_eq!(tidy_output("  “下週三開會。”  "), "下週三開會");
    }

    #[test]
    fn lone_bullet_is_dropped_but_a_list_keeps_its_bullets() {
        assert_eq!(strip_lone_bullet("• 下週三開會"), "下週三開會");
        assert_eq!(strip_lone_bullet("- 下週三開會"), "下週三開會");
        assert_eq!(strip_lone_bullet("• 甲\n• 乙"), "• 甲\n• 乙");
        assert_eq!(strip_lone_bullet("一般句子"), "一般句子");
    }

    #[test]
    fn translation_request_is_split_from_the_draft() {
        assert_eq!(
            detect_translation_request("把這句翻成英文：明天下午三點跟客戶開會"),
            Some(("en", "明天下午三點跟客戶開會".to_string()))
        );
        assert_eq!(
            detect_translation_request("明天下午三點開會，翻成英文"),
            Some(("en", "明天下午三點開會".to_string()))
        );
        assert_eq!(
            detect_translation_request("請用英文回答，合約週五前寄出"),
            Some(("en", "合約週五前寄出".to_string()))
        );
    }

    #[test]
    fn ordinary_mentions_of_a_language_are_not_requests() {
        // "我用英文寫了一封信" is content, not an instruction.
        assert_eq!(detect_translation_request("我用英文寫了一封信給客戶"), None);
        // A question about the API must not be read as a request to translate.
        assert_eq!(detect_translation_request("這個 API 的 rate limit 是多少？"), None);
        // Nothing left once the instruction is removed.
        assert_eq!(detect_translation_request("翻成英文"), None);
    }

    #[test]
    fn tidy_keeps_multi_line_layout() {
        assert_eq!(
            tidy_output("• 第一點\n• 第二點。第三點"),
            "• 第一點\n• 第二點。第三點"
        );
        // 3+ blank lines collapse to one; single newlines are the bullet layout.
        assert_eq!(tidy_output("第一行\n\n\n\n第二行"), "第一行\n\n第二行");
        assert_eq!(tidy_output("  我用 Slack 跟 PM 確認  "), "我用 Slack 跟 PM 確認");
    }

    #[test]
    fn numbering_keeps_the_lines_of_a_multi_line_draft() {
        // Blank lines in the draft are not items, and each line keeps its order.
        assert_eq!(
            numbered_items("跟客戶確認規格\n下週三下午三點開會\n\n把報價單寄出去"),
            vec!["跟客戶確認規格", "下週三下午三點開會", "把報價單寄出去"]
        );
    }

    #[test]
    fn a_single_line_draft_is_split_into_its_sentences() {
        // Speech has no line breaks, so "第三句刪掉" has to be able to name a
        // sentence: one line becomes one item per sentence, punctuation kept.
        assert_eq!(
            numbered_items("先確認規格。再找供應商！最後排時程"),
            vec!["先確認規格。", "再找供應商！", "最後排時程"]
        );
        assert_eq!(numbered_items("我先跟客戶確認規格。等下再回你"), vec!["我先跟客戶確認規格。", "等下再回你"]);
        // A single line with no sentence end stays one item.
        assert_eq!(numbered_items("下週三下午三點開會"), vec!["下週三下午三點開會"]);
    }

    #[test]
    fn numbering_drops_bullets() {
        assert_eq!(numbered_items("• 甲\n- 乙\n* 丙"), vec!["甲", "乙", "丙"]);
    }

    #[test]
    fn numbering_and_parsing_agree() {
        // The whole design rests on these two being inverses: the prompt's
        // numbering is only usable if the answer's numbering reads back the same.
        let items = numbered_items("• 甲\n• 乙。丙");
        assert_eq!(number_lines(&items), "1. 甲\n2. 乙。丙");
        assert_eq!(parse_edited_items(&number_lines(&items)), items);
    }

    #[test]
    fn parsing_strips_every_number_marker() {
        assert_eq!(parse_edited_items("2. 禮拜五下午兩點"), vec!["禮拜五下午兩點"]);
        assert_eq!(parse_edited_items("2、禮拜五下午兩點"), vec!["禮拜五下午兩點"]);
        assert_eq!(parse_edited_items("12) 禮拜五下午兩點"), vec!["禮拜五下午兩點"]);
        // A bullet in front of the number is allowed too, and the answer keeps
        // its own order rather than being sorted by the numbers.
        assert_eq!(parse_edited_items("- 2. 甲\n1. 乙"), vec!["甲", "乙"]);
    }

    #[test]
    fn parsing_ignores_anything_that_is_not_a_numbered_line() {
        // The remark the model likes to append is not part of the user's text. A
        // line whose number is not followed by a marker ("3 pm") is not an item
        // either, and a numbered line with nothing after the number is not one.
        assert_eq!(
            parse_edited_items("1. 跟客戶確認規格\n2. 禮拜五下午兩點\n（我把第二點改掉了）"),
            vec!["跟客戶確認規格", "禮拜五下午兩點"]
        );
        assert_eq!(parse_edited_items("1. 甲\n3 pm 開會"), vec!["甲"]);
        assert_eq!(parse_edited_items("1.\n1. 甲"), vec!["甲"]);
    }

    #[test]
    fn an_unnumbered_answer_parses_to_nothing() {
        // Deliberately empty rather than "one item": the caller turns this into
        // an error, so chatty prose is never handed back as an edit.
        assert!(parse_edited_items("好的，我把第二點改成禮拜五下午兩點了").is_empty());
        assert!(parse_edited_items("").is_empty());
        assert!(parse_edited_items("   \n  ").is_empty());
    }

    #[test]
    fn joining_follows_the_original_layout() {
        let items = vec!["甲".to_string(), "乙".to_string()];
        // The original was one CJK line: no separator, or a sentence comes back
        // looking like a list.
        assert_eq!(join_edited_items("甲。乙", &items), "甲乙");
        // One Latin line: words need the space.
        assert_eq!(join_edited_items("one two", &items), "甲 乙");
        // Multiple lines: the newlines were the user's layout and stay.
        assert_eq!(join_edited_items("甲\n乙", &items), "甲\n乙");
    }

    #[test]
    fn an_edited_single_line_is_tidied_like_a_refine_result() {
        // The joined result goes through `tidy_output`, so the delivery rule
        // holds for an edit too: only the end of the text loses its full stop,
        // and an interior one stays.
        let items = vec!["先確認規格。".to_string(), "再找供應商。".to_string(), "最後排時程。".to_string()];
        let joined = join_edited_items("先確認規格。再找供應商。最後排時程", &items);
        assert_eq!(joined, "先確認規格。再找供應商。最後排時程。");
        assert_eq!(tidy_output(&joined), "先確認規格。再找供應商。最後排時程");
    }
}
