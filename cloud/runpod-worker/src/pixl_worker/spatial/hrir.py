"""The dummy-head impulse responses (SADIE II D1, Neumann KU100; see tools/build_hrir.py and NOTICE).

Azimuth is in degrees, 0 = straight ahead, positive = to the listener's LEFT; elevation positive = up.
`pair()` returns the response at the left ear and at the right ear for a source in that direction.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import numpy as np

DATA = Path(__file__).resolve().parent / "data" / "hrir_ku100.npz"
SUPPORTED_RATES = (44100, 48000)


def unit(az_deg, el_deg) -> np.ndarray:
    az, el = np.radians(az_deg), np.radians(el_deg)
    return np.stack([np.cos(el) * np.cos(az), np.cos(el) * np.sin(az), np.sin(el)], axis=-1)


class HrirSet:
    def __init__(self, ir: np.ndarray, az: np.ndarray, el: np.ndarray, sample_rate: int):
        self.ir = np.ascontiguousarray(ir, dtype=np.float32)  # (M, 2, taps)
        self.az, self.el = az.astype(np.float64), el.astype(np.float64)
        self.sample_rate = sample_rate
        self.taps = self.ir.shape[2]
        self._units = unit(self.az, self.el)
        front = self.ir[self.index(0.0, 0.0)]
        # where the frontal response peaks: the delay everything that bypasses the head model gets
        self.front_delay = int(np.argmax(np.abs(front[0])))
        self.front_energy = float(np.mean(np.sum(front.astype(np.float64) ** 2, axis=1)))

    def index(self, az: float, el: float) -> int:
        return int(np.argmax(self._units @ unit(az, el)))

    def pair(self, az: float, el: float = 0.0) -> np.ndarray:
        """(2, taps): row 0 the left ear, row 1 the right ear."""
        return self.ir[self.index(az, el)]

    def energy(self, az: float, el: float = 0.0) -> float:
        pair = self.pair(az, el).astype(np.float64)
        return float(np.mean(np.sum(pair ** 2, axis=1)))

    def diffuse_coherence(self, freqs: np.ndarray) -> np.ndarray:
        """How alike the two ears' signals are, per frequency, when sound arrives equally from every direction:
        the real part of the average of H_left * conj(H_right) over the sphere, over the average power. It is 1 at
        the lowest frequencies and falls to about zero by 500 Hz for this head (a sphere model would still say 0.6
        there). The late reverb is built to this curve."""
        n_fft = 1024
        spec = np.fft.rfft(self.ir.astype(np.float64), n_fft, axis=-1)          # (M, 2, bins)
        rings = np.round(self.el).astype(int)
        weight = np.cos(np.radians(self.el))
        for ring in np.unique(rings):
            members = rings == ring
            weight[members] *= 1.0 / max(1, int(members.sum()))                # each ring counts once, by its area
        weight = np.maximum(weight, 1e-3)
        cross = np.tensordot(weight, (spec[:, 0] * np.conj(spec[:, 1])).real, axes=1)
        power = np.sqrt(np.tensordot(weight, np.abs(spec[:, 0]) ** 2, axes=1)
                        * np.tensordot(weight, np.abs(spec[:, 1]) ** 2, axes=1))
        curve = cross / np.maximum(power, 1e-20)
        grid = np.fft.rfftfreq(n_fft, 1.0 / self.sample_rate)
        return np.clip(np.interp(freqs, grid, curve), -1.0, 1.0)


@lru_cache(maxsize=2)
def load(sample_rate: int) -> HrirSet:
    if sample_rate not in SUPPORTED_RATES:
        raise ValueError(f"the head model supports {SUPPORTED_RATES} Hz, not {sample_rate}")
    with np.load(DATA) as data:
        ir = data["ir"].astype(np.float64) * float(data["scale"])
        az, el, fs = data["az"], data["el"], int(data["fs"])
    if sample_rate != fs:
        ir = _resample(ir, fs, sample_rate)
    return HrirSet(ir, az, el, sample_rate)


def _resample(ir: np.ndarray, sr_from: int, sr_to: int) -> np.ndarray:
    """Band-limited resampling of the short responses, exact for 48000 -> 44100 (640 -> 588 samples)."""
    assert (sr_from, sr_to) == (48000, 44100)
    n_in, n_out = 640, 588
    spec = np.fft.rfft(ir, n_in, axis=-1)[..., :n_out // 2 + 1]
    spec[..., -1] *= 0.5
    # The kept bins ARE the response at the new rate's bin frequencies (both grids are 75 Hz apart), so the inverse
    # transform needs no extra scale: the filter keeps its gain.
    out = np.fft.irfft(spec, n_out, axis=-1)
    taps = 240
    out = out[..., :taps].copy()
    out[..., taps - 32:] *= 0.5 * (1.0 + np.cos(np.linspace(0.0, np.pi, 32)))
    return out
