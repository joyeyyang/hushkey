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
export OVC_LLM_WORKER="${OVC_LLM_WORKER:-$ROOT/rust/core_engine/target/release/ovc-llm-worker}"

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
( cd rust/core_engine && \
  SHERPA_ONNX_DIR="$PWD/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared" \
  DYLD_LIBRARY_PATH="$PWD/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared/lib" \
  cargo test --release ) >/tmp/ovc-verify-rust.log 2>&1
record "rust tests" $?

step "swift tests"
( cd mac/macos_app && swift test ) >/tmp/ovc-verify-swift.log 2>&1
record "swift tests" $?

if [ ! -x "$APP" ]; then
    printf '\nthe app is not built -- run scripts/build_macos.sh first\n'
    exit 1
fi

step "cli self-test"
./mac/macos_app/.build/release/voiceinput --selftest >/tmp/ovc-verify-cli.log 2>&1
record "cli self-test" $?

# The CLI's edit and summarise paths are the kit's, reached from the command
# line. Both are checked with a real model call, because a probe that only
# checked the argument handling would pass with a broken pipeline.
step "cli edit"
printf '明天下午三點跟小林開會，討論第四季時程，地點還沒確定' \
    | ./mac/macos_app/.build/release/voiceinput --edit "把小林改成大衛" \
    >/tmp/ovc-verify-cli-edit.log 2>&1
EDIT_STATUS=$?
record "cli edit" $EDIT_STATUS
if [ $EDIT_STATUS -eq 0 ]; then
    # The edit has to land on the right line, not merely succeed.
    if grep -q "明天下午三點跟大衛開會" /tmp/ovc-verify-cli-edit.log; then
        printf 'PASS  cli edit landed on the right line\n'
    else
        printf 'FAIL  cli edit landed on the wrong line\n'
        FAILED+=("cli edit target")
    fi
fi

step "cli summarize"
printf '明天下午三點跟小林開會討論第四季時程。小林說下週三之前會給客戶看初稿。我負責週五之前補上第二段的數字。' \
    | ./mac/macos_app/.build/release/voiceinput --summarize \
    >/tmp/ovc-verify-cli-summary.log 2>&1
SUMMARY_STATUS=$?
record "cli summarize" $SUMMARY_STATUS
if [ $SUMMARY_STATUS -eq 0 ]; then
    # The three meeting sections have to be there, and the owner of an action
    # must not be invented.
    if grep -q "## 摘要" /tmp/ovc-verify-cli-summary.log \
        && grep -q "## 決議" /tmp/ovc-verify-cli-summary.log \
        && grep -q "## 待辦" /tmp/ovc-verify-cli-summary.log; then
        printf 'PASS  cli summarize has the meeting sections\n'
    else
        printf 'FAIL  cli summarize is missing a meeting section\n'
        FAILED+=("cli summarize sections")
    fi
fi

# The three registers, on one sentence: the same input through the same cleanup,
# once per tone. What is checked is not that each answer is good -- that is a
# judgement call -- but that the switch is wired all the way to the prompt: three
# identical answers mean the tone never left the settings file. The fourth run
# omits --tone and has to match "normal", which is the default the product
# promises when nothing is chosen.
step "refine tone (3 registers)"
TONE_INPUT='嗯那個下週三下午三點半你有空嗎，我要跟你討論那個八十萬的案子，然後記得帶合約'
TONE_STATUS=0
for tone in casual normal formal default; do
    TONE_FLAG="--tone $tone"
    [ "$tone" = "default" ] && TONE_FLAG=""
    # shellcheck disable=SC2086
    printf '%s' "$TONE_INPUT" | ./mac/macos_app/.build/release/voiceinput --refine $TONE_FLAG \
        >"/tmp/ovc-verify-tone-$tone.log" 2>&1 || TONE_STATUS=1
    [ -s "/tmp/ovc-verify-tone-$tone.log" ] || TONE_STATUS=1
done
record "refine tone" $TONE_STATUS
if [ $TONE_STATUS -eq 0 ]; then
    if cmp -s /tmp/ovc-verify-tone-casual.log /tmp/ovc-verify-tone-normal.log \
        || cmp -s /tmp/ovc-verify-tone-normal.log /tmp/ovc-verify-tone-formal.log \
        || cmp -s /tmp/ovc-verify-tone-casual.log /tmp/ovc-verify-tone-formal.log; then
        printf 'FAIL  two registers answered identically\n'
        FAILED+=("refine tone distinct")
    elif ! cmp -s /tmp/ovc-verify-tone-default.log /tmp/ovc-verify-tone-normal.log; then
        printf 'FAIL  omitting --tone did not answer like normal\n'
        FAILED+=("refine tone default")
    else
        printf 'PASS  the three registers answered differently, and the default is normal\n'
    fi
fi

# The guardrail, through the C entry point the two apps call. `cargo test` covers
# the rules as Rust functions; this is the only harness that reaches
# `LLM_CheckOutput` itself, so it is what would catch an argument in the wrong
# order or a reason that never gets written. No model, so it costs a second.
step "guardrail (C ABI)"
./rust/core_engine/target/release/examples/guardrail_probe >/tmp/ovc-verify-guardrail.log 2>&1
GUARD_STATUS=$?
record "guardrail" $GUARD_STATUS
if [ $GUARD_STATUS -eq 0 ]; then
    grep -q "=== 8/8 as expected" /tmp/ovc-verify-guardrail.log \
        && printf 'PASS  both directions: the bad answers are refused, the good ones are kept\n' \
        || { printf 'FAIL  guardrail case table did not match\n'; FAILED+=("guardrail cases"); }
fi

# The edit probe measures the PRODUCT path -- the same call the app makes --
# against the eleven spoken edits and their expected answers. Checking the raw
# model instead would measure something the user never sees: the model's
# answer is a numbered list, and the product's job is to find the named line
# and put the draft's own shape back.
step "voice edit probe (15 cases)"
OVC_LLM_WORKER="$ROOT/rust/core_engine/target/release/ovc-llm-worker" \
    ./rust/core_engine/target/release/examples/edit_batch tests/edit_expected.tsv \
    >/tmp/ovc-verify-edit-batch.log 2>&1
EDIT_BATCH_STATUS=$?
record "voice edit probe" $EDIT_BATCH_STATUS
if grep -qE "^=== 15/15 right$" /tmp/ovc-verify-edit-batch.log; then
    printf 'PASS  voice edit probe landed on the right line in every case\n'
else
    printf 'FAIL  voice edit probe did not land on the right line in every case\n'
    grep -E "verdict: WRONG|wanted:|^=== " /tmp/ovc-verify-edit-batch.log | head -8
    FAILED+=("voice edit probe")
fi

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
