"""Storage drivers: presigned R2 URLs (primary) and a mounted RunPod network volume (fallback). Design 2.3–2.5.

The worker holds no storage credentials. For presigned storage every URL was already checked by schema.py
(https, host allowlist, signature present, object path belongs to this job); here each request additionally:
- resolves the host and refuses non-public addresses, then connects to that exact address (no DNS rebinding);
- never follows redirects (http.client doesn't, and any 3xx is an error);
- streams downloads with a byte cap and a total-time cap, hashing as it goes;
- retries transient failures (connection errors, 5xx, 408, 429) with backoff, never 4xx signature failures.
Error messages never contain the URL or its query; logs get host/path only.
"""

from __future__ import annotations

import hashlib
import http.client
import ipaddress
import json
import os
import shutil
import socket
import ssl
import time
from dataclasses import dataclass
from typing import Callable, Protocol
from urllib.parse import urlsplit

from .config import Caps
from .errors import (
    BAD_URL, DOWNLOAD_FAILED, INPUT_MISMATCH, INPUT_MISSING, INPUT_TOO_LARGE, UPLOAD_FAILED, WorkerError,
)
from .log import log, safe_url
from .schema import Job

CONTENT_TYPES = {"m4a": "audio/mp4", "flac": "audio/flac", "json": "application/json"}
CHUNK = 1024 * 1024
RETRY_STATUSES = {408, 425, 429, 500, 502, 503, 504}


@dataclass
class Response:
    status: int
    headers: dict
    body: bytes = b""


class Transport(Protocol):
    def request(self, method: str, url: str, *, headers: dict | None = None, body: bytes | None = None,
                body_path: str | None = None, sink: Callable[[bytes], None] | None = None,
                max_body: int | None = None, timeout: float = 30.0, deadline: float | None = None) -> Response:
        ...


class TransientError(Exception):
    """A failure worth retrying (connection reset, timeout, 5xx)."""


class TooLarge(Exception):
    pass


