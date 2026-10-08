"""End-to-end check of PixlAudio's built-in cloud keys (docs/handoff/2026-10-08-baked-keys.md): exactly what a phone
does with the keys baked into the app. Stdlib, plus `cryptography` for AES-GCM (Python has no AES; cloud-e2e.yml
installs it from deploy/e2e-requirements.txt into a throwaway venv). About a cent.

    CLOUD_DEFAULTS_KEY=<base64> RUNPOD_API_KEY=<the deploy key> python3 deploy/e2e.py [--blob FILE] [--seconds 20]

1. Open the committed App/Resources/CloudDefaults.enc with CLOUD_DEFAULTS_KEY and mask every value it holds
   (::add-mask::) before anything else is printed or sent.
2. Make a ~20 s synthetic clip with ffmpeg: sine tones with a slow tremolo plus pink noise (no music), FLAC 44.1 kHz
   16-bit stereo.
3. PUT it to R2 as in/<jobKey>.flac with a presigned URL (SigV4, PixlNet's S3Signer ported).
4. POST /run with the built-in Restricted key: schema v1 op process, tasks [instrumental], every worker URL presigned,
   the guard, input.policy.last_in_batch true (the worker stops itself afterwards).
5. GET /status until the job is final (25 minutes at most; one still queued then is cancelled, so it can't start and
   bill later).
6. GET the manifest from R2: ok, this input's sha256, an instrumental of a sane size and length; then the instrumental
   itself, whose size and sha256 must match the manifest.
7. DELETE every object of the job, whatever happened before.
8. GET /health until no worker is idle or ready (3 minutes at most). One that lingers means last_in_batch didn't stop
   it: it is released like deploy/reaper.py (max workers 0, then back) with RUNPOD_API_KEY, and the run warns.
The repository is public, so its logs are: only pass/fail lines, sizes, timings and the GPU name are printed. Never a
key, an id, a URL, a response body or money.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from reaper import STILL_THERE, ReaperError, counts, has_work, release_idle  # noqa: E402
from runpod_api import FINAL_STATES, ApiError, RunPod, mask, wait_for_job  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_BLOB = REPO / "App" / "Resources" / "CloudDefaults.enc"
MAGIC = b"PXCD1"
# The committed placeholder's public throwaway key (tools/cloud/bake-cloud-keys.mjs): opening with it means the real
# blob was never baked.
PLACEHOLDER_KEY = "8So6sYvJwxeya05DKvPe8+SXf78b9qOdon/a66BjyQw="
FIELDS = ("runpodEndpointId", "runpodKey", "r2Endpoint", "bucket", "r2AccessKeyId", "r2SecretAccessKey")
ENDPOINT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
ACCOUNT_RE = re.compile(r"^[0-9a-fA-F]{32}$")
BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")
SAMPLE_RATE = 44_100
PRESIGN_S = 2 * 3600  # every URL of the job; it takes minutes
JOB_DEADLINE_S = 1500.0
IDLE_WAIT_S = 180.0
IDLE_POLL_S = 10.0
USER_AGENT = "pixl-cloud-e2e/1"


class E2EError(Exception):
    """A failed step. The message is safe for a public log."""


def say(line: str) -> None:
    print(line, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        text = line.split("::", 2)[-1] if line.startswith("::") else line
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"- {text}\n")


# ---- the blob ------------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Keys:
    endpoint_id: str
    runpod_key: str
    r2_endpoint: str  # https://<host>
    bucket: str
    access_key_id: str
    secret_access_key: str

    def __repr__(self) -> str:  # never a value, not even in a traceback
        return "Keys(redacted)"

    __str__ = __repr__


def decode_key(text: str) -> bytes:
    try:
        key = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise E2EError("CLOUD_DEFAULTS_KEY is not base64") from None
    if len(key) != 32:
        raise E2EError("CLOUD_DEFAULTS_KEY is not 32 bytes")
    return key


def normalized_endpoint(value: str) -> str:
    """`https://<host>` for an R2 endpoint or a bare 32-hex account id (the app's CloudConfig.normalizedEndpoint)."""
    value = value.strip()
    if ACCOUNT_RE.match(value):
        return f"https://{value.lower()}.r2.cloudflarestorage.com"
    parts = urllib.parse.urlsplit(value if "://" in value else "https://" + value)
    host = (parts.hostname or "").lower()
    if parts.scheme != "https" or not host or "." not in host or parts.username or parts.password:
        raise E2EError("the blob's R2 endpoint is not https://<host>")
    return f"https://{host}" + (f":{parts.port}" if parts.port else "")


def open_blob(blob: bytes, key: bytes) -> Keys:
    """The built-in keys inside `blob` (AES-256-GCM, PXCD1 layout); E2EError when it doesn't open or isn't usable."""
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    if len(blob) <= len(MAGIC) + 12 + 16 or not blob.startswith(MAGIC):
        raise E2EError("App/Resources/CloudDefaults.enc is not a PXCD1 blob")
    nonce, sealed = blob[len(MAGIC):len(MAGIC) + 12], blob[len(MAGIC) + 12:]
    try:
        plain = AESGCM(key).decrypt(nonce, sealed, None)
    except InvalidTag:
        try:
            AESGCM(decode_key(PLACEHOLDER_KEY)).decrypt(nonce, sealed, None)
            raise E2EError("CloudDefaults.enc is still the placeholder: run tools/cloud/bake-cloud-keys.mjs and "
                           "commit the blob") from None
        except InvalidTag:
            raise E2EError("CloudDefaults.enc doesn't open with CLOUD_DEFAULTS_KEY (another key, or damaged): run "
                           "tools/cloud/bake-cloud-keys.mjs again") from None
    try:
        payload = json.loads(plain.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise E2EError("the blob opened but holds no JSON") from None
    if not isinstance(payload, dict) or payload.get("v") != 1:
        raise E2EError("the blob opened but isn't a v1 payload")
    missing = [f for f in FIELDS if not isinstance(payload.get(f), str) or not payload[f].strip()]
    if missing:
        raise E2EError(f"the blob opened but these fields are empty: {', '.join(missing)}")
    values = {f: payload[f].strip() for f in FIELDS}
    # Masked before any check below can fail and before anything is sent.
    for name in FIELDS:
        mask(values[name])
    account = re.match(r"^https://([0-9a-f]{32})\.r2\.cloudflarestorage\.com", normalized_endpoint(values["r2Endpoint"]))
    if account:
        mask(account.group(1))
    if not ENDPOINT_ID_RE.match(values["runpodEndpointId"]):
        raise E2EError("the blob's RunPod endpoint id isn't one")
    if not BUCKET_RE.match(values["bucket"]):
        raise E2EError("the blob's bucket name isn't a valid one")
    return Keys(endpoint_id=values["runpodEndpointId"], runpod_key=values["runpodKey"],
                r2_endpoint=normalized_endpoint(values["r2Endpoint"]), bucket=values["bucket"],
                access_key_id=values["r2AccessKeyId"], secret_access_key=values["r2SecretAccessKey"])


# ---- SigV4 query presigning (Packages/PixlCore/Sources/PixlNet/Cloud/S3Signer.swift) ---------------------------------

def uri_encode(text: str, encode_slash: bool) -> str:
    """AWS UriEncode: every byte but A-Z a-z 0-9 - _ . ~ as %XX (upper-case); '/' kept in paths."""
    return urllib.parse.quote(text, safe="-_.~" + ("" if encode_slash else "/"))


def presign(method: str, key: str, *, keys: Keys, expires_s: int, now_s: int | None = None, region: str = "auto",
            virtual_hosted: bool = False, query: tuple[tuple[str, str], ...] = ()) -> str:
    """A query-presigned URL (only `host` signed, payload UNSIGNED-PAYLOAD), valid `expires_s` (1 s ... 7 days)."""
    host = urllib.parse.urlsplit(keys.r2_endpoint).netloc.lower()
    if virtual_hosted:
        host = f"{keys.bucket}.{host}"
        path = "/" + uri_encode(key, encode_slash=False)
    else:
        path = "/" + uri_encode(keys.bucket, encode_slash=True) + ("/" + uri_encode(key, encode_slash=False) if key else "")
    amz_date = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(time.time() if now_s is None else now_s))
    date = amz_date[:8]
    scope = f"{date}/{region}/s3/aws4_request"
    params = list(query) + [
        ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
        ("X-Amz-Credential", f"{keys.access_key_id}/{scope}"),
        ("X-Amz-Date", amz_date),
        ("X-Amz-Expires", str(min(max(int(expires_s), 1), 604_800))),
        ("X-Amz-SignedHeaders", "host"),
    ]
    canonical_query = "&".join(f"{n}={v}" for n, v in sorted((uri_encode(n, True), uri_encode(v, True))
                                                             for n, v in params))
    canonical_request = "\n".join([method, path, canonical_query, f"host:{host}\n", "host", "UNSIGNED-PAYLOAD"])
    string_to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()])
    signing_key = ("AWS4" + keys.secret_access_key).encode("utf-8")
    for part in (date, region, "s3", "aws4_request"):
        signing_key = hmac.new(signing_key, part.encode("utf-8"), hashlib.sha256).digest()
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"https://{host}{path}?{canonical_query}&X-Amz-Signature={signature}"


