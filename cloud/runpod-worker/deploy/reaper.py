"""Release a Cloud Studio worker that stays up, idle and billed, after its jobs are done. Stdlib only.

    RUNPOD_API_KEY=... python3 deploy/reaper.py

Why: on 2026-10-08, after the first deploy's selftest, a worker of pixl-cloud-studio sat idle=1 / ready=1 for 7+
minutes although idleTimeout is 10 s, and RunPod bills an idle worker like a busy one (about $0.6-0.7 an hour on
these pools). Setting max workers to 0 and back released it at once. The worker now asks RunPod to stop it after the
jobs nothing follows (handler.py, refresh_worker); this is the safety net behind that, run every 30 minutes by
.github/workflows/cloud-worker-reaper.yml and by runpod_deploy.py after its selftest/bench.

1. Find the endpoint by name (deploy/endpoint.json); its id is masked at once. No key or no endpoint yet: succeed
   quietly. Max workers already 0 (switched off by hand, or RunPod's own scale-down): leave it alone.
2. GET /health twice, about a minute apart. A worker counts as stranded only when BOTH reads show an idle or
   ready worker, none running, and no job in the queue or in progress.
3. PATCH workers.max to 0, then read /health every 10 s until no worker is left (2 minutes at most). A job that
   turns up meanwhile ends the wait at once: it only waits for the restore.
4. PATCH the workers back: max as it was found (never above endpoint.json's), min and idleTimeout from
   endpoint.json. Always, also after a timeout, a failed read or a failed PATCH to 0 (it may have been applied
   before the connection dropped). A failed PATCH, either one, and a worker still there after the 2 minutes fail
   the run, so GitHub emails the owner.
A read that fails before anything was changed is only a warning (the daily keepalive reports an unreachable RunPod
or a revoked key), so an outage doesn't send an email every half hour.
Prints counts only: never a key, the endpoint id, a response body or money.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from runpod_api import ApiError, RunPod, mask  # noqa: E402

HERE = Path(__file__).resolve().parent
CONFIRM_S = 60.0  # between the two /health reads that must both show the worker stranded
GONE_TIMEOUT_S = 120.0  # how long max 0 may take to release the worker
POLL_S = 10.0

# release_idle outcomes
OFF = "off"  # max workers is 0: nothing to release, nothing touched
NOTHING_IDLE = "nothing idle"
RELEASED = "released"
JOB_ARRIVED = "job arrived"  # a job turned up while max was 0: restored at once
STILL_THERE = "still there"  # max 0 didn't release the worker within GONE_TIMEOUT_S (restored anyway)
UNKNOWN = "unknown"  # /health failed while waiting at max 0 (restored at once; the next run looks again)
NO_MAX = "no max"  # the endpoint's workers.max wasn't in RunPod's answer: nothing touched


class ReaperError(Exception):
    pass


def say(line: str) -> None:
    print(line, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        text = line.split("::", 2)[-1] if line.startswith("::") else line
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"- {text}\n")


def _count(doc: dict, key: str) -> int:
    value = doc.get(key)
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def counts(health: dict | None) -> dict[str, int]:
    """The /health numbers this needs: {"jobs": {inQueue, inProgress, ...}, "workers": {idle, ready, running, ...}}."""
    health = health if isinstance(health, dict) else {}
    jobs = health.get("jobs") if isinstance(health.get("jobs"), dict) else {}
    workers = health.get("workers") if isinstance(health.get("workers"), dict) else {}
    return {"idle": _count(workers, "idle"), "ready": _count(workers, "ready"), "running": _count(workers, "running"),
            "initializing": _count(workers, "initializing"), "inQueue": _count(jobs, "inQueue"),
            "inProgress": _count(jobs, "inProgress")}


def stranded(c: dict[str, int]) -> bool:
    """An idle or ready worker with nothing to do: no job queued, in progress or running."""
    return c["idle"] + c["ready"] > 0 and c["running"] == 0 and c["inQueue"] == 0 and c["inProgress"] == 0


def has_work(c: dict[str, int]) -> bool:
    return c["inQueue"] > 0 or c["inProgress"] > 0 or c["running"] > 0


def gone(c: dict[str, int]) -> bool:
    return c["idle"] + c["ready"] + c["running"] + c["initializing"] == 0


def describe(c: dict[str, int]) -> str:
    return (f"workers idle {c['idle']}, ready {c['ready']}, running {c['running']}, initializing {c['initializing']}; "
            f"jobs in queue {c['inQueue']}, in progress {c['inProgress']}")


def release_idle(api: RunPod, endpoint_id: str, current_workers: dict, template: dict, *,
                 confirm_s: float = CONFIRM_S, gone_timeout_s: float = GONE_TIMEOUT_S, poll_s: float = POLL_S,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
                 say: Callable[[str], None] = say) -> str:
    """Steps 2-4 of the module docstring for one endpoint. Returns one of the outcomes above. Raises ApiError when a
    read fails before anything changed, ReaperError when the workers couldn't be restored."""
    want = template["workers"]
    raw_max = (current_workers or {}).get("max")
    if isinstance(raw_max, bool) or not isinstance(raw_max, int):
        # REST v2's Endpoint always has workers.max; without it there is nothing safe to restore to.
        say("::warning::reaper: RunPod's answer doesn't say the endpoint's max workers; nothing changed")
        return NO_MAX
    found_max = raw_max
    if found_max <= 0:
        say("reaper: max workers is 0 (switched off or scaled down); left alone")
        return OFF
    first = counts(api.health(endpoint_id))
    if not stranded(first):
        say(f"reaper: nothing idle ({describe(first)})")
        return NOTHING_IDLE
    sleep(confirm_s)
    second = counts(api.health(endpoint_id))
    if not stranded(second):
        say(f"reaper: nothing idle on the second look ({describe(second)})")
        return NOTHING_IDLE
    restore_max = min(found_max, int(want["max"]))
    restore = {"min": min(int(want.get("min", 0)), restore_max), "max": restore_max,
               "idleTimeout": int(want["idleTimeout"])}
    say(f"reaper: a worker has been idle for over {int(confirm_s)} s with nothing to do ({describe(second)}); "
        "setting max workers to 0 to release it")
    outcome = STILL_THERE
    patch_error: ApiError | None = None
    started = clock()
    try:
        try:
            api.update_endpoint(endpoint_id, {"workers": {"min": 0, "max": 0, "idleTimeout": restore["idleTimeout"]}})
        except ApiError as exc:  # it may still have been applied (a dropped connection): the restore runs anyway
            patch_error = exc
        while patch_error is None:
            sleep(poll_s)
            try:
                now = counts(api.health(endpoint_id))
            except ApiError as exc:
                outcome = UNKNOWN
                say(f"::warning::reaper: /health failed while waiting (HTTP {exc.status}); restoring now")
                break
            if has_work(now):
                outcome = JOB_ARRIVED
                say(f"reaper: a job arrived while max was 0 ({describe(now)}); restoring at once")
                break
            if gone(now):
                outcome = RELEASED
                say(f"reaper: the idle worker is gone after {int(clock() - started)} s")
                break
            if clock() - started >= gone_timeout_s:
                say(f"::warning::reaper: still {describe(now)} after {int(gone_timeout_s)} s at max 0")
                break
    finally:
        try:
            api.update_endpoint(endpoint_id, {"workers": restore})
        except ApiError as exc:
            raise ReaperError(f"couldn't set max workers back to {restore_max} ({exc}); set it in the RunPod "
                              "console (Serverless > pixl-cloud-studio > Edit) or run cloud-worker-keepalive") from None
        say(f"reaper: max workers back to {restore_max}")
    if patch_error is not None:
        raise ReaperError(f"couldn't set max workers to 0 ({patch_error}); the idle worker is still there")
    return outcome


