"""deploy/e2e.py (cloud-e2e.yml): the SigV4 port against AWS's example, the /run body against the worker's own schema
and validator, the clip (FLAC header length, --clip), the manifest checks, the idle check and release, the whole flow
with fakes (cleanup on every path, nothing secret printed), the clear failures before anything is sent, and, where
`cryptography` is installed (not in the test image), opening the blob. No network.
"""

import base64
import hashlib
import io
import json
import sys
import urllib.error
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))

import e2e as E  # noqa: E402
from conftest import EXAMPLE_HOST, load_schema  # noqa: E402

TEMPLATE = json.loads((ROOT / "deploy" / "endpoint.json").read_text(encoding="utf-8"))
ACCOUNT = EXAMPLE_HOST.split(".")[0]
KEYS = E.Keys(endpoint_id="dummyendpoint01", runpod_key="rpa_DUMMYKEY0000", r2_endpoint=f"https://{EXAMPLE_HOST}",
              bucket="pixl-cloud-studio", access_key_id="DUMMYACCESSKEYID", secret_access_key="dummy-secret-0000")
SECRETS = ("rpa_DUMMYKEY0000", "DUMMYACCESSKEYID", "dummy-secret-0000", "dummyendpoint01")
JOB_KEY = "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10"


# ---- SigV4 ---------------------------------------------------------------------------------------------------------

