"""op: process end to end with in-memory storage and fake models: the order of the uploads (manifest last), the
input deleted only after a usable result, the guard (duplicate, poisoned), partial results, error manifests,
the rejection manifest for jobs that fail validation, and every manifest/lyrics document against its schema.
The tests that decode and encode real audio need ffmpeg (the Docker test target installs it)."""

import copy
import hashlib
import json
import os
import shutil

import jsonschema
import numpy as np
import pytest

from conftest import EXAMPLE_HOST, load_example, load_schema
from pixl_worker import errors, pipeline
from pixl_worker import audio as A
from pixl_worker.config import load_caps
from pixl_worker.deadline import Deadline
from pixl_worker.errors import WorkerError
from pixl_worker.lyrics import languages
from pixl_worker.lyrics.languages import Token
from pixl_worker.lyrics.postprocess import is_kept_char
from pixl_worker.schema import validate_job
from pixl_worker.selftest import synthetic_song

HAVE_FFMPEG = shutil.which(A.FFMPEG) is not None and shutil.which(A.FFPROBE) is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")
RESULT = jsonschema.Draft202012Validator(load_schema("job.result"))
LYRICS = jsonschema.Draft202012Validator(load_schema("lyrics"))
WORKER = {"version": "1.0.0", "gitSha": "abc1234def56", "gpu": "Fake GPU", "vramGB": 16.0, "cuda": "12.8"}
SECONDS = 12


class MemStorage:
    """The storage driver interface, in memory. `objects` maps slot names to bytes; `ops` records the order."""

    def __init__(self, job, caps, source: bytes, *, guard=True, manifest=None, attempt=None, fail_put=()):
        self.job, self.caps, self.source = job, caps, source
        self.has_guard = guard
        self.objects = {}
        if manifest is not None:
            self.objects["manifest"] = json.dumps(manifest).encode()
        if attempt is not None:
            self.objects["attempt"] = json.dumps(attempt).encode()
        self.ops = []
        self.fail_put = set(fail_put)
        self.input_deleted = False

    def fetch_input(self, dest, *, total_timeout=120.0):
        self.ops.append(("fetch", total_timeout))
        with open(dest, "wb") as fh:
            fh.write(self.source)
        return len(self.source)

    def delete_input(self):
        self.ops.append(("delete_input",))
        self.input_deleted = True

    def _put(self, slot, data):
        if slot in self.fail_put:
            raise WorkerError(errors.UPLOAD_FAILED, f"storage refused the {slot} upload (HTTP 403)")
        self.ops.append(("put", slot))
        self.objects[slot] = data
        return self.job.object_key(slot)

    def put_file(self, slot, path, content_type):
        with open(path, "rb") as fh:
            return self._put(slot, fh.read())

    def put_json(self, slot, data):
        return self._put(slot, data)

    def get_guard_json(self, which):
        raw = self.objects.get(which)
        return json.loads(raw) if raw else None

    def put_attempt(self, data):
        self.ops.append(("put", "attempt"))
        self.objects["attempt"] = data


class HalfVocals:
    model_id = "fake-separator"

    def vocals(self, mix, sr, *, quality="standard", progress=None):
        if progress:
            progress(1, 2)
            progress(2, 2)
        return (mix * 0.5).astype(np.float32)


class WordAligner:
    """A word-timing backend that spreads the kept words of each line evenly over its window."""
    model_id = "fake-aligner"

    def supports(self, language):
        return language in ("ko", "en")

    def align(self, requests):
        out = []
        for r in requests:
            words = ["".join(ch for ch in w if is_kept_char(ch)) for w in r.text.split()]
            words = [w for w in words if w]
            span = len(r.audio) / 16000.0
            step = span / max(1, len(words) + 1)
            out.append([Token(text=w, start_s=step * (k + 0.5), end_s=step * (k + 1.2)) for k, w in enumerate(words)])
        return out


@pytest.fixture(autouse=True)
def aligner_backend():
    languages.clear_backends()
    languages.register_backend(WordAligner())
    yield
    languages.clear_backends()


