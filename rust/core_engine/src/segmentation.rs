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

/// Floor for the onset gate: below this a frame is numerical silence, not a
/// question about the speaker.
///
/// The gate itself is the room's own noise level times `ONSET_SNR` -- see
/// `onset_threshold` for why an absolute level was the wrong shape. This
/// constant only stops a perfectly silent room from making the gate zero.
pub const ONSET_MEAN_SQUARE: f32 = 1e-6;
/// How many frames the noise estimate looks at: 3 seconds at 30 ms a frame.
///
/// Long enough that the gap between two words is inside the window, short enough
/// that a room which changes is re-measured within a few seconds.
pub const NOISE_WINDOW_FRAMES: usize = 100;
/// How far above the room's noise a frame must sit to *start* speech.
///
/// The absolute version of this was the defect the user hit. At -35 dBFS (later
/// -43) the gate was a fixed level the speaker had to beat, and a soft speaker,
/// or one sitting back from the microphone, never beat it: synthesised speech
/// scaled to a peak of 0.05 came back as an EMPTY transcript, and the app's own
/// log shows the same session firing `silence warning` sixteen times while
/// nothing was transcribed. Relative to the floor, that same speech is 20 dB
/// above a quiet room and fires at once, while a noisy room raises the bar by
/// itself, with no second setting to keep in sync.
pub const ONSET_SNR: f32 = 12.0;
/// Floor for the continue gate, same role as `ONSET_MEAN_SQUARE`.
pub const CONTINUE_MEAN_SQUARE: f32 = 5e-7;
/// How far above the room's noise a frame must sit to *keep* speech going.
///
/// Lower than `ONSET_SNR` on purpose: that gap is the hysteresis, and it is what
/// stops a soft syllable or a phrase that trails off from being cut out of the
/// utterance that is still being spoken. (An earlier revision lowered the
/// absolute continuation threshold below the onset one and inverted the two --
/// continuation then required MORE energy than onset, which discarded exactly
/// the soft passages this exists to keep. Keep the two ratios ordered.)
pub const CONTINUE_SNR: f32 = 4.0;
/// Consecutive voiced frames required to call something an utterance.
///
/// Replaces a plain count of voiced frames: 6 frames is 180 ms, so a chair
/// creak, a lip smack or a key press cannot satisfy it, while a single short
/// word ("好", "OK", 200-300 ms) can -- and those one-word dictations are
/// exactly what a bare 240 ms total-length rule was throwing away.
///
/// Six, counted properly rather than estimated. A 100 ms burst crosses up to
/// FIVE analysis frames: the frame it starts inside is voiced for the part of
/// the burst that falls in it (a fifth of a frame of a click is already far
/// above the gate), and so is the frame it ends inside. Five therefore accepted
/// the clicks this exists to reject -- which is where the stray "。" in the
/// benchmark's noise case came from. A word has to be sustained for 180 ms.
pub const MIN_VOICED_RUN_FRAMES: usize = 6;
/// Shortest accepted utterance, preroll and tail included. With
/// `MIN_VOICED_RUN_FRAMES` this is what separates a word from a click.
pub const MIN_UTTERANCE_SECONDS: f32 = 0.4;
/// Zero crossings per second above which a frame is noise, not speech.
///
/// A level threshold cannot tell a quiet speaker from noise, and neither can a
/// ratio threshold: the gate is 12x the room's level, so in a file of pure
/// gaussian noise more than half the frames pass it, and the decoder is handed
/// four seconds of hiss and answers with a sentence of its own invention
/// ("我。"). What separates them is the SPECTRUM, and the cheapest measure of it
/// is the zero-crossing rate: a voice is made of low-frequency oscillation and
/// crosses zero a few hundred to a couple of thousand times a second, while
/// broadband hiss crosses it about eight thousand times a second.
///
/// Measured on the benchmark's fifteen spoken clips and its three noise files:
/// the median frame of speech crosses 630-1300 times a second and 76-88% of
/// the frames are below 4000, while every frame of the noise and of the clicks
/// is at 7500-8033. The rule is 4000, which is well clear of the fricatives
/// (an "s" is the loudest crossing in speech and stays below it).
pub const MAX_SPEECH_ZCR: f32 = 4000.0;
/// 540 ms of quiet closes an utterance.
pub const END_SILENCE_FRAMES: usize = 18;

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
    /// Absolute index of the first voiced frame of the utterance being built.
    ///
    /// The onset sits `PREROLL_FRAMES` earlier, in the quiet that led up to it,
    /// and that quiet is not part of the speech: counting it against the
    /// density would reject every short word.
    first_voiced_frame: u64,
    speech_frames: usize,
    silence_frames: usize,
    /// Voiced frames since the last unvoiced one, and the longest such run in
    /// the utterance being built. The run is what tells a word from a click:
    /// total length cannot, because the preroll and tail are counted in it too.
    voiced_run: usize,
    longest_voiced_run: usize,
    /// The energies of the last `NOISE_WINDOW_FRAMES` frames, and whether each
    /// of them was judged to be speech.
    ///
    /// The floor is the LOWEST energy among the frames that were NOT speech, and
    /// the reason for each of those two choices is a failure that was measured:
    ///
    /// * The mean instead of the minimum is dragged up by whatever noise the room
    ///   had in its loudest moments, so the gate ends up above quiet speech.
    /// * Every frame, speech included, is worse: a voice quieter than the gate
    ///   is classified as noise, and every frame of it raises the estimate that
    ///   is keeping it out. After enough dictation the room's "noise" is the
    ///   speaker's voice, and the speaker goes silent.
    /// * Only the frames judged NOT to be speech is right, because the gap
    ///   between two words is quieter than either of them and keeps the floor at
    ///   the room's level while the speaker talks.
    ///
    /// The window is in wall time, so a room that gets louder replaces the old
    /// measurement within three seconds.
    noise_window: [(f32, bool); NOISE_WINDOW_FRAMES],
    /// How many entries of `noise_window` are filled.
    noise_count: usize,
    /// Where the next frame goes in the ring.
    noise_next: usize,
    /// The last floor that could be computed.
    ///
    /// Kept because the window may hold nothing but speech: a person talking
    /// without a pause for three seconds leaves no frame to measure, and the
    /// floor has to stay where it was rather than rise to the speaker's voice.
    floor_value: f32,
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
            first_voiced_frame: 0,
            speech_frames: 0,
            silence_frames: 0,
            voiced_run: 0,
            longest_voiced_run: 0,
            noise_window: [(0.0, false); NOISE_WINDOW_FRAMES],
            noise_count: 0,
            noise_next: 0,
            floor_value: ONSET_MEAN_SQUARE,
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

    /// The room's own level: the quietest frame of the last three seconds that
    /// was not speech.
    ///
    /// When the window holds no such frame -- the speaker has not paused for
    /// three seconds -- the last known floor stands.
    fn noise_floor(&mut self) -> f32 {
        let mut lowest = f32::INFINITY;
        for (energy, voiced) in &self.noise_window[..self.noise_count] {
            if !*voiced {
                lowest = lowest.min(*energy);
            }
        }
        if lowest.is_finite() {
            // A room that is truly silent measures zero, and a gate of zero would
            // call every numerical artefact speech.
            self.floor_value = lowest.max(ONSET_MEAN_SQUARE);
        }
        self.floor_value
    }

    fn onset_threshold(&mut self) -> f32 {
        ONSET_MEAN_SQUARE.max(self.noise_floor() * ONSET_SNR)
    }

    fn continue_threshold(&mut self) -> f32 {
        CONTINUE_MEAN_SQUARE.max(self.noise_floor() * CONTINUE_SNR)
    }

    fn consume_frame(&mut self, frame: &[f32; FRAME], out: &mut Vec<Utterance>) {
        let energy = frame.iter().map(|x| x * x).sum::<f32>() / FRAME as f32;
        // How often the signal crosses zero. A voice crosses a few hundred to a
        // couple of thousand times a second; broadband hiss crosses it about
        // eight thousand times, and a click crosses it on every sample.
        let crossings = frame
            .windows(2)
            .filter(|pair| (pair[0] >= 0.0) != (pair[1] >= 0.0))
            .count();
        let zcr = crossings as f32 * SAMPLE_RATE as f32 / FRAME as f32;
        let speaking = self.speech_frames > 0;
        let voiced = energy >= if speaking { self.continue_threshold() } else { self.onset_threshold() }
            && zcr <= MAX_SPEECH_ZCR;

        if voiced {
            if !speaking {
                let preroll_frames = self.preroll.len() / FRAME;
                self.onset_frame = self.frames_seen - preroll_frames as u64;
                self.audio.clear();
                self.audio.extend_from_slice(&self.preroll);
                self.voiced_run = 0;
                self.longest_voiced_run = 0;
                self.first_voiced_frame = self.frames_seen;
            }
            self.audio.extend_from_slice(frame);
            self.speech_frames += 1;
            self.silence_frames = 0;
            self.voiced_run += 1;
            self.longest_voiced_run = self.longest_voiced_run.max(self.voiced_run);
            self.last_voiced_frame = self.frames_seen;
            if self.audio.len() >= MAX_UTTERANCE_FRAMES * FRAME {
                self.split_at_cap(out);
            }
        } else if speaking {
            self.audio.extend_from_slice(frame);
            self.silence_frames += 1;
            self.voiced_run = 0;
            if self.silence_frames >= END_SILENCE_FRAMES {
                self.close(out);
            }
        } else {
            // Nothing to do here: the frame is recorded below.
        }

        // Every frame goes into the window with the verdict on it. The floor is
        // the quietest frame that was NOT called speech, so the speaker's own
        // voice cannot raise it, and a room that gets louder raises it within
        // one window.
        self.noise_window[self.noise_next] = (energy, voiced);
        self.noise_next = (self.noise_next + 1) % NOISE_WINDOW_FRAMES;
        self.noise_count = self.noise_count.saturating_add(1).min(NOISE_WINDOW_FRAMES);

        // Keep the preroll window filled, after the onset decision has used it.
        self.preroll.extend_from_slice(frame);
        let keep = PREROLL_FRAMES * FRAME;
        if self.preroll.len() > keep {
            let drop = self.preroll.len() - keep;
            self.preroll.drain(..drop);
        }
        self.frames_seen += 1;
    }

    /// Trim the trailing quiet, apply the length rule, and emit.
    ///
    /// The rule is a run of voiced frames plus a total length, not a count of
    /// voiced frames: a click is loud but cannot be sustained, and a one-word
    /// dictation is short but is sustained for longer than a click. Judging on
    /// the total alone is how "好" and "OK" used to disappear -- the preroll and
    /// tail put a click's total at 0.46 s, while a genuinely short word fell
    /// under the voiced-frame count.
    fn close(&mut self, out: &mut Vec<Utterance>) {
        let run_long_enough = self.longest_voiced_run >= MIN_VOICED_RUN_FRAMES;
        let start_frame = self.onset_frame;
        // Keep a short tail of quiet past the last voiced frame.
        let end_frame = (self.last_voiced_frame + 1 + TAIL_FRAMES as u64).min(self.frames_seen);
        let available = (end_frame - start_frame) as usize * FRAME;
        let min_samples = (MIN_UTTERANCE_SECONDS * SAMPLE_RATE as f32) as usize;
        let long_enough = run_long_enough && available >= min_samples;

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
        self.voiced_run = 0;
        self.longest_voiced_run = 0;
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
        self.first_voiced_frame += (cut / FRAME) as u64;
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
        let out = feed(
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

    /// A click that starts inside a frame is voiced for that frame too, and one
    /// that ends inside a frame is voiced for it as well: five frames, not four.
    /// The benchmark's noise case decoded a stray "。" from exactly this.
    #[test]
    fn a_click_straddling_frame_boundaries_is_not_an_utterance() {
        let mut s = Segmenter::new();
        let out = feed(&mut s, &[silence(0.025), tone(0.1, 0.3), silence(1.0)]);
        assert!(out.is_empty(), "a straddling 100 ms click became {out:?}");
    }

    /// Noise lights the gate up in scattered bursts; a voice does not. The
    /// benchmark's noise file decoded a sentence of the decoder's own invention,
    /// and this is what stops it.
    #[test]
    fn scattered_noise_is_not_speech() {
        let mut s = Segmenter::new();
        let mut out = Vec::new();
        // Four seconds of bursts: each 30 ms frame is loud, the frame after it
        // is silent, so the gate is crossed about half the time.
        for _ in 0..130 {
            s.push(&tone(0.03, 0.05), &mut out);
            s.push(&silence(0.03), &mut out);
        }
        s.flush(&mut out);
        assert!(out.is_empty(), "scattered noise became {out:?}");
    }

    /// Broadband hiss crosses zero about eight thousand times a second; a voice
    /// crosses a few hundred times. This is the rule that separates them, and
    /// the level alone cannot: the hiss in the benchmark is loud enough to pass
    /// the gate on every frame.
    #[test]
    fn broadband_hiss_is_not_speech() {
        let mut s = Segmenter::new();
        let mut out = Vec::new();
        // Deterministic pseudo-noise: alternating the sign of a fast sequence
        // crosses zero on every sample, which is the worst case for the rule.
        let hiss: Vec<f32> = (0..SAMPLE_RATE * 2)
            .map(|i| if (i * 2654435761usize) & 1 == 0 { 0.05 } else { -0.05 })
            .collect();
        s.push(&hiss, &mut out);
        s.push(&silence(1.0), &mut out);
        assert!(out.is_empty(), "hiss became {out:?}");
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

    /// The gate is relative to the room, so a quiet speaker is heard.
    ///
    /// This is the user's report as a unit test: at the old absolute -35 dBFS
    /// gate, a voice at this level produced nothing at all -- no utterance, no
    /// text, no error.
    #[test]
    fn a_quiet_room_lets_a_soft_speaker_through() {
        let mut s = Segmenter::new();
        let mut out = Vec::new();
        // A second of near-silence first, so the floor is measured rather than
        // guessed, then a voice 14 dB quieter than the old gate.
        s.push(&vec![0.0; SAMPLE_RATE], &mut out);
        s.push(&tone(0.8, 0.01), &mut out);
        s.push(&silence(1.0), &mut out);
        assert_eq!(out.len(), 1, "soft speech was dropped: {out:?}");
        assert!(out[0].duration() > 0.7, "duration {}", out[0].duration());
    }

    /// A word right after a click: the click is rejected on its own, and the
    /// word that follows is not.
    #[test]
    fn a_short_word_is_an_utterance_but_a_click_is_not() {
        let mut s = Segmenter::new();
        let out = feed(&mut s, &[tone(0.1, 0.3), silence(0.8), tone(0.3, 0.2), silence(1.0)]);
        assert_eq!(out.len(), 1, "expected only the word, got {out:?}");
        // The utterance starts after the click ended (the 360 ms preroll reaches
        // back into the silence before the word, not into the click) and covers
        // the word plus its tail.
        assert!(out[0].start > 0.1, "the utterance still contains the click: {}", out[0].start);
        assert!(out[0].duration() >= 0.6, "duration {}", out[0].duration());
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
