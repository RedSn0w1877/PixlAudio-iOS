"""Build src/pixl_worker/spatial/data/hrir_ku100.npz from the SADIE II database (developer tool, run by hand).

    pip install numpy h5py
    python tools/build_hrir.py --sofa D1_48K_24bit_256tap_FIR_SOFA.sofa

Source: SADIE II, subject D1 (Neumann KU100 dummy head), University of York, Apache-2.0.
https://zenodo.org/records/12092466 -> D1_HRIR_SOFA.zip (md5 4850c1eb8e63e2d4f605edcdb4d5c883) ->
D1_HRIR_SOFA/D1_48K_24bit_256tap_FIR_SOFA.sofa (8802 directions, 256 taps, 48 kHz, 1.2 m).

What it does (all of it deterministic):
1. Picks the measured direction nearest to each point of a regular grid (azimuth every 5 degrees on the rings from
   -45 to +60 degrees elevation, coarser rings near the poles). About 900 directions.
2. Makes the head exactly symmetric: the right half of the sphere is the mirror image of the left half, and on
   the median plane both ears get the average. A centred source is then centred to the sample.
3. Removes the common leading silence (the same number of samples from every response, so interaural time
   differences are untouched) and fades the tail out.
4. Diffuse-field equalises the set: the power average over all directions becomes flat, so a room's reverb, and
   music on average, keep their tone. The correction is minimum phase and limited to +/- 12 dB.
5. Stores int16 with a scale factor (the file is about 0.6 MB).

SOFA is netCDF-4/HDF5: Data.IR is (M, R, N) with receiver 0 = left ear; SourcePosition is azimuth (0 = front,
counter-clockwise, so 90 = left), elevation, distance.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

TAPS = 256
LEAD = 12  # samples kept before the earliest onset
OUT = Path(__file__).resolve().parents[1] / "src" / "pixl_worker" / "spatial" / "data" / "hrir_ku100.npz"


def grid() -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for el in range(-45, 61, 15):
        points += [(float(az), float(el)) for az in range(0, 360, 5)]
    for el in (-30 + 7, ):  # no extra ring: keeps the table regular
        pass
    for el, step in ((-60, 15), (75, 15)):
        points += [(float(az), float(el)) for az in range(0, 360, step)]
    points.append((0.0, 90.0))
    return points


def unit(az_deg: np.ndarray, el_deg: np.ndarray) -> np.ndarray:
    az, el = np.radians(az_deg), np.radians(el_deg)
    return np.stack([np.cos(el) * np.cos(az), np.cos(el) * np.sin(az), np.sin(el)], axis=-1)


def onset(ir: np.ndarray) -> int:
    peak = np.abs(ir).max()
    return int(np.argmax(np.abs(ir) > 0.1 * peak))


def smooth_log(freqs: np.ndarray, values: np.ndarray, fraction: float = 3.0) -> np.ndarray:
    out = np.empty_like(values)
    ratio = 2.0 ** (0.5 / fraction)
    for i, f in enumerate(freqs):
        if f <= 0:
            out[i] = values[i]
            continue
        lo, hi = np.searchsorted(freqs, f / ratio), np.searchsorted(freqs, f * ratio, side="right")
        out[i] = values[lo:max(hi, lo + 1)].mean()
    return out


def min_phase(mag: np.ndarray, n_fft: int) -> np.ndarray:
    """Minimum-phase impulse response with the given magnitude (rfft bins of n_fft), by the cepstral method."""
    log_mag = np.log(np.maximum(mag, 1e-8))
    cep = np.fft.irfft(log_mag, n_fft)
    fold = np.zeros(n_fft)
    fold[0] = cep[0]
    fold[1:n_fft // 2] = 2.0 * cep[1:n_fft // 2]
    fold[n_fft // 2] = cep[n_fft // 2]
    return np.fft.irfft(np.exp(np.fft.rfft(fold, n_fft)), n_fft)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sofa", required=True)
    parser.add_argument("--out", default=str(OUT))
    args = parser.parse_args()
    import h5py

    with h5py.File(args.sofa, "r") as f:
        ir = np.asarray(f["Data.IR"], dtype=np.float64)  # (M, 2, N)
        pos = np.asarray(f["SourcePosition"], dtype=np.float64)
        fs = int(round(float(np.asarray(f["Data.SamplingRate"]).ravel()[0])))
    assert fs == 48000 and ir.shape[1] == 2, (fs, ir.shape)
    measured = unit(pos[:, 0], pos[:, 1])

    wanted = grid()
    az = np.array([p[0] for p in wanted])
    el = np.array([p[1] for p in wanted])
    az = np.where(az > 180.0, az - 360.0, az)  # -180..180, positive = left

    def nearest(a: float, e: float) -> int:
        return int(np.argmax(measured @ unit(np.array(a), np.array(e))))

    picked = np.zeros((len(wanted), 2, ir.shape[2]))
    worst = 0.0
    for i, (a, e) in enumerate(zip(az, el)):
        if a < 0 and abs(a) < 180.0:
            m = nearest(-a, e)  # the mirror direction on the left half; swap the ears
            picked[i, 0], picked[i, 1] = ir[m, 1], ir[m, 0]
            target = unit(np.array(-a), np.array(e))
        else:
            m = nearest(a, e)
            picked[i] = ir[m]
            target = unit(np.array(a), np.array(e))
        worst = max(worst, float(np.degrees(np.arccos(np.clip(measured[m] @ target, -1.0, 1.0)))))
        if a in (0.0, 180.0, -180.0) or abs(e) == 90.0:  # median plane: both ears the same
            both = 0.5 * (picked[i, 0] + picked[i, 1])
            picked[i, 0] = picked[i, 1] = both
    print(f"directions: {len(wanted)}, worst distance to a measured point: {worst:.2f} deg")

    first = min(onset(picked[i, c]) for i in range(len(wanted)) for c in range(2))
    cut = max(0, first - LEAD)
    trimmed = np.zeros((len(wanted), 2, TAPS))
    trimmed[:, :, :ir.shape[2] - cut] = picked[:, :, cut:]
    fade = 0.5 * (1.0 + np.cos(np.linspace(0.0, np.pi, 48)))
    trimmed[:, :, TAPS - 48:] *= fade
    print(f"earliest onset at sample {first}; removed {cut} leading samples")

    # diffuse-field equalisation
    n_fft = 4096
    freqs = np.fft.rfftfreq(n_fft, 1.0 / fs)
    weights = np.cos(np.radians(el))
    step = np.where(np.isin(el, (-60.0, 75.0)), 15.0, 5.0)
    weights = weights * step
    weights[np.abs(el) == 90.0] = 0.3 * 5.0  # a small cap for the pole
    weights /= weights.sum()
    power = np.zeros(len(freqs))
    for i in range(len(wanted)):
        spec = np.abs(np.fft.rfft(trimmed[i], n_fft, axis=-1)) ** 2
        power += weights[i] * spec.mean(axis=0)
    power = smooth_log(freqs, power, 3.0)
    lo, hi = np.searchsorted(freqs, 150.0), np.searchsorted(freqs, 18000.0)
    power[:lo] = power[lo]
    power[hi:] = power[hi]
    inverse = 1.0 / np.sqrt(power)
    reference = inverse[np.searchsorted(freqs, 300.0):np.searchsorted(freqs, 1200.0)].mean()
    inverse = np.clip(inverse / reference, 10 ** (-12 / 20), 10 ** (12 / 20)) * reference
    eq = min_phase(inverse, n_fft)[:TAPS]
    eq[TAPS - 32:] *= 0.5 * (1.0 + np.cos(np.linspace(0.0, np.pi, 32)))
    equalised = np.zeros_like(trimmed)
    for i in range(len(wanted)):
        for c in range(2):
            equalised[i, c] = np.convolve(trimmed[i, c], eq)[:TAPS]
    equalised[:, :, TAPS - 32:] *= 0.5 * (1.0 + np.cos(np.linspace(0.0, np.pi, 32)))
    span = 20 * np.log10(inverse.max() / inverse.min())
    print(f"diffuse-field correction spans {span:.1f} dB")

    # After equalisation the diffuse average is flat with gain 1; scale to int16 with headroom.
    peak = float(np.abs(equalised).max())
    scale = peak / 32000.0
    data = np.round(equalised / scale).astype(np.int16)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, ir=data, scale=np.float32(scale), az=az.astype(np.float32), el=el.astype(np.float32),
                        fs=np.int32(fs),
                        source=np.array("SADIE II D1 (Neumann KU100), University of York, Apache-2.0, "
                                        "https://zenodo.org/records/12092466; symmetrised, trimmed, diffuse-field "
                                        "equalised by tools/build_hrir.py"))
    print(f"wrote {out} ({out.stat().st_size / 1e6:.2f} MB), {data.shape}, scale {scale:.3e}")


if __name__ == "__main__":
    main()