@pytest.fixture(scope="module")
def song_m4a(tmp_path_factory):
    if not HAVE_FFMPEG:
        pytest.skip("ffmpeg not installed")
    path = tmp_path_factory.mktemp("song") / "song.m4a"
    A.encode(synthetic_song(SECONDS), 44100, str(path), codec="aac", kbps=192)
    return path.read_bytes()


def job_doc(data: bytes, **changes):
    doc = load_example("job.input.process.json")
    doc["audio"]["bytes"] = len(data)
    doc["audio"]["sha256"] = hashlib.sha256(data).hexdigest()
    doc["audio"]["durationMs"] = SECONDS * 1000
    # The synthetic voice sings 0-3 s, 4-7 s, 8-11 s: one line per phrase.
    doc["lyrics"]["lines"] = [
        {"startMs": 0, "endMs": 3000, "text": "별빛 아래 우리 둘이"},
        {"startMs": 4000, "endMs": 7000, "text": "다시 노래해, 오늘 밤"},
        {"startMs": 8000, "endMs": 11000, "text": "(Oh-oh) Stay with me"},
        {"startMs": 11000, "text": ""},
    ]
    for key, value in changes.items():
        doc[key] = value
    return doc


def run(doc, data, tmp_path, *, storage_kwargs=None, models=None, deadline_s=870, runpod_id="rp-job-1", caps_env=None):
    caps = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_TMP_ROOT": str(tmp_path / "work"),
                      **(caps_env or {})})
    job = validate_job(doc, caps)
    holder = {}

    def factory(j, c):
        holder["storage"] = MemStorage(j, c, data, **(storage_kwargs or {}))
        return holder["storage"]

    progress = []
    ctx = pipeline.Context(caps=caps, worker=WORKER, storage_factory=factory, progress=progress.append,
                           cold_start_ms=1234)
    result = pipeline.process(job, runpod_id, models or pipeline.Models(separator=HalfVocals()), ctx,
                              Deadline(deadline_s))
    return result, holder["storage"], progress


@needs_ffmpeg
def test_ok_job_uploads_everything_then_the_manifest_last(song_m4a, tmp_path):
    result, storage, progress = run(job_doc(song_m4a), song_m4a, tmp_path)
    assert result["status"] == "ok", result
    RESULT.validate(result)
    puts = [op[1] for op in storage.ops if op[0] == "put"]
    assert puts == ["attempt", "instrumental", "lyrics", "manifest"]
    assert storage.ops[-1] == ("delete_input",) and storage.input_deleted
    assert json.loads(storage.objects["manifest"]) == result
    inst = result["outputs"]["instrumental"]
    assert inst["samples"] == result["input"]["decodedSamples"] and inst["codec"] == "aac" and inst["kbps"] == 256
    assert inst["sha256"] == hashlib.sha256(storage.objects["instrumental"]).hexdigest()
    assert inst["bytes"] == len(storage.objects["instrumental"])
    assert result["input"]["sha256"] == hashlib.sha256(song_m4a).hexdigest()
    assert abs(result["input"]["decodedSamples"] - SECONDS * 44100) <= 2048
    assert result["timings"]["coldStartMs"] == 1234 and result["timings"]["totalMs"] > 0
    assert result["models"] == {"separator": "fake-separator", "stems4": None, "aligner": "fake-aligner", "asr": None}
    lyrics = json.loads(storage.objects["lyrics"])
    LYRICS.validate(lyrics)
    assert lyrics["mode"] == "aligned" and lyrics["language"] == "ko"
    assert [line["timing"] for line in lyrics["lines"]] == ["word", "word", "word", "line"]
    for line in lyrics["lines"]:
        for word in line["words"]:  # c0/c1 rebuild each word from the original text (punctuation kept out)
            assert line["text"][word["c0"]:word["c1"]].replace("-", "") == word["text"]
    assert result["lyrics"]["wordTimedLines"] == 3 and result["lyrics"]["sha256"] == hashlib.sha256(
        storage.objects["lyrics"]).hexdigest()
    assert progress[0] == "download:0" and progress[-1] == "done:100"
    assert any(p.startswith("separate:") for p in progress)
    assert not os.path.exists(tmp_path / "work" / job_doc(song_m4a)["jobKey"])  # work dir cleaned up


