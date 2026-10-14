#!/usr/bin/env bash
# Verify installed models against models/manifest.json (size + SHA-256).
# Exit 0 only if every download==true entry is present, correct, and pinned.
# Usage: scripts/verify_models.sh [models_dir]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/models/manifest.json"
DEST="${1:-$ROOT/models}"
fail=0

while IFS='|' read -r id file bytes sha; do
  out="$DEST/$file"
  if [[ ! -f "$out" ]]; then
    echo "MISSING  $id ($file)"; fail=1; continue
  fi
  size="$(stat -f %z "$out")"
  if [[ "$size" != "$bytes" ]]; then
    echo "BADSIZE  $id ($size != $bytes)"; fail=1; continue
  fi
  if [[ "$sha" == "PENDING" ]]; then
    echo "UNPINNED $id (size ok; no sha256 in manifest)"; fail=1; continue
  fi
  got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    echo "BADHASH  $id"; fail=1; continue
  fi
  echo "OK       $id"
done < <(python3 -c '
import json,sys
for e in json.load(open(sys.argv[1]))["models"]:
    if e.get("download", True):
        print("|".join([e["id"], e["file"], str(e["bytes"]), e["sha256"]]))
' "$MANIFEST")

exit $fail
