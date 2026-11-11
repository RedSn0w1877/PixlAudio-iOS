"""deploy/library_janitor.py (cloud-library-janitor.yml) against a fake bucket behind presigned URLs: the listing
(pages, namespaces, odd answers), which renders go and in what order, manifest before audio, nothing below the
limit, the dry run, failures, that only lib/ is ever touched and nothing secret or identifying is printed, and
the workflow file. No network."""

import base64
import io
import json
import sys
import urllib.error
import urllib.parse
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy"))

import e2e as E  # noqa: E402
import library_janitor as J  # noqa: E402
from conftest import EXAMPLE_HOST  # noqa: E402

KEYS = E.Keys(endpoint_id="dummyendpoint01", runpod_key="rpa_DUMMYKEY0000", r2_endpoint=f"https://{EXAMPLE_HOST}",
              bucket="pixl-cloud-studio", access_key_id="DUMMYACCESSKEYID", secret_access_key="dummy-secret-0000")
SECRETS = ("rpa_DUMMYKEY0000", "DUMMYACCESSKEYID", "dummy-secret-0000", "dummyendpoint01")
NOW = 1_800_000_000.0
DAY = 86400.0
MB = 1_000_000


class Resp:
    def __init__(self, status, body=b""):
        self.status, self.body = status, body

    def read(self, size=-1):
        body, self.body = self.body, b""
        return body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeBucket:
    """R2 behind presigned URLs: ListObjectsV2 with pages and DELETE. `objects` maps key -> (size, age in days)."""

    def __init__(self, objects, *, page=1000, refuse=(), namespace=True, list_status=200):
        self.objects = dict(objects)
        self.page, self.refuse, self.namespace, self.list_status = page, set(refuse), namespace, list_status
        self.log, self.lists = [], 0

    def __call__(self, req, timeout=None):
        url = req.full_url
        parts = urllib.parse.urlsplit(url)
        assert parts.netloc == EXAMPLE_HOST and "X-Amz-Signature=" in url, "every request is presigned for the bucket"
        query = urllib.parse.parse_qs(parts.query)
        path = urllib.parse.unquote(parts.path)
        method = req.get_method()
        if method == "GET" and path == "/pixl-cloud-studio":
            assert query["list-type"] == ["2"] and query["max-keys"] == ["1000"]
            self.lists += 1
            self.log.append(("LIST", query["prefix"][0], query.get("continuation-token", [None])[0]))
            if self.list_status != 200:
                raise urllib.error.HTTPError(url, self.list_status, "x", {}, io.BytesIO(
                    b"<Error><Code>AccessDenied</Code><Message>no</Message></Error>"))
            return Resp(200, self._listing(query["prefix"][0], query.get("continuation-token", [None])[0]))
        assert path.startswith("/pixl-cloud-studio/")
        key = path[len("/pixl-cloud-studio/"):]
        self.log.append((method, key))
        if method == "DELETE":
            if key in self.refuse:
                raise urllib.error.HTTPError(url, 403, "Forbidden", {}, io.BytesIO(b""))
            if key not in self.objects:
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, io.BytesIO(b""))
            del self.objects[key]
            return Resp(204)
        raise AssertionError(f"the janitor made a {method} request")

    def _listing(self, prefix, token):
        keys = sorted(k for k in self.objects if k.startswith(prefix))
        start = int(token) if token else 0
        chunk = keys[start:start + self.page]
        more = start + self.page < len(keys)
        ns = ' xmlns="http://s3.amazonaws.com/doc/2006-03-01/"' if self.namespace else ""
        out = [f'<?xml version="1.0" encoding="UTF-8"?><ListBucketResult{ns}><Name>pixl-cloud-studio</Name>'
               f"<Prefix>{prefix}</Prefix><KeyCount>{len(chunk)}</KeyCount><MaxKeys>1000</MaxKeys>"
               f"<IsTruncated>{'true' if more else 'false'}</IsTruncated>"]
        for key in chunk:
            size, age_days = self.objects[key]
            stamp = E.time.strftime("%Y-%m-%dT%H:%M:%S.000Z", E.time.gmtime(NOW - age_days * DAY))
            out.append(f"<Contents><Key>{key}</Key><LastModified>{stamp}</LastModified><ETag>&quot;abc&quot;</ETag>"
                       f"<Size>{size}</Size><StorageClass>STANDARD</StorageClass></Contents>")
        if more:
            out.append(f"<NextContinuationToken>{start + self.page}</NextContinuationToken>")
        out.append("</ListBucketResult>")
        return "".join(out).encode()


