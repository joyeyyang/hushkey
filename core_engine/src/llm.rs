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
const EDIT_EXAMPLES_ZH: [(&str, &str); 3] = [
    // The positional pair edits the LAST line, not the second one. With every
    // positional example editing line 2, the model learned "a positional
    // instruction means line 2" and every "把第三點改成…" came back unchanged.
    // The deletion pair below deletes line 2, so with this one the two
    // positional examples cover both a change and a removal on different
    // lines.
    (
        "把第三點改成禮拜五下午兩點\n\n1. 跟客戶確認規格\n2. 把報價單寄出去\n3. 下週三下午三點開會",
        "1. 跟客戶確認規格\n2. 把報價單寄出去\n3. 禮拜五下午兩點",
    ),
    // The deleted item's number disappears with it: the answer is two lines, not
    // three with a hole where the third was.
    //
    // The deleted line is the SECOND one, not the third. With the third as the
    // deleted line, "把第三點改成…" came back unchanged across every draft
    // tried: two of the three pairs left line 3 alone, and the model had
    // learned that the last line is the one that disappears rather than the one
    // that changes.
    (
        "第二句刪掉\n\n1. 先確認規格\n2. 再找供應商\n3. 最後排時程",
        "1. 先確認規格\n3. 最後排時程",
    ),
    // The instruction names the CONTENT to change, not a position ("合約"), and
    // the answer changes the line that carries that content. Without this pair
    // the model had only ever seen "change the second one", and an answer with
    // no position in it came back as the draft read out again -- the edit
    // silently did nothing.
    //
    // Three things this pair has to get right, all measured:
    //
    // * The answer must read as a SENTENCE. A first attempt made it nonsense
    //   ("討論第四季禮拜五"), and the model copied that shape: a content
    //   instruction came back unchanged.
    // * The REPLACEMENT has to be the kind of thing that slot can hold. A
    //   second attempt put a date ("禮拜五") into a venue slot, and the model
    //   refused -- correctly, since "地點：禮拜五" is not a place -- so the
    //   answer came back unchanged.
    // * The changed line must be the LAST one. With the content in the middle
    //   line, every instruction about the last line came back unchanged: the
    //   two earlier pairs both leave line 3 alone (one edits line 2, one
    //   deletes line 3), and the model copied that -- "the last line is not
    //   edited" -- which is what made "把第三點改成…" do nothing at all.
    //
    // So the content sits on the LAST line here, and the middle line stays
    // untouched, which is the opposite of the earlier attempt.
    (
        "把合約改成報價單\n\n1. 上週的進度還沒回報，\n2. 客戶在等回覆，\n3. 合約是舊版的",
        "1. 上週的進度還沒回報，\n2. 客戶在等回覆，\n3. 合約改成報價單",
    ),
];

const EDIT_EXAMPLES_EN: [(&str, &str); 3] = [
    // The positional pair edits the LAST line -- the English twin of the
    // Chinese first pair, and for the same measured reason.
    (
        "change the third one to Friday at 2 pm\n\n1. Confirm the spec with the client\n2. Send the quote\n3. Meeting on Wednesday at 3 pm",
        "1. Confirm the spec with the client\n2. Send the quote\n3. Friday at 2 pm",
    ),
    (
        "delete the second one\n\n1. Confirm the spec\n2. Find a supplier\n3. Set the schedule",
        "1. Confirm the spec\n3. Set the schedule",
    ),
    // The instruction names the content ("the contract"), not a position -- the
    // English twin of the Chinese third pair, and it exists for the same
    // measured reason: with only position-based pairs in the prompt, a content
    // instruction came back as the draft read out again. The content sits on
    // the LAST line, for the same reason the Chinese one does: with it in the
    // middle, every instruction about the last line changed nothing.
    (
        "change the contract to the quote\n\n1. Last week's progress is not reported yet,\n2. The client is waiting for an answer,\n3. The contract is the old version",
        "1. Last week's progress is not reported yet,\n2. The client is waiting for an answer,\n3. The contract changed to the quote",
    ),
];

/// True for the CJK ranges that decide "this draft is Chinese".
pub(crate) fn has_cjk(text: &str) -> bool {
    text.chars().any(is_cjk)
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x3040..=0x30ff | 0xac00..=0xd7af)
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

