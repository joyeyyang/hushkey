#!/usr/bin/env bash
# Download models listed in models/manifest.json (download == true).
# Resumable (curl -C -), verifies byte size and SHA-256, writes atomically.
# Usage: scripts/download_models.sh [models_dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/models/manifest.json"
DEST="${1:-$ROOT/models}"
TMP="$DEST/downloads"

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v shasum >/dev/null || { echo "error: shasum not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

mkdir -p "$TMP"

python3 -c '
import json,sys
for e in json.load(open(sys.argv[1]))["models"]:
    if not e.get("download", True):
        continue
    print("|".join([e["id"], e["source_url"], e["file"], str(e["bytes"]), e["sha256"]]))
' "$MANIFEST" | while IFS='|' read -r id url file bytes sha; do
  out="$DEST/$file"
  mkdir -p "$(dirname "$out")"

  if [[ -f "$out" ]] && [[ "$(stat -f %z "$out")" == "$bytes" ]] \
     && [[ "$sha" != "PENDING" ]] && [[ "$(shasum -a 256 "$out" | cut -d' ' -f1)" == "$sha" ]]; then
    echo "ok (cached): $id"
    continue
  fi

  part="$TMP/$(basename "$file").part"
  echo "downloading: $id"
  if ! curl -fL --retry 5 --retry-delay 3 -C - -o "$part" "$url"; then
    echo "error: download failed for $id" >&2
    exit 1
  fi

  got_size="$(stat -f %z "$part")"
  if [[ "$got_size" != "$bytes" ]]; then
    echo "error: $id size $got_size != expected $bytes (partial kept for resume? removing)" >&2
    rm -f "$part"
    exit 1
  fi
  if [[ "$sha" != "PENDING" ]]; then
    got_sha="$(shasum -a 256 "$part" | cut -d' ' -f1)"
    if [[ "$got_sha" != "$sha" ]]; then
      echo "error: $id sha256 mismatch: $got_sha" >&2
      rm -f "$part"
      exit 1
    fi
  else
    echo "warning: $id has no pinned sha256; size-only check" >&2
  fi
  mv "$part" "$out"
  echo "ok: $id"
done
