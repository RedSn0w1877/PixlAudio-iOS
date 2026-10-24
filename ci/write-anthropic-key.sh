#!/usr/bin/env bash
# Built-in Claude key (spec A1, the sibling of ci/write-cloud-defaults-key.sh): writes App/Generated/AnthropicKey.swift
# from the ANTHROPIC_API_KEY secret, split into 4 XOR shares of the key's length (3 random, the last the key XOR the
# other three), so the key never sits in the binary as one string. Without the secret (forks, pull requests, a repo that
# never set it) the committed stub stays and the build simply has no built-in key (every AI feature stays on the device).
# Reads the key from the environment only and never prints it, a share or a byte of either.
#   ANTHROPIC_API_KEY=<key> bash ci/write-anthropic-key.sh [output file]
# bash 3.2 (macOS /bin/bash) compatible; needs only od and tr.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-App/Generated/AnthropicKey.swift}"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY is not set: this build has no built-in Claude key (the committed stub stays)."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s' "$ANTHROPIC_API_KEY" | tr -d ' \t\r\n' > "$work/key.txt"
# Anthropic keys are printable ASCII without spaces (sk-ant-...); anything else is a pasting mistake.
# LC_ALL=C: in a UTF-8 locale BSD grep's [!-~] range follows collation order and rejects a valid key.
if ! LC_ALL=C grep -Eq '^[[:graph:]]{20,400}$' "$work/key.txt"; then
  echo "::error::ANTHROPIC_API_KEY doesn't look like an API key (printable ASCII, 20-400 characters); set it again"
  exit 1
fi
key=( $(od -An -v -tu1 "$work/key.txt") )
n=${#key[@]}

s1=( $(od -An -v -tu1 -N "$n" /dev/urandom) )
s2=( $(od -An -v -tu1 -N "$n" /dev/urandom) )
s3=( $(od -An -v -tu1 -N "$n" /dev/urandom) )
if [ "${#s1[@]}" -ne "$n" ] || [ "${#s2[@]}" -ne "$n" ] || [ "${#s3[@]}" -ne "$n" ]; then
  echo "::error::could not read random bytes"
  exit 1
fi
s4=()
last=$((n - 1))
for i in $(seq 0 "$last"); do
  s4[$i]=$(( key[i] ^ s1[i] ^ s2[i] ^ s3[i] ))
done
# Self-check: the four shares give the key back (what ClaudeKeyShares.combine does in the app).
for i in $(seq 0 "$last"); do
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
  echo "// Generated on CI by ci/write-anthropic-key.sh from the ANTHROPIC_API_KEY secret. Never commit this version:"
  echo "// the committed file is the empty stub."
  echo "nonisolated enum AnthropicKey {"
  echo "    static let shares: [[UInt8]] = ["
  row "${s1[@]}"
  row "${s2[@]}"
  row "${s3[@]}"
  row "${s4[@]}"
  echo "    ]"
  echo "}"
} > "$work/AnthropicKey.swift"
mv "$work/AnthropicKey.swift" "$out"
echo "Built-in Claude key: wrote $out (4 shares; the key itself is not in the file)."
