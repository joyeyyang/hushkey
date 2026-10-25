//! Streaming utterance segmentation.
//!
//! The recogniser decodes one utterance per call, so something has to decide
//! where an utterance begins and ends. That decision lives here, on the audio
//! clock, rather than in the app: the timestamps of a transcript, its SRT export
//! and the point where the microphone stream hands over to the system-audio
//! stream all have to agree with each other.
//!
//! It deliberately does not decode. Decoding takes hundreds of milliseconds and
//! must never run on the thread that is receiving audio, so this module only
//! accumulates samples and hands back finished utterances.

use crate::vad;

pub const SAMPLE_RATE: usize = 16_000;
/// 30 ms of audio per analysis frame.
pub const FRAME: usize = 480;

/// A frame counts as the *start* of speech above this mean square.
///
/// Lowered from 3e-4 (about -35 dBFS) to 5e-5 (about -43 dBFS), measured on
/// synthesised speech scaled down to a peak of 0.05 (a quiet speaker, or someone
/// sitting back from the microphone): at 3e-4 the whole utterance was dropped --
/// the transcript came back EMPTY -- and that is the failure the user reported as
/// "the words do not match what I said", because an onset that fires late eats
/// the first word and an onset that never fires eats the sentence.
///
/// The floor is not lowered with it: `onset_threshold` still takes
/// `max(this, noise_floor * 8)`, and the floor tracks the room while nothing is
/// being said, so a noisy room raises the gate back up on its own.
pub const ONSET_MEAN_SQUARE: f32 = 5e-5;
/// Once speaking, a quieter frame still counts as speech. The gap between the
/// two thresholds is what stops a soft final syllable from cutting the
/// utterance in half.
///
/// Lowered from 1e-4 (about -40 dBFS) after the user reported recognition worse
/// than the system dictation: a phrase that trails off is a quieter frame, not a
/// pause, and a split there costs the recogniser the end of a word. The floor
/// still clamps this upward in a noisy room (`continue_threshold`), so the extra
/// sensitivity only applies where the room is quiet enough to earn it.
pub const CONTINUE_MEAN_SQUARE: f32 = 7e-5;
/// 540 ms of quiet closes an utterance.
pub const END_SILENCE_FRAMES: usize = 18;
/// Shorter than 240 ms and it is a click, a lip smack or a chair, not speech.
pub const MIN_SPEECH_FRAMES: usize = 8;
/// Keep 300 ms of the trailing quiet so the recogniser never hears a clipped stop.
pub const TAIL_FRAMES: usize = 10;
/// Audio kept before the onset, so the first phoneme is not lost.
///
/// 360 ms, up from 150: the recogniser is non-autoregressive and cannot infer a
/// clipped consonant back, and a word-initial fricative or an aspirated stop is
/// exactly what the onset test fires after. The gap a previous utterance closes
/// on is 540 ms (`END_SILENCE_FRAMES`), so this window is always inside silence
/// and cannot pull the previous sentence back in.
pub const PREROLL_FRAMES: usize = 12;
/// Close a monologue after 30 s so the buffer cannot grow without bound.
pub const MAX_UTTERANCE_FRAMES: usize = 1000;

/// Bring a quiet utterance up to a level the recogniser was trained on.
///
/// The model consumes log-mel energies, so a recording 15 dB below the training
/// level is not a scaled copy of the same input -- it is a different input, and
/// the word error rate moves with it. The gain is therefore applied per
/// utterance, only upwards, and capped:
///
/// * a loud utterance is left alone, because normalising it downwards would take
///   away level information the model expects to see;
/// * a segment whose peak is under `MIN_PEAK_TO_BOOST` is left alone as well,
///   because that is room tone and the decoder can invent words for it;
/// * the cap keeps one stray sample (a click, a keyboard) from setting a gain
///   that makes the rest of the utterance clip.
fn normalize_gain(samples: &mut [f32]) {
    const TARGET_PEAK: f32 = 0.5;
    const MAX_GAIN: f32 = 4.0;
    const MIN_PEAK_TO_BOOST: f32 = 0.02;
    let peak = samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
    if peak < MIN_PEAK_TO_BOOST || peak >= TARGET_PEAK {
        return;
    }
    let gain = (TARGET_PEAK / peak).min(MAX_GAIN);
    for sample in samples.iter_mut() {
        *sample = (*sample * gain).clamp(-1.0, 1.0);
    }
}

