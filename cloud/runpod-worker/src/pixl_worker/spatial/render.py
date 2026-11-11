"""The spatial renderer: stems in, one binaural stereo file per profile out.

For each profile:
1. every stem is split into centre / left / right (upmix.py) and each part becomes a source at its own place in
   the profile's room: direct sound through the head model, plus early reflections (room.py);
2. a stereo send of all stems feeds the room's late reverb;
3. below the crossover (110 Hz) the ORIGINAL mix passes straight through, time-aligned, so bass and kick keep
   their weight and punch, and a share of the untouched mix is blended back above it;
4. the result is matched to the original: its long-term tone (third-octave, at most +/- 5 dB), then its loudness
   (BS.1770), and a true-peak limiter that is idle unless a peak goes over -1 dBTP.

Everything is deterministic (fixed seeds), NumPy only, and the output has exactly the input's length and
timeline.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterable

import numpy as np

from . import hrir as hrir_mod
from .dsp import convolve_bank, fast_len, interp_log, smooth_bands
from .loudness import integrated_lufs, limit, true_peak_db
from .profiles import PROFILES, STEM_NAMES, Profile, Stage
from .room import KernelBuilder, late_tail
from .upmix import split_center

CEILING_DB = -1.0
# A binaural render of a loud modern master peaks 3-5 dB higher than the master at the same loudness (the head
# model and the room undo the phase alignment its limiter relied on). Rather than squash that back, every render
# sits this far under the source's loudness; the on-device stage does the same, so the two match, and the apps
# give the level back whenever their own volume gain has the room (spec 6.3).
HEADROOM_DB = 4.0
TONE_LIMIT_DB = 5.0
BAD_STEMS_DB = -6.0     # stems that miss the mix by more than this are not trusted
SILENT_DB = -70.0


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
class _Part:
    stem: str
    centre: np.ndarray
    left: np.ndarray
    right: np.ndarray


@dataclass
class _Prepared:
    mix: np.ndarray
    sample_rate: int
    parts: list[_Part]
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
    frames = mix.shape[0]
    mix_power = float(np.mean(mix.astype(np.float64) ** 2))
    usable = {name: np.asarray(stems[name], dtype=np.float32) for name in STEM_NAMES
              if name in stems and stems[name] is not None and np.shape(stems[name]) == mix.shape}
    stem_mode = "mix"
    if usable and mix_power > 0.0:
        residual = mix - sum(usable.values())
        if _db(float(np.mean(residual.astype(np.float64) ** 2))) - _db(mix_power) <= BAD_STEMS_DB:
            usable["other"] = usable["other"] + residual if "other" in usable else residual
            stem_mode = "stems6" if ("guitar" in usable or "piano" in usable) else "stems4"
        del residual
    parts: list[_Part] = []
    if stem_mode == "mix":
        parts.append(_Part("mix", *split_center(mix)))
    else:
        for name in STEM_NAMES:
            stem = usable.get(name)
            if stem is None:
                continue
            if _db(float(np.mean(stem.astype(np.float64) ** 2))) - _db(mix_power) < SILENT_DB:
                continue
            parts.append(_Part(name, *split_center(stem)))
    n_fft = fast_len(frames + 4096)
    spectrum = np.stack([np.fft.rfft(mix[:, c], n_fft) for c in range(2)])
    return _Prepared(mix=mix, sample_rate=sample_rate, parts=parts, stem_mode=stem_mode,
                     source_lufs=integrated_lufs(mix, sample_rate), n_fft=n_fft, mix_spectrum=spectrum)


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
    gain_db[level_db < reference - 25.0] = 0.0  # never lift near-silence
    centres = (np.arange(count) + 0.5) * block
    gain = 10.0 ** (np.interp(np.arange(x.shape[0]), centres, gain_db) / 20.0)
    return (x * gain[:, None]).astype(np.float32)


def render_one(prepared: _Prepared, profile: Profile, tick: Callable[[], None] | None = None) -> SpatialResult:
    sr = prepared.sample_rate
    frames = prepared.mix.shape[0]
    head = hrir_mod.load(sr)
    builder = KernelBuilder(head, profile.room, profile.mix_stage.dist)

    sources: list[np.ndarray] = []
    kernels: list[np.ndarray] = []
    send_left = np.zeros(frames, dtype=np.float32)
    send_right = np.zeros(frames, dtype=np.float32)
    for part in prepared.parts:
        stage = _stage_for(profile, part.stem)
        gain = 10.0 ** (stage.gain_db / 20.0)
        centre, left, right = part.centre, part.left, part.right
        if stage.center < 1.0:  # leave some of the centred content on the sides
            keep = (1.0 - stage.center) * centre
            centre, left, right = stage.center * centre, left + keep, right + keep
        for signal, az, el in ((centre, 0.0, stage.center_el), (left, stage.width, stage.side_el),
                               (right, -stage.width, stage.side_el)):
            if not np.any(signal):
                continue
            sources.append(signal)
            kernels.append(builder.kernel(az, el, stage.dist, gain, stage.er))
        send = gain * stage.rev
        send_left += send * (part.centre + part.left)
        send_right += send * (part.centre + part.right)

    out_len = frames + head.front_delay
    wet = convolve_bank(sources, np.stack(kernels), out_len, tick) if sources else np.zeros((out_len, 2), np.float32)
    tail = late_tail(profile.room, sr, profile.seed, builder.front_energy)
    wet += convolve_bank([send_left, send_right], tail, out_len, tick)
    del sources, kernels, send_left, send_right
    wet = wet[head.front_delay:]  # undo the head model's own delay: the render keeps the source's timeline

    n_fft = prepared.n_fft
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)
    low = 1.0 / (1.0 + (freqs / profile.crossover_hz) ** 4)
    high = 1.0 - low
    dry = profile.dry
    spectrum = np.empty_like(prepared.mix_spectrum)
    for c in range(2):
        spectrum[c] = (1.0 - dry) * high * np.fft.rfft(wet[:, c], n_fft) \
            + (dry * high + low) * prepared.mix_spectrum[c]
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


def render_profiles(mix: np.ndarray, stems: dict[str, np.ndarray], sample_rate: int, profiles: Iterable[str],
                    progress: Callable[[int, int], None] | None = None) -> dict[str, SpatialResult]:
    """See docs/handoff/2026-11-10-plans/cloud-audio-spec.md, section 5."""
    wanted = list(profiles)
    for profile_id in wanted:
        if profile_id not in PROFILES:
            raise ValueError(f"unknown profile {profile_id}")
    if sample_rate not in hrir_mod.SUPPORTED_RATES:
        raise ValueError(f"the renderer works at {hrir_mod.SUPPORTED_RATES} Hz")
    total = 2 + 10 * len(wanted)
    state = {"done": 0}

    def step(count: int = 1) -> None:
        state["done"] = min(total, state["done"] + count)
        if progress is not None:
            progress(state["done"], total)

    prepared = prepare(mix, stems, sample_rate)
    step(2)
    results: dict[str, SpatialResult] = {}
    for profile_id in wanted:
        results[profile_id] = render_one(prepared, PROFILES[profile_id])
        step(10)
    return results