def render(video, slot="sp-studio", *, mb=25, age=1.0, version=1, manifest=True, audio=True):
    out = {}
    if audio:
        out[f"lib/v{version}/{video}/{slot}.flac"] = (mb * MB, age + 0.0001)  # uploaded just before its manifest
    if manifest:
        out[f"lib/v{version}/{video}/{slot}.json"] = (1100, age)
    return out


def library(count, mb=25, **kw):
    objects = {}
    for i in range(count):
        objects.update(render(f"video{i:06d}", mb=mb, age=count - i, **kw))  # video000000 is the oldest
    return objects


def run(bucket, *, limit_gb=8.0, dry_run=False):
    r2 = E.R2(KEYS, opener=bucket, sleep=lambda s: None)
    return J.run(r2, limit_bytes=int(limit_gb * J.GB), dry_run=dry_run, now=NOW)


def deleted(bucket):
    return [key for method, key in ((entry[0], entry[1]) for entry in bucket.log) if method == "DELETE"]


# ---- the listing -------------------------------------------------------------------------------------------

def test_listing_follows_every_page_and_only_asks_for_lib():
    objects = library(25)
    objects["in/3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804.flac"] = (90 * MB, 3)
    objects["out/3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804/manifest.json"] = (900, 3)
    bucket = FakeBucket(objects, page=7)
    found = J.list_library(E.R2(KEYS, opener=bucket, sleep=lambda s: None))
    assert len(found) == 50 and all(o.key.startswith("lib/") for o in found)
    assert bucket.lists == 8 and {entry[1] for entry in bucket.log} == {"lib/"}
    assert [entry[2] for entry in bucket.log] == [None, "7", "14", "21", "28", "35", "42", "49"]
    first = next(o for o in found if o.key == "lib/v1/video000000/sp-studio.json")
    assert first.size == 1100 and first.modified == pytest.approx(NOW - 25 * DAY, abs=1)


def test_the_listing_is_read_with_or_without_the_s3_namespace_and_with_escaped_keys():
    for namespace in (True, False):
        bucket = FakeBucket(render("J7p4bzqLvCw"), namespace=namespace)
        assert len(J.list_library(E.R2(KEYS, opener=bucket, sleep=lambda s: None))) == 2
    body = (b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IsTruncated>false</IsTruncated>'
            b"<Contents><Key>lib/v1/a&amp;b/x.flac</Key><LastModified>2026-10-07T10:00:00.000Z</LastModified>"
            b"<Size>12</Size></Contents><Contents><Key>lib/v1/c/y.json</Key><LastModified>not a date</LastModified>"
            b"<Size>3</Size></Contents><CommonPrefixes><Prefix>lib/v1/</Prefix></CommonPrefixes></ListBucketResult>")
    objects, token = J.parse_page(body)
    assert token is None and [(o.key, o.size) for o in objects] == [("lib/v1/a&b/x.flac", 12), ("lib/v1/c/y.json", 3)]
    assert objects[0].modified == pytest.approx(1791367200.0) and objects[1].modified == 0.0
    # the app's own listing fixture (another prefix) parses too
    fixture = ROOT.parents[1] / "Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud-phone/s3.list.xml"
    if fixture.is_file():
        objects, token = J.parse_page(fixture.read_bytes())
        assert token is None and [o.key for o in objects] == ["out/readme&notes.txt"]


