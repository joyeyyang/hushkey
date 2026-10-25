use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use crate::asr::Recognizer;
use crate::error::{EngineError, ErrorCode};
use crate::memory::{peak_rss_bytes, OvcMemoryUsage};
use crate::segmentation::{join_speech, Segmenter, Utterance};

type Result<T, E = EngineError> = std::result::Result<T, E>;

pub const SAMPLE_RATE: u32 = 16_000;

/// One decoded utterance, kept for the transcript window, the SRT export and the
/// speaker-split transcript.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredSegment {
    /// 1-based and never reused within a session: edit instructions address
    /// sentences by this number.
    pub index: u32,
    /// 0 = microphone ("me"), 1 = system audio ("other").
    pub speaker: u8,
    pub start: f64,
    pub end: f64,
    pub text: String,
}

struct Session {
    segments: Vec<StoredSegment>,
    next_index: u32,
    finished: bool,
    segmenter: Segmenter,
    /// Speaker of the audio currently sitting inside `segmenter`.
    speaker: u8,
    /// How many segments the caller has already been handed.
    ///
    /// `ASR_Stop` decodes the last utterance itself, so it lands in `segments`
    /// without ever passing through `asr_take_segments`. Counting what was
    /// delivered lets the live transcript pick that tail up after the session
    /// ends instead of losing the final sentence.
    delivered: usize,
}

/// Audio captured but not yet segmented.
///
/// The microphone callback hands samples over on a realtime thread, and decoding
/// an utterance costs hundreds of milliseconds. If that decode ran under the same
/// lock the audio thread takes, the tap would drop frames, so captured audio
/// waits here and is drained from the polling thread instead.
struct AudioQueue {
    chunks: VecDeque<(u8, Vec<f32>)>,
    samples: usize,
}

impl AudioQueue {
    const fn new() -> Self {
        Self {
            chunks: VecDeque::new(),
            samples: 0,
        }
    }
}

static AUDIO: Mutex<AudioQueue> = Mutex::new(AudioQueue::new());

/// Twenty minutes of audio. The app drains this four times a second, so the cap
/// only binds when segmentation has stalled; losing the oldest audio is better
/// than growing until an 8 GB machine swaps.
const AUDIO_CAP_SAMPLES: usize = 20 * 60 * SAMPLE_RATE as usize;

fn audio_lock() -> MutexGuard<'static, AudioQueue> {
    AUDIO.lock().unwrap_or_else(|e| e.into_inner())
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
    {
        let mut s = lock();
        s.session = None;
        s.asr = None;
        s.asr_model_bytes = 0;
        s.models_dir = None;
    }
    let mut q = audio_lock();
    q.chunks.clear();
    q.samples = 0;
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
    // SenseVoice Small int8 first, which is the model this install was tuned on.
    //
    // Dolphin base int8 was the default for part of 2026-10-25 because it is
    // smaller and faster (99 MB vs 228 MB, 0.141 s vs 0.190 s on one clip), and
    // that measurement was the whole case for it: speed, memory and language
    // coverage. It is not a better transcriber of the audio this app actually
    // receives. Real dictations after it became the default came back incoherent
    // -- "说费三个。不敢干母亲一个专门的行为", "手がちょっと" (the 40-language CTC
    // drifting into Japanese) -- while the same speaker's recordings from the
    // previous weeks, all SenseVoice, were readable. On clean synthesised speech
    // the two are comparable, so there is no accuracy to be bought back by the
    // smaller model, and the typo Dolphin made there ("時程" -> "時乘") is not one
    // SenseVoice avoided either.
    //
    // Dolphin stays installed and reachable via `OVC_ASR_MODEL=dolphin` so the
    // comparison can be re-run on real recordings; an install that only has
    // Dolphin still dictates.
    let override_choice = std::env::var("OVC_ASR_MODEL").unwrap_or_default().to_lowercase();
    let dolphin_model = dir.join("asr/dolphin/model.int8.onnx");
    let dolphin_tokens = dir.join("asr/dolphin/tokens.txt");
    let sense_int8 = dir.join("asr/model.int8.onnx");
    let sense_fp32 = dir.join("asr/model.onnx");
    let sense_tokens = dir.join("asr/tokens.txt");
    let have_dolphin = dolphin_model.exists() && dolphin_tokens.exists();
    let forced_dolphin = override_choice.contains("dolphin");

    let (model, tokens, kind) = if forced_dolphin && have_dolphin {
        (dolphin_model, dolphin_tokens, crate::asr::AsrKind::Dolphin)
    } else if sense_int8.exists() {
        (sense_int8, sense_tokens, crate::asr::AsrKind::SenseVoice)
    } else if sense_fp32.exists() {
        (sense_fp32, sense_tokens, crate::asr::AsrKind::SenseVoice)
    } else {
        (dolphin_model, dolphin_tokens, crate::asr::AsrKind::Dolphin)
    };

    // The language hint. SenseVoice identifies the language per utterance when
    // this is "auto", and it has nothing to identify from on a short, accented,
    // technical sentence -- a Chinese dictation came back carrying a Japanese
    // fragment ("手がちょっと"). "zh" is the better prior for the person this app
    // was built for, who dictates Chinese with English terms and numbers in it;
    // `OVC_ASR_LANGUAGE=auto|en|ja|ko|yue` says otherwise. Dolphin ignores it.
    let language = {
        let requested = std::env::var("OVC_ASR_LANGUAGE").unwrap_or_default().trim().to_lowercase();
        match requested.as_str() {
            "auto" | "en" | "ja" | "ko" | "yue" | "zh" => requested,
            _ => "zh".to_string(),
        }
    };
    let bytes = file_len(&model)? + file_len(&tokens)?;
    let threads = std::thread::available_parallelism().map(|n| n.get().min(4)).unwrap_or(2) as i32;
    let rec = Recognizer::new(&model, &tokens, threads, kind, &language)?;
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
    {
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
            segments: Vec::new(),
            next_index: 1,
            finished: false,
            segmenter: Segmenter::new(),
            speaker: 0,
            delivered: 0,
        });
    }
    // The previous session's tail must not be decoded into this one. The state
    // lock is released first: the order is always STATE then AUDIO, never both,
    // so a capture thread waiting on AUDIO can never deadlock against a poller
    // holding STATE.
    let mut q = audio_lock();
    q.chunks.clear();
    q.samples = 0;
    Ok(())
}