def reap(api: RunPod | None, template: dict, **kw) -> int:
    if api is None:
        say("reaper: RUNPOD_API_KEY is not set; nothing to do")
        return 0
    try:
        endpoint = api.find_endpoint(template["name"])
    except ApiError as exc:
        say(f"::warning::reaper: couldn't list the endpoints ({exc}); nothing changed")
        return 0
    if endpoint is None:
        say(f"reaper: no endpoint named {template['name']} yet; nothing to do")
        return 0
    endpoint_id = endpoint["id"]
    mask(endpoint_id)
    try:
        outcome = release_idle(api, endpoint_id, endpoint.get("workers") or {}, template, **kw)
    except ApiError as exc:  # a read before anything changed (a failed PATCH to 0 changed nothing either)
        say(f"::warning::reaper: {exc}; nothing changed")
        return 0
    if outcome == STILL_THERE:
        say("::error::max workers 0 didn't release the idle worker; check Serverless > pixl-cloud-studio > Workers in "
            "the RunPod console and stop it there")
        return 1
    return 0


def main() -> int:
    key = os.environ.get("RUNPOD_API_KEY", "").strip()
    template = json.loads((HERE / "endpoint.json").read_text(encoding="utf-8"))
    try:
        return reap(RunPod(key) if key else None, template)
    except ReaperError as exc:
        say(f"::error::reaper failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
