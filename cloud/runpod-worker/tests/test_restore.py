"""restore.py: where a song's spectrum was cut off (NumPy, on synthetic songs shaped like the real ones it was
tuned on), what the worker then decides, and the seam the restoration model will plug into."""

import numpy as np
import pytest

from conftest import band_mix, band_stems
from pixl_worker import errors, restore as R


def song(seconds: float, sample_rate: int, *, cut_hz: float | None = None, tilt_db_per_octave: float = -4.5,
         dark_above_hz: float | None = None, bits: int | None = None, seed: int = 4) -> np.ndarray:
    """Stereo noise with the long-term spectrum of a pop master (falling a few dB per octave), optionally cut off
    like a codec does (a brick wall at cut_hz), made dull (12 dB per octave more above dark_above_hz), or stored
    at `bits` bits (which puts a flat noise floor under it, as a 16-bit FLAC upload has)."""
    rng = np.random.default_rng(seed)
    frames = int(seconds * sample_rate)
    freqs = np.fft.rfftfreq(frames, 1.0 / sample_rate)
    magnitude = np.where(freqs >= 40.0, (np.maximum(freqs, 40.0) / 1000.0) ** (tilt_db_per_octave / 6.02), 0.0)
    if dark_above_hz is not None:
        magnitude = magnitude / (1.0 + (freqs / dark_above_hz) ** 2)
    if cut_hz is not None:
        magnitude = np.where(freqs <= cut_hz, magnitude, 0.0)
    channels = []
    for _ in range(2):
        x = np.fft.irfft(magnitude * np.exp(2j * np.pi * rng.random(len(freqs))), frames)
        channels.append(0.1 * x / np.sqrt(np.mean(x ** 2)))
    x = np.stack(channels, axis=1)
    if bits is not None:
        scale = float(1 << (bits - 1))
        x = np.round(x * scale) / scale
    return x.astype(np.float32)


# ---- detect_cutoff_hz ------------------------------------------------------------------------------------

@pytest.mark.parametrize("sample_rate", [44100, 48000])
def test_a_full_band_song_has_no_cutoff(sample_rate):
    for bits in (None, 16):
        cutoff = R.detect_cutoff_hz(song(8.0, sample_rate, bits=bits), sample_rate)
        assert cutoff >= sample_rate / 2 - R.TOP_MARGIN_HZ and cutoff <= sample_rate / 2
        assert R.decide(cutoff, "auto", None)[1].reason == "full_band"


@pytest.mark.parametrize("sample_rate, cut", [(44100, 16000.0), (48000, 16000.0), (44100, 15000.0), (44100, 11000.0),
                                              (48000, 8000.0), (44100, 4000.0)])
def test_a_codec_cut_is_found_where_it_is(sample_rate, cut):
    for bits in (None, 16):  # decoded to float (an AAC stream passed through), and through a 16-bit FLAC upload
        cutoff = R.detect_cutoff_hz(song(8.0, sample_rate, cut_hz=cut, bits=bits), sample_rate)
        assert abs(cutoff - cut) <= 60.0, (bits, cutoff)
        assert R.decide(cutoff, "auto", None)[1] == R.RestoreInfo(False, None, "unavailable", int(round(cutoff)))


def test_an_opus_stream_reports_its_own_20k_edge_and_is_full_band():
    cutoff = R.detect_cutoff_hz(song(8.0, 48000, cut_hz=20000.0, bits=16), 48000)
    assert abs(cutoff - 20000.0) <= 60.0
    assert cutoff > R.FULL_BAND_HZ and R.decide(cutoff, "auto", None)[1].reason == "full_band"


