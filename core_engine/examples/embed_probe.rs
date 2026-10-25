//! Measures the retrieval model on real Traditional-Chinese material, and prints
//! the RAW cosine numbers.
//!
//! Two decisions depend on these numbers and neither can be read off the model
//! card:
//!
//!   1. Where the term-relevance floor belongs. Too low and every term survives
//!      (the narrowing does nothing); too high and a name the speaker really said
//!      is dropped, which costs the user a manual fix.
//!   2. Where the instruction-screening floor belongs. `clause_candidates`' cue
//!      list is only a cost filter, so the probe deliberately scores EVERY clause
//!      — measuring through the filter would hide exactly the false negatives the
//!      cue list causes.
//!
//! Usage: embed_probe <embeddinggemma.gguf>

use std::path::PathBuf;
use std::time::Instant;

use offline_voice_core::{embed_cosine, embed_documents, embed_queries, embed_screen};
use offline_voice_core::embed::EDIT_EXEMPLARS;

/// Terms a user might keep, split into the ones a given draft should match and
/// the ones it should not. The pairs are chosen to be genuinely confusable
/// (林口廠 vs 小林, 王經理 vs 小林) rather than obviously unrelated: an unrelated
/// term proves nothing about the threshold.
const SHOULD_MATCH: &[&str] = &["小林", "隼", "第四季", "Figma"];
const SHOULD_NOT: &[&str] = &[
    "林口廠",
    "王經理",
    "Onboarding",
    "供應商名單",
    "年度預算",
    "客服信箱",
    "小林設計",
    "季度報告",
    "第四台",
    "UIKit",
];

const DRAFT: &str = "明天下午三點要跟小林開會，討論隼的第四季時程，Figma 的稿子我會先更新。";

/// Clauses that really are instructions about the draft, including phrasings the
/// cue list does NOT contain — those are the ones worth knowing about.
const INSTRUCTIONS: &[&str] = &[
    "把前面那句刪掉",
    "第二點不要",
    "時間改成四點",
    "幫我翻成英文",
    "把地點那句拿掉",
    "講短一點",
    "後面那半段不用",
    "這句拿掉",
    "換成禮拜五",
];

/// Ordinary speech. The first three are ordinary clauses with no cue at all; the
/// next two contain a cue word but are not instructions, which is the false
/// positive the margin has to survive.
const ORDINARY: &[&str] = &[
    "明天下午三點開會",
    "我今天要去開會",
    "這個 API 的 rate limit 是多少？",
    "我不要再等了",
    "會議室在二樓",
    "他說時間會改",
    "東西先放著就好",
    "會議室改成二樓",
    "我要加薪",
    "東西先不要動",
    "補充一下我的想法",
    "順序是這樣沒錯",
];

/// Instruction phrasings deliberately NOT in `EDIT_EXEMPLARS`. Without these the
/// measurement is circular: a clause that IS an exemplar scores 1.0 by
/// construction and proves only that the exemplar list contains the exemplar list.
const HELD_OUT: &[&str] = &[
    "前面不要了",
    "第二句刪掉",
    "把時間改成五點半",
    "幫我寫成日文",
    "講得簡單一點",
    "最後一句拿掉",
    "順序換一下",
    "幫我加一句問候",
];

/// A real dictation, split the way the screener splits it, so the probe shows the
/// pass over running speech rather than over curated single clauses.
const RUNNING_SPEECH: &str = "呃就是明天下午三點要跟小林開會，討論隼的第四季時程，把地點那句拿掉，我還沒確定，另外 Figma 的稿子我會先更新";

fn main() {
    let model = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .expect("usage: embed_probe <embeddinggemma.gguf>");

    terms(&model);
    screening(&model);
    running(&model);
}