def test_presign_matches_the_aws_example():
    aws = E.Keys(endpoint_id="x", runpod_key="x", r2_endpoint="https://s3.amazonaws.com", bucket="examplebucket",
                 access_key_id="AKIAIOSFODNN7EXAMPLE", secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    url = E.presign("GET", "test.txt", keys=aws, expires_s=86_400, now_s=1_369_353_600, region="us-east-1",
                    virtual_hosted=True)
    assert url == ("https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                   "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
                   "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
                   "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")


def test_r2_urls_are_path_style_with_region_auto_and_carry_no_secret():
    url = E.presign("PUT", f"in/{JOB_KEY}.flac", keys=KEYS, expires_s=7200, now_s=1_369_353_600)
    assert url.startswith(f"https://{EXAMPLE_HOST}/pixl-cloud-studio/in/{JOB_KEY}.flac?")
    assert "X-Amz-Credential=DUMMYACCESSKEYID%2F20130524%2Fauto%2Fs3%2Faws4_request" in url
    assert "X-Amz-Expires=7200" in url and "dummy-secret" not in url
    assert E.presign("GET", "a", keys=KEYS, expires_s=10**9, now_s=0).count("X-Amz-Expires=604800") == 1


def test_endpoint_normalisation_matches_the_app():
    assert E.normalized_endpoint(ACCOUNT) == f"https://{ACCOUNT}.r2.cloudflarestorage.com"
    assert E.normalized_endpoint(f"https://{EXAMPLE_HOST}/pixl-cloud-studio") == f"https://{EXAMPLE_HOST}"
    for bad in ("http://example.com", "", "not a host"):
        with pytest.raises(E.E2EError):
            E.normalized_endpoint(bad)


def test_keys_never_show_their_values():
    for text in (repr(KEYS), str(KEYS), f"{KEYS}"):
        assert not any(secret in text for secret in SECRETS)


# ---- the job -------------------------------------------------------------------------------------------------------

def test_the_job_passes_the_workers_schema_and_validator(caps):
    jsonschema = pytest.importorskip("jsonschema")
    from pixl_worker.schema import validate_job

    job_input, policy = E.build_job(E.R2(KEYS), JOB_KEY, size=1_288_578, sha256="ab" * 32, duration_ms=20_000,
                                    build="e2e abc1234def56")
    jsonschema.validate(job_input, load_schema("job.input"))
    job = validate_job(job_input, caps)
    assert job.op == "process" and job.job_key == JOB_KEY
    assert job_input["policy"] == {"last_in_batch": True}
    assert job_input["tasks"] == ["instrumental"]
    assert set(job_input["output"]["put"]) == {"instrumental", "manifest"}
    assert policy == {"ttl": 3_600_000, "executionTimeout": 900_000}


def manifest(sha="ab" * 32, **over):
    doc = {"schema": "pixl.cloudstudio.result", "v": 1, "jobKey": JOB_KEY, "status": "ok", "error": None,
           "input": {"sha256": sha}, "worker": {"gpu": "NVIDIA L4"},
           "outputs": {"instrumental": {"key": f"out/{JOB_KEY}/instrumental.m4a", "bytes": 640_000,
                                        "sha256": "cd" * 32, "codec": "aac", "kbps": 256, "sampleRate": 44_100,
                                        "samples": 882_000}},
           "timings": {"coldStartMs": 18_400, "separateMs": 9_100, "totalMs": 12_000}}
    doc.update(over)
    return doc


def test_manifest_checks():
    assert E.check_manifest(manifest(), job_key=JOB_KEY, sha256="ab" * 32, seconds=20)["bytes"] == 640_000
    bad = [
        manifest(status="error", error={"code": "GPU_OOM"}),
        manifest(jobKey="6f1c2a9e-3b7d-4c11-9a0e-000000000000"),
        manifest(sha="ef" * 32),
        manifest(outputs={}),
        manifest(outputs={"instrumental": {**manifest()["outputs"]["instrumental"], "bytes": 100}}),
        manifest(outputs={"instrumental": {**manifest()["outputs"]["instrumental"], "samples": 441_000}}),
        manifest(outputs={"instrumental": {**manifest()["outputs"]["instrumental"], "key": "out/other/x.m4a"}}),
    ]
    for doc in bad:
        with pytest.raises(E.E2EError):
            E.check_manifest(doc, job_key=JOB_KEY, sha256="ab" * 32, seconds=20)


def streaminfo(rate=44_100, samples=882_000, body=b"\x01" * 50_000):
    """A FLAC file's start: the magic, a last-block STREAMINFO header and its 34 bytes (stereo, 16-bit)."""
    info = bytearray(34)
    info[10] = (rate >> 12) & 0xFF
    info[11] = (rate >> 4) & 0xFF
    info[12] = ((rate & 0x0F) << 4) | (1 << 1) | 0  # 2 channels, bits-per-sample high bit 0
    info[13] = (15 << 4) | ((samples >> 32) & 0x0F)  # 16 bits per sample
    info[14:18] = (samples & 0xFFFFFFFF).to_bytes(4, "big")
    return b"fLaC" + bytes([0x80, 0, 0, 34]) + bytes(info) + body


def test_flac_length_reads_streaminfo():
    assert E.flac_length(streaminfo()) == (44_100, 882_000)
    assert E.flac_length(streaminfo(rate=48_000, samples=(1 << 33) + 5)) == (48_000, (1 << 33) + 5)
    for bad in (b"", b"RIFF" + streaminfo()[4:], streaminfo(samples=100), b"fLaC" + b"\x04" + streaminfo()[5:]):
        with pytest.raises(E.E2EError):
            E.flac_length(bad)


def test_make_clip_is_flac_44k_stereo(tmp_path):
    if not __import__("shutil").which("ffmpeg"):
        pytest.skip("ffmpeg not installed")
    path = tmp_path / "clip.flac"
    E.make_clip(path, 2)
    data = path.read_bytes()
    rate, total = E.flac_length(data)
    assert rate == 44_100 and abs(total - 88_200) < 4_608
    # --clip: the first seconds of another file, converted the same way.
    cut = tmp_path / "cut.flac"
    E.make_clip(cut, 1, source=path)
    rate, total = E.flac_length(cut.read_bytes())
    assert rate == 44_100 and abs(total - 44_100) < 4_608


def test_clip_sources(tmp_path, monkeypatch, capsys):
    local = tmp_path / "song.wav"
    local.write_bytes(b"RIFF")
    assert E.fetch_clip(str(local), tmp_path) == local
    with pytest.raises(E.E2EError, match="no such file"):
        E.fetch_clip(str(tmp_path / "missing.wav"), tmp_path)

    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    url = "https://example.com/clip.m4a?token=SECRET0TOKEN"
    got = E.fetch_clip(url, tmp_path, opener=lambda req, timeout=None: Resp(200, b"\x00" * 2_000_000))
    assert got.read_bytes() == b"\x00" * 2_000_000
    out = capsys.readouterr().out
    assert f"::add-mask::{url}" in out and out.replace(f"::add-mask::{url}", "").count("SECRET0TOKEN") == 0

    monkeypatch.setattr(E, "CLIP_DOWNLOAD_MAX", 1_000)
    with pytest.raises(E.E2EError, match="over"):
        E.fetch_clip(url, tmp_path, opener=lambda req, timeout=None: Resp(200, b"\x00" * 5_000))

    def refused(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, io.BytesIO(b""))

    with pytest.raises(E.E2EError, match="HTTP 403") as info:
        E.fetch_clip(url, tmp_path, opener=refused)
    assert "SECRET0TOKEN" not in str(info.value)


# ---- fakes ---------------------------------------------------------------------------------------------------------

class FakeBucket:
    """R2 behind presigned URLs: checks each URL is presigned for the right method and object."""

    def __init__(self, *, instrumental=b"\x00" * 640_000, manifest_doc=None, put_fails=False):
        self.objects, self.log = {}, []
        self.instrumental, self.manifest_doc, self.put_fails = instrumental, manifest_doc, put_fails

    def __call__(self, req, timeout=None):
        url = req.full_url
        assert url.startswith(f"https://{EXAMPLE_HOST}/pixl-cloud-studio/") and "X-Amz-Signature=" in url
        key = url.split("/pixl-cloud-studio/", 1)[1].split("?", 1)[0]
        self.log.append((req.get_method(), key))
        if req.get_method() == "PUT":
            if self.put_fails:
                raise urllib.error.HTTPError(url, 403, "Forbidden", {}, io.BytesIO(b""))
            self.objects[key] = req.data
            return Resp(200)
        if req.get_method() == "DELETE":
            self.objects.pop(key, None)
            return Resp(204)
        if key.endswith("manifest.json"):
            # The worker writes the manifest for the job that asked (e2e.py makes a new jobKey every run).
            job = key.split("/")[1]
            return Resp(200, json.dumps(self.manifest_doc).replace(JOB_KEY, job).encode())
        if key.endswith("instrumental.m4a"):
            return Resp(200, self.instrumental)
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, io.BytesIO(b""))


