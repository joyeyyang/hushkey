//! Out-of-process LLM refinement. Reads one transcript (or, for `edit`, the text the
//! user already has) from stdin, writes the result to stdout, and exits. Exiting returns
//! all LLM memory (weights, Metal buffers) to the OS, so the parent process's peak RSS
//! does not include them.
//!
//! Usage: ovc-llm-worker <refine|refine-two-stage|summary|translate|edit> <model.gguf> [instruction]
//! `instruction` is, per task: the keywords hint (refine, refine-two-stage), the section
//! instruction (summary), the target language (translate), or the spoken edit instruction
//! (edit). stdin: UTF-8 text. stdout: UTF-8 result. Exit code 0 on success.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: ovc-llm-worker <refine|refine-two-stage|summary|translate|edit> <model.gguf> [instruction]");
        return ExitCode::from(2);
    }
    let task = args[1].as_str();
    let model = PathBuf::from(&args[2]);
    let instruction = args.get(3).cloned().unwrap_or_default();
    let mut input = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("stdin: {e}");
        return ExitCode::from(2);
    }
    let result = match task {
        "refine" => offline_voice_core::llm_refine_with_keywords(&model, input.trim(), &instruction),
        "refine-two-stage" => offline_voice_core::llm_refine_two_stage(&model, input.trim(), &instruction),
        "summary" => offline_voice_core::llm_summarize_one(&model, &instruction, input.trim()),
        "translate" => offline_voice_core::llm_translate(&model, input.trim(), &instruction),
        "edit" => offline_voice_core::llm_edit(&model, input.trim(), &instruction),
        other => {
            eprintln!("unknown task: {other}");
            return ExitCode::from(2);
        }
    };
    match result {
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
