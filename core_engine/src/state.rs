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
    // Prefer the full-precision (fp32) model when present; fall back to the
    // int8 one so an older install keeps working.
    let full = dir.join("asr/model.onnx");
    let model = if full.exists() { full } else { dir.join("asr/model.int8.onnx") };
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

/// Live preview: decode whatever is still buffered and return the transcript as
/// it would read right now, WITHOUT consuming the buffer or ending the session.
///
/// `asr_result` only moves once a whole 5-minute segment is committed, which
/// never happens during a normal dictation -- so the HUD's live character count
/// needs this instead. Re-decoding the same buffer is safe (the recogniser is
/// stateless per call), but the cost grows with the audio held, so callers poll
/// it slowly and stop once a recording gets long.
pub fn asr_peek() -> Result<String> {
    let mut guard = lock();
    let State { asr, session, .. } = &mut *guard;
    let rec = asr
        .as_mut()
        .ok_or_else(|| EngineError::new(ErrorCode::NotLoaded, "ASR model not loaded"))?;
    let sess = active_session(session)?;
    let mut full = sess.transcript.clone();
    if !sess.buffer.is_empty() {
        full.push_str(&rec.decode(&sess.buffer, SAMPLE_RATE)?);
    }
    Ok(full)
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

/// Refine a transcript in a separate worker process. The worker loads the LLM, answers
/// one request, and exits, so its memory is returned to the OS. The parent never maps the
/// LLM weights, which keeps this process's peak RSS to the ASR path alone.
pub fn refine_text(text: &str) -> Result<String> {
    refine_text_with_keywords(text, "")
}

pub fn refine_text_with_keywords(text: &str, keywords_hint: &str) -> Result<String> {
    refine_text_with_keywords_stages(text, keywords_hint, 0)
}

/// Refine a transcript, choosing how many model passes to run.
///
/// The two-stage path (understand, then tidy) was tried and measured against the
/// single pass on the same drafts: it kept one long rambling paragraph more
/// completely, but it cost a second generation and introduced errors the single
/// pass did not make -- a three-point dictation came back as "改議會" (garbled
/// from "會議改到"), and a polite request became "我以為可能是..." (a statement,
/// not a request). The single pass with worked examples is both more faithful
/// and faster, so it is the default.
///
/// `stages` is 0 for the default, 1 for a single tidy pass, 2 for
/// understand-then-tidy. `OVC_REFINE_STAGES` (1 or 2) overrides the choice so
/// both shapes can be compared on the same input.
pub fn refine_text_with_keywords_stages(text: &str, keywords_hint: &str, stages: u32) -> Result<String> {
    let _ = text;
    let model = llm_model_path()?;
    let stages = match std::env::var("OVC_REFINE_STAGES").ok().and_then(|v| v.trim().parse::<u32>().ok()) {
        Some(forced @ (1 | 2)) => forced,
        _ => stages,
    };
    let task = match stages {
        2 => "refine-two-stage",
        _ => "refine",
    };
    run_worker(&worker_path()?, task, &model, text, keywords_hint)
}

fn llm_model_path() -> Result<PathBuf> {
    let dir = lock()
        .models_dir
        .clone()
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidState, "Core_Initialize has not been called"))?;
    let model = dir.join("llm/qwen2.5-1.5b-instruct-q4_k_m.gguf");
    file_len(&model)?;
    Ok(model)
}

/// Structured meeting summary: 摘要 / 決策 / 待辦.
///
/// Each section is a separate model call, so the program owns the layout and does not rely
/// on the model following a format. Long transcripts are reduced by map-reduce:
/// map over 600-char chunks (20-char overlap), then run each section over the joined notes.
pub fn summarize_text(transcript: &str) -> Result<String> {
    use crate::{SECTION_ACTIONS, SECTION_DECISIONS, SECTION_SUMMARY};
    let model = llm_model_path()?;
    let worker = worker_path()?;
    let chunks = crate::chunking::split_text(transcript, SUMMARY_CHUNK_CHARS, SUMMARY_OVERLAP_CHARS);
    if chunks.is_empty() {
        return Err(EngineError::new(ErrorCode::InvalidArg, "transcript is empty"));
    }
    // Map: one short note per chunk, only when the transcript spans several chunks.
    let source = if chunks.len() == 1 {
        chunks[0].clone()
    } else {
        let mut notes = Vec::with_capacity(chunks.len());
        for chunk in &chunks {
            notes.push(run_worker(&worker, "summary", &model, chunk, SECTION_SUMMARY)?);
        }
        notes.join("\n")
    };
    let summary = run_worker(&worker, "summary", &model, &source, SECTION_SUMMARY)?;
    let decisions = run_worker(&worker, "summary", &model, &source, SECTION_DECISIONS)?;
    let actions = run_worker(&worker, "summary", &model, &source, SECTION_ACTIONS)?;
    Ok(format!("## 摘要\n{}\n\n## 決策\n{}\n\n## 待辦\n{}", summary.trim(), decisions.trim(), actions.trim()))
}

/// Map chunk size in characters and the overlap between adjacent chunks.
const SUMMARY_CHUNK_CHARS: usize = 600;
const SUMMARY_OVERLAP_CHARS: usize = 20;

/// The worker is installed next to the core library (Contents/Frameworks in the app bundle),
/// or next to the current executable for development runs.
fn worker_path() -> Result<PathBuf> {
    let exe = std::env::current_exe()
        .map_err(|e| EngineError::new(ErrorCode::Internal, format!("current_exe: {e}")))?;
    let dir = exe.parent().unwrap_or(Path::new("."));
    // dev: target/release/examples/<exe> -> target/release/ ; app: Contents/MacOS -> Contents/Frameworks
    let candidates = [
        dir.join("ovc-llm-worker"),
        dir.join("../ovc-llm-worker"),
        dir.join("../Frameworks/ovc-llm-worker"),
    ];
    for candidate in candidates {
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    Err(EngineError::new(
        ErrorCode::NotLoaded,
        format!("ovc-llm-worker not found next to {}", exe.display()),
    ))
}

fn run_worker(worker: &Path, task: &str, model: &Path, text: &str, instruction: &str) -> Result<String> {
    use std::io::Write;
    use std::process::{Command, Stdio};

    let mut child = Command::new(worker)
        .arg(task)
        .arg(model)
        .arg(instruction)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| EngineError::new(ErrorCode::Internal, format!("spawn worker: {e}")))?;
    {
        let mut stdin = child.stdin.take().expect("piped stdin");
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| EngineError::new(ErrorCode::Internal, format!("write to worker: {e}")))?;
    }
    let out = child
        .wait_with_output()
        .map_err(|e| EngineError::new(ErrorCode::Internal, format!("wait worker: {e}")))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(EngineError::new(
            ErrorCode::Inference,
            format!("LLM worker failed ({}): {err}", out.status),
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}
