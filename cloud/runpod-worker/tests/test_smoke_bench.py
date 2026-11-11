"""The image's CPU smoke script and the bench's spatial stages, run here with stand-in models: the real ones need
torch and the baked weights (the smoke stage of the image build, and op bench on RunPod, run those). What this
proves is that the checks themselves are sound: they pass on models that behave and fail on ones that do not."""

import json
import shutil
import sys
import types

import jsonschema
import numpy as np
import pytest

from conftest import EXAMPLE_HOST, load_example, load_schema
from pixl_worker import audio as A
from pixl_worker import handler, pipeline, selftest, smoke
from pixl_worker import separate as S
from pixl_worker.config import load_caps
from pixl_worker.lyrics.languages import Token
from pixl_worker.schema import validate_job

HAVE_FFMPEG = shutil.which(A.FFMPEG) is not None and shutil.which(A.FFPROBE) is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")
SELFTEST = jsonschema.Draft202012Validator(load_schema("selftest.result"))
INFO = {"version": "1.1.0", "gitSha": "abcdef012345", "gpu": None, "vramGB": None, "cuda": None}


class Separator:
    model_id = "fake-separator"
    sample_rate = 44100

    def __init__(self, *args):
        pass

    def vocals(self, mix, sr, *, quality="standard", progress=None):
        if progress:
            progress(1, 1)
        return (0.3 * mix).astype(np.float32)


class Four:
    model_id = "htdemucs_ft"
    there = True

    def __init__(self, repo_dir=None):
        self.loaded = False

    def available(self):
        return self.there

    def stems(self, x, sr, *, progress=None, overlap=0.25):
        self.loaded = True
        if progress:  # what demucs reports for a bag of four: one total, into the last model
            for done in (0, 1200, 2400, 3600, 4000):
                progress(done, 4000)
        return {"drums": (0.5 * x).astype(np.float32), "bass": (0.2 * x).astype(np.float32),
                "other": (0.3 * x).astype(np.float32)}


class Six:
    model_id = "htdemucs_6s"
    there = True
    broken = False

    def __init__(self, repo_dir=None):
        self.loaded = False

    def available(self):
        return self.there

    def split(self, other, sr, *, progress=None, overlap=0.25):
        self.loaded = True
        if progress:
            progress(1000, 1000)
        if self.broken:
            return {"guitar": (0.4 * other[:-5]).astype(np.float32), "piano": (0.1 * other).astype(np.float32)}
        return {"guitar": (0.4 * other).astype(np.float32), "piano": (0.1 * other).astype(np.float32)}


class Aligner:
    def __init__(self, path):
        pass

    def align(self, requests):
        return [[Token(text=w, start_s=0.3 * k, end_s=0.3 * k + 0.2) for k, w in enumerate(
            "Hello world sing along with me".split())] for _ in requests]


@pytest.fixture
def stand_ins(monkeypatch):
    torch = types.ModuleType("torch")
    torch.set_num_threads = lambda n: None
    monkeypatch.setitem(sys.modules, "torch", torch)
    from pixl_worker.lyrics import align

    monkeypatch.setattr(align, "QwenAligner", Aligner)
    monkeypatch.setattr(S, "RoformerSeparator", Separator)
    monkeypatch.setattr(S, "Stems4", Four)
    monkeypatch.setattr(S, "GuitarPiano", Six)
    for cls in (Four, Six):
        monkeypatch.setattr(cls, "there", True)
    monkeypatch.setattr(Six, "broken", False)


def lines(capsys):
    return {record["check"]: record for record in map(json.loads, capsys.readouterr().out.strip().splitlines())}


@needs_ffmpeg
def test_the_smoke_script_passes_on_models_that_behave(stand_ins, capsys):
    assert smoke.smoke("/models", seconds=4.0) is True
    out = lines(capsys)
    assert list(out) == ["separator", "separator_48k", "aligner", "stems4", "stems6", "render", "summary"]
    assert all(record["ok"] for record in out.values()) and out["summary"]["checks"] == 6
    assert out["stems6"]["stems"] == ["bass", "drums", "guitar", "other", "piano", "vocals"]
    assert out["stems6"]["progressCalls"] >= 3 and out["stems6"]["leftoverDb"] < -60.0  # these stems add up
    assert out["render"]["stemMode"] == "stems6" and out["render"]["flacBytes"] > 1000
    assert abs(out["render"]["sourceLufs"] - 4.0 - out["render"]["lufs"]) <= 0.3
    assert out["render"]["truePeakDb"] <= -0.9


@needs_ffmpeg
def test_the_smoke_script_fails_an_image_without_htdemucs_6s(stand_ins, capsys, monkeypatch):
    monkeypatch.setattr(Six, "there", False)
    assert smoke.smoke("/models", seconds=4.0) is False
    out = lines(capsys)
    assert out["stems6"]["ok"] is False and "htdemucs_6s" in out["stems6"]["error"]
    assert out["render"]["ok"] is True and out["render"]["stemMode"] == "mix"  # still checked, from the mix
    assert out["stems4"]["ok"] is True and out["summary"]["ok"] is False


@needs_ffmpeg
def test_the_smoke_script_fails_on_a_stem_of_the_wrong_length(stand_ins, capsys, monkeypatch):
    monkeypatch.setattr(Six, "broken", True)
    assert smoke.smoke("/models", seconds=4.0) is False
    assert lines(capsys)["stems6"]["ok"] is False


