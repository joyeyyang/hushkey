#!/bin/bash
# Runs the Accessibility check against the INSTALLED app.
#
# The check needs the installed app, not the build tree: Accessibility
# permission is granted to a bundle id with a signature, and the installed
# app is the one that has it. It also needs a window server, so it cannot run
# over SSH.
#
# Usage: scripts/ax_check.sh [--reset] [app-path]
#
#   --reset   drop the app's Accessibility grant (tccutil reset) and print how
#             to give it back. Use it when the switch in System Settings reads
#             ON but the check still says there is no permission: that pair
#             means the row belongs to a build that is not the one on disk, and
#             the only way out is to remove the row and grant it again.
#
# Exit codes: 0 pass, 1 the replacement itself is wrong, 77 skipped because
# the app has no Accessibility permission. 77 is a SKIP and not a failure on
# purpose: a missing grant is an environment fact (the switch is off, or the
# signature changed and TCC still remembers the old one), and it says nothing
# about whether the code is right. verify.sh prints the same code as SKIP.
set -uo pipefail

APP=""
RESET=0
for arg in "$@"; do
    case "$arg" in
        --reset) RESET=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) APP="$arg" ;;
    esac
done
APP="${APP:-/Applications/OfflineVoiceAssistant.app}"
BIN="$APP/Contents/MacOS/OfflineVoiceAssistant"
OUT="${TMPDIR:-/tmp}/ovc-ax-check.out"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$APP/Contents/Info.plist" 2>/dev/null || echo com.example.offlinevoiceassistant)"

if [ ! -x "$BIN" ]; then
    echo "no app at $APP -- run scripts/build_macos.sh and install it first"
    exit 1
fi

if [ "$RESET" -eq 1 ]; then
    tccutil reset Accessibility "$BUNDLE_ID" || exit 1
    cat <<EOF
reset the Accessibility grant for $BUNDLE_ID.

Now give it back, or the next run is a SKIP:
  1. open -a "$APP"
  2. System Settings > Privacy & Security > Accessibility: switch the app on
     (the app asks on launch; if the entry is stale, remove it with "−" and
     add it again with "+")
  3. scripts/ax_check.sh
EOF
    exit 0
fi

pkill -x OfflineVoiceAssistant 2>/dev/null
sleep 1
# An instance wedged in the GPU driver (seen once: the LLM init hung and the
# process would not take SIGTERM) stays in front and makes the NEW instance
# non-frontmost, which fails every case for a reason that is not the paste. A
# second, harder kill is cheap; if it survives that too, say so instead of
# reporting four paste failures.
if pgrep -x OfflineVoiceAssistant >/dev/null; then
    pkill -9 -x OfflineVoiceAssistant 2>/dev/null
    sleep 1
fi
if pgrep -x OfflineVoiceAssistant >/dev/null; then
    echo "another OfflineVoiceAssistant is running and will not die -- log out or kill it first"
    exit 1
fi

OVC_SELFTEST_AX=1 "$BIN" > "$OUT" 2>&1 &
APP_PID=$!

# The check ends by exiting the app, so the wait is for the app to finish.
# It takes a few seconds: four cases, each with a focus settle and a paste
# settle. The cap is only for a run that hangs -- a hung app must not hold
# verify.sh forever.
for _ in $(seq 1 60); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if kill -0 "$APP_PID" 2>/dev/null; then
    echo "the app is still running after 30 s -- killing it"
    kill -9 "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    grep -E "^ok ax|^FAIL|AX SELFTEST" "$OUT" || true
    exit 1
fi
wait "$APP_PID" 2>/dev/null
STATUS=$?

grep -E "^ok ax|^FAIL|AX SELFTEST" "$OUT" || true

if grep -q "no Accessibility permission" "$OUT"; then
    cat <<EOF

SKIP  the installed app has no Accessibility permission.

This is an environment problem, not a code problem. Either the switch is off,
or the row in System Settings belongs to a different build than the one on
disk -- a rebuild with another signature leaves the switch reading ON while the
running build is untrusted.

  scripts/ax_check.sh --reset    # drop the stale grant, then follow the steps
EOF
    exit 77
fi

exit "$STATUS"
