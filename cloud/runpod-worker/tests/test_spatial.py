"""What every spatial render promises, whatever the rooms are tuned to (cloud-audio-spec.md, sections 3.1, 5 and 8):
the source's length and timeline, a loudness exactly the headroom under the source, a true peak under the ceiling,
left and right in balance for a mirrored song, silence for silence, a render without stems, the same output every
time. Short synthetic signals, NumPy only. No output value is pinned: the profiles are still being tuned."""

import numpy as np
import pytest

from conftest import band_mix, band_stems
from pixl_worker.spatial import (CEILING_DB, ENGINE_ID, HEADROOM_DB, PROFILE_IDS, PROFILES, STEM_NAMES, SpatialResult,
                                 render_profiles)
from pixl_worker.spatial.loudness import integrated_lufs, true_peak_db

LOUDNESS_TOLERANCE_LU = 0.3
PEAK_TOLERANCE_DB = 0.05
BALANCE_TOLERANCE_DB = 0.6
SECONDS = 5.0  # long enough for Night's slow leveller to engage (it needs 4 s)


def level_db(x) -> float:
    return 10.0 * np.log10(max(float(np.mean(np.asarray(x, dtype=np.float64) ** 2)), 1e-20))


def balance_db(audio) -> float:
    """Left minus right, in dB of energy."""
    return level_db(audio[:, 0]) - level_db(audio[:, 1])


def shaped_noise(frames: int, sample_rate: int, seed: int) -> np.ndarray:
    """Noise with a pink-like spectrum. Every seed has exactly the same magnitude spectrum, only other phases, so
    two of them are each other's mirror image in everything but the waveform."""
    rng = np.random.default_rng(seed)
    freqs = np.fft.rfftfreq(frames, 1.0 / sample_rate)
    magnitude = np.where(freqs >= 60.0, (np.maximum(freqs, 60.0) / 1000.0) ** -0.5, 0.0)
    x = np.fft.irfft(magnitude * np.exp(2j * np.pi * rng.random(len(freqs))), frames)
    return (x / np.sqrt(np.mean(x ** 2))).astype(np.float32)


def mirrored_band(seconds: float, sample_rate: int, seed: int = 11) -> dict:
    """A band whose right half is the mirror image of its left half: a centred voice and bass, a guitar on the
    left with its twin (the piano) on the right, and a wide pad built the same way."""
    frames = int(seconds * sample_rate)
    centre = 0.07 * shaped_noise(frames, sample_rate, seed)
    a = 0.05 * shaped_noise(frames, sample_rate, seed + 1)
    b = 0.05 * shaped_noise(frames, sample_rate, seed + 2)
    bass = (0.1 * np.sin(2 * np.pi * 60.0 * np.arange(frames) / sample_rate)).astype(np.float32)
    stems = {"vocals": np.stack([centre, centre], axis=1), "bass": np.stack([bass, bass], axis=1),
             "guitar": np.stack([a, 0.25 * a], axis=1), "piano": np.stack([0.25 * b, b], axis=1),
             "other": np.stack([0.5 * b + 0.2 * centre, 0.5 * a + 0.2 * centre], axis=1)}
    return {name: stem.astype(np.float32) for name, stem in stems.items()}


@pytest.fixture(scope="module")
def band():
    stems = band_stems(SECONDS, 44100)
    return stems, band_mix(stems)


@pytest.fixture(scope="module")
def rendered(band):
    """All six profiles of the test band at 44.1 kHz, rendered once: (results, the progress calls)."""
    stems, mix = band
    calls = []
    results = render_profiles(mix, stems, 44100, PROFILE_IDS, progress=lambda done, total: calls.append((done, total)))
    return results, calls


