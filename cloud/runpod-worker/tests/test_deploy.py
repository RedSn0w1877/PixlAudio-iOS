"""deploy/: the REST v2 client (retries, safe errors), the desired state and the smallest valid PATCH, the deploy
flow (auto vs by hand, private package, rollout, selftest gitSha), the W1 concurrency check, the keepalive
(restore only when healthy, spend alarm without printing money), and the idle-worker reaper (alone and after the
deploy's jobs). No network: a fake RunPod and a fake opener."""

import copy
import io
import json
import sys
import urllib.error
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))

import keepalive as K  # noqa: E402
import reaper as RP  # noqa: E402
import runpod_api as R  # noqa: E402
import runpod_deploy as D  # noqa: E402

TEMPLATE = json.loads((ROOT / "deploy" / "endpoint.json").read_text(encoding="utf-8"))
ACCOUNT = "0123456789abcdef0123456789abcdef"
SHA = "abc1234def56" + "0" * 28
TAG = "sha-abc1234def56"


class FakeRunPod:
    def __init__(self, endpoint=None, *, selftest_shas=("abc1234def56",), unhealthy=0, spend=0.0, rollout=(False,),
                 running=(1,)):
        self.endpoint = copy.deepcopy(endpoint)
        self.calls = []
        self.selftest_shas = list(selftest_shas)
        self.unhealthy = unhealthy
        self.spend = spend
        self.rollout = list(rollout)
        self.running = list(running)
        self.jobs = {}

    def find_endpoint(self, name):
        self.calls.append(("find", name))
        return copy.deepcopy(self.endpoint) if self.endpoint and self.endpoint["name"] == name else None

    def create_endpoint(self, body):
        self.calls.append(("create", body))
        self.endpoint = {**copy.deepcopy(body), "id": "ep123456"}
        return {**body, "id": "ep123456"}

    def get_endpoint(self, endpoint_id):
        return copy.deepcopy(self.endpoint)

    def update_endpoint(self, endpoint_id, body):
        self.calls.append(("patch", body))
        for key, value in body.items():
            self.endpoint[key] = copy.deepcopy(value)
        return self.endpoint

    def releases(self, endpoint_id):
        in_progress = self.rollout.pop(0) if len(self.rollout) > 1 else self.rollout[0]
        return {"rollout": {"inProgress": in_progress, "workersOnLatest": 0, "workersTotal": 1, "percentOnLatest": 0}}

    def workers(self, endpoint_id):
        running = self.running.pop(0) if len(self.running) > 1 else self.running[0]
        return {"summary": {"running": running, "idle": 0, "initializing": 0, "throttled": 0,
                            "unhealthy": self.unhealthy, "total": running}}

    def runsync(self, endpoint_id, job_input, wait_ms=300000):
        self.calls.append(("runsync", job_input["op"]))
        if job_input["op"] == "selftest":
            sha = self.selftest_shas.pop(0) if len(self.selftest_shas) > 1 else self.selftest_shas[0]
            if sha == "FAIL":
                return {"id": "j", "status": "FAILED", "error": "INTERNAL: boom https://secret.example/x"}
            return {"id": "j", "status": "COMPLETED", "output": {
                "schema": "pixl.cloudstudio.selftest", "supported": [1], "coldStartMs": 18000,
                "worker": {"gitSha": sha, "gpu": "NVIDIA L4", "vramGB": 22.5, "cuda": "12.8"},
                "models": {"anvuew-bs-roformer-ft1": True}, "caps": {"maxInputMB": 160, "maxAudioS": 900,
                                                                     "hostsConfigured": 1}}}
        return {"id": "b", "status": "IN_PROGRESS"}

    def status(self, endpoint_id, job_id):
        return {"id": job_id, "status": "COMPLETED", "output": {
            "stagesMs": {"decode": 700, "separate": 12000}, "vramPeakMB": 6000, "lazyLoadMs": {},
            "worker": {"gpu": "NVIDIA L4"}}}

    def run(self, endpoint_id, job_input, policy=None):
        job_id = f"r{len(self.jobs)}"
        self.jobs[job_id] = job_input
        return {"id": job_id, "status": "IN_QUEUE"}

    def cancel(self, endpoint_id, job_id):
        self.calls.append(("cancel", job_id))
        return {"id": job_id, "status": "CANCELLED"}

    def health(self, endpoint_id):
        return {"workers": {"idle": 0, "running": 0}}

    def weekly_spend(self, endpoint_id, days=7):
        return self.spend


