"""Storage: caps, sha/size checks, retries, status mapping, the guard objects, and the real HTTPS transport
(against a local TLS server with a throwaway certificate, pinned to 127.0.0.1)."""

import hashlib
import http.server
import json
import os
import shutil
import socket
import ssl
import subprocess
import threading
import time

import pytest

from conftest import EXAMPLE_HOST, load_example
from pixl_worker import errors
from pixl_worker.config import load_caps
from pixl_worker.schema import validate_job
from pixl_worker.storage import (
    HttpTransport, PresignedStorage, Response, TooLarge, TransientError, VolumeStorage, _public_addresses,
    sweep_volume,
)

DATA = os.urandom(200_000)


def make_job(data=DATA, **overrides):
    doc = load_example("job.input.process.json")
    doc["audio"]["bytes"] = len(data)
    doc["audio"]["sha256"] = hashlib.sha256(data).hexdigest()
    doc.update(overrides)
    caps = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_MAX_INPUT_MB": "1"})
    return validate_job(doc, caps), caps


class FakeTransport:
    def __init__(self, script):
        self.script = list(script)  # each: Response | Exception | callable(method, url, kw) -> Response
        self.calls = []

    def request(self, method, url, **kw):
        self.calls.append((method, url, kw))
        step = self.script.pop(0)
        if isinstance(step, Exception):
            raise step
        if callable(step):
            return step(method, url, kw)
        if step.status == 200 and kw.get("sink") is not None and step.body:
            if kw.get("max_body") is not None and len(step.body) > kw["max_body"]:
                raise TooLarge()
            kw["sink"](step.body)
            return Response(200, step.headers)
        return step


def storage_with(script, data=DATA):
    job, caps = make_job(data)
    transport = FakeTransport(script)
    return PresignedStorage(job, caps, transport, sleep=lambda s: None), transport


def test_fetch_ok_checks_size_and_sha(tmp_path):
    storage, transport = storage_with([Response(200, {}, DATA)])
    dest = tmp_path / "in.m4a"
    assert storage.fetch_input(str(dest)) == len(DATA)
    assert dest.read_bytes() == DATA
    method, url, kw = transport.calls[0]
    assert method == "GET" and kw["max_body"] == len(DATA)


def test_fetch_sha_mismatch(tmp_path):
    storage, _ = storage_with([Response(200, {}, DATA[:-1] + b"x")])
    with pytest.raises(errors.WorkerError) as info:
        storage.fetch_input(str(tmp_path / "in"))
    assert info.value.code == errors.INPUT_MISMATCH


def test_fetch_more_bytes_than_declared(tmp_path):
    storage, _ = storage_with([Response(200, {}, DATA + b"extra")])
    with pytest.raises(errors.WorkerError) as info:
        storage.fetch_input(str(tmp_path / "in"))
    assert info.value.code == errors.INPUT_MISMATCH


def test_fetch_over_the_cap_never_downloads(tmp_path):
    big = b"\0" * (2 * 1024 * 1024)
    storage, transport = storage_with([], data=big)
    with pytest.raises(errors.WorkerError) as info:
        storage.fetch_input(str(tmp_path / "in"))
    assert info.value.code == errors.INPUT_TOO_LARGE and transport.calls == []


@pytest.mark.parametrize("status,code", [(404, errors.INPUT_MISSING), (403, errors.BAD_URL), (401, errors.BAD_URL),
                                         (302, errors.BAD_URL), (400, errors.DOWNLOAD_FAILED)])
def test_fetch_status_mapping_without_retry(tmp_path, status, code):
    storage, transport = storage_with([Response(status, {})])
    with pytest.raises(errors.WorkerError) as info:
        storage.fetch_input(str(tmp_path / "in"))
    assert info.value.code == code and len(transport.calls) == 1
    assert "://" not in info.value.message


def test_fetch_retries_transient_then_succeeds(tmp_path):
    storage, transport = storage_with([TransientError("reset"), Response(503, {}), Response(200, {}, DATA)])
    assert storage.fetch_input(str(tmp_path / "in")) == len(DATA)
    assert len(transport.calls) == 3


def test_fetch_gives_up_after_three_tries(tmp_path):
    storage, transport = storage_with([TransientError("a"), TransientError("b"), Response(500, {})])
    with pytest.raises(errors.WorkerError) as info:
        storage.fetch_input(str(tmp_path / "in"))
    assert info.value.code == errors.DOWNLOAD_FAILED and len(transport.calls) == 3


