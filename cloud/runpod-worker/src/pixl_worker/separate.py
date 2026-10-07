"""Stage 4 (vocals with BS-RoFormer, anvuew ft1) and stage 5 (htdemucs_ft 4 stems, lazy). Needs torch, msst,
demucs; imported by the handler only.

The separator works at 44.1 kHz. Songs at other rates are handed to msst with their rate (it resamples in), and
its vocals are resampled back, so every output has exactly the input's sample rate and frame count and the
phone's sample-count check (design 7.5) holds. The instrumental is mix − vocals at the input rate.
"""

from __future__ import annotations

from pathlib import Path
from typing import Callable

import numpy as np

from .audio import fit_length, resample
from .errors import GPU_OOM, WorkerError

SEPARATOR_ID = "anvuew-bs-roformer-ft1"
STEMS4_ID = "htdemucs_ft"
OVERLAP = {"standard": 2, "best": 4}


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
        return self.repo_dir.is_dir() and any(self.repo_dir.glob("*.th"))

    def _load(self):
        if self._model is None:
            from demucs.pretrained import get_model

            self._model = get_model("htdemucs_ft", repo=self.repo_dir)
            self._model.eval()
        return self._model

    def stems(self, x: np.ndarray, sample_rate: int, *,
              progress: Callable[[int, int], None] | None = None) -> dict[str, np.ndarray]:
        """x: (frames, 2) at sample_rate (the instrumental). Returns drums, bass, other at the same rate/length."""
        import torch
        from demucs.apply import apply_model

        model = self._load()
        frames = x.shape[0]
        src = resample(x, sample_rate, model.samplerate) if model.samplerate != sample_rate else x
        wav = torch.from_numpy(np.ascontiguousarray(src.T, dtype=np.float32))
        ref = wav.mean(0)
        mean, std = ref.mean(), ref.std() + 1e-8
        done = {"n": 0}

        def callback(info: dict) -> None:
            if progress is not None:
                done["n"] += 1
                progress(done["n"], max(done["n"], 1))

        try:
            with torch.inference_mode():
                out = apply_model(model, ((wav - mean) / std)[None], shifts=1, split=True, overlap=0.25,
                                  device="cuda" if torch.cuda.is_available() else "cpu", progress=False,
                                  callback=callback)[0]
        except torch.cuda.OutOfMemoryError:
            raise WorkerError(GPU_OOM, "the GPU ran out of memory while splitting stems", refresh_worker=True) from None
        finally:
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        out = (out * std + mean).cpu().numpy()
        result = {}
        for name in ("drums", "bass", "other"):
            stem = out[model.sources.index(name)].T.astype(np.float32)
            if model.samplerate != sample_rate:
                stem = resample(stem, model.samplerate, sample_rate)
            result[name] = fit_length(stem, frames)
        return result
