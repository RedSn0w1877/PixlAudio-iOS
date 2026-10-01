#!/usr/bin/env bash
# Hosted macOS runners only (no-op elsewhere): stop Spotlight indexing on the throwaway VM. mds/mdworker index the
# build folder and the simulator's data while we build and test; on the 3-CPU / 7 GB runners they held ~300–450 MB
# and up to a full core (ci-speed load samples, run 36939967573).
set -uo pipefail
if [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "$(uname)" != "Darwin" ]; then
  echo "tune-runner: not a GitHub-hosted macOS runner, nothing to do"; exit 0
fi
sudo -n mdutil -a -i off >/dev/null 2>&1 && echo "Spotlight indexing off" || echo "::warning::could not turn Spotlight indexing off"
exit 0