def deployed():
    body = D.desired_state(TEMPLATE, f"{D.IMAGE_REPO}:{TAG}", ACCOUNT, [])
    return {**body, "id": "ep123456", "gpu": {**body["gpu"], "allowedCudaVersions": []}}


def go(api, **kw):
    args = dict(tag=TAG, git_sha=SHA, account_id=ACCOUNT, create=False, auto=False, run_selftest=True,
                run_bench=False, extra_pools=[], template=TEMPLATE, pull_check=lambda image: (True, ""),
                sleep=lambda s: None)
    args.update(kw)
    return D.deploy(api, **args)


# ---- desired state and PATCH ----------------------------------------------------------------------------

def test_desired_state_pins_the_allowlist_to_the_account():
    body = D.desired_state(TEMPLATE, "img", ACCOUNT, ["ADA_24"])
    assert body["env"]["PIXL_ALLOWED_HOST_SUFFIXES"] == f"{ACCOUNT}.r2.cloudflarestorage.com"
    assert body["env"]["PIXL_MAX_INPUT_MB"] == "160"
    assert body["gpu"]["pools"] == ["AMPERE_16", "AMPERE_24", "ADA_24"]
    assert body["flashboot"] == "FLASHBOOT" and body["workers"] == {"min": 0, "max": 1, "idleTimeout": 10}
    assert "RUNPOD_INIT_TIMEOUT" not in body["env"]  # design 2.4: the override is dropped
    for bad in ("", "not-hex", ACCOUNT.upper()[:31]):
        with pytest.raises(D.DeployError):
            D.desired_state(TEMPLATE, "img", bad, [])
    with pytest.raises(D.DeployError):
        D.desired_state(TEMPLATE, "img", ACCOUNT, ["ada 24; rm"])


def test_patch_is_empty_when_nothing_changed():
    assert D.patch_for(deployed(), D.desired_state(TEMPLATE, f"{D.IMAGE_REPO}:{TAG}", ACCOUNT, [])) == {}


def test_patch_sends_the_complete_env_and_pools_with_exclusions():
    current = deployed()
    current["env"] = {**current["env"], "PIXL_MAX_INPUT_MB": "60", "OLD": "1"}
    current["gpu"]["pools"] = ["AMPERE_24"]
    desired = D.desired_state(TEMPLATE, f"{D.IMAGE_REPO}:sha-0000000000ff", ACCOUNT, [])
    patch = D.patch_for(current, desired)
    assert patch["image"].endswith(":sha-0000000000ff")
    assert patch["env"] == desired["env"]  # whole env, never a diff (a PATCH with env replaces it)
    assert patch["gpu"]["pools"] == ["AMPERE_16", "AMPERE_24"]
    assert patch["gpu"]["excludedTypes"] == ["NVIDIA RTX 2000 Ada Generation"]  # pools alone would clear them
    assert patch["gpu"]["allowedCudaVersions"] == [] and patch["gpu"]["minCudaVersion"] == "12.8"
    assert "workers" not in patch and "type" not in patch


def test_patch_restores_scaled_down_workers_and_refuses_a_type_change():
    current = deployed()
    current["workers"] = {"min": 0, "max": 0, "idleTimeout": 10}
    assert D.patch_for(current, D.desired_state(TEMPLATE, current["image"], ACCOUNT, []))["workers"]["max"] == 1
    current["type"] = "LOAD_BALANCER"
    with pytest.raises(D.DeployError, match="LOAD_BALANCER"):
        D.patch_for(current, D.desired_state(TEMPLATE, current["image"], ACCOUNT, []))