fn terms(model: &std::path::Path) {
    println!("=== 詞彙檢索：草稿對每個詞的餘弦 ===");
    println!("草稿：{DRAFT}\n");
    let started = Instant::now();
    let query = match embed_queries(model, &[DRAFT.to_string()]) {
        Ok(v) => v.into_iter().next().unwrap_or_default(),
        Err(e) => return println!("失敗：{}", e.msg),
    };
    let all: Vec<String> = SHOULD_MATCH
        .iter()
        .chain(SHOULD_NOT.iter())
        .map(|t| t.to_string())
        .collect();
    let docs = match embed_documents(model, &all) {
        Ok(v) => v,
        Err(e) => return println!("失敗：{}", e.msg),
    };
    let mut rows: Vec<(String, f32, bool)> = all
        .iter()
        .zip(docs.iter())
        .map(|(t, d)| {
            let score = embed_cosine(&query, d);
            (t.clone(), score, SHOULD_MATCH.contains(&t.as_str()))
        })
        .collect();
    rows.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    for (term, score, wanted) in &rows {
        println!(
            "  {term:<14} {score:.4}   {}",
            if *wanted { "（該抓到）" } else { "（不該抓到）" }
        );
    }
    let worst_kept = rows
        .iter()
        .filter(|(_, _, w)| *w)
        .map(|(_, s, _)| *s)
        .fold(f32::INFINITY, f32::min);
    let best_dropped = rows
        .iter()
        .filter(|(_, _, w)| !*w)
        .map(|(_, s, _)| *s)
        .fold(f32::NEG_INFINITY, f32::max);
    println!(
        "\n  最低的「該抓到」= {worst_kept:.4}   最高的「不該抓到」= {best_dropped:.4}   間隙 = {:.4}",
        worst_kept - best_dropped
    );
    println!("  （{:.0} ms）", started.elapsed().as_millis() as f64);
}

fn screening(model: &std::path::Path) {
    println!("\n=== 指令篩選：每個句子對範例句的最大餘弦（跳過前置過濾）===");
    let started = Instant::now();
    let exemplars: Vec<String> = EDIT_EXEMPLARS.iter().map(|e| e.to_string()).collect();
    let ex = match embed_queries(model, &exemplars) {
        Ok(v) => v,
        Err(e) => return println!("失敗：{}", e.msg),
    };
    let score_of = |clause: &str| -> Option<f32> {
        let q = embed_queries(model, &[clause.to_string()]).ok()?.into_iter().next()?;
        Some(
            ex.iter()
                .map(|e| embed_cosine(&q, e))
                .fold(f32::NEG_INFINITY, f32::max),
        )
    };

    let mut instr_scores = Vec::new();
    println!("-- 真的是指令");
    for clause in INSTRUCTIONS {
        match score_of(clause) {
            Some(s) => {
                instr_scores.push(s);
                println!("  {clause:<16} {s:.4}");
            }
            None => println!("  {clause:<16} 失敗"),
        }
    }
    let mut held_scores = Vec::new();
    println!("-- 保留樣本（不在範例表裡，這才是真正的召回）");
    for clause in HELD_OUT {
        match score_of(clause) {
            Some(s) => {
                held_scores.push((clause, s));
                println!("  {clause:<16} {s:.4}");
            }
            None => println!("  {clause:<16} 失敗"),
        }
    }
    let kept = held_scores.iter().filter(|(_, s)| *s >= 0.72).count();
    println!(
        "  保留樣本通過門檻 0.72 的比例：{kept}/{}",
        held_scores.len()
    );

    let mut ord_scores = Vec::new();
    println!("-- 一般說話");
    for clause in ORDINARY {
        match score_of(clause) {
            Some(s) => {
                ord_scores.push(s);
                println!("  {clause:<24} {s:.4}");
            }
            None => println!("  {clause:<24} 失敗"),
        }
    }
    let worst_instr = instr_scores.iter().cloned().fold(f32::INFINITY, f32::min);
    let best_ord = ord_scores.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    println!(
        "\n  最低的「是指令」= {worst_instr:.4}   最高的「一般說話」= {best_ord:.4}   間隙 = {:.4}",
        worst_instr - best_ord
    );
    println!(
        "  可行的門檻區間：({best_ord:.3}, {worst_instr:.3})，中點 {:.3}",
        (best_ord + worst_instr) / 2.0
    );
    println!("  （{:.0} ms，{} 句）", started.elapsed().as_millis() as f64, INSTRUCTIONS.len() + ORDINARY.len());
}

fn running(model: &std::path::Path) {
    println!("\n=== 真實聽寫逐句過一次篩選（含前置過濾的實際行為）===");
    println!("{RUNNING_SPEECH}\n");
    let started = Instant::now();
    match embed_screen(model, None, &[], RUNNING_SPEECH, 0, 0.38, 0.72) {
        Ok(result) => {
            println!("  判定為指令：{:?}", result.edit_clauses);
            println!("  最高分：{:.4}", result.top_edit_score);
        }
        Err(e) => println!("  失敗：{}", e.msg),
    }
    println!("  （{:.0} ms）", started.elapsed().as_millis() as f64);
}
