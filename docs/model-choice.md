# Hushkey（HSK）：which model, and what the A/B actually showed

The app's default LLM changed from Qwen2.5-1.5B to Qwen3.5-2B, but the prompts
were tuned against the older model, and every quality claim in the README was
measured on it. This records the re-measurement, including the parts that got
worse.

Everything below is a recorded run, not an impression. The harness lives in
`rust/core_engine/tests/transcripts/` (ten fixed transcripts: Chinese and English
meetings, an assignments-only meeting, a decisions-only meeting, a chat, two
novel-style narrations) and runs through `scripts/ab_models.sh`.

## Two harnesses, because they answer different questions

| Script | Runs | Answers |
|---|---|---|
| `scripts/ab_models.sh [q35\|both]` | the whole summary pipeline (摘要 + 決議 + 待辦, three model calls) | "what does the app actually produce?" |
| `SECTION=actions scripts/section_ab.sh` | one section's prompt, one model, no post-filters | "is this the prompt, the model, or the filter?" |

Both are serial on purpose: 8 GB of RAM, and two llama workers at once land in
swap.

## Cost

Whole pipeline, one transcript = three calls, model loaded per call (in-process
harness, so peak RSS is the parent's):

| Model | Peak RSS | Time per transcript |
|---|---|---|
| Qwen3.5-2B Q4_K_M (1.28 GB file) | 1,415–1,528 MB | 16–34 s |
| Qwen2.5-1.5B Q4_K_M (0.90 GB file) | 1,245–1,268 MB | 12–28 s |

In the app the model runs in a per-call worker (`ovc-llm-worker`), so this memory
is released between calls instead of being held for the session.

## What the re-measurement fixed

**1. An English meeting's 決議 came back in Simplified Chinese.**

```
## 摘要
The team decided to ship the new homepage next Wednesday ...      ← English, correct
## 決議
会议决定将新首页于下周三发布，其余页面稍后发布，并将广告预算削减百分之三十。   ← Chinese
```

The English 決議 prompt had no worked examples, and the only non-English text in
it was the "nothing here" marker at the end (`无`). Qwen3.5-2B latched onto that
one character and answered in Chinese. Adding English example pairs fixed the
language but made the model enumerate the meeting's assignments under 決議
(measured twice, matching the older note on the 1.5B). The fix that holds is the
marker: `none` for the English instruction, `无` for the Chinese one, so the
English prompt contains no Chinese characters at all. `parse_no_decision`
accepts both.

**2. `<think>` blocks no longer leak.** The engine prefills the model's own empty
think block and strips any reasoning that survives; `grep -l think` over all
twenty outputs finds nothing.

**3. An assignments-only meeting stopped producing a 決議.** It produced
`美玲下週安排時間校對官網文案` — an assignment, kept because `安排` was not among
the task cues and `下週` without `以前`/`之前` is not a deadline. `安排` is now a
task cue, which only ever applies to a clause that already names an owner from
the action list.

**4. Decisions no longer end in a stray `、`.** The 決議 joiner respects clause
separators; a dropped assignment used to leave the punctuation behind.

## What the re-measurement did not fix — 待辦 attribution

This is the part that got worse with the newer model, and it is the part the
app's hard requirement is about ("不遺漏、可追蹤", "負責人不可編造").

Same transcript, same pipeline, post-filters included:

| Case | Qwen2.5-1.5B | Qwen3.5-2B |
|---|---|---|
| t1 中文 | `我：下週一以前把合約草稿送給法務` | `下週一以前把合約草稿送**給我**` — owner dropped **and** the recipient flipped |
| t2 英文 | `I: get the contract draft to legal by Monday` | `get the contract draft to legal by Monday` — owner dropped |
| t10 英文 | `I: handle the quarterly stock count myself` | `Priya: handle the quarterly stock count` — **wrong owner, and it survives every filter** |
| t9 中文敘述體 | `阿珍：負責聯絡廠商問堆高機的交期` | `這禮拜畫出新動線圖` — owner dropped |

The section-level run shows the mechanism: given the same four worked examples,
Qwen3.5-2B copies a name out of an example (`小華` appears in the 待辦 answer of
a transcript that never mentions him) and turns decisions into tasks
(`Priya: move the packing tables`). A fifth example teaching third-person
narration fixed the dropped owner but produced `大家：把出貨區改到後面那棟` —
an owner invented for a group that was never assigned anything, which breaks the
same rule from the other side. That example was reverted.

The app already drops an owner that appears nowhere in the transcript
(`strip_invented_owners`), which is why the full-pipeline output does not contain
`小華`. What it cannot catch is a *mis*-attribution to a real participant —
`Priya: handle the quarterly stock count` — because nothing in the text says the
attribution is wrong.

Qwen2.5-1.5B has its own failure on the same section: it writes topic-as-owner
lines (`上線時間：大家討論後決定…`) and, on the chitchat transcript, answers with
a question (`- 今天中午吃什麼？`). Its owners, though, are the ones the transcript
named.

## Recommendation, stated plainly

- **決議 (decisions)** is cleaner on Qwen3.5-2B: it drops assignment clauses
  instead of restating them.
- **待辦 (actions)** is materially more faithful on Qwen2.5-1.5B: owners are
  kept, and it does not mis-attribute work to a real participant.

The default stays Qwen3.5-2B (chosen deliberately), but a meeting's 待辦 list is
where traceability lives, so the trade is worth knowing: switching the model in
設定 → 模型 to Qwen2.5-1.5B trades tidier decisions for a 待辦 list whose owners
match what was said. Both models stay installed; nothing is removed.

## How to re-run

```bash
# whole pipeline, both models, ~10 min serial
bash scripts/ab_models.sh

# one section only, e.g. the action list
cd core_engine
SHERPA_ONNX_DIR="$PWD/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared" \
  cargo build --release --example section_probe
cd .. && SECTION=actions bash scripts/section_ab.sh
```

`ab_models.sh` writes `rust/core_engine/target/ab/<tag>_<case>.out` and `.time`;
`section_ab.sh` writes `rust/core_engine/target/section_ab/`. A prompt change that
touches one section only needs that section's run.

---

# ASR: why Dolphin base int8 replaced SenseVoice Small

Same clip, same machine, same 4 threads, greedy decoding. The probe is a
throwaway C program that links the vendored sherpa-onnx the app ships with, so
these numbers come from the same runtime the app uses.

Test audio: `test_wavs/0.wav` from the Dolphin release (5.61 s, 16 kHz mono).

| | SenseVoice Small int8 | Dolphin base int8 |
|---|---|---|
| Weights on disk | 228 MB (`model.int8.onnx`) | **99 MB** (`model.int8.onnx`) |
| Load time | 2.230 s | **0.330 s** |
| Decode (5.61 s audio) | 0.190 s | **0.141 s** |
| RTF | 0.034 | **0.025** |
| Peak RSS | 452 MB | **299 MB** |
| Languages | zh, en, ja, ko, yue | **40 Eastern languages + 22 Chinese dialects** |
| 台語 (Minnan) | no | **yes (`zh-MINNAN`)** |
| Punctuation | commas throughout | sentence-final only |

Transcripts on that clip:

```
sense  : 对我做了介绍啊，那么我想说的是呢，大家如果对我的研究感兴趣呢嗯。
dolphin: 对我做了介绍哈那么我想说的是呢大家如果对我的研究感兴趣呢。
```

Both are correct. Dolphin differs in two ways worth knowing:

1. **Sparser punctuation.** It emits a final `。` but not the mid-sentence
   commas SenseVoice inserts. The LLM polish step restores readable punctuation
   for dictation; the live transcript window shows the raw text and will look
   flatter.
2. **Filler handling.** It kept `哈` where SenseVoice wrote `啊`, and dropped a
   trailing `嗯`. Fillers are removed by the polish step either way.

What decided it: 41% of the memory, 25% faster decode, 7× faster load, and a
language list that includes the one thing SenseVoice could not do. The cost is a
smaller model (0.1 B vs 0.23 B), so Mandarin accuracy was the risk -- on this
clip it matched. **This is one clip, not a corpus.** The A/B scripts in
`scripts/` cover the summary pipeline, not ASR; a wider ASR comparison still has
to be done on real user recordings.

Rechecking which file actually loaded (the manifest and the log can both be
stale, the model_bytes cannot):

```
cd core_engine
SHERPA_ONNX_DIR=$PWD/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared \
  cargo run --release --example asr_probe
# loaded: model_bytes=104234464 peak_rss=264978432 -> dolphin
```

SenseVoice is still installed and still selected automatically when
`asr/dolphin/` is missing, so upgrading an existing install never leaves the app
without an ASR model.

## End-to-end check (engine, not just the model file)

`asr_probe` proves which file the engine opened; it does not prove dictation
works. `scripts/probe_transcribe.c` drives the shipped dylib through the same C
ABI the app uses — `Core_Initialize` → `Agent_Load("asr")` → `ASR_Start` →
`ASR_SubmitAudio` → `ASR_Stop` — so the text below came out of the product code
path, after its own cleanup:

```
clang -O2 scripts/probe_transcribe.c -o /tmp/probe_transcribe \
  -L rust/core_engine/target/release -loffline_voice_core \
  -Wl,-rpath,$PWD/rust/core_engine/target/release
DYLD_LIBRARY_PATH=rust/core_engine/target/release /tmp/probe_transcribe \
  <clip>.wav "$HOME/Library/Application Support/OfflineVoiceAssistant/models"
```

```
wav: 0.wav (5.612s, 16000 Hz)
load=0.001s asr=0.145s rtf=0.026
model_bytes=104234464 peak_rss=298 MB
text: 对我做了介绍哈那么我想说的是呢大家如果对我的研究感兴趣呢
```

`model_bytes=104234464` is the Dolphin pair (103,729,802 + 504,662) — the loader
picked it, not SenseVoice. Note the result has no trailing `。`: the engine's
cleanup drops sentence-final punctuation and the polish step puts punctuation
back where it belongs, which is why the raw transcript window looks flatter than
the pasted text.