@needs_ffmpeg
def test_the_smoke_script_reports_a_missing_separator_without_crashing(stand_ins, capsys, monkeypatch):
    class Broken(Separator):
        def __init__(self, *args):
            raise RuntimeError("checkpoint missing")

    monkeypatch.setattr(S, "RoformerSeparator", Broken)
    assert smoke.smoke("/models", seconds=4.0) is False
    out = lines(capsys)
    assert out["separator"]["ok"] is False and out["stems6"]["ok"] is False
    assert "failed above" in out["stems6"]["error"] and out["render"]["ok"] is True


# ---- op bench: the stages stems6 and render ---------------------------------------------------------------

def make_worker(tmp_path, **models):
    caps = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_TMP_ROOT": str(tmp_path)})
    separator = Separator()
    all_models = pipeline.Models(separator=separator, **models)
    return handler.Worker(caps, all_models, INFO, 0, lambda: {"anvuew-bs-roformer-ft1": True, "htdemucs_ft": "lazy",
                                                               "htdemucs_6s": "lazy"})


def test_bench_times_the_cascade_and_one_render(tmp_path):
    stems6 = S.Stems6(Separator(), Four(), Six())
    worker = make_worker(tmp_path, stems6=stems6)
    progress = []
    worker.progress = lambda job, message: progress.append(message)
    out = worker.handle({"id": "b", "input": {"v": 1, "op": "bench",
                                              "bench": {"seconds": 10, "stages": ["separate", "stems6", "render"]}}})
    assert out["status"] == "ok" and out["refresh_worker"] is True, out
    stages = out["stagesMs"]
    assert {"separate", "stems6", "render", "stems6Stems", "renderFrames"} <= set(stages)
    assert stages["stems6Stems"] == 6 and stages["renderFrames"] == 441000 and stages["render"] > 0
    assert progress == ["bench:separate", "bench:stems6", "bench:render"]
    note = next(n for n in out["notes"] if n.startswith("render:"))
    assert "studio" in note and "stems6" in note and "LUFS" in note
    # no GPU and (on this machine) maybe no /proc: the memory fields are there and empty, never an error
    assert out["vramPeakMB"] is None and out["vramPeakByStageMB"] == {}
    assert set(out["ramPeakByStageMB"]) <= {"stems6", "render"}
    assert out["ramPeakMB"] is None or out["ramPeakMB"] > 0
    assert out["ramLimitMB"] is None or out["ramLimitMB"] > 0
    json.dumps(out)


def test_bench_without_the_six_stem_models_still_renders_from_the_mix(tmp_path):
    worker = make_worker(tmp_path)
    out = worker.handle({"id": "b", "input": {"v": 1, "op": "bench", "bench": {"seconds": 10,
                                                                             "stages": ["stems6", "render"]}}})
    assert out["status"] == "ok" and "stems6" not in out["stagesMs"] and "render" in out["stagesMs"]
    assert any("six-stem separator's weights are not baked" in n for n in out["notes"])
    assert any(n.startswith("render: studio, mix") for n in out["notes"])


def test_bench_says_when_the_cascade_only_gave_four_stems(tmp_path, monkeypatch):
    monkeypatch.setattr(Six, "there", False)
    worker = make_worker(tmp_path, stems6=S.Stems6(Separator(), Four(), Six()))
    out = worker.handle({"id": "b", "input": {"v": 1, "op": "bench", "bench": {"seconds": 10, "stages": ["stems6"]}}})
    assert out["stagesMs"]["stems6Stems"] == 4
    assert "stems6: open-cascade-6 gave 4 stems, not six" in out["notes"]


def test_the_default_bench_covers_the_spatial_path(caps):
    job = validate_job({"v": 1, "op": "bench"}, caps)
    assert job.bench.stages.index("stems4") < job.bench.stages.index("stems6") < job.bench.stages.index("render")
    assert validate_job(load_example("job.input.bench.json"), caps).bench.stages == (
        "decode", "separate", "align", "transcribe", "encode")  # an explicit list is still taken as it is


# ---- op selftest: what 1.1.0 adds ---------------------------------------------------------------------------

def test_selftest_reports_the_library_the_new_model_and_the_host(tmp_path):
    worker = make_worker(tmp_path)
    out = worker.handle({"id": "s", "input": {"v": 1, "op": "selftest"}})
    out.pop("refresh_worker")
    SELFTEST.validate(out)
    assert out["models"]["htdemucs_6s"] == "lazy"
    assert out["library"] == {"libV": 1, "engine": "pixl-spatial-1",
                              "profiles": ["studio", "wide", "intimate", "hall", "surround", "night"]}
    assert set(out["host"]) == {"cpus", "ramLimitMB"} and (out["host"]["cpus"] or 1) >= 1
    # an older worker's answer (the committed example) has neither and is still valid
    old = load_example("selftest.result.json")
    assert "library" not in old and "host" not in old
    SELFTEST.validate(old)


def test_memory_probes_never_raise_and_make_sense_where_they_work(tmp_path, monkeypatch):
    limit, peak = selftest.memory_limit_mb(), selftest.peak_rss_mb()
    assert limit is None or limit > 64
    assert peak is None or peak > 1
    if selftest.peak_rss_mb(reset=True) is not None:  # Linux: counting afresh, a big array shows up in the peak
        block = np.ones(64 * 1024 * 1024 // 8)
        assert selftest.peak_rss_mb() >= 60
        del block
