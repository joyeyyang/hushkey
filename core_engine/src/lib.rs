//! Offline AI voice assistant core. Exposes a plain C ABI; see include/offline_voice_core.h.
//!
//! Thread safety: every entry point serializes on one global mutex. Last-error text is
//! per-thread. Strings returned to C are owned by the caller and must be released with
//! `Core_FreeString`.

mod asr;
pub mod chunking;
pub mod embed;
mod error;
pub mod llm;
mod memory;
pub mod segmentation;
mod state;
mod vad;

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;

use error::{clear_last_error, last_error, set_last_error, EngineError, ErrorCode};
pub use memory::OvcMemoryUsage;

pub use embed::{
    cosine as embed_cosine, embed_documents, embed_queries, screen as embed_screen, ScreenResult,
};

pub use llm::{
    refine as llm_refine, refine_stages as llm_refine_stages, refine_two_stage as llm_refine_two_stage,
    refine_with_keywords as llm_refine_with_keywords,
    summarize_one as llm_summarize_one, translate as llm_translate,
    SECTION_ACTIONS, SECTION_DECISIONS, SECTION_SUMMARY,
};

/// Rust-level access to the same loader the C ABI uses.
///
/// The C entry points are the app's contract, but a probe or a test inside this
/// crate cannot call them (an example links the rlib, not the `#[no_mangle]`
/// objects), and "which file did it open" is exactly the question a probe has to
/// answer from the engine's own bookkeeping rather than from a manifest.
pub use state::{load_asr, set_models_dir, usage as memory_usage};

type Result<T, E = EngineError> = std::result::Result<T, E>;

fn status(r: Result<()>) -> c_int {
    match r {
        Ok(()) => {
            clear_last_error();
            0
        }
        Err(e) => {
            let code = e.code as c_int;
            set_last_error(e.msg);
            code
        }
    }
}

fn into_c_string(s: &str) -> *mut c_char {
    // Interior NULs are removed rather than failing, so the result is always valid.
    CString::new(s.replace('\0', "")).unwrap_or_default().into_raw()
}

/// # Safety
/// `p` must be null or a valid NUL-terminated string.
unsafe fn read_str<'a>(p: *const c_char, what: &str) -> Result<&'a str> {
    if p.is_null() {
        return Err(EngineError::new(ErrorCode::InvalidArg, format!("{what} is null")));
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| EngineError::new(ErrorCode::InvalidArg, format!("{what} is not valid UTF-8")))
}

/// # Safety
/// `out` must be null or a valid pointer to writable storage for one `char*`.
unsafe fn write_out(out: *mut *mut c_char, s: &str) -> Result<()> {
    if out.is_null() {
        return Err(EngineError::new(ErrorCode::InvalidArg, "output pointer is null"));
    }
    *out = into_c_string(s);
    Ok(())
}

fn not_implemented(name: &str) -> Result<()> {
    Err(EngineError::new(
        ErrorCode::NotImplemented,
        format!("{name} is not implemented in this build"),
    ))
}

// ---- Core -------------------------------------------------------------------

/// # Safety
/// `models_dir` must be a valid NUL-terminated UTF-8 path.
#[no_mangle]
pub unsafe extern "C" fn Core_Initialize(models_dir: *const c_char) -> c_int {
    status((|| {
        let dir = read_str(models_dir, "models_dir")?;
        state::set_models_dir(PathBuf::from(dir))
    })())
}

#[no_mangle]
pub extern "C" fn Core_Shutdown() -> c_int {
    state::shutdown();
    status(Ok(()))
}

/// Returns a newly allocated message (free with `Core_FreeString`), or NULL if no error.
#[no_mangle]
pub extern "C" fn Core_GetLastError() -> *mut c_char {
    match last_error() {
        Some(m) => into_c_string(&m),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `s` must be NULL or a pointer returned by this library, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn Core_FreeString(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

// ---- Agent (model) management ------------------------------------------------

/// # Safety
/// `name` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn Agent_Load(name: *const c_char) -> c_int {
    status((|| match read_str(name, "name")? {
        "asr" => state::load_asr(),
        "llm" | "rag" => not_implemented("LLM/RAG model loading"),
        other => Err(EngineError::new(ErrorCode::InvalidArg, format!("unknown agent: {other}"))),
    })())
}

/// # Safety
/// `name` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn Agent_Unload(name: *const c_char) -> c_int {
    status((|| match read_str(name, "name")? {
        "asr" => state::unload_asr(),
        "llm" | "rag" => not_implemented("LLM/RAG model unloading"),
        other => Err(EngineError::new(ErrorCode::InvalidArg, format!("unknown agent: {other}"))),
    })())
}

#[no_mangle]
pub extern "C" fn Memory_Unload() -> c_int {
    status(state::unload_asr())
}

/// # Safety
/// `out` must be a valid pointer to an `OvcMemoryUsage`.
#[no_mangle]
pub unsafe extern "C" fn Memory_GetUsage(out: *mut OvcMemoryUsage) -> c_int {
    if out.is_null() {
        return status(Err(EngineError::new(ErrorCode::InvalidArg, "out is null")));
    }
    *out = state::usage();
    status(Ok(()))
}

// ---- ASR ---------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn ASR_Start() -> c_int {
    status(state::asr_start())
}