/// One stretch of speech, in session time.
#[derive(Debug, Clone, PartialEq)]
pub struct Utterance {
    /// Seconds from the start of the session.
    pub start: f64,
    pub end: f64,
    pub samples: Vec<f32>,
}

impl Utterance {
    pub fn duration(&self) -> f64 {
        self.end - self.start
    }
}

/// Join utterance texts into one transcript.
///
/// Chinese must not gain spaces at the seams and English must, so the rule is
/// applied per boundary: mixed speech still reads the way it was spoken.
pub fn join_speech(parts: &[&str]) -> String {
    let mut out = String::new();
    for part in parts {
        let piece = part.trim();
        if piece.is_empty() {
            continue;
        }
        if let (Some(left), Some(right)) = (out.chars().next_back(), piece.chars().next()) {
            if !(is_cjk(left) && is_cjk(right)) {
                out.push(' ');
            }
        }
        out.push_str(piece);
    }
    out
}

fn is_cjk(character: char) -> bool {
    matches!(
        character as u32,
        0x2E80..=0x9FFF | 0xF900..=0xFAFF | 0xFE30..=0xFE4F | 0xFF00..=0xFF60 | 0x20000..=0x3FFFF
    )
}

/// Frame-by-frame voice activity state machine.
pub struct Segmenter {
    /// Samples that do not yet fill a frame.
    carry: Vec<f32>,
    /// The last few frames, held so an onset can include what led up to it.
    preroll: Vec<f32>,
    /// Frames consumed since the session started, including the current one.
    frames_seen: u64,
    /// Audio of the utterance being built, starting at `onset_frame`.
    audio: Vec<f32>,
    /// Frame index (absolute) where `audio` begins.
    onset_frame: u64,
    /// Absolute index of the most recent voiced frame.
    last_voiced_frame: u64,
    speech_frames: usize,
    silence_frames: usize,
    /// Running noise estimate, updated only while not speaking.
    noise_floor: f32,
}

impl Default for Segmenter {
    fn default() -> Self {
        Self::new()
    }
}

impl Segmenter {
    pub fn new() -> Self {
        Self {
            carry: Vec::new(),
            preroll: Vec::new(),
            frames_seen: 0,
            audio: Vec::new(),
            onset_frame: 0,
            last_voiced_frame: 0,
            speech_frames: 0,
            silence_frames: 0,
            noise_floor: 1e-5,
        }
    }

    /// Feed PCM. Appends any utterances that closed while consuming it.
    pub fn push(&mut self, samples: &[f32], out: &mut Vec<Utterance>) {
        self.carry.extend_from_slice(samples);
        let complete = self.carry.len() / FRAME;
        for index in 0..complete {
            let frame = &self.carry[index * FRAME..(index + 1) * FRAME];
            // `consume_frame` borrows self mutably, so the frame is copied out
            // first; one 30 ms copy per frame is nothing next to decoding.
            let frame: [f32; FRAME] = frame.try_into().expect("frame is FRAME long");
            self.consume_frame(&frame, out);
        }
        if complete > 0 {
            self.carry.drain(..complete * FRAME);
        }
    }

    /// Close whatever is buffered. Call on stop, and when the speaker changes:
    /// speech from two different people must never share one utterance.
    pub fn flush(&mut self, out: &mut Vec<Utterance>) {
        // A partial frame is finished with silence rather than discarded: the
        // tail of the last word lives in it.
        if !self.carry.is_empty() {
            let mut padded = [0.0f32; FRAME];
            let take = self.carry.len();
            padded[..take].copy_from_slice(&self.carry);
            self.carry.clear();
            self.consume_frame(&padded, out);
        }
        if self.speech_frames > 0 {
            self.close(out);
        }
    }

    /// True while a word is (probably) still being spoken — used to decide
    /// whether the app should keep the microphone open a moment longer.
    pub fn in_speech(&self) -> bool {
        self.speech_frames > 0
    }

    fn onset_threshold(&self) -> f32 {
        ONSET_MEAN_SQUARE.max(self.noise_floor * 8.0)
    }

    fn continue_threshold(&self) -> f32 {
        CONTINUE_MEAN_SQUARE.max(self.noise_floor * 3.0)
    }