class Resp:
    def __init__(self, status, body=b""):
        self.status, self.body = status, body

    def read(self, size=-1):
        if size is None or size < 0:
            body, self.body = self.body, b""
            return body
        chunk, self.body = self.body[:size], self.body[size:]
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeApi:
    def __init__(self, *, final="COMPLETED", output=None, health=None):
        self.final, self.output = final, output or {}
        self.health_seq = list(health or [{"workers": {"idle": 0, "ready": 0}}])
        self.calls, self.runs, self.patches = [], [], []
        self.endpoint = {"workers": {"min": 0, "max": 1, "idleTimeout": 10}}

    def run(self, endpoint_id, job_input, policy=None):
        self.runs.append((job_input, policy))
        return {"id": "job-1", "status": "IN_QUEUE"}

    def status(self, endpoint_id, job_id):
        return {"id": job_id, "status": self.final, "output": self.output}

    def cancel(self, endpoint_id, job_id):
        self.calls.append("cancel")
        return {}

    def health(self, endpoint_id):
        return self.health_seq.pop(0) if len(self.health_seq) > 1 else self.health_seq[0]

    def get_endpoint(self, endpoint_id):
        return self.endpoint

    def update_endpoint(self, endpoint_id, body):
        self.patches.append(body["workers"]["max"])
        if body["workers"]["max"] == 0:
            self.health_seq = [{"workers": {"idle": 0, "ready": 0}}]
        return self.endpoint


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.t += s


CLIP = streaminfo()


def fake_clip(path, seconds):
    path.write_bytes(CLIP)


def run_flow(tmp_path, *, api, bucket, admin=None):
    clock = Clock()
    return E.run(KEYS, api=api, admin=admin, r2=E.R2(KEYS, opener=bucket, sleep=clock.sleep), template=TEMPLATE,
                 workdir=tmp_path, seconds=20, build="e2e test", sleep=clock.sleep, clock=clock, clip=fake_clip)


def good_bucket():
    audio = b"\x07" * 640_000
    clip_sha = hashlib.sha256(CLIP).hexdigest()
    doc = manifest(sha=clip_sha)
    doc["outputs"]["instrumental"]["sha256"] = hashlib.sha256(audio).hexdigest()
    return FakeBucket(instrumental=audio, manifest_doc=doc), doc


# ---- the flow ------------------------------------------------------------------------------------------------------

def test_a_good_run_passes_cleans_up_and_prints_nothing_secret(tmp_path, capsys):
    bucket, doc = good_bucket()
    api = FakeApi(output=doc)
    assert run_flow(tmp_path, api=api, bucket=bucket) == 0
    out = capsys.readouterr().out
    assert "cloud e2e PASSED" in out and "NVIDIA L4" in out
    assert not any(secret in out for secret in SECRETS) and "X-Amz" not in out and EXAMPLE_HOST not in out
    job_input, _ = api.runs[0]
    assert job_input["policy"] == {"last_in_batch": True}
    assert bucket.objects == {}, "every object is deleted"
    deleted = {key for method, key in bucket.log if method == "DELETE"}
    assert deleted == set(E.job_keys(job_input["jobKey"]).values())
    assert api.patches == [], "the worker stopped itself: nothing to release"


