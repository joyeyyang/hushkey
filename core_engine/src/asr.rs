use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

use crate::error::{EngineError, ErrorCode};

extern "C" {
    fn ovc_asr_create(
        model: *const c_char,
        tokens: *const c_char,
        num_threads: c_int,
        kind: c_int,
    ) -> *mut c_void;
    fn ovc_asr_decode(rec: *mut c_void, samples: *const f32, n: c_int, sample_rate: c_int) -> *mut c_char;
    fn ovc_asr_destroy(rec: *mut c_void);
    fn free(ptr: *mut c_void);
}

/// Which model family the recognizer was built from.
///
/// The two need different sherpa-onnx configs (Dolphin resolves its own
/// language from vocabulary tokens; SenseVoice takes a hint and an ITN flag), so
/// the family has to travel to the C shim with the file paths.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AsrKind {
    SenseVoice,
    Dolphin,
}

impl AsrKind {
    fn code(self) -> c_int {
        match self {
            Self::SenseVoice => 0,
            Self::Dolphin => 1,
        }
    }
}

/// Owns a sherpa-onnx recognizer. Not thread-safe; callers must serialize access.
pub struct Recognizer {
    raw: *mut c_void,
}

// SAFETY: the sherpa recognizer has no thread affinity; state.rs guards it with a Mutex.
unsafe impl Send for Recognizer {}

impl Recognizer {
    pub fn new(
        model: &Path,
        tokens: &Path,
        num_threads: i32,
        kind: AsrKind,
    ) -> Result<Self, EngineError> {
        let m = path_cstring(model)?;
        let t = path_cstring(tokens)?;
        // SAFETY: both pointers are valid NUL-terminated strings for the call.
        let raw = unsafe { ovc_asr_create(m.as_ptr(), t.as_ptr(), num_threads, kind.code()) };
        if raw.is_null() {
            return Err(EngineError::new(
                ErrorCode::ModelLoad,
                format!("sherpa-onnx could not create recognizer from {}", model.display()),
            ));
        }
        Ok(Self { raw })
    }

    /// Decode one mono float32 segment. Returns text with SenseVoice control tags removed.
    pub fn decode(&mut self, samples: &[f32], sample_rate: u32) -> Result<String, EngineError> {
        let n = c_int::try_from(samples.len())
            .map_err(|_| EngineError::new(ErrorCode::InvalidArg, "segment too long"))?;
        let sr = c_int::try_from(sample_rate)
            .map_err(|_| EngineError::new(ErrorCode::InvalidArg, "sample rate out of range"))?;
        // SAFETY: samples is valid for n floats; self.raw is a live recognizer.
        let p = unsafe { ovc_asr_decode(self.raw, samples.as_ptr(), n, sr) };
        if p.is_null() {
            return Err(EngineError::new(ErrorCode::Inference, "sherpa-onnx decode failed"));
        }
        // SAFETY: p is a NUL-terminated strdup'd buffer we free below.
        let text = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { free(p.cast()) };
        Ok(strip_tags(&text))
    }
}

impl Drop for Recognizer {
    fn drop(&mut self) {
        // SAFETY: raw came from ovc_asr_create and is destroyed exactly once.
        unsafe { ovc_asr_destroy(self.raw) };
    }
}

fn path_cstring(p: &Path) -> Result<CString, EngineError> {
    let s = p
        .to_str()
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidArg, format!("non-UTF-8 path: {}", p.display())))?;
    CString::new(s).map_err(|_| EngineError::new(ErrorCode::InvalidArg, "path contains NUL"))
}

/// Remove SenseVoice markers such as `<|zh|>`, `<|NEUTRAL|>`, `<|itn|>`.
pub fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find("<|") {
        out.push_str(&rest[..i]);
        match rest[i..].find("|>") {
            Some(j) => rest = &rest[i + j + 2..],
            None => {
                rest = &rest[i..];
                break;
            }
        }
    }
    out.push_str(rest);
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::strip_tags;

    #[test]
    fn strips_sensevoice_tags() {
        assert_eq!(strip_tags("<|zh|><|NEUTRAL|><|Speech|>你好世界"), "你好世界");
        assert_eq!(strip_tags("plain text"), "plain text");
        assert_eq!(strip_tags("a<|unterminated"), "a<|unterminated");
    }
}