def check_promises(result: SpatialResult, mix: np.ndarray, sample_rate: int, *, limited: bool = False) -> None:
    audio = result.audio
    assert audio.shape == mix.shape and audio.dtype == np.float32  # the source's frame count: no added delay
    assert np.isfinite(audio).all() and np.abs(audio).max() <= 1.0
    # the numbers the manifest will carry are the file's own
    assert result.integrated_lufs == pytest.approx(integrated_lufs(audio, sample_rate), abs=1e-6)
    assert result.true_peak_db == pytest.approx(true_peak_db(audio), abs=1e-6)
    assert result.source_lufs == pytest.approx(integrated_lufs(mix, sample_rate), abs=1e-6)
    assert result.true_peak_db <= CEILING_DB + PEAK_TOLERANCE_DB
    assert result.limiter_max_db >= 0.0
    if not limited:  # a limiter that had to work is allowed to cost a little level; an idle one is not
        assert abs(result.source_lufs - HEADROOM_DB - result.integrated_lufs) <= LOUDNESS_TOLERANCE_LU


def test_the_interface_of_the_spec():
    assert PROFILE_IDS == ("studio", "wide", "intimate", "hall", "surround", "night")
    assert tuple(PROFILES) == PROFILE_IDS and PROFILES["hall"].name == "Concert Hall"
    assert ENGINE_ID == "pixl-spatial-1" and HEADROOM_DB == 4.0 and CEILING_DB == -1.0
    assert STEM_NAMES == ("vocals", "drums", "bass", "guitar", "piano", "other")


def test_every_profile_keeps_the_promises(rendered, band):
    results, _ = rendered
    _, mix = band
    assert list(results) == list(PROFILE_IDS)
    for profile, result in results.items():
        check_promises(result, mix, 44100)
        assert result.stem_mode == "stems6", profile
        assert result.limiter_max_db == 0.0, profile  # a quiet mix never needs the limiter
        assert abs(result.source_lufs - HEADROOM_DB - result.integrated_lufs) <= 0.05, profile


def test_the_profiles_are_different_renders(rendered):
    results, _ = rendered
    for a in PROFILE_IDS:
        for b in PROFILE_IDS:
            if a < b:
                assert not np.array_equal(results[a].audio, results[b].audio), (a, b)


def test_progress_counts_up_to_its_total(rendered):
    _, calls = rendered
    totals = {total for _, total in calls}
    dones = [done for done, _ in calls]
    assert len(totals) == 1 and dones == sorted(dones) and dones[-1] == max(totals)
    assert len(calls) >= 1 + len(PROFILE_IDS)  # after the preparation, and after each profile at least


def test_an_exception_from_progress_stops_the_render(band):
    stems, mix = band

    class OutOfTime(Exception):
        pass

    def progress(done, total):
        raise OutOfTime()

    with pytest.raises(OutOfTime):  # how the job's deadline reaches into the renderer
        render_profiles(mix[:44100], {}, 44100, ["studio", "wide"], progress=progress)


def test_48_khz_keeps_the_promises():
    stems = band_stems(SECONDS, 48000)
    mix = band_mix(stems)
    for profile, result in render_profiles(mix, stems, 48000, ["studio", "hall", "night"]).items():
        check_promises(result, mix, 48000)
        assert result.audio.shape == (240000, 2) and result.stem_mode == "stems6", profile


def test_a_louder_mix_is_held_under_the_ceiling(band):
    stems, _ = band
    loud = {name: (2.0 * stem[:4 * 44100]).astype(np.float32) for name, stem in stems.items()}  # peaks over full scale
    mix = band_mix(loud)
    results = render_profiles(mix, loud, 44100, ["studio", "intimate", "surround"])
    for result in results.values():
        check_promises(result, mix, 44100, limited=result.limiter_max_db > 0.0)
        assert abs(result.source_lufs - HEADROOM_DB - result.integrated_lufs) <= LOUDNESS_TOLERANCE_LU
    assert any(result.limiter_max_db > 0.0 for result in results.values())  # the limiter did work somewhere


