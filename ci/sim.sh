#!/usr/bin/env bash
# Simulator lifecycle for CI jobs. A first boot on a hosted runner takes 2–6 minutes, so jobs start it early
# in the background and only wait for it right before testing; meanwhile XcodeGen and the build run.
#   ci/sim.sh boot <ios-major>   pick the simulator (ci/pick-sim.sh exports SIM_UDID/SIM_NAME/SIM_OS to
#                                $GITHUB_ENV) and start booting it in the background
#   ci/sim.sh wait               block until that simulator has finished booting (SIM_UDID from the env)
set -euo pipefail
cd "$(dirname "$0")/.."
log="build/sim-boot.log"
case "${1:-}" in
  boot)
    udid="$(bash ci/pick-sim.sh "${2:-27}")"
    mkdir -p build
    # `bootstatus -b` boots the device if needed and then follows the whole boot (data migration included) until
    # the device is usable. Detach it completely (no inherited stdio) so this step returns at once and the boot
    # keeps running into the following steps.
    nohup bash -c "date -u +'%T boot started'; xcrun simctl bootstatus '$udid' -b; echo \"exit \$?\"; date -u +'%T boot finished'" \
      < /dev/null > "$log" 2>&1 &
    echo "Booting $udid in the background (log: $log)"
    ;;
  wait)
    udid="${SIM_UDID:?SIM_UDID is not set; run ci/sim.sh boot first}"
    start=$(date +%s)
    # Returns as soon as the device is booted; boots it itself if the background boot died.
    xcrun simctl bootstatus "$udid" -b
    echo "Waited $(( $(date +%s) - start )) s for the simulator."
    [ -f "$log" ] && sed 's/^/  boot log: /' "$log" || true
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "**Simulator wait after the build:** $(( $(date +%s) - start )) s" >> "$GITHUB_STEP_SUMMARY"
    fi
    ;;
  *)
    echo "usage: ci/sim.sh boot <ios-major> | wait" >&2; exit 2 ;;
esac
