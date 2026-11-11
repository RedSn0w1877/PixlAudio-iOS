"""separate.py without torch: the demucs wrappers against stand-ins for torch and demucs (same calls, NumPy
underneath), which bag files count as present, and the six-stem cascade's arithmetic, order and progress with fake
models. The real models run in the image's CPU smoke stage (smoke.py), never here."""

import sys
import types
from pathlib import Path

import numpy as np
import pytest

from pixl_worker import errors
from pixl_worker import separate as S

ROOT = Path(__file__).resolve().parents[1]
FT = ("f7e0c4bc-ba3fe64a.th", "d12395a8-e57c48e6.th", "92cfc3b6-ef3bcb9c.th", "04573f0d-f3cf25b2.th")
SIX = "5c90dfd2-34c22ccb.th"


def repo(tmp_path, *, ft=True, six=True, yamls=True) -> Path:
    """A local demucs repo like /models/demucs in the image: the real bag files, empty stand-ins for the weights."""
    root = tmp_path / "demucs"
    root.mkdir(parents=True)
    if yamls:
        for name in ("htdemucs_ft.yaml", "htdemucs_6s.yaml"):
            (root / name).write_bytes((ROOT / "models" / "demucs" / name).read_bytes())
    for name in (FT if ft else ()) + ((SIX,) if six else ()):
        (root / name).write_bytes(b"")
    return root


# ---- which models are there ---------------------------------------------------------------------------------

def test_the_bag_files_name_the_weights_in_weights_lock(tmp_path):
    root = repo(tmp_path)
    assert S.bag_ready(root, "htdemucs_ft") and S.bag_ready(root, "htdemucs_6s")
    lock = (ROOT / "weights.lock").read_text(encoding="utf-8")
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    for name in FT + (SIX,):
        assert f"/models/demucs/{name}" in lock and dockerfile.count(f"/models/demucs/{name}") == 2  # final + smoke
    assert dockerfile.count("COPY --link models/demucs/htdemucs_6s.yaml /models/demucs/htdemucs_6s.yaml") == 2
    assert S.SIX_ID == "htdemucs_6s" and S.STEMS4_ID == "htdemucs_ft" and S.STEMS6_ID == "open-cascade-6"


def test_a_bag_is_ready_only_with_its_yaml_and_every_weight_file(tmp_path):
    root = repo(tmp_path)
    assert not S.bag_ready(root, "htdemucs") and not S.bag_ready(tmp_path / "missing", "htdemucs_ft")
    (root / FT[2]).unlink()
    assert not S.bag_ready(root, "htdemucs_ft") and S.bag_ready(root, "htdemucs_6s")
    (root / "92cfc3b6.th").write_bytes(b"")  # demucs also takes a file without the checksum suffix
    assert S.bag_ready(root, "htdemucs_ft")
    (root / "htdemucs_6s.yaml").write_text("weights: [[1.0]]\n")  # no models line
    assert not S.bag_ready(root, "htdemucs_6s")
    (root / "htdemucs_6s.yaml").write_text("models: []\n")
    assert not S.bag_ready(root, "htdemucs_6s")


def test_each_model_reports_its_own_files(tmp_path):
    both = repo(tmp_path)
    assert S.Stems4(str(both)).available() and S.GuitarPiano(str(both)).available()
    only_six = repo(tmp_path / "a", ft=False)
    # The 6s file alone must not make the 4-stem bag look present (both live in one folder).
    assert not S.Stems4(str(only_six)).available() and S.GuitarPiano(str(only_six)).available()
    only_ft = repo(tmp_path / "b", six=False)
    assert S.Stems4(str(only_ft)).available() and not S.GuitarPiano(str(only_ft)).available()
    no_yaml = repo(tmp_path / "c", yamls=False)
    assert not S.Stems4(str(no_yaml)).available() and not S.GuitarPiano(str(no_yaml)).available()
    nowhere = tmp_path / "nowhere"
    assert not S.Stems4(str(nowhere)).available() and not S.GuitarPiano(str(nowhere)).available()
    assert not S.Stems4(str(both)).loaded and not S.GuitarPiano(str(both)).loaded  # asking loads nothing


# ---- the demucs wrappers, against stand-ins for torch and demucs ----------------------------------------------

class T(np.ndarray):
    """A NumPy array with the two tensor methods the wrapper calls."""

    def cpu(self):
        return self

    def numpy(self):
        return np.asarray(self)


class FakeModel:
    samplerate = 44100

    def __init__(self, name, sources):
        self.name, self.sources, self.evals = name, list(sources), 0

    def eval(self):
        self.evals += 1


