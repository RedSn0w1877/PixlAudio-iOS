#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest runtime of the wanted iOS major version.
# Preference: iPhone 18 Pro, iPhone 17 Pro, iPhone 17, then any iPhone. Never hard-code names in workflows.
# Usage: ci/pick-sim.sh 27   (prints UDID; also exports SIM_UDID/SIM_NAME/SIM_OS to $GITHUB_ENV)
set -euo pipefail
major="${1:-27}"
json_file="$(mktemp)"
xcrun simctl list devices available -j > "$json_file"
result="$(python3 - "$major" "$json_file" <<'PY'
import json, re, sys
major = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)["devices"]
runtimes = []
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not m:
        continue
    version = tuple(int(x) for x in m.groups() if x is not None)
    iphones = [d for d in devices if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
    if iphones:
        runtimes.append((version, runtime, iphones))
if not runtimes:
    sys.exit("no iPhone simulators available")
wanted = [r for r in runtimes if str(r[0][0]) == major] or runtimes
version, runtime, iphones = sorted(wanted, key=lambda r: r[0])[-1]
preferred = ["iPhone 18 Pro", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro"]
def rank(d):
    return preferred.index(d["name"]) if d["name"] in preferred else len(preferred)
device = sorted(iphones, key=rank)[0]
print(device["udid"], ".".join(map(str, version)), device["name"], sep="|")
PY
)"
udid="${result%%|*}"; rest="${result#*|}"; os="${rest%%|*}"; name="${rest#*|}"
echo "Simulator: $name (iOS $os) $udid" >&2
if [ -n "${GITHUB_ENV:-}" ]; then
  { echo "SIM_UDID=$udid"; echo "SIM_NAME=$name"; echo "SIM_OS=$os"; } >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "**Simulator:** $name, iOS $os (\`$udid\`)" >> "$GITHUB_STEP_SUMMARY"
fi
echo "$udid"
