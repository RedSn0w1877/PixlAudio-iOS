"""The build's guard rails: weights.lock vs the Dockerfile, the small-file fetcher's verification, the pip-check
allowlist, the fixture drift check and the lock generator's base-package filter."""

import hashlib
import io
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "ci"))

import check_fixtures  # noqa: E402
import check_weights  # noqa: E402
import fetch_small  # noqa: E402
import lock  # noqa: E402
import pip_check  # noqa: E402

DOCKERFILE = (ROOT / "Dockerfile").read_text(encoding="utf-8")
WEIGHTS = (ROOT / "weights.lock").read_text(encoding="utf-8")
SEP_SHA = "60347271e8493fdff28ef558c3b2297afb869a1f4462594ed548038264bec395"


def test_the_real_dockerfile_and_lock_agree():
    assert check_weights.check(DOCKERFILE, WEIGHTS) == []


def test_every_large_row_is_a_real_pinned_url():
    rows = fetch_small.parse_lock(WEIGHTS)
    large = [r for r in rows if r.kind == "large"]
    assert {r.slot for r in large} == {"sep", "demucs", "aligner", "asr"}
    assert sum(r.bytes for r in large) > 6_900_000_000  # ~7.1 GB of weights
    for row in rows:
        assert "/resolve/main/" not in row.url
    demucs = [r for r in large if r.slot == "demucs"]
    for row in demucs:  # demucs names each file after the start of its own sha256 and re-checks it
        assert row.sha256.startswith(row.dest.rsplit("-", 1)[1].split(".")[0])


@pytest.mark.parametrize("mutate,expect", [
    (lambda d, w: (d.replace(SEP_SHA, "0" * 64, 1), w), "does not match any large row"),
    (lambda d, w: (d.replace("--link --chmod=644 --checksum=sha256:" + SEP_SHA,
                             "--chmod=644 --checksum=sha256:" + SEP_SHA, 1), w), "needs --link"),
    (lambda d, w: (d.replace("CMD [\"python3\", \"-u\"", "RUN echo hi\nCMD [\"python3\", \"-u\"", 1), w),
     "final stage must not RUN"),
    (lambda d, w: (d.replace("@sha256:eee11b3b3872a8c838e35ef48f08b2d5def2080902c7f666831310ca1a0ef2be", "", 1), w),
     "ARG BASE must default"),
    (lambda d, w: (d.replace("# syntax=docker/dockerfile:1.10@sha256:", "# syntax=docker/dockerfile:1.10#", 1), w),
     "frontend must be pinned"),
    (lambda d, w: (d, w.replace("24988f47270cb3529b62c4f3bbb8234f4586de9b/config.yaml", "main/config.yaml")),
     "must pin a commit revision"),
    (lambda d, w: (d, w + "large  sep  " + "1" * 64 + "  10  MIT  /models/sep/extra.bin  https://example.com/x\n"),
     "has no ADD line in the final stage"),
    (lambda d, w: (d, w + "small  sep  nothex  10  MIT  /models/a  https://example.com/a\n"), "sha256 must be"),
])
def test_disagreements_fail(mutate, expect):
    dockerfile, weights = mutate(DOCKERFILE, WEIGHTS)
    errors = check_weights.check(dockerfile, weights)
    assert any(expect in e for e in errors), errors


