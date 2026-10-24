#!/usr/bin/env bash
# Summarise the model A/B: wall time and peak RSS per case, per model.
#
# The time files are `/usr/bin/time -l` output, which puts the wall clock on a
# "N.NN real" line and the peak on a "N maximum resident set size" line.
set -u
cd "$(dirname "$0")/../core_engine/target/ab" || exit 1

row() { # file tag
  awk -v tag="$2" '
    $2 == "real" { t = $1 }
    $3 == "maximum" { r = $1 }
    END { printf "%-8s %8.1f s  %6.0f MB\n", tag, t, r / 1048576 }
  ' "$1"
}

echo "case                              Qwen3.5-2B           Qwen2.5-1.5B"
for t in "$(ls q35_*.time 2>/dev/null | head -1)" ; do :; done
for f in q35_*.time; do
  case_name="${f#q35_}"; case_name="${case_name%.time}"
  a="$(row "q35_${case_name}.time" "q35")"
  b="$(row "q25_${case_name}.time" "q25")"
  printf "%-32s %s   %s\n" "$case_name" "$a" "$b"
done

echo
echo "totals"
awk 'BEGIN{t=0;r=0} $2=="real"{t+=$1} $3=="maximum"{r+=$1} END{printf "q35  %6.1f s total, peak %.0f MB\n", t, r/1048576}' q35_*.time
awk 'BEGIN{t=0;r=0} $2=="real"{t+=$1} $3=="maximum"{r+=$1} END{printf "q25  %6.1f s total, peak %.0f MB\n", t, r/1048576}' q25_*.time