@needs_ffmpeg
def test_flac_output_has_the_same_sample_count(song_m4a, tmp_path):
    doc = job_doc(song_m4a, tasks=["instrumental"])
    doc["output"]["codec"] = "flac"
    doc["output"]["put"]["instrumental"] = doc["output"]["put"]["instrumental"].replace(
        "instrumental.m4a", "instrumental.flac")
    result, storage, _ = run(doc, song_m4a, tmp_path)
    RESULT.validate(result)
    inst = result["outputs"]["instrumental"]
    assert inst["codec"] == "flac" and inst["kbps"] is None and inst["key"].endswith("instrumental.flac")
    assert storage.objects["instrumental"][:4] == b"fLaC"
    assert result["lyrics"] is None and inst["samples"] == result["input"]["decodedSamples"]


@needs_ffmpeg
def test_lyrics_failure_is_partial_and_keeps_the_instrumental(song_m4a, tmp_path, monkeypatch):
    def boom(*args, **kwargs):
        raise WorkerError(errors.GPU_OOM, "the GPU ran out of memory while aligning lyrics", refresh_worker=True)

    monkeypatch.setattr(pipeline, "run_lyrics", boom)
    result, storage, _ = run(job_doc(song_m4a), song_m4a, tmp_path)
    assert result["status"] == "partial" and result.pop("refresh_worker") is True
    RESULT.validate(result)
    assert "instrumental" in result["outputs"] and result["lyrics"] is None
    assert any("lyrics: failed (GPU_OOM)" in w for w in result["warnings"])
    assert "lyrics" not in storage.objects and storage.input_deleted


@needs_ffmpeg
@pytest.mark.parametrize("failure, code", [
    (WorkerError(errors.DEADLINE, "the job ran out of time during lyrics"), "DEADLINE"),
    (RuntimeError("aligner blew up"), "INTERNAL"),
])
def test_lyrics_only_job_whose_lyrics_fail_is_an_error_and_keeps_the_input(song_m4a, tmp_path, monkeypatch,
                                                                             failure, code):
    # A song that already has its instrumental sends tasks ["lyrics"]: when the lyrics fail there is nothing to
    # deliver, so the job fails with the code (not "partial", which would delete the input and report no result).
    def boom(*args, **kwargs):
        raise failure

    monkeypatch.setattr(pipeline, "run_lyrics", boom)
    doc = job_doc(song_m4a, tasks=["lyrics"])
    del doc["output"]["put"]["instrumental"]
    result, storage, _ = run(doc, song_m4a, tmp_path)
    assert result["error"].startswith(f"{code}:"), result
    manifest = json.loads(storage.objects["manifest"])
    RESULT.validate(manifest)
    assert manifest["status"] == "error" and manifest["error"]["code"] == code and manifest["outputs"] == {}
    assert not storage.input_deleted and "lyrics" not in storage.objects


@needs_ffmpeg
def test_vocals_and_lyrics_job_names_what_was_kept(song_m4a, tmp_path, monkeypatch):
    def boom(*args, **kwargs):
        raise WorkerError(errors.DEADLINE, "the job ran out of time during lyrics")

    monkeypatch.setattr(pipeline, "run_lyrics", boom)
    doc = job_doc(song_m4a, tasks=["vocals", "lyrics"])
    doc["output"]["put"]["vocals"] = doc["output"]["put"]["instrumental"].replace("instrumental.m4a", "vocals.m4a")
    del doc["output"]["put"]["instrumental"]
    result, storage, _ = run(doc, song_m4a, tmp_path)
    assert result["status"] == "partial" and list(result["outputs"]) == ["vocals"]
    assert "lyrics: failed (DEADLINE); the other outputs are complete" in result["warnings"]