/// # Safety
/// `pcm` must point to `n` valid f32 samples (mono, 16 kHz).
#[no_mangle]
pub unsafe extern "C" fn ASR_SubmitAudio(pcm: *const f32, n: usize, sample_rate: u32) -> c_int {
    if n == 0 {
        return status(Ok(()));
    }
    if pcm.is_null() {
        return status(Err(EngineError::new(ErrorCode::InvalidArg, "pcm is null")));
    }
    let samples = std::slice::from_raw_parts(pcm, n);
    status(state::asr_submit(samples, sample_rate))
}

/// # Safety
/// `out` must be a valid pointer to writable storage for one `char*`.
#[no_mangle]
pub unsafe extern "C" fn ASR_GetResult(out: *mut *mut c_char) -> c_int {
    status((|| {
        let text = state::asr_result()?;
        write_out(out, &text)
    })())
}

/// # Safety
/// `out` must be a valid pointer to writable storage for one `char*`.
#[no_mangle]
pub unsafe extern "C" fn ASR_Peek(out: *mut *mut c_char) -> c_int {
    status((|| {
        let text = state::asr_peek()?;
        write_out(out, &text)
    })())
}

/// # Safety
/// `out` must be a valid pointer to writable storage for one `char*`.
#[no_mangle]
pub unsafe extern "C" fn ASR_Stop(out: *mut *mut c_char) -> c_int {
    status((|| {
        let text = state::asr_stop()?;
        write_out(out, &text)
    })())
}

/// Append audio tagged with the route it came from.
///
/// `speaker` is 0 for the microphone and 1 for the system-audio tap. The tag is
/// what makes a two-route meeting transcript possible: speech from the two
/// routes is segmented separately, so the transcript can say who was talking
/// without guessing.
///
/// # Safety
/// `pcm` must point to `n` valid f32 samples (mono, 16 kHz).
#[no_mangle]
pub unsafe extern "C" fn ASR_SubmitTagged(
    pcm: *const f32,
    n: usize,
    sample_rate: u32,
    speaker: u32,
) -> c_int {
    if n == 0 {
        return status(Ok(()));
    }
    if pcm.is_null() {
        return status(Err(EngineError::new(ErrorCode::InvalidArg, "pcm is null")));
    }
    if speaker > 1 {
        return status(Err(EngineError::new(
            ErrorCode::InvalidArg,
            "speaker must be 0 (microphone) or 1 (system audio)",
        )));
    }
    let samples = std::slice::from_raw_parts(pcm, n);
    status(state::asr_submit_tagged(samples, sample_rate, speaker as u8))
}

/// Decode the utterances that closed since the last call.
///
/// Returns a JSON array, `[]` when nothing is ready:
/// `[{"index":1,"speaker":0,"start":1.234,"end":2.987,"text":"..."}]`
/// `index` is 1-based and stable for the session; `start`/`end` are seconds from
/// the start of the session. Only segments the caller has not been given yet are
/// returned, so the caller appends and never has to diff. That includes the last
/// utterance of a session: `ASR_Stop` decodes it itself, and one more call here
/// after the stop yields it, which is how the live transcript window gets the
/// closing sentence.
///
/// # Safety
/// `out_json` must be a valid pointer to writable storage for one `char*`.
#[no_mangle]
pub unsafe extern "C" fn ASR_TakeSegments(out_json: *mut *mut c_char) -> c_int {
    status((|| {
        let segments = state::asr_take_segments()?;
        write_out(out_json, &segments_json(&segments))
    })())
}

fn segments_json(segments: &[state::StoredSegment]) -> String {
    let mut out = String::from("[");
    for (i, s) in segments.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&format!(
            "{{\"index\":{},\"speaker\":{},\"start\":{:.3},\"end\":{:.3},\"text\":\"{}\"}}",
            s.index,
            s.speaker,
            s.start,
            s.end,
            json_escape(&s.text)
        ));
    }
    out.push(']');
    out
}

fn json_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

// ---- LLM (out-of-process worker) --------------------------------------------

/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_Summarize(transcript: *const c_char, out: *mut *mut c_char) -> c_int {
    status((|| {
        let input = read_str(transcript, "transcript")?;
        let summary = state::summarize_text(input)?;
        write_out(out, &summary)
    })())
}

/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_RefineText(text: *const c_char, out: *mut *mut c_char) -> c_int {
    status((|| {
        let input = read_str(text, "text")?;
        let refined = state::refine_text(input)?;
        write_out(out, &refined)
    })())}