class R2:
    """The bucket through presigned URLs (what the phone's background session and CloudObjectClient do)."""

    def __init__(self, keys: Keys, *, opener: Callable = urllib.request.urlopen,
                 sleep: Callable[[float], None] = time.sleep):
        self.keys, self.opener, self.sleep = keys, opener, sleep

    def url(self, method: str, key: str) -> str:
        return presign(method, key, keys=self.keys, expires_s=PRESIGN_S)

    def request(self, method: str, key: str, data: bytes | None = None, *, what: str,
                expect: tuple[int, ...] = (200,), tries: int = 3) -> bytes:
        status = 0
        for attempt in range(tries):
            headers = {"User-Agent": USER_AGENT}
            if data is not None:
                headers["Content-Type"] = "application/octet-stream"
            req = urllib.request.Request(self.url(method, key), data=data, method=method, headers=headers)
            try:
                with self.opener(req, timeout=300) as resp:
                    status, body = resp.status, resp.read()
            except urllib.error.HTTPError as exc:
                status, body = exc.code, b""
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
                status, body = 0, type(exc).__name__.encode()
            if status in expect:
                return body
            if status not in (0, 429, 500, 502, 503, 504) or attempt + 1 == tries:
                break
            self.sleep(2.0 * (2 ** attempt))
        raise E2EError(f"{what}: HTTP {status}")


