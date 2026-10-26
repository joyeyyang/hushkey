#!/bin/bash
# Every check that can run without a human, in one place.
#
# The checks live in different places -- Rust unit tests, Swift unit tests, the
# app's own self-tests, the command-line tool -- and it is easy to run one of
# them and not the other. This runs them all, in order, and stops at the first
# failure.
#
# Usage: scripts/verify.sh [wav]
#   wav  a 16 kHz mono 16-bit WAV for the audio checks. Defaults to the
#        benchmark clip under /tmp. The audio checks are skipped when it is
#        missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WAV="${1:-/tmp/ovc-bench/b0.wav}"
APP="$ROOT/dist/OfflineVoiceAssistant.app/Contents/MacOS/OfflineVoiceAssistant"
FAILED=()

export OVC_MODELS="${OVC_MODELS:-$ROOT/models}"
export OVC_LLM_WORKER="${OVC_LLM_WORKER:-$ROOT/core_engine/target/release/ovc-llm-worker}"

step() {
    printf '\n=== %s ===\n' "$1"
}

record() {
    local name="$1" code="$2"
    if [ "$code" -eq 0 ]; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s (exit %s)\n' "$name" "$code"
        FAILED+=("$name")
    fi
}

step "rust tests"
( cd core_engine && \
  SHERPA_ONNX_DIR="$PWD/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared" \
  DYLD_LIBRARY_PATH="$PWD/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared/lib" \
  cargo test --release ) >/tmp/ovc-verify-rust.log 2>&1
record "rust tests" $?

step "swift tests"
( cd macos_app && swift test ) >/tmp/ovc-verify-swift.log 2>&1
record "swift tests" $?

if [ ! -x "$APP" ]; then
    printf '\nthe app is not built -- run scripts/build_macos.sh first\n'
    exit 1
fi

step "cli self-test"
./macos_app/.build/release/voiceinput --selftest >/tmp/ovc-verify-cli.log 2>&1
record "cli self-test" $?

step "offscreen ui self-test"
rm -rf /tmp/ovc-verify-ui && mkdir -p /tmp/ovc-verify-ui
for theme in paper night; do
    OVC_SELFTEST_UI=/tmp/ovc-verify-ui OVC_SELFTEST_UI_THEME="$theme" "$APP" \
        >/tmp/ovc-verify-ui-$theme.log 2>&1
    record "offscreen ui ($theme)" $?
done

if [ -f "$WAV" ]; then
    step "dictation end to end"
    OVC_SELFTEST_WAV="$WAV" OVC_SELFTEST_POLISH=1 "$APP" \
        >/tmp/ovc-verify-dictation.log 2>&1
    record "dictation end to end" $?

    step "audio import"
    OVC_SELFTEST_IMPORT="$WAV" "$APP" >/tmp/ovc-verify-import.log 2>&1
    record "audio import" $?

    step "meeting session (no cleanup over a meeting transcript)"
    OVC_SELFTEST_MEETING="$WAV" "$APP" >/tmp/ovc-verify-meeting.log 2>&1
    record "meeting session" $?

    step "meeting session control (a dictation DOES run the cleanup)"
    OVC_SELFTEST_MEETING="$WAV" OVC_SELFTEST_MEETING_MODE=dictation "$APP" \
        >/tmp/ovc-verify-meeting-control.log 2>&1
    record "meeting session control" $?
else
    printf '\n(skipping the audio checks: no WAV at %s)\n' "$WAV"
fi

# The Accessibility check runs against the INSTALLED app, because the
# Accessibility permission belongs to a bundle id with a signature and the
# installed app is the one that has it. It also needs a window server.
step "accessibility replacement (against a real text field)"
if [ -x /Applications/OfflineVoiceAssistant.app/Contents/MacOS/OfflineVoiceAssistant ]; then
    ./scripts/ax_check.sh >/tmp/ovc-verify-ax.log 2>&1
    record "accessibility replacement" $?
else
    printf 'SKIP  accessibility replacement (the app is not installed)\n'
fi

printf '\n'
if [ ${#FAILED[@]} -eq 0 ]; then
    printf 'ALL CHECKS PASSED\n'
    exit 0
fi
printf 'FAILED: %s\n' "${FAILED[*]}"
exit 1