def test_put_file_and_json(tmp_path):
    storage, transport = storage_with([Response(200, {}), Response(201, {}), Response(204, {})])
    path = tmp_path / "instrumental.m4a"
    path.write_bytes(b"m4a")
    assert storage.put_file("instrumental", str(path), "audio/mp4").endswith("/instrumental.m4a")
    assert storage.put_json("lyrics", b"{}").endswith("/lyrics.json")
    assert storage.put_json("manifest", b"{}").endswith("/manifest.json")
    (m1, u1, k1), (m2, u2, k2), (m3, u3, k3) = transport.calls
    assert m1 == "PUT" and k1["body_path"] == str(path) and k1["headers"]["Content-Type"] == "audio/mp4"
    assert k2["headers"]["Content-Type"] == "application/json" and "/lyrics.json?" in u2
    assert "/manifest.json?" in u3


def test_put_retries_5xx_but_not_403(tmp_path):
    storage, transport = storage_with([Response(500, {}), Response(200, {})])
    storage.put_json("manifest", b"{}")
    assert len(transport.calls) == 2
    storage, transport = storage_with([Response(403, {})])
    with pytest.raises(errors.WorkerError) as info:
        storage.put_json("manifest", b"{}")
    assert info.value.code == errors.UPLOAD_FAILED and len(transport.calls) == 1


def test_guard_objects(tmp_path):
    marker = json.dumps({"schema": "pixl.cloudstudio.attempt", "v": 1, "runpodJobId": "j", "attempts": 1}).encode()
    storage, transport = storage_with([Response(404, {}), Response(200, {}, marker), Response(200, {})])
    assert storage.get_guard_json("manifest") is None
    assert storage.get_guard_json("attempt")["attempts"] == 1
    storage.put_attempt(b"{}")
    assert "/manifest.json?" in transport.calls[0][1] and "/attempt.json?" in transport.calls[1][1]
    assert transport.calls[2][0] == "PUT" and "/attempt.json?" in transport.calls[2][1]


def test_delete_input_is_best_effort():
    storage, transport = storage_with([TransientError("down")])
    storage.delete_input()  # no exception
    assert transport.calls[0][0] == "DELETE"


def test_private_addresses_are_refused(monkeypatch):
    def fake(host, port, type=0):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.5", port))]
    monkeypatch.setattr(socket, "getaddrinfo", fake)
    with pytest.raises(errors.WorkerError) as info:
        _public_addresses("bucket.example.com", 443)
    assert info.value.code == errors.BAD_URL
    monkeypatch.setattr(socket, "getaddrinfo",
                        lambda h, p, type=0: [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("::1", p, 0, 0))])
    with pytest.raises(errors.WorkerError):
        _public_addresses("bucket.example.com", 443)
    monkeypatch.setattr(socket, "getaddrinfo",
                        lambda h, p, type=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("104.18.2.3", p))])
    assert _public_addresses("bucket.example.com", 443) == ["104.18.2.3"]


def test_volume_storage_round_trip(tmp_path):
    data = b"volume-audio" * 1000
    doc = load_example("job.input.volume.json")
    doc["audio"]["bytes"] = len(data)
    doc["audio"]["sha256"] = hashlib.sha256(data).hexdigest()
    caps = load_caps({"PIXL_VOLUME_ROOT": str(tmp_path)})
    job = validate_job(doc, caps)
    (tmp_path / "in").mkdir()
    (tmp_path / job.audio.key).write_bytes(data)
    storage = VolumeStorage(job, caps)
    assert storage.fetch_input(str(tmp_path / "local.m4a")) == len(data)
    src = tmp_path / "x.m4a"
    src.write_bytes(b"out")
    key = storage.put_file("instrumental", str(src), "audio/mp4")
    assert (tmp_path / key).read_bytes() == b"out"
    assert storage.get_guard_json("manifest") is None
    storage.put_json("manifest", b'{"status":"ok"}')
    assert storage.get_guard_json("manifest") == {"status": "ok"}
    storage.delete_input()
    assert not (tmp_path / job.audio.key).exists()


def test_volume_sweep(tmp_path):
    (tmp_path / "in").mkdir()
    (tmp_path / "out" / "old").mkdir(parents=True)
    (tmp_path / "out" / "new").mkdir(parents=True)
    old_in = tmp_path / "in" / "a.m4a"
    old_in.write_bytes(b"x")
    now = time.time()
    os.utime(old_in, (now - 8 * 86400, now - 8 * 86400))
    os.utime(tmp_path / "out" / "old", (now - 31 * 86400, now - 31 * 86400))
    assert sweep_volume(str(tmp_path), now=now) == 2
    assert not old_in.exists() and (tmp_path / "out" / "new").exists()


# ---- the real transport over TLS --------------------------------------------------------------------------