@pytest.mark.parametrize("body, why", [
    (b"not xml at all", "not XML"),
    (b"<Error><Code>AccessDenied</Code></Error>", "not a listing"),
    (b"<ListBucketResult><Contents><Key>lib/v1/a/x.flac</Key><Size>big</Size></Contents></ListBucketResult>",
     "without a size"),
    (b"<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>", "no continuation token"),
])
def test_a_listing_that_cannot_be_trusted_stops_the_run_before_anything_is_deleted(body, why, capsys):
    with pytest.raises(E.E2EError, match=why):
        J.parse_page(body)

    def opener(req, timeout=None):
        assert req.get_method() == "GET", "nothing may be deleted on a listing that makes no sense"
        return Resp(200, body)

    assert J.run(E.R2(KEYS, opener=opener, sleep=lambda s: None), limit_bytes=0, dry_run=False, now=NOW) == 1
    assert "library janitor FAILED" in capsys.readouterr().out


def test_a_refused_listing_fails_with_the_status_and_nothing_secret(capsys):
    bucket = FakeBucket(library(3), list_status=403)
    assert run(bucket) == 1
    out = capsys.readouterr().out
    assert "library janitor FAILED: list lib/ (R2 ListObjectsV2): HTTP 403 (AccessDenied: no)" in out
    assert deleted(bucket) == [] and not any(secret in out for secret in SECRETS) and "X-Amz" not in out


def test_a_listing_that_never_ends_is_given_up_on(monkeypatch):
    bucket = FakeBucket(library(30), page=5)
    with pytest.raises(E.E2EError, match="did not end"):
        J.list_library(E.R2(KEYS, opener=bucket, sleep=lambda s: None), max_pages=3)


# ---- what goes, and in what order --------------------------------------------------------------------------

def test_under_the_limit_nothing_is_deleted(capsys):
    bucket = FakeBucket(library(300))  # 7.5 GB
    assert run(bucket) == 0
    out = capsys.readouterr().out
    assert deleted(bucket) == [] and "under the limit, nothing to delete" in out
    assert "library: 600 objects, 7.50 GB of 8.00 GB: 300 renders with audio" in out


def test_over_the_limit_the_oldest_renders_go_until_it_is_under_manifest_first(capsys):
    bucket = FakeBucket(library(400))  # 10 GB: 2 GB over, 25 MB a render
    assert run(bucket) == 0
    gone = deleted(bucket)
    # 81 renders: 80 would leave 8.0003 GB with the manifests' own bytes
    assert len(gone) == 162 and bucket.lists == 1
    for i in range(81):  # the oldest ones, oldest first, and each manifest before its audio
        assert gone[2 * i] == f"lib/v1/video{i:06d}/sp-studio.json"
        assert gone[2 * i + 1] == f"lib/v1/video{i:06d}/sp-studio.flac"
    assert sum(size for size, _ in bucket.objects.values()) <= 8 * J.GB
    assert "lib/v1/video000081/sp-studio.json" in bucket.objects  # the first one that stays
    out = capsys.readouterr().out
    assert "deleted 81 renders (162 objects), freed 2.03 GB" in out and "the library is now 7.98 GB" in out
    assert "video" not in out and "lib/v1" not in out  # counts and sizes only: never a key or a video id


def test_a_dry_run_says_what_it_would_do_and_deletes_nothing(capsys):
    bucket = FakeBucket(library(400))
    assert run(bucket, dry_run=True) == 0
    out = capsys.readouterr().out
    assert deleted(bucket) == [] and len(bucket.objects) == 800
    assert "(dry run): would delete 81 renders, 2.03 GB, the oldest 400.0 days old, leaving 7.98 GB" in out


