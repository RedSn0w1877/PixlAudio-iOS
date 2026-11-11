"""Enhanced audio: finding out whether a song's highs were cut off, and the seam for the model that puts them back
(docs/handoff/2026-11-10-plans/cloud-audio-spec.md, sections 4 and 5).

Two parts:

- `detect_cutoff_hz` (NumPy only, runs in the CPU tests): where the song's spectrum stops. A 128 kb/s AAC stream
  ends at about 16 kHz, an Opus stream at 20 kHz, an old upload sometimes at 11 kHz.
- `Restorer`: the restoration model's wrapper. There is no model behind it yet (it comes with the second worker
  change, see the spec), so `available()` is False and `decide()` answers `unavailable` for a band-limited song.
  The pipeline already does everything else: it asks `decide()`, calls `restore()` when told to, writes
  `enhanced.flac` from what comes back and renders the spatial profiles from it. The tests drive that path with a
  fake model.

How the cutoff is found. The long-term spectrum of the whole song (both channels, 4096-point frames) is measured
against its own level between 2 and 8 kHz. The cutoff is the highest frequency that is still within 30 dB of that
level, provided the spectrum falls off a cliff right there: a codec's low-pass drops into nothing within a few
hundred hertz, while a dark but complete recording only fades, a few dB per kHz. Measured on real songs
(2026-11-11, four pop masters decoded from Opus and stored as 16-bit FLAC): their level at 17 kHz is 8 to 25 dB
under the 2-8 kHz average, the Opus edge at 20 kHz is a 19 to 32 dB cliff, and the 16-bit noise floor above it sits
45 to 50 dB under. So when there is no cliff at the 30 dB point the search goes on a little lower (36, then 42 dB,
still above that floor) for songs whose highs are weak, and a spectrum with no cliff at all has no cutoff: it is
reported as full band (the Nyquist frequency), because there is nothing a stream took away.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import numpy as np

from .errors import INTERNAL, WorkerError

# A song whose spectrum goes on above this is left alone (spec section 5: the model only runs at or under 17 kHz).
FULL_BAND_HZ = 17000.0
REASONS = ("full_band", "off", "unavailable", "failed")

N_FFT = 4096
MAX_FRAMES = 8192        # per channel: 12 minutes at 48 kHz before frames are skipped
REFERENCE_BAND_HZ = (2000.0, 8000.0)
DROPS_DB = (30.0, 36.0, 42.0)
CLIFF_DB = 10.0          # how far the level has to fall across the edge to be a cut, not a fade
SMOOTH_HZ = 150.0        # median over +/- this much: a 19 kHz pilot tone or a 15.7 kHz whine is not "content"
EDGE_BELOW_HZ = (700.0, 100.0)   # the stretch just under the edge that is compared ...
EDGE_ABOVE_HZ = (200.0, 1000.0)  # ... with the stretch just over it
TOP_MARGIN_HZ = 800.0    # content this close to the Nyquist frequency reaches the top: nothing was cut


def long_term_spectrum(mix: np.ndarray, sample_rate: int, n_fft: int = N_FFT) -> tuple[np.ndarray, np.ndarray]:
    """(frequencies, mean power per bin) over Hann-windowed frames of every channel. mix is (frames, channels) or
    (frames,). Frames are taken back to back; a long song is thinned to at most MAX_FRAMES evenly spread frames per
    channel (a 15-minute song costs what a 12-minute one does), and the work is done in small batches, so this
    needs almost no memory."""
    x = np.asarray(mix)
    if x.ndim == 1:
        x = x[:, None]
    if x.shape[0] < n_fft:
        x = np.concatenate([x, np.zeros((n_fft - x.shape[0], x.shape[1]), x.dtype)])
    hop = n_fft * max(1, -(-(x.shape[0] // n_fft) // MAX_FRAMES))
    window = np.hanning(n_fft + 1)[:-1].astype(np.float32)
    power = np.zeros(n_fft // 2 + 1, dtype=np.float64)
    count = 0
    for c in range(x.shape[1]):
        view = np.lib.stride_tricks.sliding_window_view(x[:, c], n_fft)[::hop]
        for start in range(0, view.shape[0], 256):
            spec = np.fft.rfft(view[start:start + 256].astype(np.float32, copy=False) * window, axis=-1)
            power += (spec.real.astype(np.float64) ** 2 + spec.imag.astype(np.float64) ** 2).sum(axis=0)
            count += spec.shape[0]
    return np.fft.rfftfreq(n_fft, 1.0 / sample_rate), power / max(count, 1)


def _median_smooth(values: np.ndarray, half: int) -> np.ndarray:
    if half <= 0:
        return values
    padded = np.concatenate([np.repeat(values[:1], half), values, np.repeat(values[-1:], half)])
    return np.median(np.lib.stride_tricks.sliding_window_view(padded, 2 * half + 1), axis=1)


def detect_cutoff_hz(mix: np.ndarray, sample_rate: int) -> float:
    """The frequency where the song's spectrum was cut off, in Hz. A song that was not cut returns about the Nyquist
    frequency (an Opus stream: its own 20 kHz edge); silence returns the Nyquist frequency. See the module note."""
    nyquist = sample_rate / 2.0
    freqs, power = long_term_spectrum(mix, sample_rate)
    if not np.isfinite(power).all() or float(power.sum()) <= 0.0:
        return float(nyquist)
    step = float(freqs[1] - freqs[0])
    smooth = _median_smooth(power, int(round(SMOOTH_HZ / step)))
    lo = min(REFERENCE_BAND_HZ[0], 0.25 * nyquist)
    hi = min(REFERENCE_BAND_HZ[1], 0.9 * nyquist)
    band = (freqs >= lo) & (freqs <= hi)
    reference = float(power[band].mean())
    if reference <= 0.0:
        return float(nyquist)
    level = 10.0 * np.log10(np.maximum(smooth, 1e-30) / reference)

    def stretch(centre: float, span: tuple[float, float], sign: float) -> float | None:
        a, b = sorted((centre + sign * span[0], centre + sign * span[1]))
        b = min(b, nyquist)
        chosen = level[(freqs >= a) & (freqs <= b)]
        return float(np.median(chosen)) if b - a >= 300.0 and chosen.size else None

    for drop in DROPS_DB:
        within = np.nonzero(level >= -drop)[0]
        if within.size == 0:
            continue
        edge = float(freqs[within[-1]])
        if edge >= nyquist - TOP_MARGIN_HZ:
            return float(min(edge, nyquist))
        below, above = stretch(edge, EDGE_BELOW_HZ, -1.0), stretch(edge, EDGE_ABOVE_HZ, +1.0)
        if below is not None and above is not None and below - above >= CLIFF_DB:
            return edge
    return float(nyquist)


@dataclass(frozen=True)
class RestoreInfo:
    """What happened to a song's highs, as the manifests record it (`render.restore`, plus `source.cutoffHz`)."""
    applied: bool
    model: str | None
    reason: str | None   # one of REASONS, None when the restoration was applied
    cutoff_hz: int

    def as_dict(self) -> dict:
        return {"applied": self.applied, "model": self.model, "reason": self.reason}