def test_a_failed_job_still_cleans_up(tmp_path, capsys):
    bucket, _ = good_bucket()
    api = FakeApi(final="FAILED")
    assert run_flow(tmp_path, api=api, bucket=bucket) == 1
    assert "FAILED" in capsys.readouterr().out
    assert bucket.objects == {}
    assert "cancel" not in api.calls, "a FAILED job is final: nothing to cancel"


def test_a_job_still_queued_at_the_deadline_is_cancelled(tmp_path):
    bucket, _ = good_bucket()
    api = FakeApi(final="IN_QUEUE")
    assert run_flow(tmp_path, api=api, bucket=bucket) == 1
    assert api.calls == ["cancel"]
    assert bucket.objects == {}


def test_an_upload_refused_sends_no_job(tmp_path, capsys):
    bucket = FakeBucket(put_fails=True)
    api = FakeApi()
    assert run_flow(tmp_path, api=api, bucket=bucket) == 1
    assert "upload (R2 PUT): HTTP 403" in capsys.readouterr().out
    assert api.runs == []


def test_a_lingering_idle_worker_is_released_and_warned_about(tmp_path, capsys):
    bucket, doc = good_bucket()
    idle = {"workers": {"idle": 1, "ready": 1, "running": 0}, "jobs": {"inQueue": 0, "inProgress": 0}}
    api = FakeApi(output=doc, health=[idle] * 40)
    assert run_flow(tmp_path, api=api, bucket=bucket, admin=api) == 0
    out = capsys.readouterr().out
    assert "last_in_batch didn't stop it" in out
    assert api.patches == [0, 1], "max workers 0, then back to 1"


def test_without_the_admin_key_a_lingering_worker_fails_the_run(tmp_path):
    bucket, doc = good_bucket()
    idle = {"workers": {"idle": 1, "ready": 0, "running": 0}, "jobs": {"inQueue": 0, "inProgress": 0}}
    api = FakeApi(output=doc, health=[idle] * 40)
    assert run_flow(tmp_path, api=api, bucket=bucket, admin=None) == 1


def test_the_jobs_own_worker_winding_down_is_waited_for(tmp_path):
    bucket, doc = good_bucket()
    winding = {"workers": {"idle": 0, "ready": 0, "running": 1}, "jobs": {"inQueue": 0, "inProgress": 0}}
    api = FakeApi(output=doc, health=[winding, winding, {"workers": {"idle": 0, "ready": 0, "running": 0}}])
    assert run_flow(tmp_path, api=api, bucket=bucket, admin=api) == 0
    assert api.patches == [] and api.health_seq == [{"workers": {"idle": 0, "ready": 0, "running": 0}}]


def test_the_job_is_sent_with_the_clips_real_length(tmp_path):
    bucket, doc = good_bucket()
    api = FakeApi(output=doc)
    assert run_flow(tmp_path, api=api, bucket=bucket) == 0
    job_input, _ = api.runs[0]
    assert job_input["audio"]["durationMs"] == 20_000
    assert job_input["audio"]["bytes"] == len(CLIP)
    assert bucket.log[0][0] == "PUT" and bucket.log[0][1].startswith("in/")


def test_other_jobs_on_the_endpoint_are_left_alone(tmp_path):
    bucket, doc = good_bucket()
    busy = {"workers": {"idle": 1, "ready": 0, "running": 1}, "jobs": {"inQueue": 2, "inProgress": 1}}
    api = FakeApi(output=doc, health=[busy])
    assert run_flow(tmp_path, api=api, bucket=bucket, admin=api) == 0
    assert api.patches == []


# ---- clear failures before anything is sent ------------------------------------------------------------------------

def test_without_the_secret_it_says_what_to_do(monkeypatch, capsys):
    monkeypatch.delenv("CLOUD_DEFAULTS_KEY", raising=False)
    assert E.main([]) == 1
    out = capsys.readouterr().out
    assert "CLOUD_DEFAULTS_KEY secret is not set" in out and "bake-cloud-keys.mjs" in out


def test_a_bad_or_placeholder_key_stops_before_anything_is_sent(monkeypatch, capsys, tmp_path):
    blob = tmp_path / "CloudDefaults.enc"
    blob.write_bytes(b"PXCD1" + b"\x00" * 60)
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", "not base64!")
    assert E.main(["--blob", str(blob)]) == 1
    assert "not base64" in capsys.readouterr().out
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", base64.b64encode(bytes(16)).decode())
    assert E.main(["--blob", str(blob)]) == 1
    assert "not 32 bytes" in capsys.readouterr().out
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", E.PLACEHOLDER_KEY)
    assert E.main(["--blob", str(blob)]) == 1
    assert "public placeholder key" in capsys.readouterr().out
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", base64.b64encode(bytes(range(32))).decode())
    assert E.main(["--blob", str(tmp_path / "missing.enc")]) == 1
    assert "could not be read" in capsys.readouterr().out


