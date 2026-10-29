use std::cell::RefCell;

/// Status codes. Values are part of the C ABI (see include/offline_voice_core.h).
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    InvalidArg = 1,
    NotLoaded = 2,
    NotImplemented = 3,
    ModelLoad = 4,
    Inference = 5,
    InvalidState = 6,
    #[allow(dead_code)]
    Internal = 7,
}

#[derive(Debug)]
pub struct EngineError {
    pub code: ErrorCode,
    pub msg: String,
}

impl EngineError {
    pub fn new(code: ErrorCode, msg: impl Into<String>) -> Self {
        Self { code, msg: msg.into() }
    }
}

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

pub fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(msg));
}

pub fn clear_last_error() {
    LAST_ERROR.with(|e| *e.borrow_mut() = None);
}

pub fn last_error() -> Option<String> {
    LAST_ERROR.with(|e| e.borrow().clone())
}
