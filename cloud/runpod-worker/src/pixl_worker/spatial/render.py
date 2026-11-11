"""The spatial renderer: stems in, one binaural stereo file per profile out.

For each profile:
1. every stem is taken apart into its sources, each with its own direction, and its ambience (upmix.py); each
   becomes a source at its place in the profile's room: direct sound through the head model plus early
   reflections (room.py). In the profiles that ask for it, centred instruments are also spread around the
   listener (room.py, decorrelate.py);
2. a stereo send of all stems feeds the room's late reverb;
3. below the crossover (110 Hz) the ORIGINAL mix passes straight through, time-aligned, so bass and kick keep
   their weight and punch. (Nothing of the untouched mix is blended back above it: it cancels against the head
   model's phase. A 25 % blend measured as a 2-5 dB hole from 2.5 to 8 kHz.)
4. the result is matched to the original: its long-term tone (third-octave, at most +/- 5 dB; in practice it
   has about 2 dB to do), then its loudness (BS.1770), and a true-peak limiter that is idle unless a peak goes
   over -1 dBTP.

Everything is deterministic (fixed seeds), NumPy only, and the output has exactly the input's length and
timeline.

Memory: a stem taken apart is up to nine full-length signals, so stems are taken apart one or two at a time and
each is placed in every requested profile before it is let go. What stays for the whole job is the song, its
stems, and one stereo accumulator per profile.
"""

from __future__ import annotations

import os
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable, Iterable, Iterator

import numpy as np

from . import hrir as hrir_mod
from .dsp import convolve_bank, fast_len, interp_log, smooth_bands
from .loudness import integrated_lufs, limit, true_peak_db
from .profiles import PROFILES, STEM_NAMES, Profile, Stage
from .room import KernelBuilder, late_tail
from .upmix import TRANSIENT, Decomposition, decompose

CEILING_DB = -1.0
# A binaural render of a loud modern master peaks 3-5 dB higher than the master at the same loudness (the head
# model and the room undo the phase alignment its limiter relied on). Rather than squash that back, every render
# sits this far under the source's loudness; the on-device stage does the same, so the two match, and the apps
# give the level back whenever their own volume gain has the room (spec 6.3).
HEADROOM_DB = 4.0
TONE_LIMIT_DB = 5.0
BAD_STEMS_DB = -6.0     # stems that miss the mix by more than this are not trusted
SILENT_DB = -70.0
# Levels. A source signal carries the power its sound had in BOTH channels together, and that power is shared
# between the two ears (equally for a centred sound, mostly the near ear for a panned one). Every direction's head
# model is levelled to the front's, per ear, so the share is 1/sqrt(2) everywhere: a centred voice then reaches
# each ear exactly as on plain headphones, and a hard-panned guitar keeps the power its one channel had. (Without
# it, everything panned came out 3 dB louder against the voice than the mix intended.)
SIDE_LEVEL = float(np.sqrt(0.5))


@dataclass
class SpatialResult:
    audio: np.ndarray           # (frames, 2) float32
    integrated_lufs: float
    source_lufs: float
    true_peak_db: float
    limiter_max_db: float
    stem_mode: str              # stems6 | stems4 | mix
    tone_db: tuple = ()         # the third-octave tone correction that was applied (diagnostics)


@dataclass
class _Prepared:
    mix: np.ndarray
    sample_rate: int
    stems: list[tuple[str, np.ndarray]]   # (name, (frames, 2) float32) for every stem to place; "mix" when stem-free
    stem_mode: str
    source_lufs: float
    n_fft: int
    mix_spectrum: np.ndarray    # (2, bins)


def _db(power: float) -> float:
    return 10.0 * np.log10(max(power, 1e-20))