def test_the_repository_root_resolves_inside_the_test_image_too():
    # In the worker's test image this file is /t/deploy/e2e.py (no repository around it): importing must not fail.
    assert E.DEFAULT_BLOB.name == "CloudDefaults.enc"


# ---- the blob (needs `cryptography`, which cloud-e2e.yml installs; the test image doesn't have it) -----------------

def seal(key: bytes, payload: dict) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    nonce = b"\x01" * 12
    return E.MAGIC + nonce + AESGCM(key).encrypt(nonce, json.dumps(payload).encode(), None)


PAYLOAD = {"v": 1, "runpodEndpointId": "dummyendpoint01", "runpodKey": "rpa_DUMMYKEY0000",
           "r2Endpoint": ACCOUNT, "bucket": "pixl-cloud-studio", "r2AccessKeyId": "DUMMYACCESSKEYID",
           "r2SecretAccessKey": "dummy-secret-0000"}


def test_open_blob_round_trip_and_failures(monkeypatch, capsys):
    pytest.importorskip("cryptography")
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    key = bytes(range(32))
    keys = E.open_blob(seal(key, PAYLOAD), key)
    assert keys.r2_endpoint == f"https://{EXAMPLE_HOST}" and keys.endpoint_id == "dummyendpoint01"
    out = capsys.readouterr().out
    for secret in SECRETS + (ACCOUNT,):
        assert f"::add-mask::{secret}" in out, "every value is masked before use"
    with pytest.raises(E.E2EError, match="doesn't open"):
        E.open_blob(seal(key, PAYLOAD), bytes(32))
    tampered = bytearray(seal(key, PAYLOAD))
    tampered[20] ^= 1
    with pytest.raises(E.E2EError):
        E.open_blob(bytes(tampered), key)
    with pytest.raises(E.E2EError, match="empty"):
        E.open_blob(seal(key, {**PAYLOAD, "r2SecretAccessKey": ""}), key)
    with pytest.raises(E.E2EError, match="v1"):
        E.open_blob(seal(key, {**PAYLOAD, "v": 2}), key)
    with pytest.raises(E.E2EError, match="PXCD1"):
        E.open_blob(b"PXCD2" + seal(key, PAYLOAD)[5:], key)


def test_the_committed_placeholder_is_recognised():
    pytest.importorskip("cryptography")
    blob = E.DEFAULT_BLOB
    if not blob.exists():
        pytest.skip("not in the app repository checkout")
    data = blob.read_bytes()
    placeholder = base64.b64decode(E.PLACEHOLDER_KEY)
    try:
        keys = E.open_blob(data, placeholder)
    except E.E2EError:
        pytest.skip("the real blob is baked: it no longer opens with the placeholder key")
    assert keys.endpoint_id == "placeholder0endpoint"
    with pytest.raises(E.E2EError, match="placeholder"):
        E.open_blob(data, bytes(32))


# ---- the workflow ----------------------------------------------------------------------------------------------------

def test_the_workflow_is_manual_in_the_runpod_environment_and_execs_python():
    found = [p / ".github" / "workflows" / "cloud-e2e.yml" for p in ROOT.parents]
    workflow = next((w for w in found if w.is_file()), None)
    if workflow is None:
        pytest.skip("the repository's workflows are not in this checkout")
    text = workflow.read_text(encoding="utf-8")
    trigger = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
    assert "workflow_dispatch:" in trigger and "push" not in trigger and "schedule" not in trigger
    assert "environment: runpod" in text and "contents: read" in text
    assert "CLOUD_DEFAULTS_KEY: ${{ secrets.CLOUD_DEFAULTS_KEY }}" in text
    assert 'exec "$RUNNER_TEMP/e2e-venv/bin/python" cloud/runpod-worker/deploy/e2e.py' in text
    assert "--require-hashes" in text and "e2e-requirements.txt" in text
    # Inputs reach the script through the environment, never pasted into the shell script.
    assert "${{ inputs." not in text.split("run: >-", 1)[1]
    for line in text.splitlines():
        if "uses:" in line:
            ref = line.split("@", 1)[1].split()[0]
            assert len(ref) == 40 and all(ch in "0123456789abcdef" for ch in ref), line  # pinned to a commit