def test_a_dull_but_complete_song_is_not_taken_for_a_cut_one():
    # A dark master: its highs fade a few dB per kHz into the 16-bit floor and never fall off a cliff. Its level
    # is 30 dB under the 2-8 kHz average long before 17 kHz, which is exactly why the level alone is not enough.
    dark = song(8.0, 44100, dark_above_hz=3000.0, bits=16)
    freqs, power = R.long_term_spectrum(dark, 44100)
    reference = power[(freqs >= 2000) & (freqs <= 8000)].mean()
    level = 10 * np.log10(R._median_smooth(power, 14) / reference)
    last_within_30_db = freqs[np.nonzero(level >= -30.0)[0][-1]]
    assert 8000.0 < last_within_30_db < R.FULL_BAND_HZ - 1000.0  # by level alone it would count as cut off
    cutoff = R.detect_cutoff_hz(dark, 44100)
    assert cutoff == 22050.0 and R.decide(cutoff, "auto", None)[1].reason == "full_band"
    # ... and the same dull song WITH a codec cut is still found
    cut = R.detect_cutoff_hz(song(8.0, 44100, dark_above_hz=9000.0, cut_hz=16000.0, bits=16), 44100)
    assert abs(cut - 16000.0) <= 60.0


def test_a_lone_tone_above_the_cut_is_not_content():
    x = song(8.0, 48000, cut_hz=15000.0, bits=16)
    t = np.arange(x.shape[0]) / 48000.0
    for tone_hz in (19000.0, 15734.0):  # an FM pilot, a TV line whistle
        with_tone = x + (0.01 * np.sin(2 * np.pi * tone_hz * t))[:, None].astype(np.float32)
        assert abs(R.detect_cutoff_hz(with_tone, 48000) - 15000.0) <= 60.0


def test_a_low_sample_rate_is_its_own_cutoff():
    for sample_rate in (32000, 22050, 16000, 8000):
        cutoff = R.detect_cutoff_hz(song(6.0, sample_rate), sample_rate)
        assert sample_rate / 2 - R.TOP_MARGIN_HZ <= cutoff <= sample_rate / 2
        assert R.decide(cutoff, "auto", None)[1].reason == "unavailable"  # at or under 17 kHz: something is missing
    assert R.decide(R.detect_cutoff_hz(song(6.0, 96000), 96000), "auto", None)[1].reason == "full_band"


def test_shape_and_length_do_not_matter():
    x = song(8.0, 44100, cut_hz=16000.0)
    assert abs(R.detect_cutoff_hz(x[:, 0], 44100) - 16000.0) <= 60.0          # mono, one dimension
    assert abs(R.detect_cutoff_hz(x[:, :1], 44100) - 16000.0) <= 60.0         # mono, a column
    assert abs(R.detect_cutoff_hz(x[:44100], 44100) - 16000.0) <= 120.0       # one second is enough
    assert abs(R.detect_cutoff_hz(x.astype(np.float64), 44100) - 16000.0) <= 60.0
    quiet = np.concatenate([np.zeros((44100 * 3, 2), np.float32), x, np.zeros((44100 * 3, 2), np.float32)])
    assert abs(R.detect_cutoff_hz(quiet, 44100) - 16000.0) <= 60.0            # silence around the music
    assert abs(R.detect_cutoff_hz(0.001 * x, 44100) - 16000.0) <= 60.0        # a very quiet master
    left_only = x.copy()
    left_only[:, 1] = 0.0
    assert abs(R.detect_cutoff_hz(left_only, 44100) - 16000.0) <= 60.0


def test_silence_and_scraps_never_fail():
    assert R.detect_cutoff_hz(np.zeros((44100, 2), np.float32), 44100) == 22050.0
    assert R.detect_cutoff_hz(np.zeros((10, 2), np.float32), 48000) == 24000.0
    for frames in (1, 100, R.N_FFT - 1, R.N_FFT, R.N_FFT + 1):
        cutoff = R.detect_cutoff_hz(song(1.0, 44100)[:frames], 44100)
        assert 0.0 <= cutoff <= 22050.0 and np.isfinite(cutoff)
    tone = (0.5 * np.sin(2 * np.pi * 100.0 * np.arange(88200) / 44100.0)).astype(np.float32)
    cutoff = R.detect_cutoff_hz(np.stack([tone, tone], axis=1), 44100)  # nothing between 2 and 8 kHz at all
    assert 0.0 <= cutoff <= 22050.0 and np.isfinite(cutoff)
    bad = song(2.0, 44100)
    bad[1000] = np.nan
    assert R.detect_cutoff_hz(bad, 44100) == 22050.0  # not a number: nothing to restore, and no crash


