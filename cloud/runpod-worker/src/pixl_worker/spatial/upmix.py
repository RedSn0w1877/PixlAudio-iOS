"""Stereo -> centre + left + right, so a part panned to the middle can be placed in the middle.

Two virtual speakers far apart make a bad phantom centre over headphones (a hollow, phasey notch), so each stem
is first split in three: whatever both channels share goes to a real centre source, and only what is left stays
on the sides. And the split has to be thorough: if a third of a centred voice is left behind in the side signals,
that third arrives from the side positions a fraction of a millisecond off and cancels the voice around 5 kHz
(measured: a 4 dB hole before this was fixed).

Per time-frequency bin the stem is modelled as ONE panned source plus equal uncorrelated ambience in the two
channels. From the smoothed channel powers and their correlation that gives, in closed form,
- the ambience power N (the smaller eigenvalue of the 2x2 covariance),
- the source's power in each channel (what is left), hence how far it is panned,
and the centre is  C = kappa * (L + R)  with  kappa = [min(a, b) / (a + b)] * [S / (S + N / 4)] :
the first factor is the classic re-panning rule (Vickers 2009: a dead-centre source moves to the centre completely,
a hard-panned one stays put, and nothing is ever left with inverted polarity), computed from the SOURCE's powers,
so stereo reverb around a centred voice does not make it look panned and the voice still goes to the centre
whole; the second only closes the gate where there is no source to speak of (S is the source's power in L + R),
so a reverb tail on its own stays wide instead of collapsing into the middle.
The statistics are averaged over about 0.2 s and a few bins, so kappa moves slowly and there is
no musical noise; and because the sides are simply L - C and R - C, the three always add back to the input
exactly, whatever the estimate did.
"""

from __future__ import annotations

import numpy as np

from .dsp import istft, stft

N_FFT = 4096
HOP = 1024
SMOOTH_FRAMES = 9
NEAR_CENTRE = 0.18   # as a share of (a + b): about +/- 1.6 dB between the channels


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
    """Moving average over 5 bins (axis 1), edges held."""
    padded = np.concatenate([values[:, :1], values[:, :1], values, values[:, -1:], values[:, -1:]], axis=1)
    return (padded[:, :-4] + padded[:, 1:-3] + padded[:, 2:-2] + padded[:, 3:-1] + padded[:, 4:]) / 5.0


def centre_gain(p_ll: np.ndarray, p_rr: np.ndarray, cross: np.ndarray) -> np.ndarray:
    """kappa (see the module note) from the smoothed channel powers and the real part of their cross-spectrum."""
    in_phase = np.maximum(cross, 0.0)
    total = p_ll + p_rr
    ambience = 0.5 * (total - np.sqrt((p_ll - p_rr) ** 2 + 4.0 * in_phase ** 2))
    ambience = np.clip(ambience, 0.0, np.minimum(p_ll, p_rr))
    left = np.sqrt(np.maximum(p_ll - ambience, 0.0))
    right = np.sqrt(np.maximum(p_rr - ambience, 0.0))
    both = left + right
    # 2 * min / (a + b) = 1 - |a - b| / (a + b). Measured powers always differ a little, which would leave a few
    # percent of every centred source on the sides, so anything within NEAR_CENTRE of the middle counts as centred.
    offset = np.abs(left - right) / (both + 1e-12)
    repan = 0.5 * np.clip((1.0 - offset) / (1.0 - NEAR_CENTRE), 0.0, 1.0)
    source = both * both
    gate = source / (source + 0.25 * ambience + 1e-20)
    return (repan * gate).astype(np.float32)


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
    p_ll, p_rr, cross = (_smooth_freq(_smooth_time(p, SMOOTH_FRAMES)) for p in (p_ll, p_rr, cross))
    kappa = centre_gain(p_ll, p_rr, cross) * float(min(1.0, strength))
    del p_ll, p_rr, cross
    centre = istft((spec_l + spec_r) * kappa, N_FFT, HOP, frames)
    return centre, (left - centre).astype(np.float32), (right - centre).astype(np.float32)