# ---- the deploy flow ------------------------------------------------------------------------------------

def test_auto_deploy_without_key_or_endpoint_is_a_notice(capsys):
    assert go(None, auto=True) == 0
    api = FakeRunPod()
    assert go(api, auto=True) == 0
    assert [c[0] for c in api.calls] == ["find"]
    assert "owner step B4" in capsys.readouterr().out


def test_by_hand_without_endpoint_needs_create():
    with pytest.raises(D.DeployError, match="--create"):
        go(FakeRunPod())
    with pytest.raises(D.DeployError, match="RUNPOD_API_KEY"):
        go(None)


def test_first_deploy_creates_then_selftests(capsys):
    api = FakeRunPod()
    assert go(api, create=True) == 0
    kinds = [c[0] for c in api.calls]
    assert kinds == ["find", "create", "runsync"]
    body = api.calls[1][1]
    assert body["image"] == f"{D.IMAGE_REPO}:{TAG}" and body["type"] == "QUEUE"
    out = capsys.readouterr().out
    assert "endpoint: created" in out and "selftest: ok on NVIDIA L4" in out
    assert "ep123456" not in out  # the endpoint id never reaches the log


def test_private_package_fails_before_touching_the_endpoint():
    api = FakeRunPod(deployed())
    with pytest.raises(D.DeployError, match="owner step B3"):
        go(api, pull_check=lambda image: (False, "the package is private"))
    assert [c[0] for c in api.calls] == ["find"]


def test_update_waits_for_the_rollout_and_retries_until_the_new_build_answers(capsys):
    current = deployed()
    current["image"] = f"{D.IMAGE_REPO}:sha-0000000000aa"
    api = FakeRunPod(current, selftest_shas=("0000000000aa", "abc1234def56"), rollout=(True, False))
    assert go(api) == 0
    assert ("patch", {"image": f"{D.IMAGE_REPO}:{TAG}"}) in api.calls
    assert [c for c in api.calls if c[0] == "runsync"] == [("runsync", "selftest")] * 2
    out = capsys.readouterr().out
    assert "older worker" in out and "rollout: done" in out


def test_selftest_failure_reports_only_the_code():
    with pytest.raises(D.DeployError) as info:
        go(FakeRunPod(deployed(), selftest_shas=("FAIL",)))
    assert "INTERNAL" in str(info.value) and "secret.example" not in str(info.value)


def test_selftest_never_from_this_build_fails():
    with pytest.raises(D.DeployError, match="after 3 tries"):
        go(FakeRunPod(deployed(), selftest_shas=("0000000000aa",)))


def test_bench_and_concurrency_check(capsys):
    api = FakeRunPod(deployed(), running=(1, 2, 1))
    assert go(api, run_bench=True) == 0
    assert len(api.jobs) == 3
    out = capsys.readouterr().out
    assert "bench (240 s synthetic song): decode 0.7 s, separate 12.0 s" in out
    assert "peak running workers 1" in out or "peak running workers 2" in out


class NoGpu(FakeRunPod):
    """Every job stays IN_QUEUE: no GPU free in the pools."""

    def runsync(self, endpoint_id, job_input, wait_ms=300000):
        self.calls.append(("runsync", job_input["op"]))
        return {"id": "q-" + job_input["op"], "status": "IN_QUEUE"}

    def status(self, endpoint_id, job_id):
        return {"id": job_id, "status": "IN_QUEUE"}


def ticking(step=100):
    ticks = iter(range(0, 10 ** 9, step))
    return lambda: next(ticks)


def test_a_selftest_still_queued_at_the_deadline_is_cancelled(capsys):
    api = NoGpu(deployed())
    with pytest.raises(D.DeployError, match="IN_QUEUE"):
        go(api, clock=ticking())
    assert ("cancel", "q-selftest") in api.calls  # otherwise it would start, and bill, whenever a GPU turns up
    assert "cancelled the unfinished job" in capsys.readouterr().out