/// Append mono float32 PCM at 16 kHz, tagged with the route it came from
/// (0 = microphone, 1 = system audio).
///
/// This runs on the realtime audio thread, so it only copies samples into the
/// queue. Segmentation and decoding happen in `asr_take_segments`.
pub fn asr_submit_tagged(samples: &[f32], sample_rate: u32, speaker: u8) -> Result<()> {
    if sample_rate != SAMPLE_RATE {
        return Err(EngineError::new(
            ErrorCode::InvalidArg,
            format!("sample_rate must be {SAMPLE_RATE}, got {sample_rate} (resampling not implemented)"),
        ));
    }
    if samples.is_empty() {
        return Ok(());
    }
    let mut q = audio_lock();
    let same_route = matches!(q.chunks.back(), Some((last, _)) if *last == speaker);
    if same_route {
        if let Some((_, buffer)) = q.chunks.back_mut() {
            buffer.extend_from_slice(samples);
        }
    } else {
        q.chunks.push_back((speaker, samples.to_vec()));
    }
    q.samples += samples.len();
    while q.samples > AUDIO_CAP_SAMPLES {
        match q.chunks.pop_front() {
            Some((_, dropped)) => q.samples -= dropped.len(),
            None => break,
        }
    }
    Ok(())
}

pub fn asr_submit(samples: &[f32], sample_rate: u32) -> Result<()> {
    asr_submit_tagged(samples, sample_rate, 0)
}

/// Segment whatever has been captured since the last call and decode the
/// utterances that closed. Returns only the new segments, so the caller can
/// append them to a table without diffing.
///
/// New here means "not handed out yet", not "not decoded yet": after `ASR_Stop`
/// has decoded the final utterance, one last call still yields it, which is how
/// the live transcript window gets the last sentence of a session.
pub fn asr_take_segments() -> Result<Vec<StoredSegment>> {
    let chunks = drain_audio();
    let mut guard = lock();
    let State { asr, session, .. } = &mut *guard;
    let Some(sess) = session.as_mut() else {
        return Ok(Vec::new());
    };
    if !chunks.is_empty() && !sess.finished {
        let asr = asr
            .as_mut()
            .ok_or_else(|| EngineError::new(ErrorCode::NotLoaded, "ASR model not loaded"))?;
        let mut fresh = Vec::new();
        feed_audio(sess, asr, chunks, &mut fresh)?;
    }
    let undelivered = sess.segments.get(sess.delivered..).unwrap_or(&[]).to_vec();
    sess.delivered = sess.segments.len();
    Ok(undelivered)
}

/// Committed transcript so far: the decoded utterances, joined.
pub fn asr_result() -> Result<String> {
    let guard = lock();
    let sess = guard
        .session
        .as_ref()
        .filter(|x| !x.finished)
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidState, "no active ASR session"))?;
    Ok(transcript_text(sess))
}

/// Live preview of the transcript so far, without consuming anything.
///
/// This used to re-decode the whole buffered audio, which grew more expensive
/// the longer someone talked. With utterance segmentation the text is already
/// there, so this is a join and costs nothing; poll it as often as the UI likes.
pub fn asr_peek() -> Result<String> {
    asr_result()
}

/// Decode remaining buffered audio, end the session, and return the full transcript.
pub fn asr_stop() -> Result<String> {
    let chunks = drain_audio();
    let mut guard = lock();
    let State { asr, session, .. } = &mut *guard;
    let sess = active_session(session)?;
    let mut fresh = Vec::new();
    if !chunks.is_empty() {
        let asr = asr
            .as_mut()
            .ok_or_else(|| EngineError::new(ErrorCode::NotLoaded, "ASR model not loaded"))?;
        feed_audio(sess, asr, chunks, &mut fresh)?;
    }
    let mut tail = Vec::new();
    sess.segmenter.flush(&mut tail);
    if !tail.is_empty() {
        let speaker = sess.speaker;
        let asr = asr
            .as_mut()
            .ok_or_else(|| EngineError::new(ErrorCode::NotLoaded, "ASR model not loaded"))?;
        decode_into(sess, asr, tail, speaker, &mut fresh)?;
    }
    sess.finished = true;
    Ok(transcript_text(sess))
}

fn drain_audio() -> Vec<(u8, Vec<f32>)> {
    let mut q = audio_lock();
    q.samples = 0;
    q.chunks.drain(..).collect()
}

fn feed_audio(
    sess: &mut Session,
    rec: &mut Recognizer,
    chunks: Vec<(u8, Vec<f32>)>,
    out: &mut Vec<StoredSegment>,
) -> Result<()> {
    for (speaker, samples) in chunks {
        if speaker != sess.speaker {
            // Speech from two different routes must never share an utterance.
            let mut finished = Vec::new();
            sess.segmenter.flush(&mut finished);
            let previous = sess.speaker;
            decode_into(sess, rec, finished, previous, out)?;
            sess.speaker = speaker;
        }
        let mut finished = Vec::new();
        sess.segmenter.push(&samples, &mut finished);
        decode_into(sess, rec, finished, speaker, out)?;
    }
    Ok(())
}

fn decode_into(
    sess: &mut Session,
    rec: &mut Recognizer,
    utterances: Vec<Utterance>,
    speaker: u8,
    out: &mut Vec<StoredSegment>,
) -> Result<()> {
    for utterance in utterances {
        let text = rec.decode(&utterance.samples, SAMPLE_RATE)?;
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let segment = StoredSegment {
            index: sess.next_index,
            speaker,
            start: utterance.start,
            end: utterance.end,
            text: text.to_string(),
        };
        sess.next_index += 1;
        sess.segments.push(segment.clone());
        out.push(segment);
    }
    Ok(())
}

fn transcript_text(sess: &Session) -> String {
    let parts: Vec<&str> = sess.segments.iter().map(|s| s.text.as_str()).collect();
    join_speech(&parts)
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

/// Filename of the LLM inside `llm/`. `OVC_LLM_MODEL` overrides it so another
/// model can be selected at runtime (the model manager sets it from the user's
/// choice); the constant is the default the manifest ships.
const DEFAULT_LLM_FILE: &str = "Qwen3.5-2B-Q4_K_M.gguf";
/// Previous default, kept so an install that has not downloaded the new one yet
/// still has a working model.
const LEGACY_LLM_FILE: &str = "qwen2.5-1.5b-instruct-q4_k_m.gguf";

fn llm_model_path() -> Result<PathBuf> {
    let dir = lock()
        .models_dir
        .clone()
        .ok_or_else(|| EngineError::new(ErrorCode::InvalidState, "Core_Initialize has not been called"))?;
    let chosen = std::env::var("OVC_LLM_MODEL")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty() && !v.contains('/') && !v.contains(".."))
        .unwrap_or_else(|| DEFAULT_LLM_FILE.to_string());
    let model = dir.join("llm").join(&chosen);
    if model.exists() {
        file_len(&model)?;
        return Ok(model);
    }
    let legacy = dir.join("llm").join(LEGACY_LLM_FILE);
    if legacy.exists() {
        file_len(&legacy)?;
        return Ok(legacy);
    }
    file_len(&model)?;
    Ok(model)
}