/// Strip ONE trailing separator the text cannot end on: `。`, `.`, `．`, `，`, `、`
/// or `,`.
///
/// The full stop is the delivery rule (the text goes to a cursor). The comma and
/// the enumeration mark are the edit pass's leftovers: the model joins an edited
/// line back together and can leave the separator that used to sit between two
/// clauses dangling at the end ("我明天要去開會，地點還沒確定，"). A trailing
/// separator of any kind reads as an unfinished sentence at a cursor, and none of
/// them is ever spoken as the last character.
///
/// Deliberately literal -- only the last character is judged, so an interior
/// period stays, and an ellipsis (`…`), a question mark, a bang, a colon or a
/// semicolon is left as the speaker's punctuation. No abbreviation lookup and no
/// `...` detection: the model emits `…` for an ellipsis, and the product rule is
/// about the final character, not about guessing words.
fn strip_trailing_separator(text: &str) -> &str {
    match text.chars().next_back() {
        Some(c @ ('。' | '.' | '．' | '，' | '、' | ',')) => text[..text.len() - c.len_utf8()].trim_end(),
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
    collapse_blank_lines(strip_trailing_separator(single))
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
        // A draft that already carries numbers ("1. 先確認規格") is numbered by
        // the user or by an earlier pass. Numbering it again produced "1. 1.
        // 先確認規格", and the model answered to that broken shape.
        let body = strip_item_number(body).unwrap_or(body).trim();
        if !body.is_empty() {
            items.push(body.to_string());
        }
    }
    if items.len() == 1 {
        // A spoken draft is one run-on line with almost no punctuation: in the
        // app's own 43 recorded drafts, 34 carry no sentence end at all. Sentence
        // ends alone therefore left the model looking at `1. <the whole thing>`,
        // so a spoken 「第二句」 named nothing it had been shown, and an answer
        // could not be checked against anything. Clause marks are the only
        // boundaries such a draft has, so they are used when there is no sentence
        // end to split on.
        let parts = if items[0].chars().any(is_sentence_end) {
            split_sentences(&items[0])
        } else {
            split_clause_marks(&items[0])
        };
        if parts.len() > 1 {
            items = parts;
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

/// Split at clause marks, keeping each clause's own punctuation.
///
/// Only reached for a draft with no sentence end anywhere. The marks stay
/// attached to their clause so that rejoining the edited items reproduces the
/// line as it was spoken -- `join_edited_items` puts no separator between CJK
/// items for exactly that reason.
fn split_clause_marks(text: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        current.push(c);
        if matches!(c, '，' | ',' | '；' | ';' | '、') {
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
/// see `parse_edited_answer`.
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
        // The space after the marker is the model's habit, not a rule: "1. 甲",
        // "1.甲" and "2、甲" are the same item, and a line dropped here is a line
        // of the user's text lost without a word. The one thing that is not an
        // item is a fraction -- "3.14" only looks like a marker because a dot is
        // also a decimal point, so a dot followed by a digit is refused.
        None if !rest.starts_with(|c: char| c.is_ascii_digit()) => rest,
        None => return None,
    }
    .trim();
    if item.is_empty() {
        return None;
    }
    Some(item)
}

/// Read the model's answer back: the lines, and whether they arrived numbered.
///
/// Numbered lines are the shape the prompt asks for, and the only shape that can
/// express a deletion -- the numbers that are missing say which line went. The
/// model also answers with plain lines often enough to matter: measured on this
/// 1.5B model, the SAME prompt and draft returned the numbered shape and the
/// plain one on different runs (Metal reductions are not bit-identical under the
/// memory pressure of an 8 GB machine), so refusing the plain shape made the
/// feature fail at random.
///
/// A plain answer is therefore read as its own non-empty lines and left to
/// `check_edited_shape`, which knows the draft it has to account for. Lines that
/// are neither -- a closing remark such as "好的，我改好了" -- are dropped here,
/// and an answer that is only remarks comes back empty, which the caller turns
/// into an error.
fn parse_edited_answer(answer: &str) -> (Vec<String>, bool) {
    let numbered: Vec<String> = answer
        .lines()
        .filter_map(strip_item_number)
        .map(str::to_string)
        .collect();
    if !numbered.is_empty() {
        return (numbered, true);
    }
    let plain: Vec<String> = answer
        .lines()
        .map(|line| strip_bullet(line.trim()).trim())
        .filter(|line| !line.is_empty() && !looks_like_commentary(line))
        .map(str::to_string)
        .collect();
    (plain, false)
}

/// Whether a line is the model talking about the edit instead of making it.
///
/// Only consulted for an answer that ignored the numbering, where the line count
/// is the whole check and one remark equals one line of the user's text. The
/// prefixes are the ones this model actually produces ("好的", "已幫你改好",
/// "以下是修改後的內容"); a real edited line that happens to start with 我 or 今天
/// is not affected, which is why the list is short and specific.
fn looks_like_commentary(line: &str) -> bool {
    const PREFIXES: [&str; 14] = [
        "好的", "好，", "OK", "okay", "已幫", "已經", "已完成", "完成", "以下是", "這是",
        "抱歉", "對不起", "Here is", "Sure",
    ];
    PREFIXES.iter().any(|prefix| line.starts_with(prefix))
}

/// Rejoin the edited items using the ORIGINAL text's layout.
///
/// The model was asked for numbered lines because they are unambiguous to edit,
/// but the user never asked for a list: a text that was one line has to come back
/// as one line, or a dictated sentence returns looking like a bullet list. So a
/// multi-line original keeps newlines, and a single-line original is rejoined the
/// way it was written -- no space inside CJK, one space between Latin words.
fn join_edited_items(original: &str, items: &[String]) -> String {
    let lines: Vec<&str> = original.lines().filter(|line| !line.trim().is_empty()).collect();
    let multiline = lines.len() > 1;
    let separator = if multiline {
        "\n"
    } else if has_cjk(original) {
        ""
    } else {
        " "
    };
    let joined = items.join(separator);
    // The numbering hid the bullet markers from the model, so they come back
    // here: the bullets are the user's layout in the same way the newlines are,
    // and every line of a bulleted draft carried one. "• " is the canonical
    // marker the refine prompt asks for and `normalizeOutput` writes.
    let bulleted = multiline && lines.iter().all(|line| line.trim_start().starts_with("• "));
    if !bulleted {
        return joined;
    }
    joined.split('\n').map(|line| format!("• {line}")).collect::<Vec<_>>().join("\n")
}

/// Which line of the draft a spoken edit instruction is about.
///
/// The model cannot be trusted to find it. Measured on this 2B model over a
/// three-line draft: a positional instruction ("把第三點改成…") left the draft
/// unchanged for most values tried, and a content instruction ("把地點改成…")
/// changed the WRONG line or nothing at all -- the few-shot examples taught it
/// which line the examples touched, and it copied that rather than reading the
/// instruction. A prompt cannot fix a model that answers a different question.
///
/// So the line is found HERE, where it is arithmetic rather than interpretation,
/// and the model is asked to rewrite that ONE line. The program owns the
/// structure; the model owns the wording.
///
/// Two ways to name a line, both spelled out in the instruction:
///
/// * A POSITION: "第三點", "the second one", "3". Unambiguous, so it wins.
/// * A CONTENT WORD: "把地點改成…", "change the venue to…". The line that
///   contains the word is the one. When several lines contain it, the longest
///   run of shared characters decides -- "第四季時程" points at the line that
///   says 時程, not at one that merely says 季.
///
/// Returns `None` when nothing matches, which leaves the caller on the old
/// whole-draft path: a refusal keeps the user's text, and an unlocatable
/// instruction is exactly the case where the whole-draft model at least has a
/// chance.
fn locate_edit_target(instruction: &str, items: &[String]) -> Option<(usize, EditTarget)> {
    if items.is_empty() {
        return None;
    }
    if let Some(index) = locate_by_position(instruction, items.len()) {
        return Some((index, EditTarget::Position));
    }
    let word = locate_by_content(instruction, items)?;
    Some((word.0, EditTarget::Content(word.1)))
}

/// How the instruction named the line it is about.
///
/// The two ways need different instructions to the model. A position names a
/// line and the replacement becomes that line ("把第二點改成禮拜五" makes the
/// line "禮拜五"). A content word names a PART of a line, and the replacement
/// takes that part's place ("把小林改成大衛" makes the line "明天下午三點跟大衛
/// 開會"). Telling the model "replace this line" for the second case made it
/// put the new value in front of the line instead of in the word's place.
#[derive(Clone, Debug, PartialEq, Eq)]
enum EditTarget {
    Position,
    Content(String),
}

/// The line a POSITION in the instruction names, if any.
///
/// The position words are the ones a person actually says: "第三點", "第三句",
/// "第三行", "the second one", "3". Chinese numerals are read as well as
/// Arabic ones, because "第三點" is how the instruction comes out of the
/// microphone.
fn locate_by_position(instruction: &str, count: usize) -> Option<usize> {
    if let Some(n) = chinese_position(instruction) {
        if n >= 1 && n <= count {
            return Some(n - 1);
        }
    }
    // An English ordinal: "the second one", "the third line".
    if let Some(n) = english_ordinal(instruction) {
        if n >= 1 && n <= count {
            return Some(n - 1);
        }
    }
    // An Arabic digit run: "把3改成…". A digit that FOLLOWS the change verb is
    // part of the replacement ("改成3樓"), not a position, so the digit has to
    // come before the verb -- or be followed by a word that marks it as a
    // position ("3點").
    let bytes = instruction.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        if !b.is_ascii_digit() {
            continue;
        }
        let start = i;
        let mut end = i;
        while end < bytes.len() && bytes[end].is_ascii_digit() {
            end += 1;
        }
        let after = instruction[end..].chars().next().unwrap_or(' ');
        let marked = matches!(after, '點' | '句' | '行' | '項' | '條' | '.' | ')');
        if !marked && !before_change_verb(instruction, start) {
            continue;
        }
        let n: usize = instruction[start..end].parse().ok()?;
        if n >= 1 && n <= count {
            return Some(n - 1);
        }
    }
    None
}

/// Whether the byte offset sits before the word that marks the replacement.
///
/// "把3改成禮拜五" has the 3 before the verb, so it is a position; "改成3樓" has
/// it after, so it is part of the new value.
fn before_change_verb(instruction: &str, at: usize) -> bool {
    const VERBS: [&str; 6] = ["改成", "換成", "改為", "換", "改", "刪掉"];
    let head = &instruction[..at];
    !VERBS.iter().any(|verb| head.contains(verb))
}

/// The Chinese position in the instruction, if it names one.
///
/// "第三點" is 3, "第十行" is 10. The numeral has to be preceded by 第 and
/// followed by a position word, so "第四季" is not read as a line number and
/// "把三點改成四點" is not read as "change line 3" -- 三點 there is the time
/// in the afternoon, and reading it as a position put the new time on the
/// wrong clause.
fn chinese_position(instruction: &str) -> Option<usize> {
    const DIGITS: [(&str, usize); 10] = [
        ("一", 1), ("二", 2), ("三", 3), ("四", 4), ("五", 5),
        ("六", 6), ("七", 7), ("八", 8), ("九", 9), ("十", 10),
    ];
    const POSITION_WORDS: [char; 6] = ['點', '句', '行', '項', '條', '個'];
    let chars: Vec<char> = instruction.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        // 第 has to be there: without it, "三點" is a time and not a position.
        if i == 0 || chars[i - 1] != '第' {
            continue;
        }
        let value = match DIGITS.iter().find(|(d, _)| d.chars().next() == Some(*c)) {
            Some((_, v)) => *v,
            None => continue,
        };
        let next = i + 1;
        // A numeral run: 十一 is 11.
        if next + 1 < chars.len() {
            if let Some((_, tens)) = DIGITS.iter().find(|(d, _)| d.chars().next() == Some(chars[next])) {
                if *tens == 10 {
                    // 十一 = 11, 十二 = 12 …
                    if let Some((_, ones)) = DIGITS.iter().find(|(d, _)| d.chars().next() == Some(chars[next + 1])) {
                        if *ones < 10 && POSITION_WORDS.contains(&chars[next + 2]) {
                            return Some(10 + ones);
                        }
                    }
                }
            }
        }
        if next < chars.len() && POSITION_WORDS.contains(&chars[next]) {
            return Some(value);
        }
    }
    None
}

/// The English position in the instruction, if it names one.
fn english_ordinal(instruction: &str) -> Option<usize> {
    const ORDINALS: [(&str, usize); 10] = [
        ("first", 1), ("second", 2), ("third", 3), ("fourth", 4), ("fifth", 5),
        ("sixth", 6), ("seventh", 7), ("eighth", 8), ("ninth", 9), ("tenth", 10),
    ];
    let lower = instruction.to_lowercase();
    ORDINALS
        .iter()
        .find(|(word, _)| lower.contains(word))
        .map(|(_, value)| *value)
}

/// The line a CONTENT WORD in the instruction points at.
///
/// The word is what the instruction names as the thing to change: "把地點改成…"
/// names 地點, and the line that says 地點 is the one. The word is taken from
/// the instruction's own wording rather than from a fixed list, so this works
/// for any vocabulary the user speaks.
///
/// The instruction is read as "把 <TARGET> 改成 <VALUE>" or "change <TARGET> to
/// <VALUE>": the target is what sits between the verb and the replacement. The
/// replacement itself is dropped -- it is the new value, not a word to look for
/// in the old text -- and so are the verbs, or "改成" would be looked for in
/// every line.
///
/// Chinese has no spaces, so the target is the run of characters between the
/// verb and the next verb or the end: "把地點改成三樓會議室" yields 地點, not
/// 地點改成三樓會議室.
fn locate_by_content(instruction: &str, items: &[String]) -> Option<(usize, String)> {
    let targets = content_words(instruction);
    if targets.is_empty() {
        return None;
    }
    let mut best: Option<(usize, usize, String)> = None; // (index, shared, word)
    for (index, item) in items.iter().enumerate() {
        let mut shared = 0;
        let mut word = String::new();
        for candidate in &targets {
            if candidate.chars().count() < 2 {
                continue;
            }
            if item.contains(candidate.as_str()) && candidate.chars().count() > shared {
                shared = candidate.chars().count();
                word = candidate.clone();
            }
        }
        // A line that carries more of the instruction's words is the better
        // match; ties go to the earlier line.
        if shared > 0 && best.as_ref().map(|(_, s, _)| shared > *s).unwrap_or(true) {
            best = Some((index, shared, word));
        }
    }
    let (index, _, word) = best?;
    // The word has to be on ONE line only. "把三點改成四點" on a draft whose
    // first and third lines both say 三點 names two lines, and which one the
    // user meant is not decidable here. The whole-draft path is not asked
    // either -- it put the new time in the third line, which was as likely to
    // be wrong as right -- so this is a refusal, and the user keeps the text
    // they already have.
    if items.iter().filter(|i| i.contains(word.as_str())).count() != 1 {
        return None;
    }
    Some((index, word))
}

/// The content words an instruction names, taken out of its own wording.
///
/// The instruction is read as "把 <TARGET> 改成 <VALUE>" or "change <TARGET> to
/// <VALUE>": the target is what sits between the verb and the replacement. The
/// replacement itself is dropped -- it is the new value, not a word to look for
/// in the old text -- and so are the verbs.
fn content_words(instruction: &str) -> Vec<String> {
    // The verbs that frame the target. The FIRST one ends the target and the
    // rest starts the replacement, so only what sits before it is the target.
    const CHINESE_VERBS: [&str; 10] = ["改成", "換成", "改為", "換", "改", "刪掉", "刪除", "拿掉", "去掉", "換成"];
    const ENGLISH_VERBS: [&str; 6] = ["change", "replace", "make it", "delete", "remove", "to"];
    let mut rest = instruction.trim().to_string();
    for verb in CHINESE_VERBS.iter() {
        if let Some(at) = rest.find(verb) {
            rest = rest[..at].to_string();
            break;
        }
    }
    for verb in ENGLISH_VERBS.iter() {
        if let Some(at) = rest.find(verb) {
            rest = rest[..at].to_string();
            break;
        }
    }
    // What is left, minus the words that frame the sentence.
    const FRAMING: [&str; 16] = [
        "請幫我", "幫我", "請", "幫", "把", "給我", "我要", "我想", "要", "的", "了",
        "please", "can you", "could you", "make", "the",
    ];
    for word in FRAMING {
        rest = rest.replace(word, " ");
    }
    let words: Vec<String> = rest
        .split(|c: char| c.is_whitespace() || "，,。.、；;：:！!？?「」『』".contains(c))
        .map(|w| w.trim())
        .filter(|w| !w.is_empty() && !w.chars().all(|c| c.is_ascii_digit()))
        .map(|w| w.to_string())
        .collect();
    // A Chinese target is one run of characters, not a list of words: the
    // split above left "地點" intact because Chinese has no spaces, but a
    // mixed instruction can leave a run with a stray Latin word in it.
    words
        .into_iter()
        .filter(|w| w.chars().count() >= 2 || w.chars().all(|c| c.is_ascii_alphabetic()))
        .collect()
}

/// Prompt for rewriting ONE line of the draft.
///
/// The line has already been chosen by the program (see `locate_edit_target`),
/// so the model is not asked which line to change -- only how to word it. The
/// line comes back on its own, with no numbering, because there is nothing to
/// number it against.
///
/// The instruction the model is given is the ONE LINE's instruction, rebuilt
/// from the spoken one: the position is dropped (the line is already the one),
/// and only the replacement is kept. Passing the spoken instruction through
/// unchanged made the model echo it -- "把第二點改成禮拜五" came back as the
/// line "第二點改成禮拜五討論第四季時程" -- because the instruction still
/// talked about a position the model could not see.
///
/// The examples are the two shapes this can be: a replacement and a removal.
/// A one-line answer is all that is wanted, so the prompt says so and the
/// worked pairs show it.
const EDIT_ONE_SYSTEM_ZH: &str = "使用者要修改下面這一行文字。只輸出改寫後的那一行，不要解釋、不要加標號、不要加引號。\
如果使用者要刪掉這一行，只輸出一個固定的符號「␡」。\
沒有被要求改的部分要保留，數字、時間、人名照原樣保留。";
const EDIT_ONE_SYSTEM_EN: &str = "The user wants this one line changed. Output only the changed line, no explanation, no numbering, no quotes. \
If the user wants this line deleted, output the single marker 「␡」. \
Keep everything that was not asked to change; keep numbers, times and names as they are.";

/// The marker that stands for a deleted line.
const DELETED_LINE: &str = "␡";

const EDIT_ONE_EXAMPLES_ZH: [(&str, &str); 4] = [
    // A POSITION target replaces the WHOLE line. The first attempt showed
    // "禮拜五下午兩點開會" for the line "下週三下午三點開會", and the model
    // copied that shape everywhere: it put the new value in front of the line
    // and kept the rest, so "把地點改成三樓會議室" came back as
    // "三樓會議室地點還沒確定". A whole-line replacement is shown as one.
    ("把這行完全改成禮拜五下午兩點\n下週三下午三點開會", "禮拜五下午兩點"),
    ("把這行完全改成禮拜五\n討論第四季時程", "禮拜五"),
    // A CONTENT target replaces only the word, and the rest of the line stays.
    ("把這行裡的「小林」改成大衛，其他字不變\n明天下午三點跟小林開會，", "明天下午三點跟大衛開會，"),
    ("刪掉這行\n地點還沒確定", DELETED_LINE),
];

const EDIT_ONE_EXAMPLES_EN: [(&str, &str); 4] = [
    ("replace this whole line with Friday at 2 pm\nMeeting on Wednesday at 3 pm", "Friday at 2 pm"),
    ("replace this whole line with Friday\nWe will discuss the Q4 schedule", "Friday"),
    ("replace \"Kevin\" with David in this line, keep the rest\nMeeting with Kevin tomorrow,", "Meeting with David tomorrow,"),
    ("delete this line\nThe venue is still undecided", DELETED_LINE),
];

/// Prompt for rewriting one chosen line.
fn edit_one_prompt(instruction: &str, line: &str, target: &EditTarget) -> String {
    let (system, examples): (&str, &[(&str, &str)]) = if has_cjk(line) {
        (EDIT_ONE_SYSTEM_ZH, &EDIT_ONE_EXAMPLES_ZH)
    } else {
        (EDIT_ONE_SYSTEM_EN, &EDIT_ONE_EXAMPLES_EN)
    };
    let user = format!("{}\n{}", one_line_instruction(instruction, target), line.trim());
    chatml_few_shot(system, examples, &user)
}

/// The instruction for rewriting ONE line, rebuilt from the spoken one.
///
/// The spoken instruction names a position ("把第二點改成禮拜五") and the model
/// has only ever been shown one line, so the position is dropped and the
/// replacement is kept. What is left is the part of the instruction after the
/// change verb, which is the new value.
///
/// A CONTENT target is different: the instruction named a word INSIDE the line
/// ("把小林改成大衛"), and the replacement has to take that word's place. So
/// the word is named again in the instruction, and the model is told to replace
/// it where it sits. Without that, the model put the new value in front of the
/// line ("大衛明天下午三點跟小林開會") -- it was told to replace the line, and
/// that is what it did.
///
/// A deletion keeps its own wording, because there is no value to carry over.
fn one_line_instruction(instruction: &str, target: &EditTarget) -> String {
    let text = instruction.trim();
    const CHINESE_VERBS: [&str; 5] = ["改成", "換成", "改為", "換", "改"];
    const ENGLISH_VERBS: [&str; 3] = ["change", "replace", "to"];
    if instruction_removes(text) {
        return if has_cjk(text) { "刪掉這行".to_string() } else { "delete this line".to_string() };
    }
    let value = CHINESE_VERBS
        .iter()
        .find_map(|verb| {
            text.find(verb).map(|at| text[at + verb.len()..].trim().to_string())
        })
        .or_else(|| {
            ENGLISH_VERBS.iter().find_map(|verb| {
                text.to_lowercase()
                    .find(verb)
                    .map(|at| text[at + verb.len()..].trim().to_string())
            })
        })
        .unwrap_or_default();
    if value.is_empty() {
        return text.to_string();
    }
    match target {
        EditTarget::Position => {
            if has_cjk(text) {
                format!("把這行完全改成{value}")
            } else {
                format!("replace this whole line with {value}")
            }
        }
        EditTarget::Content(word) => {
            if has_cjk(text) {
                format!("把這行裡的「{word}」改成{value}，其他字不變")
            } else {
                format!("replace \"{word}\" with {value} in this line, keep the rest")
            }
        }
    }
}

/// Prompt for one voice edit: the instruction and the numbered draft, with one
/// worked pair per edit shape for the draft's language.
pub fn edit_prompt(instruction: &str, text: &str) -> String {
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
    let draft = numbered_items(text);
    // The line is found here when it can be found, and the model then rewrites
    // only that line. This is the path that works: the whole-draft prompt below
    // measures at 4/7 on a three-line draft, because a 2B model does not
    // reliably pick the line an instruction names.
    if let Some((index, target)) = locate_edit_target(instruction, &draft) {
        match edit_one_line(model_path, text, &draft, index, instruction, &target) {
            Ok(edited) => return Ok(edited),
            // A targeted rewrite that came back unusable falls back to the
            // whole-draft path, which at least has a chance of applying the
            // edit somewhere.
            Err(e) => {
                eprintln!("targeted edit failed ({e:?}); falling back to the whole-draft edit");
            }
        }
    }
    // A content instruction whose word is on SEVERAL lines names no line, and
    // the whole-draft path below would guess: measured, "把三點改成四點" on a
    // draft whose first and third lines both said 三點 put the new time in the
    // third line. A refusal keeps the user's text, which is the harmless
    // outcome; a wrong guess rewrites the wrong sentence.
    if let Some(word) = ambiguous_content_word(instruction, &draft) {
        return Err(EngineError::new(
            ErrorCode::Inference,
            format!("the word 「{word}」 appears in more than one line"),
        ));
    }
    let answer = generate(model_path, &edit_prompt(instruction, text))?;
    let (items, numbered) = parse_edited_answer(&answer);
    // No usable line means the model answered conversationally -- a sentence like
    // "好的，我改好了" about the edit rather than the edited text. That is an ERROR
    // and deliberately not a success: what came back is commentary, and returning
    // it would replace the user's own text with that remark. A failure leaves the
    // user with the text they already have, which is the harmless outcome of the
    // two.
    if items.is_empty() {
        return Err(EngineError::new(ErrorCode::Inference, "the model's answer had no lines to use"));
    }
    // A one-line draft answered with one plain line: the model applied the edit and
    // rejoined the line (measured -- the clause numbering is what it drops), so
    // there are no line counts to compare. Content is compared instead.
    let one_line_draft = text.lines().filter(|line| !line.trim().is_empty()).count() == 1;
    if !numbered && one_line_draft && items.len() == 1 {
        let candidate = tidy_output(&items[0]);
        if !single_line_answer_is_an_edit(text, &candidate) {
            return Err(EngineError::new(
                ErrorCode::Inference,
                "the answer is not an edit of the draft",
            ));
        }
        return Ok(candidate);
    }
    check_edited_shape(&items, &draft, instruction, numbered)?;
    Ok(tidy_output(&join_edited_items(text, &items)))
}

/// The word a content instruction names, if that word is on more than one line.
///
/// Returns the word, so the caller can refuse the edit with a reason. The
/// instruction named a word the draft uses twice, and the two lines are not
/// told apart by the instruction -- so which one to change is a guess.
fn ambiguous_content_word(instruction: &str, items: &[String]) -> Option<String> {
    if locate_by_position(instruction, items.len()).is_some() {
        return None;
    }
    for word in content_words(instruction) {
        if word.chars().count() < 2 {
            continue;
        }
        if items.iter().filter(|i| i.contains(word.as_str())).count() > 1 {
            return Some(word);
        }
    }
    None
}

/// Rewrite ONE chosen line of the draft and put it back.
///
/// The line was chosen by the program, so the model is only asked for the
/// wording. The result is checked against the line it replaces -- a rewritten
/// line that lost most of its own characters is a fragment rather than an
/// edit, and a line that came back unchanged means the model did not apply the
/// instruction. Both are errors: the caller keeps the user's text, which is the
/// harmless outcome.
///
/// A deletion is handled here too, by the marker the model was asked to
/// output: the line is dropped and the rest of the draft is untouched.
fn edit_one_line(
    model_path: &Path,
    original: &str,
    draft: &[String],
    index: usize,
    instruction: &str,
    target: &EditTarget,
) -> Result<String> {
    let line = draft.get(index).ok_or_else(|| {
        EngineError::new(ErrorCode::InvalidArg, "the edit target is outside the draft")
    })?;
    // A POSITION instruction replaces the whole line with the new value, and
    // that is arithmetic, not interpretation: the program can do it exactly.
    // Asking the model for it measured worse than doing it -- "把第三點改成
    // 三樓會議室" came back as the line with the value in front of it, or as
    // the line unchanged, depending on the run.
    if let EditTarget::Position = target {
        if let Some(value) = replacement_value(instruction) {
            let mut items: Vec<String> = draft.to_vec();
            items[index] = keep_trailing_mark(line, &value);
            return Ok(tidy_output(&join_edited_items(original, &items)));
        }
    }
    // A deletion removes the line, and that is arithmetic too. The model is
    // only needed for a rewrite, where the wording is the model's job.
    if instruction_removes(instruction) {
        let mut items: Vec<String> = draft.to_vec();
        items.remove(index);
        return Ok(tidy_output(&join_edited_items(original, &items)));
    }
    // A CONTENT instruction that names a short word ("地點", "小林") is a plain
    // substitution, and doing it here is exact. The model is asked only when
    // the substitution cannot be made on its own.
    if let EditTarget::Content(word) = target {
        if let Some(value) = replacement_value(instruction) {
            if let Some(substituted) = substitute_in_draft(draft, index, word, &value) {
                let mut items: Vec<String> = draft.to_vec();
                items[index] = keep_trailing_mark(line, &substituted);
                return Ok(tidy_output(&join_edited_items(original, &items)));
            }
        }
    }
    let answer = generate(model_path, &edit_one_prompt(instruction, line, target))?;
    let rewritten = answer
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !looks_like_commentary(l))
        .unwrap_or("")
        .trim_matches(['"', '\'', '「', '」', '『', '』'])
        .trim();
    if rewritten.is_empty() {
        return Err(EngineError::new(ErrorCode::Inference, "the model returned no line"));
    }
    // The whole answer can be more than one line if the model ignored the
    // instruction; only the first line is the line's new wording.
    let deleted = rewritten == DELETED_LINE;
    if deleted {
        let mut items: Vec<String> = draft.to_vec();
        items.remove(index);
        return Ok(tidy_output(&join_edited_items(original, &items)));
    }
    if rewritten == *line {
        return Err(EngineError::new(ErrorCode::Inference, "the model returned the line unchanged"));
    }
    // A rewritten line that keeps almost nothing of the original is a fragment
    // of some other sentence, not this line edited. The same half-kept rule
    // the one-line path uses applies here.
    if retained_ratio(line, rewritten) < RETAINED_MIN {
        return Err(EngineError::new(
            ErrorCode::Inference,
            "the model's line is not an edit of the line it replaced",
        ));
    }
    let mut items: Vec<String> = draft.to_vec();
    items[index] = keep_trailing_mark(line, rewritten);
    Ok(tidy_output(&join_edited_items(original, &items)))
}

