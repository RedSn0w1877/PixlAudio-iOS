"""Stage 4 (vocals with BS-RoFormer, anvuew ft1), stage 5 (htdemucs_ft 4 stems, lazy) and the six-stem cascade
behind the spatial renders (Stems6: those two plus htdemucs_6s, lazy). Needs torch, msst, demucs; the heavy imports
happen inside the methods, so the handler (and the CPU tests, with fakes) can import this module without them.

The separator works at 44.1 kHz. Songs at other rates are handed to msst with their rate (it resamples in), and
its vocals are resampled back, so every output has exactly the input's sample rate and frame count and the
phone's sample-count check (design 7.5) holds. The instrumental is mix − vocals at the input rate.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable

import numpy as np

from .audio import fit_length, resample
from .errors import GPU_OOM, WorkerError

SEPARATOR_ID = "anvuew-bs-roformer-ft1"
STEMS4_ID = "htdemucs_ft"
SIX_ID = "htdemucs_6s"
STEMS6_ID = "open-cascade-6"
OVERLAP = {"standard": 2, "best": 4}
# demucs' overlap between its 7.8 s segments. The 4-stem task has always used 0.25; the six-stem cascade uses
# more for `separation.quality: best`, as the vocal separator does (cloud-audio-spec.md, section 4).
DEMUCS_OVERLAP = {"standard": 0.25, "best": 0.5}


class _ProgressHook:
    """Stands in for msst's tqdm so its chunk loop reports progress and honours the deadline (an exception raised
    here aborts the separation cleanly)."""

    callback: Callable[[int, int], None] | None = None

    def __init__(self, iterable=None, total=None, **_kwargs):
        self.iterable = iterable
        self.total = total if total is not None else (len(iterable) if iterable is not None else 0)
        self.n = 0

    def __iter__(self):
        for item in self.iterable or ():
            yield item

    def update(self, n=1):
        self.n += n
        callback = _ProgressHook.callback
        if callback is not None:
            callback(self.n, self.total or 1)

    def close(self):
        pass

    def set_postfix(self, *args, **kwargs):
        pass


class RoformerSeparator:
    model_id = SEPARATOR_ID

    def __init__(self, config_path: str, checkpoint_path: str):
        import torch
        import msst
        import msst.utils.model_utils as model_utils

        self._torch = torch
        model_utils.tqdm = _ProgressHook  # progress + deadline inside the chunk loop
        self._sep = msst.Separator(
            config_path=config_path, checkpoint_path=checkpoint_path, model_type="bs_roformer",
            device_ids=0, extract_instrumental=False, detailed_progress=True)
        self.sample_rate = self._sep.sample_rate

    def vocals(self, mix: np.ndarray, sample_rate: int, *, quality: str = "standard",
               progress: Callable[[int, int], None] | None = None) -> np.ndarray:
        """mix: (frames, 2) float32 at sample_rate. Returns vocals (frames, 2) at the same rate and length."""
        frames = mix.shape[0]
        self._sep._config.inference.num_overlap = OVERLAP.get(quality, 2)
        _ProgressHook.callback = progress
        try:
            stems = self._sep.separate(np.ascontiguousarray(mix.T), sample_rate=sample_rate, channels_first=True)
        except self._torch.cuda.OutOfMemoryError:
            raise WorkerError(GPU_OOM, "the GPU ran out of memory while separating", refresh_worker=True) from None
        finally:
            _ProgressHook.callback = None
            if self._torch.cuda.is_available():
                self._torch.cuda.empty_cache()
        vocals = np.asarray(stems["vocals"], dtype=np.float32)
        if vocals.ndim == 1:
            vocals = np.stack([vocals, vocals])
        vocals = vocals.T  # (frames@44.1k, 2)
        if self.sample_rate != sample_rate:
            vocals = resample(vocals, self.sample_rate, sample_rate)
        return fit_length(vocals, frames)


def bag_ready(repo_dir: Path, name: str) -> bool:
    """Is the demucs bag `<name>.yaml` in the local repo together with the weight file of every model it lists?
    (demucs names each file `<signature>-<start of its sha256>.th`.) Reads the one `models: [...]` line itself, so
    asking needs neither demucs nor a YAML library."""
    try:
        text = (repo_dir / f"{name}.yaml").read_text(encoding="utf-8")
    except OSError:
        return False
    listed = re.search(r"^models:\s*\[([^\]]*)\]", text, re.MULTILINE)
    signatures = re.findall(r"[0-9A-Za-z_]+", listed.group(1)) if listed else []
    return bool(signatures) and all(
        any(repo_dir.glob(f"{sig}-*.th")) or (repo_dir / f"{sig}.th").is_file() for sig in signatures)


def _apply_demucs(model, x: np.ndarray, sample_rate: int, names: tuple[str, ...], *, overlap: float,
                  progress: Callable[[int, int], None] | None, doing: str) -> dict[str, np.ndarray]:
    """Run a demucs model (or bag of models) over x, (frames, 2) at sample_rate, and return the sources `names`
    at the same rate and length. `doing` finishes the sentence "the GPU ran out of memory while ..."."""
    import torch
    from demucs.apply import apply_model

    frames = x.shape[0]
    src = resample(x, sample_rate, model.samplerate) if model.samplerate != sample_rate else x
    wav = torch.from_numpy(np.ascontiguousarray(src.T, dtype=np.float32))
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    length = max(1, int(src.shape[0]))

    def callback(info: dict) -> None:
        # demucs 4.1.0 apply_model calls this at the start and at the end of every chunk of every model in the
        # bag, with model_idx_in_bag / models and the chunk's segment_offset (samples). Report how far through
        # the whole bag that is (the reporter checks the deadline on every call and sends ~10 updates; each
        # runpod progress_update is its own thread and HTTP call, so never one per chunk).
        if progress is None:
            return
        models = max(1, int(info.get("models") or 1))
        idx = min(models - 1, max(0, int(info.get("model_idx_in_bag") or 0)))
        within = min(1.0, max(0.0, float(info.get("segment_offset") or 0) / length))
        progress(int(round(1000 * (idx + within))), 1000 * models)

    try:
        with torch.inference_mode():
            out = apply_model(model, ((wav - mean) / std)[None], shifts=1, split=True, overlap=overlap,
                              device="cuda" if torch.cuda.is_available() else "cpu", progress=False,
                              callback=callback)[0]
    except torch.cuda.OutOfMemoryError:
        raise WorkerError(GPU_OOM, f"the GPU ran out of memory while {doing}", refresh_worker=True) from None
    finally:
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    out = (out * std + mean).cpu().numpy()
    result = {}
    for name in names:
        stem = out[model.sources.index(name)].T.astype(np.float32)
        if model.samplerate != sample_rate:
            stem = resample(stem, model.samplerate, sample_rate)
        result[name] = fit_length(stem, frames)
    return result


class Stems4:
    """htdemucs_ft (a bag of 4 models) from the baked local repo; loaded on first use."""

    model_id = STEMS4_ID

    def __init__(self, repo_dir: str):
        self.repo_dir = Path(repo_dir)
        self._model = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def available(self) -> bool:
        return self.repo_dir.is_dir() and bag_ready(self.repo_dir, STEMS4_ID)

    def _load(self):
        if self._model is None:
            from demucs.pretrained import get_model

            self._model = get_model(STEMS4_ID, repo=self.repo_dir)
            self._model.eval()
        return self._model

    def stems(self, x: np.ndarray, sample_rate: int, *, progress: Callable[[int, int], None] | None = None,
              overlap: float = DEMUCS_OVERLAP["standard"]) -> dict[str, np.ndarray]:
        """x: (frames, 2) at sample_rate (the instrumental). Returns drums, bass, other at the same rate/length."""
        return _apply_demucs(self._load(), x, sample_rate, ("drums", "bass", "other"), overlap=overlap,
                             progress=progress, doing="splitting stems")


class GuitarPiano:
    """htdemucs_6s (one model, MIT, 55 MB) from the same local repo, loaded on first use. Only its guitar and piano
    outputs are used: Stems6 runs it on the "other" stem of htdemucs_ft to lift those two out of it."""

    model_id = SIX_ID

    def __init__(self, repo_dir: str):
        self.repo_dir = Path(repo_dir)
        self._model = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def available(self) -> bool:
        return self.repo_dir.is_dir() and bag_ready(self.repo_dir, SIX_ID)

    def _load(self):
        if self._model is None:
            from demucs.pretrained import get_model

            self._model = get_model(SIX_ID, repo=self.repo_dir)
            self._model.eval()
        return self._model

    def split(self, other: np.ndarray, sample_rate: int, *, progress: Callable[[int, int], None] | None = None,
              overlap: float = DEMUCS_OVERLAP["standard"]) -> dict[str, np.ndarray]:
        """other: (frames, 2) at sample_rate. Returns guitar and piano at the same rate and length."""
        return _apply_demucs(self._load(), other, sample_rate, ("guitar", "piano"), overlap=overlap,
                             progress=progress, doing="splitting guitar and piano")


def _phase(progress: Callable[[int, int], None] | None, start: float, end: float):
    """A sub-stage's progress callback that reports into the slice [start, end] of the whole stage (0..1)."""
    if progress is None:
        return None

    def report(done: int, total: int) -> None:
        fraction = min(1.0, max(0.0, done / max(1, total)))
        progress(int(round(1000 * (start + (end - start) * fraction))), 1000)
    return report


