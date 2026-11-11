"""The room around the listener: early reflections from an image-source shoebox, and a synthetic late tail.

Early reflections are what moves a sound out of the head over headphones: each one is a quieter, slightly duller
copy of the direct sound arriving from its own direction, so each goes through the head model for that direction.
The ones that help are the LATERAL ones (side walls): they reach the two ears differently. Reflections from the
floor, the ceiling and the wall behind the sources arrive in the same plane as a centred source, so they only
colour it (a comb filter); the rooms in profiles.py therefore have soft floors, ceilings and front walls, lively
side walls, and a listener who sits off the centre line so the left and right reflections never arrive as a
mirrored pair.
The late tail is diffuse: noise that decays at the room's reverberation time (faster at high frequencies), equal
in level at both ears and decorrelated between them the way a real diffuse field is around a head (the same at low
frequencies, independent above about 1 kHz).
"""

from __future__ import annotations

import numpy as np

from .dsp import istft, pow2_at_least, raised_cosine, stft
from .hrir import HrirSet
from .profiles import Room

SPEED_OF_SOUND = 343.0


def source_position(room: Room, az: float, el: float, dist: float) -> np.ndarray:
    """Where a source at (az, el, dist) from the listener is in the room, kept 0.3 m off every wall."""
    a, e = np.radians(az), np.radians(el)
    direction = np.array([np.cos(e) * np.cos(a), np.cos(e) * np.sin(a), np.sin(e)])
    position = np.asarray(room.listener, dtype=np.float64) + dist * direction
    return np.clip(position, 0.3, np.asarray(room.size, dtype=np.float64) - 0.3)


def reflections(room: Room, source: np.ndarray, sample_rate: int) -> list[tuple[float, float, float, float, int]]:
    """(delay in samples after the direct sound, gain relative to it, azimuth, elevation, bounces) for every image
    source up to room.order bounces that arrives within room.er_max_s. Each wall has its own reflection
    coefficient (room.reflect: back, front, right, left, floor, ceiling)."""
    listener = np.asarray(room.listener, dtype=np.float64)
    direct = float(np.linalg.norm(source - listener))
    per_axis = []
    for axis in range(3):
        near, far = room.reflect[2 * axis], room.reflect[2 * axis + 1]  # the wall at 0 and the wall at size
        options = []
        for i in range(-room.order, room.order + 1):
            for parity in (0, 1):
                hits_near, hits_far = abs(i - parity), abs(i)
                if hits_near + hits_far <= room.order:
                    options.append(((1 - 2 * parity) * source[axis] + 2 * i * room.size[axis], hits_near + hits_far,
                                    near ** hits_near * far ** hits_far))
        per_axis.append(options)
    found = []
    for x, hx, gx in per_axis[0]:
        for y, hy, gy in per_axis[1]:
            for z, hz, gz in per_axis[2]:
                bounces = hx + hy + hz
                if bounces == 0 or bounces > room.order:
                    continue
                vector = np.array([x, y, z]) - listener
                distance = float(np.linalg.norm(vector))
                delay_s = (distance - direct) / SPEED_OF_SOUND
                if delay_s <= 0.0 or delay_s > room.er_max_s:
                    continue
                gain = (direct / distance) * gx * gy * gz
                az = float(np.degrees(np.arctan2(vector[1], vector[0])))
                el = float(np.degrees(np.arcsin(np.clip(vector[2] / distance, -1.0, 1.0))))
                found.append((delay_s * sample_rate, gain, az, el, bounces))
    return found


