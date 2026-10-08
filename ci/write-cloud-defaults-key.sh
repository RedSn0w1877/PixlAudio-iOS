#!/usr/bin/env bash
# Built-in cloud keys (docs/handoff/2026-10-08-baked-keys.md): writes App/Generated/CloudDefaultsKey.swift from the
# CLOUD_DEFAULTS_KEY secret (base64 of the 32-byte AES-256 key that opens App/Resources/CloudDefaults.enc), split into
# 4 XOR shares (3 random, the last the key XOR the other three), so the key never sits in the binary as one string.
# Without the secret (forks, pull requests, a repo that never set it) the committed stub stays and the build simply has
# no built-in keys. Reads the key from the environment only and never prints it, a share or a byte of either.
#   CLOUD_DEFAULTS_KEY=<base64> bash ci/write-cloud-defaults-key.sh [output file]
# bash 3.2 (macOS /bin/bash) compatible; needs only base64 (or openssl), od, tr.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-App/Generated/CloudDefaultsKey.swift}"

if [ -z "${CLOUD_DEFAULTS_KEY:-}" ]; then
  echo "CLOUD_DEFAULTS_KEY is not set: this build has no built-in cloud keys (the committed stub stays)."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s' "$CLOUD_DEFAULTS_KEY" | tr -d ' \t\r\n' > "$work/key.b64"
# 32 bytes are exactly 43 base64 characters and one '='.
if ! grep -Eq '^[A-Za-z0-9+/]{43}=$' "$work/key.b64"; then
  echo "::error::CLOUD_DEFAULTS_KEY is not the base64 of 32 bytes; set it again with tools/cloud/bake-cloud-keys.mjs"
  exit 1
fi
if ! { base64 -d < "$work/key.b64" > "$work/key.bin" 2>/dev/null \
       || base64 -D < "$work/key.b64" > "$work/key.bin" 2>/dev/null \
       || openssl base64 -d -A < "$work/key.b64" > "$work/key.bin" 2>/dev/null; }; then
  echo "::error::could not decode CLOUD_DEFAULTS_KEY (no base64 or openssl?)"
  exit 1
fi
key=( $(od -An -v -tu1 "$work/key.bin") )
if [ "${#key[@]}" -ne 32 ]; then
  echo "::error::CLOUD_DEFAULTS_KEY decodes to ${#key[@]} bytes, not 32"
  exit 1
fi

s1=( $(od -An -v -tu1 -N 32 /dev/urandom) )
s2=( $(od -An -v -tu1 -N 32 /dev/urandom) )
s3=( $(od -An -v -tu1 -N 32 /dev/urandom) )
if [ "${#s1[@]}" -ne 32 ] || [ "${#s2[@]}" -ne 32 ] || [ "${#s3[@]}" -ne 32 ]; then
  echo "::error::could not read random bytes"
  exit 1
fi
s4=()
for i in $(seq 0 31); do
  s4[$i]=$(( key[i] ^ s1[i] ^ s2[i] ^ s3[i] ))
done
# Self-check: the four shares give the key back (what CloudDefaultsKeyShares.combine does in the app).
for i in $(seq 0 31); do
  if [ $(( s1[i] ^ s2[i] ^ s3[i] ^ s4[i] )) -ne "${key[i]}" ]; then
    echo "::error::share self-check failed"
    exit 1
  fi
done

row() {
  local line="        [" first=1 byte
  for byte in "$@"; do
    if [ $first -eq 1 ]; then first=0; else line="$line, "; fi
    line="$line$(printf '0x%02x' "$byte")"
  done
  printf '%s],\n' "$line"
}

mkdir -p "$(dirname "$out")"
{
  echo "// Generated on CI by ci/write-cloud-defaults-key.sh from the CLOUD_DEFAULTS_KEY secret. Never commit this version:"
  echo "// the committed file is the empty stub."
  echo "nonisolated enum CloudDefaultsKey {"
  echo "    static let shares: [[UInt8]] = ["
  row "${s1[@]}"
  row "${s2[@]}"
  row "${s3[@]}"
  row "${s4[@]}"
  echo "    ]"
  echo "}"
} > "$work/CloudDefaultsKey.swift"
mv "$work/CloudDefaultsKey.swift" "$out"
echo "Built-in cloud keys: wrote $out (4 shares; the key itself is not in the file)."
