#!/usr/bin/env bash
# Build the Rust core (release), run core tests, build the SwiftPM app, and assemble
# dist/OfflineVoiceAssistant.app. Models are NOT bundled: the app downloads them on first
# launch using the manifest copied into Contents/Resources.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
SHERPA_DIR="${SHERPA_ONNX_DIR:-$ROOT/rust/core_engine/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared}"
APP="$ROOT/dist/OfflineVoiceAssistant.app"

need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need cargo; need swift; need codesign; need install_name_tool
[[ -d "$SHERPA_DIR/lib" ]] || { echo "sherpa-onnx not found at $SHERPA_DIR (see README)" >&2; exit 1; }

echo "== core engine (release)"
(cd "$ROOT/rust/core_engine" && SHERPA_ONNX_DIR="$SHERPA_DIR" cargo build --release)

# The edit probe is a verification tool, but it has to be built here or
# scripts/verify.sh would run a stale one.
(cd "$ROOT/rust/core_engine" && SHERPA_ONNX_DIR="$SHERPA_DIR" cargo build --release --example edit_batch)

echo "== core tests"
(cd "$ROOT/rust/core_engine" && SHERPA_ONNX_DIR="$SHERPA_DIR" DYLD_LIBRARY_PATH="$SHERPA_DIR/lib" cargo test --release)

echo "== swift app (release)"
(cd "$ROOT/mac/macos_app" && swift build -c release)

echo "== assemble .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$ROOT/mac/macos_app/.build/release/OfflineVoiceAssistant" "$APP/Contents/MacOS/"
cp "$ROOT/mac/macos_app/Resources/Info.plist" "$APP/Contents/"
cp "$ROOT/models/manifest.json" "$APP/Contents/Resources/models-manifest.json"
cp "$ROOT/rust/core_engine/target/release/deps/liboffline_voice_core.dylib" "$APP/Contents/Frameworks/" 2>/dev/null \
  || cp "$ROOT/rust/core_engine/target/release/liboffline_voice_core.dylib" "$APP/Contents/Frameworks/"
cp "$SHERPA_DIR"/lib/libsherpa-onnx-c-api.dylib "$SHERPA_DIR"/lib/libonnxruntime*.dylib "$APP/Contents/Frameworks/"
# LLM worker runs out of process; the core looks for it in Contents/Frameworks (see state.rs).
WORKER="$ROOT/rust/core_engine/target/release/ovc-llm-worker"
[[ -x "$WORKER" ]] || { echo "missing LLM worker at $WORKER (cargo build --release must produce it)" >&2; exit 1; }
cp "$WORKER" "$APP/Contents/Frameworks/ovc-llm-worker"

echo "== relink install names to bundle-relative paths"
BIN="$APP/Contents/MacOS/OfflineVoiceAssistant"
CORE="$APP/Contents/Frameworks/liboffline_voice_core.dylib"
install_name_tool -id "@rpath/liboffline_voice_core.dylib" "$CORE"
# Paths may contain spaces ("open typeless"): extract the whole line, not a word.
old_core="$(otool -L "$BIN" | sed -n 's/^[[:space:]]*\(.*liboffline_voice_core\.dylib\) (.*/\1/p' | head -1)"
[[ -n "$old_core" ]] || { echo "could not locate liboffline_voice_core in $BIN" >&2; exit 1; }
install_name_tool -change "$old_core" "@rpath/liboffline_voice_core.dylib" "$BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
otool -L "$BIN" | grep -q "@rpath/liboffline_voice_core.dylib" || { echo "relink failed" >&2; exit 1; }
install_name_tool -add_rpath "@loader_path" "$CORE" 2>/dev/null || true

# Sign with a stable identity whenever the machine has one. macOS keys the
# Accessibility and Microphone grants to the app's signing identity, so an
# ad-hoc signature -- whose cdhash changes on every rebuild -- silently loses
# the grant: System Settings still shows the switch ON while the running build
# reports "no permission". A real certificate keeps the grant across rebuilds.
# Apple Development is preferred because it also satisfies Gatekeeper locally.
# Override with OVC_SIGN_IDENTITY, or force ad-hoc with OVC_SIGN_IDENTITY=-.
SIGN_ID="${OVC_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
fi

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "== codesign with identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" \
    --entitlements "$ROOT/mac/macos_app/Resources/OfflineVoiceAssistant.entitlements" "$APP"
else
  echo "== codesign (ad-hoc: no signing identity found, so the Accessibility"
  echo "   grant will have to be re-enabled after every rebuild)"
  codesign --force --deep --sign - \
    --entitlements "$ROOT/mac/macos_app/Resources/OfflineVoiceAssistant.entitlements" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "codesign verify: ok"
# LaunchServices caches the bundle it first saw at a given path. When the binary
# behind that path is replaced, System Settings can keep showing the old record --
# a permission switch that is ON but applies to a build that no longer exists.
# Re-registering after signing makes the pane describe the build that is on disk.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" && echo "registered with LaunchServices"
fi
codesign -dv "$APP" 2>&1 | grep -E "^Authority=|^Identifier=" | head -2
echo "built: $APP"