def test_what_no_phone_can_use_goes_before_any_real_render():
    objects = library(320)  # 8 GB of good renders, the oldest 320 days old
    objects.update(render("orphanOld01", mb=40, age=0.5, manifest=False))    # its manifest never came
    objects.update(render("orphanNew01", mb=40, age=0.01, manifest=False))   # 14 minutes old: maybe still coming
    objects.update(render("olderLib001", mb=40, age=2.0, version=0))         # a library version nobody reads now
    objects.update(render("noteOnly001", "enhanced", age=900.0, audio=False))  # "nothing to restore", 1 KB
    bucket = FakeBucket(objects)
    assert run(bucket) == 0
    gone = deleted(bucket)
    assert gone[:3] == ["lib/v1/orphanOld01/sp-studio.flac", "lib/v0/olderLib001/sp-studio.json",
                        "lib/v0/olderLib001/sp-studio.flac"]
    assert gone[3] == "lib/v1/video000000/sp-studio.json"  # then the oldest real render
    assert "lib/v1/orphanNew01/sp-studio.flac" in bucket.objects  # a render in progress is the newest thing there
    assert "lib/v1/noteOnly001/enhanced.json" in bucket.objects   # ancient, but deleting it frees nothing
    assert sum(size for size, _ in bucket.objects.values()) <= 8 * J.GB


def test_plan_orders_by_the_manifests_date_and_takes_no_more_than_needed():
    objects = [J.Obj("lib/v1/aaa/sp-studio.flac", 30 * MB, NOW - 5 * DAY),
               J.Obj("lib/v1/aaa/sp-studio.json", 1000, NOW - 1 * DAY),      # its manifest is what dates it
               J.Obj("lib/v1/bbb/sp-wide.json", 1000, NOW - 3 * DAY),
               J.Obj("lib/v1/bbb/sp-wide.flac", 30 * MB, NOW - 3 * DAY),
               J.Obj("lib/v1/bbb/sp-hall.json", 1000, NOW - 2 * DAY),        # another render of the same song
               J.Obj("lib/v1/bbb/sp-hall.flac", 30 * MB, NOW - 2 * DAY),
               J.Obj("lib/v1/ccc/enhanced.flac", 30 * MB, NOW - 9 * DAY),
               J.Obj("lib/v1/ccc/enhanced.json", 1000, NOW - 9 * DAY)]
    renders = J.group(objects)
    assert sorted(r.stem for r in renders) == ["lib/v1/aaa/sp-studio", "lib/v1/bbb/sp-hall", "lib/v1/bbb/sp-wide",
                                               "lib/v1/ccc/enhanced"]
    assert J.plan(renders, 200 * MB, now=NOW) == []
    order = [r.stem for r in J.plan(renders, 0, now=NOW)]
    assert order == ["lib/v1/ccc/enhanced", "lib/v1/bbb/sp-wide", "lib/v1/bbb/sp-hall", "lib/v1/aaa/sp-studio"]
    assert [r.stem for r in J.plan(renders, 95 * MB, now=NOW)] == ["lib/v1/ccc/enhanced"]
    assert [r.stem for r in J.plan(renders, 89 * MB, now=NOW)] == ["lib/v1/ccc/enhanced", "lib/v1/bbb/sp-wide"]
    for chosen in J.plan(renders, 0, now=NOW):
        assert [o.key.rsplit(".", 1)[1] for o in chosen.deletion_order()] == ["json", "flac"]


def test_a_manifest_that_cannot_be_deleted_keeps_its_audio_and_fails_the_run(capsys):
    objects = library(400)
    stuck = "lib/v1/video000001/sp-studio.json"
    bucket = FakeBucket(objects, refuse={stuck})
    assert run(bucket) == 1
    gone = deleted(bucket)
    assert stuck in gone and "lib/v1/video000001/sp-studio.flac" not in gone  # never audio from under a manifest
    assert "lib/v1/video000001/sp-studio.flac" in bucket.objects and stuck in bucket.objects
    assert "lib/v1/video000002/sp-studio.flac" not in bucket.objects  # the others still went
    out = capsys.readouterr().out
    assert "deleted 80 renders (160 objects)" in out
    assert "::error::library janitor: 1 renders could not be deleted (delete (R2 DELETE): HTTP 403)" in out


