#!/bin/bash
# Runs the Accessibility check against the INSTALLED app.
#
# The check needs the installed app, not the build tree: Accessibility
# permission is granted to a bundle id with a signature, and the installed
# app is the one that has it. It also needs a window server, so it cannot run
# over SSH.
#
# Usage: scripts/ax_check.sh [app-path]
set -uo pipefail

APP="${1:-/Applications/OfflineVoiceAssistant.app}"
BIN="$APP/Contents/MacOS/OfflineVoiceAssistant"
OUT="${TMPDIR:-/tmp}/ovc-ax-check.out"

if [ ! -x "$BIN" ]; then
    echo "no app at $APP -- run scripts/build_macos.sh and install it first"
    exit 1
fi

pkill -x OfflineVoiceAssistant 2>/dev/null
sleep 1

OVC_SELFTEST_AX=1 "$BIN" > "$OUT" 2>&1 &
APP_PID=$!

# The check ends by exiting the app, so the wait is for the app to finish.
# It takes a few seconds: four cases, each with a focus settle and a paste
# settle.
for _ in $(seq 1 60); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
wait "$APP_PID" 2>/dev/null
STATUS=$?

grep -E "^ok ax|^FAIL|AX SELFTEST" "$OUT" || true
exit "$STATUS"
