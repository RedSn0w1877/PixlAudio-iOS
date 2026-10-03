#!/usr/bin/env bash
# Prints (one per line) the xcodebuild test-selection arguments for the shots job and records the requested
# classes in build/ui-test-classes.txt for ci/check-ui-tests-ran.sh.
#   Filter: the shots_only dispatch input (SHOTS_ONLY_INPUT), else "[shots:A,B]" in the commit message (COMMIT_MSG).
#   Entries are UI test classes (or Class/testMethod) of PixlAudioUITests.
#   - On branches a filter runs just those classes; no filter runs every class.
#   - main always runs every class (the filter is ignored there, except as below).
#   - Opt-in classes (TransitionPerformanceTests: slow performance measurements, not screenshots; the recording
#     classes, made to be filmed with [record:Class]) are skipped whenever every class runs, unless the filter
#     names them explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
opt_in_classes=(TransitionPerformanceTests MenuRecordingTests TransitionRecordingTests)

filter="${SHOTS_ONLY_INPUT:-}"
if [ -z "$filter" ]; then
  filter="$(printf '%s' "${COMMIT_MSG:-}" | grep -o '\[shots:[^]]*\]' | head -1 | sed 's/^\[shots://; s/\]$//' || true)"
fi
entries=()
if [ -n "$filter" ]; then
  IFS=',' read -ra raw <<< "$filter"
  for e in ${raw[@]+"${raw[@]}"}; do
    e="$(printf '%s' "$e" | tr -d '[:space:]')"
    [ -z "$e" ] && continue
    if [[ "$e" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?$ ]]; then
      entries+=("$e")
    else
      echo "::warning::ignoring invalid [shots:] entry '$e' (expected Class or Class/testMethod)" >&2
    fi
  done
fi
named() { local c; for c in "${entries[@]+"${entries[@]}"}"; do [ "${c%%/*}" = "$1" ] && return 0; done; return 1; }

mkdir -p build
: > build/ui-test-classes.txt
if [ ${#entries[@]} -gt 0 ] && [ "${GITHUB_REF:-}" != "refs/heads/main" ]; then
  for e in "${entries[@]}"; do
    echo "-only-testing:PixlAudioUITests/$e"
    echo "${e%%/*}" >> build/ui-test-classes.txt
  done
  echo "UI tests: only ${entries[*]}" >&2
else
  # Every UI test class: skip the unit-test bundle instead of -only-testing the UI bundle, so the -skip-testing of
  # opt-in classes below is not overridden (xcodebuild gives -only-testing precedence over -skip-testing).
  echo "-skip-testing:PixlAudioTests"
  skipped=()
  for c in "${opt_in_classes[@]}"; do
    if named "$c"; then continue; fi
    echo "-skip-testing:PixlAudioUITests/$c"
    skipped+=("$c")
  done
  echo "UI tests: every class${skipped[0]+ except ${skipped[*]}}" >&2
fi