#[no_mangle]
pub unsafe extern "C" fn LLM_RefineTextWithKeywords(text: *const c_char, keywords_hint: *const c_char, out: *mut *mut c_char) -> c_int {
    status((|| {
        let input = read_str(text, "text")?;
        let hint = if keywords_hint.is_null() { String::new() } else { read_str(keywords_hint, "keywords_hint")?.to_owned() };
        let refined = state::refine_text_with_keywords(input, &hint)?;
        write_out(out, &refined)
    })())
}

/// Like `LLM_RefineTextWithKeywords`, but the caller chooses how many model
/// passes to run: 0 = decide by transcript length, 1 = single condense pass,
/// 2 = understand the speech first, then condense it.
///
/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_RefineTextWithKeywordsStages(
    text: *const c_char,
    keywords_hint: *const c_char,
    stages: u32,
    out: *mut *mut c_char,
) -> c_int {
    status((|| {
        let input = read_str(text, "text")?;
        let hint = if keywords_hint.is_null() { String::new() } else { read_str(keywords_hint, "keywords_hint")?.to_owned() };
        let refined = state::refine_text_with_keywords_stages(input, &hint, stages)?;
        write_out(out, &refined)
    })())
}

/// Translate a transcript into another language. `target` is "en" or "zh".
///
/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_Translate(text: *const c_char, target: *const c_char, out: *mut *mut c_char) -> c_int {
    status((|| {
        let input = read_str(text, "text")?;
        let lang = if target.is_null() { "zh" } else { read_str(target, "target")? };
        let translated = state::translate_text(input, lang)?;
        write_out(out, &translated)
    })())
}

/// Rank the caller's terms against `text` with the retrieval model.
///
/// `terms` is the list joined by newlines. The result is the relevant terms, best
/// first, joined by newlines — or an empty string when the retrieval model is not
/// installed, which is a normal state and NOT an error: the caller then keeps its
/// full term list, exactly as it did before this existed.
///
/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_RelevantTerms(
    text: *const c_char,
    terms: *const c_char,
    out: *mut *mut c_char,
) -> c_int {
    status((|| {
        let input = read_str(text, "text")?;
        let raw = if terms.is_null() { "" } else { read_str(terms, "terms")? };
        let terms: Vec<String> = raw
            .split('\n')
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect();
        let ranked = state::relevant_terms(input, &terms)?;
        write_out(out, &ranked.join("\n"))
    })())
}

/// Embed the retrieval model's exemplar set (and the terms passed in, newline
/// separated) into its cache. Returns the number of vectors computed in *out_count
/// (0 when the cache was already warm), so a caller can log the one-time cost.
///
/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_WarmRetrieval(
    terms: *const c_char,
    out_count: *mut i32,
) -> c_int {
    status((|| {
        let raw = if terms.is_null() { "" } else { read_str(terms, "terms")? };
        let terms: Vec<String> = raw
            .split('\n')
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect();
        let computed = state::warm_retrieval(&terms)?;
        if !out_count.is_null() {
            *out_count = computed as i32;
        }
        Ok(())
    })())
}

/// The clauses of `text` that read as an instruction about the text itself
/// ("把前面那句刪掉"), joined by newlines. Empty when there are none, or when the
/// retrieval model is not installed.
///
/// # Safety
/// Pointers must follow the header contract.
#[no_mangle]
pub unsafe extern "C" fn LLM_EditClauses(text: *const c_char, out: *mut *mut c_char) -> c_int {
    status((|| {
        let input = read_str(text, "text")?;
        let clauses = state::edit_clauses(input)?;
        write_out(out, &clauses.join("\n"))
    })())
}

/// # Safety
/// Pointers must follow the header contract. Currently always returns NotImplemented.
#[no_mangle]
pub unsafe extern "C" fn RAG_Search(_query: *const c_char, _out: *mut *mut c_char) -> c_int {
    status(not_implemented("RAG_Search"))
}

/// # Safety
/// Pointers must follow the header contract. Currently always returns NotImplemented.
#[no_mangle]
pub unsafe extern "C" fn RAG_AddEntry(_entry: *const c_char) -> c_int {
    status(not_implemented("RAG_AddEntry"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_json_escapes_and_formats() {
        let segments = vec![state::StoredSegment {
            index: 3,
            speaker: 1,
            start: 1.2345,
            end: 2.9876,
            text: "他說「好」\n然後\t走了 \\ 回家".to_string(),
        }];
        let json = segments_json(&segments);
        assert!(json.starts_with('[') && json.ends_with(']'), "{json}");
        assert!(json.contains("\"index\":3"));
        assert!(json.contains("\"speaker\":1"));
        assert!(json.contains("\"start\":1.234"), "{json}");
        assert!(json.contains("\\n"), "newline escaped: {json}");
        assert!(json.contains("\\t"), "tab escaped: {json}");
        assert!(json.contains("\\\\"), "backslash escaped: {json}");
    }

    #[test]
    fn empty_segment_list_is_an_empty_array() {
        assert_eq!(segments_json(&[]), "[]");
    }
}