/// Replace a word INSIDE a line with a new value.
///
/// When the new value can stand in for the old word on its own -- the word is
/// the whole of what the instruction named ("地點" for "地點還沒確定"), or the
/// value is a name or a number that simply takes the word's place -- the
/// substitution is done here, exactly. The model was asked for the same thing
/// and came back with the word still in place ("地點改成三樓會議室" for
/// "地點還沒確定"): asked to replace one part of a line, it rewrote the line
/// instead.
///
/// The substitution only happens when the word appears ONCE. A word that
/// appears twice is a case where which occurrence the user meant is not
/// decidable here, and the model is asked instead.
fn substitute_in_line(line: &str, word: &str, value: &str) -> Option<String> {
    if word.is_empty() || value.is_empty() {
        return None;
    }
    if line.matches(word).count() != 1 {
        return None;
    }
    // The word has to be a NAME, a NUMBER or a short noun for the value to
    // stand in for it. A long noun is part of the sentence ("第四季時程"), and
    // a value cannot take its place: the model has to rewrite the clause.
    if word.chars().count() > 4 {
        return None;
    }
    // The value has to be a single term -- a name, a number, a time. Punctuation
    // means it is a phrase, and a phrase cannot stand in for a word.
    if value.chars().any(|c| {
        c.is_whitespace() || "，,。.、；;：:！!？?「」『』()（）".contains(c)
    }) {
        return None;
    }
    Some(line.replacen(word, value, 1))
}