def test_the_test_band_and_the_bench_song_are_full_band():
    from pixl_worker.selftest import synthetic_song

    assert R.detect_cutoff_hz(band_mix(band_stems(4.0, 44100)), 44100) > R.FULL_BAND_HZ
    assert R.detect_cutoff_hz(synthetic_song(10), 44100) > R.FULL_BAND_HZ


def test_a_long_song_is_thinned_not_measured_differently(monkeypatch):
    x = song(20.0, 44100, cut_hz=16000.0, bits=16)
    full = R.detect_cutoff_hz(x, 44100)
    freqs, power = R.long_term_spectrum(x, 44100)
    monkeypatch.setattr(R, "MAX_FRAMES", 40)  # every sixth frame
    thin_freqs, thin_power = R.long_term_spectrum(x, 44100)
    assert np.array_equal(freqs, thin_freqs)
    band = (freqs > 100) & (freqs < 15000)
    assert np.abs(10 * np.log10(thin_power[band] / power[band])).max() < 3.0  # the same spectrum, a bit noisier
    assert abs(R.detect_cutoff_hz(x, 44100) - full) <= 60.0


def test_the_spectrum_of_a_tone_is_at_its_frequency():
    tone = np.sin(2 * np.pi * 3000.0 * np.arange(44100 * 2) / 44100.0).astype(np.float32)
    freqs, power = R.long_term_spectrum(tone, 44100)
    assert freqs[0] == 0.0 and freqs[-1] == 22050.0 and len(freqs) == R.N_FFT // 2 + 1
    assert abs(freqs[int(np.argmax(power))] - 3000.0) <= freqs[1]


# ---- what the worker decides ---------------------------------------------------------------------------

class FakeModel(R.Restorer):
    model_id = "fake-restorer"

    def available(self):
        return True


def test_decide_reports_the_reason_in_the_order_that_keeps_shared_manifests_true():
    none, missing, model = None, R.Restorer(), FakeModel()
    # full band is a fact about the song: it wins over what was asked and over what the worker has
    for mode in ("auto", "off"):
        for restorer in (none, missing, model):
            assert R.decide(20000.0, mode, restorer) == (False, R.RestoreInfo(False, None, "full_band", 20000))
    assert R.decide(17000.4, "auto", model)[1].reason == "full_band" and R.decide(17000.4, "auto", model)[0] is False
    # at or under 17 kHz: the job's own switch, then whether there is a model
    assert R.decide(17000.0, "off", model) == (False, R.RestoreInfo(False, None, "off", 17000))
    assert R.decide(16000.0, "auto", none) == (False, R.RestoreInfo(False, None, "unavailable", 16000))
    assert R.decide(15989.6, "auto", missing) == (False, R.RestoreInfo(False, None, "unavailable", 15990))
    # with a model: run it; until it has run, the record says what stands if it fails
    run, info = R.decide(16000.0, "auto", model)
    assert run is True and info == R.RestoreInfo(False, "fake-restorer", "failed", 16000)
    assert {info.reason, "full_band", "off", "unavailable"} == set(R.REASONS)


def test_restore_info_is_what_the_manifests_carry():
    info = R.RestoreInfo(True, "fake-restorer", None, 15989)
    assert info.as_dict() == {"applied": True, "model": "fake-restorer", "reason": None}
    assert R.RestoreInfo(False, None, "full_band", 20000).as_dict() == {"applied": False, "model": None,
                                                                         "reason": "full_band"}


def test_there_is_no_model_behind_the_seam_yet():
    restorer = R.Restorer()
    assert restorer.model_id is None and restorer.loaded is False and restorer.available() is False
    with pytest.raises(errors.WorkerError) as info:
        restorer.restore(np.zeros((10, 2), np.float32), 44100, 16000.0)
    assert info.value.code == errors.INTERNAL
    assert R.FULL_BAND_HZ == 17000.0
