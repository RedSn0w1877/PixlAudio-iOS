"""Small NumPy-only signal tools for the spatial renderer (no SciPy, no torch: the CPU tests run this code)."""

from __future__ import annotations

from typing import Callable

import numpy as np


def fast_len(n: int) -> int:
    """The smallest 2^a 3^b 5^c >= n (FFT sizes with large prime factors are slow)."""
    if n <= 1:
        return 1
    best = 1 << (int(n - 1).bit_length())
    p5 = 1
    while p5 < best:
        p35 = p5
        while p35 < best:
            value = p35
            while value < n:
                value *= 2
            best = min(best, value)
            p35 *= 3
        p5 *= 5
    return best


def pow2_at_least(n: int) -> int:
    return 1 << max(0, int(n - 1).bit_length())


def raised_cosine(n: int, rising: bool = True) -> np.ndarray:
    if n <= 0:
        return np.zeros(0)
    ramp = 0.5 * (1.0 - np.cos(np.pi * (np.arange(n) + 0.5) / n))
    return ramp if rising else ramp[::-1]


def smooth_bands(freqs: np.ndarray, power_a: np.ndarray, power_b: np.ndarray, *, lo: float, hi: float,
                 per_octave: int = 3) -> tuple[np.ndarray, np.ndarray]:
    """Mean power of two spectra in fractional-octave bands between lo and hi. Returns (centres, ratio a/b)."""
    edges = [lo]
    step = 2.0 ** (1.0 / per_octave)
    while edges[-1] * step < hi:
        edges.append(edges[-1] * step)
    edges.append(hi)
    centres, ratio = [], []
    for f0, f1 in zip(edges[:-1], edges[1:]):
        i0, i1 = np.searchsorted(freqs, f0), np.searchsorted(freqs, f1)
        if i1 <= i0:
            continue
        a, b = float(power_a[i0:i1].mean()), float(power_b[i0:i1].mean())
        centres.append(np.sqrt(f0 * f1))
        ratio.append(a / b if b > 0.0 and a > 0.0 else 1.0)
    return np.asarray(centres), np.asarray(ratio)


def convolve_bank(sources: list[np.ndarray], kernels: np.ndarray, out_len: int,
                  tick: Callable[[], None] | None = None) -> np.ndarray:
    """sum_s sources[s] * kernels[s, e] for each output channel e, by overlap-add in the frequency domain.

    sources: S arrays of shape (frames,) float32; kernels (S, E, L) float32 -> (out_len, E) float32. One forward
    transform per source and block, one inverse per output channel and block.
    """
    count, frames = len(sources), len(sources[0])
    outputs, taps = kernels.shape[1], kernels.shape[2]
    n_fft = max(pow2_at_least(4 * taps), 1 << 15)
    hop = n_fft - taps + 1
    spectra = np.fft.rfft(kernels.astype(np.float32, copy=False), n_fft, axis=-1)  # (S, E, bins)
    out = np.zeros((out_len + n_fft, outputs), dtype=np.float32)
    block = np.zeros((count, hop), dtype=np.float32)
    for start in range(0, frames, hop):
        if start >= out_len:
            break
        block[:] = 0.0
        for s, source in enumerate(sources):
            chunk = source[start:start + hop]
            block[s, :len(chunk)] = chunk
        x = np.fft.rfft(block, n_fft, axis=-1)  # (S, bins)
        y = np.fft.irfft(np.einsum("sb,seb->eb", x, spectra), n_fft, axis=-1)  # (E, n_fft)
        out[start:start + n_fft] += y.T.astype(np.float32, copy=False)
        if tick is not None:
            tick()
    return out[:out_len]


def stft(x: np.ndarray, n_fft: int, hop: int) -> np.ndarray:
    """x (frames,) float32 -> (T, n_fft//2+1) with a sqrt-Hann window; padded so every sample is covered n_fft/hop
    times."""
    window = np.sqrt(np.hanning(n_fft + 1)[:-1]).astype(np.float32)
    padded = np.concatenate([np.zeros(n_fft, np.float32), x.astype(np.float32, copy=False),
                             np.zeros(n_fft + hop, np.float32)])
    count = 1 + (len(padded) - n_fft) // hop
    view = np.lib.stride_tricks.sliding_window_view(padded, n_fft)[::hop][:count]
    return np.fft.rfft(view * window, axis=-1)


def istft(spec: np.ndarray, n_fft: int, hop: int, length: int) -> np.ndarray:
    """Inverse of stft() (sqrt-Hann synthesis, hop = n_fft/4). Returns `length` samples."""
    assert n_fft % hop == 0
    overlap = n_fft // hop
    window = np.sqrt(np.hanning(n_fft + 1)[:-1]).astype(np.float32)
    frames = np.fft.irfft(spec, n_fft, axis=-1).astype(np.float32, copy=False) * window
    total = (frames.shape[0] - 1) * hop + n_fft
    out = np.zeros(total + n_fft, dtype=np.float32)
    for k in range(overlap):
        part = frames[k::overlap]
        out[k * hop:k * hop + part.size] += part.reshape(-1)
    # sqrt-Hann analysis x synthesis = Hann; Hann summed at hop n/4 is 2.0
    out *= 1.0 / (overlap / 2.0)
    return out[n_fft:n_fft + length]


def zero_phase(spec: np.ndarray, gain: np.ndarray) -> np.ndarray:
    return spec * gain


def interp_log(freqs: np.ndarray, centres: np.ndarray, values: np.ndarray) -> np.ndarray:
    """Values given at `centres` (Hz), interpolated on a log-frequency axis onto `freqs`, held flat outside."""
    out = np.interp(np.log(np.maximum(freqs, 1e-3)), np.log(centres), values)
    return out


def min_phase_spectrum(magnitude: np.ndarray, n_fft: int) -> np.ndarray:
    """The spectrum (rfft bins of n_fft) of the minimum-phase filter with this magnitude (cepstral method)."""
    cepstrum = np.fft.irfft(np.log(np.maximum(magnitude, 1e-8)), n_fft)
    folded = np.zeros(n_fft)
    folded[0] = cepstrum[0]
    folded[1:n_fft // 2] = 2.0 * cepstrum[1:n_fft // 2]
    folded[n_fft // 2] = cepstrum[n_fft // 2]
    return np.exp(np.fft.rfft(folded, n_fft))