def prepare(mix: np.ndarray, stems: dict[str, np.ndarray], sample_rate: int) -> _Prepared:
    mix = np.ascontiguousarray(mix, dtype=np.float32)
    if mix.ndim != 2 or mix.shape[1] != 2:
        raise ValueError("mix must be (frames, 2)")
    if not np.isfinite(mix).all():
        mix = np.nan_to_num(mix, nan=0.0, posinf=0.0, neginf=0.0)
    frames = mix.shape[0]
    mix_power = float(np.mean(mix.astype(np.float64) ** 2)) if frames else 0.0
    usable = {}
    for name in STEM_NAMES:
        stem = stems.get(name)
        if stem is None or np.shape(stem) != mix.shape:
            continue
        stem = np.asarray(stem, dtype=np.float32)
        usable[name] = stem if np.isfinite(stem).all() else np.nan_to_num(stem, nan=0.0, posinf=0.0, neginf=0.0)
    stem_mode = "mix"
    if usable and mix_power > 0.0:
        residual = mix - sum(usable.values())
        if _db(float(np.mean(residual.astype(np.float64) ** 2))) - _db(mix_power) <= BAD_STEMS_DB:
            usable["other"] = usable["other"] + residual if "other" in usable else residual
            stem_mode = "stems6" if ("guitar" in usable or "piano" in usable) else "stems4"
        del residual
    todo: list[tuple[str, np.ndarray]] = []
    if stem_mode == "mix":
        if mix_power > 0.0:
            todo.append(("mix", mix))
    else:
        for name in STEM_NAMES:
            stem = usable.get(name)
            if stem is None:
                continue
            if _db(float(np.mean(stem.astype(np.float64) ** 2))) - _db(mix_power) < SILENT_DB:
                continue
            todo.append((name, stem))
    n_fft = fast_len(frames + 4096)
    spectrum = np.stack([np.fft.rfft(mix[:, c], n_fft) for c in range(2)])
    return _Prepared(mix=mix, sample_rate=sample_rate, stems=todo, stem_mode=stem_mode,
                     source_lufs=integrated_lufs(mix, sample_rate) if frames else -70.0, n_fft=n_fft,
                     mix_spectrum=spectrum)


def _stage_for(profile: Profile, stem: str) -> Stage:
    return profile.mix_stage if stem == "mix" else profile.stage(stem)


def _level(x: np.ndarray, sample_rate: int, amount: float) -> np.ndarray:
    """Night: pull loud and quiet passages towards the song's usual level, slowly (3 s), by at most 3.5 dB."""
    block = sample_rate // 10
    count = x.shape[0] // block
    if count < 40 or amount <= 0.0:
        return x
    power = (x[:count * block].astype(np.float64) ** 2).reshape(count, block, 2).mean(axis=(1, 2))
    window = np.hanning(31)
    window /= window.sum()
    smooth = np.convolve(np.pad(power, 15, mode="edge"), window, mode="valid")
    level_db = 10.0 * np.log10(np.maximum(smooth, 1e-10))
    loud = level_db[level_db > np.percentile(level_db, 20)]
    reference = float(np.median(loud)) if loud.size else float(np.median(level_db))
    gain_db = np.clip(-0.35 * amount * 2.0 * (level_db - reference), -3.5, 3.5)
    # never lift near-silence: the lift fades out between 18 and 30 dB under the usual level (a hard switch here
    # stepped the gain by 3.5 dB inside a fade-out)
    gain_db *= np.clip((level_db - (reference - 30.0)) / 12.0, 0.0, 1.0)
    centres = (np.arange(count) + 0.5) * block
    gain = 10.0 ** (np.interp(np.arange(x.shape[0]), centres, gain_db) / 20.0)
    return (x * gain[:, None]).astype(np.float32)


LONG_SONG_FRAMES = 8 * 60 * 48000   # longer than this: one stem at a time (each one takes a few GB apart)


def _decompositions(stems: list[tuple[str, np.ndarray]], frames: int) -> Iterator[tuple[str, Decomposition]]:
    """Each stem taken apart, in order. Taking a stem apart is FFT work, which NumPy does outside the interpreter
    lock, so the next stem is prepared while the current one is being placed; never more than two at once."""
    workers = 1 if frames > LONG_SONG_FRAMES else 2
    workers = max(1, min(workers, len(stems), (os.cpu_count() or 2) - 1))
    def take_apart(name: str, audio: np.ndarray) -> Decomposition:
        return decompose(audio, **TRANSIENT) if name in ("drums", "mix") else decompose(audio)

    if workers == 1:
        for name, audio in stems:
            yield name, take_apart(name, audio)
        return
    with ThreadPoolExecutor(max_workers=workers) as pool:
        upcoming = iter(stems)
        pending: deque = deque()
        for name, audio in upcoming:
            pending.append((name, pool.submit(take_apart, name, audio)))
            if len(pending) == workers:
                break
        while pending:
            name, future = pending.popleft()
            parts = future.result()
            yield name, parts
            del parts
            following = next(upcoming, None)
            if following is not None:
                pending.append((following[0], pool.submit(take_apart, following[0], following[1])))


