"""op: selftest (versions, GPU, models; no audio, no storage) and op: bench (a synthetic song through every stage,
timing each one and the peak VRAM; uploads nothing). Design 2.3, risk R2 and step W1."""

from __future__ import annotations

import importlib.metadata
import os
import platform
import sys
import tempfile
import time
from typing import Any

import numpy as np

from . import SUPPORTED_VERSIONS, WORKER_VERSION
from . import audio as A
from .config import Caps
from .lyrics.languages import AlignRequest, backend_for, word_timing_languages
from .log import log

OPS = ["process", "selftest", "bench"]


def _version(dist: str) -> str | None:
    try:
        return importlib.metadata.version(dist)
    except importlib.metadata.PackageNotFoundError:
        return None


def versions() -> dict[str, str | None]:
    out: dict[str, str | None] = {"python": platform.python_version()}
    for name, dist in (("torch", "torch"), ("runpod", "runpod"), ("msst", "msst"), ("qwen_asr", "qwen-asr"),
                       ("transformers", "transformers"), ("demucs", "demucs")):
        out[name] = _version(dist)
    out["ffmpeg"] = A.ffmpeg_version()
    return out


def caps_summary(caps: Caps) -> dict[str, Any]:
    """The server-side limits the app should respect before it uploads anything (it can't raise them)."""
    return {
        "maxInputMB": caps.max_input_mb, "maxAudioS": caps.max_audio_s, "bestMaxAudioS": caps.best_max_audio_s,
        "maxLyricsLines": caps.max_lyrics_lines, "maxLyricsChars": caps.max_lyrics_chars,
        "maxBodyKB": caps.max_body_kb, "hostsConfigured": len(caps.allowed_host_suffixes),
    }


def selftest(worker: dict, models_state: dict, cold_start_ms: int, caps: Caps | None = None) -> dict[str, Any]:
    out = {
        "schema": "pixl.cloudstudio.selftest", "v": 1, "status": "ok",
        "supported": list(SUPPORTED_VERSIONS), "ops": OPS,
        "worker": dict(worker), "models": dict(models_state), "versions": versions(),
        "wordTimingLanguages": word_timing_languages(),
        "coldStartMs": int(cold_start_ms), "error": None,
    }
    if caps is not None:
        out["caps"] = caps_summary(caps)
    return out