    fn consume_frame(&mut self, frame: &[f32; FRAME], out: &mut Vec<Utterance>) {
        let energy = frame.iter().map(|x| x * x).sum::<f32>() / FRAME as f32;
        let speaking = self.speech_frames > 0;
        let voiced = energy >= if speaking { self.continue_threshold() } else { self.onset_threshold() };

        if voiced {
            if !speaking {
                let preroll_frames = self.preroll.len() / FRAME;
                self.onset_frame = self.frames_seen - preroll_frames as u64;
                self.audio.clear();
                self.audio.extend_from_slice(&self.preroll);
            }
            self.audio.extend_from_slice(frame);
            self.speech_frames += 1;
            self.silence_frames = 0;
            self.last_voiced_frame = self.frames_seen;
            if self.audio.len() >= MAX_UTTERANCE_FRAMES * FRAME {
                self.split_at_cap(out);
            }
        } else if speaking {
            self.audio.extend_from_slice(frame);
            self.silence_frames += 1;
            if self.silence_frames >= END_SILENCE_FRAMES {
                self.close(out);
            }
        } else {
            // Track the floor only on frames that are definitely not speech, so a
            // long sentence cannot drag the threshold up behind it.
            self.noise_floor = 0.98 * self.noise_floor + 0.02 * energy;
        }

        // Keep the preroll window filled, after the onset decision has used it.
        self.preroll.extend_from_slice(frame);
        let keep = PREROLL_FRAMES * FRAME;
        if self.preroll.len() > keep {
            let drop = self.preroll.len() - keep;
            self.preroll.drain(..drop);
        }
        self.frames_seen += 1;
    }

    /// Trim the trailing quiet, apply the minimum-length rule, and emit.
    fn close(&mut self, out: &mut Vec<Utterance>) {
        let speech_frames = self.speech_frames;
        let long_enough = speech_frames >= MIN_SPEECH_FRAMES;
        let start_frame = self.onset_frame;
        // Keep a short tail of quiet past the last voiced frame.
        let end_frame = (self.last_voiced_frame + 1 + TAIL_FRAMES as u64).min(self.frames_seen);
        let available = (end_frame - start_frame) as usize * FRAME;

        if long_enough && available > 0 {
            let mut samples = self.audio[..available.min(self.audio.len())].to_vec();
            normalize_gain(&mut samples);
            out.push(Utterance {
                start: start_frame as f64 * FRAME as f64 / SAMPLE_RATE as f64,
                end: (start_frame as f64 * FRAME as f64 + samples.len() as f64) / SAMPLE_RATE as f64,
                samples,
            });
        }

        self.audio.clear();
        self.speech_frames = 0;
        self.silence_frames = 0;
    }