@needs_ffmpeg
def test_aac_output_of_a_192k_input_fails_before_the_separation(tmp_path):
    # ffmpeg's AAC encoder would quietly resample 192 kHz to 96 kHz: the stem's sample count would not match the
    # input, and the phone would reject it after a billed separation. FLAC output keeps the rate.
    src = tmp_path / "hires.flac"
    A.encode(synthetic_song(3, 192000), 192000, str(src), codec="flac", kbps=256)
    data = src.read_bytes()

    class Never(HalfVocals):
        def vocals(self, *args, **kwargs):
            raise AssertionError("separated a job that can't be encoded")

    doc = job_doc(data, tasks=["instrumental"])
    doc["audio"]["ext"] = "flac"
    for key in ("get", "delete"):
        doc["audio"][key] = doc["audio"][key].replace(".m4a?", ".flac?")
    doc["audio"]["durationMs"] = 3000
    result, storage, _ = run(doc, data, tmp_path, models=pipeline.Models(separator=Never()))
    assert result["error"].startswith("UNSUPPORTED_FORMAT:") and "flac" in result["error"]
    assert not storage.input_deleted

    doc["output"]["codec"] = "flac"
    doc["output"]["put"]["instrumental"] = doc["output"]["put"]["instrumental"].replace(
        "instrumental.m4a", "instrumental.flac")
    result, storage, _ = run(doc, data, tmp_path)
    assert result["status"] == "ok", result
    inst = result["outputs"]["instrumental"]
    assert inst["sampleRate"] == 192000 and inst["samples"] == result["input"]["decodedSamples"] == 3 * 192000


@needs_ffmpeg
def test_best_quality_on_a_long_song_falls_back_to_standard(song_m4a, tmp_path):
    seen = {}

    class Spy(HalfVocals):
        def vocals(self, mix, sr, *, quality="standard", progress=None):
            seen["quality"] = quality
            return super().vocals(mix, sr, quality=quality)

    doc = job_doc(song_m4a, separation={"quality": "best"})
    result, _, _ = run(doc, song_m4a, tmp_path, models=pipeline.Models(separator=Spy()),
                       caps_env={"PIXL_BEST_MAX_AUDIO_S": "5"})
    assert seen["quality"] == "standard"
    assert any("best quality is limited" in w for w in result["warnings"])


def test_duplicate_returns_the_existing_manifest_without_work(tmp_path):
    data = b"not even audio"
    existing = load_example("job.result.ok.json")
    existing["input"]["sha256"] = hashlib.sha256(data).hexdigest()
    result, storage, _ = run(job_doc(data), data, tmp_path, storage_kwargs={"manifest": existing})
    assert result["warnings"][-1] == "duplicate" and result["outputs"] == existing["outputs"]
    assert storage.ops == []  # no attempt marker, no download, no delete


def test_a_manifest_for_another_input_is_not_a_duplicate(tmp_path):
    data = b"not even audio"
    existing = load_example("job.result.ok.json")  # its input sha256 is some other file's
    result, storage, _ = run(job_doc(data), data, tmp_path, storage_kwargs={"manifest": existing})
    assert "error" in result  # it went on and processed (and failed on the fake bytes)
    assert ("put", "attempt") in storage.ops


def test_third_delivery_is_poisoned(tmp_path):
    data = b"x"
    attempt = {"schema": "pixl.cloudstudio.attempt", "v": 1, "runpodJobId": "rp-job-1", "attempts": 2}
    result, storage, _ = run(job_doc(data), data, tmp_path, storage_kwargs={"attempt": attempt})
    assert result["error"].startswith("POISONED:") and result["refresh_worker"] is True
    manifest = json.loads(storage.objects["manifest"])
    RESULT.validate(manifest)
    assert manifest["status"] == "error" and manifest["error"]["code"] == "POISONED"
    assert not storage.input_deleted  # a failed job keeps its input so the phone can retry without re-uploading


def test_attempts_count_up_for_the_same_runpod_job_and_restart_for_a_new_one(tmp_path):
    data = b"x"
    attempt = {"schema": "pixl.cloudstudio.attempt", "v": 1, "runpodJobId": "rp-job-1", "attempts": 1}
    _, storage, _ = run(job_doc(data), data, tmp_path, storage_kwargs={"attempt": attempt})
    assert json.loads(storage.objects["attempt"])["attempts"] == 2
    _, storage, _ = run(job_doc(data), data, tmp_path, storage_kwargs={"attempt": attempt}, runpod_id="rp-job-2")
    marker = json.loads(storage.objects["attempt"])
    assert marker["attempts"] == 1 and marker["runpodJobId"] == "rp-job-2"
    jsonschema.Draft202012Validator(load_schema("attempt")).validate(marker)


