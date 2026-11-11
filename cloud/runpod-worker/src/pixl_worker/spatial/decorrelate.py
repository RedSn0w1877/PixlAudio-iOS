"""Two short decorrelating filters, used to spread a centred instrument around the listener (Wide, Surround).

Moving a copy of a sound to the side does not make it wider: the copies stay one sound, and where they meet at an
ear they cancel. A copy that has been through a decorrelating filter is heard as the same instrument coming from
a different place. Each filter here is a short burst of sparse impulses with random signs that dies away within
about ten milliseconds (decaying "velvet noise"): too short to be heard as an echo or to blur an attack, long
enough to make the copy independent above a few hundred hertz. The two filters are picked, from a fixed list of
candidates, as the pair that changes the tone least and is least alike, so the choice is the same on every run.
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np

LENGTH_S = 0.024
IMPULSES = 24
DECAY_S = 0.006
CANDIDATES = 96
# Silence in front of both filters: their first impulses arrived together with the centred source they copy and
# combed against it, differently at each ear (measured: +/- 6 dB in 1/12 octaves, and the image split left and
# right in Surround). 3 ms is the measured compromise; 5 ms balances better but puts a third of the energy late.
LEAD_S = 0.003


def _sequence(sample_rate: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    taps = int(round(LENGTH_S * sample_rate))
    cell = taps / IMPULSES
    out = np.zeros(taps)
    for i in range(IMPULSES):
        position = min(taps - 1, int((i + rng.uniform(0.0, 1.0)) * cell))
        out[position] += rng.choice((-1.0, 1.0)) * np.exp(-(position / sample_rate) / DECAY_S)
    return out / np.sqrt(np.sum(out ** 2))


def _ripple_db(sequence: np.ndarray, sample_rate: int) -> float:
    """How far the filter's third-octave response strays from flat between 400 Hz and 12 kHz (standard deviation)."""
    n_fft = 1 << 14
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sample_rate)
    power = np.abs(np.fft.rfft(sequence, n_fft)) ** 2
    levels = []
    centre = 400.0
    while centre <= 12000.0:
        band = (freqs >= centre / 2 ** (1 / 6)) & (freqs < centre * 2 ** (1 / 6))
        levels.append(10.0 * np.log10(power[band].mean()))
        centre *= 2 ** (1 / 3)
    return float(np.std(levels))


@lru_cache(maxsize=4)
def pair(sample_rate: int) -> np.ndarray:
    """(2, taps) float64: two unit-energy decorrelating filters for this sample rate."""
    candidates = [_sequence(sample_rate, 7000 + seed) for seed in range(CANDIDATES)]
    ripples = np.array([_ripple_db(c, sample_rate) for c in candidates])
    flattest = np.argsort(ripples)[:12]
    best, best_score = (int(flattest[0]), int(flattest[1])), np.inf
    for i in flattest:
        for j in flattest:
            if j <= i:
                continue
            alike = abs(float(np.max(np.abs(np.correlate(candidates[i], candidates[j], mode="full")))))
            score = ripples[i] + ripples[j] + 6.0 * alike
            if score < best_score:
                best, best_score = (int(i), int(j)), score
    lead = np.zeros(int(round(LEAD_S * sample_rate)))
    return np.stack([np.concatenate([lead, candidates[best[0]]]), np.concatenate([lead, candidates[best[1]]])])