def _public_addresses(host: str, port: int) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise TransientError(f"cannot resolve the storage host ({exc.strerror or exc})") from None
    addresses: list[str] = []
    for info in infos:
        address = info[4][0]
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise TransientError("the storage host has no addresses")
    for address in addresses:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
        if not ip.is_global:
            raise WorkerError(BAD_URL, "the storage host resolves to a non-public address")
    return addresses


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS to an already-validated IP address, with SNI and certificate checks for the real host name."""

    def __init__(self, host: str, address: str, *, timeout: float, context: ssl.SSLContext):
        super().__init__(host, 443, timeout=timeout, context=context)
        self._address = address
        self._ctx = context

    def connect(self) -> None:  # noqa: D401 - http.client API
        sock = socket.create_connection((self._address, 443), self.timeout)
        self.sock = self._ctx.wrap_socket(sock, server_hostname=self.host)


class HttpTransport:
    """Real network transport (stdlib http.client)."""

    def __init__(self, *, connect_timeout: float = 10.0, resolver=_public_addresses,
                 context: ssl.SSLContext | None = None):
        self._context = context or ssl.create_default_context()
        self._connect_timeout = connect_timeout
        self._resolver = resolver

    def request(self, method, url, *, headers=None, body=None, body_path=None, sink=None, max_body=None,
                timeout=30.0, deadline=None) -> Response:
        parts = urlsplit(url)
        host = parts.hostname or ""
        target = parts.path or "/"
        if parts.query:
            target += "?" + parts.query
        addresses = self._resolver(host, 443)
        conn = _PinnedHTTPSConnection(host, addresses[0], timeout=self._connect_timeout, context=self._context)
        try:
            try:
                conn.connect()
                conn.sock.settimeout(timeout)
                send_headers = dict(headers or {})
                if body_path is not None:
                    send_headers["Content-Length"] = str(os.path.getsize(body_path))
                    conn.putrequest(method, target, skip_accept_encoding=True)
                    for key, value in send_headers.items():
                        conn.putheader(key, value)
                    conn.endheaders()
                    with open(body_path, "rb") as fh:
                        while True:
                            if deadline is not None and time.monotonic() > deadline:
                                raise TransientError("upload took too long")
                            chunk = fh.read(CHUNK)
                            if not chunk:
                                break
                            conn.sock.sendall(chunk)
                else:
                    if body is not None:
                        send_headers["Content-Length"] = str(len(body))
                    elif method in ("PUT", "POST"):
                        send_headers["Content-Length"] = "0"
                    conn.request(method, target, body=body, headers=send_headers)
                resp = conn.getresponse()
                status = resp.status
                resp_headers = {k.lower(): v for k, v in resp.getheaders()}
                collected = bytearray()
                if status == 200 and sink is not None:
                    total = 0
                    while True:
                        if deadline is not None and time.monotonic() > deadline:
                            raise TransientError("download took too long")
                        chunk = resp.read(CHUNK)
                        if not chunk:
                            break
                        total += len(chunk)
                        if max_body is not None and total > max_body:
                            raise TooLarge()
                        sink(chunk)
                else:
                    limit = max_body if max_body is not None else 64 * 1024
                    while True:
                        chunk = resp.read(min(CHUNK, limit + 1 - len(collected)))
                        if not chunk:
                            break
                        collected.extend(chunk)
                        if len(collected) > limit:
                            if status == 200:
                                raise TooLarge()
                            break  # error bodies are only ever logged in part
                return Response(status=status, headers=resp_headers, body=bytes(collected))
            except (socket.timeout, TimeoutError, ConnectionError, http.client.HTTPException, ssl.SSLError,
                    OSError) as exc:
                if isinstance(exc, (TooLarge, WorkerError)):
                    raise
                raise TransientError(type(exc).__name__) from None
        finally:
            conn.close()


def _backoff(attempt: int) -> float:
    return min(8.0, 1.0 * (3 ** attempt))


def download_budget_s(size_bytes: int) -> float:
    """Time allowed for the whole input download, all tries together: 120 s plus 1 s per 2 MB (a 160 MB FLAC gets
    200 s). R2 to a RunPod host normally runs far faster; the budget only stops a stalled transfer."""
    return 120.0 + max(0, size_bytes) / (2 * 1024 * 1024)


class PresignedStorage:
    """Every object is reached through a URL the phone presigned for this job only."""

    def __init__(self, job: Job, caps: Caps, transport: Transport | None = None, *, tries: int = 3,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic):
        self.job = job
        self.caps = caps
        self.transport = transport or HttpTransport()
        self.tries = tries
        self.sleep = sleep
        self.clock = clock

    # ---- input --------------------------------------------------------------------------------------------
    def fetch_input(self, dest_path: str, *, total_timeout: float = 120.0) -> int:
        """Stream the input to dest_path. `total_timeout` bounds every try together, not each one."""
        audio = self.job.audio
        expect = audio.bytes
        if expect > self.caps.max_input_bytes:
            raise WorkerError(INPUT_TOO_LARGE, f"the input is larger than {self.caps.max_input_mb} MB")
        last = "unknown"
        end = self.clock() + total_timeout
        for attempt in range(self.tries):
            if attempt and self.clock() >= end - 1.0:
                last = "out of time"
                break
            digest = hashlib.sha256()
            with open(dest_path, "wb") as fh:
                def sink(chunk: bytes) -> None:
                    digest.update(chunk)
                    fh.write(chunk)
                try:
                    resp = self.transport.request(
                        "GET", audio.get, sink=sink, max_body=expect, timeout=30.0, deadline=end)
                except TooLarge:
                    raise WorkerError(INPUT_MISMATCH, "the input is larger than audio.bytes") from None
                except TransientError as exc:
                    last = str(exc)
                    log.warning("fetch_retry", attempt=attempt + 1, reason=last, url=safe_url(audio.get))
                    self.sleep(_backoff(attempt))
                    continue
            status = resp.status
            if status == 200:
                size = os.path.getsize(dest_path)
                if size != expect:
                    raise WorkerError(INPUT_MISMATCH, f"downloaded {size} bytes, audio.bytes says {expect}")
                if digest.hexdigest() != audio.sha256:
                    raise WorkerError(INPUT_MISMATCH, "the downloaded input's sha256 does not match audio.sha256")
                return size
            if status == 404:
                raise WorkerError(INPUT_MISSING, "the input object does not exist (expired or never uploaded)")
            if status in (401, 403):
                raise WorkerError(BAD_URL, f"storage refused the input URL (HTTP {status}: expired or wrong signature)")
            if 300 <= status < 400:
                raise WorkerError(BAD_URL, "storage answered with a redirect, which the worker never follows")
            if status in RETRY_STATUSES:
                last = f"HTTP {status}"
                log.warning("fetch_retry", attempt=attempt + 1, reason=last, url=safe_url(audio.get))
                self.sleep(_backoff(attempt))
                continue
            raise WorkerError(DOWNLOAD_FAILED, f"storage answered HTTP {status} for the input")
        raise WorkerError(DOWNLOAD_FAILED, f"could not download the input after {self.tries} tries ({last})")

    def delete_input(self) -> None:
        url = self.job.audio.delete
        if not url:
            return
        try:
            resp = self.transport.request("DELETE", url, timeout=10.0, deadline=self.clock() + 10.0)
            log.info("input_deleted", status=resp.status)
        except Exception as exc:  # best effort
            log.warning("input_delete_failed", reason=type(exc).__name__)

    # ---- outputs ------------------------------------------------------------------------------------------
    def _put(self, url: str, *, body: bytes | None = None, body_path: str | None = None, content_type: str,
             what: str, timeout: float = 120.0) -> None:
        last = "unknown"
        for attempt in range(self.tries):
            try:
                resp = self.transport.request(
                    "PUT", url, headers={"Content-Type": content_type}, body=body, body_path=body_path,
                    timeout=60.0, deadline=self.clock() + timeout)
            except TransientError as exc:
                last = str(exc)
                log.warning("upload_retry", attempt=attempt + 1, what=what, reason=last)
                self.sleep(_backoff(attempt))
                continue
            if 200 <= resp.status < 300:
                return
            if resp.status in RETRY_STATUSES:
                last = f"HTTP {resp.status}"
                log.warning("upload_retry", attempt=attempt + 1, what=what, reason=last)
                self.sleep(_backoff(attempt))
                continue
            raise WorkerError(UPLOAD_FAILED, f"storage refused the {what} upload (HTTP {resp.status})")
        raise WorkerError(UPLOAD_FAILED, f"could not upload the {what} after {self.tries} tries ({last})")

    def put_file(self, slot: str, path: str, content_type: str) -> str:
        self._put(self.job.output.put[slot], body_path=path, content_type=content_type, what=slot)
        return self.job.object_key(slot)

    def put_json(self, slot: str, data: bytes) -> str:
        self._put(self.job.output.put[slot], body=data, content_type=CONTENT_TYPES["json"], what=slot)
        return self.job.object_key(slot)

    # ---- guard --------------------------------------------------------------------------------------------
    @property
    def has_guard(self) -> bool:
        return self.job.guard is not None

    def get_guard_json(self, which: str) -> dict | None:
        """which: manifest | attempt. Returns None when the object does not exist. Raises TransientError when
        storage can't be read (the caller decides; the guard is best effort)."""
        url = self.job.guard.manifest_get if which == "manifest" else self.job.guard.attempt_get
        resp = self.transport.request("GET", url, max_body=256 * 1024, timeout=10.0, deadline=self.clock() + 10.0)
        if resp.status == 404:
            return None
        if resp.status != 200:
            raise TransientError(f"HTTP {resp.status}")
        try:
            value = json.loads(resp.body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def put_attempt(self, data: bytes) -> None:
        self._put(self.job.guard.attempt_put, body=data, content_type=CONTENT_TYPES["json"], what="attempt",
                  timeout=10.0)


class VolumeStorage:
    """storage: volume — the RunPod network volume mounted at /runpod-volume (design 4, fallback). Keys were
    validated against in/<jobKey>.<ext>; outputs go to out/<jobKey>/, manifest last, each written atomically."""

    def __init__(self, job: Job, caps: Caps):
        self.job = job
        self.caps = caps
        self.root = os.path.realpath(caps.volume_root)

    def _path(self, key: str) -> str:
        path = os.path.realpath(os.path.join(self.root, key))
        if not path.startswith(self.root + os.sep):
            raise WorkerError(BAD_URL, "the object key escapes the volume")
        return path

    def fetch_input(self, dest_path: str, *, total_timeout: float = 120.0) -> int:
        audio = self.job.audio
        if audio.bytes > self.caps.max_input_bytes:
            raise WorkerError(INPUT_TOO_LARGE, f"the input is larger than {self.caps.max_input_mb} MB")
        src = self._path(audio.key)
        if not os.path.isfile(src):
            raise WorkerError(INPUT_MISSING, "the input object does not exist on the volume")
        size = os.path.getsize(src)
        if size != audio.bytes:
            raise WorkerError(INPUT_MISMATCH, f"the input has {size} bytes, audio.bytes says {audio.bytes}")
        digest = hashlib.sha256()
        with open(src, "rb") as fin, open(dest_path, "wb") as fout:
            while True:
                chunk = fin.read(CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
                fout.write(chunk)
        if digest.hexdigest() != audio.sha256:
            raise WorkerError(INPUT_MISMATCH, "the input's sha256 does not match audio.sha256")
        return size

    def delete_input(self) -> None:
        try:
            os.remove(self._path(self.job.audio.key))
        except OSError:
            pass

    def _write(self, key: str, *, data: bytes | None = None, src_path: str | None = None) -> str:
        dest = self._path(key)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".part"
        try:
            if src_path is not None:
                shutil.copyfile(src_path, tmp)
            else:
                with open(tmp, "wb") as fh:
                    fh.write(data or b"")
            os.replace(tmp, dest)
        except OSError as exc:
            raise WorkerError(UPLOAD_FAILED, f"could not write to the volume ({exc.strerror or type(exc).__name__})") from None
        return key

    def put_file(self, slot: str, path: str, content_type: str) -> str:
        return self._write(self.job.object_key(slot), src_path=path)

    def put_json(self, slot: str, data: bytes) -> str:
        return self._write(self.job.object_key(slot), data=data)

    has_guard = True

    def get_guard_json(self, which: str) -> dict | None:
        key = self.job.object_key("manifest" if which == "manifest" else "attempt")
        path = self._path(key)
        if not os.path.isfile(path):
            return None
        try:
            with open(path, "rb") as fh:
                value = json.loads(fh.read(256 * 1024).decode("utf-8"))
        except (OSError, UnicodeDecodeError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def put_attempt(self, data: bytes) -> None:
        self._write(self.job.object_key("attempt"), data=data)


def sweep_volume(root: str, *, now: float | None = None, in_days: int = 7, out_days: int = 30) -> int:
    """Volume fallback housekeeping at worker start: delete in/ older than 7 days and out/<jobKey>/ older than
    30 days (matches the R2 lifecycle rules). Returns the number of entries removed."""
    now = time.time() if now is None else now
    removed = 0
    for prefix, days in (("in", in_days), ("out", out_days)):
        base = os.path.join(root, prefix)
        if not os.path.isdir(base):
            continue
        for name in os.listdir(base):
            path = os.path.join(base, name)
            try:
                if now - os.path.getmtime(path) < days * 86400:
                    continue
                if os.path.isdir(path):
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    os.remove(path)
                removed += 1
            except OSError:
                continue
    return removed


def make_storage(job: Job, caps: Caps, transport: Transport | None = None):
    if job.storage == "volume":
        return VolumeStorage(job, caps)
    return PresignedStorage(job, caps, transport)