def test_audio_that_cannot_be_deleted_after_its_manifest_is_reported_and_expires_on_its_own(capsys):
    stuck = "lib/v1/video000000/sp-studio.flac"
    bucket = FakeBucket(library(400), refuse={stuck})
    assert run(bucket) == 1
    assert "lib/v1/video000000/sp-studio.json" not in bucket.objects and stuck in bucket.objects
    assert "deleted 80 renders (161 objects)" in capsys.readouterr().out


def test_a_bucket_that_refuses_everything_is_left_alone_after_five_tries():
    objects = library(400)
    bucket = FakeBucket(objects, refuse=set(objects))
    assert run(bucket) == 1
    assert len(deleted(bucket)) == 5 and len(bucket.objects) == 800


def test_an_object_that_is_already_gone_counts_as_deleted():
    bucket = FakeBucket(library(400))
    original = bucket._listing

    def listing(prefix, token):  # someone else (the lifecycle rule) removes the oldest render after the listing
        body = original(prefix, token)
        bucket.objects.pop("lib/v1/video000000/sp-studio.json", None)
        bucket.objects.pop("lib/v1/video000000/sp-studio.flac", None)
        return body

    bucket._listing = listing
    assert run(bucket) == 0


def test_only_lib_is_ever_deleted_whatever_the_bucket_lists():
    class Lying(FakeBucket):
        def _listing(self, prefix, token):  # a bucket that answers a lib/ listing with everything it has
            return super()._listing("", token)

    objects = library(10, mb=900)  # 9 GB
    objects["in/3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804.flac"] = (900 * MB, 300)
    objects["out/3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804/instrumental.m4a"] = (900 * MB, 300)
    bucket = Lying(objects)
    assert run(bucket) == 0
    assert deleted(bucket) and all(key.startswith("lib/") for key in deleted(bucket))
    assert "in/3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804.flac" in bucket.objects
    render_out = J.Render("out/x", [J.Obj("out/x.json", 1, 0.0)])
    assert J.delete_render(E.R2(KEYS, opener=bucket, sleep=lambda s: None), render_out)[2] is not None


def test_an_empty_library_is_fine(capsys):
    assert run(FakeBucket({})) == 0
    assert "library: 0 objects, 0.00 GB of 8.00 GB" in capsys.readouterr().out


# ---- main: the secret, the blob, the flags -----------------------------------------------------------------

def test_without_the_secret_it_says_so_and_succeeds(monkeypatch, capsys):
    monkeypatch.delenv("CLOUD_DEFAULTS_KEY", raising=False)
    assert J.main([]) == 0
    assert "CLOUD_DEFAULTS_KEY secret is not set" in capsys.readouterr().out
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", E.PLACEHOLDER_KEY)
    assert J.main([]) == 0
    assert "placeholder key" in capsys.readouterr().out


def test_a_bad_key_or_blob_fails_before_anything_is_sent(monkeypatch, capsys, tmp_path):
    blob = tmp_path / "CloudDefaults.enc"
    blob.write_bytes(b"PXCD1" + b"\x00" * 60)
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", "not base64!")
    assert J.main(["--blob", str(blob)]) == 1
    assert "not base64" in capsys.readouterr().out
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", base64.b64encode(bytes(range(32))).decode())
    assert J.main(["--blob", str(tmp_path / "missing.enc")]) == 1
    assert "could not be read" in capsys.readouterr().out
    assert J.main(["--blob", str(blob), "--limit-gb", "50"]) == 1
    assert "between 0 and 10" in capsys.readouterr().out


