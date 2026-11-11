"""op: process for the tasks spatial and enhance (cloud-audio-spec.md, section 4), with in-memory storage and fake
models: what is already in the library is skipped before any separation, each render uploads its audio and then
its manifest, one failing output leaves the others (partial), a job that delivers nothing is an error that keeps
its input, the vocal separation is shared with the job's own outputs, and every manifest is checked against its
schema. Two tests run the real renderer end to end; the rest use a stand-in so they stay quick.
They decode and encode real audio, so they need ffmpeg (the Docker test target installs it)."""

import copy
import hashlib
import json
import os
import subprocess

import jsonschema
import numpy as np
import pytest

from conftest import EXAMPLE_HOST, load_example, load_schema
from pixl_worker import audio as A
from pixl_worker import errors, pipeline
from pixl_worker import library as L
from pixl_worker import restore as R
from pixl_worker.config import load_caps
from pixl_worker.deadline import Deadline
from pixl_worker.errors import WorkerError
from pixl_worker.schema import validate_job
from pixl_worker.selftest import synthetic_song
from pixl_worker.spatial import PROFILE_IDS, SpatialResult
from pixl_worker.storage import TransientError
from test_pipeline import HAVE_FFMPEG, HalfVocals, MemStorage

pytestmark = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")
RESULT = jsonschema.Draft202012Validator(load_schema("job.result"))
MANIFEST = jsonschema.Draft202012Validator(load_schema("library.render"))
WORKER = {"version": "1.1.0", "gitSha": "abcdef012345", "gpu": "Fake GPU", "vramGB": 16.0, "cuda": "12.8"}
VIDEO = "J7p4bzqLvCw"
LIB = f"lib/v1/{VIDEO}"
HOST = f"https://{EXAMPLE_HOST}/pixl-cloud-studio"
SIG = "X-Amz-Signature=" + "a" * 64
SECONDS = 4
NOW = 1794337331.0  # 2026-11-10T19:02:11Z


# ---- fakes -------------------------------------------------------------------------------------------------

class FakeStems6:
    """Splits the mix into six equal parts (they add up to it), or four without the 6s model."""
    model_id = "open-cascade-6"

    def __init__(self, names=("vocals", "drums", "bass", "guitar", "piano", "other"), fail=None, during=None):
        self.names, self.fail, self.during, self.calls = names, fail, during, []

    def stems(self, mix, sr, *, quality="standard", vocals=None, progress=None):
        self.calls.append({"mix": mix.copy(), "sr": sr, "quality": quality, "vocals": vocals})
        if self.during:
            self.during()
        if progress:
            progress(1, 2)
        if self.fail:
            raise self.fail
        if progress:
            progress(2, 2)
        return {name: (mix / len(self.names)).astype(np.float32) for name in self.names}


class FakeRender:
    """Stands in for library.render: half the mix, with numbers a real render would report."""

    def __init__(self, fail=None, stem_mode=None):
        self.calls, self.fail, self.stem_mode = [], fail, stem_mode

    def __call__(self, mix, stems, sr, profiles, progress=None):
        profiles = list(profiles)
        self.calls.append({"mix": mix.copy(), "stems": sorted(stems), "sr": sr, "profiles": profiles})
        if progress:
            progress(2, 2 + 10 * len(profiles))
        if self.fail:
            raise self.fail
        mode = self.stem_mode or ("stems6" if "guitar" in stems else "stems4" if stems else "mix")
        out = {}
        for k, profile in enumerate(profiles):
            audio = (mix * (0.5 - 0.01 * k)).astype(np.float32)
            out[profile] = SpatialResult(audio=audio, integrated_lufs=-18.0 - k, source_lufs=-14.0 - k,
                                         true_peak_db=-3.21, limiter_max_db=0.25, stem_mode=mode)
            if progress:
                progress(2 + 10 * (k + 1), 2 + 10 * len(profiles))
        return out


class FakeRestorer(R.Restorer):
    model_id = "fake-restorer"

    def __init__(self, fail=None):
        self.fail, self.calls = fail, []

    def available(self):
        return True

    def restore(self, mix, sample_rate, cutoff_hz, *, progress=None):
        self.calls.append((mix.shape, sample_rate, cutoff_hz))
        if progress:
            progress(1, 2)
        if self.fail:
            raise self.fail
        return (mix * 0.25).astype(np.float32)


# ---- helpers -----------------------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def song(tmp_path_factory):
    """A short FLAC, as a phone uploads a decoded stream. (bytes, frames)"""
    path = tmp_path_factory.mktemp("libsong") / "song.flac"
    audio = synthetic_song(SECONDS)
    A.encode(audio, 44100, str(path), codec="flac", kbps=0)
    return path.read_bytes()


def target(slot, video=VIDEO, get=True):
    out = {"audioPut": f"{HOST}/lib/v1/{video}/{slot}.flac?{SIG}", "manifestPut": f"{HOST}/lib/v1/{video}/{slot}.json?{SIG}"}
    if get:
        out["manifestGet"] = f"{HOST}/lib/v1/{video}/{slot}.json?{SIG}"
    return out


