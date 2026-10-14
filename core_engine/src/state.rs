use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use crate::asr::Recognizer;
use crate::error::{EngineError, ErrorCode};
use crate::memory::{peak_rss_bytes, OvcMemoryUsage};
use crate::vad;

type Result<T, E = EngineError> = std::result::Result<T, E>;

pub const SAMPLE_RATE: u32 = 16_000;
/// Target segment length: 5 minutes.
const SEGMENT_SAMPLES: usize = 300 * SAMPLE_RATE as usize;
/// Search window on each side of the target for a silent cut: 20 seconds.
const SEARCH_SAMPLES: usize = 20 * SAMPLE_RATE as usize;
/// VAD analysis frame: 100 ms.
const FRAME_SAMPLES: usize = SAMPLE_RATE as usize / 10;

struct Session {
    buffer: Vec<f32>,
    transcript: String,
    finished: bool,
}

struct State {
    models_dir: Option<PathBuf>,
    asr: Option<Recognizer>,
    asr_model_bytes: u64,
    session: Option<Session>,
}

static STATE: Mutex<State> = Mutex::new(State {
    models_dir: None,
    asr: None,
    asr_model_bytes: 0,
    session: None,
});

fn lock() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn set_models_dir(dir: PathBuf) -> Result<()> {
    if !dir.is_dir() {
        return Err(EngineError::new(
            ErrorCode::InvalidArg,
            format!("models directory not found: {}", dir.display()),
        ));
    }
    lock().models_dir = Some(dir);
    Ok(())
}

pub fn shutdown() {
    let mut s = lock();
    s.session = None;
    s.asr = None;
    s.asr_model_bytes = 0;
    s.models_dir = None;
}

pub fn load_asr() -> Result<()> {
    let mut s = lock();
    if s.asr.is_some() {
        return Ok(());
    }
    let dir = s
        .models_dir
        .clone()
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidState, "Core_Initialize has not been called"))?;
    let model = dir.join("asr/model.int8.onnx");
    let tokens = dir.join("asr/tokens.txt");
    let bytes = file_len(&model)? + file_len(&tokens)?;
    let threads = std::thread::available_parallelism().map(|n| n.get().min(4)).unwrap_or(2) as i32;
    let rec = Recognizer::new(&model, &tokens, threads)?;
    s.asr = Some(rec);
    s.asr_model_bytes = bytes;
    Ok(())
}

pub fn unload_asr() -> Result<()> {
    let mut s = lock();
    if s.session.as_ref().is_some_and(|x| !x.finished) {
        return Err(EngineError::new(
            ErrorCode::InvalidState,
            "an ASR session is active; call ASR_Stop first",
        ));
    }
    s.asr = None;
    s.asr_model_bytes = 0;
    s.session = None;
    Ok(())
}

pub fn usage() -> OvcMemoryUsage {
    let s = lock();
    OvcMemoryUsage {
        model_bytes: s.asr_model_bytes,
        peak_rss_bytes: peak_rss_bytes(),
    }
}

pub fn asr_start() -> Result<()> {
    let mut s = lock();
    if s.asr.is_none() {
        return Err(EngineError::new(
            ErrorCode::NotLoaded,
            "ASR model not loaded; call Agent_Load(\"asr\") first",
        ));
    }
    if s.session.as_ref().is_some_and(|x| !x.finished) {
        return Err(EngineError::new(ErrorCode::InvalidState, "ASR session already active"));
    }
    s.session = Some(Session {
        buffer: Vec::new(),
        transcript: String::new(),
        finished: false,
    });
    Ok(())
}

/// Append mono float32 PCM at 16 kHz. Whenever the buffer holds a full segment
/// plus the search window, decode the segment cut at the quietest nearby frame.
pub fn asr_submit(samples: &[f32], sample_rate: u32) -> Result<()> {
    if sample_rate != SAMPLE_RATE {
        return Err(EngineError::new(
            ErrorCode::InvalidArg,
            format!("sample_rate must be {SAMPLE_RATE}, got {sample_rate} (resampling not implemented)"),
        ));
    }
    let mut guard = lock();
    let State { asr, session, .. } = &mut *guard;
    let rec = asr
        .as_mut()
        .ok_or_else(|| EngineError::new(ErrorCode::NotLoaded, "ASR model not loaded"))?;
    let sess = active_session(session)?;
    sess.buffer.extend_from_slice(samples);
    while sess.buffer.len() >= SEGMENT_SAMPLES + SEARCH_SAMPLES {
        let cut = vad::choose_cut(&sess.buffer, SEGMENT_SAMPLES, SEARCH_SAMPLES, FRAME_SAMPLES);
        let text = rec.decode(&sess.buffer[..cut], SAMPLE_RATE)?;
        sess.transcript.push_str(&text);
        sess.buffer.drain(..cut);
    }
    Ok(())
}

/// Committed transcript so far. Excludes audio still buffered (< 5 min + 20 s).
pub fn asr_result() -> Result<String> {
    let guard = lock();
    let sess = guard
        .session
        .as_ref()
        .filter(|x| !x.finished)
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidState, "no active ASR session"))?;
    Ok(sess.transcript.clone())
}

/// Decode remaining buffered audio, end the session, and return the full transcript.
pub fn asr_stop() -> Result<String> {
    let mut guard = lock();
    let State { asr, session, .. } = &mut *guard;
    let sess = active_session(session)?;
    if !sess.buffer.is_empty() {
        let rec = asr
            .as_mut()
            .ok_or_else(|| EngineError::new(ErrorCode::NotLoaded, "ASR model not loaded"))?;
        let text = rec.decode(&sess.buffer, SAMPLE_RATE)?;
        sess.transcript.push_str(&text);
        sess.buffer.clear();
    }
    sess.finished = true;
    Ok(sess.transcript.clone())
}

fn active_session(slot: &mut Option<Session>) -> Result<&mut Session> {
    match slot {
        Some(s) if !s.finished => Ok(s),
        _ => Err(EngineError::new(ErrorCode::InvalidState, "no active ASR session; call ASR_Start")),
    }
}

fn file_len(p: &Path) -> Result<u64> {
    std::fs::metadata(p)
        .map(|m| m.len())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", p.display())))
}

/// Refine a transcript with the Qwen model. Loads the model for this call only and
/// releases it on return, so the LLM's weights do not stay resident between calls.
pub fn refine_text(text: &str) -> Result<String> {
    let dir = lock()
        .models_dir
        .clone()
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidState, "Core_Initialize has not been called"))?;
    let model = dir.join("llm/qwen2.5-0.5b-instruct-q4_k_m.gguf");
    file_len(&model)?;
    let prompt = crate::llm::refine_prompt(text);
    crate::llm::generate(&model, &prompt)
}
