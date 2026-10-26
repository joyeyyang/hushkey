# Offline AI Voice Assistant (macOS)

Fully offline voice input for macOS: press **Option+Space**, speak, the transcript is pasted into the focused field.

**`docs/PROJECT.md`** is the full picture — architecture, the C ABI, the design decisions and their measurements, and what is not done yet. The table below is the short version.

## Status

| Area | Status |
|---|---|
| Rust core: C ABI, error codes, string ownership | Built, unit-tested |
| ASR (Dolphin base int8, via sherpa-onnx) | **Default since 2026-10-25.** `asr/dolphin/model.int8.onnx` (99 MB, 104 MB with tokens) — 40 Eastern languages and 22 Chinese dialects including **Minnan**. Measured on the same 5.6 s clip: **0.141 s decode (RTF 0.025), 299 MB peak RSS**, against SenseVoice int8's 0.190 s and 452 MB. CTC, so it is still non-autoregressive. SenseVoice int8 (228 MB) stays as the fallback when `asr/dolphin/` is absent |
| Memory | ASR: **299 MB peak RSS measured** for Dolphin base int8 (SenseVoice int8 was 452 MB, fp32 ~1.12 GB). The LLM runs in a separate per-call worker (`ovc-llm-worker`), so its memory is returned to the OS between calls. Measured on the summary harness, which loads the GGUF in-process: **1,415–1,528 MB peak with Qwen3.5-2B** vs **1,245–1,268 MB with Qwen2.5-1.5B**, 16–34 s vs 12–28 s per transcript (three section calls). See `docs/model-choice.md` for the full A/B |
| LLM worker isolation | Implemented; LLM memory is returned to the OS on each call |
| Smart Chunking (5 min VAD cut, 20-char overlap dedup) | Implemented; cut and dedup unit-tested. Not exercised on a >5 min recording |
| LLM (Qwen3.5-2B Q4_K_M by default) | Wired into `LLM_RefineTextWithKeywords` via llama.cpp, loaded per call. `OVC_LLM_MODEL` overrides the file (filename only, joined onto `<models>/llm`); when it names a file that is not installed the engine falls back to `qwen2.5-1.5b-instruct-q4_k_m.gguf`, so an old install keeps working. Qwen3.5-2B thinks by default, which leaked `<think>` blocks into the answer: the engine now prefills the exact empty think block from the model's own template and strips any reasoning that survives. A test asserts the prefill is byte-identical to what the GGUF template renders, so a template change breaks the test instead of the output. Prompt refined so the output is **easy to read and understand**: fillers are removed and the content is reorganised into short bullet points (`• …`), staying in the transcript's language, never translating. Chinese is forced to **Traditional** deterministically with macOS's ICU Hans→Hant transform (the ASR emits Simplified and the LLM mirrors its input script), so that conversion never depends on the model. A sanity guard (see below) still falls back to the raw transcript if the output shrinks, translates, or drops content |
| RAG (EmbeddingGemma) | **Not available.** Upstream is 1.2 GB unquantized; no verified quantized artifact |
| Taiwanese Hokkien (台語) | **Attempted now, not yet verified by ear.** Dolphin base lists `zh-MINNAN` and `zh-TW` among its 22 Chinese dialects (SenseVoice could not do this at all). Whether 台灣腔 台語 transcribes usefully has to be judged on real recordings; the model card's "Minnan" is a broader label than one accent |
| First-launch model setup | Implemented in app (`ModelInstaller`): manifest bundled, size + SHA-256 verified, atomic move, progress in HUD. No resume (restarts on interruption). Verified: a fresh download from an empty directory fetched all three `download:true` entries (int8 ASR + tokens + Qwen3.5-2B, 1,520,385,575 bytes ≈ 1.52 GB), and `verify_models.sh` passes on the result. Cached path also verified |
| App → LLM refinement | **Wired.** `deliver()` runs `LLM_RefineTextWithKeywords` (with user keywords) off the main thread, then a **sanity guard** (`plausible`) rejects output that shrinks, translates, or drops most of the transcript's Chinese characters, falling back to the raw transcript |
| App interface | A persistent **main window** with tabs (轉錄 / 關鍵字 / 設定) replaces the old transient popover, so it does not close on its own. Left-click the menu-bar icon reopens it; right-click gives Open / Quit; 設定 also has a Quit button. If Accessibility is not granted, the 轉錄 tab shows a red banner with a button that opens the right System Settings pane |
| Configurable hotkey / theme / polish | Hotkey rebinds at runtime (`Option+Space` default); appearance persists across launches; an "AI 整理" toggle switches the LLM step on/off (default on) |
| Dictation HUD | By default the polished text is **pasted automatically** into the focused field (Typeless-style), with a short "已貼上" confirmation. Enable "貼上前先顯示文字讓我確認" in 設定 to instead review it in an editable HUD and press **Enter** to insert / **Escape** to cancel. Without Accessibility permission the text is left on the clipboard and the HUD says so |
| Meeting mode | Records, then writes `meeting-<timestamp>.txt` to the meetings folder plus a best-effort `摘要/決策/待辦` `.md` summary |
| macOS hotkey / HUD / mic / text injection | Compiled and launched from the `.app`; ASR→deliver path exercised via the `OVC_SELFTEST_WAV` env var on synthesized Mandarin and English WAVs (both decoded correctly). Mic/Accessibility flows **not verified end-to-end** (need a GUI session and granted permissions) |
| Packaging | `.app` and `.dmg` built; DMG 12 MiB (models downloaded on first launch) |
| Signing / notarization | **Not done.** Ad-hoc signature only |
| iOS / Android | Design notes only; not implemented |

## Build

Requires macOS 13+, Xcode 26, Rust, and the sherpa-onnx macOS arm64 shared library
(extract `sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2` into `core_engine/vendor/`).

```sh
scripts/download_models.sh   # optional for developers; the app downloads on first launch
scripts/verify_models.sh
scripts/build_macos.sh       # cargo test + swift build + .app + ad-hoc codesign
scripts/verify.sh            # every check that needs no human judgement
scripts/package_dmg.sh       # dist/OfflineVoiceAssistant.dmg
```

## Permissions

- **Microphone:** prompted on first use (`NSMicrophoneUsageDescription`).
- **Accessibility:** required for automatic paste (Cmd+V via CGEvent). Without it the
  transcript is left on the clipboard and the HUD says so. Grant it in
  System Settings > Privacy & Security > Accessibility. Adding a key to Info.plist does not grant it.

## Layout

- `core_engine/` Rust core, C header in `include/offline_voice_core.h`
- `macos_app/` SwiftPM app (hotkey, HUD, capture, injection)
- `models/manifest.json` model sources, sizes, SHA-256, licenses
- `scripts/` download, verify, build, package
- `platform_interfaces/` iOS/Android notes

Privacy: audio and transcripts stay on this Mac. A recording-state indicator (red menu-bar glyph
while capturing) is implemented; the data-deletion UI is **not implemented**.