def synthetic_song(seconds: int, sr: int = 44100, seed: int = 7) -> np.ndarray:
    """A deterministic stereo test signal: a chord bed, a drum-like click track and a 'voice' (a vibrato tone
    with formant-ish harmonics) that sings 3 s phrases with 1 s breaths. Not music, but the right shape."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * sr), dtype=np.float32) / sr
    bed = sum(0.08 * np.sin(2 * np.pi * f * t) for f in (110.0, 164.8, 220.0, 277.2))
    clicks = np.zeros_like(t)
    beat = int(0.5 * sr)
    burst = (rng.standard_normal(2000).astype(np.float32) * np.exp(-np.arange(2000) / 300.0)).astype(np.float32)
    for start in range(0, len(t) - 2000, beat):
        clicks[start:start + 2000] += 0.3 * burst
    f0 = 220.0 * (1 + 0.01 * np.sin(2 * np.pi * 5.5 * t))
    phase = 2 * np.pi * np.cumsum(f0) / sr
    voice = sum((0.12 / k) * np.sin(k * phase) for k in (1, 2, 3, 5))
    gate = ((t % 4.0) < 3.0).astype(np.float32)
    left = bed + clicks + 0.9 * voice * gate
    right = bed + 0.8 * clicks + 1.0 * voice * gate
    return np.stack([left, right], axis=1).astype(np.float32) * 0.8


def bench(spec, *, caps: Caps, worker: dict, separator, stems4, transcriber_factory, cold_start_ms: int,
          progress=lambda message: None) -> dict[str, Any]:
    """Every stage on `spec.seconds` of synthetic audio. Returns per-stage milliseconds, lazy-load times and the
    peak VRAM. The crash flag (test builds only) kills the process to measure RunPod's re-delivery (W1)."""
    if spec.crash:
        if not caps.allow_crash_test:
            return {"error": "BAD_SCHEMA: bench.crash needs PIXL_ALLOW_CRASH_TEST=1 on the endpoint"}
        log.warning("bench_crash", note="exiting on purpose to measure re-delivery")
        sys.stdout.flush()
        os._exit(137)

    torch = None
    try:
        import torch as _torch  # noqa: F401

        torch = _torch
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
    except ImportError:
        pass

    stages: dict[str, int] = {}
    loads: dict[str, int] = {}
    notes: list[str] = []

    def timed(name: str, fn):
        t0 = time.monotonic()
        value = fn()
        stages[name] = int(round((time.monotonic() - t0) * 1000))
        progress(f"bench:{name}")
        return value

    sr = 44100
    mix = synthetic_song(spec.seconds, sr)
    with tempfile.TemporaryDirectory(dir=caps.tmp_root if os.path.isdir(caps.tmp_root) else None) as work:
        if "decode" in spec.stages:
            src = os.path.join(work, "bench.m4a")
            A.encode(mix, sr, src, codec="aac", kbps=256)

            def decode():
                info = A.probe(src, caps)
                return A.decode(src, info, caps, work)
            decoded = timed("decode", decode)
            stages["decodedFrames"] = int(decoded.shape[0])
        vocals = None
        if "separate" in spec.stages and separator is not None:
            vocals = timed("separate", lambda: separator.vocals(mix, sr, quality="standard"))
        instrumental = mix - vocals if vocals is not None else mix
        if "stems4" in spec.stages:
            if stems4 is not None and stems4.available():
                t0 = time.monotonic()
                timed("stems4", lambda: stems4.stems(instrumental, sr))
                loads["stems4"] = stages["stems4"]  # includes the first load
            else:
                notes.append("stems4: weights not baked into this image")
        voice16k = A.to_mono_16k(vocals if vocals is not None else mix, sr)
        if "align" in spec.stages:
            backend = backend_for("en")
            if backend is None:
                notes.append("align: no word-timing backend loaded")
            else:
                requests = []
                for k in range(min(40, spec.seconds // 4)):
                    start = 4.0 * k
                    clip = voice16k[int(start * 16000): int((start + 5.5) * 16000)]
                    requests.append(AlignRequest(key=k, text="la la la sing along with me", language="en",
                                                 audio=clip, offset_s=start))
                if hasattr(backend, "deadline"):
                    backend.deadline = None  # the bench has no deadline; never inherit a finished job's
                timed("align", lambda: backend.align(requests))
                stages["alignWindows"] = len(requests)
        if "transcribe" in spec.stages and transcriber_factory is not None:
            t0 = time.monotonic()
            transcriber = transcriber_factory()
            loads["asr"] = int(round((time.monotonic() - t0) * 1000))
            clips = [voice16k[int(4.0 * k * 16000): int((4.0 * k + 3.0) * 16000)] for k in range(min(10, spec.seconds // 4))]
            if hasattr(transcriber, "deadline"):
                transcriber.deadline = None
            timed("transcribe", lambda: transcriber.transcribe(clips, "en"))
            stages["transcribeClips"] = len(clips)
        if "encode" in spec.stages:
            out = os.path.join(work, "inst.m4a")
            timed("encode", lambda: A.encode(instrumental, sr, out, codec="aac", kbps=256))

    vram_peak = None
    if torch is not None and torch.cuda.is_available():
        vram_peak = int(torch.cuda.max_memory_allocated() // (1024 * 1024))
    return {
        "schema": "pixl.cloudstudio.bench", "v": 1, "status": "ok", "seconds": spec.seconds,
        "stagesMs": stages, "lazyLoadMs": loads, "vramPeakMB": vram_peak, "notes": notes,
        "worker": dict(worker), "coldStartMs": int(cold_start_ms),
    }
