#!/usr/bin/env bash
# Builds an unsigned Release archive and packages it as build/PixlAudio-unsigned.ipa (Payload/PixlAudio.app).
# Sideloadly re-signs it with the user's free Apple ID. Requires the generated PixlAudio.xcodeproj.
set -euo pipefail
mkdir -p build
archive="build/PixlAudio.xcarchive"
rm -rf "$archive" build/Payload build/PixlAudio-unsigned.ipa
set -o pipefail
xcodebuild archive \
  -project PixlAudio.xcodeproj \
  -scheme PixlAudio \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -derivedDataPath build/DerivedData-archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-}" \
  2>&1 | tee build/archive.log | xcbeautify --quieter
app="$archive/Products/Applications/PixlAudio.app"
[ -d "$app" ] || { echo "::error::archive has no PixlAudio.app"; exit 1; }
mkdir -p build/Payload
cp -R "$app" build/Payload/
(cd build && zip -qry PixlAudio-unsigned.ipa Payload)
size="$(du -h build/PixlAudio-unsigned.ipa | cut -f1)"
echo "IPA: build/PixlAudio-unsigned.ipa ($size)"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist" || true
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "**Unsigned IPA:** PixlAudio-unsigned.ipa — $size" >> "$GITHUB_STEP_SUMMARY"
fi