def test_bench_and_concurrency_jobs_still_queued_are_cancelled():
    api = NoGpu(deployed())
    with pytest.raises(D.DeployError, match="bench IN_QUEUE"):
        D.bench(api, "ep123456", sleep=lambda s: None, clock=ticking())
    assert ("cancel", "q-bench") in api.calls
    api = NoGpu(deployed())
    D.concurrency_check(api, "ep123456", sleep=lambda s: None, clock=ticking(1000))
    assert sorted(c[1] for c in api.calls if c[0] == "cancel") == ["r0", "r1", "r2"]


def test_bad_tags_are_refused():
    for tag in ("latest", "main", "sha-xyz", "sha-ABC1234DEF56"):
        with pytest.raises(D.DeployError):
            go(FakeRunPod(deployed()), tag=tag)


# ---- keepalive ------------------------------------------------------------------------------------------

def scaled_down(max_workers=0):
    endpoint = deployed()
    endpoint["workers"] = {"min": 0, "max": max_workers, "idleTimeout": 10}
    return endpoint


def test_keepalive_restores_an_idle_scale_down(capsys):
    api = FakeRunPod(scaled_down(0))
    assert K.keepalive(api, TEMPLATE, alarm=2.0, last_deploy="success") == 0
    assert ("patch", {"workers": {"min": 0, "max": 1, "idleTimeout": 10}}) in api.calls
    assert "restored to 1" in capsys.readouterr().out


def test_keepalive_never_restores_a_crash_loop():
    api = FakeRunPod(scaled_down(0), unhealthy=2)
    assert K.keepalive(api, TEMPLATE, alarm=2.0, last_deploy="success") == 1
    assert not [c for c in api.calls if c[0] == "patch"]
    api = FakeRunPod(scaled_down(0))
    assert K.keepalive(api, TEMPLATE, alarm=2.0, last_deploy="failure") == 1
    assert not [c for c in api.calls if c[0] == "patch"]


def test_keepalive_treats_a_cancelled_or_timed_out_deploy_like_a_failed_one(capsys):
    # A deploy stopped half way may have PATCHed the image without a selftest ever answering.
    for conclusion in ("cancelled", "timed_out", "startup_failure"):
        api = FakeRunPod(scaled_down(0))
        assert K.keepalive(api, TEMPLATE, alarm=2.0, last_deploy=conclusion) == 1, conclusion
        assert not [c for c in api.calls if c[0] == "patch"], conclusion
        assert f"didn't pass ({conclusion})" in capsys.readouterr().out
    for conclusion in ("success", ""):  # "" = no deploy has run yet
        api = FakeRunPod(scaled_down(0))
        assert K.keepalive(api, TEMPLATE, alarm=2.0, last_deploy=conclusion) == 0, conclusion
        assert [c for c in api.calls if c[0] == "patch"], conclusion


def test_the_keepalive_workflow_ignores_deploy_runs_that_never_ran():
    # A failed or superseded main build still starts a deploy run, whose job is skipped: if the newest such run
    # counted, it would hide the failed deploy before it. (The Docker test stage holds only cloud/runpod-worker.)
    found = [p / ".github" / "workflows" / "cloud-worker-keepalive.yml" for p in ROOT.parents]
    workflow = next((w for w in found if w.is_file()), None)
    if workflow is None:
        pytest.skip("the repository's workflows are not in this checkout")
    text = workflow.read_text(encoding="utf-8")
    assert 'select(.conclusion != "skipped"' in text and "--limit 1 " not in text


def test_keepalive_spend_alarm_never_prints_the_amount(capsys):
    api = FakeRunPod(deployed(), spend=3.1415)
    assert K.keepalive(api, TEMPLATE, alarm=2.0, last_deploy="") == 1
    out = capsys.readouterr().out
    assert "3.14" not in out and "alarm" in out
    assert K.keepalive(FakeRunPod(deployed(), spend=0.5), TEMPLATE, alarm=2.0, last_deploy="") == 0
    assert "0.5" not in capsys.readouterr().out