# ---- the clip and the job ------------------------------------------------------------------------------------------

def make_clip(path: Path, seconds: int = 20, ffmpeg: str = "ffmpeg") -> None:
    """Synthetic stereo audio: two sine chords with a slow tremolo plus a little pink noise. No music."""
    tones = ("aevalsrc=exprs="
             "(0.22*sin(2*PI*220*t)+0.10*sin(2*PI*659.25*t))*(0.75+0.25*sin(2*PI*0.5*t))|"
             "(0.22*sin(2*PI*329.63*t)+0.10*sin(2*PI*440*t))*(0.75+0.25*sin(2*PI*0.7*t))"
             f":s={SAMPLE_RATE}:d={seconds}")
    noise = f"anoisesrc=d={seconds}:c=pink:r={SAMPLE_RATE}:a=0.03"
    cmd = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", tones, "-f", "lavfi", "-i", noise,
           "-filter_complex", "[1:a]aformat=channel_layouts=stereo[n];[0:a][n]amix=inputs=2:normalize=0[out]",
           "-map", "[out]", "-ar", str(SAMPLE_RATE), "-ac", "2", "-sample_fmt", "s16", "-c:a", "flac", str(path)]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0 or not path.exists() or path.stat().st_size < 1000:
        raise E2EError("ffmpeg could not make the test clip: " + (result.stderr.strip().splitlines() or ["?"])[-1][:200])


def job_keys(job_key: str) -> dict[str, str]:
    """Every object the job may leave in the bucket (the app's CloudJobBuilder.objectKeys for instrumental/aac)."""
    return {"input": f"in/{job_key}.flac", "instrumental": f"out/{job_key}/instrumental.m4a",
            "manifest": f"out/{job_key}/manifest.json", "attempt": f"out/{job_key}/attempt.json"}


def build_job(r2: R2, job_key: str, *, size: int, sha256: str, duration_ms: int, build: str) -> tuple[dict, dict]:
    """The /run body's `input` and RunPod `policy`, as the app's CloudJobBuilder makes them for one song."""
    k = job_keys(job_key)
    job_input = {
        "schema": "pixl.cloudstudio.job", "v": 1, "op": "process", "jobKey": job_key,
        "client": {"app": "pixl-cloud-e2e", "build": build[:64]},
        "storage": "presigned",
        "audio": {"get": r2.url("GET", k["input"]), "delete": r2.url("DELETE", k["input"]), "ext": "flac",
                  "bytes": size, "sha256": sha256, "durationMs": duration_ms},
        "tasks": ["instrumental"],
        "separation": {"quality": "standard"},
        "output": {"codec": "aac", "kbps": 256,
                   "put": {"instrumental": r2.url("PUT", k["instrumental"]), "manifest": r2.url("PUT", k["manifest"])}},
        "guard": {"manifestGet": r2.url("GET", k["manifest"]), "attemptGet": r2.url("GET", k["attempt"]),
                  "attemptPut": r2.url("PUT", k["attempt"])},
        # A single song is a burst of one: the worker stops itself afterwards instead of idling, billed.
        "policy": {"last_in_batch": True},
    }
    return job_input, {"ttl": 3_600_000, "executionTimeout": 900_000}


