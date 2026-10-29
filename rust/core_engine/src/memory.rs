/// C-visible memory report. Layout must match include/offline_voice_core.h.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct OvcMemoryUsage {
    /// Bytes of model files currently loaded (on-disk size as a proxy for weights).
    pub model_bytes: u64,
    /// Peak resident set size of this process in bytes (getrusage ru_maxrss).
    /// Not current RSS: the current value requires mach task_info, not implemented yet.
    pub peak_rss_bytes: u64,
}

pub fn peak_rss_bytes() -> u64 {
    // SAFETY: getrusage writes into a zeroed rusage we own.
    unsafe {
        let mut ru: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut ru) == 0 {
            // macOS reports ru_maxrss in bytes.
            ru.ru_maxrss as u64
        } else {
            0
        }
    }
}
