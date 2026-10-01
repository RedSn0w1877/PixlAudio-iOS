#!/usr/bin/env bash
# TEMPORARY diagnostics: samples the processes involved in a test run every 15 s, and once the XCTest summary
# line has appeared in <log> for 60 s, takes `sample` stacks of xcodebuild and the test host so we can see what
# xcodebuild waits for after the tests finished. Usage: ci/diag-sampler.sh <xcodebuild log> <out dir> &
set -uo pipefail
log="$1"; out="$2"; mkdir -p "$out"
sampled=0; done_at=""
while true; do
  {
    echo "=== $(date -u +%T)"
    ps -axo pid,ppid,etime,stat,pcpu,rss,command | grep -E 'PixlAudio|xctest|XCTest|testmanagerd|xcodebuild|XCBBuildService|simctl|CoreSimulator|SimulatorTrampoline|launchd_sim|diagnosticd|ReportCrash|spindump|xcresult' | grep -v grep | cut -c1-260
  } >> "$out/ps-samples.log" 2>&1
  if [ -z "$done_at" ] && grep -q "Test Suite 'All tests'" "$log" 2>/dev/null; then done_at=$(date +%s); fi
  if [ -n "$done_at" ] && [ $sampled -lt 2 ] && [ $(( $(date +%s) - done_at )) -ge $(( 60 + sampled * 180 )) ]; then
    for p in $(pgrep -x xcodebuild); do sample "$p" 3 -file "$out/sample-xcodebuild-$p-$sampled.txt" >/dev/null 2>&1; done
    for p in $(pgrep -f 'PixlAudio.app/PixlAudio'); do sample "$p" 3 -file "$out/sample-PixlAudio-$p-$sampled.txt" >/dev/null 2>&1; done
    if [ -n "${SIM_UDID:-}" ]; then
      xcrun simctl spawn "$SIM_UDID" launchctl list 2>&1 | grep -iE 'pixl|xctest|test' > "$out/sim-launchctl-$sampled.txt" 2>&1
    fi
    sampled=$((sampled + 1))
  fi
  sleep 15
done