/// Structured meeting summary: 摘要 / 決議 / 待辦.
///
/// Each section is a separate model call, so the program owns the layout and does not rely
/// on the model following a format. Long transcripts are reduced by map-reduce:
/// map over 600-char chunks (20-char overlap), then run each section over the joined notes.
///
/// Known limitation: a recording that is not a meeting -- a conversation that
/// decided nothing -- still gets a 決議 line and a 待辦 list. The model reports
/// both where neither exists, in either language, and the prompt fixes that were
/// tried made real meetings worse (a "nothing was decided" example does not stop
/// it and makes a mixed meeting leak people back into 決議; an English marker
/// makes a real English meeting list its assignments). What the code can
/// guarantee is the part it can check against the transcript: an owner the
/// transcript never addresses as a person is dropped from 待辦, and a 決議 clause
/// naming one of those owners is dropped from 決議. So nothing here invents a
/// person -- but a fabricated *decision* on a non-meeting is still possible.
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
    let actions = section_or_empty(&run_worker(&worker, "summary", &model, &source, SECTION_ACTIONS)?);
    let decisions = drop_void_lines(&section_or_empty(&run_worker(
        &worker, "summary", &model, &source, SECTION_DECISIONS,
    )?));
    // Each section then has to survive the facts it can be checked against: an
    // owner has to be someone the transcript addresses, a 決議 clause may not name
    // one of those owners, and a 待辦 line that names nobody and restates a
    // decision is that decision said twice. Order matters -- the list is
    // normalised and its owners settled first, so the two section filters work on
    // clean lines.
    let actions = normalize_action_lines(&actions);
    let actions = strip_invented_owners(&actions, transcript);
    let decisions = strip_owner_clauses(&decisions, &actions);
    let actions = drop_ownerless_restatements(&actions, &decisions);
    Ok(format!(
        "## 摘要\n{}\n\n## 決議\n{}\n\n## 待辦\n{}",
        summary.trim(),
        decisions,
        actions
    ))
}

