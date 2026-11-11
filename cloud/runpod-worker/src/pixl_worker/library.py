"""The shared library of finished renders (docs/handoff/2026-11-10-plans/cloud-audio-spec.md, sections 2-4).

A render is stored once in R2, keyed by the YouTube video, and every phone fetches it from there:

    lib/v<LIB_V>/<videoId>/sp-<profile>.flac    a spatial render, FLAC 16-bit, the input's rate and frame count
    lib/v<LIB_V>/<videoId>/sp-<profile>.json    its manifest, written LAST: its presence means the render is whole
    lib/v<LIB_V>/<videoId>/enhanced.flac        the restored stereo song (only when something was restored)
    lib/v<LIB_V>/<videoId>/enhanced.json        its manifest; also written without audio when nothing was restored

This module holds everything about that layout that is not a network call: the version and the keys (schema.py
checks every presigned URL against them), the render manifest (schema/v1/library.render.schema.json), the "is it
already there" test, the FLAC encoder (16-bit with TPDF dither made here in NumPy) and the call into the renderer
for sample rates it does not work at. storage.py does the GETs and PUTs, pipeline.py the order.

Nothing in the library is ever updated in place: two jobs that render the same thing write the same result twice.
"""

from __future__ import annotations

import dataclasses
import os
import re
import time
from typing import Any, Callable, Iterable

import numpy as np

from . import audio as A
from .spatial import CEILING_DB, ENGINE_ID, HEADROOM_DB, PROFILE_IDS, SpatialResult, render_profiles
from .spatial.hrir import SUPPORTED_RATES
from .spatial.loudness import integrated_lufs, limit, true_peak_db

# The library version, in every key. Bump it when the renderer or the separator changes audibly: older renders are
# then ignored and expire on their own (the bucket deletes objects 30 days after they were written). The only
# place this number lives; schema/v1/job.input.schema.json and the examples repeat it and the tests compare.
LIB_V = 1

MANIFEST_SCHEMA = "pixl.library.render"
MANIFEST_V = 1
SPATIAL = "spatial"
ENHANCED = "enhanced"   # the kind, and also the output slot of the restored stereo song
RENDER_SLOT_PREFIX = "sp-"
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
STATES = ("ok", "exists", "failed", "not_needed")

RENDER_RATE = 48000     # songs at a rate the renderer does not work at are rendered at this one
FLAC_BITS = 16
DITHER_SEED = 20261110  # fixed: the same render always becomes the same file
_DITHER_CHUNK = 1 << 18

__all__ = ["DITHER_SEED", "ENGINE_ID", "ENHANCED", "FLAC_BITS", "HEADROOM_DB", "LIB_V", "MANIFEST_SCHEMA",
           "MANIFEST_V", "PROFILE_IDS", "RENDER_RATE", "SPATIAL", "STATES", "VIDEO_ID_RE", "audio_block",
           "audio_key", "dither_to_int16", "encode_flac16", "existing_output", "loudness_block", "manifest_key",
           "manifest_matches", "output_entry", "render", "render_manifest", "render_slot", "slot_kind",
           "stereo_loudness", "utc_now"]


# ---- keys ------------------------------------------------------------------------------------------------------

def render_slot(profile: str) -> str:
    """The output slot of a spatial profile: `sp-studio`. Slots name the job manifest's outputs and the files."""
    return f"{RENDER_SLOT_PREFIX}{profile}"


def slot_kind(slot: str) -> tuple[str, str | None]:
    """(kind, profile) of an output slot: ("spatial", "studio") for sp-studio, ("enhanced", None) for enhanced."""
    if slot == ENHANCED:
        return ENHANCED, None
    if slot.startswith(RENDER_SLOT_PREFIX) and slot[len(RENDER_SLOT_PREFIX):] in PROFILE_IDS:
        return SPATIAL, slot[len(RENDER_SLOT_PREFIX):]
    raise ValueError(f"not a library slot: {slot}")


def audio_key(video_id: str, slot: str) -> str:
    return f"lib/v{LIB_V}/{video_id}/{slot}.flac"


def manifest_key(video_id: str, slot: str) -> str:
    return f"lib/v{LIB_V}/{video_id}/{slot}.json"