def test_garbage_input_writes_an_error_manifest_and_keeps_the_input(tmp_path):
    data = b"\x00" * 4096
    result, storage, _ = run(job_doc(data), data, tmp_path)
    assert result["error"].split(":")[0] in ("UNSUPPORTED_FORMAT", "DECODE_FAILED", "INTERNAL")
    manifest = json.loads(storage.objects["manifest"])
    RESULT.validate(manifest)
    assert manifest["status"] == "error" and manifest["outputs"] == {} and manifest["lyrics"] is None
    assert not storage.input_deleted
    assert "http" not in json.dumps(manifest)  # nothing URL-like leaks into a stored manifest


def test_an_expired_deadline_ends_in_DEADLINE_with_a_manifest(tmp_path):
    data = b"x"
    result, storage, _ = run(job_doc(data), data, tmp_path, deadline_s=0)
    assert result["error"].startswith("DEADLINE:")
    assert json.loads(storage.objects["manifest"])["error"]["code"] == "DEADLINE"


def test_upload_failure_is_reported(tmp_path, monkeypatch):
    data = b"x"
    result, storage, _ = run(job_doc(data), data, tmp_path, storage_kwargs={"fail_put": {"manifest"}})
    assert "error" in result  # the error manifest itself can't be written either: logged, still a FAILED job


# ---- jobs that fail validation still leave an error manifest when their manifest slot can be trusted ------

class Recorder:
    def __init__(self):
        self.written = []

    def __call__(self, job, caps):
        outer = self

        class Store:
            def put_json(self, slot, data):
                outer.written.append((job.job_key, slot, json.loads(data)))
                return job.object_key(slot)
        return Store()


def caps():
    return load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST})


def test_rejected_job_gets_an_error_manifest():
    doc = load_example("job.input.process.json")
    doc["tasks"] = ["karaoke"]
    with pytest.raises(WorkerError) as info:
        validate_job(doc, caps())
    rec = Recorder()
    assert pipeline.write_rejection(doc, caps(), info.value, WORKER, rec) is True
    (job_key, slot, manifest), = rec.written
    assert slot == "manifest" and job_key == doc["jobKey"]
    RESULT.validate(manifest)
    assert manifest["error"]["code"] == "BAD_SCHEMA" and manifest["status"] == "error"


def test_newer_app_version_gets_UNSUPPORTED_VERSION_in_its_manifest():
    doc = load_example("job.input.process.json")
    doc["v"] = 2
    with pytest.raises(WorkerError) as info:
        validate_job(doc, caps())
    rec = Recorder()
    assert pipeline.write_rejection(doc, caps(), info.value, WORKER, rec)
    assert rec.written[0][2]["error"]["code"] == "UNSUPPORTED_VERSION"


@pytest.mark.parametrize("mutate", [
    lambda d: d.update(jobKey="../../etc"),
    lambda d: d["output"]["put"].update(manifest="https://evil.example.com/x/manifest.json?X-Amz-Signature=" + "0" * 64),
    lambda d: d["output"]["put"].update(manifest=d["output"]["put"]["lyrics"]),  # not this job's manifest key
    lambda d: d["output"].pop("put"),
    lambda d: d.update(op="selftest"),
    lambda d: d.update(storage="ftp"),
])
def test_untrusted_manifest_slots_get_nothing(mutate):
    doc = copy.deepcopy(load_example("job.input.process.json"))
    mutate(doc)
    rec = Recorder()
    assert pipeline.write_rejection(doc, caps(), WorkerError(errors.BAD_SCHEMA, "x"), WORKER, rec) is False
    assert rec.written == []
    assert pipeline.write_rejection("not a dict", caps(), WorkerError(errors.BAD_SCHEMA, "x"), WORKER, rec) is False