/// Renders one list section, or （無） when the model said it had nothing.
/// The model signals "nothing here" with a bare 无 / 無 / None (simplified or
/// traditional, sometimes with a trailing period); that reads as an omission in
/// the file, so it becomes explicit instead.
fn section_or_empty(answer: &str) -> String {
    let trimmed = answer.trim();
    let bare = trimmed
        .trim_start_matches(['-', '*', ' '])
        .trim_end_matches(['。', '.', ' ']);
    let probe = bare.to_lowercase();
    if bare.is_empty() || matches!(probe.as_str(), "无" | "無" | "none" | "n/a" | "沒有" | "没有") {
        "（無）".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Removes decision lines that are meeting furniture rather than decisions.
///
/// Every meeting ends with "any questions? no", and the model reliably turns
/// that into "- No questions" under a 決議 heading, which reads as a decision
/// the group never made. Matching is on the line's content with punctuation and
/// case removed, so "No questions.", "- 沒有問題" and "N/A" all match.
fn drop_void_lines(decisions: &str) -> String {
    const VOID: [&str; 10] = [
        "noquestions", "nootherbusiness", "none", "na", "n/a",
        "沒有問題", "没有问题", "沒有其他事項", "沒有其他事情", "沒有決議",
    ];
    let kept: Vec<&str> = decisions
        .lines()
        .filter(|line| {
            let content: String = line
                .to_lowercase()
                .chars()
                .filter(|c| c.is_alphanumeric() || *c == '/')
                .collect();
            content.is_empty() || !VOID.contains(&content.as_str())
        })
        .collect();
    if kept.is_empty() {
        "（無）".to_string()
    } else {
        kept.join("\n")
    }
}

/// Removes invented owner prefixes from the 待辦 answer.
///
/// The model fabricates an owner by promoting a topic to one: asked for
/// `- owner: task` it writes `- 課題一：上線時間延到十一月中` or `- Launch: …`, and
/// a "leave the owner out when the transcript does not give one" example only
/// fixes the transcript it was written for. The owner is therefore checked
/// against the transcript: it survives only when the transcript uses that string
/// the way one addresses or tasks a person -- followed by 你/您/麻煩/請/負責, by a
/// time phrase ("Amy 月底以前…"), or by a comma ("Sarah, finish…").
///
/// A rejected prefix keeps its task and loses only the label, so an invented
/// owner costs a label rather than a line. The check errs toward rejecting on
/// purpose: a rejected real owner is an omission, an accepted fake owner is a
/// fabricated fact, and fabrication is the failure to avoid.
fn strip_invented_owners(actions: &str, transcript: &str) -> String {
    if actions == "（無）" || actions.trim().is_empty() {
        return actions.to_string();
    }
    let mut kept: Vec<String> = Vec::new();
    for line in actions.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match split_owner(trimmed) {
            Some((owner, task)) if !owner_is_backed(owner, transcript) => {
                // Keep the bullet so the section still reads as a list.
                if trimmed.starts_with(['-', '*']) {
                    kept.push(format!("- {task}"));
                } else {
                    kept.push(task.to_string());
                }
            }
            _ => kept.push(trimmed.to_string()),
        }
    }
    if kept.is_empty() {
        "（無）".to_string()
    } else {
        kept.join("\n")
    }
}

/// Words that follow a person in an instruction: addressing them ("怡君你…",
/// "Sarah, finish"), making them responsible ("小明負責部署"), or placing the work
/// in time ("Amy 月底以前…", "Tom next week"). A topic the model promoted to an
/// owner ("課題一", "上線時間") is followed by none of them.
const OWNER_CUES_CJK: [&str; 20] = [
    "你", "您", "麻煩", "請", "負責", "協助", "幫忙", "這邊", "你們",
    "今天", "明天", "後天", "這週", "這禮拜", "下週", "下個月", "下月", "月底", "月初", "以前",
];
const OWNER_CUES_EN: [&str; 6] = ["will", "please", "could", "can", "should", "'ll"];

/// Whether the transcript supports `owner` as a person it addresses or tasks.
fn owner_is_backed(owner: &str, transcript: &str) -> bool {
    let haystack = transcript.to_lowercase();
    let needle = owner.to_lowercase();
    if needle.is_empty() {
        return false;
    }
    // A Latin owner followed by a comma is being addressed ("Sarah, finish…").
    // CJK needs a stronger cue: a topic sits before a comma all the time
    // ("第一個是上線時間，討論之後…"), and that was a fabricated owner surviving.
    let latin = owner.chars().all(|c| c.is_ascii_alphabetic());
    let mut from = 0;
    while let Some(found) = haystack[from..].find(&needle) {
        let at = from + found;
        let after = &transcript[at + needle.len()..];
        // Punctuation and spaces are noise between a name and its cue.
        let window: String = after.chars().filter(|c| c.is_alphanumeric()).take(6).collect();
        if OWNER_CUES_CJK.iter().any(|cue| window.starts_with(cue)) {
            return true;
        }
        if OWNER_CUES_EN.iter().any(|cue| after.trim_start().starts_with(cue)) {
            return true;
        }
        if latin && (after.starts_with(',') || after.starts_with('，')) {
            return true;
        }
        from = at + needle.len();
    }
    false
}

/// Whether `text` names `owner`. A short Latin owner is matched on word
/// boundaries so that the owner "I" does not match every English sentence that
/// contains an "i"; CJK has no such ambiguity.
fn names_owner(text: &str, owner: &str) -> bool {
    let owner_is_latin = owner.chars().all(|c| c.is_ascii_alphabetic());
    if !owner_is_latin {
        return text.to_lowercase().contains(&owner.to_lowercase());
    }
    let haystack = text.to_lowercase();
    let needle = owner.to_lowercase();
    let bytes = haystack.as_bytes();
    let mut from = 0;
    while let Some(found) = haystack[from..].find(&needle) {
        let at = from + found;
        let before_ok = at == 0 || !bytes[at - 1].is_ascii_alphanumeric();
        let end = at + needle.len();
        let after_ok = end >= bytes.len() || !bytes[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        from = at + needle.len();
    }
    false
}

/// Drops 決議 clauses that name one of the meeting's owners.
///
/// The prompt asks for the decision "with no names and no assignments of work"
/// and the model obeys most of the time, which is not a guarantee: on an English
/// warehouse meeting it listed all three assignments under 決議 and left the two
/// real decisions out. That cannot be repaired here -- the filter can only
/// remove, not recover -- but the removals it makes are the ones it can prove:
/// a clause naming a person the action list already has is an assignment, not a
/// decision, and it goes.
///
/// The unit is the CLAUSE, and clauses are split at commas as well as sentence
/// ends. Splitting only on the period was the bug that made this filter a no-op:
/// "Priya redraws the plan, Marcus calls the vendor, and the count is handled by
/// the author" is one sentence holding three people, so either the whole answer
/// went (taking any real decision with it) or the keep-the-original fallback
/// dropped nothing at all.
fn strip_owner_clauses(decisions: &str, actions: &str) -> String {
    if decisions == "（無）" || decisions.trim().is_empty() {
        return decisions.to_string();
    }
    let owners = action_owners(actions);
    if owners.is_empty() {
        return decisions.to_string();
    }
    // Rejected: also dropping a clause that restates a task body. It catches the
    // 決議 leak the owner test misses ("客服的SOP下週五以前生出來"), but character
    // bigrams are too noisy to aim at a short body: English "update the status
    // page" shares 14 of its 18 bigrams with a long unrelated clause, so a real
    // decision got dropped. Needs a word-level test, not this one.
    let kept: Vec<(String, String)> = split_clauses(decisions)
        .into_iter()
        .filter(|(clause, _)| !names_an_owner(clause, &owners))
        .collect();
    if kept.is_empty() {
        "（無）".to_string()
    } else {
        join_clauses(&kept, crate::llm::has_cjk(decisions))
    }
}

/// Whether a decision clause is really an assignment that leaked out of the
/// action list.
///
/// Merely mentioning a person is not an assignment. "Sarah 明年三月退休" is a
/// decision about Sarah, and dropping it because Sarah happens to be on the
/// action list throws away a real decision -- which is the one thing this
/// filter cannot put back.
///
/// A Chinese assignment carries a task verb or a deadline, and that is what is
/// looked for. English keeps the older, looser rule (naming an owner is enough)
/// because a third-person verb marks neither "Marcus calls the vendor" nor
/// "Sarah retires in March", and the measured English cases are assignments.
fn names_an_owner(clause: &str, owners: &[String]) -> bool {
    owners.iter().any(|owner| {
        names_owner(clause, owner) && (!crate::llm::has_cjk(clause) || looks_like_a_task(clause))
    })
}

/// Cues that make a Chinese clause a piece of work rather than a statement
/// about a person.
fn looks_like_a_task(clause: &str) -> bool {
    // 安排 is in the list because a meeting with no decisions at all still
    // produced one: "美玲下週安排時間校對官網文案" survived as the 決議 of an
    // assignments-only meeting, because 安排 was not a task cue and 下週 without
    // 以前/之前 is not a deadline. It only ever applies to a clause that already
    // names an owner from the action list, so a decision about scheduling that
    // names nobody ("決定安排員工旅遊") is untouched.
    const TASK_VERBS: [&str; 11] = [
        "負責", "完成", "整理", "處理", "送出", "更新", "請", "必須", "交付", "跟進", "安排",
    ];
    TASK_VERBS.iter().any(|cue| clause.contains(cue)) || has_deadline(clause)
}

/// Whether a clause names a deadline.
///
/// "下週五以前" and "下週五前" are deadlines; "目前" and "前面" are not, so the
/// character before 前 is checked instead of the character itself.
fn has_deadline(clause: &str) -> bool {
    if clause.contains("以前") || clause.contains("之前") || clause.contains("截止") {
        return true;
    }
    let chars: Vec<char> = clause.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        if *c != '前' || i == 0 {
            continue;
        }
        let previous = chars[i - 1];
        if previous.is_ascii_digit() || "一二三四五六七八九十日天週禮拜".contains(previous) {
            return true;
        }
    }
    false
}

/// Whether a separator ends a sentence, as opposed to merely joining two parts
/// of one.
fn ends_a_sentence(separator: &str) -> bool {
    matches!(separator, "。" | "！" | "？" | "!" | "?" | ".")
}

/// Splits text into `(clause, trailing separator)` pairs. Both sentence and list
/// punctuation end a clause -- see `strip_owner_clauses` for why a comma counts.
fn split_clauses(text: &str) -> Vec<(String, String)> {
    let mut clauses: Vec<(String, String)> = Vec::new();
    let mut current = String::new();
    for ch in text.chars() {
        if matches!(ch, '。' | '！' | '？' | '；' | '!' | '?' | ';' | '\n' | '，' | ',' | '、' | '.') {
            let trimmed = current.trim();
            if !trimmed.is_empty() {
                clauses.push((trimmed.to_string(), ch.to_string()));
            }
            current.clear();
        } else {
            current.push(ch);
        }
    }
    let trimmed = current.trim();
    if !trimmed.is_empty() {
        clauses.push((trimmed.to_string(), String::new()));
    }
    clauses
}

/// Rebuilds clauses into one line, keeping each clause's own punctuation where it
/// still separates something and closing the sentence otherwise.
fn join_clauses(clauses: &[(String, String)], chinese: bool) -> String {
    let inside = if chinese { "，" } else { ", " };
    let ending = if chinese { "。" } else { "." };
    let last = clauses.len().saturating_sub(1);
    let mut out = String::new();
    for (i, (clause, separator)) in clauses.iter().enumerate() {
        // A clause kept after a dropped one can start with the conjunction that
        // joined them ("and the count is handled by the author").
        out.push_str(drop_leading_conjunction(clause));
        if i < last {
            if separator.is_empty() || separator == "、" {
                out.push_str(inside);
            } else {
                out.push_str(separator);
            }
        } else if separator.is_empty() || !ends_a_sentence(separator) {
            // The last clause cannot end on a weak separator. When a clause was
            // dropped, the one before it still carries the separator it had in
            // the middle of the list ("…、") and ending there leaves the section
            // dangling: "決定上線，預算砍三成、".
            out.push_str(ending);
        } else {
            out.push_str(separator);
        }
    }
    // Dropping a leading conjunction can leave an English clause starting
    // mid-sentence ("and the count is handled by the author" -> "the count…").
    // Capitalise so the section does not read as a typo.
    if !chinese && out.starts_with(|c: char| c.is_ascii_lowercase()) {
        let mut chars = out.chars();
        if let Some(first) = chars.next() {
            out = format!("{}{}", first.to_ascii_uppercase(), chars.as_str());
        }
    }
    out
}

fn drop_leading_conjunction(clause: &str) -> &str {
    let lower = clause.to_lowercase();
    for conjunction in ["and ", "並且", "而且", "另外"] {
        if lower.starts_with(conjunction) {
            return clause[conjunction.len()..].trim_start();
        }
    }
    clause
}

/// The owner of every 待辦 line that names one (`- Sarah: …` -> `Sarah`).
fn action_owners(actions: &str) -> Vec<String> {
    actions
        .lines()
        .filter_map(|line| split_owner(line).map(|(owner, _)| owner.to_string()))
        .collect()
}

/// Splits a 待辦 line into its owner and the rest. The colon must be near the
/// front (in characters, not bytes -- four CJK characters are already twelve
/// bytes): a colon further in belongs to the task's own text
/// ("問設計公司報價：今天沒定誰去問" has none).
fn split_owner(line: &str) -> Option<(&str, &str)> {
    let body = line.trim().trim_start_matches(['-', '*', ' ']);
    let mut before = 0usize;
    let mut cut = None;
    for (i, ch) in body.char_indices() {
        if ch == '：' || ch == ':' {
            if before <= 12 {
                cut = Some(i);
            }
            break;
        }
        before += 1;
    }
    let cut = cut?;
    let owner = body[..cut].trim();
    let task = body[cut..].trim_start_matches(['：', ':']).trim();
    (!owner.is_empty() && !task.is_empty()).then_some((owner, task))
}

/// Whether an action line and a decision clause say the same thing, in either
/// direction: the line restating the clause, or the clause being the line's
/// content said shorter -- "行銷活動暫緩" against "暫緩行銷活動，等產品穩定再說" is
/// the same decision twice, and neither direction alone catches both.
fn restates(line: &[String], clause: &[String], line_text: &str, clause_text: &str) -> bool {
    const RESTATED: f32 = 0.60;
    if line.is_empty() || clause.is_empty() {
        return false;
    }
    let shared = line.iter().filter(|gram| clause.contains(*gram)).count();
    if (shared as f32) / (line.len() as f32) >= RESTATED {
        return true;
    }
    // A short clause contained in a longer line is only a duplicate if the clause
    // is substantial; a two-character grab would match half the list. It also
    // has to be a duplicate and nothing more: a line that starts with the
    // decision but names work of its own is not saying the decision twice.
    clause.len() >= 4
        && (shared as f32) / (clause.len() as f32) >= RESTATED
        && !adds_work_of_its_own(line_text, clause_text)
}

/// Whether an action line carries work that the decision it echoes does not.
///
/// "暫緩行銷活動，等產品穩定再說" says the same as "行銷活動暫緩" and is dropped.
/// "停用舊版後要更新說明文件" starts with the decision but also names a task
/// nobody mentioned, and dropping it would lose that task.
fn adds_work_of_its_own(line: &str, clause: &str) -> bool {
    const WORK_CUES: [&str; 8] = ["要", "需要", "負責", "記得", "請", "必須", "處理", "更新"];
    WORK_CUES.iter().any(|cue| line.contains(cue) && !clause.contains(cue))
}

/// Rebuilds the 待辦 answer as one bulleted item per line.
///
/// The model usually complies, but it also returns one long line holding the
/// whole list ("- 今天先上線首頁…。珮婷整理…。問設計公司報價。"). Judging that line
/// as one item means one stray fragment can drop the whole list, so the section
/// is normalised before anything else looks at it.
fn normalize_action_lines(actions: &str) -> String {
    if actions == "（無）" || actions.trim().is_empty() {
        return actions.to_string();
    }
    let mut items: Vec<String> = Vec::new();
    for line in actions.lines() {
        let mut current = String::new();
        for ch in line.trim().chars() {
            if matches!(ch, '。' | '；' | '\n') {
                push_item(&mut items, &current);
                current.clear();
            } else {
                current.push(ch);
            }
        }
        push_item(&mut items, &current);
    }
    if items.is_empty() {
        "（無）".to_string()
    } else {
        items.join("\n")
    }
}

fn push_item(items: &mut Vec<String>, text: &str) {
    let body = text.trim().trim_start_matches(['-', '*', ' ']).trim();
    if !body.is_empty() {
        items.push(format!("- {body}"));
    }
}

/// Drops 待辦 lines that name nobody and only restate a decision.
///
/// A meeting that decides "每月固定開一次檢討會" and hands it to nobody produces
/// the same line under both 決議 and 待辦. One mention per fact is the rule, and
/// the ownerless restatement is the one to lose: the decision section already
/// carries it and nothing was assigned. A line WITH an owner is never dropped --
/// it names who is doing something, which the decision section cannot hold.
///
/// Unlike the earlier version this does empty the section when every line is a
/// restatement, because that is the truth: a meeting that assigned nothing has
/// an empty 待辦. The old "never empty" fallback meant the filter could not
/// touch a section that was entirely wrong, which is exactly the case it exists
/// for.
fn drop_ownerless_restatements(actions: &str, decisions: &str) -> String {
    if decisions.trim().is_empty() || decisions == "（無）" {
        return actions.to_string();
    }
    if actions.trim().is_empty() || actions == "（無）" {
        return actions.to_string();
    }
    let clauses: Vec<(Vec<String>, String)> = split_clauses(decisions)
        .into_iter()
        .map(|(clause, _)| (gram_set(&clause), clause))
        .collect();
    let kept: Vec<&str> = actions
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return false;
            }
            if has_owner(trimmed) {
                return true;
            }
            let grams = gram_set(trimmed);
            !clauses.iter().any(|(clause_grams, clause_text)| {
                restates(&grams, clause_grams, trimmed, clause_text)
            })
        })
        .collect();
    if kept.is_empty() {
        "（無）".to_string()
    } else {
        kept.join("\n")
    }
}

