//! Out-of-process LLM refinement. Reads one transcript from stdin, writes the refined
//! text to stdout, and exits. Exiting returns all LLM memory (weights, Metal buffers)
//! to the OS, so the parent process's peak RSS does not include them.
//!
//! Usage: ovc-llm-worker <model.gguf>   (stdin: UTF-8 text, stdout: UTF-8 text)

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let model = match std::env::args().nth(1) {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!("usage: ovc-llm-worker <model.gguf>");
            return ExitCode::from(2);
        }
    };
    let mut input = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("stdin: {e}");
        return ExitCode::from(2);
    }
    let prompt = offline_voice_core::llm_prompt(input.trim());
    match offline_voice_core::llm_generate(&model, &prompt) {
        Ok(text) => {
            let mut out = std::io::stdout().lock();
            if out.write_all(text.as_bytes()).and_then(|_| out.flush()).is_err() {
                return ExitCode::from(3);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{}", e.msg);
            ExitCode::from(1)
        }
    }
}