@pytest.mark.xfail(strict=False, reason="measured 2026-11-11: when the limiter has to take off more than about "
                   "3.5 dB its three passes leave the true peak up to 0.8 dB over the ceiling (a clipped -6 LUFS "
                   "brick at 48 kHz: -0.18 to -0.8 dBTP). Real masters need 0-2 dB and stay at -1.00. The renderer "
                   "is the lead's: reported, not changed here.")
def test_a_brick_of_a_master_is_held_under_the_ceiling_too():
    stems = {name: np.clip(6.0 * stem, -1.0, 1.0) for name, stem in band_stems(3.0, 48000).items()}
    mix = np.clip(band_mix(stems), -1.0, 1.0)
    result = render_profiles(mix, stems, 48000, ["intimate"])["intimate"]
    assert np.abs(result.audio).max() <= 1.0
    assert result.true_peak_db <= CEILING_DB + PEAK_TOLERANCE_DB


def test_the_stem_free_render(band):
    _, mix = band
    for result in render_profiles(mix, {}, 44100, ["studio", "surround"]).values():
        check_promises(result, mix, 44100)
        assert result.stem_mode == "mix"


def test_stem_modes(band):
    stems, mix = band
    seconds2 = slice(0, 2 * 44100)
    short = {name: stem[seconds2] for name, stem in stems.items()}
    short_mix = mix[seconds2]

    def mode(given):
        return render_profiles(short_mix, given, 44100, ["studio"])["studio"].stem_mode

    assert mode(short) == "stems6"
    four = {name: short[name] for name in ("vocals", "drums", "bass")}
    four["other"] = short["other"] + short["guitar"] + short["piano"]
    assert mode(four) == "stems4"
    # A few quiet parts missing: what the stems do not add up to becomes "other", and the stems are still used.
    assert mode({name: short[name] for name in ("vocals", "drums", "bass", "guitar")}) == "stems6"
    assert mode({name: short[name] for name in ("vocals", "drums", "bass")}) == "stems4"
    # Stems that miss most of the mix, or do not belong to it, are not trusted: the render is made from the mix.
    assert mode({"vocals": short["vocals"]}) == "mix"
    assert mode({name: np.roll(stem, 7001, axis=0) * 3.0 for name, stem in short.items()}) == "mix"
    assert mode({}) == "mix" and mode({"vocals": None}) == "mix" and mode({"strings": short["other"]}) == "mix"
    # A stem of another length is ignored, exactly as if it had not been given.
    odd = dict(short, other=short["other"][:-1])
    without = {name: stem for name, stem in short.items() if name != "other"}
    assert np.array_equal(render_profiles(short_mix, odd, 44100, ["studio"])["studio"].audio,
                          render_profiles(short_mix, without, 44100, ["studio"])["studio"].audio)


def test_stems_that_do_not_add_up_are_completed_not_lost(band):
    stems, mix = band
    part = {"vocals": stems["vocals"][:88200], "bass": stems["bass"][:88200]}  # drums, guitar, piano, pad missing
    short_mix = mix[:88200]
    result = render_profiles(short_mix, part, 44100, ["studio"])["studio"]
    check_promises(result, short_mix, 44100)  # the level still matches the whole song, not two stems of it
    assert result.stem_mode == "stems4"


def test_silence_in_gives_silence_out():
    silence = np.zeros((44100, 2), dtype=np.float32)
    for stems in ({}, {name: silence for name in STEM_NAMES}):
        for profile, result in render_profiles(silence, stems, 44100, ["studio", "hall"]).items():
            assert result.audio.shape == silence.shape and not result.audio.any(), profile
            assert result.limiter_max_db == 0.0 and result.integrated_lufs <= -69.0


