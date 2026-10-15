//! Qwen2.5-0.5B-Instruct (GGUF Q4_K_M) text refinement via llama.cpp.
//! Loaded on demand and dropped after each call so idle memory stays low.

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
/// Summaries run longer than refinement output and need the same context budget.
pub const SUMMARY_MAX_TOKENS: usize = 400;

static BACKEND: OnceLock<std::result::Result<LlamaBackend, String>> = OnceLock::new();

fn backend() -> Result<&'static LlamaBackend> {
    BACKEND
        .get_or_init(|| LlamaBackend::init().map_err(|e| e.to_string()))
        .as_ref()
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("llama backend init: {e}")))
}

/// Chinese instruction measured to remove filler words; the English version kept them.
const REFINE_SYSTEM: &str = "你是语音转写润饰助手。任务：删除口头禅和无意义语气词（嗯、啊、呃、那个、就是），补全标点。严格要求：不得删除或改写任何有实际含义的词语、数字、人名、观点和动作；保持原语言；只输出润饰后的文字，不要解释。";

/// Each section is a separate model call; the program owns the structure.
const SUMMARY_SYSTEM: &str = "You summarize meeting transcripts written in Chinese or English. \
Answer in the same language as the transcript. Use only facts from the transcript. Keep the answer short.";

pub const SECTION_SUMMARY: &str = "Write a short summary of this meeting in up to 3 sentences.";
pub const SECTION_DECISIONS: &str = "List the decisions the group agreed on. One per line, each starting with '- '. If none, reply with exactly: 无";
pub const SECTION_ACTIONS: &str = "List the action items with their owners. One per line, each starting with '- '. If none, reply with exactly: 无";

fn chatml(system: &str, user: &str) -> String {
    format!("<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n")
}

/// Prompt for cleaning one transcript chunk.
pub fn refine_prompt(text: &str) -> String {
    chatml(REFINE_SYSTEM, text)
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

/// Refine one transcript chunk. Used by the worker's `refine` task.
pub fn refine(model_path: &Path, text: &str) -> Result<String> {
    generate(model_path, &refine_prompt(text))
}

/// Run one summary instruction over a text block. Used by the worker's `summarize` task.
pub fn summarize_one(model_path: &Path, instruction: &str, text: &str) -> Result<String> {
    generate_with(model_path, &summary_prompt(instruction, text), SUMMARY_MAX_TOKENS)
}