def _place(builder: KernelBuilder, profile: Profile, name: str, parts: Decomposition, out_len: int,
           tick: Callable[[], None] | None) -> np.ndarray | None:
    """(out_len, 2) float32: one stem's sources and ambience, each at its place in the profile's room."""
    stage = _stage_for(profile, name)
    gain = 10.0 ** (stage.gain_db / 20.0)
    level = gain * SIDE_LEVEL
    steps = max(1, parts.steps)
    sources: list[np.ndarray] = []
    kernels: list[np.ndarray] = []
    for k, signal in parts.sources.items():
        sources.append(signal)
        if k == 0:
            kernels.append(builder.kernel(0.0, 0.0, stage.dist, level, stage.er, spread=stage.spread,
                                          spread_az=stage.spread_az))
        else:
            share = k / steps
            kernels.append(builder.kernel(share * stage.width, abs(share) * stage.side_el, stage.dist, level, stage.er))
    for signal, az in ((parts.ambience_left, stage.ambience_az), (parts.ambience_right, -stage.ambience_az)):
        if signal is None:
            continue
        sources.append(signal)
        kernels.append(builder.kernel(az, stage.side_el, stage.dist, level, stage.er))
    if not sources:
        return None
    return convolve_bank(sources, np.stack(kernels), out_len, tick)


def _finish(prepared: _Prepared, profile: Profile, builder: KernelBuilder, wet: np.ndarray,
            tick: Callable[[], None] | None = None) -> SpatialResult:
    """Late reverb, the untouched lows, tone, loudness and the limiter, for one profile's placed stems."""
    sr = prepared.sample_rate
    frames = prepared.mix.shape[0]
    head = builder.hrir
    send_left = np.zeros(frames, dtype=np.float32)
    send_right = np.zeros(frames, dtype=np.float32)
    for name, audio in prepared.stems:
        stage = _stage_for(profile, name)
        send = np.float32(10.0 ** (stage.gain_db / 20.0) * stage.rev)
        send_left += send * audio[:, 0]
        send_right += send * audio[:, 1]
    tail = late_tail(profile.room, head, profile.seed, builder.front_energy)
    wet += convolve_bank([send_left, send_right], tail, wet.shape[0], tick)
    del send_left, send_right
    wet = wet[head.front_delay:]  # undo the head model's own delay: the render keeps the source's timeline

    n_fft = prepared.n_fft
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)
    low = 1.0 / (1.0 + (freqs / profile.crossover_hz) ** 4)
    high = 1.0 - low
    spectrum = np.empty_like(prepared.mix_spectrum)
    for c in range(2):
        spectrum[c] = high * np.fft.rfft(wet[:, c], n_fft) + low * prepared.mix_spectrum[c]
    del wet

    # tone: match the original's long-term spectrum in third-octave bands
    power_mix = (np.abs(prepared.mix_spectrum) ** 2).sum(axis=0)
    power_out = (np.abs(spectrum) ** 2).sum(axis=0)
    centres, ratio = smooth_bands(freqs, power_mix, power_out, lo=80.0, hi=min(16000.0, 0.45 * sr))
    del power_mix, power_out
    limit_lin = 10.0 ** (TONE_LIMIT_DB / 20.0)
    correction = np.clip(np.sqrt(ratio), 1.0 / limit_lin, limit_lin)
    centres = np.concatenate([[30.0], centres])
    correction = np.concatenate([[1.0], correction])
    tone = interp_log(freqs, centres, correction)
    if profile.shelf_db:
        shelf = 10.0 ** (profile.shelf_db / 20.0)
        share = (freqs / 7000.0) ** 2 / (1.0 + (freqs / 7000.0) ** 2)
        tone = tone * (1.0 + (shelf - 1.0) * share)
    audio = np.stack([np.fft.irfft(spectrum[c] * tone, n_fft)[:frames] for c in range(2)], axis=1).astype(np.float32)
    del spectrum

    if profile.leveler > 0.0:
        audio = _level(audio, sr, profile.leveler)

    # loudness: HEADROOM_DB under the source's integrated loudness, the same offset for every song and profile
    loudness = integrated_lufs(audio, sr)
    if loudness > -69.0 and prepared.source_lufs > -69.0:
        audio *= np.float32(10.0 ** (np.clip(prepared.source_lufs - HEADROOM_DB - loudness, -16.0, 12.0) / 20.0))
    audio, reduction = limit(audio, sr, CEILING_DB)
    fade = min(frames, int(0.01 * sr))
    if fade:
        audio[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)[:, None]
    np.clip(audio, -1.0, 1.0, out=audio)
    return SpatialResult(audio=audio, integrated_lufs=integrated_lufs(audio, sr), source_lufs=prepared.source_lufs,
                         true_peak_db=true_peak_db(audio), limiter_max_db=reduction, stem_mode=prepared.stem_mode,
                         tone_db=tuple(round(float(v), 2) for v in 20.0 * np.log10(correction[1:])))



