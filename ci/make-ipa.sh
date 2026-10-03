#!/usr/bin/env bash
# Builds an unsigned Release archive and packages it as build/PixlAudio-unsigned.ipa (Payload/PixlAudio.app).
# Sideloadly re-signs it with the user's free Apple ID. Requires the generated PixlAudio.xcodeproj.
set -euo pipefail
mkdir -p build
archive="build/PixlAudio.xcarchive"
rm -rf "$archive" build/Payload build/PixlAudio-unsigned.ipa
# A tag build (`v1.2.3`, `v1.2.3-beta2`) reports the tag's version, so the installed app never offers its own release
# as an update. Only the numeric part: CFBundleShortVersionString allows no suffix. Other builds (main, manual runs)
# keep project.yml's MARKETING_VERSION.
version_args=()
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
  tag_version="${GITHUB_REF_NAME#v}"
  tag_version="${tag_version%%-*}"
  if [[ "$tag_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    version_args+=("MARKETING_VERSION=$tag_version")
  else
    echo "::warning::tag ${GITHUB_REF_NAME} has no numeric version; keeping project.yml's MARKETING_VERSION"
  fi
fi
# An empty client ID is a supported state (Spotify sign-in asks for one in the app), so this only warns.
if [ -z "${SPOTIFY_CLIENT_ID:-}" ]; then
  echo "::warning::SPOTIFY_CLIENT_ID secret is empty; Spotify sign-in needs a client ID pasted in the app"
fi
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
  ${version_args[@]+"${version_args[@]}"} \
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