def test_keepalive_before_setup_succeeds_quietly():
    assert K.keepalive(None, TEMPLATE, alarm=2.0, last_deploy="") == 0
    assert K.keepalive(FakeRunPod(), TEMPLATE, alarm=2.0, last_deploy="") == 0
    assert K.alarm_usd("") == 2.0 and K.alarm_usd("5") == 5.0 and K.alarm_usd("x") == 2.0 and K.alarm_usd("-1") == 2.0


# ---- the HTTP layer -------------------------------------------------------------------------------------

class Resp(io.BytesIO):
    def __init__(self, status, body=b"", headers=None):
        super().__init__(body)
        self.status = status
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(status, body=b"", headers=None):
    return urllib.error.HTTPError("https://api.runpod.io/x", status, "err", headers or {}, io.BytesIO(body))


def test_http_retries_429_with_retry_after_then_succeeds():
    script = [http_error(429, b'{"title":"Too Many Requests"}', {"Retry-After": "7"}), Resp(200, b'{"ok": true}')]
    slept = []

    def opener(req, timeout):
        step = script.pop(0)
        if isinstance(step, Exception):
            raise step
        return step

    http = R.Http(opener=opener, sleep=slept.append)
    assert http.request("GET", "https://api.runpod.io/v2/serverless", what="GET").body == {"ok": True}
    assert slept == [7.0]


def test_http_errors_are_safe_to_print():
    def opener(req, timeout):
        raise http_error(401, b'{"title":"Unauthorized <script>","detail":"key rp_SECRET is invalid"}')

    with pytest.raises(R.ApiError) as info:
        R.Http(opener=opener, sleep=lambda s: None).request("GET", "https://x", what="GET /v2/serverless")
    message = str(info.value)
    assert message.startswith("GET /v2/serverless: HTTP 401") and "SECRET" not in message and "<" not in message


def test_client_sends_the_key_only_as_a_bearer_header():
    seen = []

    def opener(req, timeout):
        seen.append((req.full_url, dict(req.header_items())))
        return Resp(200, b'{"endpoints": [{"id": "e1", "name": "pixl-cloud-studio"}], '
                         b'"pagination": {"nextCursor": null, "hasNextPage": false}}')

    api = R.RunPod("rp_KEY", R.Http(opener=opener, sleep=lambda s: None))
    assert api.find_endpoint("pixl-cloud-studio")["id"] == "e1"
    url, headers = seen[0]
    assert url == "https://api.runpod.io/v2/serverless?limit=1000" and "rp_KEY" not in url
    assert headers["Authorization"] == "Bearer rp_KEY"


def test_weekly_spend_uses_the_totals():
    def opener(req, timeout):
        assert "serverlessId=e1" in req.full_url and "bucketSize=day" in req.full_url and "lastN=7" in req.full_url
        return Resp(200, b'{"records": [{"totalAmount": 0.25}], "metadata": {"totals": {"totalAmount": 0.75}}}')

    assert R.RunPod("k", R.Http(opener=opener)).weekly_spend("e1") == 0.75


def test_ghcr_public_check():
    def make(status):
        def opener(req, timeout):
            if "/token" in req.full_url:
                return Resp(200, b'{"token": "anon"}')
            assert req.get_method() == "HEAD" and req.headers["Authorization"] == "Bearer anon"
            if status == 200:
                return Resp(200)
            raise http_error(status)
        return R.Http(opener=opener, sleep=lambda s: None, tries=1)

    assert R.ghcr_public(f"{D.IMAGE_REPO}:{TAG}", make(200)) == (True, "")
    assert R.ghcr_public(f"{D.IMAGE_REPO}:{TAG}", make(401)) == (False, "the package is private")
    assert R.ghcr_public(f"{D.IMAGE_REPO}:{TAG}", make(404)) == (False, "the tag does not exist")
    assert R.ghcr_public("docker.io/x:y")[0] is False


def test_mask_only_inside_actions(capsys, monkeypatch):
    monkeypatch.delenv("GITHUB_ACTIONS", raising=False)
    R.mask("ep1")
    assert capsys.readouterr().out == ""
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    R.mask("ep1")
    assert capsys.readouterr().out == "::add-mask::ep1\n"


