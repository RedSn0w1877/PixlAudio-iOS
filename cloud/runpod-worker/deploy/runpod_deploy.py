"""Create or update the Cloud Studio endpoint on RunPod and prove the new image answers (design 3.3).

    RUNPOD_API_KEY=... R2_ACCOUNT_ID=<32 hex> python3 deploy/runpod_deploy.py --tag sha-<12 hex> [--create]
        [--no-selftest] [--bench] [--extra-pools ADA_24] [--auto]

Steps (stdlib only, idempotent):
1. find the endpoint by name (deploy/endpoint.json `name`); its id is masked in the log at once;
   with --auto (the run that follows a main build) a missing endpoint or key is a notice, not a failure:
   the first deploy is always by hand (owner step B4), with --create;
2. check RunPod can pull the image without credentials (anonymous GHCR token + manifest HEAD);
3. create it (POST /v2/serverless) or PATCH only what differs. A PATCH that changes `env` always carries the
   complete env, and a GPU change always carries pools and excludedTypes together (pools alone clears the
   exclusions);
4. wait for the rollout (GET .../releases until no worker runs an older version);
5. selftest through /runsync: the answering worker's gitSha must be this build's (old workers may still answer
   while they drain, so it retries); the storage host allowlist must not be empty;
6. --bench: one `op: bench` (per-stage seconds, peak VRAM), then the W1 concurrency check: 3 bench jobs at
   once while polling the workers every 5 s for the peak number running (above 1 means "extra workers" exist
   and every max-1 cost bound is off). Each selftest and bench stops its worker afterwards (handler.py), so the
   3 concurrency jobs each start a worker of their own;
7. after the selftest/bench, whether they passed or not (but not when the run is cancelled): the idle release of
   deploy/reaper.py (two /health reads a minute apart; a worker still idle and ready with nothing to do is
   released by max workers 0 and back), since an idle worker left by the deploy's own jobs bills until something
   stops it (seen on 2026-10-08).
Prints only pass/fail lines, the GPU name and timings: never a key, the endpoint id, a response body or money.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from reaper import STILL_THERE, ReaperError, release_idle  # noqa: E402
from runpod_api import FINAL_STATES, ApiError, RunPod, ghcr_public, mask, wait_for_job  # noqa: E402

IMAGE_REPO = "ghcr.io/redsn0w1877/pixl-cloud-worker"
TAG_RE = re.compile(r"^sha-[0-9a-f]{12}$")
ACCOUNT_RE = re.compile(r"^[0-9a-f]{32}$")
POOL_RE = re.compile(r"^[A-Z][A-Z0-9_]{1,40}$")
HERE = Path(__file__).resolve().parent


class DeployError(Exception):
    pass


def say(line: str) -> None:
    print(line, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        text = line.split("::", 2)[-1] if line.startswith("::") else line
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"- {text}\n")


def desired_state(template: dict, image: str, account_id: str, extra_pools: list[str]) -> dict:
    if not ACCOUNT_RE.match(account_id or ""):
        raise DeployError("R2_ACCOUNT_ID must be the 32-hex Cloudflare account id (a GitHub variable, not a secret)")
    body = copy.deepcopy(template)
    body["image"] = image
    body["env"] = {k: str(v).replace("{R2_ACCOUNT_ID}", account_id) for k, v in body.get("env", {}).items()}
    if any("{" in v for v in body["env"].values()):
        raise DeployError("deploy/endpoint.json has an unfilled {placeholder} in env")
    pools = list(body["gpu"]["pools"])
    for pool in extra_pools:
        if not POOL_RE.match(pool):
            raise DeployError(f"extra pool {pool!r} is not a RunPod pool id such as ADA_24")
        if pool not in pools:
            pools.append(pool)
    body["gpu"]["pools"] = pools
    return body


def _same_set(a, b) -> bool:
    return sorted(a or []) == sorted(b or [])


def patch_for(current: dict, desired: dict) -> dict:
    """The smallest valid PATCH body that makes `current` match `desired` (empty when nothing differs)."""
    patch: dict = {}
    if current.get("type") not in (None, desired["type"]):
        raise DeployError(f"the endpoint is {current.get('type')}, not {desired['type']}; delete it and redeploy")
    for key in ("image", "disk", "timeout", "flashboot", "name"):
        if current.get(key) != desired[key]:
            patch[key] = desired[key]
    if (current.get("env") or {}) != desired["env"]:
        patch["env"] = dict(desired["env"])  # always complete: never a diff
    cur, want = current.get("gpu") or {}, desired["gpu"]
    if (not _same_set(cur.get("pools"), want["pools"]) or not _same_set(cur.get("excludedTypes"), want["excludedTypes"])
            or cur.get("count", 1) != want.get("count", 1) or cur.get("minCudaVersion") != want.get("minCudaVersion")
            or (cur.get("allowedCudaVersions") or [])):
        patch["gpu"] = {"pools": list(want["pools"]), "excludedTypes": list(want["excludedTypes"]),
                        "count": want.get("count", 1), "minCudaVersion": want["minCudaVersion"],
                        "allowedCudaVersions": []}  # [] may accompany a floor; a non-empty set may not
    cur_w, want_w = current.get("workers") or {}, desired["workers"]
    if any(cur_w.get(k) != want_w[k] for k in want_w):
        patch["workers"] = dict(want_w)
    cur_s, want_s = current.get("scaling") or {}, desired["scaling"]
    if cur_s.get("type") != want_s["type"] or float(cur_s.get("queueDelay") or 0) != float(want_s["queueDelay"]):
        patch["scaling"] = dict(want_s)
    return patch


def wait_rollout(api: RunPod, endpoint_id: str, *, timeout_s: float = 900, poll_s: float = 15,
                 clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep) -> bool:
    end = clock() + timeout_s
    while True:
        rollout = (api.releases(endpoint_id) or {}).get("rollout") or {}
        if not rollout.get("inProgress"):
            say(f"rollout: done ({rollout.get('workersOnLatest', 0)}/{rollout.get('workersTotal', 0)} workers on the new version)")
            return True
        if clock() > end:
            say(f"rollout: still in progress after {int(timeout_s)} s ({rollout.get('percentOnLatest', 0)} % on the new version)")
            return False
        sleep(poll_s)


def _error_code(reply: dict) -> str:
    error = str(reply.get("error") or "")
    code = error.split(":", 1)[0].strip()
    return code if re.fullmatch(r"[A-Z][A-Z0-9_]{1,40}", code) else "UNKNOWN"


def cancel_unfinished(api: RunPod, endpoint_id: str, job_id: str | None, state: str | None) -> None:
    """A job still queued when the script stops waiting (no GPU free in the pools) would otherwise start, and bill,
    whenever a GPU turns up, long after anyone reads the result. Best effort."""
    if not job_id or state in FINAL_STATES:
        return
    try:
        api.cancel(endpoint_id, job_id)
        say("cancelled the unfinished job, so it can't start (and bill) later")
    except ApiError as exc:
        say(f"::warning::could not cancel the unfinished job (HTTP {exc.status})")


def selftest(api: RunPod, endpoint_id: str, git_sha: str, *, tries: int = 3, job_timeout_s: float = 1500,
             sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> dict:
    """Run op selftest until a worker from this build answers. Returns its output; raises DeployError."""
    for attempt in range(1, tries + 1):
        first = api.runsync(endpoint_id, {"v": 1, "op": "selftest"}, wait_ms=300000)
        reply = wait_for_job(api, endpoint_id, first, deadline_s=job_timeout_s, sleep=sleep, clock=clock)
        state = reply.get("status")
        if state != "COMPLETED":
            cancel_unfinished(api, endpoint_id, reply.get("id") or first.get("id"), state)
            raise DeployError(f"selftest {state or 'did not finish'}" + (f" ({_error_code(reply)})" if reply.get("error") else ""))
        output = reply.get("output") or {}
        answered = (output.get("worker") or {}).get("gitSha")
        if answered == git_sha[:12]:
            return output
        say(f"selftest {attempt}/{tries}: answered by an older worker ({answered}); retrying while it drains")
        sleep(60)
    raise DeployError(f"no worker running {git_sha[:12]} answered the selftest after {tries} tries")


def report_selftest(output: dict) -> None:
    worker = output.get("worker") or {}
    caps = output.get("caps") or {}
    models = output.get("models") or {}
    supported = ", ".join(f"v{v}" for v in output.get("supported") or [])
    say(f"selftest: ok on {worker.get('gpu')} ({worker.get('vramGB')} GB, CUDA {worker.get('cuda')}), "
        f"schema {supported}, cold start {round((output.get('coldStartMs') or 0) / 1000, 1)} s")
    say("models: " + ", ".join(f"{k}={'loaded' if v is True else v}" for k, v in sorted(models.items())))
    say(f"caps: input <= {caps.get('maxInputMB')} MB, audio <= {caps.get('maxAudioS')} s, "
        f"storage hosts configured: {caps.get('hostsConfigured')}")
    if caps and not caps.get("hostsConfigured"):
        raise DeployError("the worker's storage allowlist is empty: every presigned job would fail BAD_URL")


def bench(api: RunPod, endpoint_id: str, *, sleep: Callable[[float], None] = time.sleep,
          clock: Callable[[], float] = time.monotonic) -> dict:
    first = api.runsync(endpoint_id, {"v": 1, "op": "bench", "bench": {"seconds": 240}}, wait_ms=300000)
    reply = wait_for_job(api, endpoint_id, first, deadline_s=1500, sleep=sleep, clock=clock)
    if reply.get("status") != "COMPLETED":
        cancel_unfinished(api, endpoint_id, reply.get("id") or first.get("id"), reply.get("status"))
        raise DeployError(f"bench {reply.get('status')} ({_error_code(reply)})")
    out = reply.get("output") or {}
    stages = out.get("stagesMs") or {}
    say("bench (240 s synthetic song): " + ", ".join(f"{k} {round(v / 1000, 1)} s" for k, v in stages.items()
                                                    if k.isalpha() and isinstance(v, (int, float))))
    say(f"bench: lazy loads {out.get('lazyLoadMs')}, peak VRAM {out.get('vramPeakMB')} MB on "
        f"{(out.get('worker') or {}).get('gpu')}")
    return out


def concurrency_check(api: RunPod, endpoint_id: str, *, jobs: int = 3, poll_s: float = 5, timeout_s: float = 1800,
                      sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> int:
    """W1: queue `jobs` short bench jobs at once and record the peak number of running workers."""
    ids = [api.run(endpoint_id, {"v": 1, "op": "bench", "bench": {"seconds": 60, "stages": ["separate"]}}).get("id")
           for _ in range(jobs)]
    peak_running = peak_total = 0
    end = clock() + timeout_s
    pending = {i for i in ids if i}
    while pending and clock() < end:
        summary = (api.workers(endpoint_id) or {}).get("summary") or {}
        peak_running = max(peak_running, int(summary.get("running") or 0))
        peak_total = max(peak_total, int(summary.get("total") or 0))
        for job_id in list(pending):
            if api.status(endpoint_id, job_id).get("status") in FINAL_STATES:
                pending.discard(job_id)
        if pending:
            sleep(poll_s)
    for job_id in sorted(pending):  # still queued at the timeout
        cancel_unfinished(api, endpoint_id, job_id, None)
    say(f"concurrency (W1): peak running workers {peak_running}, peak allocated {peak_total} (workers.max is 1)"
        + ("" if peak_running <= 1 else " - EXTRA WORKERS: every max-1 cost bound in the design is off"))
    return peak_running


def release_after_jobs(api: RunPod, endpoint_id: str, template: dict, *, strict: bool,
                       sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
                       **kw) -> str | None:
    """The selftest and bench stop their own worker (refresh_worker); this makes sure no idle worker stays behind
    anyway. A failed read is a warning (cloud-worker-reaper looks again within 30 minutes); workers that couldn't
    be put back fail the deploy unless it is already failing (`strict` False), when it is an error line."""
    try:
        current = (api.get_endpoint(endpoint_id) or {}).get("workers") or template["workers"]
        outcome = release_idle(api, endpoint_id, current, template, sleep=sleep, clock=clock, say=say, **kw)
    except ApiError as exc:
        say(f"::warning::idle check after the jobs failed ({exc}); cloud-worker-reaper looks again within 30 minutes")
        return None
    except ReaperError as exc:
        if strict:
            raise DeployError(str(exc)) from None
        say(f"::error::{exc}")
        return None
    if outcome == STILL_THERE:
        say("::warning::a worker stayed idle at max workers 0; cloud-worker-reaper tries again within 30 minutes")
    return outcome


def deploy(api: RunPod | None, *, tag: str, git_sha: str, account_id: str, create: bool, auto: bool,
           run_selftest: bool, run_bench: bool, extra_pools: list[str], template: dict,
           pull_check=ghcr_public, sleep: Callable[[float], None] = time.sleep,
           clock: Callable[[], float] = time.monotonic) -> int:
    if not TAG_RE.match(tag):
        raise DeployError("--tag must be sha-<12 hex digits> (deploys never use latest or main)")
    if api is None:
        if auto:
            say("::notice::RUNPOD_API_KEY is not set; nothing to deploy")
            return 0
        raise DeployError("RUNPOD_API_KEY is not set (GitHub environment 'runpod')")
    name = template["name"]
    current = api.find_endpoint(name)
    if current:
        mask(current.get("id"))
    if current is None and not create:
        if auto:
            say(f"::notice::No endpoint named {name} yet. Run cloud-worker-deploy by hand once (owner step B4).")
            return 0
        raise DeployError(f"no endpoint named {name}; run again with --create")
    image = f"{IMAGE_REPO}:{tag}"
    desired = desired_state(template, image, account_id, extra_pools)
    ok, why = pull_check(image)
    if not ok:
        raise DeployError(f"RunPod can't pull {tag}: {why}. Make the package public (owner step B3).")
    if current is None:
        created = api.create_endpoint(desired)
        endpoint_id = created.get("id")
        mask(endpoint_id)
        say(f"endpoint: created ({name}, image {tag})")
        changed = True
    else:
        endpoint_id = current["id"]
        patch = patch_for(current, desired)
        if patch:
            api.update_endpoint(endpoint_id, patch)
            say(f"endpoint: updated ({', '.join(sorted(patch))}; image {tag})")
        else:
            say(f"endpoint: unchanged (already on {tag})")
        changed = bool(set(patch) & {"image", "env"})
    if not endpoint_id:
        raise DeployError("RunPod did not return an endpoint id")
    if changed and current is not None:
        wait_rollout(api, endpoint_id, sleep=sleep, clock=clock)
    passed = False
    release = run_selftest or run_bench
    try:
        if run_selftest:
            report_selftest(selftest(api, endpoint_id, git_sha, sleep=sleep, clock=clock))
        if run_bench:
            bench(api, endpoint_id, sleep=sleep, clock=clock)
            concurrency_check(api, endpoint_id, sleep=sleep, clock=clock)
        passed = True
    except KeyboardInterrupt:
        # Cancelled (the workflow execs python, so GitHub's SIGINT lands here, with SIGTERM 7.5 s behind it): no
        # time for a minute-long idle check; cloud-worker-reaper looks within 30 minutes.
        release = False
        raise
    finally:
        if release:
            release_after_jobs(api, endpoint_id, template, strict=passed, sleep=sleep, clock=clock)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Create or update the Cloud Studio RunPod endpoint")
    parser.add_argument("--tag", required=True, help="image tag, sha-<12 hex>")
    parser.add_argument("--git-sha", default=os.environ.get("GITHUB_SHA", ""), help="full commit sha of the build")
    parser.add_argument("--endpoint-json", default=str(HERE / "endpoint.json"))
    parser.add_argument("--create", action="store_true", help="create the endpoint when it doesn't exist")
    parser.add_argument("--auto", action="store_true", help="the automatic run after a main build")
    parser.add_argument("--no-selftest", action="store_true")
    parser.add_argument("--bench", action="store_true")
    parser.add_argument("--extra-pools", default="")
    args = parser.parse_args(argv)
    key = os.environ.get("RUNPOD_API_KEY", "").strip()
    git_sha = (args.git_sha or args.tag[len("sha-"):]).lower()
    try:
        template = json.loads(Path(args.endpoint_json).read_text(encoding="utf-8"))
        return deploy(RunPod(key) if key else None, tag=args.tag, git_sha=git_sha,
                      account_id=os.environ.get("R2_ACCOUNT_ID", "").strip().lower(), create=args.create,
                      auto=args.auto, run_selftest=not args.no_selftest, run_bench=args.bench,
                      extra_pools=[p.strip() for p in args.extra_pools.split(",") if p.strip()], template=template)
    except (DeployError, ApiError) as exc:
        say(f"::error::deploy failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
