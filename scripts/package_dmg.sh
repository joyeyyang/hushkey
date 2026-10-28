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
# The identity is reported, never enforced. The cdhash guard above is the one that
# protects the user's grants, and a Developer ID Application signature -- the
# identity a build for distribution actually carries -- has a real designated
# requirement too. Demanding "Apple Development" here made the normal release path
# exit 1, so the check only says which identity it found and which one shipping
# needs.
if grep -q 'Authority=Apple Development' <<<"$SIG"; then
  echo "WARN: signed with Apple Development, which only runs on machines holding that" >&2
  echo "      provisioning profile; a build for distribution must use Developer ID Application." >&2
elif ! grep -q 'Authority=Developer ID Application' <<<"$SIG"; then
  echo "WARN: signature carries neither Apple Development nor Developer ID Application;" >&2
  echo "      distribution expects Developer ID Application." >&2
fi
# Which team signed it is a warning too, and not a hard-coded equality: a fork or a
# CI runner under another team still produces a valid DR, it is just not the team
# the existing grants were made against. OVC_TEAM_ID overrides the project default.
EXPECTED_TEAM="${OVC_TEAM_ID:-7S48J3H2N2}"
TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIG" | head -1)"
if [[ -z "$TEAM" ]]; then
  echo "WARN: signature carries no TeamIdentifier; distribution expects one (Developer ID Application)." >&2
elif [[ "$TEAM" != "$EXPECTED_TEAM" ]]; then
  echo "WARN: TeamIdentifier=$TEAM, expected $EXPECTED_TEAM (override with OVC_TEAM_ID)." >&2
fi

# Best effort: warn when the stored Accessibility grant is a stale cdhash-only
# record left over from an ad-hoc build. Two databases hold grants, and the one
# that matters depends on the app: a grant made to a user-level app lives in the
# per-user database under $HOME, while /Library holds the system-wide ones. On a
# stock machine the system database is protected by SIP/TCC and not readable
# without Full Disk Access, which is why the readable one is skipped silently
# instead of reported as "no grant".
BUNDLE_ID="com.example.offlinevoiceassistant"
for TCC_DB in \
  "/Library/Application Support/com.apple.TCC/TCC.db" \
  "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  [[ -r "$TCC_DB" ]] || continue
  REQ="$(sqlite3 "$TCC_DB" \
    "select hex(csreq) from access where service='kTCCServiceAccessibility' and client='$BUNDLE_ID';" \
    2>/dev/null | head -1 || true)"
  if [[ -n "${REQ:-}" && ${#REQ} -lt 200 ]]; then
    echo "WARN: the Accessibility grant in $TCC_DB is a stale cdhash-only record (${#REQ} hex chars)." >&2
    echo "      Remove and re-add the app in System Settings > Privacy & Security > Accessibility." >&2
  fi
done

rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hushkey" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
bytes=$(stat -f %z "$DMG")
echo "dmg: $DMG  ($((bytes / 1048576)) MiB)"
budget=$((700 * 1048576))
if (( bytes > budget )); then echo "FAIL: over 700 MB budget" >&2; exit 1; fi
echo "within 700 MB budget (models are downloaded on first launch, not included)"