# ---- the idle-worker reaper -----------------------------------------------------------------------------

IDLE = {"jobs": {"completed": 1, "failed": 0, "inProgress": 0, "inQueue": 0, "retried": 0},
        "workers": {"idle": 1, "initializing": 0, "ready": 1, "running": 0, "throttled": 0, "unhealthy": 0}}
GONE = {"jobs": {"completed": 1, "failed": 0, "inProgress": 0, "inQueue": 0, "retried": 0},
        "workers": {"idle": 0, "initializing": 0, "ready": 0, "running": 0, "throttled": 0, "unhealthy": 0}}


def health(*, idle=0, ready=0, running=0, initializing=0, in_queue=0, in_progress=0):
    return {"jobs": {"inQueue": in_queue, "inProgress": in_progress, "completed": 3},
            "workers": {"idle": idle, "ready": ready, "running": running, "initializing": initializing}}


class Clock:
    """Time moves only when the code sleeps."""

    def __init__(self):
        self.now = 0.0
        self.slept = []

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds

    def __call__(self):
        return self.now


class Reaped(FakeRunPod):
    """/health answers from a script (the last answer repeats; an exception is raised); PATCHes can be made to fail."""

    def __init__(self, endpoint, script, *, fail_patch=()):
        super().__init__(endpoint)
        self.script = list(script)
        self.fail_patch = set(fail_patch)  # indexes of PATCH calls that fail
        self.patches = 0

    def health(self, endpoint_id):
        self.calls.append(("health",))
        step = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        if isinstance(step, Exception):
            raise step
        return copy.deepcopy(step)

    def update_endpoint(self, endpoint_id, body):
        index, self.patches = self.patches, self.patches + 1
        if index in self.fail_patch:
            self.calls.append(("patch-failed", body))
            raise R.ApiError("PATCH /v2/serverless/{id}", 503, "Service Unavailable")
        return super().update_endpoint(endpoint_id, body)


def patches(api):
    return [c[1] for c in api.calls if c[0] == "patch"]


ZERO = {"workers": {"min": 0, "max": 0, "idleTimeout": 10}}
BACK = {"workers": {"min": 0, "max": 1, "idleTimeout": 10}}


def release(api, clock=None, template=TEMPLATE):
    clock = clock or Clock()
    return RP.release_idle(api, "ep123456", (api.endpoint or {}).get("workers") or {}, template,
                           sleep=clock.sleep, clock=clock)


def test_reaper_releases_a_worker_idle_on_both_reads_and_puts_max_back(capsys):
    api = Reaped(deployed(), [IDLE, IDLE, IDLE, GONE])
    clock = Clock()
    assert release(api, clock) == RP.RELEASED
    assert patches(api) == [ZERO, BACK]
    assert clock.slept[0] == RP.CONFIRM_S  # the two reads are a minute apart
    assert api.endpoint["workers"] == {"min": 0, "max": 1, "idleTimeout": 10}
    out = capsys.readouterr().out
    assert "idle worker is gone after 20 s" in out and "max workers back to 1" in out
    assert "ep123456" not in out and "$" not in out


@pytest.mark.parametrize("second", [
    health(idle=1, running=1),          # it picked up a job
    health(idle=1, in_queue=1),         # a job is waiting for it
    health(ready=1, in_progress=1),
    GONE,                               # it left on its own (refresh_worker, idleTimeout)
])
def test_reaper_leaves_a_worker_that_isnt_idle_on_the_second_read(second):
    api = Reaped(deployed(), [IDLE, second])
    assert release(api) == RP.NOTHING_IDLE
    assert patches(api) == []


@pytest.mark.parametrize("first", [GONE, health(running=1, in_progress=1), health(idle=1, in_queue=2),
                                   health(initializing=1, in_queue=1), {}, None])
def test_reaper_does_nothing_without_an_idle_worker(first):
    api = Reaped(deployed(), [first])
    clock = Clock()
    assert release(api, clock) == RP.NOTHING_IDLE
    assert patches(api) == [] and clock.slept == []  # no second read: nothing to confirm


