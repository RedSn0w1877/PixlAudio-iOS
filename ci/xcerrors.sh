#!/usr/bin/env bash
# Summarises compiler errors and failed tests into $GITHUB_STEP_SUMMARY (and stdout).
# Usage: ci/xcerrors.sh <xcodebuild.log> [result.xcresult ...]
set -uo pipefail
log="${1:-}"; shift || true
out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
{
  echo "### Build/test problems"
  if [ -n "$log" ] && [ -f "$log" ]; then
    errors="$(grep -E '(^|[[:space:]])(error|fatal error):' "$log" | grep -vE '^\s*$' | sed -E 's#^.*/(App|AppTests|UITests|Packages)/#\1/#' | sort -u | head -n 80)"
    if [ -n "$errors" ]; then
      echo; echo '```'; echo "$errors"; echo '```'
    else
      echo; echo "No \`error:\` lines in \`$log\`."
      echo; echo "Last 40 log lines:"; echo '```'; tail -n 40 "$log"; echo '```'
    fi
  fi
  for bundle in "$@"; do
    [ -d "$bundle" ] || continue
    echo; echo "#### $(basename "$bundle")"
    echo '```'
    xcrun xcresulttool get test-results summary --path "$bundle" --compact 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print("result:", s.get("result"), "| passed:", s.get("passedTests"), "| failed:", s.get("failedTests"), "| skipped:", s.get("skippedTests"))
for f in s.get("testFailures", [])[:40]:
    print("FAIL", f.get("testIdentifierString") or f.get("testName"), "-", (f.get("failureText") or "").strip()[:300])
' || true
    echo '```'
  done
} >> "$out"
[ "$out" != "/dev/stdout" ] && cat "$GITHUB_STEP_SUMMARY" | tail -n 120 || true