def job_doc(data: bytes, *, tasks=("spatial", "enhance"), profiles=("studio",), **library):
    doc = load_example("job.input.spatial.json")
    doc["audio"].update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), durationMs=SECONDS * 1000)
    doc["tasks"] = list(tasks)
    doc["library"]["renders"] = [{"profile": p, **target(f"sp-{p}")} for p in profiles]
    doc["library"].update(library)
    return doc


def models_for(**kw):
    kw.setdefault("separator", HalfVocals())
    kw.setdefault("stems6", FakeStems6())
    return pipeline.Models(**kw)


def run(doc, data, tmp_path, *, storage_kwargs=None, models=None, deadline=None, caps_env=None):
    caps = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_TMP_ROOT": str(tmp_path / "work"),
                      **(caps_env or {})})
    job = validate_job(doc, caps)
    holder = {}

    def factory(j, c):
        holder["storage"] = MemStorage(j, c, data, **(storage_kwargs or {}))
        return holder["storage"]

    progress = []
    ctx = pipeline.Context(caps=caps, worker=WORKER, storage_factory=factory, progress=progress.append,
                           cold_start_ms=77, now=lambda: NOW)
    result = pipeline.process(job, "rp-job-1", models or models_for(), ctx, deadline or Deadline(1770))
    assert not os.path.exists(tmp_path / "work" / doc["jobKey"])  # the work folder is always cleaned up
    return result, holder["storage"], progress


@pytest.fixture
def fake_render(monkeypatch):
    fake = FakeRender()
    monkeypatch.setattr(pipeline.L, "render", fake)
    return fake


def puts(storage):
    return [op[1] for op in storage.ops if op[0] == "put"]


def lib_json(storage, slot):
    doc = json.loads(storage.library[f"{LIB}/{slot}.json"])
    MANIFEST.validate(doc)
    return doc


