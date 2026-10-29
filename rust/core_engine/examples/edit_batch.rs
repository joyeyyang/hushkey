//! Runs many voice-edit cases against ONE loaded model, so a batch of them can
//! be measured in one go instead of paying the model load for each.
//!
//! Usage: edit_batch <cases-file>
//! The file holds one case per line: `<instruction>\t<draft>` -- a tab between
//! the two, the draft may contain spaces and commas. A case that is about a
//! MULTI-LINE draft writes `\n` for its line breaks: the file is line-oriented,
//! so a literal newline would end the case. Each line prints the
//! instruction, the draft, the raw answer, and whether the answer differs from
//! the draft.
//!
//! The cases go through `state::edit_text` -- the path the app, the kit and
//! the command line all use -- not straight to the model. The model's raw
//! answer is a NUMBERED list; the product's job is to find the line the
//! instruction names, change that line, and hand back the draft's own shape.
//! Measuring the raw model measures something the user never sees.

fn main() {
    let path = std::env::args().nth(1).expect("usage: edit_batch <cases-file>");
    let body = std::fs::read_to_string(&path).expect("read cases");

    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../models");
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

    // A case is `<instruction>\t<draft>` and, when the answer is known,
    // `<instruction>\t<draft>\t<expected>`. The columns are split off the
    // TABS, not on a whitespace boundary: the draft is Chinese prose and may
    // contain spaces, and the expected answer may too.
    // `\n` is the only escape: a multi-line draft is the whole point of the
    // line/region cases, and a real newline would split the row.
    fn unescape(s: &str) -> String {
        s.replace("\\n", "\n")
    }

    let mut cases: Vec<(String, String, Option<String>)> = Vec::new();
    for line in body.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let mut parts = line.split('\t');
        let Some(instruction) = parts.next() else { continue };
        let Some(draft) = parts.next() else { continue };
        cases.push((
            instruction.trim().to_string(),
            unescape(draft.trim()),
            parts.next().map(|e| unescape(e.trim())),
        ));
    }
    if cases.is_empty() {
        eprintln!("no cases");
        std::process::exit(1);
    }

    // The core has to know where the models are before it can hand the worker
    // a path to one. This is the same call the app and the kit make at start.
    // `dir` is already the models root; the model lives under its `llm/`.
    if let Err(e) = offline_voice_core::state::set_models_dir(dir.clone()) {
        eprintln!("could not set the models dir: {e:?}");
        std::process::exit(1);
    }

    // The expected answer for each case, when the cases file names one. The
    // file holds `<instruction>\t<draft>\t<expected>`; a two-column file has
    // no expectation and only reports what came out.
    let mut changed = 0;
    let mut right = 0;
    let mut checked = 0;
    for (instruction, draft, expected) in &cases {
        // The product path: the same call the app makes, through the worker.
        match offline_voice_core::state::edit_text(draft, instruction) {
            Ok(answer) => {
                // The answer is already the draft's own shape -- the product
                // put the changed line back where it was and left the others
                // alone. So a plain comparison is the right one here.
                let differs = answer.trim() != draft.trim();
                if differs {
                    changed += 1;
                }
                let mut verdict = if differs { "changed" } else { "UNCHANGED" };
                if let Some(expected) = expected {
                    checked += 1;
                    if answer.trim() == expected {
                        right += 1;
                        verdict = "RIGHT";
                    } else {
                        verdict = "WRONG";
                        println!("  wanted: {expected}");
                    }
                }
                println!("--- {instruction}");
                println!("  draft:  {}", draft.replace('\n', " | "));
                println!("  answer: {}", answer.trim().replace('\n', " | "));
                println!("  changed: {}", if differs { "YES" } else { "no" });
                println!("  verdict: {verdict}");
            }
            Err(e) => {
                println!("--- {instruction}");
                println!("  ERROR: {e:?}");
            }
        }
    }
    println!("=== {}/{} changed", changed, cases.len());
    if checked > 0 {
        println!("=== {}/{} right", right, checked);
    }
}
