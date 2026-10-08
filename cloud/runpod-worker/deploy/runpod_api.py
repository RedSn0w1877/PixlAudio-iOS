"""A small RunPod client for the deploy and keepalive scripts (stdlib only: urllib).

- Management: REST v2 at https://api.runpod.io/v2 (REST v1 retires 2026-11-15). Field names and response
  shapes follow https://api.runpod.io/v2/openapi.json (checked 2026-10-07): ListEndpointsResponse
  {endpoints, pagination}, Endpoint, UpdateEndpointRequest (a partial PATCH), ListEndpointReleasesResponse
  {rollout, releases}, ListEndpointWorkersResponse {workers, summary}, ListServerlessBillingResponse
  {records, metadata.totals}.
- Jobs: https://api.runpod.ai/v2/<endpoint id>/{run,runsync,status/<job>,health}.
- GHCR: the anonymous token + manifest HEAD that RunPod itself needs to pull a public image.

The repository is public, so its Actions logs are public: nothing here prints or raises a key, an endpoint id,
a response body or a spend amount. Errors carry the HTTP status and RunPod's short `title` only, and the
scripts mask the endpoint id with ::add-mask:: before anything else is printed.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

MANAGEMENT = "https://api.runpod.io"
JOBS = "https://api.runpod.ai"
GHCR = "https://ghcr.io"
USER_AGENT = "pixl-cloud-worker-deploy/1"
RETRY_STATUSES = {408, 425, 429, 500, 502, 503, 504}
FINAL_STATES = frozenset({"COMPLETED", "FAILED", "CANCELLED", "TIMED_OUT"})
_TITLE = re.compile(r"[^A-Za-z0-9 .,:;'()/_-]")


class ApiError(Exception):
    """A failed call. The message is safe for a public log: method, path template, status, short title."""

    def __init__(self, what: str, status: int, title: str = ""):
        self.what, self.status, self.title = what, status, title
        super().__init__(f"{what}: HTTP {status}" + (f" ({title})" if title else ""))


@dataclass
class Reply:
    status: int
    headers: dict
    body: Any


def _safe_title(raw: bytes) -> str:
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return ""
    title = doc.get("title") if isinstance(doc, dict) else None
    return _TITLE.sub("", str(title))[:80] if title else ""


def mask(value: str | None) -> None:
    """Hide a value in GitHub Actions logs from here on (no-op outside Actions)."""
    if value and os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{value}", flush=True)


class Http:
    """urllib with retries on 429/5xx (honouring Retry-After) and on connection errors. Injectable for tests."""

    def __init__(self, *, opener: Callable | None = None, sleep: Callable[[float], None] = time.sleep,
                 tries: int = 4, timeout: float = 60.0):
        self.opener = opener or urllib.request.urlopen
        self.sleep = sleep
        self.tries = tries
        self.timeout = timeout

    def request(self, method: str, url: str, *, what: str, headers: dict | None = None, body: Any = None,
                expect: tuple[int, ...] = (200,), timeout: float | None = None) -> Reply:
        data = None
        send = {"User-Agent": USER_AGENT, "Accept": "application/json", **(headers or {})}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            send["Content-Type"] = "application/json"
        last: ApiError | None = None
        for attempt in range(self.tries):
            req = urllib.request.Request(url, data=data, method=method, headers=send)
            try:
                with self.opener(req, timeout=timeout or self.timeout) as resp:
                    status, raw, hdrs = resp.status, resp.read(), {k.lower(): v for k, v in resp.headers.items()}
            except urllib.error.HTTPError as exc:
                status, raw, hdrs = exc.code, exc.read() or b"", {k.lower(): v for k, v in (exc.headers or {}).items()}
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
                last = ApiError(what, 0, type(exc).__name__)
                self.sleep(min(30.0, 2.0 * (2 ** attempt)))
                continue
            if status in expect:
                parsed: Any = None
                if raw:
                    try:
                        parsed = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        parsed = None
                return Reply(status, hdrs, parsed)
            last = ApiError(what, status, _safe_title(raw))
            if status in RETRY_STATUSES and attempt + 1 < self.tries:
                retry_after = hdrs.get("retry-after", "")
                wait = float(retry_after) if retry_after.isdigit() else min(30.0, 2.0 * (2 ** attempt))
                self.sleep(min(wait, 120.0))
                continue
            raise last
        raise last or ApiError(what, 0, "no response")


class RunPod:
    def __init__(self, api_key: str, http: Http | None = None):
        if not api_key:
            raise ValueError("RUNPOD_API_KEY is empty")
        self._auth = {"Authorization": f"Bearer {api_key}"}
        self.http = http or Http()

    # ---- management (REST v2) ----------------------------------------------------------------------------
    def _mgmt(self, method: str, path: str, *, what: str, query: dict | None = None, body: Any = None,
              expect: tuple[int, ...] = (200,)) -> Any:
        url = MANAGEMENT + path + ("?" + urllib.parse.urlencode(query) if query else "")
        return self.http.request(method, url, what=what, headers=self._auth, body=body, expect=expect).body

    def list_endpoints(self) -> list[dict]:
        endpoints: list[dict] = []
        cursor = None
        for _ in range(50):
            query = {"limit": 1000, **({"cursor": cursor} if cursor else {})}
            page = self._mgmt("GET", "/v2/serverless", what="GET /v2/serverless", query=query) or {}
            endpoints.extend(page.get("endpoints") or [])
            pagination = page.get("pagination") or {}
            cursor = pagination.get("nextCursor")
            if not pagination.get("hasNextPage") or not cursor:
                break
        return endpoints

    def find_endpoint(self, name: str) -> dict | None:
        matches = [e for e in self.list_endpoints() if e.get("name") == name]
        if len(matches) > 1:
            raise ApiError("GET /v2/serverless", 409, f"{len(matches)} endpoints are named {name}")
        return matches[0] if matches else None

    def get_endpoint(self, endpoint_id: str) -> dict:
        return self._mgmt("GET", f"/v2/serverless/{endpoint_id}", what="GET /v2/serverless/{id}")

    def create_endpoint(self, body: dict) -> dict:
        return self._mgmt("POST", "/v2/serverless", what="POST /v2/serverless", body=body, expect=(200, 201))

    def update_endpoint(self, endpoint_id: str, body: dict) -> dict:
        return self._mgmt("PATCH", f"/v2/serverless/{endpoint_id}", what="PATCH /v2/serverless/{id}", body=body)

    def releases(self, endpoint_id: str) -> dict:
        return self._mgmt("GET", f"/v2/serverless/{endpoint_id}/releases", what="GET /v2/serverless/{id}/releases",
                          query={"limit": 5})

    def workers(self, endpoint_id: str) -> dict:
        return self._mgmt("GET", f"/v2/serverless/{endpoint_id}/workers", what="GET /v2/serverless/{id}/workers")

    def weekly_spend(self, endpoint_id: str, days: int = 7) -> float:
        doc = self._mgmt("GET", "/v2/billing/serverless", what="GET /v2/billing/serverless",
                         query={"serverlessId": endpoint_id, "bucketSize": "day", "lastN": days}) or {}
        totals = (doc.get("metadata") or {}).get("totals") or {}
        if isinstance(totals.get("totalAmount"), (int, float)):
            return float(totals["totalAmount"])
        return float(sum(float(r.get("totalAmount") or 0) for r in doc.get("records") or []))

    # ---- jobs (api.runpod.ai) -----------------------------------------------------------------------------
    def _jobs(self, method: str, endpoint_id: str, tail: str, *, what: str, body: Any = None,
              expect: tuple[int, ...] = (200,), timeout: float | None = None) -> Any:
        url = f"{JOBS}/v2/{endpoint_id}/{tail}"
        return self.http.request(method, url, what=what, headers=self._auth, body=body, expect=expect,
                                 timeout=timeout).body

    def health(self, endpoint_id: str) -> dict:
        return self._jobs("GET", endpoint_id, "health", what="GET /health") or {}

    def run(self, endpoint_id: str, job_input: dict, policy: dict | None = None) -> dict:
        body = {"input": job_input, **({"policy": policy} if policy else {})}
        return self._jobs("POST", endpoint_id, "run", what="POST /run", body=body) or {}

    def runsync(self, endpoint_id: str, job_input: dict, wait_ms: int = 300000) -> dict:
        return self._jobs("POST", endpoint_id, f"runsync?wait={int(wait_ms)}", what="POST /runsync",
                          body={"input": job_input}, timeout=wait_ms / 1000.0 + 60) or {}

    def status(self, endpoint_id: str, job_id: str) -> dict:
        return self._jobs("GET", endpoint_id, f"status/{urllib.parse.quote(job_id, safe='')}", what="GET /status") or {}

    def cancel(self, endpoint_id: str, job_id: str) -> dict:
        return self._jobs("POST", endpoint_id, f"cancel/{urllib.parse.quote(job_id, safe='')}", what="POST /cancel") or {}


def wait_for_job(api: RunPod, endpoint_id: str, first: dict, *, deadline_s: float, poll_s: float = 10.0,
                 clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep) -> dict:
    """Follow a /run or /runsync reply until the job is final (COMPLETED, FAILED, CANCELLED, TIMED_OUT)."""
    reply = first
    end = clock() + deadline_s
    while reply.get("status") not in FINAL_STATES:
        job_id = reply.get("id")
        if not job_id or clock() > end:
            return reply
        sleep(poll_s)
        reply = api.status(endpoint_id, job_id)
    return reply


def ghcr_public(image: str, http: Http | None = None) -> tuple[bool, str]:
    """Can RunPod pull `ghcr.io/<owner>/<name>:<tag>` without credentials? (True, "") or (False, why)."""
    match = re.fullmatch(r"ghcr\.io/([a-z0-9._-]+/[a-z0-9._/-]+):([A-Za-z0-9._-]+)", image)
    if not match:
        return False, "not a ghcr.io/<owner>/<name>:<tag> reference"
    repo, tag = match.groups()
    http = http or Http()
    try:
        token = http.request("GET", f"{GHCR}/token?scope=repository:{repo}:pull&service=ghcr.io",
                             what="GET ghcr.io/token").body or {}
    except ApiError as exc:
        return False, f"anonymous token refused (HTTP {exc.status})"
    accept = ", ".join([
        "application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ])
    try:
        http.request("HEAD", f"{GHCR}/v2/{repo}/manifests/{tag}", what="HEAD ghcr.io manifest",
                     headers={"Authorization": f"Bearer {token.get('token', '')}", "Accept": accept})
    except ApiError as exc:
        if exc.status in (401, 403):
            return False, "the package is private"
        if exc.status == 404:
            return False, "the tag does not exist"
        return False, f"HTTP {exc.status}"
    return True, ""
