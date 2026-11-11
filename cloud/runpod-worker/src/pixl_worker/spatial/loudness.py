"""Loudness (ITU-R BS.1770-4 integrated, gated) and a true-peak safety limiter, NumPy only.

The limiter does nothing at all while the true peak is under the ceiling (its gain is exactly 1), so it never
colours a render that doesn't need it. When peaks go over, the gain dips smoothly around them: 20 ms either side,
far too slow to follow a waveform and too short to pump.
"""

from __future__ import annotations

import numpy as np


def _biquad_response(b: tuple[float, float, float], a: tuple[float, float, float], w: np.ndarray) -> np.ndarray:
    z1, z2 = np.exp(-1j * w), np.exp(-2j * w)
    return (b[0] + b[1] * z1 + b[2] * z2) / (a[0] + a[1] * z1 + a[2] * z2)


def k_weight_power(freqs: np.ndarray, sample_rate: int) -> np.ndarray:
    """|K(f)|^2: the BS.1770 pre-filter (a +4 dB high shelf, then a 38 Hz high-pass), as two RBJ biquads at this
    sample rate."""
    w = 2.0 * np.pi * freqs / sample_rate
    # high shelf: G = +4 dB, Q = 1/sqrt(2), fc = 1500 Hz
    gain_db, q, fc = 4.0, 1.0 / np.sqrt(2.0), 1500.0
    a_lin = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * fc / sample_rate
    alpha = np.sin(w0) / (2.0 * q)
    cos0 = np.cos(w0)
    b = (a_lin * ((a_lin + 1) + (a_lin - 1) * cos0 + 2 * np.sqrt(a_lin) * alpha),
         -2 * a_lin * ((a_lin - 1) + (a_lin + 1) * cos0),
         a_lin * ((a_lin + 1) + (a_lin - 1) * cos0 - 2 * np.sqrt(a_lin) * alpha))
    a = ((a_lin + 1) - (a_lin - 1) * cos0 + 2 * np.sqrt(a_lin) * alpha,
         2 * ((a_lin - 1) - (a_lin + 1) * cos0),
         (a_lin + 1) - (a_lin - 1) * cos0 - 2 * np.sqrt(a_lin) * alpha)
    shelf = _biquad_response(b, a, w)
    # high-pass: Q = 0.5, fc = 38 Hz
    q, fc = 0.5, 38.0
    w0 = 2.0 * np.pi * fc / sample_rate
    alpha = np.sin(w0) / (2.0 * q)
    cos0 = np.cos(w0)
    b = ((1 + cos0) / 2, -(1 + cos0), (1 + cos0) / 2)
    a = (1 + alpha, -2 * cos0, 1 - alpha)
    high = _biquad_response(b, a, w)
    return np.abs(shelf * high) ** 2


def block_power(x: np.ndarray, sample_rate: int) -> np.ndarray:
    """K-weighted mean square of every 400 ms block (100 ms hop), channels summed. x (frames, ch)."""
    n = int(round(0.4 * sample_rate))
    hop = int(round(0.1 * sample_rate))
    if x.shape[0] < n:
        x = np.concatenate([x, np.zeros((n - x.shape[0], x.shape[1]), x.dtype)])
    freqs = np.fft.rfftfreq(n, 1.0 / sample_rate)
    weight = k_weight_power(freqs, sample_rate)
    weight[1:-1] *= 2.0  # one-sided spectrum (Parseval); n is even
    total = None
    for c in range(x.shape[1]):
        view = np.lib.stride_tricks.sliding_window_view(x[:, c], n)[::hop]
        power = np.empty(view.shape[0])
        for start in range(0, view.shape[0], 128):
            spec = np.fft.rfft(view[start:start + 128], axis=-1)
            power[start:start + 128] = (np.abs(spec) ** 2 @ weight) / (n * n)
        total = power if total is None else total + power
    return total


def integrated_lufs(x: np.ndarray, sample_rate: int) -> float:
    power = block_power(x, sample_rate)
    loud = -0.691 + 10.0 * np.log10(np.maximum(power, 1e-12))
    keep = loud > -70.0
    if not keep.any():
        return -70.0
    relative = -0.691 + 10.0 * np.log10(power[keep].mean()) - 10.0
    keep &= loud > relative
    if not keep.any():
        return -70.0
    return float(-0.691 + 10.0 * np.log10(power[keep].mean()))


def peak_envelope(x: np.ndarray, oversample: int = 4) -> np.ndarray:
    """Per input sample, the largest |value| of the band-limited waveform around it (any channel), from `oversample`
    times oversampling. x (frames, ch) -> (frames,)."""
    frames = x.shape[0]
    size, margin = 1 << 15, 256
    hop = size - 2 * margin
    padded = np.concatenate([np.zeros((margin, x.shape[1]), np.float32), x.astype(np.float32, copy=False),
                             np.zeros((size, x.shape[1]), np.float32)])
    out = np.zeros(frames, dtype=np.float32)
    bins = size // 2 + 1
    for start in range(0, frames, hop):
        chunk = padded[start:start + size]
        spec = np.fft.rfft(chunk, axis=0)
        wide = np.zeros((size * oversample // 2 + 1, x.shape[1]), dtype=spec.dtype)
        wide[:bins] = spec
        wide[bins - 1] *= 0.5
        up = np.fft.irfft(wide, size * oversample, axis=0) * oversample
        peak = np.abs(up).max(axis=1).reshape(size, oversample).max(axis=1)
        keep = peak[margin:margin + hop]
        end = min(frames, start + hop)
        out[start:end] = keep[:end - start]
    return out


def true_peak_db(x: np.ndarray) -> float:
    peak = float(peak_envelope(x).max()) if x.size else 0.0
    return 20.0 * np.log10(max(peak, 1e-9))


def limit(x: np.ndarray, sample_rate: int, ceiling_db: float = -1.0) -> tuple[np.ndarray, float]:
    """Keep the true peak at or under `ceiling_db`. Returns (audio, the deepest gain reduction in dB, >= 0)."""
    ceiling = 10.0 ** (ceiling_db / 20.0)
    deepest = 0.0
    y = x
    for _ in range(3):
        env = peak_envelope(y)
        if float(env.max(initial=0.0)) <= ceiling * 1.0005:
            break
        block = max(1, sample_rate // 1000)
        count = -(-len(env) // block)
        padded = np.concatenate([env, np.zeros(count * block - len(env), np.float32)])
        need = np.minimum(1.0, ceiling / np.maximum(padded.reshape(count, block).max(axis=1), 1e-9))
        reach = 10  # blocks either side
        # edge values, not ones, outside the signal: otherwise the first and last millisecond are let through
        wide = np.concatenate([np.full(reach, need[0]), need, np.full(reach, need[-1])])
        floor = np.lib.stride_tricks.sliding_window_view(wide, 2 * reach + 1).min(axis=1)
        window = np.hanning(2 * reach + 3)[1:-1]
        window /= window.sum()
        smooth = np.convolve(np.concatenate([np.full(reach, floor[0]), floor, np.full(reach, floor[-1])]), window,
                             mode="valid")
        centres = (np.arange(count) + 0.5) * block
        gain = np.interp(np.arange(len(env)), centres, smooth).astype(np.float32)
        deepest += float(-20.0 * np.log10(max(float(gain.min()), 1e-9)))
        y = y * gain[:, None]
    return y.astype(np.float32, copy=False), deepest