def test_a_song_that_ends_in_silence_keeps_its_length_and_stays_quiet_there(band):
    stems, mix = band
    tail = int(1.5 * 44100)
    padded = np.concatenate([mix[:88200], np.zeros((tail, 2), np.float32)])
    padded_stems = {name: np.concatenate([stem[:88200], np.zeros((tail, 2), np.float32)])
                    for name, stem in stems.items()}
    result = render_profiles(padded, padded_stems, 44100, ["studio"])["studio"]
    assert result.audio.shape == padded.shape
    assert result.audio[-1].tolist() == [0.0, 0.0]  # every render ends on digital silence
    # a room rings on after the music stops, but far below it
    assert level_db(result.audio[-tail // 2:]) < level_db(result.audio[:88200]) - 20.0


def test_the_same_input_gives_the_same_output(band):
    stems, mix = band
    short = {name: stem[:88200] for name, stem in stems.items()}
    first = render_profiles(mix[:88200], short, 44100, ["wide", "night"])
    again = render_profiles(mix[:88200].copy(), {name: stem.copy() for name, stem in short.items()}, 44100,
                            ["night", "wide"])
    for profile in ("wide", "night"):
        assert np.array_equal(first[profile].audio, again[profile].audio), profile
        assert first[profile].integrated_lufs == again[profile].integrated_lufs
    # one profile alone is the same render as that profile among others
    alone = render_profiles(mix[:88200], short, 44100, ["night"])["night"]
    assert np.array_equal(alone.audio, first["night"].audio)


def test_the_inputs_are_left_as_they_were(band):
    stems, mix = band
    short = {name: stem[:66150].copy() for name, stem in stems.items()}
    short_mix = mix[:66150].copy()
    before = {name: stem.copy() for name, stem in short.items()}
    render_profiles(short_mix, short, 44100, ["intimate"])
    assert np.array_equal(short_mix, mix[:66150]) and sorted(short) == sorted(before)
    for name in before:
        assert np.array_equal(short[name], before[name]), name


@pytest.mark.parametrize("sample_rate, with_stems", [(44100, True), (44100, False), (48000, True)])
def test_a_mirrored_song_stays_in_balance(sample_rate, with_stems):
    stems = mirrored_band(4.0, sample_rate)
    mix = band_mix(stems)
    assert abs(balance_db(mix)) < 0.05  # the song itself is balanced
    for profile, result in render_profiles(mix, stems if with_stems else {}, sample_rate, PROFILE_IDS).items():
        # The rooms are not symmetric on purpose, so the two ears are not mirror images, sample for sample.
        # Their energy is what has to stay level.
        assert abs(balance_db(result.audio)) <= BALANCE_TOLERANCE_DB, profile


def test_a_song_on_one_side_stays_on_that_side(band):
    stems, _ = band
    left_only = {"guitar": np.stack([stems["guitar"][:88200, 0], np.zeros(88200, np.float32)], axis=1)}
    mix = band_mix(left_only)
    result = render_profiles(mix, left_only, 44100, ["studio"])["studio"]
    assert balance_db(result.audio) > 3.0  # louder in the left ear, as a speaker on the left would be
    mirrored = render_profiles(mix[:, ::-1].copy(), {"guitar": left_only["guitar"][:, ::-1].copy()}, 44100,
                               ["studio"])["studio"]
    assert balance_db(mirrored.audio) < -3.0


def test_unknown_profiles_and_rates_are_refused(band):
    stems, mix = band
    with pytest.raises(ValueError, match="unknown profile"):
        render_profiles(mix, stems, 44100, ["studio", "cinema"])
    with pytest.raises(ValueError):
        render_profiles(mix, stems, 32000, ["studio"])  # other rates go through library.render
    with pytest.raises(ValueError):
        render_profiles(mix[:, 0], {}, 44100, ["studio"])
    assert render_profiles(mix[:4410], {}, 44100, []) == {}


@pytest.mark.parametrize("frames", [1, 100, 4095, 4097, 44101])
def test_very_short_and_odd_lengths(frames):
    x = (0.1 * np.random.default_rng(1).standard_normal((frames, 2))).astype(np.float32)
    result = render_profiles(x, {}, 44100, ["studio"])["studio"]
    assert result.audio.shape == (frames, 2) and np.isfinite(result.audio).all()
    assert result.true_peak_db <= CEILING_DB + PEAK_TOLERANCE_DB
