//! Offline AI voice assistant core. Exposes a plain C ABI; see include/offline_voice_core.h.
//!
//! Thread safety: every entry point serializes on one global mutex. Last-error text is
//! per-thread. Strings returned to C are owned by the caller and must be released with
//! `Core_FreeString`.

mod asr;
pub mod chunking;
mod error;
mod memory;
mod state;
mod vad;

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;

use error::{clear_last_error, last_error, set_last_error, EngineError, ErrorCode};
pub use memory::OvcMemoryUsage;

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
pub unsafe extern "C" fn ASR_Stop(out: *mut *mut c_char) -> c_int {
    status((|| {
        let text = state::asr_stop()?;
        write_out(out, &text)
    })())
}

// ---- LLM / RAG (not yet implemented; return explicit NotImplemented) ---------

/// # Safety
/// Pointers must follow the header contract. Currently always returns NotImplemented.
#[no_mangle]
pub unsafe extern "C" fn LLM_Summarize(_transcript: *const c_char, _out: *mut *mut c_char) -> c_int {
    status(not_implemented("LLM_Summarize"))
}

/// # Safety
/// Pointers must follow the header contract. Currently always returns NotImplemented.
#[no_mangle]
pub unsafe extern "C" fn LLM_RefineText(_text: *const c_char, _out: *mut *mut c_char) -> c_int {
    status(not_implemented("LLM_RefineText"))
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
