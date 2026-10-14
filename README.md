# Offline AI Voice Assistant (macOS)

Fully offline voice input for macOS: press **Option+Space**, speak, the transcript is pasted into the focused field.

## Status

| Area | Status |
|---|---|
| Rust core: C ABI, error codes, string ownership | Built, unit-tested |
| ASR (SenseVoice Small int8, via sherpa-onnx) | Verified on one Mandarin sample; model load 1.4 s, 5.6 s audio decoded in 165 ms |
| Memory | **Not met.** Peak RSS ~520 MB on load + decode (target < 450 MB). Measured, not optimized |
| Smart Chunking (5 min VAD cut, 20-char overlap dedup) | Implemented; cut and dedup unit-tested. Not exercised on a >5 min recording |
| LLM (Qwen2.5-0.5B Q4_K_M) | Downloaded and hash-verified; **not wired into the core** (`LLM_*` return NOT_IMPLEMENTED) |
| RAG (EmbeddingGemma) | **Not available.** Upstream is 1.2 GB unquantized; no verified quantized artifact |
| Taiwanese Hokkien (台語) | **Not supported by the chosen ASR model.** Official SenseVoice languages: zh, en, ja, ko, yue |
| macOS hotkey / HUD / mic / text injection | Compiled and launched from the `.app`. **Not verified end-to-end** (needs GUI session and granted permissions) |
| Packaging | `.app` and `.dmg` built; DMG 10 MiB (models downloaded on first launch) |
| Signing / notarization | **Not done.** Ad-hoc signature only |
| iOS / Android | Design notes only; not implemented |

## Build

Requires macOS 13+, Xcode 26, Rust, and the sherpa-onnx macOS arm64 shared library
(extract `sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2` into `core_engine/vendor/`).

```sh
scripts/download_models.sh   # ~730 MB; resumable; SHA-256 verified
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
