#!/usr/bin/env bash
# Package dist/OfflineVoiceAssistant.app into a DMG and report its size against the 700 MB budget.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/OfflineVoiceAssistant.app"
DMG="$ROOT/dist/OfflineVoiceAssistant.dmg"
[[ -d "$APP" ]] || { echo "run scripts/build_macos.sh first" >&2; exit 1; }

# Guard against an ad-hoc build. Its designated requirement is a bare cdhash, so
# every rebuild invalidates the macOS permissions the user already granted (the
# Accessibility grant then looks enabled in System Settings but never matches).
DR="$(codesign -d -r- "$APP" 2>&1 || true)"
if grep -q 'cdhash' <<<"$DR"; then
  echo "FAIL: app is ad-hoc signed; its DR is a cdhash and permissions break on every rebuild." >&2
  exit 1
fi
SIG="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
if ! grep -q 'Authority=Apple Development' <<<"$SIG"; then
  echo "FAIL: expected an Apple Development signature." >&2
  exit 1
fi
if ! grep -q 'TeamIdentifier=7S48J3H2N2' <<<"$SIG"; then
  echo "FAIL: unexpected TeamIdentifier." >&2
  exit 1
fi

# Best effort: warn when the stored Accessibility grant is a stale cdhash-only
# record left over from an ad-hoc build. The system TCC database is normally
# root-only, in which case this check is skipped.
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
if [[ -r "$TCC_DB" ]]; then
  REQ="$(sqlite3 "$TCC_DB" \
    "select hex(csreq) from access where service='kTCCServiceAccessibility' and client='com.example.offlinevoiceassistant';" \
    2>/dev/null | head -1 || true)"
  if [[ -n "${REQ:-}" && ${#REQ} -lt 200 ]]; then
    echo "WARN: the Accessibility grant is a stale cdhash-only record (${#REQ} hex chars)." >&2
    echo "      Remove and re-add the app in System Settings > Privacy & Security > Accessibility." >&2
  fi
fi

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