def test_reaper_counts_only_idle_or_ready_workers_with_nothing_to_do():
    assert RP.stranded(RP.counts(IDLE)) and RP.stranded(RP.counts(health(ready=1)))
    assert RP.stranded(RP.counts(health(idle=1)))
    assert not RP.stranded(RP.counts(health(idle=1, running=1)))
    assert not RP.stranded(RP.counts({"workers": {"idle": True}}))  # not a count
    assert RP.counts({"jobs": "x", "workers": None}) == RP.counts({})
    assert RP.gone(RP.counts(GONE)) and not RP.gone(RP.counts(health(initializing=1)))


def test_reaper_restores_at_once_when_a_job_arrives_at_max_0():
    api = Reaped(deployed(), [IDLE, IDLE, health(idle=1, in_queue=1)])
    clock = Clock()
    assert release(api, clock) == RP.JOB_ARRIVED
    assert patches(api) == [ZERO, BACK]
    assert clock.now == RP.CONFIRM_S + RP.POLL_S  # the job waited one poll, not the 2 minutes


def test_reaper_gives_up_after_two_minutes_but_always_restores(capsys):
    api = Reaped(deployed(), [IDLE])  # the worker never leaves
    clock = Clock()
    assert release(api, clock) == RP.STILL_THERE
    assert patches(api) == [ZERO, BACK]
    assert clock.now - RP.CONFIRM_S == RP.GONE_TIMEOUT_S
    assert "::warning::" in capsys.readouterr().out


def test_reaper_restores_when_health_fails_while_waiting():
    api = Reaped(deployed(), [IDLE, IDLE, R.ApiError("GET /health", 502, "Bad Gateway")])
    assert release(api) == RP.UNKNOWN
    assert patches(api) == [ZERO, BACK]


def test_reaper_leaves_a_switched_off_endpoint_alone():
    endpoint = deployed()
    endpoint["workers"] = {"min": 0, "max": 0, "idleTimeout": 10}
    api = Reaped(endpoint, [IDLE])
    assert release(api) == RP.OFF
    assert api.calls == []  # not even a /health read


def test_reaper_without_max_workers_in_the_answer_changes_nothing(capsys):
    for workers in ({}, {"min": 0}, {"max": True}, {"max": "1"}):
        endpoint = deployed()
        endpoint["workers"] = workers
        api = Reaped(endpoint, [IDLE])
        assert release(api) == RP.NO_MAX, workers
        assert api.calls == []
    assert "::warning::" in capsys.readouterr().out


def test_reaper_never_raises_max_above_what_it_found_or_endpoint_json():
    template = copy.deepcopy(TEMPLATE)
    template["workers"]["max"] = 3
    api = Reaped(deployed(), [IDLE, IDLE, GONE])  # found max 1
    assert release(api, template=template) == RP.RELEASED
    assert patches(api)[-1] == BACK
    endpoint = deployed()
    endpoint["workers"] = {"min": 0, "max": 2, "idleTimeout": 10}  # raised by hand above endpoint.json's 1
    api = Reaped(endpoint, [IDLE, IDLE, GONE])
    assert release(api) == RP.RELEASED
    assert patches(api)[-1] == BACK


def test_reaper_a_failed_restore_fails_loudly():
    api = Reaped(deployed(), [IDLE, IDLE, GONE], fail_patch={1})
    with pytest.raises(RP.ReaperError, match="back to 1"):
        release(api)
    assert patches(api) == [ZERO]


def test_reaper_a_failed_patch_to_0_still_restores_then_fails():
    # The PATCH may have been applied before the connection dropped, so the restore runs anyway.
    api = Reaped(deployed(), [IDLE, IDLE, GONE], fail_patch={0})
    with pytest.raises(RP.ReaperError, match="to 0"):
        release(api)
    assert patches(api) == [BACK]
    assert [c for c in api.calls if c[0] == "health"] == [("health",)] * 2  # no waiting without the PATCH


