#!/usr/bin/env bash
# The on-device spatial stage's files (cloud audio spec of 2026-11-10, section 7): the worker generates
# spatial_preview_v1.json (the coefficient tables) and spatial_preview_golden_v1.json (a fixed input and the
# reference output) into cloud/runpod-worker/schema/v1/spatial/. The app ships a copy of the tables and the stage's
# tests read copies of both. Every copy must be byte-identical to the worker's file: nobody edits them by hand.
#
#   bash ci/check-spatial-fixtures.sh                # compare with the worker folder in this checkout
#   bash ci/check-spatial-fixtures.sh origin/audio-hq # compare with a git ref
#   bash ci/check-spatial-fixtures.sh --sync [ref]   # copy the worker's files over the app's copies
#
# Without a worker folder (and no ref) it skips with a note, so it is safe on branches without the worker.
set -euo pipefail
cd "$(dirname "$0")/.."

source_dir="cloud/runpod-worker/schema/v1/spatial"
tables="spatial_preview_v1.json"
golden="spatial_preview_golden_v1.json"
fixtures="Packages/PixlCore/Tests/PixlAudioCoreTests/Fixtures/spatial"
# "<copy>:<worker file>"
copies=(
  "App/Resources/$tables:$tables"
  "$fixtures/$tables:$tables"
  "$fixtures/$golden:$golden"
)

sync=0
if [[ "${1:-}" == "--sync" ]]; then sync=1; shift; fi
ref="${1:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -n "$ref" ]]; then
  for name in "$tables" "$golden"; do
    git show "$ref:$source_dir/$name" > "$tmp/$name" || { echo "check-spatial-fixtures: $ref has no $source_dir/$name"; exit 1; }
  done
elif [[ -d "$source_dir" ]]; then
  cp "$source_dir/$tables" "$source_dir/$golden" "$tmp/"
else
  echo "check-spatial-fixtures: no $source_dir in this checkout; skipped (pass a ref to compare with a branch)."
  exit 0
fi

fail=0
for entry in "${copies[@]}"; do
  copy="${entry%%:*}"
  name="${entry##*:}"
  if [[ $sync -eq 1 ]]; then
    mkdir -p "$(dirname "$copy")"
    cp "$tmp/$name" "$copy"
    echo "check-spatial-fixtures: copied $name to $copy"
  elif [[ ! -f "$copy" ]]; then
    echo "::error::$copy is missing (run: bash ci/check-spatial-fixtures.sh --sync ${ref})"
    fail=1
  elif ! cmp -s "$tmp/$name" "$copy"; then
    echo "::error::$copy differs from $source_dir/$name (run: bash ci/check-spatial-fixtures.sh --sync ${ref})"
    fail=1
  fi
done

if [[ $sync -eq 1 ]]; then exit 0; fi
if [[ $fail -ne 0 ]]; then
  echo "check-spatial-fixtures: the app's copies differ from the worker's files."
  exit 1
fi
echo "check-spatial-fixtures: OK (${#copies[@]} copies match)"
