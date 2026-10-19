//! Qwen2.5-Instruct (GGUF Q4_K_M, currently 1.5B) text refinement via llama.cpp.
//! Loaded on demand and dropped after each call so idle memory stays low.
//!
//! Refinement goal (Typeless-style):
//!  - Remove filler words and disfluencies.
//!  - Resolve self-corrections: keep only the final intended text.
//!  - Auto-format lists, steps, and key points into clean structure.
//!  - Keep the original language; do not translate or paraphrase meaning.

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
/// purpose: the worked example teaches the format better than more rules do.
/// System line for the refine turn. Rules live here and are kept to ONE
/// paragraph on purpose -- the shape of the task is taught by the worked
/// examples below, which a small model imitates far more reliably than a longer
/// rule list. Traditional Chinese is enforced afterwards in code, not here.
const REFINE_SYSTEM: &str = "把使用者的口語改寫成通順的書面文字，只輸出改寫後的內容。\
不要摘要、不要漏掉任何一件事；重複講的同一件事只留一次；刪掉口頭禪和多餘的字；\
只有一個重點就寫一句，多個重點就一行一個、行首加「• 」；\
數字、時間、名字照原樣保留；問句保持問句；語言跟原文相同。";

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
const REFINE_EXAMPLES_ZH: [(&str, &str); 2] = [
    (
        "嗯那個下週三下午三點半你有空嗎，我要跟你討論那個八十萬的案子，然後記得帶合約，喔對你有空嗎",
        "下週三下午三點半你有空嗎？我要跟你討論八十萬的案子，記得帶合約。",
    ),
    // A repeated clause followed by a DIFFERENT short clause: the repeat goes,
    // the new clause stays. Without this pair the model treated the whole
    // repeated sentence -- including the fresh demand hanging off its end -- as
    // one repeat and dropped it ("不要遲到" was silently lost in testing).
    (
        "嗯我明天下午要去拜訪客戶然後記得帶名片喔對我明天下午要去拜訪客戶不要忘記",
        "我明天下午要去拜訪客戶，記得帶名片，不要忘記。",
    ),
];

const REFINE_EXAMPLES_EN: [(&str, &str); 2] = [
    (
        "um so I think uh we should probably ship this you know next week because the client is waiting",
        "We should ship this next week because the client is waiting.",
    ),
    // Teaches that a question comes back as a question. Without it the model
    // turned "can you send the report before then?" into "Please send the
    // report before then." -- an ask came back as an order (observed).
    (
        "um can you uh send me the report before the meeting? the report before the meeting",
        "Can you send me the report before the meeting?",
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
the transcript says. If there are none, reply with exactly: 无";
/// The Chinese form of the 決議 instruction. Kept separate for a measured reason,
/// not for its own sake: with the English instruction, a Chinese transcript that
/// is mostly imperatives leaked the assignments into the decision
/// (`珮婷整理使用者訪談紀錄`, `問設計公司報價`) with the very examples that are
/// clean under the Chinese wording. The system line still decides the OUTPUT
/// language; this decides what the model thinks it is being asked for.
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

/// Empty on purpose -- see the note above the Chinese set. Adding an English
/// example re-introduces assignment leakage that was measured three times.
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
    Ok(String::from_utf8_lossy(&out).trim().to_string())
}

/// Refine one transcript chunk with optional keywords hint.
pub fn refine(model_path: &Path, text: &str) -> Result<String> {
    refine_with_keywords(model_path, text, "")
}

/// Refine with a keywords hint, which is added to the system line so the model
/// can spell names and jargon the way the user does.
pub fn refine_with_keywords(model_path: &Path, text: &str, keywords_hint: &str) -> Result<String> {
    generate(model_path, &refine_prompt_with_hint(text, keywords_hint))
}

/// Two-stage refine: first understand the speech, then tidy it.
///
/// Both stages run against ONE loaded model, so the extra quality costs a second
/// generation rather than a second model load. Stage 1 is skipped as an input if
/// it comes back empty, and stage 2 falls back to stage 1's output.
pub fn refine_two_stage(model_path: &Path, text: &str, keywords_hint: &str) -> Result<String> {
    let be = backend()?;
    let model = LlamaModel::load_from_file(be, model_path, &LlamaModelParams::default())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", model_path.display())))?;

    // Stage 1 rewrites at roughly the input's own length, so its cap scales;
    // stage 2 only condenses, so the normal cap is plenty.
    let stage1_max = (text.chars().count() * 2).clamp(MAX_NEW_TOKENS, STAGE1_MAX_TOKENS);
    let understood = generate_in(&model, &understand_prompt(text), stage1_max)?;
    let middle = if understood.trim().is_empty() { text.to_string() } else { understood };

    let condensed = generate_in(&model, &refine_prompt_with_hint(&middle, keywords_hint), MAX_NEW_TOKENS)?;
    if condensed.trim().is_empty() {
        return Ok(middle);
    }
    Ok(condensed)
}

/// One entry point for both refine shapes. `stages` is 1 (single pass), 2
/// (understand then condense), or 0 for "decide by length" -- see
/// `state::refine_text_with_keywords_stages`.
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
