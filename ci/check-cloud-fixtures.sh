#!/usr/bin/env bash
# Cloud Studio schema drift check (design §2.3): the worker's golden examples in
# cloud/runpod-worker/schema/v1/examples/ and the copies the Swift tests decode in
# Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/ must be identical (the same folder the worker's own
# ci/check_fixtures.py checks). The phone's other fixtures (RunPod responses, a bucket listing, lyrics edge cases)
# live in Fixtures/cloud-phone/, so every .json in Fixtures/cloud/ is a worker example.
#
#   bash ci/check-cloud-fixtures.sh                # compare with the worker folder in this checkout
#   bash ci/check-cloud-fixtures.sh origin/s19-cloud-worker   # compare with a git ref (before the worker merges)
#   bash ci/check-cloud-fixtures.sh --sync [ref]   # copy the worker's examples over the Swift fixtures
#
# Without a worker folder (and no ref) it skips with a note, so it is safe on branches without the worker.
set -euo pipefail
cd "$(dirname "$0")/.."

examples="cloud/runpod-worker/schema/v1/examples"
copies="Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud"
sync=0
if [[ "${1:-}" == "--sync" ]]; then sync=1; shift; fi
ref="${1:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -n "$ref" ]]; then
  names="$(git ls-tree --name-only "$ref" -- "$examples/" | xargs -n1 basename 2>/dev/null || true)"
  [[ -n "$names" ]] || { echo "check-cloud-fixtures: $ref has no $examples"; exit 1; }
  for name in $names; do git show "$ref:$examples/$name" > "$tmp/$name"; done
elif [[ -d "$examples" ]]; then
  cp "$examples"/*.json "$tmp/"
else
  echo "check-cloud-fixtures: no $examples in this checkout; skipped (pass a ref to compare with a branch)."
  exit 0
fi

if [[ $sync -eq 1 ]]; then
  mkdir -p "$copies"
  rm -f "$copies"/*.json
  cp "$tmp"/*.json "$copies/"
  echo "check-cloud-fixtures: copied $(ls "$tmp" | wc -l | tr -d ' ') examples into $copies"
  exit 0
fi

if diff -r "$tmp" "$copies" > "$tmp.diff" 2>&1; then
  echo "check-cloud-fixtures: OK ($(ls "$tmp" | wc -l | tr -d ' ') examples match)"
else
  cat "$tmp.diff"
  rm -f "$tmp.diff"
  echo "check-cloud-fixtures: the Swift fixture copies differ from the worker's examples."
  echo "Run: bash ci/check-cloud-fixtures.sh --sync ${ref}  then re-run the PixlNet tests."
  exit 1
fi
rm -f "$tmp.diff"