@pytest.mark.parametrize("row,why", [
    ("small sep " + "a" * 64 + " 10 MIT /models/../etc/passwd https://e.com/x", "dest must be"),
    ("small sep " + "a" * 64 + " 10 MIT /models/a http://e.com/x", "https"),
    ("small sep " + "a" * 64 + " 0 MIT /models/a https://e.com/x", "positive"),
    ("tiny sep " + "a" * 64 + " 10 MIT /models/a https://e.com/x", "kind"),
    ("small sep " + "a" * 64 + " 10 MIT /models/a", "7 columns"),
])
def test_malformed_lock_rows(row, why):
    with pytest.raises(fetch_small.LockError, match=why):
        fetch_small.parse_lock(row)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_fetch_small_verifies_size_and_sha(tmp_path):
    body = b"tokenizer bytes"
    good = fetch_small.Row(1, "small", "aligner", hashlib.sha256(body).hexdigest(), len(body), "Apache-2.0",
                           "/models/aligner/vocab.json", "https://example.com/vocab.json")
    opener = lambda req, timeout: FakeResponse(body)  # noqa: E731
    assert fetch_small.fetch([good], str(tmp_path), opener=opener, sleep=lambda s: None) == 1
    assert (tmp_path / "aligner" / "vocab.json").read_bytes() == body
    bad_sha = good.__class__(**{**good.__dict__, "sha256": "0" * 64, "dest": "/models/aligner/b.json"})
    with pytest.raises(fetch_small.LockError, match="sha256"):
        fetch_small.fetch([bad_sha], str(tmp_path), opener=opener, sleep=lambda s: None)
    too_big = good.__class__(**{**good.__dict__, "bytes": 3, "dest": "/models/aligner/c.json"})
    with pytest.raises(fetch_small.LockError, match="larger"):
        fetch_small.fetch([too_big], str(tmp_path), opener=opener, sleep=lambda s: None)
    assert not (tmp_path / "aligner" / "b.json").exists() and not (tmp_path / "aligner" / "c.json.part").exists()


def test_fetch_small_retries_network_errors_then_gives_up(tmp_path):
    calls = []

    def opener(req, timeout):
        calls.append(1)
        raise OSError("connection reset")

    row = fetch_small.Row(1, "small", "sep", "a" * 64, 5, "MIT", "/models/sep/x", "https://example.com/x")
    with pytest.raises(fetch_small.LockError, match="after 4 tries"):
        fetch_small.fetch([row], str(tmp_path), opener=opener, sleep=lambda s: None)
    assert len(calls) == 4


def test_pip_check_allows_only_qwen_asrs_demo_deps():
    lines = [
        "qwen-asr 0.0.6 requires gradio, which is not installed.",
        "qwen-asr 0.0.6 requires flask, which is not installed.",
        "qwen-asr 0.0.6 requires qwen-omni-utils, which is not installed.",
        "qwen-asr 0.0.6 requires librosa, which is not installed.",
        "msst 0.1.0 has requirement torch<2.12,>=2.0.1, but you have torch 2.12.0.",
        "ipython 9.11.0 requires something, which is not installed.",
    ]
    baseline = {"ipython 9.11.0 requires something, which is not installed."}
    assert pip_check.new_problems(lines, baseline) == [
        "qwen-asr 0.0.6 requires librosa, which is not installed.",
        "msst 0.1.0 has requirement torch<2.12,>=2.0.1, but you have torch 2.12.0.",
    ]


def test_fixture_drift(tmp_path):
    examples, copies = tmp_path / "ex", tmp_path / "copies"
    examples.mkdir()
    assert check_fixtures.drift(examples, copies) == []  # no app copies yet
    copies.mkdir()
    (examples / "a.json").write_text("{}\n")
    (copies / "a.json").write_text("{}\n")
    (copies / "b.json").write_text("{}\n")
    assert check_fixtures.drift(examples, copies) == [
        "b.json: no such example in cloud/runpod-worker/schema/v1/examples"]
    (copies / "a.json").write_text("{ }\n")
    assert len(check_fixtures.drift(examples, copies)) == 2