/// Whether a 待辦 line names an owner, in the "owner: task" shape.
fn has_owner(line: &str) -> bool {
    split_owner(line).is_some()
}

/// Character bigrams of a line, with punctuation and the "- " bullet stripped,
/// so an overlap test compares content rather than formatting. Latin text is
/// folded to lower case first, so shared words still count. `is_alphanumeric`
/// covers CJK ideographs (they are Alphabetic) but not CJK punctuation, which is
/// what separates 上線 from the ：and ，around it.
fn gram_set(text: &str) -> Vec<String> {
    let cleaned: String = text.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect();
    let chars: Vec<char> = cleaned.chars().collect();
    if chars.len() < 2 {
        return chars.iter().map(|c| c.to_string()).collect();
    }
    chars.windows(2).map(|w| w.iter().collect()).collect()
}

/// Translate a finished line into another language.
///
/// Runs as its own worker pass AFTER the refine pass rather than inside it: the
/// two jobs pull in opposite directions (refine must not change the language;
/// translate must), and one prompt asked to do both produced drafts that were
/// half-translated. `target` is "en" or "zh".
pub fn translate_text(text: &str, target: &str) -> Result<String> {
    let model = llm_model_path()?;
    run_worker(&worker_path()?, "translate", &model, text, target)
}

