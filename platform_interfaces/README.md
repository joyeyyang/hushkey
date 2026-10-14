# Mobile porting notes (design only, not implemented or tested)

The core exposes a plain C ABI (`core_engine/include/offline_voice_core.h`), so iOS and Android can link the same Rust library.

## iOS
- Build `offline_voice_core` as a static lib for `aarch64-apple-ios`; link sherpa-onnx's iOS xcframework.
- SwiftUI app plus Keyboard Extension. Keyboard extensions have tight memory limits; the 500+ MB peak measured on macOS likely exceeds them. Needs measurement on device before committing to this design.
- Microphone access from a keyboard extension is restricted; recording would have to happen in the containing app.

## Android
- Build for `aarch64-linux-android` with the NDK; call the C ABI through JNI.
- Implement InputMethodService for text entry. Foreground service required for long recordings.

Open items: model size for mobile, on-device latency, background execution limits, and the Taiwanese Hokkien gap all need real-device measurement.