class KernelBuilder:
    """Direct sound + early reflections for one profile's room, as (2, length) impulse responses per source.

    Tone: a real head colours every direction differently (the notch near 8 kHz for sounds straight ahead is the
    best known). Those colourations are personal: on someone else's ears they just sound dull or phasey. So the
    DIRECT sound of each source is equalised until the power of both ears together is flat, which leaves every
    difference BETWEEN the ears (level and time, the cues that place a sound left or right) exactly as measured.
    Sounds behind the listener keep part of their natural dullness, which is what says "behind". Reflections are
    left as measured: they are the room.
    """

    def __init__(self, hrir: HrirSet, room: Room, reference_dist: float):
        self.hrir, self.room = hrir, room
        self.sample_rate = hrir.sample_rate
        self.length = hrir.taps + int(np.ceil(room.er_max_s * self.sample_rate)) + 16
        self.n_fft = pow2_at_least(self.length)
        self._freqs = np.fft.rfftfreq(self.n_fft, 1.0 / self.sample_rate)
        self._bins = np.arange(len(self._freqs))
        self._damp = 1.0 / np.sqrt(1.0 + (self._freqs / room.damp_hz) ** 2)
        self._spectra: dict[int, np.ndarray] = {}
        self._direct: dict[int, np.ndarray] = {}
        # fractional-octave smoothing windows (a sixth of an octave either side) as index ranges
        ratio = 2.0 ** (1.0 / 6.0)
        self._lo = np.floor(self._bins / ratio).astype(int)
        self._hi = np.minimum(np.ceil(self._bins * ratio).astype(int) + 1, len(self._bins))
        self._band = (self._freqs >= 200.0) & (self._freqs <= 6000.0)
        front = self._direct_spectrum(0.0, 0.0)
        self.front_energy = self._energy(front)
        # Scale the reflections so a centred source at the reference distance gets exactly room.er_db.
        _, early = self._parts(0.0, 0.0, reference_dist)
        early_energy = self._energy(early)
        target = self.front_energy * 10.0 ** (room.er_db / 10.0)
        self.er_scale = float(np.sqrt(target / early_energy)) if early_energy > 0.0 else 0.0

    def _energy(self, spec: np.ndarray) -> float:
        """Mean over the two ears of the impulse response's energy (Parseval on the one-sided spectrum)."""
        power = np.abs(spec) ** 2
        power[:, 1:-1] *= 2.0
        return float(power.sum(axis=-1).mean() / self.n_fft)

    def _spectrum(self, az: float, el: float) -> np.ndarray:
        index = self.hrir.index(az, el)
        spec = self._spectra.get(index)
        if spec is None:
            spec = np.fft.rfft(self.hrir.ir[index].astype(np.float64), self.n_fft, axis=-1)
            self._spectra[index] = spec
        return spec

    def _direct_spectrum(self, az: float, el: float) -> np.ndarray:
        """The head model for a direct sound from (az, el): tone-neutral (see the class note), not yet levelled."""
        index = self.hrir.index(az, el)
        spec = self._direct.get(index)
        if spec is None:
            raw = self._spectrum(az, el)
            power = (np.abs(raw) ** 2).mean(axis=0)
            total = np.concatenate([[0.0], np.cumsum(power)])
            smooth = (total[self._hi] - total[self._lo]) / np.maximum(self._hi - self._lo, 1)
            reference = float(smooth[self._band].mean())
            behind = max(0.0, (abs(float(self.hrir.az[index])) - 100.0) / 80.0)  # 0 in front and beside, 1 behind
            strength = 1.0 - 0.5 * min(1.0, behind)
            correction = np.clip((reference / np.maximum(smooth, 1e-12)) ** (0.5 * strength), 10 ** (-10 / 20),
                                 10 ** (10 / 20))
            correction[self._freqs < 150.0] = correction[np.searchsorted(self._freqs, 150.0)]
            spec = raw * correction
            self._direct[index] = spec
        return spec

    def direct(self, az: float, el: float) -> np.ndarray:
        """(2, bins): the tone-neutral head model for a direct sound from (az, el), levelled so every direction is
        as loud as the front. The mix's balance is the artist's: moving a part to the side must not turn it up."""
        spec = self._direct_spectrum(az, el)
        return spec * float(np.sqrt(self.front_energy / max(self._energy(spec), 1e-12)))

    def _parts(self, az: float, el: float, dist: float) -> tuple[np.ndarray, np.ndarray]:
        raw = self._direct_spectrum(az, el)
        level = float(np.sqrt(self.front_energy / max(self._energy(raw), 1e-12)))
        direct = raw * level
        early = np.zeros_like(direct)
        source = source_position(self.room, az, el, dist)
        for delay, gain, r_az, r_el, bounces in reflections(self.room, source, self.sample_rate):
            shift = np.exp(-2j * np.pi * self._bins * delay / self.n_fft)
            early += self._spectrum(r_az, r_el) * (gain * level * self._damp ** bounces * shift)
        return direct, early

    def kernel(self, az: float, el: float, dist: float, gain: float, er_send: float) -> np.ndarray:
        direct, early = self._parts(az, el, dist)
        spec = gain * (direct + self.er_scale * er_send * early)
        return np.fft.irfft(spec, self.n_fft, axis=-1)[:, :self.length].astype(np.float32)


def late_tail(room: Room, sample_rate: int, seed: int, front_energy: float) -> np.ndarray:
    """(2 sends, 2 ears, length) float32: the left send and the right send each feed their own decorrelated
    binaural tail. A centred source feeds both sends, and then gets exactly room.rev_db of late energy."""
    start = int(0.5 * room.mix_time_s * sample_rate)
    rise = max(8, int(0.5 * room.mix_time_s * sample_rate))
    length = start + rise + int(1.1 * max(room.rt60) * sample_rate)
    n_fft, hop = 1024, 256
    rng = np.random.default_rng(seed)
    freqs_full = np.fft.rfftfreq(length, 1.0 / sample_rate)
    x = 2.0 * np.pi * freqs_full * 0.17 / SPEED_OF_SOUND
    coherence = np.where(x > 1e-6, np.sin(x) / np.maximum(x, 1e-6), 1.0)
    coherence = np.clip(coherence, 0.0, 1.0) * (1.0 / (1.0 + (freqs_full / 1400.0) ** 4))
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sample_rate)
    points = np.log(np.array([125.0, 1000.0, 8000.0]))
    rt60 = np.interp(np.log(np.maximum(freqs, 20.0)), points, np.asarray(room.rt60, dtype=np.float64))
    envelope = np.zeros(length, dtype=np.float64)
    envelope[start:start + rise] = raised_cosine(rise)
    envelope[start + rise:] = 1.0
    out = np.zeros((2, 2, length), dtype=np.float32)
    target = 0.5 * front_energy * 10.0 ** (room.rev_db / 10.0)
    for send in range(2):
        first = np.fft.rfft(rng.standard_normal(length))
        second = np.fft.rfft(rng.standard_normal(length))
        ears = (first, coherence * first + np.sqrt(1.0 - coherence ** 2) * second)
        for ear, spectrum in enumerate(ears):
            noise = np.fft.irfft(spectrum, length).astype(np.float32)
            spec = stft(noise, n_fft, hop)
            # frame t of stft() is centred at sample t*hop - n_fft/2 (it pads n_fft zeros in front)
            times = np.maximum((np.arange(spec.shape[0]) * hop - n_fft / 2.0 - (start + rise)) / sample_rate, 0.0)
            decay = np.exp(-6.9078 * times[:, None] / rt60[None, :])
            shaped = istft(spec * decay.astype(np.float32), n_fft, hop, length).astype(np.float64) * envelope
            energy = float(np.sum(shaped ** 2))
            out[send, ear] = (shaped * np.sqrt(target / energy)).astype(np.float32)
    return out
