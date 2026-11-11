"""The on-device spatial stage: its coefficient tables and a reference implementation (spec section 7).

A phone cannot separate stems in real time, so until the cloud render arrives it plays the plain stereo song
through two virtual speakers (plus, for the wider profiles, the side signal on a second pair) and a short sparse
room. Everything a phone needs is a few hundred numbers per profile and sample rate, written by this module from
the same head model and profile table the cloud renderer uses:

    python -m pixl_worker.spatial.preview --out schema/v1/spatial

writes spatial_preview_v1.json (the tables; both apps ship it as an asset) and spatial_preview_golden_v1.json
(a fixed input and this module's output for it; both apps' unit tests must reproduce it within 1e-4).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from . import hrir as hrir_mod
from .dsp import min_phase_spectrum
from .loudness import k_weight_power
from .profiles import ENGINE_ID, PROFILES, Profile
from .render import HEADROOM_DB
from .room import KernelBuilder

TAPS = 192
CROSSOVER_HZ = 120.0
SPARSE_TAPS = 40
INPUT_CORRELATION = 0.75  # how alike left and right are in a typical mix (for tone and loudness matching)
GOLDEN_FRAMES = 1024
RATES = (44100, 48000)


def lowpass_coefficients(sample_rate: int, cutoff_hz: float) -> tuple[float, float, float, float, float]:
    """RBJ low-pass biquad, Q = 1/sqrt(2), as (b0, b1, b2, a1, a2) with a0 = 1. Two in series are the crossover."""
    w0 = 2.0 * np.pi * cutoff_hz / sample_rate
    alpha = np.sin(w0) / (2.0 * (1.0 / np.sqrt(2.0)))
    cos0 = np.cos(w0)
    a0 = 1.0 + alpha
    return ((1.0 - cos0) / 2.0 / a0, (1.0 - cos0) / a0, (1.0 - cos0) / 2.0 / a0, -2.0 * cos0 / a0, (1.0 - alpha) / a0)


def _lowpass_response(freqs: np.ndarray, sample_rate: int, cutoff_hz: float) -> np.ndarray:
    b0, b1, b2, a1, a2 = lowpass_coefficients(sample_rate, cutoff_hz)
    z1 = np.exp(-2j * np.pi * freqs / sample_rate)
    one = (b0 + b1 * z1 + b2 * z1 * z1) / (1.0 + a1 * z1 + a2 * z1 * z1)
    return one * one


def _third_octave(freqs: np.ndarray, power: np.ndarray) -> np.ndarray:
    ratio = 2.0 ** (1.0 / 6.0)
    bins = np.arange(len(freqs))
    lo = np.floor(bins / ratio).astype(int)
    hi = np.minimum(np.ceil(bins * ratio).astype(int) + 1, len(bins))
    total = np.concatenate([[0.0], np.cumsum(power)])
    return (total[hi] - total[lo]) / np.maximum(hi - lo, 1)


def build_table(profile: Profile, sample_rate: int) -> dict:
    spec = profile.preview
    head = hrir_mod.load(sample_rate)
    builder = KernelBuilder(head, profile.room, profile.mix_stage.dist)
    n_fft = builder.n_fft
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sample_rate)

    def pair(theta: float) -> tuple[np.ndarray, np.ndarray]:
        """(same side, other side) spectra for a source at +theta, as loud as a frontal one."""
        direct = builder.direct(theta, 0.0)
        return direct[0], direct[1]

    same, cross = pair(spec.theta)
    if spec.side_gain > 0.0:
        side_same, side_cross = pair(spec.side_theta)
        rear = 0.5 * spec.side_gain * (side_same - side_cross)
        same, cross = same + rear, cross - rear
    delay = int(np.argmax(np.abs(np.fft.irfft(same, n_fft))))
    shift = np.exp(-2j * np.pi * np.arange(len(freqs)) * delay / n_fft)
    same = (1.0 - spec.dry) * same + spec.dry * shift
    cross = (1.0 - spec.dry) * cross

    # tone: flat for a typical mix (left and right partly alike), by a smooth minimum-phase correction
    power = np.abs(same) ** 2 + np.abs(cross) ** 2 + 2.0 * INPUT_CORRELATION * (same * np.conj(cross)).real
    smooth = _third_octave(freqs, power)
    band = (freqs >= 200.0) & (freqs <= 6000.0)
    correction = np.clip(np.sqrt(smooth[band].mean() / np.maximum(smooth, 1e-12)), 10 ** (-6 / 20), 10 ** (6 / 20))
    correction[freqs < 150.0] = correction[np.searchsorted(freqs, 150.0)]
    if profile.shelf_db:
        shelf = 10.0 ** (profile.shelf_db / 20.0)
        share = (freqs / 7000.0) ** 2 / (1.0 + (freqs / 7000.0) ** 2)
        correction = correction * (1.0 + (shelf - 1.0) * share)
    tone = min_phase_spectrum(correction, n_fft)
    fade = np.ones(TAPS)
    fade[TAPS - 24:] = 0.5 * (1.0 + np.cos(np.linspace(0.0, np.pi, 24)))
    direct_taps = np.fft.irfft(same * tone, n_fft)[:TAPS] * fade
    cross_taps = np.fft.irfft(cross * tone, n_fft)[:TAPS] * fade
    low_delay = int(np.argmax(np.abs(direct_taps)))

    # the sparse room: a few dozen decaying taps per ear, different for each ear so it surrounds
    rng = np.random.default_rng(profile.seed + sample_rate)
    wet = 10.0 ** (spec.wet_db / 10.0)
    sparse = []
    for _ear in range(2):
        edges = np.linspace(spec.start_ms, spec.end_ms, SPARSE_TAPS + 1) * sample_rate / 1000.0
        delays = np.unique(np.round(rng.uniform(edges[:-1], edges[1:])).astype(int))
        times = (delays - delays[0]) / sample_rate
        envelope = np.exp(-6.9078 * times / spec.rt60)
        angle = rng.uniform(0.0, 2.0 * np.pi, len(delays))
        gains = np.stack([np.cos(angle), np.sin(angle)], axis=1) * envelope[:, None]
        gains *= np.sqrt(wet / np.sum(gains ** 2))
        sparse.append([[int(d), round(float(g[0]), 6), round(float(g[1]), 6)] for d, g in zip(delays, gains)])

    # level: as loud as the untouched signal for a typical mix, minus the renderer's headroom
    grid = np.fft.rfftfreq(1 << 15, 1.0 / sample_rate)
    low = _lowpass_response(grid, sample_rate, CROSSOVER_HZ)
    high = 1.0 - low
    d_spec = np.fft.rfft(direct_taps, 1 << 15)
    x_spec = np.fft.rfft(cross_taps, 1 << 15)
    h_same = high * d_spec + low * np.exp(-2j * np.pi * grid * low_delay / sample_rate)
    h_cross = high * x_spec
    out_power = np.abs(h_same) ** 2 + np.abs(h_cross) ** 2 \
        + 2.0 * INPUT_CORRELATION * (h_same * np.conj(h_cross)).real + wet * np.abs(high) ** 2
    weight = k_weight_power(grid, sample_rate) / np.maximum(grid, 20.0)
    weight[(grid < 40.0) | (grid > 16000.0)] = 0.0
    gain = float(np.sqrt(weight.sum() / (weight * out_power).sum()) * 10.0 ** (-HEADROOM_DB / 20.0))

    return {
        "xoverHz": CROSSOVER_HZ, "lowDelay": low_delay, "taps": TAPS,
        "direct": [round(float(v), 7) for v in direct_taps],
        "cross": [round(float(v), 7) for v in cross_taps],
        "sparseL": sparse[0], "sparseR": sparse[1],
        "gain": round(gain, 6),
    }


def build_tables() -> dict:
    return {
        "schema": "pixl.spatial.preview", "v": 1, "engine": ENGINE_ID, "headroomDb": HEADROOM_DB,
        "profiles": {profile.id: {str(rate): build_table(profile, rate) for rate in RATES}
                     for profile in PROFILES.values()},
    }


def process(x: np.ndarray, table: dict, sample_rate: int) -> np.ndarray:
    """The reference on-device stage. x (frames, 2) float -> (frames, 2) float64, from a zero state."""
    x = np.asarray(x, dtype=np.float64)
    frames = x.shape[0]
    b0, b1, b2, a1, a2 = lowpass_coefficients(sample_rate, table["xoverHz"])
    low = x.copy()
    for _ in range(2):
        out = np.zeros_like(low)
        for c in range(2):
            x1 = x2 = y1 = y2 = 0.0
            for n in range(frames):
                x0 = low[n, c]
                y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2, x1, y2, y1 = x1, x0, y1, y0
                out[n, c] = y0
        low = out
    high = x - low
    direct = np.asarray(table["direct"], dtype=np.float64)
    cross = np.asarray(table["cross"], dtype=np.float64)
    y = np.zeros_like(x)
    y[:, 0] = np.convolve(high[:, 0], direct)[:frames] + np.convolve(high[:, 1], cross)[:frames]
    y[:, 1] = np.convolve(high[:, 1], direct)[:frames] + np.convolve(high[:, 0], cross)[:frames]
    for ear, key in enumerate(("sparseL", "sparseR")):
        for delay, from_left, from_right in table[key]:
            if delay < frames:
                y[delay:, ear] += from_left * high[:frames - delay, 0] + from_right * high[:frames - delay, 1]
    delayed = np.zeros_like(low)
    shift = int(table["lowDelay"])
    delayed[shift:] = low[:frames - shift]
    return table["gain"] * (y + delayed)


def golden_input() -> np.ndarray:
    """An impulse on the left at frame 0, one on the right at frame 300, and seeded noise from frame 600."""
    x = np.zeros((GOLDEN_FRAMES, 2))
    x[0, 0] = 0.5
    x[300, 1] = 0.5
    rng = np.random.default_rng(20261110)
    x[600:] = np.round(rng.uniform(-0.25, 0.25, (GOLDEN_FRAMES - 600, 2)), 6)
    return x


def build_golden(tables: dict) -> dict:
    x = golden_input()
    outputs: dict = {}
    for profile, rates in tables["profiles"].items():
        outputs[profile] = {}
        for rate, table in rates.items():
            y = process(x, table, int(rate))
            outputs[profile][rate] = {"left": [round(float(v), 7) for v in y[:, 0]],
                                      "right": [round(float(v), 7) for v in y[:, 1]]}
    return {"schema": "pixl.spatial.preview.golden", "v": 1, "frames": GOLDEN_FRAMES, "tolerance": 1e-4,
            "input": {"left": [float(v) for v in x[:, 0]], "right": [float(v) for v in x[:, 1]]},
            "output": outputs}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tables = build_tables()
    # newline="\n": the apps carry byte-identical copies, so the files must not depend on who wrote them
    for name, doc in (("spatial_preview_v1.json", tables), ("spatial_preview_golden_v1.json", build_golden(tables))):
        with open(out / name, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(doc, separators=(",", ":")) + "\n")
    for profile, rates in tables["profiles"].items():
        for rate, table in rates.items():
            print(f"{profile:9s} {rate}: gain {table['gain']:.3f} lowDelay {table['lowDelay']} "
                  f"sparse {len(table['sparseL'])}+{len(table['sparseR'])} max delay "
                  f"{max(t[0] for t in table['sparseL'] + table['sparseR'])}")


if __name__ == "__main__":
    main()