def render_one(prepared: _Prepared, profile: Profile, tick: Callable[[], None] | None = None) -> SpatialResult:
    """One profile (kept for callers that render profiles one by one; render_profiles shares the work)."""
    frames = prepared.mix.shape[0]
    if frames == 0 or not prepared.stems:
        return _silent(prepared)
    head = hrir_mod.load(prepared.sample_rate)
    builder = KernelBuilder(head, profile.room, profile.mix_stage.dist)
    wet = np.zeros((frames + head.front_delay, 2), dtype=np.float32)
    for name, parts in _decompositions(prepared.stems, frames):
        placed = _place(builder, profile, name, parts, wet.shape[0], tick)
        if placed is not None:
            wet += placed
    return _finish(prepared, profile, builder, wet, tick)


def _silent(prepared: _Prepared) -> SpatialResult:
    frames = prepared.mix.shape[0]
    return SpatialResult(audio=np.zeros((frames, 2), np.float32), integrated_lufs=-70.0,
                         source_lufs=prepared.source_lufs, true_peak_db=-180.0, limiter_max_db=0.0,
                         stem_mode=prepared.stem_mode)


def render_profiles(mix: np.ndarray, stems: dict[str, np.ndarray], sample_rate: int, profiles: Iterable[str],
                    progress: Callable[[int, int], None] | None = None) -> dict[str, SpatialResult]:
    """See docs/handoff/2026-11-10-plans/cloud-audio-spec.md, section 5."""
    wanted = list(profiles)
    for profile_id in wanted:
        if profile_id not in PROFILES:
            raise ValueError(f"unknown profile {profile_id}")
    if sample_rate not in hrir_mod.SUPPORTED_RATES:
        raise ValueError(f"the renderer works at {hrir_mod.SUPPORTED_RATES} Hz")
    prepared = prepare(mix, stems, sample_rate)
    total = 2 + 10 * len(prepared.stems) + 10 * len(wanted)
    state = {"done": 0}

    def step(count: int = 0) -> None:
        state["done"] = min(total, state["done"] + count)
        if progress is not None:
            progress(state["done"], total)   # count 0: a heartbeat (the worker checks its deadline on every call)

    step(2)
    frames = prepared.mix.shape[0]
    if frames == 0 or not prepared.stems:
        return {profile_id: _silent(prepared) for profile_id in wanted}
    head = hrir_mod.load(sample_rate)
    builders = {profile_id: KernelBuilder(head, PROFILES[profile_id].room, PROFILES[profile_id].mix_stage.dist)
                for profile_id in wanted}
    wets = {profile_id: np.zeros((frames + head.front_delay, 2), dtype=np.float32) for profile_id in wanted}
    for name, parts in _decompositions(prepared.stems, frames):
        for profile_id in wanted:
            placed = _place(builders[profile_id], PROFILES[profile_id], name, parts, frames + head.front_delay, step)
            if placed is not None:
                wets[profile_id] += placed
            del placed
        del parts
        step(10)
    results: dict[str, SpatialResult] = {}
    for profile_id in wanted:
        results[profile_id] = _finish(prepared, PROFILES[profile_id], builders[profile_id], wets.pop(profile_id), step)
        step(10)
    return results