@pytest.fixture(scope="module")
def tls_server(tmp_path_factory):
    openssl = shutil.which("openssl")
    if not openssl:
        pytest.skip("openssl CLI not available")
    d = tmp_path_factory.mktemp("tls")
    cert, key = d / "cert.pem", d / "key.pem"
    subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj",
                    "/CN=bucket.test.example", "-addext", "subjectAltName=DNS:bucket.test.example",
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    store: dict[str, bytes] = {"/in/a.m4a": DATA}
    seen: list = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            seen.append(("GET", self.path, dict(self.headers)))
            path = self.path.split("?")[0]
            if path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "https://elsewhere.example/")
                self.end_headers()
                return
            body = store.get(path)
            if body is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_PUT(self):
            length = int(self.headers.get("Content-Length", "0"))
            store[self.path.split("?")[0]] = self.rfile.read(length)
            seen.append(("PUT", self.path, dict(self.headers)))
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(cert), str(key))
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    client_ctx = ssl.create_default_context(cafile=str(cert))
    yield server.server_address[1], client_ctx, store, seen
    server.shutdown()


def test_http_transport_streams_and_uploads(tls_server, tmp_path, monkeypatch):
    port, client_ctx, store, seen = tls_server
    import pixl_worker.storage as S

    real_create = socket.create_connection
    monkeypatch.setattr(S.socket, "create_connection",
                        lambda addr, timeout=None: real_create(("127.0.0.1", port), timeout))
    transport = HttpTransport(resolver=lambda host, p: ["127.0.0.1"], context=client_ctx)
    chunks = []
    resp = transport.request("GET", "https://bucket.test.example/in/a.m4a?X-Amz-Signature=x", sink=chunks.append,
                             max_body=len(DATA), timeout=5)
    assert resp.status == 200 and b"".join(chunks) == DATA
    with pytest.raises(TooLarge):
        transport.request("GET", "https://bucket.test.example/in/a.m4a?q=1", sink=lambda c: None, max_body=10,
                          timeout=5)
    assert transport.request("GET", "https://bucket.test.example/missing", timeout=5).status == 404
    assert transport.request("GET", "https://bucket.test.example/redirect", timeout=5).status == 302
    src = tmp_path / "up.bin"
    src.write_bytes(b"uploaded" * 1000)
    resp = transport.request("PUT", "https://bucket.test.example/out/x.m4a?X-Amz-Signature=y",
                             headers={"Content-Type": "audio/mp4"}, body_path=str(src), timeout=5)
    assert resp.status == 200 and store["/out/x.m4a"] == b"uploaded" * 1000
    method, path, headers = seen[-1]
    assert headers.get("Host") == "bucket.test.example" and headers.get("Content-Type") == "audio/mp4"
    resp = transport.request("PUT", "https://bucket.test.example/out/m.json?s=1", body=b'{"a":1}',
                             headers={"Content-Type": "application/json"}, timeout=5)
    assert resp.status == 200 and store["/out/m.json"] == b'{"a":1}'


def test_http_transport_rejects_a_wrong_certificate(tls_server, monkeypatch):
    port, _, _, _ = tls_server
    import pixl_worker.storage as S

    real_create = socket.create_connection
    monkeypatch.setattr(S.socket, "create_connection",
                        lambda addr, timeout=None: real_create(("127.0.0.1", port), timeout))
    transport = HttpTransport(resolver=lambda host, p: ["127.0.0.1"])  # system trust store: self-signed fails
    with pytest.raises(TransientError):
        transport.request("GET", "https://bucket.test.example/in/a.m4a", timeout=5)


def test_http_transport_falls_through_an_unreachable_address(tls_server, monkeypatch):
    # A host without IPv6 routing: the first (IPv6) address can't be reached, the IPv4 one can.
    port, client_ctx, _, _ = tls_server
    import pixl_worker.storage as S

    tried = []
    real_create = socket.create_connection

    def create(addr, timeout=None):
        tried.append(addr[0])
        if addr[0] == "2001:db8::1":
            raise OSError(101, "Network is unreachable")
        return real_create(("127.0.0.1", port), timeout)

    monkeypatch.setattr(S.socket, "create_connection", create)
    transport = HttpTransport(resolver=lambda host, p: ["2001:db8::1", "127.0.0.1"], context=client_ctx)
    chunks = []
    resp = transport.request("GET", "https://bucket.test.example/in/a.m4a?X-Amz-Signature=x", sink=chunks.append,
                             max_body=len(DATA), timeout=5)
    assert resp.status == 200 and b"".join(chunks) == DATA
    assert tried == ["2001:db8::1", "127.0.0.1"]
    monkeypatch.setattr(S.socket, "create_connection", lambda addr, timeout=None: (_ for _ in ()).throw(
        OSError(101, "Network is unreachable")))
    with pytest.raises(TransientError):  # no address reachable: a retryable failure, as before
        transport.request("GET", "https://bucket.test.example/in/a.m4a", timeout=5)