def check_manifest(manifest: dict, *, job_key: str, sha256: str, seconds: int) -> dict:
    """The instrumental entry of an ok manifest for this upload; E2EError otherwise."""
    if manifest.get("schema") != "pixl.cloudstudio.result" or manifest.get("jobKey") != job_key:
        raise E2EError("the manifest is not this job's")
    if manifest.get("status") != "ok":
        code = str((manifest.get("error") or {}).get("code") or "?")
        raise E2EError(f"the manifest says {manifest.get('status')} ({code[:40]})")
    if ((manifest.get("input") or {}).get("sha256") or "").lower() != sha256:
        raise E2EError("the manifest describes another input")
    out = (manifest.get("outputs") or {}).get("instrumental") or {}
    if out.get("key") != job_keys(job_key)["instrumental"]:
        raise E2EError("the manifest names no instrumental in this job's folder")
    size = out.get("bytes")
    # 256 kb/s AAC is ~32 KB a second; anything far off is broken.
    if not isinstance(size, int) or not (seconds * 8_000 <= size <= seconds * 80_000):
        raise E2EError(f"the instrumental's size is not sane ({size} bytes for {seconds} s)")
    samples, rate = out.get("samples"), out.get("sampleRate")
    if not isinstance(samples, int) or not isinstance(rate, int) or rate <= 0 \
            or abs(samples / rate - seconds) > 0.25:
        raise E2EError("the instrumental's length doesn't match the clip")
    if not re.fullmatch(r"[0-9a-f]{64}", str(out.get("sha256") or "")):
        raise E2EError("the manifest has no sha256 for the instrumental")
    return out


def wait_idle(api: RunPod, endpoint_id: str, *, admin: RunPod | None, template: dict,
              sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
              wait_s: float = IDLE_WAIT_S, poll_s: float = IDLE_POLL_S, **release_kw) -> str:
    """Step 8. Returns "gone", "busy" (other jobs running: left to cloud-worker-reaper) or the reaper's outcome."""
    started = clock()
    while True:
        c = counts(api.health(endpoint_id))
        if c["idle"] + c["ready"] == 0:
            say(f"idle check: no idle worker {int(clock() - started)} s after the job")
            return "gone"
        if has_work(c):
            say("idle check: other jobs are running on the endpoint; cloud-worker-reaper looks after the rest")
            return "busy"
        if clock() - started >= wait_s:
            break
        sleep(poll_s)
    say(f"::warning::a worker was still idle {int(wait_s)} s after the job: last_in_batch didn't stop it; releasing it "
        "like cloud-worker-reaper")
    if admin is None:
        raise E2EError("RUNPOD_API_KEY is not set, so the idle worker can't be released; run cloud-worker-reaper")
    current = (admin.get_endpoint(endpoint_id) or {}).get("workers") or template["workers"]
    try:
        outcome = release_idle(admin, endpoint_id, current, template, sleep=sleep, clock=clock, say=say,
                               **({"confirm_s": 10.0} | release_kw))
    except ReaperError as exc:
        raise E2EError(str(exc)) from None
    if outcome == STILL_THERE:
        raise E2EError("max workers 0 didn't release the idle worker; stop it in the RunPod console (Workers)")
    return outcome