# ---- manifests -------------------------------------------------------------------------------------------------

def utc_now(now: float | None = None) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))


def _is_int(value: Any, *, lo: int = 0) -> bool:
    return type(value) is int and value >= lo


def manifest_matches(doc: Any, *, video_id: str, slot: str) -> bool:
    """Is `doc` (what a GET of the slot's manifest returned) a finished render of exactly this video and slot?
    That is: schema, v, libV, videoId, kind and profile are the ones asked for. A spatial manifest also has to
    name its own audio object, with a size and a sha256, because a phone would reject it otherwise and the render
    would then never be made again while that manifest sits there. Anything else means "make it"."""
    kind, profile = slot_kind(slot)
    if not isinstance(doc, dict):
        return False
    if doc.get("schema") != MANIFEST_SCHEMA or type(doc.get("v")) is not int or doc["v"] != MANIFEST_V:
        return False
    if type(doc.get("libV")) is not int or doc["libV"] != LIB_V:
        return False
    if doc.get("videoId") != video_id or doc.get("kind") != kind or doc.get("profile") != profile:
        return False
    audio = doc.get("audio")
    if audio is None:
        return kind == ENHANCED  # "nothing to restore" has no file; a spatial render always has one
    return (isinstance(audio, dict) and audio.get("key") == audio_key(video_id, slot)
            and _is_int(audio.get("bytes"), lo=1) and isinstance(audio.get("sha256"), str)
            and bool(SHA256_RE.match(audio["sha256"])) and _is_int(audio.get("sampleRate"), lo=1)
            and _is_int(audio.get("samples")))


def output_entry(key: str, size: int, sha256: str, sample_rate: int, samples: int) -> dict:
    """A library file as the job manifest's `outputs` lists it: the same shape as a stem output."""
    return {"key": key, "bytes": size, "sha256": sha256, "codec": "flac", "kbps": None,
            "sampleRate": sample_rate, "samples": samples}


def existing_output(doc: dict) -> dict | None:
    """The `outputs` entry for a render that was already in the library (its manifest passed manifest_matches),
    or None when that manifest has no audio (an enhanced.json that says nothing needed restoring)."""
    audio = doc.get("audio")
    if not isinstance(audio, dict):
        return None
    return output_entry(audio["key"], audio["bytes"], audio["sha256"], audio["sampleRate"], audio["samples"])


def audio_block(key: str, size: int, sha256: str, sample_rate: int, samples: int) -> dict:
    return {"key": key, "bytes": size, "sha256": sha256, "codec": "flac", "bits": FLAC_BITS,
            "sampleRate": sample_rate, "samples": samples,
            "durationMs": int(round(samples * 1000 / sample_rate))}


def loudness_block(integrated: float, source: float, headroom_db: float, true_peak: float, limiter_max: float) -> dict:
    return {"integratedLufs": round(float(integrated), 2), "sourceLufs": round(float(source), 2),
            "headroomDb": round(float(headroom_db), 2), "truePeakDb": round(float(true_peak), 2),
            "limiterMaxDb": round(float(limiter_max), 2)}


def stereo_loudness(audio: np.ndarray, source: np.ndarray, sample_rate: int) -> dict:
    """The loudness block of a file that keeps its source's level (enhanced.flac): measured, with headroomDb 0."""
    return loudness_block(integrated_lufs(audio, sample_rate), integrated_lufs(source, sample_rate), 0.0,
                          true_peak_db(audio), 0.0)


def render_manifest(*, video_id: str, slot: str, audio: dict | None, loudness: dict | None, source: dict,
                    engine: str | None, stems: str | None, stem_mode: str | None, restore: dict, worker: dict,
                    created_at: str | None = None) -> dict:
    """The manifest of one library object (spec 3.1). `audio` and `loudness` are None for an enhanced.json that
    only says nothing was restored; `engine`, `stems` and `stem_mode` are None for every enhanced.json."""
    kind, profile = slot_kind(slot)
    return {
        "schema": MANIFEST_SCHEMA, "v": MANIFEST_V, "libV": LIB_V,
        "videoId": video_id, "kind": kind, "profile": profile,
        "audio": audio, "loudness": loudness, "source": dict(source),
        "render": {"engine": engine, "stems": stems, "stemMode": stem_mode, "restore": dict(restore)},
        "worker": {"version": worker.get("version"), "gitSha": worker.get("gitSha")},
        "createdAt": created_at or utc_now(),
    }