def test_reap_before_setup_succeeds_quietly(capsys):
    assert RP.reap(None, TEMPLATE) == 0
    assert RP.reap(FakeRunPod(), TEMPLATE) == 0
    out = capsys.readouterr().out
    assert "::" not in out and "nothing to do" in out


def test_reap_treats_a_failed_read_as_a_warning_and_changes_nothing(capsys):
    class Down(FakeRunPod):
        def find_endpoint(self, name):
            raise R.ApiError("GET /v2/serverless", 503, "Service Unavailable")

    assert RP.reap(Down(), TEMPLATE) == 0
    api = Reaped(deployed(), [R.ApiError("GET /health", 502, "")])
    assert RP.reap(api, TEMPLATE) == 0
    assert patches(api) == []
    assert capsys.readouterr().out.count("::warning::") == 2


def test_reap_masks_the_endpoint_id_first_and_fails_when_the_worker_stays(capsys, monkeypatch):
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    clock = Clock()
    api = Reaped(deployed(), [IDLE])
    assert RP.reap(api, TEMPLATE, sleep=clock.sleep, clock=clock) == 1
    out = capsys.readouterr().out
    assert out.startswith("::add-mask::ep123456\n") and out.count("ep123456") == 1
    assert "::error::" in out
    clock = Clock()
    assert RP.reap(Reaped(deployed(), [IDLE, IDLE, GONE]), TEMPLATE, sleep=clock.sleep, clock=clock) == 0


def test_reaper_main_without_a_key_succeeds(monkeypatch, capsys):
    monkeypatch.delenv("RUNPOD_API_KEY", raising=False)
    assert RP.main() == 0
    assert "::" not in capsys.readouterr().out


def test_deploy_releases_an_idle_worker_left_by_its_selftest(capsys):
    api = Reaped(deployed(), [IDLE, IDLE, GONE])
    assert go(api) == 0
    assert patches(api) == [ZERO, BACK]
    kinds = [c[0] for c in api.calls]
    assert kinds.index("runsync") < kinds.index("health")  # after the selftest, never before
    assert "idle worker is gone" in capsys.readouterr().out


def test_deploy_without_jobs_doesnt_look_for_idle_workers():
    api = Reaped(deployed(), [IDLE])
    assert go(api, run_selftest=False) == 0
    assert ("health",) not in api.calls


def test_deploy_after_a_failed_selftest_still_releases_and_keeps_its_own_error(capsys):
    api = Reaped(deployed(), [IDLE, IDLE, GONE], fail_patch={1})
    api.selftest_shas = ["FAIL"]
    with pytest.raises(D.DeployError, match="selftest FAILED"):
        go(api)
    out = capsys.readouterr().out
    assert "::error::couldn't set max workers back to 1" in out


def test_deploy_fails_when_the_workers_cant_be_put_back():
    api = Reaped(deployed(), [IDLE, IDLE, GONE], fail_patch={1})
    with pytest.raises(D.DeployError, match="back to 1"):
        go(api)


def test_deploy_only_warns_when_the_idle_check_cant_read_health(capsys):
    api = Reaped(deployed(), [R.ApiError("GET /health", 502, "")])
    assert go(api) == 0
    assert "::warning::idle check after the jobs failed" in capsys.readouterr().out


def test_the_reaper_workflow_runs_every_30_minutes_in_the_runpod_environment():
    found = [p / ".github" / "workflows" / "cloud-worker-reaper.yml" for p in ROOT.parents]
    workflow = next((w for w in found if w.is_file()), None)
    if workflow is None:
        pytest.skip("the repository's workflows are not in this checkout")
    text = workflow.read_text(encoding="utf-8")
    assert "cron: '7,37 * * * *'" in text and "workflow_dispatch" in text
    assert "environment: runpod" in text and "contents: read" in text
    assert "python3 cloud/runpod-worker/deploy/reaper.py" in text
    for line in text.splitlines():
        if "uses:" in line:
            ref = line.split("@", 1)[1].split()[0]
            assert len(ref) == 40 and all(ch in "0123456789abcdef" for ch in ref), line  # pinned to a commit