/// The same substitution, but only when the word is on ONE line of the draft.
///
/// The line-level check in `substitute_in_line` cannot see the other lines, and
/// a word that is on two of them names no single line: "把三點改成四點" on a
/// draft whose first and third lines both say 三點 has two possible targets,
/// and taking the first one put the new time in the wrong place.
fn substitute_in_draft(draft: &[String], index: usize, word: &str, value: &str) -> Option<String> {
    let line = draft.get(index)?;
    if draft.iter().filter(|l| l.contains(word)).count() != 1 {
        return None;
    }
    substitute_in_line(line, word, value)
}

/// The NEW value an instruction carries, if it carries one.
///
/// "把第二點改成禮拜五" carries 禮拜五; "把地點改成三樓會議室" carries 三樓會議室.
/// The value is what sits after the change verb, and it is empty for a
/// deletion -- there is no new value in "刪掉第三句".
fn replacement_value(instruction: &str) -> Option<String> {
    let text = instruction.trim();
    if instruction_removes(text) {
        return None;
    }
    const CHINESE_VERBS: [&str; 5] = ["改成", "換成", "改為", "換", "改"];
    const ENGLISH_VERBS: [&str; 3] = ["change", "replace", "to"];
    for verb in CHINESE_VERBS.iter() {
        if let Some(at) = text.find(verb) {
            let value = text[at + verb.len()..].trim().trim_end_matches(['。', '.', '！', '!', '？', '?']);
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    for verb in ENGLISH_VERBS.iter() {
        if let Some(at) = text.to_lowercase().find(verb) {
            let value = text[at + verb.len()..].trim().trim_end_matches(['。', '.', '！', '!', '？', '?']);
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

/// Put the original line's trailing punctuation back on the rewritten line.
///
/// A draft's lines are clauses, and a clause carries the comma that separates it
/// from the next one. The model writes the new wording and leaves the comma
/// off -- "討論第四季時程，" comes back as "討論第四季禮拜五" -- so rejoining
/// the lines loses the punctuation and the clauses run together.
///
/// The mark is the original line's, not the model's: the model may well have
/// put a different one in the middle of the line, and only the END matters for
/// the join.
fn keep_trailing_mark(original: &str, rewritten: &str) -> String {
    let mark = original
        .trim_end()
        .chars()
        .last()
        .filter(|c| matches!(c, '，' | ',' | '；' | ';' | '、' | '。' | '.' | '！' | '!' | '？' | '?'));
    match mark {
        Some(mark) if !rewritten.trim_end().ends_with(mark) => {
            format!("{}{}", rewritten.trim_end(), mark)
        }
        _ => rewritten.to_string(),
    }
}

/// Reject an answer that cannot be the edited draft.
///
/// The dangerous shape is an answer that echoed only the line it changed: pasted,
/// it would replace the user's whole text with that fragment, and the text it
/// deleted would be gone. The draft's own line count is what makes that
/// detectable, and the instruction's words decide how many lines may
/// legitimately be missing -- a deletion loses lines, and nothing else does.
/// Adding lines is refused as well: the numbering is the user's text, and the
/// model was not asked to restructure it.
fn check_edited_shape(items: &[String], draft: &[String], instruction: &str, numbered: bool) -> Result<()> {
    if items.len() > draft.len() {
        return Err(EngineError::new(
            ErrorCode::Inference,
            "the model's answer has more lines than the draft",
        ));
    }
    // Lines may only be missing when the answer said which ones, i.e. when it came
    // numbered and the instruction asked for a removal. Up to three, because one
    // instruction can empty a short list ("前三句都刪掉"). Being wrong here costs a
    // refused edit and the text the user already had; being generous costs them
    // the text.
    let allowed_missing = if numbered && instruction_removes(instruction) { 3 } else { 0 };
    if items.len() + allowed_missing < draft.len() {
        return Err(EngineError::new(
            ErrorCode::Inference,
            "the model's answer does not account for every line of the draft",
        ));
    }
    Ok(())
}

/// Fraction of the draft's own characters that survive in the answer.
///
/// Only consulted for the one shape the line count cannot judge: a one-line draft
/// the model edited and then rejoined ("我明天要去開會。禮拜五下午兩點記得帶合約書" for
/// a draft numbered by its clauses). One line in, one line out -- there is nothing
/// to compare line by line, so what is compared is content, exactly as the cleanup
/// pass compares it for the same reason: an answer that kept most of the
/// speaker's characters is an edit of that text, and one that kept a small
/// fraction is a fragment of it.
fn retained_ratio(draft: &str, answer: &str) -> f32 {
    let characters: Vec<char> = draft.chars().filter(|c| is_cjk(*c)).collect();
    if characters.is_empty() {
        // Nothing to compare character by character; the count rules still apply.
        return 1.0;
    }
    let kept = characters.iter().filter(|c| answer.contains(**c)).count();
    kept as f32 / characters.len() as f32
}

/// Half the draft has to survive. A deletion of one clause in three keeps about
/// two thirds, and the fragments that must be refused (the model answering with
/// the one line it changed) keep about a third.
const RETAINED_MIN: f32 = 0.5;

/// Whether a one-line answer can be the edited version of a one-line draft.
///
/// Echoing the draft is not an edit, and a fragment of it is not one either.
fn single_line_answer_is_an_edit(text: &str, candidate: &str) -> bool {
    candidate != tidy_output(text) && retained_ratio(text, candidate) >= RETAINED_MIN
}

/// Whether the instruction asks for something to be removed.
///
/// Only consulted to decide how many lines the answer may be missing. A miss
/// costs a refused edit rather than a damaged text, which is the direction this
/// feature always fails in: the caller leaves the user's text alone.
fn instruction_removes(instruction: &str) -> bool {
    const CUES: [&str; 10] = [
        "刪", "删", "拿掉", "去掉", "移除", "不要", "delete", "remove", "drop", "cut",
    ];
    let lower = instruction.to_lowercase();
    CUES.iter().any(|cue| lower.contains(cue))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The lines of an answer, for the tests that only care about those.
    fn parse_edited_items(answer: &str) -> Vec<String> {
        parse_edited_answer(answer).0
    }

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

    /// The edit pass can leave the separator that used to join two clauses at the
    /// end of the line it rejoined; at a cursor that reads as an unfinished
    /// sentence.
    #[test]
    fn tidy_drops_a_trailing_separator() {
        assert_eq!(tidy_output("我明天要去開會，地點還沒確定，"), "我明天要去開會，地點還沒確定");
        assert_eq!(tidy_output("買牛奶、麵包、"), "買牛奶、麵包");
        assert_eq!(tidy_output("milk, bread,"), "milk, bread");
        // Interior separators are the speaker's punctuation and stay.
        assert_eq!(tidy_output("買牛奶，麵包"), "買牛奶，麵包");
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

    /// A spoken draft is one run-on line, so the numbering has to come from its
    /// clause marks -- otherwise "第二句" names a line the model never saw.
    #[test]
    fn a_run_on_draft_is_numbered_by_its_clauses() {
        assert_eq!(
            numbered_items("我先跟客戶確認規格，等下再回你，記得帶合約書"),
            vec!["我先跟客戶確認規格，", "等下再回你，", "記得帶合約書"]
        );
        // With a sentence end present, sentences win: they are what the speaker
        // hears as sentences.
        assert_eq!(
            numbered_items("先確認規格。等下再回你，記得帶合約"),
            vec!["先確認規格。", "等下再回你，記得帶合約"]
        );
    }

    /// A dot with no space after it is an item; a decimal point is not.
    #[test]
    fn a_dot_without_a_space_is_an_item_but_a_fraction_is_not() {
        assert_eq!(parse_edited_items("1.甲"), vec!["甲"]);
        // A decimal point is not a marker: the line is read as plain text rather
        // than as an item named "14", and it does not claim to be numbered.
        assert_eq!(parse_edited_answer("3.14 is pi").0, vec!["3.14 is pi"]);
        assert!(!parse_edited_answer("3.14 is pi").1);
    }

    /// The answer has to account for the draft: an answer that echoed one line is
    /// a fragment that would replace the whole text.
    #[test]
    fn an_answer_that_drops_a_line_is_refused_unless_the_instruction_deletes() {
        let draft: Vec<String> = ["甲", "乙", "丙"].iter().map(|s| s.to_string()).collect();
        assert!(check_edited_shape(&["新甲".to_string()], &draft, "把第一句改成新甲", true).is_err());
        assert!(check_edited_shape(&["甲".to_string(), "丙".to_string()], &draft, "第二句刪掉", true).is_ok());
        assert!(
            check_edited_shape(&["甲".to_string(), "丙".to_string()], &draft, "把第一句改成新甲", true).is_err(),
            "an answer that lost a line without being asked to delete is a fragment"
        );
        let four: Vec<String> = ["甲", "乙", "丙", "丁"].iter().map(|s| s.to_string()).collect();
        assert!(check_edited_shape(&four, &draft, "把第一句改成新甲", true).is_err());
        // Unnumbered lines cannot say WHICH line went, so a deletion is not
        // allowed to explain a short answer.
        assert!(
            check_edited_shape(&["甲".to_string(), "丙".to_string()], &draft, "第二句刪掉", false).is_err()
        );
    }

    /// The model answers with plain lines often enough to matter, and the same
    /// prompt produced both shapes on different runs. A plain answer of the right
    /// length is used; a remark is not an answer.
    #[test]
    fn a_plain_answer_is_read_but_only_if_it_accounts_for_the_draft() {
        assert_eq!(
            parse_edited_answer("跟客戶確認規格\n禮拜五下午兩點\n把報價單寄出去"),
            (
                vec!["跟客戶確認規格", "禮拜五下午兩點", "把報價單寄出去"]
                    .iter()
                    .map(|s| s.to_string())
                    .collect::<Vec<String>>(),
                false
            )
        );
        assert!(parse_edited_answer("好的，我改好了").0.is_empty());
        assert!(parse_edited_answer("以下是修改後的內容").0.is_empty());
    }

    /// The one-line case the line counts cannot judge, with the answer this model
    /// actually gave for that draft.
    #[test]
    fn a_rejoined_one_line_answer_is_an_edit_but_its_fragment_is_not() {
        let draft = "我明天要去開會，地點還沒確定，記得帶合約書";
        assert!(single_line_answer_is_an_edit(
            draft,
            "我明天要去開會。禮拜五下午兩點記得帶合約書"
        ));
        // The model echoing the draft is not an edit.
        assert!(!single_line_answer_is_an_edit(draft, draft));
        // One clause of three is a fragment, not an edit of the line.
        assert!(!single_line_answer_is_an_edit(draft, "禮拜五下午兩點"));
    }

    /// The bullets are the user's layout: they are stripped before the model sees
    /// the draft, so they are restored when the answer is rejoined.
    #[test]
    fn an_edited_bulleted_draft_keeps_its_bullets() {
        let items = ["甲".to_string(), "新乙".to_string()];
        assert_eq!(join_edited_items("• 甲\n• 乙", &items), "• 甲\n• 新乙");
        assert_eq!(join_edited_items("甲\n乙", &items), "甲\n新乙");
    }

    /// A position in the instruction names the line, whatever the wording.
    #[test]
    fn a_position_names_the_line() {
        let items = vec!["甲".to_string(), "乙".to_string(), "丙".to_string()];
        let position = EditTarget::Position;
        assert_eq!(locate_edit_target("把第二點改成禮拜五", &items), Some((1, position.clone())));
        assert_eq!(locate_edit_target("把第三句刪掉", &items), Some((2, position.clone())));
        assert_eq!(locate_edit_target("把第三行改成禮拜五", &items), Some((2, position.clone())));
        assert_eq!(locate_edit_target("第一點改成大衛", &items), Some((0, position.clone())));
        assert_eq!(locate_edit_target("把3改成禮拜五", &items), Some((2, position.clone())));
        assert_eq!(locate_edit_target("change the second one to Friday", &items), Some((1, position.clone())));
        // A position past the end of the draft names nothing: the whole-draft
        // path is the right fallback there, not a wrong line.
        assert_eq!(locate_edit_target("把第五點改成禮拜五", &items), None);
    }

    /// "第四季" is not a position: the character after the numeral decides.
    #[test]
    fn a_number_that_is_not_a_position_is_not_read_as_one() {
        let items = vec!["甲".to_string(), "乙".to_string(), "丙".to_string()];
        assert_eq!(locate_edit_target("把第四季改成第三季", &items), None);
    }

    /// A content word names the line that carries it, and the word itself is
    /// kept: the model is told to replace that word where it sits.
    #[test]
    fn a_content_word_names_the_line_that_carries_it() {
        let items = vec![
            "明天下午三點跟小林開會，".to_string(),
            "討論第四季時程，".to_string(),
            "地點還沒確定".to_string(),
        ];
        assert_eq!(
            locate_edit_target("把地點改成三樓會議室", &items),
            Some((2, EditTarget::Content("地點".to_string())))
        );
        assert_eq!(
            locate_edit_target("把小林改成大衛", &items),
            Some((0, EditTarget::Content("小林".to_string())))
        );
        assert_eq!(
            locate_edit_target("把第四季時程改成禮拜五", &items),
            Some((1, EditTarget::Content("第四季時程".to_string())))
        );
    }

    /// The replacement in the instruction is not a word to look for in the
    /// draft: it is the new value.
    #[test]
    fn the_replacement_is_not_used_as_a_search_word() {
        let items = vec![
            "明天下午三點跟小林開會，".to_string(),
            "討論第四季時程，".to_string(),
            "地點還沒確定".to_string(),
        ];
        // "禮拜五" appears nowhere in the draft, so the target has to be the
        // word before the verb.
        assert_eq!(
            locate_edit_target("把時程改成禮拜五", &items),
            Some((1, EditTarget::Content("時程".to_string())))
        );
    }

    /// The instruction the model gets for one line is rebuilt: the position is
    /// dropped, and a content target is named again so the replacement lands in
    /// the word's place.
    #[test]
    fn the_one_line_instruction_is_rebuilt_for_the_target() {
        assert_eq!(
            one_line_instruction("把第二點改成禮拜五", &EditTarget::Position),
            "把這行完全改成禮拜五"
        );
        assert_eq!(
            one_line_instruction("把小林改成大衛", &EditTarget::Content("小林".to_string())),
            "把這行裡的「小林」改成大衛，其他字不變"
        );
        assert_eq!(
            one_line_instruction("刪掉這行", &EditTarget::Position),
            "刪掉這行"
        );
    }

    /// The words an instruction names, with the verbs and the framing removed.
    #[test]
    fn the_named_word_is_taken_out_of_the_instruction() {
        assert_eq!(content_words("把地點改成三樓會議室"), vec!["地點"]);
        assert_eq!(content_words("把小林改成大衛"), vec!["小林"]);
        assert_eq!(content_words("把時程改成禮拜五"), vec!["時程"]);
        assert_eq!(content_words("把三點改成四點"), vec!["三點"]);
    }

    /// The whole path for one instruction: the draft's items, the word, and the
    /// line the word is on.
    #[test]
    fn a_word_in_a_run_on_draft_lands_on_its_own_clause() {
        let text = "明天下午三點跟小林開會，討論第四季時程，地點還沒確定";
        let items = numbered_items(text);
        assert_eq!(items.len(), 3);
        assert_eq!(
            locate_edit_target("把三點改成四點", &items),
            Some((0, EditTarget::Content("三點".to_string())))
        );
        // And the substitution happens on that clause.
        let substituted = substitute_in_draft(&items, 0, "三點", "四點");
        assert_eq!(substituted, Some("明天下午四點跟小林開會，".to_string()));
    }

    /// The line's own trailing punctuation comes back after the rewrite: a
    /// clause carries the comma that separates it from the next one.
    #[test]
    fn the_trailing_mark_survives_a_rewrite() {
        assert_eq!(
            keep_trailing_mark("討論第四季時程，", "討論第四季禮拜五"),
            "討論第四季禮拜五，"
        );
        // A line that already ends in a full stop keeps it.
        assert_eq!(keep_trailing_mark("地點還沒確定。", "三樓會議室"), "三樓會議室。");
        // Nothing to restore: the line has no trailing mark.
        assert_eq!(keep_trailing_mark("地點還沒確定", "三樓會議室"), "三樓會議室");
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
