#!/usr/bin/env bash
# Installs a pinned XcodeGen release binary (build-time tool only; never shipped) and puts it on PATH.
# Usage: ci/install-xcodegen.sh [version]
set -euo pipefail
version="${1:-2.46.0}"
expected_sha="${XCODEGEN_SHA256:-}"
dest="${RUNNER_TEMP:-/tmp}/xcodegen-${version}"
if [ ! -x "$dest/xcodegen/bin/xcodegen" ]; then
  mkdir -p "$dest"
  curl -fsSL --retry 3 -o "$dest/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip"
  if [ -n "$expected_sha" ]; then
    echo "${expected_sha}  $dest/xcodegen.zip" | shasum -a 256 -c -
  fi
  unzip -q -o "$dest/xcodegen.zip" -d "$dest"
fi
"$dest/xcodegen/bin/xcodegen" --version
if [ -n "${GITHUB_PATH:-}" ]; then echo "$dest/xcodegen/bin" >> "$GITHUB_PATH"; fi
