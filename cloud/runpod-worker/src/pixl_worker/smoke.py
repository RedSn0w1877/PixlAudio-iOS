"""CPU smoke test for the image (run by the Dockerfile's `smoke` stage on CI; never part of the pushed image).

It loads the real baked weights the way the handler does, on CPU, and pushes a few seconds of synthetic audio
through each model the handler loads or may load lazily, except Qwen3-ASR (6.8 GB in fp32 is too much for a CI
runner; `op: bench` on RunPod covers it):

- BS-RoFormer (anvuew ft1) through msst: the vocals come back with the input's length and rate;
- Qwen3-ForcedAligner: one English window aligns to monotonic tokens that map back onto the text;
- htdemucs_ft from the local repo: drums, bass and other come back with the input's length;
- the six-stem cascade (Stems6: those two models plus htdemucs_6s from the same repo): six stems of the input's
  length, progress from start to end;
- one spatial profile rendered from those stems (NumPy and the head model in the package) and packed by the
  library's FLAC encoder: the level, the true peak and the frame count the manifest promises.

This is what proves, before anything is deployed, that the pinned torch / msst / qwen-asr / transformers /
demucs versions and the pinned weights work together (design risk R1). Exit status 0 means every check passed.
Prints one JSON line per check; never touches the network (HF_HUB_OFFLINE=1 in the stage).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np


def _line(check: str, ok: bool, **fields) -> dict:
    record = {"check": check, "ok": ok, **fields}
    print(json.dumps(record), flush=True)
    return record


def smoke(models_dir: str, seconds: float = 4.0) -> bool:
    import torch

    torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
    from .lyrics.align import QwenAligner
    from .lyrics.languages import AlignRequest
    from .lyrics.postprocess import map_tokens
    from .selftest import synthetic_song
    from .separate import GuitarPiano, RoformerSeparator, Stems4, Stems6
    from . import audio as A

    sr = 44100
    mix = synthetic_song(int(seconds), sr)
    frames = mix.shape[0]
    results = []

    t0 = time.monotonic()
    try:
        sep = RoformerSeparator(os.path.join(models_dir, "sep", "config.yaml"),
                                os.path.join(models_dir, "sep", "bs_roformer_ft1_anvuew_sdr_12.55.ckpt"))
        load_ms = int((time.monotonic() - t0) * 1000)
        t1 = time.monotonic()
        vocals = sep.vocals(mix, sr, quality="standard")
        ok = vocals.shape == mix.shape and bool(np.isfinite(vocals).all())
        results.append(_line("separator", ok, loadMs=load_ms, runMs=int((time.monotonic() - t1) * 1000),
                             shape=list(vocals.shape), modelRate=sep.sample_rate))
    except Exception as exc:  # report and carry on so one run shows every failure
        vocals = None
        results.append(_line("separator", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

    # The separator also handles 48 kHz input (resampled in and back out, same frame count).
    try:
        if vocals is not None:
            mix48 = A.resample(mix[: int(2.0 * sr)], sr, 48000)
            v48 = sep.vocals(mix48, 48000, quality="standard")
            results.append(_line("separator_48k", v48.shape == mix48.shape, shape=list(v48.shape)))
    except Exception as exc:
        results.append(_line("separator_48k", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

    try:
        t0 = time.monotonic()
        aligner = QwenAligner(os.path.join(models_dir, "aligner"))
        load_ms = int((time.monotonic() - t0) * 1000)
        voice = A.to_mono_16k(vocals if vocals is not None else mix, sr)
        text = "Hello world, sing along with me"
        t1 = time.monotonic()
        out = aligner.align([AlignRequest(key=0, text=text, language="en", audio=voice[: int(3.5 * 16000)],
                                          offset_s=0.0)])[0]
        tokens = [t.text for t in out or []]
        spans = map_tokens(text, tokens) if tokens else None
        monotonic = all(out[i].start_s <= out[i + 1].start_s for i in range(len(out) - 1)) if out else False
        ok = bool(tokens) and spans is not None and monotonic
        results.append(_line("aligner", ok, loadMs=load_ms, runMs=int((time.monotonic() - t1) * 1000),
                             tokens=tokens, spans=spans))
    except Exception as exc:
        results.append(_line("aligner", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

    stems4 = None
    try:
        stems4 = Stems4(os.path.join(models_dir, "demucs"))
        if not stems4.available():
            raise RuntimeError("htdemucs_ft weights are missing")
        t0 = time.monotonic()
        instrumental = mix - vocals if vocals is not None else mix
        calls: list[tuple[int, int]] = []
        out = stems4.stems(instrumental[: int(3.0 * sr)], sr, progress=lambda done, total: calls.append((done, total)))
        ok = sorted(out) == ["bass", "drums", "other"] and all(v.shape == (int(3.0 * sr), 2) for v in out.values())
        # The progress hook sees the whole bag: one total for every call, never going backwards, reaching the
        # last model (the pipeline's reporter turns this into ~10 updates and checks the deadline on each call).
        dones = [d for d, _ in calls]
        totals = {t for _, t in calls}
        progress_ok = (bool(calls) and len(totals) == 1 and min(totals) > 1000 and dones == sorted(dones)
                       and dones[-1] >= min(totals) - 1000)
        results.append(_line("stems4", ok and progress_ok, runMs=int((time.monotonic() - t0) * 1000),
                             progressCalls=len(calls), progressTotal=sorted(totals), progressLast=dones[-1:]))
    except Exception as exc:
        results.append(_line("stems4", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

    # The spatial path (worker 1.1.0). First the six-stem cascade: the separator's vocals handed in (as a job that
    # also makes an instrumental hands them over), htdemucs_ft on the rest, then htdemucs_6s from the local repo
    # on its "other" stem. Six stems of the input's length must come back and progress must run from 0 to its end.
    clip = mix[: int(3.0 * sr)]
    stems: dict = {}
    try:
        six = GuitarPiano(os.path.join(models_dir, "demucs"))
        if not six.available():
            raise RuntimeError("htdemucs_6s weights or its bag file are missing")
        if vocals is None or stems4 is None or not stems4.available():
            raise RuntimeError("the cascade needs the separator and htdemucs_ft, and one of them failed above")
        cascade = Stems6(sep, stems4, six)
        calls = []
        t0 = time.monotonic()
        stems = cascade.stems(clip, sr, quality="standard", vocals=vocals[: clip.shape[0]],
                              progress=lambda done, total: calls.append((done, total)))
        names_ok = sorted(stems) == ["bass", "drums", "guitar", "other", "piano", "vocals"]
        shapes_ok = all(v.shape == clip.shape and v.dtype == np.float32 and bool(np.isfinite(v).all())
                        for v in stems.values())
        dones = [d for d, _ in calls]
        progress_ok = bool(calls) and dones[0] == 0 and dones[-1] == calls[-1][1] and dones == sorted(dones)
        leftover = clip - sum(stems.values())
        mix_power = float(np.mean(clip.astype(np.float64) ** 2))
        leftover_db = 10.0 * np.log10(max(float(np.mean(leftover.astype(np.float64) ** 2)), 1e-20)
                                      / max(mix_power, 1e-20))
        results.append(_line("stems6", names_ok and shapes_ok and progress_ok and six.loaded,
                             runMs=int((time.monotonic() - t0) * 1000), stems=sorted(stems),
                             progressCalls=len(calls), leftoverDb=round(leftover_db, 1)))
    except Exception as exc:
        stems = {}
        results.append(_line("stems6", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

    # Then one profile through the renderer (NumPy, the committed head model) from those stems, and the library's
    # FLAC encoder (ffmpeg): the file a phone would download. A synthetic clip is not music, so whether the
    # renderer trusts its stems (stems6) or falls back to the mix is reported, not required.
    try:
        import tempfile

        from . import library as L
        from .spatial import CEILING_DB, HEADROOM_DB

        t0 = time.monotonic()
        result = L.render(clip, stems, sr, ["studio"])["studio"]
        run_ms = int((time.monotonic() - t0) * 1000)
        level_ok = abs(result.source_lufs - HEADROOM_DB - result.integrated_lufs) <= 0.5
        ok = (result.audio.shape == clip.shape and bool(np.isfinite(result.audio).all()) and level_ok
              and result.true_peak_db <= CEILING_DB + 0.1 and result.stem_mode in ("stems6", "stems4", "mix"))
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sp-studio.flac")
            L.encode_flac16(result.audio, sr, path)
            with open(path, "rb") as fh:
                head = fh.read(4)
            flac_bytes = os.path.getsize(path)
        results.append(_line("render", ok and head == b"fLaC" and flac_bytes > 1000, runMs=run_ms,
                             stemMode=result.stem_mode, lufs=round(result.integrated_lufs, 2),
                             sourceLufs=round(result.source_lufs, 2), truePeakDb=round(result.true_peak_db, 2),
                             flacBytes=flac_bytes))
    except Exception as exc:
        results.append(_line("render", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

    passed = all(r["ok"] for r in results)
    _line("summary", passed, checks=len(results), frames=frames)
    return passed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--models", default=os.environ.get("PIXL_MODELS_DIR", "/models"))
    parser.add_argument("--seconds", type=float, default=4.0)
    args = parser.parse_args(argv)
    return 0 if smoke(args.models, args.seconds) else 1


if __name__ == "__main__":
    sys.exit(main())
