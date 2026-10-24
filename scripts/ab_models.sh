#!/usr/bin/env bash
# Model A/B over the ten verification transcripts.
#
# Serial on purpose: the machine has 8 GB of RAM, and two workers at once land in
# swap and produce empty output that looks like a model failure.
set -u
cd "$(dirname "$0")/../core_engine" || exit 1
# The transcripts live in the repo, not a temp directory: the first run of this
# script read them from /tmp and macOS deleted them, which silently turned every
# case into "cat: No such file" and a FAILED line.
D="tests/transcripts"
AB="target/ab"
BIN="target/release/examples/meeting_summary"
mkdir -p "$AB"
[[ -x "$BIN" ]] || { echo "build first: $BIN missing" >&2; exit 1; }
shopt -s nullglob
CASES=("$D"/t*.txt)
if (( ${#CASES[@]} == 0 )); then
  echo "no transcripts in $D -- refusing to run" >&2
  exit 1
fi

run_model() {
  local file="$1" tag="$2"
  for t in "${CASES[@]}"; do
    local name
    name="$(basename "$t" .txt)"
    echo "== $tag $name"
    if OVC_LLM_MODEL="$file" TRANSCRIPT="$(cat "$t")" \
        /usr/bin/time -l "$BIN" > "$AB/${tag}_${name}.out" 2> "$AB/${tag}_${name}.time"; then
      local rss
      rss="$(awk '/maximum resident set size/ {print $1}' "$AB/${tag}_${name}.time")"
      echo "   ok rss=$rss"
    else
      echo "   FAILED"
    fi
  done
}

run_model "Qwen3.5-2B-Q4_K_M.gguf" q35
# `bash scripts/ab_models.sh q35` re-runs one model only, which is what a prompt
# change needs: the other model's numbers are unaffected by it.
if [[ "${1:-both}" != "q35" ]]; then
  run_model "qwen2.5-1.5b-instruct-q4_k_m.gguf" q25
fi
echo "AB DONE"
