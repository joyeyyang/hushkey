#!/bin/bash
# Builds the iOS core static libraries and the Xcode project.
#
# Two things are unusual here and both are load-bearing:
#  * sherpa-onnx and onnxruntime ship for iOS as STATIC archives, so the search
#    path must hold only .a files -- a .dylib beside them wins the -l lookup and
#    the app then fails to launch with nothing in the log.
#  * keyboard extensions get tens of megabytes, so the recogniser lives in the
#    app; the extension only inserts what the App Group holds.
set -euo pipefail
cd "$(dirname "$0")/.."

SHERPA_IOS="core_engine/vendor/ios"
if [ ! -d "$SHERPA_IOS/build-ios-no-tts" ]; then
    echo "missing $SHERPA_IOS -- extract sherpa-onnx-v1.13.4-ios-no-tts.tar.bz2 there"
    exit 1
fi

for slice in sim device; do
    mkdir -p "ios_app/vendor/$slice"
done
cp -f "$SHERPA_IOS/sim/lib/"*.a ios_app/vendor/sim/ 2>/dev/null || true
cp -f "$SHERPA_IOS/device/lib/"*.a ios_app/vendor/device/ 2>/dev/null || true

# IPHONEOS_DEPLOYMENT_TARGET is load-bearing, not decoration: clang bakes the
# minimum OS into every object file it produces, and the app links at 17.0. Built
# without it, the core's objects said 26.5 (the SDK's default) and every link
# printed "was built for newer 'iOS' version (26.5) than being linked (17.0)"
# hundreds of times -- one per object in the archive. The cc and cmake crates
# both read this variable, so it covers the shim and llama.cpp in one place.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

SHERPA_ONNX_DIR="$PWD/$SHERPA_IOS/sim" \
    cargo build --manifest-path core_engine/Cargo.toml --target aarch64-apple-ios-sim --release
SHERPA_ONNX_DIR="$PWD/$SHERPA_IOS/device" \
    cargo build --manifest-path core_engine/Cargo.toml --target aarch64-apple-ios --release

cp -f core_engine/target/aarch64-apple-ios-sim/release/liboffline_voice_core.a ios_app/vendor/sim/
cp -f core_engine/target/aarch64-apple-ios/release/liboffline_voice_core.a ios_app/vendor/device/

cd ios_app
xcodegen generate
xcodebuild -project OfflineVoiceAssistant.xcodeproj -scheme OfflineVoiceAssistant \
    -sdk iphonesimulator -configuration Debug -derivedDataPath build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY="-" build