def run(keys: Keys, *, api: RunPod, admin: RunPod | None, r2: R2, template: dict, workdir: Path, seconds: int,
        build: str, sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
        clip: Callable[[Path, int], None] = make_clip, **idle_kw) -> int:
    job_key = str(uuid.uuid4())
    objects = job_keys(job_key)
    path = workdir / "clip.flac"
    clip(path, seconds)
    data = path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    say(f"clip: {seconds} s synthetic tones and noise, FLAC, {len(data) / 1e6:.1f} MB")
    failure: str | None = None
    job_id: str | None = None
    state: str | None = None
    try:
        t0 = clock()
        r2.request("PUT", objects["input"], data, what="upload (R2 PUT)")
        say(f"upload: ok in {clock() - t0:.1f} s")
        job_input, policy = build_job(r2, job_key, size=len(data), sha256=sha, duration_ms=seconds * 1000, build=build)
        t1 = clock()
        first = api.run(keys.endpoint_id, job_input, policy)
        job_id = first.get("id")
        if not job_id:
            raise E2EError("/run returned no job id")
        reply = wait_for_job(api, keys.endpoint_id, first, deadline_s=JOB_DEADLINE_S, poll_s=10, sleep=sleep,
                             clock=clock)
        state = reply.get("status")
        if state != "COMPLETED":
            raise E2EError(f"the job ended {state or 'without a state'} after {clock() - t1:.0f} s")
        output = reply.get("output") if isinstance(reply.get("output"), dict) else {}
        worker = output.get("worker") or {}
        timings = output.get("timings") or {}
        gpu = re.sub(r"[^A-Za-z0-9 ._()-]", "", str(worker.get("gpu") or "?"))[:60]
        say(f"job: COMPLETED {clock() - t1:.0f} s after /run on {gpu} (cold start "
            f"{(timings.get('coldStartMs') or 0) / 1000:.1f} s, separate {(timings.get('separateMs') or 0) / 1000:.1f} s,"
            f" worker total {(timings.get('totalMs') or 0) / 1000:.1f} s)")
        try:
            manifest = json.loads(r2.request("GET", objects["manifest"], what="manifest (R2 GET)").decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise E2EError("the manifest in R2 is not JSON") from None
        out = check_manifest(manifest, job_key=job_key, sha256=sha, seconds=seconds)
        audio = r2.request("GET", objects["instrumental"], what="instrumental (R2 GET)")
        if len(audio) != out["bytes"] or hashlib.sha256(audio).hexdigest() != out["sha256"]:
            raise E2EError("the instrumental in R2 doesn't match its manifest (size or sha256)")
        say(f"result: ok; instrumental {len(audio) / 1e3:.0f} KB, {out['samples'] / out['sampleRate']:.2f} s, "
            "size and sha256 match the manifest")
    except (E2EError, ApiError) as exc:
        failure = str(exc)
    except KeyboardInterrupt:
        failure = "cancelled"
    finally:
        if job_id and state not in FINAL_STATES:
            try:
                api.cancel(keys.endpoint_id, job_id)
                say("cancelled the unfinished job, so it can't start (and bill) later")
            except ApiError as exc:
                say(f"::warning::could not cancel the unfinished job (HTTP {exc.status})")
        deleted = 0
        for name, key in objects.items():
            try:
                r2.request("DELETE", key, what=f"delete {name}", expect=(200, 204, 404))
                deleted += 1
            except E2EError as exc:
                say(f"::warning::cleanup: {exc} (the bucket's lifecycle rules remove it within 30 days)")
        say(f"cleanup: {deleted} of {len(objects)} objects deleted")
    if job_id and failure != "cancelled":
        try:
            wait_idle(api, keys.endpoint_id, admin=admin, template=template, sleep=sleep, clock=clock, **idle_kw)
        except (E2EError, ApiError) as exc:
            failure = failure or f"idle check: {exc}"
    if failure:
        say(f"::error::cloud e2e FAILED: {failure}")
        return 1
    say("cloud e2e PASSED: the built-in keys reach RunPod and R2, and an instrumental comes back")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--blob", type=Path, default=DEFAULT_BLOB)
    parser.add_argument("--seconds", type=int, default=20)
    args = parser.parse_args(argv)
    key_text = os.environ.get("CLOUD_DEFAULTS_KEY", "")
    mask(key_text.strip())
    if not key_text.strip():
        say("::error::CLOUD_DEFAULTS_KEY is not set (tools/cloud/bake-cloud-keys.mjs sets it)")
        return 1
    admin_key = os.environ.get("RUNPOD_API_KEY", "").strip()
    try:
        keys = open_blob(args.blob.read_bytes(), decode_key(key_text))
    except (E2EError, OSError) as exc:
        say(f"::error::cloud e2e FAILED: {exc if isinstance(exc, E2EError) else 'the blob could not be read'}")
        return 1
    say("blob: opened with CLOUD_DEFAULTS_KEY; v1, every field filled in (all masked)")
    template = json.loads((HERE / "endpoint.json").read_text(encoding="utf-8"))
    build = "e2e " + os.environ.get("GITHUB_SHA", "local")[:12]
    with tempfile.TemporaryDirectory(prefix="pixl-e2e-") as tmp:
        try:
            return run(keys, api=RunPod(keys.runpod_key), admin=RunPod(admin_key) if admin_key else None,
                       r2=R2(keys), template=template, workdir=Path(tmp), seconds=max(5, min(args.seconds, 120)),
                       build=build)
        except E2EError as exc:
            say(f"::error::cloud e2e FAILED: {exc}")
            return 1


if __name__ == "__main__":
    sys.exit(main())