class Restorer:
    """The restoration model. This base class is "no model on this worker": the next worker change subclasses it
    (lazy torch, like separate.Stems4), sets `model_id`, and implements `available`, `loaded` and `restore`.

    Contract for `restore`: mix is (frames, 2) float32 at sample_rate, cutoff_hz what detect_cutoff_hz returned
    (at or under FULL_BAND_HZ). Returns the restored song, (frames, 2) float32 with the same frame count and
    timeline and values within [-1, 1], at the source's loudness. `progress(done, total)` is called often: it
    carries the job's deadline, so an exception raised by it must abort the work. Running out of GPU memory raises
    WorkerError(GPU_OOM, ..., refresh_worker=True), like the separators."""

    model_id: str | None = None

    @property
    def loaded(self) -> bool:
        return False

    def available(self) -> bool:
        return False

    def restore(self, mix: np.ndarray, sample_rate: int, cutoff_hz: float, *,
                progress: Callable[[int, int], None] | None = None) -> np.ndarray:
        raise WorkerError(INTERNAL, "no restoration model on this worker")


def decide(cutoff_hz: float, mode: str, restorer: Restorer | None) -> tuple[bool, RestoreInfo]:
    """(run the model?, what to record when it does not run). The order matters: a full-band song is `full_band`
    whatever was asked (that is a fact about the song, and it goes into a manifest every phone reads); then the
    job's own `library.restore: off`; then a worker without the model."""
    cutoff = int(round(cutoff_hz))
    if cutoff_hz > FULL_BAND_HZ:
        return False, RestoreInfo(False, None, "full_band", cutoff)
    if mode == "off":
        return False, RestoreInfo(False, None, "off", cutoff)
    if restorer is None or not restorer.available():
        return False, RestoreInfo(False, None, "unavailable", cutoff)
    return True, RestoreInfo(False, restorer.model_id, "failed", cutoff)  # what stands if the model then fails
