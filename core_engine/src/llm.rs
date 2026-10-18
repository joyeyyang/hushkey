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
fn has_cjk(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(c as u32,
            0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x3040..=0x30ff | 0xac00..=0xd7af)
    })
}

/// Each section is a separate model call; the program owns the structure.
const SUMMARY_SYSTEM: &str = "You summarize meeting transcripts written in Chinese or English. \
Answer in the same language as the transcript. Use only facts from the transcript. Keep the answer short.";

pub const SECTION_SUMMARY: &str = "Write a short summary of this meeting in up to 3 sentences.";
pub const SECTION_DECISIONS: &str = "List the decisions the group agreed on. One per line, each starting with '- '. If none, reply with exactly: 无";
pub const SECTION_ACTIONS: &str = "List the action items with their owners. One per line, each starting with '- '. If none, reply with exactly: 无";

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
pub fn summary_prompt(instruction: &str, text: &str) -> String {
    chatml(SUMMARY_SYSTEM, &format!("{instruction}\n\nTranscript:\n{text}"))
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

/// Run one summary instruction over a text block. Used by the worker's `summarize` task.
pub fn summarize_one(model_path: &Path, instruction: &str, text: &str) -> Result<String> {
    generate_with(model_path, &summary_prompt(instruction, text), SUMMARY_MAX_TOKENS)
}
