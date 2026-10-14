# Offline AI Voice Assistant (macOS)

Fully offline voice input for macOS: press **Option+Space**, speak, the transcript is pasted into the focused field.

## Status

| Area | Status |
|---|---|
| Rust core: C ABI, error codes, string ownership | Built, unit-tested |
| ASR (SenseVoice Small int8, via sherpa-onnx) | Verified on one Mandarin sample; model load 1.4 s, 5.6 s audio decoded in 165 ms |
| Memory | Target 550 MB peak RSS. **Not met:** ASR + LLM in one process measured 670–920 MB peak (`ru_maxrss`, not reproducible across runs). ASR alone ~400–560 MB. Pending owner decision (split processes / smaller quant / accept ~900 MB) |
| Smart Chunking (5 min VAD cut, 20-char overlap dedup) | Implemented; cut and dedup unit-tested. Not exercised on a >5 min recording |
| LLM (Qwen2.5-0.5B Q4_K_M) | Wired into `LLM_RefineText` via llama.cpp, loaded per call. Refines a sample transcript correctly (removed filler, added punctuation). ~1 s warm, ~45 s on first call in one run (cold Metal shader compile) |
| RAG (EmbeddingGemma) | **Not available.** Upstream is 1.2 GB unquantized; no verified quantized artifact |
| Taiwanese Hokkien (台語) | **Not supported; accepted by owner.** Official SenseVoice languages: zh, en, ja, ko, yue |
| First-launch model setup | Implemented in app (`ModelInstaller`): manifest bundled, size + SHA-256 verified, atomic move, progress in HUD. No resume (restarts on interruption). Verified: fresh download from an empty directory fetched all three models (~730 MB), and `verify_models.sh` passes on the result. Cached path also verified |
| macOS hotkey / HUD / mic / text injection | Compiled and launched from the `.app`. **Not verified end-to-end** (needs GUI session and granted permissions) |
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

Privacy: audio and transcripts stay on this Mac. Recording-state indicator and data deletion UI are **not implemented**.
