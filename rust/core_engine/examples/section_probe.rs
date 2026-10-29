//! Puts ONE summary section's prompt in front of the model, so a bad line can be
//! traced to the prompt or to the model instead of guessed at.
//!
//! Usage: section_probe <summary|decisions|actions> [file]
//! Reads the transcript from the file (or a built-in sample), prints the answer.

fn main() {
    let mut args = std::env::args().skip(1);
    let section = args.next().unwrap_or_else(|| "actions".to_string());
    let instruction = match section.as_str() {
        "summary" => offline_voice_core::llm::SECTION_SUMMARY,
        "decisions" => offline_voice_core::llm::SECTION_DECISIONS,
        _ => offline_voice_core::llm::SECTION_ACTIONS,
    };
    let text = match args.next() {
        Some(path) => std::fs::read_to_string(path).expect("read transcript"),
        None => "好那我們今天會議開始。第一個是上線時間，大家討論之後就決定下週三正式上線，其他頁面之後再排。第二個是廣告預算，決定砍三成，多出來的部分先保留。客服的部分，怡君你下週五以前要生出客服的 SOP。志豪這週四以前把測試報告整理好寄給我。然後我這邊下週一以前把合約草稿送給法務。行銷的部分先不動，等產品穩定再說。大家還有問題嗎？沒有就這樣。".to_string(),
    };

    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../models");
    // Same resolution the engine uses: OVC_LLM_MODEL overrides the filename, and
    // the file lives under llm/.
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

    let prompt = offline_voice_core::llm::summary_prompt(instruction, &text);
    if std::env::var("PROBE_PROMPT").is_ok() {
        eprintln!("{prompt}");
    }
    match offline_voice_core::llm::generate(&model, &prompt) {
        Ok(answer) => println!("{answer}"),
        Err(e) => {
            eprintln!("generate failed: {e:?}");
            std::process::exit(1);
        }
    }
}
