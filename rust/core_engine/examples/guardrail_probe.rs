//! The guardrail through the C ABI the two apps actually call.
//!
//! `cargo test` covers the rules (`src/guardrail.rs`), but it calls them as Rust
//! functions. The apps call `LLM_CheckOutput`, and a `#[no_mangle]` entry point
//! is the one thing a unit test inside the crate cannot reach -- an example links
//! the rlib, so this is the harness that does. It is the difference between
//! "the rules are right" and "the rules are wired": an argument in the wrong
//! order, or a reason that never gets written, would pass every unit test and
//! still ship.
//!
//! Usage: guardrail_probe
//! Exit 0 when every case matches, 1 otherwise. No model, no audio, no state --
//! so it runs in a second and can live in `scripts/verify.sh`.
//!
//! A case is `(raw, refined, mode, tone, expect_ok)`. Both directions are
//! covered on purpose: a gate that rejects everything passes every "catches the
//! bad answer" case and loses every dictation.

use std::ffi::{c_char, CString};

use offline_voice_core::{Core_FreeString, LLM_CheckOutput};

/// Runs one case through the ABI and returns the reason string (`""` = accept).
fn check(raw: &str, refined: &str, mode: &str, tone: &str) -> Result<String, String> {
    let raw_c = CString::new(raw).map_err(|e| e.to_string())?;
    let refined_c = CString::new(refined).map_err(|e| e.to_string())?;
    let mode_c = CString::new(mode).map_err(|e| e.to_string())?;
    let tone_c = CString::new(tone).map_err(|e| e.to_string())?;
    let mut out: *mut c_char = std::ptr::null_mut();
    let rc = unsafe {
        LLM_CheckOutput(
            raw_c.as_ptr(),
            refined_c.as_ptr(),
            mode_c.as_ptr(),
            tone_c.as_ptr(),
            &mut out,
        )
    };
    if rc != 0 {
        return Err(format!("status {rc}"));
    }
    if out.is_null() {
        return Err("no reason written".to_string());
    }
    let reason = unsafe { std::ffi::CStr::from_ptr(out) }
        .to_string_lossy()
        .into_owned();
    unsafe { Core_FreeString(out) };
    Ok(reason)
}

fn main() {
    let raw = "嗯那個明天下午三點跟小林開會，討論第四季時程，地點還沒確定";
    let cases: [(&str, &str, &str, &str, bool, &str); 8] = [
        // A real cleanup: must pass, in every register.
        (
            raw,
            "明天下午三點與小林開會，討論第四季時程，地點尚未確定",
            "refine",
            "normal",
            true,
            "a faithful cleanup",
        ),
        (
            raw,
            "明天下午三點與小林開會，討論第四季時程，地點尚未確定",
            "refine",
            "formal",
            true,
            "a faithful cleanup in 正式",
        ),
        // Answering the prompt instead of the draft.
        (
            raw,
            "以下是整理後的版本：明天下午三點開會",
            "refine",
            "normal",
            false,
            "meta phrasing",
        ),
        // A summary where a rewrite was asked for.
        (raw, "開會", "refine", "normal", false, "far too short"),
        // The script changed under the model's own hand.
        (
            "這個會議記錄要寄給客戶",
            "这个会议记录要寄给客户",
            "refine",
            "normal",
            false,
            "simplified introduced",
        ),
        // An edit may delete lines -- that is what half the instructions ask for.
        (
            "明天下午三點跟小林開會\n討論第四季時程\n地點還沒確定",
            "明天下午三點跟小林開會\n地點還沒確定",
            "edit",
            "normal",
            true,
            "an edit that deleted a line",
        ),
        // An edit may not be a remark.
        (
            "明天下午三點跟小林開會\n討論第四季時程",
            "以下是修改後的版本",
            "edit",
            "normal",
            false,
            "an edit that answered the instructions",
        ),
        // An unknown tone is "normal", not an error: a settings typo must not
        // cost the user their sentence.
        (
            raw,
            "明天下午三點與小林開會，討論第四季時程，地點尚未確定",
            "refine",
            "正式",
            true,
            "an unknown tone falls back to normal",
        ),
    ];

    let mut failed = 0;
    for (raw, refined, mode, tone, expect_ok, name) in cases {
        match check(raw, refined, mode, tone) {
            Err(e) => {
                println!("FAIL  {name}: the call failed ({e})");
                failed += 1;
            }
            Ok(reason) => {
                let ok = reason.is_empty();
                if ok == expect_ok {
                    println!(
                        "PASS  {name}: {}",
                        if ok { "accepted".to_string() } else { format!("rejected ({reason})") }
                    );
                } else {
                    println!(
                        "FAIL  {name}: expected {}, got {:?}",
                        if expect_ok { "accepted" } else { "rejected" },
                        if ok { "accepted".to_string() } else { reason }
                    );
                    failed += 1;
                }
            }
        }
    }
    println!("=== {}/{} as expected", cases.len() - failed, cases.len());
    if failed > 0 {
        std::process::exit(1);
    }
}
