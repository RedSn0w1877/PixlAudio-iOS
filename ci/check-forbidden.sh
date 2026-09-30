#!/usr/bin/env bash
# Enforces the repo's hard rules (AGENTS.md). Runs on CI before every app build; works on macOS and
# Git Bash on Windows. Exit code 1 lists every violation.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
err() { echo "::error::$*"; fail=1; }

# Apple frameworks and toolchain modules the code may import, plus our own modules.
allowed_imports=(
  # our modules
  PixlAudio PixlFoundation PixlModel PixlLyrics PixlLibrary PixlAudioCore PixlTags PixlNet PixlBackup
  # Swift toolchain / platform
  Swift Foundation FoundationEssentials FoundationNetworking FoundationXML Dispatch Darwin Glibc Musl ucrt WinSDK
  CRT PackageDescription Synchronization Observation RegexBuilder Distributed Testing XCTest os OSLog
  # Apple frameworks
  SwiftUI UIKit AVFoundation AVKit AVRouting MediaPlayer MusicKit CoreMedia CoreAudio CoreAudioTypes AudioToolbox
  Accelerate CoreImage CoreGraphics CoreText CoreFoundation CoreServices ImageIO QuartzCore Metal MetalKit simd
  UniformTypeIdentifiers Security CryptoKit LocalAuthentication SwiftData CoreData Combine Charts
  FoundationModels NaturalLanguage Translation CoreML Vision Speech SoundAnalysis
  AuthenticationServices SafariServices WebKit JavaScriptCore Network BackgroundTasks AppIntents
  Compression CoreHaptics CoreTransferable LinkPresentation PhotosUI Photos StoreKit TipKit
  SystemConfiguration UserNotifications ActivityKit CoreSpotlight MobileCoreServices GameController
)

swift_dirs=()
for d in App AppTests UITests Packages; do [ -d "$d" ] && swift_dirs+=("$d"); done

# 1. Imports limited to Apple frameworks + our modules.
while IFS= read -r line; do
  file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; code="${rest#*:}"
  module="$(echo "$code" | sed -E 's/^[[:space:]]*(@[A-Za-z_]+([(][^)]*[)])?[[:space:]]+)*(public |internal |package |private |fileprivate )?import[[:space:]]+(typealias |struct |class |enum |protocol |let |var |func )?([A-Za-z0-9_]+).*/\5/')"
  ok=0
  for a in "${allowed_imports[@]}"; do [ "$module" = "$a" ] && { ok=1; break; }; done
  [ $ok -eq 1 ] || err "$file:$lineno: import of '$module' is not an allowed Apple framework or PixlCore module"
done < <(grep -rnE --include='*.swift' '^[[:space:]]*(@[A-Za-z_]+([(][^)]*[)])?[[:space:]]+)*((public|internal|package|private|fileprivate)[[:space:]]+)?import[[:space:]]+' "${swift_dirs[@]}" 2>/dev/null)

# 2. Local packages only.
if grep -nE '^[[:space:]]+(url|from|exactVersion|majorVersion|minorVersion|minVersion|maxVersion|branch|revision|github):' project.yml; then
  err "project.yml: remote Swift packages are forbidden (local 'path:' packages only)"
fi
for manifest in Packages/*/Package.swift; do
  [ -f "$manifest" ] || continue
  if grep -nE '\.package[[:space:]]*\(' "$manifest"; then
    err "$manifest: package dependencies are forbidden (PixlCore has zero dependencies)"
  fi
done

# 3. No app extensions / watch apps (free-signing sideload).
if grep -nE 'type:[[:space:]]*(app-extension|extensionkit-extension|watchkit2-extension|watchkit2-app|watchkit2-app-container|application\.watchapp2|application\.watchapp2-container|xpc-service)' project.yml; then
  err "project.yml: app extensions / watch apps are forbidden (free Apple ID sideloading)"
fi

# 4. No glassEffect in content rows/cells/cards.
while IFS= read -r f; do
  if grep -nE 'glassEffect|GlassEffectContainer' "$f" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -q .; then
    err "$f: glassEffect is forbidden in rows/cells/cards (content layer — HIG)"
  fi
done < <(find App -type f -name '*.swift' \( -path '*/Rows/*' -o -name '*Row*.swift' -o -name '*Cell*.swift' -o -name '*Card*.swift' \) 2>/dev/null)

# 5. No "Apple" / "Apple Music" in UI strings (string literals in app sources, the string catalog, Info.plist values).
while IFS= read -r hit; do
  err "$hit: UI strings must not mention Apple"
done < <(grep -rnE --include='*.swift' '"[^"]*\bApple\b[^"]*"' App 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' )
if grep -nE 'Apple Music' project.yml App/Resources/*.xcstrings 2>/dev/null; then
  err "project.yml / string catalog: 'Apple Music' must not appear in user-visible strings"
fi

# 6. iOS 27-only availability checks only in Compat27.swift.
while IFS= read -r hit; do
  err "$hit: iOS 27 APIs belong in App/DesignSystem/Compat27.swift"
done < <(grep -rnE --include='*.swift' '(#available|@available)\(iOS 27' App 2>/dev/null | grep -v 'App/DesignSystem/Compat27.swift')

# 7. Never bundle fonts.
if find App -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' -o -iname '*.woff*' \) | grep -q .; then
  err "App/: bundled fonts are forbidden (system font only)"
fi

if [ $fail -ne 0 ]; then
  echo "check-forbidden: FAILED"
  exit 1
fi
echo "check-forbidden: OK"
