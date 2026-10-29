//! Prints which ASR file the engine actually loads, and how big it is.
//!
//! The loader prefers Dolphin, then SenseVoice int8, then SenseVoice fp32, and
//! a normal install has more than one of them on disk -- so "which model are we
//! running" cannot be answered from the manifest or the log, only from the bytes
//! the engine reports after it has opened one. That is what `memory_usage()`
//! returns.
//!
//! Usage: cargo run --release --example asr_probe [models-dir]
//! Default models dir: ~/Library/Application Support/OfflineVoiceAssistant/models

use std::path::{Path, PathBuf};

fn size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn main() {
    let dir = std::env::args().nth(1).map(PathBuf::from).unwrap_or_else(|| {
        let home = std::env::var("HOME").expect("HOME");
        PathBuf::from(home).join("Library/Application Support/OfflineVoiceAssistant/models")
    });
    println!("models dir: {}", dir.display());

    let candidates = [
        ("dolphin", "asr/dolphin/model.int8.onnx", "asr/dolphin/tokens.txt"),
        ("sense int8", "asr/model.int8.onnx", "asr/tokens.txt"),
        ("sense fp32", "asr/model.onnx", "asr/tokens.txt"),
    ];
    let mut expected: Vec<(&str, u64)> = Vec::new();
    for (label, model, tokens) in candidates {
        let m = dir.join(model);
        let t = dir.join(tokens);
        let (mb, tb) = (size(&m), size(&t));
        println!(
            "{label:>10}: model {} ({}), tokens {} ({})",
            m.display(),
            if mb > 0 { format!("{mb} bytes") } else { "missing".to_string() },
            t.display(),
            if tb > 0 { format!("{tb} bytes") } else { "missing".to_string() }
        );
        if mb > 0 && tb > 0 {
            expected.push((label, mb + tb));
        }
    }

    if let Err(e) = offline_voice_core::set_models_dir(dir.clone()) {
        eprintln!("set_models_dir failed: {e:?}");
        std::process::exit(1);
    }
    if let Err(e) = offline_voice_core::load_asr() {
        eprintln!("load_asr failed: {e:?}");
        std::process::exit(1);
    }
    let usage = offline_voice_core::memory_usage();

    let which = expected
        .iter()
        .find(|(_, bytes)| *bytes == usage.model_bytes)
        .map(|(label, _)| *label)
        .unwrap_or("unknown");
    println!(
        "loaded: model_bytes={} peak_rss={} -> {}",
        usage.model_bytes, usage.peak_rss_bytes, which
    );
    for (label, bytes) in &expected {
        println!(
            "expect {label}: {bytes} bytes ({} MiB)",
            bytes / 1024 / 1024
        );
    }
}