def test_main_runs_with_the_blobs_keys_and_honours_the_dry_run_switches(monkeypatch, capsys, tmp_path):
    pytest.importorskip("cryptography")
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    key = bytes(range(32))
    payload = {"v": 1, "runpodEndpointId": "dummyendpoint01", "runpodKey": "rpa_DUMMYKEY0000",
               "r2Endpoint": EXAMPLE_HOST.split(".")[0], "bucket": "pixl-cloud-studio",
               "r2AccessKeyId": "DUMMYACCESSKEYID", "r2SecretAccessKey": "dummy-secret-0000"}
    blob = tmp_path / "CloudDefaults.enc"
    blob.write_bytes(E.MAGIC + b"\x01" * 12 + AESGCM(key).encrypt(b"\x01" * 12, json.dumps(payload).encode(), None))
    monkeypatch.setenv("CLOUD_DEFAULTS_KEY", base64.b64encode(key).decode())
    seen = []

    def fake_run(r2, *, limit_bytes, dry_run, now=None):
        seen.append((r2.keys.bucket, limit_bytes, dry_run))
        return 0

    monkeypatch.setattr(J, "run", fake_run)
    monkeypatch.delenv("JANITOR_DRY_RUN", raising=False)
    assert J.main(["--blob", str(blob)]) == 0
    assert J.main(["--blob", str(blob), "--dry-run", "--limit-gb", "2.5"]) == 0
    monkeypatch.setenv("JANITOR_DRY_RUN", "true")  # the workflow's checkbox
    assert J.main(["--blob", str(blob)]) == 0
    monkeypatch.setenv("JANITOR_DRY_RUN", "false")  # a scheduled run: the input is empty or false
    assert J.main(["--blob", str(blob)]) == 0
    assert seen == [("pixl-cloud-studio", 8_000_000_000, False), ("pixl-cloud-studio", 2_500_000_000, True),
                    ("pixl-cloud-studio", 8_000_000_000, True), ("pixl-cloud-studio", 8_000_000_000, False)]
    assert not any(secret in capsys.readouterr().out for secret in SECRETS)


def test_the_limit_leaves_room_inside_the_free_tier():
    assert J.DEFAULT_LIMIT_GB == 8.0 and J.GB == 10 ** 9 and J.PREFIX == "lib/"
    assert J.parse_time("2026-11-10T19:02:11.000Z") == 1794337331.0 and J.parse_time("") == 0.0
    assert J.parse_time(None) == 0.0 and J.gb(27_100_200) == "0.03 GB"


# ---- the workflow ------------------------------------------------------------------------------------------

def test_the_workflow_runs_daily_without_an_environment_and_execs_python():
    found = [p / ".github" / "workflows" / "cloud-library-janitor.yml" for p in ROOT.parents]
    workflow = next((w for w in found if w.is_file()), None)
    if workflow is None:
        pytest.skip("the repository's workflows are not in this checkout")
    text = workflow.read_text(encoding="utf-8")
    trigger = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
    assert "schedule:" in trigger and "workflow_dispatch:" in trigger and "push" not in trigger
    assert "cron: '43 4 * * *'" in trigger
    body = text.split("\njobs:\n", 1)[1]
    # CLOUD_DEFAULTS_KEY is a repository secret: no environment (the runpod one is limited to main and holds
    # only the deploy key), and no other secret is handed to the job
    assert "environment:" not in body and "RUNPOD_API_KEY" not in text
    assert "CLOUD_DEFAULTS_KEY: ${{ secrets.CLOUD_DEFAULTS_KEY }}" in body and body.count("secrets.") == 1
    assert "contents: read" in text and "cancel-in-progress: false" in text
    assert 'exec "$RUNNER_TEMP/janitor-venv/bin/python" cloud/runpod-worker/deploy/library_janitor.py' in body
    assert "--require-hashes" in body and "e2e-requirements.txt" in body
    # the input reaches the script through the environment, never pasted into the shell
    assert "JANITOR_DRY_RUN: ${{ inputs.dry_run }}" in body
    for line in body.splitlines():
        if line.strip().startswith(("run:", "exec ")):
            assert "${{" not in line, line
    for line in text.splitlines():
        if "uses:" in line:
            ref = line.split("@", 1)[1].split()[0]
            assert len(ref) == 40 and all(ch in "0123456789abcdef" for ch in ref), line  # pinned to a commit
    ci = workflow.parent / "ci.yml"
    if ci.is_file():  # worker-side workflows never hold a macOS runner
        assert "'.github/workflows/cloud-library-janitor.yml'" in ci.read_text(encoding="utf-8")
