#!/usr/bin/env bash
# Section-level A/B: one summary section ("actions") across every transcript and
# both installed models.
#
# The whole-pipeline A/B cannot say WHY a section is bad -- prompt, model, or the
# post-filters. This puts the section's own prompt in front of each model, so a
# difference in owner attribution is attributable to the model alone.
#
# Serial on purpose: 8 GB of RAM, and two llama workers at once land in swap.
set -u
cd "$(dirname "$0")/../rust/core_engine" || exit 1

D="tests/transcripts"
OUT="target/section_ab"
BIN="target/release/examples/section_probe"
SECTION="${SECTION:-actions}"
mkdir -p "$OUT"
[[ -x "$BIN" ]] || { echo "build first: $BIN missing" >&2; exit 1; }

shopt -s nullglob
CASES=("$D"/t*.txt)
(( ${#CASES[@]} )) || { echo "no transcripts in $D" >&2; exit 1; }

for model in "Qwen3.5-2B-Q4_K_M.gguf:q35" "qwen2.5-1.5b-instruct-q4_k_m.gguf:q25"; do
  file="${model%%:*}"; tag="${model##*:}"
  for t in "${CASES[@]}"; do
    name="$(basename "$t" .txt)"
    echo "== $tag $name"
    OVC_LLM_MODEL="$file" "$BIN" "$SECTION" "$t" > "$OUT/${tag}_${SECTION}_${name}.out" 2>/dev/null || echo "   FAILED"
  done
done
echo "SECTION AB DONE"
