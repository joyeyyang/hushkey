#!/usr/bin/env bash
# Build Rust core (release) and the SwiftPM app, then assemble OfflineVoiceAssistant.app.
# Models are NOT bundled: they download on first launch (see download_models.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
SHERPA_DIR="${SHERPA_ONNX_DIR:-$ROOT/core_engine/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared}"
APP="$ROOT/dist/OfflineVoiceAssistant.app"

need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need cargo; need swift; need codesign
[[ -d "$SHERPA_DIR/lib" ]] || { echo "sherpa-onnx not found at $SHERPA_DIR (see docs/BUILD.md)" >&2; exit 1; }

echo "== core engine (release)"
(cd "$ROOT/core_engine" && SHERPA_ONNX_DIR="$SHERPA_DIR" cargo build --release)

echo "== core tests"
(cd "$ROOT/core_engine" && SHERPA_ONNX_DIR="$SHERPA_DIR" cargo test --release)

echo "== swift app (release)"
(cd "$ROOT/macos_app" && swift build -c release)

echo "== assemble .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$ROOT/macos_app/.build/release/OfflineVoiceAssistant" "$APP/Contents/MacOS/"
cp "$ROOT/macos_app/Resources/Info.plist" "$APP/Contents/"
cp "$ROOT/core_engine/target/release/deps/liboffline_voice_core.dylib" "$APP/Contents/Frameworks/" 2>/dev/null \
  || cp "$ROOT/core_engine/target/release/liboffline_voice_core.dylib" "$APP/Contents/Frameworks/"
cp "$SHERPA_DIR"/lib/libsherpa-onnx-c-api.dylib "$SHERPA_DIR"/lib/libonnxruntime*.dylib "$APP/Contents/Frameworks/"

echo "== relink install names to bundle-relative paths"
BIN="$APP/Contents/MacOS/OfflineVoiceAssistant"
CORE="$APP/Contents/Frameworks/liboffline_voice_core.dylib"
install_name_tool -id "@rpath/liboffline_voice_core.dylib" "$CORE"
# Path may contain spaces ("open typeless"), so extract the whole line, not a word.
old_core="$(otool -L "$BIN" | sed -n 's/^[[:space:]]*\(.*liboffline_voice_core\.dylib\) (.*/\1/p' | head -1)"
[[ -n "$old_core" ]] || { echo "could not locate liboffline_voice_core in $BIN" >&2; exit 1; }
install_name_tool -change "$old_core" "@rpath/liboffline_voice_core.dylib" "$BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
otool -L "$BIN" | grep -q "@rpath/liboffline_voice_core.dylib" || { echo "relink failed" >&2; exit 1; }
install_name_tool -add_rpath "@loader_path" "$CORE" 2>/dev/null || true
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  for dep in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
    install_name_tool -change "@rpath/$dep" "@rpath/$dep" "$lib" 2>/dev/null || true
  done
done

echo "== codesign (ad-hoc; Developer ID signing and notarization are NOT performed here)"
codesign --force --deep --sign - --entitlements "$ROOT/macos_app/Resources/OfflineVoiceAssistant.entitlements" "$APP"
codesign --verify --deep --strict "$APP" && echo "codesign verify: ok"
echo "built: $APP"