def decode_flac(data: bytes, tmp_path):
    path = tmp_path / "check.flac"
    path.write_bytes(data)
    out = subprocess.run([A.FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "s16le",
                          "-c:a", "pcm_s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(out, dtype="<i2").reshape(-1, 2)


def same_shape(a, b, path="") -> None:
    """a has the same keys as b, all the way down (values differ: one is an example, the other a real result)."""
    if isinstance(b, dict):
        assert isinstance(a, dict) and sorted(a) == sorted(b), (path, sorted(a) if isinstance(a, dict) else a, sorted(b))
        for key in b:
            same_shape(a[key], b[key], f"{path}.{key}")
    else:
        assert not isinstance(a, dict), path


# ---- the whole path, with the real renderer ----------------------------------------------------------------

def test_spatial_and_enhance_end_to_end(song, tmp_path):
    result, storage, progress = run(job_doc(song), song, tmp_path)
    assert result["status"] == "ok", result
    RESULT.validate(result)
    same_shape(result, load_example("job.result.spatial.json"))  # the golden example is what the worker writes
    # order: the note that nothing was restored, then the render (its audio first, its manifest last), then the
    # job's own manifest last of all, and only then the input goes
    assert puts(storage) == ["attempt", f"{LIB}/enhanced.json", f"{LIB}/sp-studio.flac", f"{LIB}/sp-studio.json",
                             "manifest"]
    assert [op for op in storage.ops if op[0] == "get"] == [("get", "lib:sp-studio"), ("get", "lib:enhanced")]
    assert storage.ops.index(("get", "lib:enhanced")) < storage.ops.index(("put", f"{LIB}/enhanced.json"))
    assert storage.ops[-1] == ("delete_input",) and json.loads(storage.objects["manifest"]) == result
    frames = result["input"]["decodedSamples"]
    assert frames == SECONDS * 44100

    flac = storage.library[f"{LIB}/sp-studio.flac"]
    out = result["outputs"]["sp-studio"]
    assert out == {"key": f"{LIB}/sp-studio.flac", "bytes": len(flac), "sha256": hashlib.sha256(flac).hexdigest(),
                   "codec": "flac", "kbps": None, "sampleRate": 44100, "samples": frames}
    assert list(result["outputs"]) == ["sp-studio"]  # nothing was restored: no enhanced file
    pcm = decode_flac(flac, tmp_path)
    assert pcm.shape == (frames, 2) and np.abs(pcm).max() > 1000  # the source's frame count, and it is music

    manifest = lib_json(storage, "sp-studio")
    same_shape(manifest, load_example("library.render.spatial.json"))
    assert (manifest["videoId"], manifest["kind"], manifest["profile"], manifest["libV"]) == (VIDEO, "spatial", "studio", 1)
    assert manifest["audio"] == {**{k: out[k] for k in ("key", "bytes", "sha256", "codec", "sampleRate", "samples")},
                                 "bits": 16, "durationMs": SECONDS * 1000}
    loud = manifest["loudness"]
    assert loud["headroomDb"] == 4.0 and abs(loud["sourceLufs"] - 4.0 - loud["integratedLufs"]) <= 0.3
    assert loud["truePeakDb"] <= -0.95 and loud["limiterMaxDb"] >= 0.0
    assert manifest["source"] == {"itag": 251, "codec": "opus", "sampleRate": 44100, "decodedSamples": frames,
                                  "sha256": hashlib.sha256(song).hexdigest(), "cutoffHz": manifest["source"]["cutoffHz"]}
    assert manifest["source"]["cutoffHz"] > 17000  # the test song is full band
    assert manifest["render"] == {"engine": "pixl-spatial-1", "stems": "open-cascade-6", "stemMode": "stems6",
                                  "restore": {"applied": False, "model": None, "reason": "full_band"}}
    assert manifest["worker"] == {"version": "1.1.0", "gitSha": "abcdef012345"}
    assert manifest["createdAt"] == "2026-11-10T19:02:11Z"
    assert L.manifest_matches(manifest, video_id=VIDEO, slot="sp-studio")  # the next job will find it there

    note = lib_json(storage, "enhanced")
    same_shape(note, load_example("library.render.enhanced.none.json"))
    assert note["kind"] == "enhanced" and note["audio"] is None and note["loudness"] is None
    assert note["render"] == {"engine": None, "stems": None, "stemMode": None,
                              "restore": {"applied": False, "model": None, "reason": "full_band"}}
    assert note["source"] == manifest["source"] and f"{LIB}/enhanced.flac" not in storage.library

    assert result["library"] == {"videoId": VIDEO, "libV": 1, "renders": {"studio": "ok"}, "enhanced": "not_needed",
                                 "restore": {"applied": False, "model": None, "reason": "full_band",
                                             "cutoffHz": manifest["source"]["cutoffHz"]},
                                 "stemMode": "stems6"}
    assert result["models"] == {"separator": "fake-separator", "stems4": None, "aligner": None, "asr": None,
                                "stems6": "open-cascade-6", "restorer": None}
    timings = result["timings"]
    assert timings["coldStartMs"] == 77 and timings["separateMs"] == 0 and timings["renderMs"] > 0
    assert timings["totalMs"] >= timings["renderMs"] and timings["encodeMs"] > 0
    assert progress[:2] == ["download:0", "decode:0"] and progress[-1] == "done:100"
    assert "stems6:0" in progress and "render:0" in progress and "render:100" in progress and "upload:0" in progress
    assert not any(p.startswith(("separate:", "restore:")) for p in progress)
    assert "http" not in json.dumps(result) and "http" not in json.dumps(manifest)  # no URL ever reaches a manifest


def test_a_song_at_another_sample_rate_keeps_its_rate_and_length(tmp_path):
    path = tmp_path / "song32k.flac"
    A.encode(synthetic_song(3, 32000), 32000, str(path), codec="flac", kbps=0)
    data = path.read_bytes()
    doc = job_doc(data, tasks=("spatial",), profiles=("hall",))
    doc["audio"]["durationMs"] = 3000
    result, storage, _ = run(doc, data, tmp_path)
    assert result["status"] == "ok", result
    RESULT.validate(result)
    manifest = lib_json(storage, "sp-hall")
    assert manifest["audio"]["sampleRate"] == 32000 and manifest["audio"]["samples"] == 96000
    assert manifest["source"]["cutoffHz"] <= 16000  # a 32 kHz file ends at 16 kHz: band-limited by its own rate
    assert manifest["render"]["restore"] == {"applied": False, "model": None, "reason": "unavailable"}
    assert abs(manifest["loudness"]["sourceLufs"] - 4.0 - manifest["loudness"]["integratedLufs"]) <= 0.3
    assert decode_flac(storage.library[f"{LIB}/sp-hall.flac"], tmp_path).shape == (96000, 2)
    assert result["library"]["enhanced"] is None and result["library"]["restore"]["reason"] == "unavailable"


# ---- what is already in the library ------------------------------------------------------------------------

def existing(slot, video=VIDEO):
    doc = copy.deepcopy(load_example("library.render.spatial.json" if slot != "enhanced"
                                     else "library.render.enhanced.none.json"))
    doc["videoId"] = video
    if slot != "enhanced":
        doc["profile"] = slot[3:]
        doc["audio"]["key"] = f"lib/v1/{video}/{slot}.flac"
    return doc


def never(*args, **kwargs):
    raise AssertionError("this stage must not run")


def test_everything_already_there_ends_ok_at_once_without_separating(song, tmp_path, monkeypatch):
    monkeypatch.setattr(pipeline.L, "render", never)
    monkeypatch.setattr(pipeline.R, "detect_cutoff_hz", never)
    library = {f"{LIB}/sp-studio.json": existing("sp-studio"), f"{LIB}/enhanced.json": existing("enhanced")}
    stems6 = FakeStems6(fail=AssertionError("separated although everything was there"))
    result, storage, progress = run(job_doc(song), song, tmp_path, storage_kwargs={"library": library},
                                    models=models_for(stems6=stems6, separator=None))
    assert result["status"] == "ok" and result["warnings"] == []
    RESULT.validate(result)
    same_shape(result, load_example("job.result.spatial.exists.json"))
    assert stems6.calls == [] and puts(storage) == ["attempt", "manifest"] and storage.input_deleted
    assert result["library"] == {"videoId": VIDEO, "libV": 1, "renders": {"studio": "exists"},
                                 "enhanced": "not_needed", "restore": None, "stemMode": None}
    # the phone downloads from the entry: it is the existing render's own description
    assert result["outputs"] == {"sp-studio": load_example("job.result.spatial.exists.json")["outputs"]["sp-studio"]}
    assert set(result["models"].values()) == {None}
    assert {result["timings"][k] for k in ("separateMs", "restoreMs", "stems6Ms", "renderMs", "encodeMs")} == {0}
    assert not any(p.startswith(("stems6", "render", "separate", "restore")) for p in progress)


def test_an_existing_enhanced_file_is_handed_over_like_a_render(song, tmp_path, fake_render):
    restored = copy.deepcopy(load_example("library.render.enhanced.json"))
    restored["videoId"] = VIDEO
    restored["audio"]["key"] = f"{LIB}/enhanced.flac"
    result, storage, _ = run(job_doc(song, tasks=("enhance",)), song, tmp_path,
                             storage_kwargs={"library": {f"{LIB}/enhanced.json": restored}})
    RESULT.validate(result)
    assert result["library"]["enhanced"] == "exists" and result["library"]["renders"] == {}
    assert result["outputs"]["enhanced"]["key"] == f"{LIB}/enhanced.flac"
    assert result["outputs"]["enhanced"]["sha256"] == restored["audio"]["sha256"]
    assert fake_render.calls == [] and puts(storage) == ["attempt", "manifest"]


def test_only_the_missing_profiles_are_rendered(song, tmp_path, fake_render):
    doc = job_doc(song, tasks=("spatial",), profiles=("studio", "wide", "hall"))
    result, storage, _ = run(doc, song, tmp_path, storage_kwargs={"library": {f"{LIB}/sp-wide.json": existing("sp-wide")}})
    RESULT.validate(result)
    assert result["status"] == "ok" and fake_render.calls[0]["profiles"] == ["studio", "hall"]
    assert result["library"]["renders"] == {"wide": "exists", "studio": "ok", "hall": "ok"}
    assert puts(storage) == ["attempt", f"{LIB}/sp-studio.flac", f"{LIB}/sp-studio.json", f"{LIB}/sp-hall.flac",
                             f"{LIB}/sp-hall.json", "manifest"]
    assert sorted(result["outputs"]) == ["sp-hall", "sp-studio", "sp-wide"]
    assert result["outputs"]["sp-wide"] == L.existing_output(existing("sp-wide"))
    assert lib_json(storage, "sp-hall")["profile"] == "hall" and lib_json(storage, "sp-studio")["profile"] == "studio"
    # the two renders differ and each manifest describes its own file
    for slot in ("sp-studio", "sp-hall"):
        flac = storage.library[f"{LIB}/{slot}.flac"]
        assert lib_json(storage, slot)["audio"]["sha256"] == hashlib.sha256(flac).hexdigest()
    assert storage.library[f"{LIB}/sp-studio.flac"] != storage.library[f"{LIB}/sp-hall.flac"]


@pytest.mark.parametrize("what", ["another video", "another profile", "an older library", "no audio", "not a manifest",
                                  "unreadable", "an error"])
def test_anything_but_this_render_means_make_it(song, tmp_path, fake_render, what):
    doc = existing("sp-studio")
    if what == "another video":
        doc["videoId"] = "ZD6rXLXZOEI"
    elif what == "another profile":
        doc["profile"] = "wide"
    elif what == "an older library":
        doc["libV"] = 0
    elif what == "no audio":
        doc["audio"] = None
    elif what == "not a manifest":
        doc = {"schema": "pixl.cloudstudio.result", "status": "ok"}

    def get(slot):
        if what == "unreadable":
            raise TransientError("HTTP 503")
        if what == "an error":
            raise RuntimeError("storage answered nonsense")
        return doc

    result, storage, _ = run(job_doc(song, tasks=("spatial",)), song, tmp_path, storage_kwargs={"library_get": get})
    assert result["status"] == "ok" and result["library"]["renders"] == {"studio": "ok"}
    assert fake_render.calls[0]["profiles"] == ["studio"] and f"{LIB}/sp-studio.json" in storage.library


def test_without_a_manifest_get_the_render_is_always_made(song, tmp_path, fake_render):
    doc = job_doc(song, tasks=("spatial",))
    del doc["library"]["renders"][0]["manifestGet"]
    result, storage, _ = run(doc, song, tmp_path,
                             storage_kwargs={"library": {f"{LIB}/sp-studio.json": existing("sp-studio")}})
    assert result["library"]["renders"] == {"studio": "ok"} and len(fake_render.calls) == 1


# ---- failures ----------------------------------------------------------------------------------------------

def test_one_render_failing_leaves_the_others_intact(song, tmp_path, fake_render):
    doc = job_doc(song, tasks=("spatial",), profiles=("studio", "wide", "night"))
    result, storage, _ = run(doc, song, tmp_path, storage_kwargs={"fail_put": {"sp-wide"}})
    assert result["status"] == "partial", result
    RESULT.validate(result)
    assert result["library"]["renders"] == {"studio": "ok", "wide": "failed", "night": "ok"}
    assert result["warnings"] == ["library: sp-wide failed (UPLOAD_FAILED)"]
    assert sorted(result["outputs"]) == ["sp-night", "sp-studio"]
    assert f"{LIB}/sp-wide.flac" not in storage.library and f"{LIB}/sp-wide.json" not in storage.library
    assert f"{LIB}/sp-night.json" in storage.library and storage.input_deleted  # partial: a usable result


def test_a_render_whose_manifest_cannot_be_written_is_not_advertised(song, tmp_path, fake_render):
    doc = job_doc(song, tasks=("spatial",), profiles=("studio", "wide"))
    result, storage, _ = run(doc, song, tmp_path, storage_kwargs={"fail_put": {"sp-studio manifest"}})
    assert result["status"] == "partial" and result["library"]["renders"] == {"studio": "failed", "wide": "ok"}
    # the audio went first, so it is there; without its manifest no phone will take it, and it expires on its own
    assert f"{LIB}/sp-studio.flac" in storage.library and f"{LIB}/sp-studio.json" not in storage.library
    assert list(result["outputs"]) == ["sp-wide"]


def test_a_library_job_where_everything_fails_is_an_error_with_the_first_code_and_keeps_its_input(song, tmp_path,
                                                                                                    fake_render):
    oom = WorkerError(errors.GPU_OOM, "the GPU ran out of memory while splitting stems", refresh_worker=True)
    doc = job_doc(song, tasks=("spatial",), profiles=("studio", "wide"))
    result, storage, _ = run(doc, song, tmp_path, models=models_for(stems6=FakeStems6(fail=oom)))
    assert result == {"error": "GPU_OOM: the GPU ran out of memory while splitting stems", "refresh_worker": True}
    manifest = json.loads(storage.objects["manifest"])
    RESULT.validate(manifest)
    assert manifest["status"] == "error" and manifest["error"]["code"] == "GPU_OOM"
    assert manifest["outputs"] == {} and manifest["library"] is None  # nothing of a failed job is to be trusted
    assert manifest["warnings"] == ["library: sp-studio failed (GPU_OOM)", "library: sp-wide failed (GPU_OOM)"]
    assert not storage.input_deleted and fake_render.calls == []
    assert puts(storage) == ["attempt", "manifest"]


def test_the_note_that_nothing_was_restored_survives_a_failed_render(song, tmp_path, fake_render):
    fake_render.fail = RuntimeError("boom https://x.r2.cloudflarestorage.com/in/a?X-Amz-Signature=" + "a" * 64)
    result, storage, _ = run(job_doc(song), song, tmp_path)
    assert result["status"] == "partial", result
    RESULT.validate(result)
    assert result["library"]["renders"] == {"studio": "failed"} and result["library"]["enhanced"] == "not_needed"
    assert result["warnings"] == ["library: sp-studio failed (INTERNAL)"] and result["outputs"] == {}
    assert f"{LIB}/enhanced.json" in storage.library and storage.input_deleted
    assert "X-Amz" not in json.dumps(result) and "cloudflarestorage" not in json.dumps(result)
    assert result["library"]["stemMode"] is None and result["models"]["stems6"] == "open-cascade-6"


def test_running_out_of_memory_in_the_renderer_recycles_the_worker(song, tmp_path, fake_render):
    fake_render.fail = MemoryError()
    result, storage, _ = run(job_doc(song, tasks=("spatial",)), song, tmp_path)
    assert result == {"error": "INTERNAL: the worker ran out of memory during render", "refresh_worker": True}
    assert not storage.input_deleted


def test_a_worker_without_the_six_stem_models_fails_the_renders(song, tmp_path, fake_render):
    result, storage, _ = run(job_doc(song), song, tmp_path, models=models_for(stems6=None))
    assert result["status"] == "partial" and result["library"]["renders"] == {"studio": "failed"}
    assert result["library"]["enhanced"] == "not_needed" and fake_render.calls == []
    result, _, _ = run(job_doc(song, tasks=("spatial",)), song, tmp_path, models=models_for(stems6=None))
    assert result["error"].startswith("INTERNAL: six-stem separation is not available")


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def test_a_deadline_that_passes_during_the_separation_fails_the_renders_with_DEADLINE(song, tmp_path, fake_render):
    clock = Clock()
    stems6 = FakeStems6(during=lambda: setattr(clock, "t", 5000.0))  # the separation took far too long
    result, storage, _ = run(job_doc(song, tasks=("spatial",)), song, tmp_path, models=models_for(stems6=stems6),
                             deadline=Deadline(1770, clock=clock))
    assert result["error"].startswith("DEADLINE: the job ran out of time during stems6")
    assert json.loads(storage.objects["manifest"])["error"]["code"] == "DEADLINE" and not storage.input_deleted
    assert fake_render.calls == []


def test_the_deadline_is_checked_inside_the_render(song, tmp_path, monkeypatch):
    clock = Clock()

    def slow_render(mix, stems, sr, profiles, progress=None):
        clock.t = 5000.0
        progress(2, 12)  # the renderer reports after its preparation: that is where a late job stops
        raise AssertionError("rendered past the deadline")

    monkeypatch.setattr(pipeline.L, "render", slow_render)
    result, storage, _ = run(job_doc(song), song, tmp_path, deadline=Deadline(1770, clock=clock))
    assert result["status"] == "partial" and result["library"]["renders"] == {"studio": "failed"}
    assert result["warnings"] == ["library: sp-studio failed (DEADLINE)"]


# ---- together with the job's own outputs -------------------------------------------------------------------

def combined_doc(song, **changes):
    doc = load_example("job.input.spatial.combined.json")
    doc["audio"].update(bytes=len(song), sha256=hashlib.sha256(song).hexdigest(), durationMs=SECONDS * 1000,
                        ext="flac")
    for key in ("get", "delete"):
        doc["audio"][key] = doc["audio"][key].replace(".m4a?", ".flac?")
    doc.update(changes)
    return doc


class CountingVocals(HalfVocals):
    def __init__(self):
        self.calls = 0

    def vocals(self, mix, sr, *, quality="standard", progress=None):
        self.calls += 1
        return super().vocals(mix, sr, quality=quality, progress=progress)


def test_an_instrumental_and_spatial_job_separates_the_vocals_once(song, tmp_path, fake_render):
    separator, stems6 = CountingVocals(), FakeStems6()
    result, storage, progress = run(combined_doc(song), song, tmp_path,
                                    models=models_for(separator=separator, stems6=stems6))
    assert result["status"] == "ok", result
    RESULT.validate(result)
    video = "ZD6rXLXZOEI"
    assert separator.calls == 1
    call = stems6.calls[0]
    assert call["vocals"] is not None and np.allclose(call["vocals"], 0.5 * call["mix"], atol=1e-6)
    # the job's own outputs go first, then the library, then the manifest
    assert puts(storage) == ["attempt", "instrumental", f"lib/v1/{video}/sp-night.flac",
                             f"lib/v1/{video}/sp-night.json", f"lib/v1/{video}/sp-hall.flac",
                             f"lib/v1/{video}/sp-hall.json", "manifest"]
    assert sorted(result["outputs"]) == ["instrumental", "sp-hall", "sp-night"]
    assert result["outputs"]["instrumental"]["key"].startswith("out/") and result["outputs"]["instrumental"]["codec"] == "aac"
    assert result["outputs"]["sp-hall"]["key"] == f"lib/v1/{video}/sp-hall.flac"
    assert result["library"]["renders"] == {"night": "ok", "hall": "ok"} and result["library"]["enhanced"] is None
    assert result["models"]["separator"] == "fake-separator" and result["models"]["stems6"] == "open-cascade-6"
    assert result["timings"]["separateMs"] >= 0 and [p for p in progress if p.endswith(":0")] == [
        "download:0", "decode:0", "separate:0", "upload:0", "stems6:0", "render:0", "upload:0"]
    # the render was made from the whole mix, not from the instrumental
    assert fake_render.calls[0]["mix"].shape == call["mix"].shape and np.array_equal(fake_render.calls[0]["mix"], call["mix"])
    assert json.loads(storage.library[f"lib/v1/{video}/sp-night.json"])["source"]["itag"] == 140


def test_a_library_failure_next_to_an_instrumental_is_partial(song, tmp_path, fake_render):
    fake_render.fail = WorkerError(errors.INTERNAL, "render failed")
    result, storage, _ = run(combined_doc(song), song, tmp_path)
    assert result["status"] == "partial" and list(result["outputs"]) == ["instrumental"]
    RESULT.validate(result)
    assert result["library"]["renders"] == {"night": "failed", "hall": "failed"} and storage.input_deleted
    assert result["warnings"] == ["library: sp-night failed (INTERNAL)", "library: sp-hall failed (INTERNAL)"]


def test_a_failure_of_the_jobs_own_separation_is_still_the_jobs_error(song, tmp_path, fake_render):
    class Broken(HalfVocals):
        def vocals(self, *args, **kwargs):
            raise WorkerError(errors.GPU_OOM, "the GPU ran out of memory while separating", refresh_worker=True)

    stems6 = FakeStems6()
    result, storage, _ = run(combined_doc(song), song, tmp_path, models=models_for(separator=Broken(), stems6=stems6))
    assert result["error"].startswith("GPU_OOM:") and result["refresh_worker"] is True
    assert stems6.calls == [] and fake_render.calls == [] and not storage.input_deleted


def lyrics_doc(song):
    doc = combined_doc(song, tasks=["lyrics", "spatial"])
    doc["lyrics"] = {"mode": "align", "language": "en", "synced": True,
                     "lines": [{"startMs": 0, "endMs": 3000, "text": "sing along with me"}]}
    doc["output"]["put"]["lyrics"] = doc["output"]["put"]["manifest"].replace("manifest.json", "lyrics.json")
    del doc["output"]["put"]["instrumental"]
    return doc


def test_lyrics_failing_next_to_library_tasks_do_not_stop_them(song, tmp_path, fake_render, monkeypatch):
    def boom(*args, **kwargs):
        raise WorkerError(errors.DEADLINE, "the job ran out of time during lyrics")

    monkeypatch.setattr(pipeline, "run_lyrics", boom)
    result, storage, _ = run(lyrics_doc(song), song, tmp_path)
    assert result["status"] == "partial", result
    RESULT.validate(result)
    assert result["lyrics"] is None and result["library"]["renders"] == {"night": "ok", "hall": "ok"}
    assert result["warnings"] == ["lyrics: failed (DEADLINE)"] and storage.input_deleted
    # ... and when the library delivers nothing either, the job fails with the first failure: the lyrics'
    fake_render.fail = WorkerError(errors.INTERNAL, "render failed")
    result, storage, _ = run(lyrics_doc(song), song, tmp_path)
    assert result["error"].startswith("DEADLINE: the job ran out of time during lyrics")
    assert not storage.input_deleted and json.loads(storage.objects["manifest"])["error"]["code"] == "DEADLINE"


# ---- restore: off, unavailable, and with a model -----------------------------------------------------------

def band_limited(monkeypatch, hz=15989.4):
    monkeypatch.setattr(pipeline.R, "detect_cutoff_hz", lambda mix, sr: hz)


@pytest.mark.parametrize("mode, cutoff, reason", [("auto", 15989.4, "unavailable"), ("off", 15989.4, "off"),
                                                  ("off", 20000.0, "full_band"), ("auto", 17000.6, "full_band"),
                                                  ("auto", 17000.0, "unavailable")])
def test_the_reason_nothing_was_restored_is_recorded_everywhere(song, tmp_path, fake_render, monkeypatch, mode,
                                                                 cutoff, reason):
    band_limited(monkeypatch, cutoff)
    result, storage, _ = run(job_doc(song, restore=mode), song, tmp_path)
    assert result["status"] == "ok"
    RESULT.validate(result)
    restore = {"applied": False, "model": None, "reason": reason}
    assert result["library"]["restore"] == {**restore, "cutoffHz": int(round(cutoff))}
    assert result["library"]["enhanced"] == "not_needed" and result["models"]["restorer"] is None
    note, render = lib_json(storage, "enhanced"), lib_json(storage, "sp-studio")
    assert note["audio"] is None and note["render"]["restore"] == restore == render["render"]["restore"]
    assert note["source"]["cutoffHz"] == render["source"]["cutoffHz"] == int(round(cutoff))
    assert f"{LIB}/enhanced.flac" not in storage.library


def test_a_missing_source_block_is_recorded_as_unknown(song, tmp_path, fake_render):
    doc = job_doc(song)
    del doc["library"]["source"]
    _, storage, _ = run(doc, song, tmp_path)
    for slot in ("enhanced", "sp-studio"):
        assert lib_json(storage, slot)["source"]["itag"] is None and lib_json(storage, slot)["source"]["codec"] is None


def test_with_a_restoration_model_the_restored_song_is_stored_and_rendered(song, tmp_path, fake_render, monkeypatch):
    band_limited(monkeypatch)
    restorer, stems6 = FakeRestorer(), FakeStems6()
    result, storage, progress = run(job_doc(song), song, tmp_path, models=models_for(restorer=restorer, stems6=stems6))
    assert result["status"] == "ok", result
    RESULT.validate(result)
    frames = result["input"]["decodedSamples"]
    assert restorer.calls == [((frames, 2), 44100, 15989.4)]
    assert puts(storage) == ["attempt", f"{LIB}/enhanced.flac", f"{LIB}/enhanced.json", f"{LIB}/sp-studio.flac",
                             f"{LIB}/sp-studio.json", "manifest"]
    applied = {"applied": True, "model": "fake-restorer", "reason": None}
    assert result["library"] == {"videoId": VIDEO, "libV": 1, "renders": {"studio": "ok"}, "enhanced": "ok",
                                 "restore": {**applied, "cutoffHz": 15989}, "stemMode": "stems6"}
    assert result["models"]["restorer"] == "fake-restorer" and "restore:0" in progress
    enhanced = lib_json(storage, "enhanced")
    same_shape(enhanced, load_example("library.render.enhanced.json"))
    flac = storage.library[f"{LIB}/enhanced.flac"]
    assert enhanced["audio"]["sha256"] == hashlib.sha256(flac).hexdigest() == result["outputs"]["enhanced"]["sha256"]
    assert enhanced["audio"]["samples"] == frames and enhanced["render"] == {
        "engine": None, "stems": None, "stemMode": None, "restore": applied}
    assert enhanced["loudness"]["headroomDb"] == 0.0 and enhanced["loudness"]["limiterMaxDb"] == 0.0
    # the fake "restoration" is the song at a quarter of its level: 12 dB down, measured, not assumed
    assert enhanced["loudness"]["sourceLufs"] - enhanced["loudness"]["integratedLufs"] == pytest.approx(12.04, abs=0.1)
    assert decode_flac(flac, tmp_path).shape == (frames, 2)
    # the stems and the render are made from the restored song; the spatial manifest says it contains it
    assert np.allclose(fake_render.calls[0]["mix"], stems6.calls[0]["mix"]) and stems6.calls[0]["vocals"] is None
    original = decode_flac(song, tmp_path).astype(np.float32) / 32768.0
    assert np.allclose(stems6.calls[0]["mix"], 0.25 * original, atol=1e-4)
    assert lib_json(storage, "sp-studio")["render"]["restore"] == applied


def test_vocals_of_the_unrestored_song_are_not_reused_for_the_restored_one(song, tmp_path, fake_render, monkeypatch):
    band_limited(monkeypatch)
    separator, stems6 = CountingVocals(), FakeStems6()
    result, _, _ = run(combined_doc(song), song, tmp_path,
                       models=models_for(separator=separator, stems6=stems6, restorer=FakeRestorer()))
    assert result["status"] == "ok" and separator.calls == 1  # for the instrumental; the cascade does its own
    assert stems6.calls[0]["vocals"] is None
    assert result["library"]["restore"]["applied"] is True and result["library"]["enhanced"] is None


def test_a_failed_restoration_makes_no_enhanced_file_and_the_renders_go_on_without_it(song, tmp_path, fake_render,
                                                                                       monkeypatch):
    band_limited(monkeypatch)
    restorer = FakeRestorer(fail=WorkerError(errors.GPU_OOM, "the GPU ran out of memory while restoring",
                                             refresh_worker=True))
    result, storage, _ = run(job_doc(song), song, tmp_path, models=models_for(restorer=restorer))
    assert result.pop("refresh_worker") is True and result["status"] == "partial"
    RESULT.validate(result)
    failed = {"applied": False, "model": "fake-restorer", "reason": "failed"}
    assert result["library"]["enhanced"] == "failed" and result["library"]["renders"] == {"studio": "ok"}
    assert result["library"]["restore"] == {**failed, "cutoffHz": 15989}
    assert result["warnings"] == ["library: enhanced failed (GPU_OOM)",
                                  "restore: failed (GPU_OOM); the song was left as it is"]
    # nothing is written for enhanced, so a later job tries again; the render says what it was made from
    assert f"{LIB}/enhanced.json" not in storage.library and f"{LIB}/enhanced.flac" not in storage.library
    assert lib_json(storage, "sp-studio")["render"]["restore"] == failed
    assert result["models"]["restorer"] is None
    # a restoration that changes the song's length is a failure too, not a file
    class Short(FakeRestorer):
        def restore(self, mix, sample_rate, cutoff_hz, *, progress=None):
            return mix[:-10]

    result, storage, _ = run(job_doc(song, tasks=("enhance",)), song, tmp_path, models=models_for(restorer=Short()))
    assert result["error"].startswith("INTERNAL: the restoration changed the song's length")


# ---- quality, the guard, rejections ------------------------------------------------------------------------

def test_quality_reaches_the_cascade_and_long_songs_fall_back_to_standard(song, tmp_path, fake_render):
    stems6 = FakeStems6()
    doc = job_doc(song, tasks=("spatial",))
    doc["separation"] = {"quality": "best"}
    run(doc, song, tmp_path, models=models_for(stems6=stems6))
    assert stems6.calls[0]["quality"] == "best"
    result, _, _ = run(doc, song, tmp_path, models=models_for(stems6=stems6), caps_env={"PIXL_BEST_MAX_AUDIO_S": "2"})
    assert stems6.calls[1]["quality"] == "standard"
    assert any("best quality is limited" in w for w in result["warnings"])


def test_four_stems_and_stem_free_renders_say_so(song, tmp_path, fake_render):
    four = FakeStems6(names=("vocals", "drums", "bass", "other"))
    result, storage, _ = run(job_doc(song, tasks=("spatial",)), song, tmp_path, models=models_for(stems6=four))
    assert result["library"]["stemMode"] == "stems4"
    assert lib_json(storage, "sp-studio")["render"]["stems"] == "open-cascade-6"
    fake_render.stem_mode = "mix"  # the renderer did not trust the stems
    result, storage, _ = run(job_doc(song, tasks=("spatial",)), song, tmp_path)
    assert result["library"]["stemMode"] == "mix"
    render = lib_json(storage, "sp-studio")["render"]
    assert render["stemMode"] == "mix" and render["stems"] is None and render["engine"] == "pixl-spatial-1"


def test_a_resent_library_job_gets_its_finished_manifest_back(song, tmp_path, fake_render):
    first, storage, _ = run(job_doc(song), song, tmp_path)
    again, storage2, _ = run(job_doc(song), song, tmp_path, storage_kwargs={"manifest": first})
    assert again["warnings"] == ["duplicate"] and again["library"] == first["library"]
    assert storage2.ops == [] and len(fake_render.calls) == 1


def test_a_rejected_library_job_still_gets_its_error_manifest():
    caps = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST})
    doc = load_example("job.input.spatial.json")
    doc["library"]["v"] = 2
    with pytest.raises(WorkerError) as info:
        validate_job(doc, caps)
    written = []

    def factory(job, caps_):
        class Store:
            def put_json(self, slot, data):
                written.append((slot, json.loads(data)))
        return Store()

    assert pipeline.write_rejection(doc, caps, info.value, WORKER, factory) is True
    (slot, manifest), = written
    RESULT.validate(manifest)
    assert slot == "manifest" and manifest["error"] == {"code": "UNSUPPORTED_VERSION", "message": "library.v must be 1"}
    assert manifest["library"] is None


def test_all_six_profiles_in_one_job(song, tmp_path, fake_render):
    doc = job_doc(song, tasks=("spatial",), profiles=PROFILE_IDS)
    result, storage, _ = run(doc, song, tmp_path)
    RESULT.validate(result)
    assert result["status"] == "ok" and result["library"]["renders"] == {p: "ok" for p in PROFILE_IDS}
    assert fake_render.calls[0]["profiles"] == list(PROFILE_IDS) and len(fake_render.calls) == 1  # prepared once
    for profile in PROFILE_IDS:
        manifest = lib_json(storage, f"sp-{profile}")
        assert manifest["profile"] == profile and manifest["audio"]["key"] == f"{LIB}/sp-{profile}.flac"