    /// A monologue has run past the cap. Cut at the quietest frame in the last
    /// second (a breath, not the middle of a syllable) and keep the remainder as
    /// the start of the next utterance, so no audio is dropped on the floor.
    fn split_at_cap(&mut self, out: &mut Vec<Utterance>) {
        let cap = MAX_UTTERANCE_FRAMES * FRAME;
        let cut = vad::choose_cut(&self.audio, cap, SAMPLE_RATE, FRAME);
        let cut = ((cut / FRAME) * FRAME).clamp(FRAME, self.audio.len());
        let mut head = Vec::with_capacity(cut);
        head.extend_from_slice(&self.audio[..cut]);
        normalize_gain(&mut head);
        self.audio.drain(..cut);
        let start = self.onset_frame;
        self.onset_frame += (cut / FRAME) as u64;
        self.speech_frames = self.audio.len() / FRAME;
        out.push(Utterance {
            start: start as f64 * FRAME as f64 / SAMPLE_RATE as f64,
            end: (start as f64 * FRAME as f64 + head.len() as f64) / SAMPLE_RATE as f64,
            samples: head,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joining_cjk_adds_no_spaces_but_latin_does() {
        assert_eq!(join_speech(&["我們今天", "討論上線時間"]), "我們今天討論上線時間");
        assert_eq!(join_speech(&["we ship", "on Wednesday"]), "we ship on Wednesday");
        assert_eq!(join_speech(&["我們決定", "ship it"]), "我們決定 ship it");
        assert_eq!(join_speech(&["  ", "有東西"]), "有東西");
    }

    fn tone(seconds: f64, amplitude: f32) -> Vec<f32> {
        let n = (seconds * SAMPLE_RATE as f64) as usize;
        (0..n).map(|i| amplitude * (i as f32 * 0.05).sin()).collect()
    }

    fn silence(seconds: f64) -> Vec<f32> {
        vec![0.0; (seconds * SAMPLE_RATE as f64) as usize]
    }

    fn feed(segmenter: &mut Segmenter, chunks: &[Vec<f32>]) -> Vec<Utterance> {
        let mut out = Vec::new();
        for chunk in chunks {
            segmenter.push(chunk, &mut out);
        }
        out
    }

    #[test]
    fn two_bursts_become_two_utterances() {
        let mut s = Segmenter::new();
        let mut out = feed(
            &mut s,
            &[
                silence(0.5),
                tone(0.8, 0.25),
                silence(1.0),
                tone(0.7, 0.25),
                silence(1.0),
            ],
        );
        assert_eq!(out.len(), 2, "expected two utterances, got {out:?}");
        // The first burst starts at 0.5 s, minus the 360 ms preroll.
        assert!((out[0].start - 0.14).abs() < 0.05, "start {}", out[0].start);
        assert!(out[0].duration() > 0.8, "duration {}", out[0].duration());
        assert!(out[1].start > 1.9, "second start {}", out[1].start);
    }

    #[test]
    fn a_click_is_not_an_utterance() {
        let mut s = Segmenter::new();
        let out = feed(&mut s, &[silence(0.5), tone(0.1, 0.3), silence(1.0)]);
        assert!(out.is_empty(), "a 100 ms click became {out:?}");
    }

    #[test]
    fn pure_silence_produces_nothing() {
        let mut s = Segmenter::new();
        let out = feed(&mut s, &[silence(3.0)]);
        assert!(out.is_empty());
        assert!(!s.in_speech());
    }

    #[test]
    fn a_monologue_is_cut_before_the_buffer_runs_away() {
        let mut s = Segmenter::new();
        let mut out = Vec::new();
        for _ in 0..40 {
            s.push(&tone(1.0, 0.25), &mut out);
        }
        s.flush(&mut out);
        assert!(out.len() >= 2, "40 s of speech stayed in {} pieces", out.len());
        for u in &out {
            assert!(u.duration() <= 31.0, "utterance ran {}s", u.duration());
        }
    }

    #[test]
    fn chunking_does_not_change_the_result() {
        // The audio callback hands over whatever the hardware gives it, so the
        // segmentation must not depend on where the chunk boundaries fall.
        let signal: Vec<Vec<f32>> = vec![
            silence(0.5),
            tone(0.8, 0.25),
            silence(1.0),
            tone(0.7, 0.25),
            silence(1.0),
        ];

        let mut whole = Segmenter::new();
        let joined: Vec<f32> = signal.concat();
        let mut a = Vec::new();
        whole.push(&joined, &mut a);

        let mut chopped = Segmenter::new();
        let mut b = Vec::new();
        for piece in joined.chunks(777) {
            chopped.push(piece, &mut b);
        }

        assert_eq!(a.len(), b.len());
        for (x, y) in a.iter().zip(b.iter()) {
            assert!((x.start - y.start).abs() < 1e-6, "{} vs {}", x.start, y.start);
            assert!((x.end - y.end).abs() < 1e-6, "{} vs {}", x.end, y.end);
            assert_eq!(x.samples.len(), y.samples.len());
        }
    }

    #[test]
    fn flush_emits_a_trailing_word() {
        let mut s = Segmenter::new();
        let mut out = Vec::new();
        s.push(&silence(0.2), &mut out);
        s.push(&tone(1.0, 0.25), &mut out);
        assert!(out.is_empty(), "nothing should close without a pause");
        s.flush(&mut out);
        assert_eq!(out.len(), 1);
        assert!(out[0].duration() >= 1.0, "flushed {}s", out[0].duration());
    }

    #[test]
    fn a_soft_tail_does_not_split_an_utterance() {
        // Loud body, then a syllable at a quarter of the level. Hysteresis must
        // keep it inside the same utterance instead of starting a new one.
        let mut s = Segmenter::new();
        let mut out = Vec::new();
        s.push(&tone(0.9, 0.12), &mut out);
        s.push(&tone(0.4, 0.02), &mut out);
        s.push(&silence(1.0), &mut out);
        assert_eq!(out.len(), 1, "soft tail split the utterance: {out:?}");
        assert!(out[0].duration() > 1.2, "duration {}", out[0].duration());
    }
}
