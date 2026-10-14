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

static BACKEND: OnceLock<std::result::Result<LlamaBackend, String>> = OnceLock::new();

fn backend() -> Result<&'static LlamaBackend> {
    BACKEND
        .get_or_init(|| LlamaBackend::init().map_err(|e| e.to_string()))
        .as_ref()
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("llama backend init: {e}")))
}

/// Build the ChatML prompt for Qwen2.5. Instructs the model to only fix
/// punctuation, remove filler words, and keep meaning and language unchanged.
pub fn refine_prompt(text: &str) -> String {
    format!(
        "<|im_start|>system\nYou clean up speech transcripts. Fix punctuation, remove filler words \
         (如:嗯、啊、那個), and keep the original meaning and language. Output only the cleaned text.<|im_end|>\n\
         <|im_start|>user\n{text}<|im_end|>\n<|im_start|>assistant\n"
    )
}

/// Load the model, run greedy generation on `prompt`, and return the decoded text.
pub fn generate(model_path: &Path, prompt: &str) -> Result<String> {
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
    for _ in 0..MAX_NEW_TOKENS {
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