# ---- FLAC 16-bit with TPDF dither ------------------------------------------------------------------------------

def dither_to_int16(samples: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """float [-1, 1] -> int16, with triangular (TPDF) dither of +/- 1 LSB added before rounding, so the 16-bit
    file carries no distortion that follows the music, only a steady noise floor near -93 dBFS."""
    noise = rng.random(samples.shape, dtype=np.float32)
    noise -= rng.random(samples.shape, dtype=np.float32)
    scaled = samples.astype(np.float32, copy=False) * np.float32(32768.0) + noise
    return np.clip(np.rint(scaled), -32768, 32767).astype("<i2")


def encode_flac16(samples: np.ndarray, sample_rate: int, out_path: str, *, timeout: float = 120.0,
                  seed: int = DITHER_SEED) -> None:
    """(frames, channels) float32 -> a 16-bit FLAC with exactly `frames` frames. The dither is made here, a chunk
    at a time (no second copy of the song in memory), and ffmpeg packs the finished 16-bit samples bit for bit."""
    if samples.ndim != 2 or samples.shape[0] < 1:
        raise ValueError("samples must be (frames, channels) with at least one frame")
    raw = out_path + ".s16"
    rng = np.random.default_rng(seed)
    try:
        with open(raw, "wb") as fh:
            for start in range(0, samples.shape[0], _DITHER_CHUNK):
                dither_to_int16(samples[start:start + _DITHER_CHUNK], rng).tofile(fh)
        A.flac_from_s16(raw, sample_rate, samples.shape[1], out_path, timeout=timeout)
    finally:
        try:
            os.remove(raw)
        except OSError:
            pass


# ---- the renderer, at any sample rate --------------------------------------------------------------------------

def render(mix: np.ndarray, stems: dict[str, np.ndarray], sample_rate: int, profiles: Iterable[str],
           progress: Callable[[int, int], None] | None = None) -> dict[str, SpatialResult]:
    """pixl_worker.spatial.render_profiles for a song at any sample rate. The renderer works at 44.1 and 48 kHz;
    anything else is resampled to 48 kHz, rendered, and resampled back to the song's own rate and frame count (the
    library keeps the source's timeline). Resampling is not exactly level-neutral and can move a peak, so the
    result is then finished the way the renderer finishes its own: set HEADROOM_DB under the song's loudness (the
    song as it is, at its own rate), passed through the same limiter (idle unless a peak is over the ceiling), and
    measured again, so the manifest's numbers describe the file."""
    if sample_rate in SUPPORTED_RATES:
        return render_profiles(mix, stems, sample_rate, profiles, progress)
    frames = mix.shape[0]
    source_lufs = integrated_lufs(mix, sample_rate)
    mix_r = A.resample(mix, sample_rate, RENDER_RATE)
    stems_r = {name: A.fit_length(A.resample(stem, sample_rate, RENDER_RATE), mix_r.shape[0])
               for name, stem in stems.items() if stem is not None}
    results = render_profiles(mix_r, stems_r, RENDER_RATE, profiles, progress)
    del mix_r, stems_r
    for profile in list(results):
        result = results[profile]
        audio = np.array(A.fit_length(A.resample(result.audio, RENDER_RATE, sample_rate), frames), dtype=np.float32)
        loudness = integrated_lufs(audio, sample_rate)
        if loudness > -69.0 and source_lufs > -69.0:
            trim_db = float(np.clip(source_lufs - HEADROOM_DB - loudness, -3.0, 3.0))
            audio *= np.float32(10.0 ** (trim_db / 20.0))
        audio, reduction = limit(audio, sample_rate, CEILING_DB)
        np.clip(audio, -1.0, 1.0, out=audio)
        results[profile] = dataclasses.replace(
            result, audio=audio, integrated_lufs=integrated_lufs(audio, sample_rate), source_lufs=source_lufs,
            true_peak_db=true_peak_db(audio), limiter_max_db=result.limiter_max_db + reduction)
    return results
