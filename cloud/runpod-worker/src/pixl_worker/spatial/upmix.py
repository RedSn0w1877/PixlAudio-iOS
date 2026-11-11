"""Stereo -> centre + left + right, so a part panned to the middle can be placed in the middle.

Two virtual speakers far apart make a bad phantom centre over headphones (a hollow, phasey notch around 1 kHz).
So each stem is first split in three: whatever both channels share goes to a real centre source, and only what is
left stays on the sides. The split is the classic frequency-domain one (Vickers 2009): per time-frequency bin the
centre is alpha * (L + R), with alpha chosen so that a part panned dead centre moves there completely and a part
panned hard to one side stays put. The statistics are smoothed over ~0.15 s and 3 bins, so alpha moves slowly and
there is no musical noise; and because the sides are simply L - C and R - C, the three always add back to the
input exactly, whatever the mask did.
"""

from __future__ import annotations

import numpy as np

from .dsp import istft, stft

N_FFT = 4096
HOP = 1024


def _smooth_time(values: np.ndarray, frames: int) -> np.ndarray:
    """Centred moving average over `frames` STFT frames (axis 0), edges held."""
    if frames <= 1:
        return values
    pad = frames // 2
    padded = np.concatenate([np.repeat(values[:1], pad, axis=0), values, np.repeat(values[-1:], pad, axis=0)])
    total = np.cumsum(padded, axis=0, dtype=np.float64)
    total = np.concatenate([np.zeros((1,) + values.shape[1:]), total])
    return ((total[frames:] - total[:-frames]) / frames).astype(np.float32)[:values.shape[0]]


def _smooth_freq(values: np.ndarray) -> np.ndarray:
    out = values.copy()
    out[:, 1:-1] = (values[:, :-2] + values[:, 1:-1] + values[:, 2:]) / 3.0
    return out


def split_center(x: np.ndarray, strength: float = 1.0) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """x (frames, 2) float32 -> (centre, left_rest, right_rest), each (frames,) float32, with
    centre + left_rest == x[:, 0] and centre + right_rest == x[:, 1]."""
    frames = x.shape[0]
    left, right = x[:, 0], x[:, 1]
    if strength <= 0.0 or frames < N_FFT or not np.any(x):
        return np.zeros(frames, np.float32), left.astype(np.float32), right.astype(np.float32)
    spec_l, spec_r = stft(left, N_FFT, HOP), stft(right, N_FFT, HOP)
    p_ll = np.abs(spec_l) ** 2
    p_rr = np.abs(spec_r) ** 2
    cross = (spec_l * np.conj(spec_r)).real
    p_ll, p_rr, cross = (_smooth_freq(_smooth_time(p, 5)) for p in (p_ll, p_rr, cross))
    total = p_ll + p_rr
    difference = np.maximum(total - 2.0 * cross, 0.0)   # |L - R|^2
    summed = np.maximum(total + 2.0 * cross, 0.0)       # |L + R|^2
    alpha = 0.5 * (1.0 - np.sqrt(difference / (summed + 1e-12)))
    alpha = np.clip(alpha, 0.0, 0.5) * float(min(1.0, strength))
    del p_ll, p_rr, cross, total, difference, summed
    centre = istft((spec_l + spec_r) * alpha, N_FFT, HOP, frames)
    return centre, (left - centre).astype(np.float32), (right - centre).astype(np.float32)