def test_spatial_table_copies_must_be_byte_identical(tmp_path):
    originals, resources, tests = tmp_path / "spatial", tmp_path / "App" / "Resources", tmp_path / "Tests"
    originals.mkdir()
    table, golden = b'{"schema":"pixl.spatial.preview","v":1}\n', b'{"frames":1024}\n'
    (originals / "spatial_preview_v1.json").write_bytes(table)
    (originals / "spatial_preview_golden_v1.json").write_bytes(golden)
    args = (originals, resources, tests, tmp_path)
    assert check_fixtures.spatial_copies(originals, resources, tests) == []  # the app has no copy yet: fine
    assert check_fixtures.spatial_drift(*args) == []

    (resources / "Audio").mkdir(parents=True)
    asset = resources / "Audio" / "spatial_preview_v1.json"  # anywhere under App/Resources
    asset.write_bytes(table)
    fixtures = tests / "PixlAudioTests" / "Fixtures" / "spatial"  # any Fixtures folder of any test target
    fixtures.mkdir(parents=True)
    (fixtures / "spatial_preview_v1.json").write_bytes(table)
    (fixtures / "spatial_preview_golden_v1.json").write_bytes(golden)
    (tests / "PixlAudioTests" / "spatial_preview_v1.json").write_bytes(b"not a fixture: not looked at")
    (fixtures / "other.json").write_bytes(b"{}")
    copies = check_fixtures.spatial_copies(originals, resources, tests)
    assert len(copies) == 3 and {c.name for _, c in copies} == {"spatial_preview_v1.json",
                                                                 "spatial_preview_golden_v1.json"}
    assert check_fixtures.spatial_drift(*args) == []

    asset.write_bytes(table.replace(b"\n", b"\r\n"))  # one line ending is drift
    (fixtures / "spatial_preview_golden_v1.json").write_bytes(b'{"frames": 1024}\n')  # so is one space
    problems = check_fixtures.spatial_drift(*args)
    assert len(problems) == 2
    assert any(p.startswith("App/Resources/Audio/spatial_preview_v1.json: differs from "
                            "cloud/runpod-worker/schema/v1/spatial/spatial_preview_v1.json") for p in problems)
    assert any(p.startswith("Tests/PixlAudioTests/Fixtures/spatial/spatial_preview_golden_v1.json: differs")
               for p in problems)


def test_the_repositorys_own_copies_are_in_step(capsys):
    assert check_fixtures.main() == 0  # whatever copies this checkout has (none inside the test image) match
    assert "0 drifted file(s)" in capsys.readouterr().out
    originals = sorted(p.name for p in check_fixtures.SPATIAL.glob("*.json"))
    assert originals == ["spatial_preview_golden_v1.json", "spatial_preview_v1.json"]
    for path in check_fixtures.SPATIAL.glob("*.json"):  # written with LF and one trailing newline, on any machine
        raw = path.read_bytes()
        assert b"\r" not in raw and raw.endswith(b"\n") and not raw.endswith(b"\n\n"), path.name


def test_lock_drops_what_the_base_image_provides():
    text = ("absl-py==2.5.0 \\\n    --hash=sha256:aa\n"
            "torch==2.11.0 \\\n    --hash=sha256:bb \\\n    --hash=sha256:cc\n"
            "nvidia-cublas==13.0 \\\n    --hash=sha256:dd\n"
            "triton==3.6.0 \\\n    --hash=sha256:ee\n"
            "zipp==3.23.0 \\\n    --hash=sha256:ff\n")
    kept, dropped = lock.drop_base_packages(text)
    assert kept == "absl-py==2.5.0 \\\n    --hash=sha256:aa\nzipp==3.23.0 \\\n    --hash=sha256:ff\n"
    assert [d.split("==")[0] for d in dropped] == ["torch", "nvidia-cublas", "triton"]


def test_the_committed_lock_is_complete_and_hashed():
    text = (ROOT / "requirements.lock").read_text(encoding="utf-8")
    pins = [line.split(" ")[0] for line in text.splitlines() if line and line[0].isalnum()]
    names = {p.split("==")[0] for p in pins}
    assert {"runpod", "msst", "demucs", "qwen-asr", "transformers", "accelerate", "nagisa", "soynlp"} <= names
    assert not names & {"torch", "torchaudio", "torchvision", "triton", "gradio", "flask"}
    assert "runpod==1.12.0" in pins and "transformers==4.57.6" in pins and "qwen-asr==0.0.6" in pins
    blocks = text.split("\n")
    for k, line in enumerate(blocks):
        if line and line[0].isalnum():
            assert line.endswith("\\") and "--hash=sha256:" in blocks[k + 1], line