class Stems6:
    """Six stems from open models only, as a cascade (cloud-audio-spec.md, section 5):

    1. vocals from the BS-RoFormer separator (or handed in, when the job already separated them for its
       instrumental: the vocal separation never runs twice);
    2. htdemucs_ft on mix − vocals for drums, bass and other;
    3. htdemucs_6s on that "other" for guitar and piano; what is left of it stays "other". Running it on "other"
       keeps the six consistent: guitar + piano + what is left add up to step 2's "other".

    Without the htdemucs_6s files step 3 is skipped and the result is the four stems (the render then says
    stemMode stems4). Whatever the stems do not add up to (htdemucs_ft's own leftover) the renderer puts back
    into "other". Every stem has the input's sample rate and frame count."""

    model_id = STEMS6_ID
    # roughly how the stage's time splits between its three steps (for the progress reports only)
    _WEIGHTS = {"vocals": 0.50, "stems4": 0.38, "six": 0.12}

    def __init__(self, separator, stems4, six=None):
        self.separator, self.stems4, self.six = separator, stems4, six

    def available(self) -> bool:
        return self.separator is not None and self.stems4 is not None and self.stems4.available()

    def six_available(self) -> bool:
        return self.six is not None and self.six.available()

    def stems(self, mix: np.ndarray, sample_rate: int, *, quality: str = "standard",
              vocals: np.ndarray | None = None,
              progress: Callable[[int, int], None] | None = None) -> dict[str, np.ndarray]:
        """mix: (frames, 2) float32 at sample_rate; vocals: the separator's vocals of this same mix when the
        caller already has them. Returns vocals, drums, bass, other and, with htdemucs_6s, guitar and piano."""
        overlap = DEMUCS_OVERLAP.get(quality, DEMUCS_OVERLAP["standard"])
        six = self.six if self.six_available() else None
        steps = (["vocals"] if vocals is None else []) + ["stems4"] + (["six"] if six is not None else [])
        total = sum(self._WEIGHTS[step] for step in steps)
        edges, at = {}, 0.0
        for step in steps:
            edges[step] = (at, at + self._WEIGHTS[step] / total)
            at = edges[step][1]
        if progress is not None:
            progress(0, 1000)
        if vocals is None:
            vocals = self.separator.vocals(mix, sample_rate, quality=quality,
                                           progress=_phase(progress, *edges["vocals"]))
        vocals = np.asarray(vocals, dtype=np.float32)
        rest = np.subtract(mix, vocals, dtype=np.float32)
        out = self.stems4.stems(rest, sample_rate, progress=_phase(progress, *edges["stems4"]), overlap=overlap)
        del rest
        out["vocals"] = vocals
        if six is not None:
            if progress is not None:
                progress(int(round(1000 * edges["six"][0])), 1000)
            lifted = six.split(out["other"], sample_rate, progress=_phase(progress, *edges["six"]), overlap=overlap)
            other = out["other"]
            if other.dtype != np.float32 or not other.flags.writeable:
                other = np.array(other, dtype=np.float32)
            for name in ("guitar", "piano"):  # in place: what is left of "other" once the two are out of it
                np.subtract(other, lifted[name], out=other)
                out[name] = lifted[name]
            out["other"] = other
        if progress is not None:
            progress(1000, 1000)
        return out
