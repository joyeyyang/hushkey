# Offline AI Voice Assistant (macOS)

Fully offline voice input for macOS: press **Option+Space**, speak, the transcript is pasted into the focused field.

## Status

| Area | Status |
|---|---|
| Rust core: C ABI, error codes, string ownership | Built, unit-tested |
| ASR (SenseVoice Small, via sherpa-onnx) | Full-precision (fp32) model shipped; the loader falls back to `asr/model.int8.onnx` if it is absent. Verified on Mandarin and English samples (transcript matched the int8 build) |
| Memory | LLM runs in a separate per-call worker (`ovc-llm-worker`, ~535 MB peak, returned to the OS on exit). Main-process peak RSS: **~1.12 GB** with the fp32 ASR (vs ~553 MB with int8) — ASR alone. fp32 is kept per request: on the test audio the transcript was identical to int8, so it is a robustness choice, not a measured accuracy win. To halve this, revert the loader/manifest to `asr/model.int8.onnx` |
| LLM worker isolation | Implemented; LLM memory is returned to the OS on each call |
| Smart Chunking (5 min VAD cut, 20-char overlap dedup) | Implemented; cut and dedup unit-tested. Not exercised on a >5 min recording |
| LLM (Qwen2.5-1.5B Q4_K_M) | Wired into `LLM_RefineTextWithKeywords` via llama.cpp, loaded per call. Prompt refined so the output is **easy to read and understand**: fillers are removed and the content is reorganised into short bullet points (`• …`), staying in the transcript's language, never translating. Chinese is forced to **Traditional** deterministically with macOS's ICU Hans→Hant transform (the ASR emits Simplified and the LLM mirrors its input script), so that conversion never depends on the model. A sanity guard (see below) still falls back to the raw transcript if the output shrinks, translates, or drops content |
| RAG (EmbeddingGemma) | **Not available.** Upstream is 1.2 GB unquantized; no verified quantized artifact |
| Taiwanese Hokkien (台語) | **Not supported; accepted by owner.** Official SenseVoice languages: zh, en, ja, ko, yue |
| First-launch model setup | Implemented in app (`ModelInstaller`): manifest bundled, size + SHA-256 verified, atomic move, progress in HUD. No resume (restarts on interruption). Verified: fresh download from an empty directory fetched all models (~1.96 GB with the fp32 ASR + 1.5B LLM), and `verify_models.sh` passes on the result. Cached path also verified |
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