/// Apply a dictated edit instruction to text the app already produced.
///
/// A worker task of its own rather than a flag on the refine task, for the same
/// reason `translate` is: the two jobs ask for opposite things from the model.
/// Refine is handed speech and told to clean it, keeping the speaker's language
/// and leaving no instruction in the result; edit is handed finished text and
/// told to CHANGE it exactly as instructed. Refine also numbers nothing -- it
/// receives one chunk -- while an edit needs the text numbered before the model
/// sees it, and the numbering has to survive the round trip. A flag would make
/// the two share one prompt and one example set, and the refine behaviour that
/// was measured with its own examples would change under it.
///
/// `instruction` is the spoken instruction ("把第二點改成禮拜五下午兩點").
pub fn edit_text(text: &str, instruction: &str) -> Result<String> {
    let model = llm_model_path()?;
    run_worker(&worker_path()?, "edit", &model, text, instruction)
}

/// Map chunk size in characters and the overlap between adjacent chunks.
const SUMMARY_CHUNK_CHARS: usize = 600;
const SUMMARY_OVERLAP_CHARS: usize = 20;

/// The worker is installed next to the core library (Contents/Frameworks in the app bundle),
/// or next to the current executable for development runs.
fn worker_path() -> Result<PathBuf> {
    // An explicit path wins, so the engine can be embedded by a caller whose
    // worker does not sit beside its own executable (the command-line tool, a
    // test binary, another host app). Without it the search below is the story.
    if let Some(explicit) = std::env::var("OVC_LLM_WORKER").ok().filter(|v| !v.trim().is_empty()) {
        let path = PathBuf::from(explicit.trim());
        if path.is_file() {
            return Ok(path);
        }
    }
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

#[cfg(test)]
mod tests {
    use super::{
        action_owners, drop_ownerless_restatements, drop_void_lines, has_owner, names_owner,
        normalize_action_lines, owner_is_backed, section_or_empty, strip_invented_owners,
        strip_owner_clauses,
    };

    /// The model's "nothing here" answers, in every shape seen in testing.
    #[test]
    fn nothing_becomes_an_explicit_marker() {
        for answer in ["无", "無", "无。", "None", "- 無", "  n/a "] {
            assert_eq!(section_or_empty(answer), "（無）", "answer: {answer:?}");
        }
        assert_eq!(section_or_empty("- 下週三上線"), "- 下週三上線");
    }

    /// The 決議 answer is a sentence, not a bullet list: it must pass through
    /// unchanged, and a one-sentence answer that names no one must survive.
    #[test]
    fn a_decision_sentence_survives_untouched() {
        let sentence = "決定廣告預算砍三成、人員不新增正職改用約聘。";
        assert_eq!(drop_void_lines(&section_or_empty(sentence)), sentence);
        assert_eq!(drop_void_lines(&section_or_empty("无")), "（無）");
    }

    /// "Any questions? No." is meeting furniture, not a decision, and it is the
    /// one void answer that survives into a real meeting's decisions list.
    #[test]
    fn meeting_furniture_is_not_a_decision() {
        assert_eq!(drop_void_lines("- No questions"), "（無）");
        assert_eq!(drop_void_lines("- 沒有問題\n- 下週三上線"), "- 下週三上線");
        assert_eq!(drop_void_lines("- 下週三上線"), "- 下週三上線");
    }

    /// An owner is a colon near the front. A colon deeper in the line belongs to
    /// the task's own text.
    #[test]
    fn owner_is_recognised_by_position() {
        assert!(has_owner("- 珮婷：整理紀錄"));
        assert!(has_owner("- Sarah: send the quote"));
        assert!(has_owner("- 問設計公司報價：今天沒定誰去問"));
        let late = format!("- {}：備註", "整理紀錄".repeat(4));
        assert!(!has_owner(&late));
    }

    #[test]
    fn owners_are_read_off_the_action_list() {
        assert_eq!(
            action_owners("- Sarah: finish the runbook\n- 珮婷：整理紀錄\n- 換掉首頁的文案"),
            vec!["Sarah".to_string(), "珮婷".to_string()]
        );
    }

    /// The fabricated owners: the model promotes the meeting's topics to owners.
    /// `課題一`, `課題二` and `課題三` are how it numbered them, and none of those
    /// strings is in the transcript.
    #[test]
    fn invented_owners_are_dropped_from_the_action_list() {
        let transcript = "今天主要討論兩件事。第一，大家決定把上線時間延到十一月中，因為測試還沒完成。\
                          第二，我們決定今年不新增正職，缺的人力先用約聘補。另外也決定行銷活動先暫緩，\
                          等產品穩定再說。細節之後再討論，今天先到這裡。";
        let actions = "- 課題一：上線時間延到十一月中\n\
                       - 課題二：不新增正職，用約聘補\n\
                       - 課題三：暫緩行銷活動，等產品穩定再說";
        assert_eq!(
            strip_invented_owners(actions, transcript),
            "- 上線時間延到十一月中\n- 不新增正職，用約聘補\n- 暫緩行銷活動，等產品穩定再說"
        );
    }

    /// A topic can sit before a comma in the transcript ("第一個是上線時間，討論之後…"),
    /// which is why a CJK owner needs an address cue and not just a comma.
    #[test]
    fn a_topic_before_a_comma_is_not_an_owner() {
        let transcript = "第一個是上線時間，討論之後我們決定下週三正式上線。第二個是預算。\
                          第三個是分工。怡君你下週五以前把客服的 SOP 生出來。";
        assert!(!owner_is_backed("上線時間", transcript));
        assert!(!owner_is_backed("分工", transcript));
        assert!(owner_is_backed("怡君", transcript));
        assert_eq!(
            strip_invented_owners("- 上線時間：下週三\n- 分工：怡君：生 SOP", transcript),
            "- 下週三\n- 怡君：生 SOP"
        );
    }

    /// Every way the transcripts actually address someone.
    #[test]
    fn real_owners_are_kept() {
        assert!(owner_is_backed("Sarah", "Sarah, finish the rollback runbook by October 30th."));
        assert!(owner_is_backed("Tom", "Tom will schedule the load tests for next week."));
        assert!(owner_is_backed("I", "And I'll get the contract draft to legal by Monday."));
        assert!(owner_is_backed("Everyone", "Everyone, update the status page before Friday."));
        assert!(owner_is_backed("怡君", "怡君你下週五以前把客服的 SOP 生出來。"));
        assert!(owner_is_backed("我", "然後我這邊下週一以前把合約草稿送給法務。"));
        assert!(owner_is_backed("Amy", "Amy 月底以前重新跑一次通路補貼試算。"));
        assert!(owner_is_backed("小明", "小明負責部署上線。"));
        // Named, but not given anything: no cue, so not an owner -- and the
        // transcript never mentions the model's garbled spelling at all.
        assert!(!owner_is_backed("阿明", "阿明畫新的動線圖，貼在公佈欄。"));
        assert!(!owner_is_backed("還明", "阿明畫新的動線圖，貼在公佈欄。"));
    }

    /// A one-letter Latin owner must match a word, or the owner "I" would match
    /// every English sentence containing an "i".
    #[test]
    fn names_owner_matches_words_not_letters() {
        assert!(names_owner("I will handle the quarterly stock count", "I"));
        assert!(!names_owner("the quarterly stock count is handled by the author", "I"));
        assert!(names_owner("Sarah will finish the runbook", "Sarah"));
        assert!(names_owner("珮婷負責整理紀錄", "珮婷"));
    }

    /// The reviewer's English warehouse meeting: the model answered 決議 with the
    /// three assignments and none of the decisions. No name may survive in it.
    #[test]
    fn assignment_clauses_leave_the_decision() {
        let decisions = "Priya redraws the floor plan by Thursday, Marcus calls the vendor for \
                         jack lead times, and the quarterly stock count is handled by the author.";
        let actions = "- Priya: redraw the floor plan by Thursday\n\
                       - Marcus: call the vendor about the jack lead times\n\
                       - I: handle the quarterly stock count myself";
        let cleaned = strip_owner_clauses(decisions, actions);
        assert!(!cleaned.contains("Priya"), "leaked into: {cleaned}");
        assert!(!cleaned.contains("Marcus"), "leaked into: {cleaned}");
    }

    /// The English migration meeting: three assignments appended to a real
    /// decision. Only the decision stays.
    #[test]
    fn clauses_naming_an_owner_leave_the_decision() {
        let decisions = "The migration meeting decided to move the cutover to November 5th and \
                         keep the old API alive for another quarter. Sarah will finish the \
                         rollback runbook by October 30th, and Tom will schedule the load tests \
                         for next week. Everyone should update the status page before Friday.";
        let actions = "- Sarah: finish the rollback runbook by October 30th\n\
                       - Tom: schedule the load tests for next week\n\
                       - Everyone: update the status page";
        assert_eq!(
            strip_owner_clauses(decisions, actions),
            "The migration meeting decided to move the cutover to November 5th and keep the old \
             API alive for another quarter."
        );
    }

    /// A meeting that decided nothing still gets a 決議 from the model, and the
    /// one it produced was an assignment phrased with 安排 rather than 負責.
    #[test]
    fn a_scheduling_assignment_is_not_a_decision() {
        let decisions = "志豪安排伺服器備份排程，美玲安排下週校對官網文案。";
        let actions = "- 怡君：整理上週會議紀錄，明天之前寄給大家\n\
                       - 志豪：這週五以前把伺服器備份排程設好\n\
                       - 美玲：下週找時間把官網文案校對一次";
        assert_eq!(strip_owner_clauses(decisions, actions), "（無）");
    }

    /// Decisions only, nobody assigned: every 待辦 line is a decision said twice,
    /// so 待辦 is empty -- which is the truth, and the whole point of the filter.
    #[test]
    fn decision_restatements_leave_an_empty_action_list() {
        let decisions = "決定把上線時間延到十一月中，今年不新增正職，行銷活動暫緩。";
        let actions = "- 上線時間延到十一月中\n- 不新增正職，用約聘補\n- 暫緩行銷活動，等產品穩定再說";
        assert_eq!(drop_ownerless_restatements(actions, decisions), "（無）");
    }

    /// The real shape: a decision nobody was handed appears under both headings,
    /// and only the 待辦 copy goes. The line with an owner stays, and so does the
    /// ownerless line that shares nothing with the decision.
    #[test]
    fn an_ownerless_restatement_leaves_the_action_list() {
        let decisions = "決定首頁今天上線，其他頁面之後再說，每月固定開一次檢討會。";
        let actions = "- 珮婷：整理使用者的訪談紀錄\n\
                       - 問設計公司報價，今天沒定誰去問\n\
                       - 每月固定開一次檢討會";
        assert_eq!(
            drop_ownerless_restatements(actions, decisions),
            "- 珮婷：整理使用者的訪談紀錄\n- 問設計公司報價，今天沒定誰去問"
        );
    }

    /// An assignment is never dropped, even when it reads like the decision it
    /// implements: it carries the owner.
    #[test]
    fn an_assigned_restatement_stays() {
        let decisions = "The old API will be kept alive for another quarter.";
        let actions = "- Sarah: keep the old API alive for another quarter";
        assert_eq!(drop_ownerless_restatements(actions, decisions), actions);
        assert_eq!(drop_ownerless_restatements("- 買咖啡豆", "（無）"), "- 買咖啡豆");
    }

    /// The model sometimes returns the whole list as one line: judging that line
    /// as a single item meant one fragment could drop every real action with it.
    #[test]
    fn the_action_list_is_split_into_one_item_per_line() {
        let blob = "- 今天先上線首頁，其他頁面之後再說。珮婷整理使用者訪談紀錄。問設計公司報價。\
                    每月固定開一次檢討會。";
        assert_eq!(
            normalize_action_lines(blob),
            "- 今天先上線首頁，其他頁面之後再說\n- 珮婷整理使用者訪談紀錄\n- 問設計公司報價\n\
             - 每月固定開一次檢討會"
        );
        assert_eq!(normalize_action_lines("（無）"), "（無）");
    }

    /// A 決議 that names nobody cannot be filtered against anything, so it passes
    /// through -- the filter only removes what it can prove.
    #[test]
    fn a_decision_naming_nobody_is_left_alone() {
        let decisions = "決定把客服服務時間延長到晚上九點。";
        assert_eq!(strip_owner_clauses(decisions, "- 買咖啡豆"), decisions);
        assert_eq!(strip_owner_clauses(decisions, "（無）"), decisions);
    }

    /// A decision ABOUT a person is not an assignment. Sarah can be on the action
    /// list and the decision "Sarah 明年三月退休" still has to survive: it names
    /// her, but it is not work being handed to her.
    #[test]
    fn a_decision_about_a_person_is_not_an_assignment() {
        let decisions = "Sarah 明年三月退休。";
        let actions = "- Sarah: 交接工作";
        assert_eq!(
            strip_owner_clauses(decisions, actions),
            "Sarah 明年三月退休。"
        );
    }

    /// The assignment shape still goes, even in Chinese: a task verb and a
    /// deadline are what tell the two apart.
    #[test]
    fn a_chinese_assignment_still_leaves_the_decision() {
        let decisions = "決定下週三上線，怡君下週五前完成客服 SOP。";
        let actions = "- 怡君：下週五以前把客服的 SOP 生出來";
        let cleaned = strip_owner_clauses(decisions, actions);
        assert!(!cleaned.contains("怡君"), "leaked into: {cleaned}");
        assert!(cleaned.contains("下週三上線"), "lost a decision: {cleaned}");
    }

    /// A section must not end on a separator that was in the middle of the list.
    /// Dropping a clause used to leave "決定上線，預算砍三成、".
    #[test]
    fn the_decision_does_not_end_on_a_dangling_separator() {
        let decisions = "決定下週三上線、廣告預算砍三成、怡君下週五前完成客服 SOP。";
        let actions = "- 怡君：下週五以前把客服的 SOP 生出來";
        let cleaned = strip_owner_clauses(decisions, actions);
        assert!(cleaned.ends_with('。'), "dangling end: {cleaned}");
        assert!(!cleaned.ends_with('、'), "dangling end: {cleaned}");
    }

    /// An action line that starts with the decision but names work of its own is
    /// not the decision said twice, and dropping it loses that work.
    #[test]
    fn an_action_that_adds_work_is_not_a_restatement() {
        let decisions = "決定停用舊版。";
        let actions = "- 停用舊版後要更新說明文件";
        assert_eq!(drop_ownerless_restatements(actions, decisions), actions);
    }

    /// A real Qwen3.5-2B answer to verification transcript t1, which is what the
    /// filter sees in production. Two assignments have to leave, the two real
    /// decisions have to stay, and the section must not end on the "、" that used
    /// to be in the middle of the list.
    #[test]
    fn a_real_qwen35_answer_keeps_its_decisions() {
        let decisions = "決定下週三正式上線、廣告預算砍三成並保留多餘部分、\
                         怡君下週五前完成客服 SOP、志豪下週四前整理測試報告。";
        let actions = "- 怡君：下週五以前把客服的 SOP 生出來\n\
                       - 志豪：這週四以前把測試報告整理好寄給我\n\
                       - 我：下週一以前把合約草稿送給法務";
        let cleaned = strip_owner_clauses(decisions, actions);
        assert!(cleaned.contains("上線"), "lost the decision: {cleaned}");
        assert!(cleaned.contains("廣告預算"), "lost the decision: {cleaned}");
        assert!(!cleaned.contains("怡君"), "kept an assignment: {cleaned}");
        assert!(!cleaned.contains("志豪"), "kept an assignment: {cleaned}");
        assert!(cleaned.ends_with('。'), "dangling end: {cleaned}");
    }

    /// The same line without the extra work IS the decision said twice.
    #[test]
    fn an_action_that_only_repeats_the_decision_goes() {
        let decisions = "決定停用舊版。";
        let actions = "- 停用舊版";
        assert_eq!(drop_ownerless_restatements(actions, decisions), "（無）");
    }
}
