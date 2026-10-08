"""CPU smoke test for the image (run by the Dockerfile's `smoke` stage on CI; never part of the pushed image).

It loads the real baked weights the way the handler does, on CPU, and pushes a few seconds of synthetic audio
through each model the handler loads or may load lazily, except Qwen3-ASR (6.8 GB in fp32 is too much for a CI
runner; `op: bench` on RunPod covers it):

- BS-RoFormer (anvuew ft1) through msst: the vocals come back with the input's length and rate;
- Qwen3-ForcedAligner: one English window aligns to monotonic tokens that map back onto the text;
- htdemucs_ft from the local repo: drums, bass and other come back with the input's length.

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
    from .separate import RoformerSeparator, Stems4
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

    try:
        stems4 = Stems4(os.path.join(models_dir, "demucs"))
        if not stems4.available():
            raise RuntimeError("htdemucs_ft weights are missing")
        t0 = time.monotonic()
        instrumental = mix - vocals if vocals is not None else mix
        out = stems4.stems(instrumental[: int(3.0 * sr)], sr)
        ok = sorted(out) == ["bass", "drums", "other"] and all(v.shape == (int(3.0 * sr), 2) for v in out.values())
        results.append(_line("stems4", ok, runMs=int((time.monotonic() - t0) * 1000)))
    except Exception as exc:
        results.append(_line("stems4", False, error=f"{type(exc).__name__}: {str(exc)[:300]}"))

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
