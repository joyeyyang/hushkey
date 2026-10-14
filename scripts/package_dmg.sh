#!/usr/bin/env bash
# Package dist/OfflineVoiceAssistant.app into a DMG and report its size against the 700 MB budget.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/OfflineVoiceAssistant.app"
DMG="$ROOT/dist/OfflineVoiceAssistant.dmg"
[[ -d "$APP" ]] || { echo "run scripts/build_macos.sh first" >&2; exit 1; }
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Offline Voice Assistant" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
bytes=$(stat -f %z "$DMG")
echo "dmg: $DMG  ($((bytes / 1048576)) MiB)"
budget=$((700 * 1048576))
if (( bytes > budget )); then echo "FAIL: over 700 MB budget" >&2; exit 1; fi
echo "within 700 MB budget (models are downloaded on first launch, not included)"
