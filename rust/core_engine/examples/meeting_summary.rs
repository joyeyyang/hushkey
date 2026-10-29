use std::ffi::{CStr, CString};
use std::os::raw::c_char;

fn main() {
    let dir = CString::new(format!("{}/../models", env!("CARGO_MANIFEST_DIR"))).unwrap();
    unsafe {
        let rc = offline_voice_core::Core_Initialize(dir.as_ptr());
        assert_eq!(rc, 0, "initialize failed");
    }
    let t = std::env::var("TRANSCRIPT").unwrap_or_else(|_| "好那我們今天會議開始。第一個是上線時間，大家討論之後就決定下週三上線，由小明負責部署。第二個是客服的部分，怡君你下週五以前要生出客服的 SOP。然後我這邊下週一以前把合約草稿給法務。另外行銷的部分先不動，等產品穩定再說。大家還有問題嗎？沒有就這樣。".to_string());
    let text = CString::new(t).unwrap();
    let mut out: *mut c_char = std::ptr::null_mut();
    let rc = unsafe { offline_voice_core::LLM_Summarize(text.as_ptr(), &mut out) };
    if rc != 0 {
        let err = unsafe { CStr::from_ptr(offline_voice_core::Core_GetLastError()) };
        eprintln!("summarize failed {rc}: {}", err.to_string_lossy());
        std::process::exit(1);
    }
    let s = unsafe { CStr::from_ptr(out) }.to_string_lossy().to_string();
    println!("{s}");
}
