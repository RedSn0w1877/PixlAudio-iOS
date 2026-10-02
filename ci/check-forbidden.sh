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
  SwiftUI UIKit AVFoundation AVKit AVRouting MediaPlayer MediaToolbox MusicKit CoreMedia CoreAudio CoreAudioTypes AudioToolbox
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
#    Pure bash per line (no subshell + sed per import): forking for each of the ~1000 import lines made this step
#    take 4 minutes on a CI runner busy booting a simulator.
import_re='^[[:space:]]*(@[A-Za-z_]+([(][^)]*[)])?[[:space:]]+)*(public |internal |package |private |fileprivate )?import[[:space:]]+(typealias |struct |class |enum |protocol |let |var |func )?([A-Za-z0-9_]+)'
allowed_list=" ${allowed_imports[*]} "
while IFS= read -r line; do
  file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; code="${rest#*:}"
  if [[ "$code" =~ $import_re ]]; then module="${BASH_REMATCH[5]}"; else module="$code"; fi
  case "$allowed_list" in
    *" $module "*) ;;
    *) err "$file:$lineno: import of '$module' is not an allowed Apple framework or PixlCore module" ;;
  esac
done < <(grep -rnE --include='*.swift' --exclude-dir=.build '^[[:space:]]*(@[A-Za-z_]+([(][^)]*[)])?[[:space:]]+)*((public|internal|package|private|fileprivate)[[:space:]]+)?import[[:space:]]+' "${swift_dirs[@]}" 2>/dev/null)

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

# 4. Decision 10 (a port of PixlAudio with Liquid Glass in place of Material): no Material leftovers in the app.
#    - Material / Compose names used as identifiers (Ripple, FloatingActionButton, FAB, TonalElevation, MaterialTheme,
#      Material3, "Material" types) — PixlAudio palette role names (primaryContainer, …) are fine.
#    - Fake glass: blur materials (.ultraThinMaterial, .thinMaterial, .regularMaterial, .thickMaterial,
#      .ultraThickMaterial, .bar, Material.*), UIBlurEffect / UIVisualEffectView. Use glassEffect / .glass styles.
#      A UIVisualEffectView holding a UIGlassEffect is real Liquid Glass (UIKit's API for it): such lines name
#      UIGlassEffect (code or trailing comment) and are allowed — the tab bar's lens needs UIKit glass (LiquidTabBar).
#    Comment lines are ignored, so docs may name what they replace.
material_pattern="\b(Ripple[A-Za-z]*|FloatingActionButton|FAB[A-Z][A-Za-z]*|[A-Za-z]*TonalElevation|tonalElevation|MaterialTheme|Material3|Material[A-Z][A-Za-z]*|Material\.)"
fake_glass_pattern="[(:,][[:space:]]*\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|ultraThickMaterial|bar)\b|\bUIBlurEffect\b|\bUIVisualEffectView\b"
while IFS= read -r hit; do
  err "$hit: Material leftover — replace with the Liquid Glass equivalent (docs/design.md, component mapping)"
done < <(grep -rnE --include="*.swift" "$material_pattern" App 2>/dev/null | grep -vE "^[^:]+:[0-9]+:[[:space:]]*//")
while IFS= read -r hit; do
  err "$hit: fake glass (blur material) — use glassEffect / .buttonStyle(.glass) (orchestrator notes, Liquid Glass rules)"
done < <(grep -rnE --include="*.swift" "$fake_glass_pattern" App 2>/dev/null | grep -vE "^[^:]+:[0-9]+:[[:space:]]*//" | grep -vE "UIVisualEffectView.*UIGlassEffect|UIGlassEffect.*UIVisualEffectView")

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
