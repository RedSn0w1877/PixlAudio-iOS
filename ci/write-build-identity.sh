#!/usr/bin/env bash
# Build identity (docs/handoff/2026-10-10-crash-diagnostics.md): writes App/Generated/BuildStamp.swift with the commit
# this build came from and the day it was built, so Settings > About and every exported diagnostics log say which
# build the phone runs. Outside CI (no GITHUB_SHA) it asks git, else leaves the committed stub alone.
#   bash ci/write-build-identity.sh [output file]
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-App/Generated/BuildStamp.swift}"
sha="${GITHUB_SHA:-}"
[ -n "$sha" ] || sha="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -z "$sha" ]; then
  echo "No commit id available: the committed BuildStamp stub stays."
  exit 0
fi
short="${sha:0:7}"
day="$(date -u +%Y-%m-%d)"
mkdir -p "$(dirname "$out")"
cat > "$out" <<SWIFT
// Generated on CI by ci/write-build-identity.sh. Never commit this version: the committed file is the stub.
nonisolated enum BuildStamp {
    static let gitSHA = "$short"
    static let builtOn = "$day"
}
SWIFT
echo "Build identity: $short, $day"
