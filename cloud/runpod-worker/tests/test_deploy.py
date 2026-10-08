"""deploy/: the REST v2 client (retries, safe errors), the desired state and the smallest valid PATCH, the deploy
flow (auto vs by hand, private package, rollout, selftest gitSha), the W1 concurrency check, and the keepalive
(restore only when healthy, spend alarm without printing money). No network: a fake RunPod and a fake opener."""

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
