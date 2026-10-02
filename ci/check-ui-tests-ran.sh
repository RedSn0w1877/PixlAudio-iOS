#!/usr/bin/env bash
# Fails the shots job when the selected UI tests did not actually run: xcodebuild reports success when a
# [shots:Name] entry matches nothing (a typo, or a *ScreenshotTests.swift file that is only an extension of
# ScreenshotTests), which would otherwise pass green with no screenshots.
# Usage: ci/check-ui-tests-ran.sh <xcodebuild log>   (reads build/ui-test-classes.txt from ci/ui-test-args.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
log="$1"; fail=0
if ! grep -q "Test Case '-\[PixlAudioUITests\." "$log"; then
  echo "::error::No UI test ran. Check the [shots:…] filter / shots_only input: entries must be UI test classes (or Class/testMethod)."
  fail=1
fi
while IFS= read -r cls; do
  [ -z "$cls" ] && continue
  if ! grep -q "Test Suite '$cls' started" "$log"; then
    hint=""
    if [ -f "UITests/$cls.swift" ] && grep -qE "^extension[[:space:]]+[A-Za-z0-9_]+" "UITests/$cls.swift"; then
      hint=" UITests/$cls.swift only extends $(grep -oE '^extension[[:space:]]+[A-Za-z0-9_]+' "UITests/$cls.swift" | head -1 | awk '{print $2}') — name that class instead."
    fi
    echo "::error::[shots:$cls] matched no UI tests: there is no UI test class named $cls.$hint"
    fail=1
  fi
done < build/ui-test-classes.txt
[ $fail -eq 0 ] && echo "UI test selection OK: $(grep -c "Test Case '-\[PixlAudioUITests\..*' started" "$log") test runs."
exit $fail
