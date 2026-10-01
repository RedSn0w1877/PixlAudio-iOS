#!/usr/bin/env bash
# Simulator steps for CI jobs (SIM_UDID comes from ci/pick-sim.sh).
#   ci/sim.sh boot            boot the simulator and wait until it is usable
#   ci/sim.sh prepare-shots   fresh app + screenshot conditions on the booted simulator (before the UI tests)
#
# Boot AFTER the build, never during it. On the hosted 3-CPU / 7 GB runners the first boot of an iOS 27 simulator
# sets off 10+ minutes of home-screen widget and wallpaper rendering (load average ~600, ~2 GB in the memory
# compressor); a build running alongside took 8–10 min instead of 2.5 (ci-speed A/B, run 36939967573). The unit
# tests run during that storm instead, and they cope.
set -euo pipefail
cd "$(dirname "$0")/.."
udid="${SIM_UDID:?SIM_UDID is not set; run ci/pick-sim.sh first}"
case "${1:-}" in
  boot)
    start=$(date +%s)
    # `bootstatus -b` boots the device if needed and follows the boot (data migration included) until it is usable.
    xcrun simctl bootstatus "$udid" -b | grep -v 'isTerminal=NO' | grep . || true
    xcrun simctl list devices | grep -F "$udid) (Booted)" >/dev/null || { echo "::error::simulator $udid did not boot"; exit 1; }
    echo "Booted in $(( $(date +%s) - start )) s."
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "**Simulator boot:** $(( $(date +%s) - start )) s" >> "$GITHUB_STEP_SUMMARY"
    fi
    ;;
  prepare-shots)
    # The unit tests ran first in this simulator with the same app as their host: remove the app (its data
    # container and preferences go with it) and reset the keychain, so the screenshots start from the same fresh
    # state as on a simulator of their own. The UI test run installs the app again.
    app="build/DerivedData/Build/Products/Debug-iphonesimulator/PixlAudio.app"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
    xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    xcrun simctl uninstall "$udid" "$bundle_id"
    xcrun simctl keychain "$udid" reset || true
    xcrun simctl status_bar "$udid" override --time 9:41 \
      --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 \
      --batteryState charged --batteryLevel 100
    # Suppress the first-run "slide to type" keyboard tip in search screenshots.
    xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true || true
    echo "Simulator ready for screenshots ($bundle_id removed, status bar overridden)."
    ;;
  *)
    echo "usage: ci/sim.sh boot | prepare-shots" >&2; exit 2 ;;
esac
