//! Exercises the C ABI error paths and lifecycle without loading a model.
//! One test function on purpose: the core keeps global state, and parallel
//! tests in one binary would race on it.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use offline_voice_core::*;

const OK: i32 = 0;
const ERR_INVALID_ARG: i32 = 1;
const ERR_NOT_LOADED: i32 = 2;
const ERR_NOT_IMPLEMENTED: i32 = 3;
const ERR_INVALID_STATE: i32 = 6;

fn last_error() -> String {
    unsafe {
        let p = Core_GetLastError();
        if p.is_null() {
            return String::new();
        }
        let s = CStr::from_ptr(p).to_string_lossy().into_owned();
        Core_FreeString(p);
        s
    }
}

#[test]
fn ffi_lifecycle_and_error_paths() {
    unsafe {
        // Null and missing-directory inputs are rejected.
        assert_eq!(Core_Initialize(std::ptr::null()), ERR_INVALID_ARG);
        let missing = CString::new("/nonexistent/ovc-models").unwrap();
        assert_eq!(Core_Initialize(missing.as_ptr()), ERR_INVALID_ARG);
        assert!(last_error().contains("models directory not found"));

        // ASR operations before Core_Initialize / Agent_Load fail with explicit codes.
        assert_eq!(ASR_Start(), ERR_NOT_LOADED);
        let asr = CString::new("asr").unwrap();
        assert_eq!(Agent_Load(asr.as_ptr()), ERR_INVALID_STATE);

        // Unknown agent name is an argument error, not a silent success.
        let bogus = CString::new("bogus").unwrap();
        assert_eq!(Agent_Load(bogus.as_ptr()), ERR_INVALID_ARG);

        // Unimplemented LLM/RAG entry points report NOT_IMPLEMENTED.
        let text = CString::new("hi").unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        assert_eq!(LLM_RefineText(text.as_ptr(), &mut out), ERR_NOT_IMPLEMENTED);
        assert!(out.is_null());

        // Submitting audio with a wrong sample rate is rejected before any model work.
        let pcm = [0.0f32; 16];
        assert_eq!(ASR_SubmitAudio(pcm.as_ptr(), pcm.len(), 44_100), ERR_INVALID_ARG);

        // Memory report is always available and fills the struct.
        let mut usage = OvcMemoryUsage { model_bytes: 1, peak_rss_bytes: 1 };
        assert_eq!(Memory_GetUsage(&mut usage), OK);
        assert_eq!(usage.model_bytes, 0);
        assert!(usage.peak_rss_bytes > 0);

        // Shutdown is idempotent and clears the last error on success.
        assert_eq!(Core_Shutdown(), OK);
        assert_eq!(Core_Shutdown(), OK);
        assert!(last_error().is_empty());
    }
}
