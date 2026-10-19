//! Offline AI voice assistant core. Exposes a plain C ABI; see include/offline_voice_core.h.
//!
//! Thread safety: every entry point serializes on one global mutex. Last-error text is
//! per-thread. Strings returned to C are owned by the caller and must be released with
//! `Core_FreeString`.

mod asr;
pub mod chunking;
mod error;
pub mod llm;
mod memory;
mod state;
mod vad;

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;

use error::{clear_last_error, last_error, set_last_error, EngineError, ErrorCode};
pub use memory::OvcMemoryUsage;

pub use llm::{
    refine as llm_refine, refine_stages as llm_refine_stages, refine_two_stage as llm_refine_two_stage,
    refine_with_keywords as llm_refine_with_keywords,
    summarize_one as llm_summarize_one, translate as llm_translate,
    SECTION_ACTIONS, SECTION_DECISIONS, SECTION_SUMMARY,
};

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
