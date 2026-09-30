#!/usr/bin/env bash
# Selects an installed Xcode by version (default 27.0) and prints what was selected.
# Usage: ci/select-xcode.sh 27.0
set -euo pipefail
want="${1:-27.0}"
path=""
for candidate in "/Applications/Xcode_${want}.app" "/Applications/Xcode_${want}.0.app"; do
  if [ -d "$candidate" ]; then path="$candidate"; break; fi
done
if [ -z "$path" ]; then
  # Discover: first non-beta Xcode whose name starts with the wanted version.
  path="$(ls -d /Applications/Xcode_"${want}"*.app 2>/dev/null | grep -vi beta | head -n1 || true)"
fi
if [ -z "$path" ]; then
  echo "::error::Xcode ${want} not found. Installed:"; ls -d /Applications/Xcode*.app; exit 1
fi
sudo xcode-select -s "$path/Contents/Developer"
echo "Selected $(readlink "$path" 2>/dev/null || echo "$path")"
xcodebuild -version
xcrun swift --version
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "**Xcode:** \`$path\` — $(xcodebuild -version | tr '\n' ' ')"; } >> "$GITHUB_STEP_SUMMARY"
fi
