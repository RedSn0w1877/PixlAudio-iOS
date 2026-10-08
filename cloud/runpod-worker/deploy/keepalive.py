"""Daily keepalive and spend alarm for the Cloud Studio endpoint (design 3.4). Stdlib only.

    RUNPOD_API_KEY=... CLOUD_WEEKLY_ALARM_USD=2 LAST_DEPLOY_CONCLUSION=success python3 deploy/keepalive.py

1. Health first. RunPod also lowers max workers on an endpoint that keeps producing unhealthy (crashing)
   workers, and every crash bills its model load. So when any worker is unhealthy, or the last deploy failed,
   this does NOT restore anything: it fails the run, and GitHub emails the owner.
2. Otherwise undo RunPod's idle scale-down (3 idle days -> max 2, 7 -> max 0): when workers.max is below
   deploy/endpoint.json's value, PATCH the workers back (min, max and idleTimeout together).
3. GET /health as a reachability check only (it probably doesn't reset the idle timer; no job is sent, so
   the keepalive itself costs nothing).
4. Spend alarm: when the endpoint's last 7 days cost more than CLOUD_WEEKLY_ALARM_USD (default 2), fail the
   run. The amount is never printed (public repo, public logs).
Before setup (no key, or no endpoint yet) it prints a notice and succeeds, so the daily run doesn't email.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from runpod_api import ApiError, RunPod, mask  # noqa: E402

HERE = Path(__file__).resolve().parent


def say(line: str) -> None:
    print(line, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        text = line.split("::", 2)[-1] if line.startswith("::") else line
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"- {text}\n")


def alarm_usd(raw: str | None) -> float:
    try:
        value = float((raw or "").strip() or "2")
    except ValueError:
        return 2.0
    return value if value > 0 else 2.0


def keepalive(api: RunPod | None, template: dict, *, alarm: float, last_deploy: str) -> int:
    if api is None:
        say("::notice::RUNPOD_API_KEY is not set; nothing to keep alive yet")
        return 0
    name = template["name"]
    endpoint = api.find_endpoint(name)
    if endpoint is None:
        say(f"::notice::No endpoint named {name} yet; nothing to keep alive")
        return 0
    endpoint_id = endpoint["id"]
    mask(endpoint_id)
    failures: list[str] = []

    summary = (api.workers(endpoint_id) or {}).get("summary") or {}
    unhealthy = int(summary.get("unhealthy") or 0)
    healthy_to_restore = unhealthy == 0 and last_deploy != "failure"
    if unhealthy:
        failures.append(f"{unhealthy} unhealthy worker(s): RunPod may be scaling the endpoint down for crashing; "
                        "not restoring max workers. Read the endpoint's logs, fix, redeploy.")
    if last_deploy == "failure":
        failures.append("the last cloud-worker-deploy run failed; not restoring max workers until a deploy passes")

    want = template["workers"]
    have = endpoint.get("workers") or {}
    if int(have.get("max") or 0) < int(want["max"]):
        if healthy_to_restore:
            api.update_endpoint(endpoint_id, {"workers": dict(want)})
            say(f"workers: max was {have.get('max')}, restored to {want['max']} (RunPod's idle scale-down)")
        else:
            say(f"workers: max is {have.get('max')} (below {want['max']}) and left alone")
    else:
        say(f"workers: max {have.get('max')}, nothing to restore")

    try:
        health = api.health(endpoint_id)
        workers = health.get("workers") or {}
        say(f"health: reachable; workers idle {workers.get('idle', 0)}, running {workers.get('running', 0)}")
    except ApiError as exc:
        failures.append(f"/health failed: HTTP {exc.status}")

    spend = api.weekly_spend(endpoint_id, 7)
    if spend > alarm:
        failures.append(f"the last 7 days cost more than the CLOUD_WEEKLY_ALARM_USD alarm (${alarm:g}); "
                        "check RunPod's billing page")
    else:
        say(f"spend: under the ${alarm:g}/week alarm")

    for failure in failures:
        say(f"::error::{failure}")
    return 1 if failures else 0


def main() -> int:
    key = os.environ.get("RUNPOD_API_KEY", "").strip()
    template = json.loads((HERE / "endpoint.json").read_text(encoding="utf-8"))
    try:
        return keepalive(RunPod(key) if key else None, template,
                         alarm=alarm_usd(os.environ.get("CLOUD_WEEKLY_ALARM_USD")),
                         last_deploy=os.environ.get("LAST_DEPLOY_CONCLUSION", "").strip().lower())
    except ApiError as exc:
        say(f"::error::keepalive failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
