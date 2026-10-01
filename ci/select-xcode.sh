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
# Stage 9: the app has Metal shaders (the lyrics artwork background). Since Xcode 26 the Metal toolchain is a separate
# download that hosted runners may not have installed; fetch it once per job when it is missing.
if git ls-files '*.metal' 2>/dev/null | grep -q . && ! xcrun metal --version >/dev/null 2>&1; then
  echo "Downloading the Metal toolchain…"
  # The component can take a moment to register after "Done downloading" (seen on main, 2026-10-01): retry the check,
  # then the download once more, before giving up. The build step reports a real absence on its own.
  for attempt in 1 2 3; do
    xcodebuild -downloadComponent MetalToolchain || true
    for wait in 2 5 10; do
      if xcrun metal --version >/dev/null 2>&1; then xcrun metal --version; exit 0; fi
      sleep "$wait"
    done
    echo "Metal toolchain not usable yet (attempt $attempt)"
  done
  echo "::warning::Metal toolchain still unavailable after download; the build may fail on .metal files"
fi
