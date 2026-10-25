//! Runs many voice-edit cases against ONE loaded model, so a batch of them can
//! be measured in one go instead of paying the model load for each.
//!
//! Usage: edit_batch <cases-file>
//! The file holds one case per line: `<instruction>\t<draft>` -- a tab between
//! the two, the draft may contain spaces and commas. Each line prints the
//! instruction, the draft, the raw answer, and whether the answer differs from
//! the draft.

use std::path::Path;

fn main() {
    let path = std::env::args().nth(1).expect("usage: edit_batch <cases-file>");
    let body = std::fs::read_to_string(&path).expect("read cases");

    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../models");
    let chosen = std::env::var("OVC_LLM_MODEL")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "Qwen3.5-2B-Q4_K_M.gguf".to_string());
    let model = dir.join("llm").join(&chosen);
    if !model.exists() {
        eprintln!("model not found: {}", model.display());
        std::process::exit(1);
    }

    let cases: Vec<(String, String)> = body
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| {
            let (instruction, draft) = l.split_once('\t')?;
            Some((instruction.trim().to_string(), draft.trim().to_string()))
        })
        .collect();
    if cases.is_empty() {
        eprintln!("no cases");
        std::process::exit(1);
    }

    let mut changed = 0;
    for (instruction, draft) in &cases {
        let prompt = offline_voice_core::llm::edit_prompt(instruction, draft);
        match offline_voice_core::llm::generate(&model, &prompt) {
            Ok(answer) => {
                // The answer comes back numbered; the draft does not. Strip the
                // numbers and rejoin the way the draft was written before
                // comparing, or every case would look "changed".
                let stripped: Vec<&str> = answer
                    .lines()
                    .filter_map(|line| {
                        let t = line.trim();
                        let rest = t.split_once(". ").map(|(_, r)| r).unwrap_or(t);
                        if rest.is_empty() {
                            None
                        } else {
                            Some(rest)
                        }
                    })
                    .collect();
                let rejoined = stripped.join("");
                let differs = rejoined.trim() != draft.trim();
                if differs {
                    changed += 1;
                }
                println!("--- {instruction}");
                println!("  draft:  {draft}");
                println!("  answer: {}", answer.trim().replace('\n', " | "));
                println!("  changed: {}", if differs { "YES" } else { "no" });
            }
            Err(e) => {
                println!("--- {instruction}");
                println!("  ERROR: {e:?}");
            }
        }
    }
    println!("=== {}/{} changed", changed, cases.len());
}
