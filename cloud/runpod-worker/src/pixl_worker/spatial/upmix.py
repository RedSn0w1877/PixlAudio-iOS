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
ANALYSIS_BLOCK = 512 # frames analysed at a time at the default hop (about 11 s at 48 kHz)
HYSTERESIS = 0.2     # a bin keeps its direction until its pan is this far past the midpoint to the next one
# Drums (and the whole mix when there are no stems) are taken apart with a quarter of the frame length: the gains
# of a long frame reach back before a hit (measured: 2-10 kHz energy up to 9 dB over the stem's own in the 30 ms
# before drum hits). The time smoothing stays about 0.2 s either way.
TRANSIENT = {"n_fft": 1024, "hop": 256, "smooth_frames": 36}


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


def _smooth_time(values: np.ndarray, first: int, start: int, stop: int, total: int, frames: int) -> np.ndarray:
    """Centred moving average over `frames` STFT frames of the rows start..stop of a signal `total` frames long,
    edges held. `values` holds that signal's rows first.. (at least start - frames//2 .. stop + frames//2, clipped
    to the signal)."""
    pad = frames // 2
    rows = stop - start
    index = np.clip(np.arange(start - pad, stop + pad), 0, total - 1) - first
    padded = values[index]
    out = padded[:rows].copy()
    for shift in range(1, frames):
        out += padded[shift:shift + rows]
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
    # Double precision: a bin 70 dB under the row's running total vanishes from a single-precision sum, and with
    # it the bin's statistics (measured: hi-hats near loud kicks lost up to 79 dB).
    total = np.cumsum(values, axis=1, dtype=np.float64)
    total = np.concatenate([np.zeros((values.shape[0], 1)), total], axis=1)
    return ((total[:, hi] - total[:, lo]) / (hi - lo)).astype(np.float32)


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
    trim = np.where(kept > 0.0, np.sqrt((along + ambience) / np.maximum(kept, 1e-20)), 1.0)
    offset = (left - right) / (left + right + 1e-20)
    pan = np.sign(offset) * np.maximum(np.abs(offset) - NEAR_CENTRE, 0.0) / (1.0 - NEAR_CENTRE)
    return (u_left.astype(np.float32), u_right.astype(np.float32), gate.astype(np.float32),
            np.minimum(trim, 1.5).astype(np.float32), pan.astype(np.float32))


def decompose(x: np.ndarray, *, n_fft: int = N_FFT, hop: int = HOP, smooth_frames: int = SMOOTH_FRAMES
              ) -> Decomposition:
    """x (frames, 2) float32 -> the stem's sources by direction and its two ambience signals.

    The analysis runs over blocks of frames (each with the few neighbouring frames the smoothing needs), so a long
    song needs three full-size spectra (left, right and the source) and nothing else big. A bin keeps its
    direction until its pan has clearly moved on (HYSTERESIS): a sound sitting between two directions no longer
    flips between them (measured before: level jumps of up to 8 dB at one ear)."""
    frames = x.shape[0]
    left = np.ascontiguousarray(x[:, 0], dtype=np.float32)
    right = np.ascontiguousarray(x[:, 1], dtype=np.float32)
    if frames < n_fft or not np.any(x):
        return Decomposition(ambience_left=left, ambience_right=right)
    spec_l, spec_r = stft(left, n_fft, hop), stft(right, n_fft, hop)
    count, bins = spec_l.shape
    lo, hi = _third_octave_ranges(bins)
    steps = DIRECTIONS // 2
    pad = smooth_frames // 2
    block = max(64, ANALYSIS_BLOCK * HOP // hop)
    source = np.empty_like(spec_l)
    step = np.empty((count, bins), dtype=np.int8)
    power_by_step = np.zeros(DIRECTIONS)
    bins_by_step = np.zeros(DIRECTIONS, dtype=np.int64)
    ambience_power = [0.0, 0.0]
    kept_l = kept_r = None    # the previous block's last frames, as they were before this pass changed them
    state = None              # every bin's current direction (the hysteresis carries over between blocks)
    for start in range(0, count, block):
        stop = min(count, start + block)
        end = min(count, stop + pad)
        if kept_l is None:
            first, block_l, block_r = start, spec_l[start:end], spec_r[start:end]
        else:
            first = start - kept_l.shape[0]
            block_l, block_r = np.concatenate([kept_l, spec_l[start:end]]), np.concatenate([kept_r, spec_r[start:end]])
        stats = []
        for raw in (np.abs(block_l) ** 2, np.abs(block_r) ** 2, (block_l * np.conj(block_r)).real):
            stats.append(_smooth_freq(_smooth_time(raw, first, start, stop, count, smooth_frames), lo, hi))
        del block_l, block_r
        u_left, u_right, gate, trim, pan = analyse(*stats)
        del stats
        tail = max(start, stop - pad)
        kept_l, kept_r = spec_l[tail:stop].copy(), spec_r[tail:stop].copy()
        rows_l, rows_r = spec_l[start:stop], spec_r[start:stop]      # views: changed in place below
        here = (u_left * rows_l + u_right * rows_r) * gate
        rows_l -= u_left * here
        rows_r -= u_right * here
        here *= trim
        rows_l *= trim
        rows_r *= trim
        target = pan * steps
        labels = np.empty(target.shape, dtype=np.int8)
        if state is None:
            state = np.rint(target[0])
        for row in range(target.shape[0]):
            move = np.abs(target[row] - state) > 0.5 + HYSTERESIS
            state = np.where(move, np.rint(target[row]), state)
            labels[row] = state
        del target
        source[start:stop] = here
        step[start:stop] = labels
        power = np.abs(here) ** 2
        flat = labels.ravel().astype(np.int64) + steps
        power_by_step += np.bincount(flat, weights=power.ravel(), minlength=DIRECTIONS)
        bins_by_step += np.bincount(flat, minlength=DIRECTIONS)
        ambience_power[0] += float(np.sum(np.abs(rows_l) ** 2))
        ambience_power[1] += float(np.sum(np.abs(rows_r) ** 2))
        del u_left, u_right, gate, trim, pan, here, labels, power, flat
    out = Decomposition()
    floor = NEGLIGIBLE * (float(power_by_step.sum()) + ambience_power[0] + ambience_power[1])
    if ambience_power[0] > floor:
        out.ambience_left = istft(spec_l, n_fft, hop, frames)
    if ambience_power[1] > floor:
        out.ambience_right = istft(spec_r, n_fft, hop, frames)
    del spec_l, spec_r
    # A direction that holds next to nothing is not worth a source of its own: its bins join the next direction
    # towards the centre.
    for k in list(range(steps, 0, -1)) + list(range(-steps, 0)):
        here, inward = k + steps, (k - 1 if k > 0 else k + 1) + steps
        if bins_by_step[here] > 0 and power_by_step[here] <= floor:
            step[step == k] = inward - steps
            power_by_step[inward] += power_by_step[here]
            bins_by_step[inward] += bins_by_step[here]
            power_by_step[here], bins_by_step[here] = 0.0, 0
    for k in range(-steps, steps + 1):
        if bins_by_step[k + steps] == 0:
            continue
        out.sources[k] = istft(source, n_fft, hop, frames, select=(step, k))
    return out
