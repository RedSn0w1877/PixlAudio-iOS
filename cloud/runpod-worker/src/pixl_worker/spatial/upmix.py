"""Stereo -> sources with a direction, plus ambience.

A stem is stereo: some of it is a source panned somewhere between the channels, some of it is ambience (reverb,
wide pads) that the two channels do not share. To place a stem in a room, each source has to become ONE source at
ONE angle. Sharing a source between two positions (a centre and a side, say) does not work over headphones: the
two copies reach an ear a fraction of a millisecond apart and cancel around 4-5 kHz (measured: up to 9 dB out of a
third octave, and the level difference between the ears even flips sign there, so the image jumps to the wrong
side in that band).

So, per time-frequency bin, the stem is modelled as one panned source plus equal, uncorrelated ambience in the two
channels. From the smoothed channel powers and their correlation that gives in closed form
- the ambience power N: the smaller eigenvalue of the 2x2 covariance;
- the source's power in each channel (what is left), so how far it is panned and which way;
- the source itself: the projection of (L, R) on that direction, as one mono signal with the power it had in both
  channels together.
The source goes, whole, to the nearest of DIRECTIONS angles between hard left and hard right (anything within
NEAR_CENTRE of the middle counts as centred: measured powers always differ a little); what the two channels do not
share stays behind as a left and a right ambience signal.

Details that were measured rather than guessed:
- the statistics are averaged over 9 frames (0.2 s) and a third of an octave (at least 5 bins). With a narrow
  average the gains change quickly from bin to bin, which smears drum attacks backwards in time (pre-echo);
- a share of sqrt(P_L * P_R) is taken off the correlation first, because two unrelated signals never measure as
  exactly unrelated, and that leftover would pull a reverb tail into the centre;
- a gate closes the source path where there is hardly any source (it is all ambience there).
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .dsp import istft, stft

N_FFT = 4096
HOP = 1024
SMOOTH_FRAMES = 9
NEAR_CENTRE = 0.18   # as a share of (a + b): about +/- 1.6 dB between the channels
DIRECTIONS = 7       # angles a source can go to, hard left ... centre ... hard right (odd)
CORRELATION_FLOOR = 0.2
NEGLIGIBLE = 3e-4    # a direction or an ambience signal with less than this share of the stem's power (-35 dB)


@dataclass
class Decomposition:
    """What one stem is made of. `sources[k]` is the mono signal of everything placed at step k, for k from
    -(DIRECTIONS // 2) (hard right) to +(DIRECTIONS // 2) (hard left); a source has the power it had in both
    channels together, so a centred one is sqrt(2) times its level in either channel. Missing keys are silent."""
    sources: dict[int, np.ndarray] = field(default_factory=dict)
    ambience_left: np.ndarray | None = None
    ambience_right: np.ndarray | None = None

    @property
    def steps(self) -> int:
        return DIRECTIONS // 2


def _smooth_time(values: np.ndarray, frames: int) -> np.ndarray:
    """Centred moving average over `frames` STFT frames (axis 0), edges held."""
    if frames <= 1:
        return values
    pad = frames // 2
    padded = np.concatenate([np.repeat(values[:1], pad, axis=0), values, np.repeat(values[-1:], pad, axis=0)])
    count = values.shape[0]
    out = padded[:count].copy()
    for shift in range(1, frames):
        out += padded[shift:shift + count]
    out *= 1.0 / frames
    return out


def _third_octave_ranges(bins: int) -> tuple[np.ndarray, np.ndarray]:
    index = np.arange(bins)
    ratio = 2.0 ** (1.0 / 6.0)
    lo = np.minimum(np.floor(index / ratio).astype(int), index - 2)
    hi = np.maximum(np.ceil(index * ratio).astype(int), index + 2) + 1
    return np.clip(lo, 0, bins), np.clip(hi, 0, bins)


def _smooth_freq(values: np.ndarray, lo: np.ndarray, hi: np.ndarray) -> np.ndarray:
    """Mean over a third of an octave around each bin (axis 1), at least five bins."""
    total = np.cumsum(values, axis=1, dtype=np.float32)   # a row is short: single precision is plenty
    total = np.concatenate([np.zeros((values.shape[0], 1), np.float32), total], axis=1)
    return (total[:, hi] - total[:, lo]) / (hi - lo).astype(np.float32)


def analyse(p_ll: np.ndarray, p_rr: np.ndarray, cross: np.ndarray):
    """From the smoothed channel powers and the real part of their cross-spectrum: the source's direction as a unit
    vector (u_left, u_right), how much of the projection on it to keep (gate), the gain that keeps the bin's power
    what it was (trim), and its pan from -1 (right) to +1 (left), with everything near the middle snapped to 0."""
    in_phase = np.maximum(cross - CORRELATION_FLOOR * np.sqrt(p_ll * p_rr), 0.0) / (1.0 - CORRELATION_FLOOR)
    total = p_ll + p_rr
    ambience = 0.5 * (total - np.sqrt((p_ll - p_rr) ** 2 + 4.0 * in_phase ** 2))
    ambience = np.clip(ambience, 0.0, np.minimum(p_ll, p_rr))
    left = np.sqrt(np.maximum(p_ll - ambience, 0.0))
    right = np.sqrt(np.maximum(p_rr - ambience, 0.0))
    source = left * left + right * right
    norm = np.sqrt(source) + 1e-20
    u_left, u_right = left / norm, right / norm
    gate = source / (source + 0.25 * ambience + 1e-20)
    # Where the gate is half open, the part of the projection that is let through and the part that is sent back
    # to the ambience are the same signal in two places, and their powers no longer add up to what came in
    # (g^2 + (1-g)^2 < 1). `trim` puts the bin's power back.
    along = source + ambience                                   # the projection's power: the source plus ambience
    kept = (gate * gate + (1.0 - gate) ** 2) * along + ambience
    trim = np.sqrt((along + ambience) / np.maximum(kept, 1e-20))
    offset = (left - right) / (left + right + 1e-20)
    pan = np.sign(offset) * np.maximum(np.abs(offset) - NEAR_CENTRE, 0.0) / (1.0 - NEAR_CENTRE)
    return (u_left.astype(np.float32), u_right.astype(np.float32), gate.astype(np.float32),
            np.minimum(trim, 1.5).astype(np.float32), pan.astype(np.float32))


def decompose(x: np.ndarray) -> Decomposition:
    """x (frames, 2) float32 -> the stem's sources by direction and its two ambience signals."""
    frames = x.shape[0]
    left = np.ascontiguousarray(x[:, 0], dtype=np.float32)
    right = np.ascontiguousarray(x[:, 1], dtype=np.float32)
    if frames < N_FFT or not np.any(x):
        return Decomposition(ambience_left=left, ambience_right=right)
    spec_l, spec_r = stft(left, N_FFT, HOP), stft(right, N_FFT, HOP)
    lo, hi = _third_octave_ranges(spec_l.shape[1])
    p_ll, p_rr, cross = (_smooth_freq(_smooth_time(p, SMOOTH_FRAMES), lo, hi)
                         for p in (np.abs(spec_l) ** 2, np.abs(spec_r) ** 2, (spec_l * np.conj(spec_r)).real))
    u_left, u_right, gate, trim, pan = analyse(p_ll, p_rr, cross)
    del p_ll, p_rr, cross
    steps = DIRECTIONS // 2
    step = np.rint(pan * steps).astype(np.int8)
    del pan
    source = (u_left * spec_l + u_right * spec_r) * gate
    del gate
    spec_l -= u_left * source
    spec_r -= u_right * source
    del u_left, u_right
    source *= trim
    spec_l *= trim
    spec_r *= trim
    del trim
    out = Decomposition()
    total = float(np.sum(np.abs(source) ** 2) + np.sum(np.abs(spec_l) ** 2) + np.sum(np.abs(spec_r) ** 2))
    floor = NEGLIGIBLE * total
    if float(np.sum(np.abs(spec_l) ** 2)) > floor:
        out.ambience_left = istft(spec_l, N_FFT, HOP, frames)
    if float(np.sum(np.abs(spec_r) ** 2)) > floor:
        out.ambience_right = istft(spec_r, N_FFT, HOP, frames)
    del spec_l, spec_r
    # A direction that holds next to nothing is not worth a source of its own: its bins join the next direction
    # towards the centre.
    power = np.abs(source) ** 2
    for k in list(range(steps, 0, -1)) + list(range(-steps, 0)):
        chosen = step == k
        if chosen.any() and float(power[chosen].sum()) <= floor:
            step[chosen] = k - 1 if k > 0 else k + 1
    del power
    for k in range(-steps, steps + 1):
        chosen = step == k
        if not chosen.any():
            continue
        out.sources[k] = istft(np.where(chosen, source, 0.0).astype(np.complex64), N_FFT, HOP, frames)
    return out