class OutOfMemory(Exception):
    pass


@pytest.fixture
def fakes(monkeypatch):
    """torch and demucs as far as separate.py uses them. apply_model splits its (unnormalised) input into equal
    shares per source scaled 1, 2, 3, ... so each source is recognisable, and calls the callback as demucs does."""
    state = types.SimpleNamespace(loads=[], applies=[], cuda=False, emptied=0, fail=None, chunks=4)

    torch = types.ModuleType("torch")
    torch.from_numpy = lambda a: a.view(T)
    torch.cuda = types.SimpleNamespace(
        is_available=lambda: state.cuda, OutOfMemoryError=OutOfMemory,
        empty_cache=lambda: setattr(state, "emptied", state.emptied + 1))

    class inference_mode:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    torch.inference_mode = inference_mode

    def get_model(name, repo=None):
        state.loads.append((name, repo))
        sources = ["drums", "bass", "other", "vocals"] + (["guitar", "piano"] if name == "htdemucs_6s" else [])
        return FakeModel(name, sources)

    def apply_model(model, mix, **kw):
        state.applies.append((model.name, mix.shape, kw))
        if state.fail is not None:
            raise state.fail
        models = 4 if model.name == "htdemucs_ft" else 1
        length = mix.shape[-1]
        for idx in range(models):
            for chunk in range(state.chunks):
                for phase in ("start", "end"):
                    kw["callback"]({"model_idx_in_bag": idx, "models": models, "shift_idx": 0,
                                    "segment_offset": chunk * length // state.chunks, "state": phase})
        total = sum(range(1, len(model.sources) + 1))
        out = np.stack([np.asarray(mix[0]) * (k / total) for k in range(1, len(model.sources) + 1)])
        return out[None].view(T)

    demucs = types.ModuleType("demucs")
    apply_mod, pretrained = types.ModuleType("demucs.apply"), types.ModuleType("demucs.pretrained")
    apply_mod.apply_model, pretrained.get_model = apply_model, get_model
    for name, module in (("torch", torch), ("demucs", demucs), ("demucs.apply", apply_mod),
                         ("demucs.pretrained", pretrained)):
        monkeypatch.setitem(sys.modules, name, module)
    return state


def noise(frames, seed=2):
    return (0.2 * np.random.default_rng(seed).standard_normal((frames, 2))).astype(np.float32)


def share_of(x, share):
    """What the stand-in model returns for a source with this share, after the wrapper's own normalisation (the
    song is centred on the mean of its mono sum and scaled going in, and that is undone coming out)."""
    mean = np.float64(x.mean(axis=1).mean())
    return (x - mean) * share + mean


def test_stems4_returns_three_stems_of_the_inputs_shape(fakes, tmp_path):
    stems4 = S.Stems4(str(repo(tmp_path)))
    x = noise(44100) + np.float32(0.01)
    calls = []
    out = stems4.stems(x, 44100, progress=lambda done, total: calls.append((done, total)))
    assert sorted(out) == ["bass", "drums", "other"] and stems4.loaded
    for share, name in ((1, "drums"), (2, "bass"), (3, "other")):  # the model's own order: drums, bass, other, vocals
        assert out[name].shape == x.shape and out[name].dtype == np.float32
        assert np.allclose(out[name], share_of(x, share / 10.0), atol=1e-6)
    name, shape, kw = fakes.applies[0]
    assert name == "htdemucs_ft" and shape == (1, 2, 44100)
    assert kw["shifts"] == 1 and kw["split"] is True and kw["overlap"] == 0.25 and kw["device"] == "cpu"
    assert kw["progress"] is False
    # progress covers the whole bag: one total, never backwards, into the last model
    dones, totals = [d for d, _ in calls], {t for _, t in calls}
    assert totals == {4000} and dones == sorted(dones) and dones[0] == 0 and dones[-1] >= 3000
    # loaded once per process, from the local repo
    stems4.stems(x, 44100)
    assert fakes.loads == [("htdemucs_ft", stems4.repo_dir)]


def test_demucs_runs_at_its_own_rate_and_the_stems_come_back_at_the_songs(fakes, tmp_path):
    stems4 = S.Stems4(str(repo(tmp_path)))
    x = noise(48000)
    out = stems4.stems(x, 48000, overlap=0.5)
    assert fakes.applies[0][1] == (1, 2, 44100) and fakes.applies[0][2]["overlap"] == 0.5
    assert all(stem.shape == (48000, 2) and stem.dtype == np.float32 for stem in out.values())
    odd = stems4.stems(noise(48001), 48000)
    assert all(stem.shape == (48001, 2) for stem in odd.values())


def test_guitar_and_piano_come_from_the_six_source_model(fakes, tmp_path):
    six = S.GuitarPiano(str(repo(tmp_path)))
    x = noise(22050)
    out = six.split(x, 44100, overlap=0.5)
    assert sorted(out) == ["guitar", "piano"] and six.loaded and six.model_id == "htdemucs_6s"
    assert np.allclose(out["guitar"], share_of(x, 5 / 21.0), atol=1e-6)
    assert np.allclose(out["piano"], share_of(x, 6 / 21.0), atol=1e-6)
    assert fakes.loads == [("htdemucs_6s", six.repo_dir)] and fakes.applies[0][2]["overlap"] == 0.5
    silent = six.split(np.zeros((1000, 2), np.float32), 44100)  # an empty "other" stem: no division by zero
    assert not silent["guitar"].any() and np.isfinite(silent["piano"]).all()


@pytest.mark.parametrize("cuda", [False, True])
def test_gpu_out_of_memory_recycles_the_worker(fakes, tmp_path, cuda):
    fakes.cuda, fakes.fail = cuda, OutOfMemory("CUDA out of memory")
    root = repo(tmp_path)
    for run, doing in ((lambda: S.Stems4(str(root)).stems(noise(4410), 44100), "splitting stems"),
                       (lambda: S.GuitarPiano(str(root)).split(noise(4410), 44100), "splitting guitar and piano")):
        with pytest.raises(errors.WorkerError) as info:
            run()
        assert info.value.code == errors.GPU_OOM and info.value.refresh_worker and doing in info.value.message
    assert fakes.emptied == (2 if cuda else 0)  # the cache is released either way, when there is a GPU
    assert fakes.applies[0][2]["device"] == ("cuda" if cuda else "cpu")


def test_an_exception_from_progress_aborts_the_separation(fakes, tmp_path):
    def progress(done, total):
        raise errors.WorkerError(errors.DEADLINE, "the job ran out of time during stems6")

    with pytest.raises(errors.WorkerError) as info:
        S.Stems4(str(repo(tmp_path))).stems(noise(4410), 44100, progress=progress)
    assert info.value.code == errors.DEADLINE


# ---- the six-stem cascade ------------------------------------------------------------------------------------

class Separator:
    model_id = "fake-separator"

    def __init__(self):
        self.calls = []

    def vocals(self, mix, sr, *, quality="standard", progress=None):
        self.calls.append((mix.shape, sr, quality))
        if progress:
            progress(1, 4)
            progress(4, 4)
        return (0.4 * mix).astype(np.float32)


class Four:
    model_id = "htdemucs_ft"

    def __init__(self, there=True):
        self.calls, self.there = [], there

    def available(self):
        return self.there

    def stems(self, x, sr, *, progress=None, overlap=0.25):
        self.calls.append((x.copy(), sr, overlap))
        if progress:
            progress(500, 4000)
            progress(4000, 4000)
        # like the real bag, the three do not quite add up to the input (its own "vocals" output is dropped)
        return {"drums": (0.5 * x).astype(np.float32), "bass": (0.2 * x).astype(np.float32),
                "other": (0.25 * x).astype(np.float32)}


class Six:
    model_id = "htdemucs_6s"

    def __init__(self, there=True):
        self.calls, self.there = [], there

    def available(self):
        return self.there

    def split(self, other, sr, *, progress=None, overlap=0.25):
        self.calls.append((other.copy(), sr, overlap))
        if progress:
            progress(1000, 1000)
        return {"guitar": (0.3 * other).astype(np.float32), "piano": (0.1 * other[::-1]).astype(np.float32)}


def cascade(four=True, six=True):
    separator, f, s = Separator(), Four(four), (Six(six) if six is not None else None)
    return S.Stems6(separator, f, s), separator, f, s


def test_the_cascade_returns_six_consistent_stems():
    stems6, separator, four, six = cascade()
    mix = noise(30000)
    before = mix.copy()
    out = stems6.stems(mix, 48000, quality="standard")
    assert sorted(out) == ["bass", "drums", "guitar", "other", "piano", "vocals"]
    assert all(stem.shape == mix.shape and stem.dtype == np.float32 for stem in out.values())
    assert np.array_equal(mix, before)
    rest = mix - 0.4 * mix
    assert np.allclose(four.calls[0][0], rest, atol=1e-7)  # htdemucs_ft works on mix minus vocals ...
    other4 = 0.25 * rest
    assert np.allclose(six.calls[0][0], other4, atol=1e-7)  # ... and htdemucs_6s on that "other" stem
    # guitar + piano + what is left add up to that "other" stem exactly (to float32 rounding)
    assert np.allclose(out["guitar"] + out["piano"] + out["other"], other4, atol=2e-7)
    assert np.allclose(out["vocals"], 0.4 * mix, atol=1e-7) and np.allclose(out["drums"], 0.5 * rest, atol=1e-7)
    # what the six do not add up to is only what htdemucs_ft left over; the renderer puts it back into "other"
    assert np.allclose(mix - sum(out.values()), 0.05 * rest, atol=1e-6)
    assert separator.calls == [(mix.shape, 48000, "standard")] and four.calls[0][1:] == (48000, 0.25)
    assert six.calls[0][1:] == (48000, 0.25) and stems6.model_id == "open-cascade-6"


def test_vocals_the_job_already_has_are_not_separated_again():
    stems6, separator, four, _ = cascade()
    mix = noise(20000)
    vocals = (0.1 * noise(20000, seed=5)).astype(np.float32)
    out = stems6.stems(mix, 44100, vocals=vocals)
    assert separator.calls == []  # an instrumental + spatial job runs the vocal separation once
    assert out["vocals"] is vocals and np.allclose(four.calls[0][0], mix - vocals, atol=1e-7)


def test_best_quality_means_more_overlap_in_every_step():
    stems6, separator, four, six = cascade()
    stems6.stems(noise(8000), 44100, quality="best")
    assert separator.calls[0][2] == "best" and four.calls[0][2] == 0.5 and six.calls[0][2] == 0.5
    assert S.DEMUCS_OVERLAP == {"standard": 0.25, "best": 0.5} and S.OVERLAP == {"standard": 2, "best": 4}
    stems6.stems(noise(8000), 44100, quality="something else")
    assert four.calls[1][2] == 0.25


@pytest.mark.parametrize("six", [False, None])
def test_without_htdemucs_6s_the_result_is_the_four_stems(six):
    stems6, _, four, model = cascade(six=six)
    mix = noise(12000)
    out = stems6.stems(mix, 44100)
    assert sorted(out) == ["bass", "drums", "other", "vocals"] and not stems6.six_available()
    assert np.allclose(out["other"], 0.25 * (mix - 0.4 * mix), atol=1e-7)  # "other" is left whole
    assert model is None or model.calls == []
    assert stems6.available()  # four stems are still a render (stemMode stems4)


def test_the_cascade_needs_the_separator_and_htdemucs_ft():
    assert cascade()[0].available() and cascade()[0].six_available()
    assert not cascade(four=False)[0].available()
    assert not S.Stems6(None, Four()).available() and not S.Stems6(Separator(), None).available()


@pytest.mark.parametrize("own_vocals, six", [(False, True), (True, True), (False, False), (True, False)])
def test_progress_runs_from_zero_to_the_end_across_the_steps(own_vocals, six):
    stems6 = cascade(six=six)[0]
    mix = noise(6000)
    calls = []
    stems6.stems(mix, 44100, vocals=(0.3 * mix).astype(np.float32) if own_vocals else None,
                 progress=lambda done, total: calls.append((done, total)))
    dones = [d for d, _ in calls]
    assert {t for _, t in calls} == {1000} and dones[0] == 0 and dones[-1] == 1000 and dones == sorted(dones)
    assert len(set(dones)) >= 3  # every step moved it


def test_a_deadline_inside_any_step_stops_the_cascade():
    for fail_at in (1, 3, 5):
        stems6, separator, four, six = cascade()
        count = {"n": 0}

        def progress(done, total):
            count["n"] += 1
            if count["n"] >= fail_at:
                raise errors.WorkerError(errors.DEADLINE, "the job ran out of time during stems6")

        with pytest.raises(errors.WorkerError) as info:
            stems6.stems(noise(4000), 44100, progress=progress)
        assert info.value.code == errors.DEADLINE
        assert six.calls == []  # out of time before the last step: it never starts


def test_a_stem_that_cannot_be_written_to_is_copied_first():
    stems6, _, four, _ = cascade()
    frozen = {}

    def stems(x, sr, *, progress=None, overlap=0.25):
        out = Four().stems(x, sr)
        out["other"].setflags(write=False)
        frozen["other"] = out["other"]
        return out

    four.stems = stems
    out = stems6.stems(noise(5000), 44100)
    assert out["other"] is not frozen["other"]
    assert np.allclose(out["guitar"] + out["piano"] + out["other"], frozen["other"], atol=2e-7)
