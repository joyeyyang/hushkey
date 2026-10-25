#!/usr/bin/env python3
"""Character accuracy of the recogniser on synthesised speech, per condition.

Why this exists: "recognition feels worse than the system dictation" is a claim
that has to be turned into numbers before anything can be changed, and the same
five sentences have to be run again after every change. `say` is the source, so
the reference text is known exactly and the run needs no microphone, no
permission and no human.

Conditions:
  loud   as `say` emits it (~-15 dBFS peak): the easy case
  quiet  scaled to a peak of 0.05 (~-26 dBFS): a soft speaker, or one sitting
         back from the microphone. This is the condition that used to come back
         EMPTY, because the voice-activity onset gate sat above it.
  fast   `say -r 230`: clipped consonants and merged syllables
  noise  room tone plus two 100 ms clicks: must yield NOTHING. A recogniser that
         answers here is inventing text.

The references are written in SIMPLIFIED Chinese on purpose: SenseVoice answers
Mandarin in Simplified, and the app converts to Traditional with ICU afterwards
(`VoiceText.toTraditional`), so folding that transform into this metric would
only measure the converter. Script is what SenseVoice emits; content is what this
script scores.

Usage:
  python3 scripts/asr_bench.py [--keep]      # --keep leaves /tmp/ovc-bench in place

Exit status is 0 unless a condition that must be empty produced text.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import statistics
import struct
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "macos_app/.build/release/voiceinput"
MODELS = ROOT / "models"
WORK = Path("/tmp/ovc-bench")

SENTENCES = [
    "明天下午三点跟小林开会，讨论第四季时程，地点还没确定。",
    "这份简报的第二段数字要更新，改成上个月的营收。",
    "请把 subagent 的任务拆小一点，这样比较快。",
    "我下午要去拜访客户，记得带名片跟合约书。",
    "这个功能的 rate limit 是多少？我们要确认一下。",
]

VOICE = "Meijia"
DEFAULT_RATE = None
FAST_RATE = 230
QUIET_PEAK = 0.05
NOISE_MEAN_SQUARE = 2e-5
CLICK_SECONDS = 0.1


def synth(text: str, tag: str, rate: int | None) -> Path:
    aiff, wav = WORK / f"{tag}.aiff", WORK / f"{tag}.wav"
    say = ["say", "-v", VOICE]
    if rate:
        say += ["-r", str(rate)]
    subprocess.run(say + ["-o", str(aiff), text], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
        check=True,
    )
    return wav


def read_samples(path: Path) -> tuple[wave._wave_params, list[int]]:  # type: ignore[attr-defined]
    with wave.open(str(path)) as w:
        return w.getparams(), list(struct.unpack("<%dh" % (w.getnframes()), w.readframes(w.getnframes())))


def write_samples(path: Path, params, samples: list[int]) -> Path:
    with wave.open(str(path), "wb") as w:
        w.setparams(params)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))
    return path


def to_peak(samples: list[int], peak: float) -> list[int]:
    current = max(abs(s) for s in samples) or 1
    gain = peak * 32768 / current
    return [int(max(-32768, min(32767, s * gain))) for s in samples]


def make_noise(seconds: float, rng_seed: int = 7) -> Path:
    import random

    random.seed(rng_seed)
    params = wave._wave_params(  # type: ignore[attr-defined]
        nchannels=1, sampwidth=2, framerate=16000, nframes=0, comptype="NONE", compname="not compressed"
    )
    amplitude = (NOISE_MEAN_SQUARE**0.5) * 32768
    count = int(seconds * 16000)
    samples = [int(random.gauss(0, amplitude)) for _ in range(count)]
    # Two clicks in the middle of the silence: short bursts that the segmenter's
    # minimum-length rule is supposed to reject.
    for start in (count // 3, 2 * count // 3):
        for i in range(int(CLICK_SECONDS * 16000)):
            samples[start + i] = int(0.25 * 32768) * (1 if i % 2 else -1)
    return write_samples(WORK / "noise.wav", params, samples)


def transcribe(wav: Path, language: str | None = None) -> str:
    env = dict(os.environ, OVC_MODELS=str(MODELS))
    if language:
        env["OVC_ASR_LANGUAGE"] = language
    result = subprocess.run(
        [str(CLI), "--transcribe", str(wav), "--raw"], env=env, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(f"voiceinput failed on {wav}: {result.stderr.strip()}")
    return result.stdout.strip()


PUNCTUATION = re.compile(r"[\s，。？、,.:：!！?；;]")


def accuracy(reference: str, hypothesis: str) -> float:
    return difflib.SequenceMatcher(None, PUNCTUATION.sub("", reference), PUNCTUATION.sub("", hypothesis)).ratio()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="leave the generated WAVs in /tmp/ovc-bench")
    parser.add_argument("--language", default=None, help="pass OVC_ASR_LANGUAGE (default: the engine's own)")
    args = parser.parse_args()

    if not CLI.exists():
        raise SystemExit(f"{CLI} is missing; run scripts/build_macos.sh first")
    WORK.mkdir(exist_ok=True)

    clips: dict[tuple[int, str], Path] = {}
    for index, sentence in enumerate(SENTENCES):
        loud = synth(sentence, f"b{index}", DEFAULT_RATE)
        params, samples = read_samples(loud)
        clips[(index, "loud")] = loud
        clips[(index, "quiet")] = write_samples(WORK / f"b{index}q.wav", params, to_peak(samples, QUIET_PEAK))
        clips[(index, "fast")] = synth(sentence, f"b{index}f", FAST_RATE)

    scores: dict[str, list[float]] = {"loud": [], "quiet": [], "fast": []}
    for (index, condition), wav in sorted(clips.items()):
        hypothesis = transcribe(wav, args.language)
        score = accuracy(SENTENCES[index], hypothesis)
        scores[condition].append(score)
        print(f"s{index} {condition:5s} {score:5.3f}  {hypothesis}")

    print()
    for condition in ("loud", "quiet", "fast"):
        per = scores[condition]
        dropped = sum(1 for s in per if s == 0.0)
        print(
            f"{condition:5s} mean {statistics.mean(per):.3f}  min {min(per):.3f}  "
            f"empty {dropped}/{len(per)}  per-sentence {[round(s, 2) for s in per]}"
        )

    noise = transcribe(make_noise(4.0), args.language)
    print(f"\nnoise (must be empty): {noise!r}")

    if not args.keep:
        for wav in list(clips.values()) + [WORK / "noise.wav"]:
            wav.with_suffix(".aiff").unlink(missing_ok=True)
    return 1 if noise else 0


if __name__ == "__main__":
    sys.exit(main())
