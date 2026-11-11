"""library.py: the shared library's keys, the render manifest (against its schema and the golden examples), the
"is it already there" test, FLAC 16-bit with TPDF dither, and rendering at sample rates the renderer does not work
at. The FLAC tests need ffmpeg (the Docker test target installs it)."""

import copy
import shutil
import subprocess

import jsonschema
import numpy as np
import pytest

from conftest import band_mix, band_stems, load_example, load_schema
from pixl_worker import audio as A
from pixl_worker import library as L
from pixl_worker.spatial import CEILING_DB, HEADROOM_DB, PROFILE_IDS
from pixl_worker.spatial.loudness import integrated_lufs, true_peak_db

HAVE_FFMPEG = shutil.which(A.FFMPEG) is not None and shutil.which(A.FFPROBE) is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")
MANIFEST = jsonschema.Draft202012Validator(load_schema("library.render"))
VIDEO = "J7p4bzqLvCw"
WORKER = {"version": "1.1.0", "gitSha": "abcdef012345", "gpu": "Fake GPU", "vramGB": 16.0, "cuda": "12.8"}


# ---- keys and slots ----------------------------------------------------------------------------------------

def test_keys_follow_the_layout_of_the_spec():
    assert L.render_slot("studio") == "sp-studio"
    assert L.audio_key(VIDEO, "sp-studio") == "lib/v1/J7p4bzqLvCw/sp-studio.flac"
    assert L.manifest_key(VIDEO, "sp-studio") == "lib/v1/J7p4bzqLvCw/sp-studio.json"
    assert L.audio_key(VIDEO, L.ENHANCED) == "lib/v1/J7p4bzqLvCw/enhanced.flac"
    assert L.manifest_key(VIDEO, L.ENHANCED) == "lib/v1/J7p4bzqLvCw/enhanced.json"
    assert [L.slot_kind(L.render_slot(p)) for p in PROFILE_IDS] == [("spatial", p) for p in PROFILE_IDS]
    assert L.slot_kind("enhanced") == ("enhanced", None)
    for bad in ("sp-cinema", "studio", "sp-", "instrumental", ""):
        with pytest.raises(ValueError):
            L.slot_kind(bad)


def test_a_new_library_version_moves_every_key(monkeypatch):
    monkeypatch.setattr(L, "LIB_V", 2)
    assert L.audio_key(VIDEO, "sp-hall") == "lib/v2/J7p4bzqLvCw/sp-hall.flac"
    assert L.manifest_key(VIDEO, "enhanced") == "lib/v2/J7p4bzqLvCw/enhanced.json"
    # ... and a render made for the older version is no longer "already there"
    assert not L.manifest_matches(load_example("library.render.spatial.json"), video_id=VIDEO, slot="sp-studio")


# ---- manifests ---------------------------------------------------------------------------------------------

def spatial_manifest():
    example = load_example("library.render.spatial.json")
    audio, loud = example["audio"], example["loudness"]
    return L.render_manifest(
        video_id=VIDEO, slot="sp-studio",
        audio=L.audio_block(audio["key"], audio["bytes"], audio["sha256"], audio["sampleRate"], audio["samples"]),
        loudness=L.loudness_block(loud["integratedLufs"], loud["sourceLufs"], HEADROOM_DB, loud["truePeakDb"],
                                  loud["limiterMaxDb"]),
        source=example["source"], engine=L.ENGINE_ID, stems="open-cascade-6", stem_mode="stems6",
        restore={"applied": False, "model": None, "reason": "full_band"}, worker=WORKER,
        created_at=example["createdAt"])


def test_the_worker_builds_exactly_the_spatial_example():
    doc = spatial_manifest()
    MANIFEST.validate(doc)
    assert doc == load_example("library.render.spatial.json")
    assert doc["loudness"]["headroomDb"] == HEADROOM_DB == 4.0  # from the renderer, not typed in again
    assert doc["audio"]["durationMs"] == 202000 and doc["audio"]["bits"] == 16 and doc["audio"]["codec"] == "flac"
    assert doc["worker"] == {"version": "1.1.0", "gitSha": "abcdef012345"}  # no GPU details in a shared file


def test_the_worker_builds_exactly_the_nothing_to_restore_example():
    example = load_example("library.render.enhanced.none.json")
    doc = L.render_manifest(video_id=VIDEO, slot="enhanced", audio=None, loudness=None, source=example["source"],
                            engine=None, stems=None, stem_mode=None,
                            restore={"applied": False, "model": None, "reason": "full_band"}, worker=WORKER,
                            created_at=example["createdAt"])
    MANIFEST.validate(doc)
    assert doc == example and doc["kind"] == "enhanced" and doc["profile"] is None


def test_created_at_is_utc_iso_8601():
    assert L.utc_now(0) == "1970-01-01T00:00:00Z"
    assert L.utc_now(1794337331) == "2026-11-10T19:02:11Z"
    doc = L.render_manifest(video_id=VIDEO, slot="enhanced", audio=None, loudness=None,
                            source=load_example("library.render.enhanced.none.json")["source"], engine=None,
                            stems=None, stem_mode=None,
                            restore={"applied": False, "model": None, "reason": "unavailable"}, worker=WORKER)
    MANIFEST.validate(doc)  # createdAt filled in from the clock


def test_loudness_block_rounds_to_hundredths():
    block = L.loudness_block(-13.8249, np.float32(-9.8151), 4.0, -1.0004, 0.6349)
    assert block == {"integratedLufs": -13.82, "sourceLufs": -9.82, "headroomDb": 4.0, "truePeakDb": -1.0,
                     "limiterMaxDb": 0.63}
    assert all(type(v) is float for v in block.values())


def test_manifest_matches_only_the_render_that_was_asked_for():
    spatial = load_example("library.render.spatial.json")
    nothing = load_example("library.render.enhanced.none.json")
    restored = load_example("library.render.enhanced.json")
    assert L.manifest_matches(spatial, video_id=VIDEO, slot="sp-studio")
    assert L.manifest_matches(nothing, video_id=VIDEO, slot="enhanced")
    assert L.manifest_matches(restored, video_id="ZD6rXLXZOEI", slot="enhanced")
    # another slot, another video
    assert not L.manifest_matches(spatial, video_id=VIDEO, slot="sp-wide")
    assert not L.manifest_matches(spatial, video_id=VIDEO, slot="enhanced")
    assert not L.manifest_matches(spatial, video_id="ZD6rXLXZOEI", slot="sp-studio")
    assert not L.manifest_matches(nothing, video_id=VIDEO, slot="sp-studio")
    # not a manifest at all
    for junk in (None, [], "x", 5, {}, {"schema": "pixl.library.render"}, load_example("job.result.spatial.json")):
        assert not L.manifest_matches(junk, video_id=VIDEO, slot="sp-studio")

    def changed(doc, path, value):
        doc = copy.deepcopy(doc)
        target = doc
        for key in path[:-1]:
            target = target[key]
        if value is KeyError:
            del target[path[-1]]
        else:
            target[path[-1]] = value
        return doc

    for path, value in [
        (["schema"], "pixl.cloudstudio.result"), (["v"], 2), (["v"], True), (["v"], "1"), (["v"], KeyError),
        (["libV"], 2), (["libV"], True), (["libV"], 1.5), (["libV"], KeyError), (["videoId"], VIDEO.lower()),
        (["kind"], "enhanced"), (["profile"], "wide"), (["profile"], None),
        # a spatial manifest a phone could not use must not stop the render from being made
        (["audio"], None), (["audio"], "x"), (["audio"], KeyError),
        (["audio", "key"], "lib/v1/J7p4bzqLvCw/sp-wide.flac"), (["audio", "key"], KeyError),
        (["audio", "bytes"], 0), (["audio", "bytes"], "27100200"), (["audio", "bytes"], True),
        (["audio", "sha256"], "abc"), (["audio", "sha256"], None), (["audio", "sampleRate"], 0),
        (["audio", "samples"], -1), (["audio", "samples"], 1.5),
    ]:
        assert not L.manifest_matches(changed(spatial, path, value), video_id=VIDEO, slot="sp-studio"), (path, value)
    # things the worker does not look at do not matter: a manifest from a later worker still counts
    for path, value in [(["worker"], {"version": "9.9.9"}), (["loudness"], None), (["render"], {}),
                        (["createdAt"], "later"), (["future"], [1])]:
        assert L.manifest_matches(changed(spatial, path, value), video_id=VIDEO, slot="sp-studio"), path
    # enhanced: with or without audio; a broken audio block is not accepted either
    assert not L.manifest_matches(changed(restored, ["audio", "key"], "lib/v1/ZD6rXLXZOEI/sp-studio.flac"),
                                  video_id="ZD6rXLXZOEI", slot="enhanced")
    assert not L.manifest_matches(changed(nothing, ["profile"], "studio"), video_id=VIDEO, slot="enhanced")


def test_existing_output_is_the_entry_a_phone_downloads_from():
    spatial = load_example("library.render.spatial.json")
    entry = L.existing_output(spatial)
    assert entry == load_example("job.result.spatial.exists.json")["outputs"]["sp-studio"]
    assert entry == L.output_entry("lib/v1/J7p4bzqLvCw/sp-studio.flac", 27100200, spatial["audio"]["sha256"], 48000,
                                   9696000)
    assert entry["codec"] == "flac" and entry["kbps"] is None
    assert L.existing_output(load_example("library.render.enhanced.none.json")) is None


# ---- 16 bits with TPDF dither ------------------------------------------------------------------------------

def test_dither_is_triangular_and_independent_of_the_signal():
    # The point of TPDF dither: the error of the 16-bit sample has zero mean and the SAME power whatever the
    # value was (0.25 LSB^2: 1/12 from rounding plus 1/6 from the dither). Without dither both depend on it.
    rng = np.random.default_rng(1)
    for offset in (0.0, 0.1, 0.25, 0.5, 0.77):
        value = (1000.0 + offset) / 32768.0
        pcm = L.dither_to_int16(np.full((200_000, 2), value, dtype=np.float32), rng).astype(np.float64)
        error = pcm - (1000.0 + offset)
        assert abs(error.mean()) < 0.01, offset
        assert error.var() == pytest.approx(0.25, abs=0.01), offset
        assert set(np.unique(pcm)) <= {999.0, 1000.0, 1001.0, 1002.0}
    # triangular: the noise itself spans (-1, 1) LSB with variance 1/6, and the channels are independent
    noise = L.dither_to_int16(np.zeros((400_000, 2), dtype=np.float32), rng).astype(np.float64)
    assert set(np.unique(noise)) == {-1.0, 0.0, 1.0}
    assert (noise == 0).mean() == pytest.approx(0.75, abs=0.01)  # P(|u1 - u2| < 0.5)
    assert abs(np.corrcoef(noise[:, 0], noise[:, 1])[0, 1]) < 0.01


def test_dither_keeps_full_scale_inside_16_bits_and_is_repeatable():
    x = np.array([[1.0, -1.0], [2.0, -2.0], [0.99999, -0.99999], [0.0, 0.5]], dtype=np.float32)
    a = L.dither_to_int16(x, np.random.default_rng(L.DITHER_SEED))
    b = L.dither_to_int16(x, np.random.default_rng(L.DITHER_SEED))
    assert a.dtype == np.dtype("<i2") and np.array_equal(a, b)
    assert a[0, 0] == 32767 and a[1, 0] == 32767 and a[1, 1] == -32768 and a.min() >= -32768
    assert abs(int(a[3, 1]) - 16384) <= 1
    assert x.dtype == np.float32 and x[0, 0] == 1.0  # the input is not touched


def _decode_s16(path, channels=2):
    out = subprocess.run([A.FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "s16le",
                          "-c:a", "pcm_s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(out, dtype="<i2").reshape(-1, channels)


def _stream(path):
    import json

    out = subprocess.run([A.FFPROBE, "-v", "error", "-select_streams", "a:0", "-show_entries",
                          "stream=codec_name,sample_rate,channels,bits_per_raw_sample,sample_fmt", "-of", "json",
                          str(path)], capture_output=True, check=True).stdout
    return json.loads(out)["streams"][0]


@needs_ffmpeg
@pytest.mark.parametrize("rate, frames", [(44100, 44100 * 2 + 17), (48000, 48000), (32000, 1), (96000, 5000)])
def test_flac_holds_exactly_the_dithered_samples(tmp_path, monkeypatch, rate, frames):
    monkeypatch.setattr(L, "_DITHER_CHUNK", 30_000)  # several chunks: the dither must run on across them
    rng = np.random.default_rng(3)
    audio = np.clip(0.3 * rng.standard_normal((frames, 2)), -0.95, 0.95).astype(np.float32)
    audio[: frames // 3] = 0.0  # digital silence in: dither noise out, never a longer or shorter file
    path = tmp_path / "sp-studio.flac"
    L.encode_flac16(audio, rate, str(path))
    assert path.read_bytes()[:4] == b"fLaC" and not (tmp_path / "sp-studio.flac.s16").exists()
    stream = _stream(path)
    assert stream["codec_name"] == "flac" and int(stream["sample_rate"]) == rate and stream["channels"] == 2
    assert stream["sample_fmt"] == "s16" and stream.get("bits_per_raw_sample", "16") == "16"
    decoded = _decode_s16(path)
    assert decoded.shape == (frames, 2)  # the source's frame count, to the sample
    expected_rng = np.random.default_rng(L.DITHER_SEED)
    expected = np.concatenate([L.dither_to_int16(audio[i:i + 30_000], expected_rng)
                               for i in range(0, frames, 30_000)])
    assert np.array_equal(decoded, expected)  # ffmpeg packed our samples bit for bit: no second conversion
    error = decoded.astype(np.float64) - audio.astype(np.float64) * 32768.0
    assert np.abs(error).max() <= 1.5 + 1e-3
    # the same render becomes the same file, byte for byte
    again = tmp_path / "again.flac"
    L.encode_flac16(audio.copy(), rate, str(again))
    assert again.read_bytes() == path.read_bytes()


@needs_ffmpeg
def test_the_stem_encoder_is_unchanged_and_undithered(tmp_path):
    # audio.encode (instrumental and the other stems) keeps letting ffmpeg convert: a constant stays a constant.
    audio = np.full((4410, 2), 1000.4 / 32768.0, dtype=np.float32)
    path = tmp_path / "instrumental.flac"
    A.encode(audio, 44100, str(path), codec="flac", kbps=0)
    assert set(np.unique(_decode_s16(path))) == {1000}
    dithered = tmp_path / "sp-night.flac"
    L.encode_flac16(audio, 44100, str(dithered))
    assert set(np.unique(_decode_s16(dithered))) <= {999, 1000, 1001, 1002} and len(np.unique(_decode_s16(dithered))) > 1


@needs_ffmpeg
def test_flac_encoder_failures_are_worker_errors_and_leave_no_raw_file(tmp_path, monkeypatch):
    from pixl_worker import errors

    with pytest.raises(ValueError):
        L.encode_flac16(np.zeros((0, 2), np.float32), 44100, str(tmp_path / "empty.flac"))
    with pytest.raises(ValueError):
        L.encode_flac16(np.zeros(100, np.float32), 44100, str(tmp_path / "mono.flac"))
    monkeypatch.setattr(A, "FFMPEG", str(tmp_path / "no-such-ffmpeg"))
    with pytest.raises(errors.WorkerError) as info:
        L.encode_flac16(np.zeros((100, 2), np.float32), 44100, str(tmp_path / "x.flac"))
    assert info.value.code == errors.INTERNAL
    assert list(tmp_path.iterdir()) == []


# ---- the renderer at any sample rate -----------------------------------------------------------------------

def test_supported_rates_go_straight_to_the_renderer(monkeypatch):
    seen = []

    def fake(mix, stems, sample_rate, profiles, progress=None):
        seen.append((mix, stems, sample_rate, list(profiles), progress))
        return {"studio": "result"}

    monkeypatch.setattr(L, "render_profiles", fake)
    mix, stems, progress = np.zeros((10, 2), np.float32), {"vocals": np.zeros((10, 2), np.float32)}, lambda d, t: None
    for rate in (44100, 48000):
        assert L.render(mix, stems, rate, ["studio"], progress) == {"studio": "result"}
        assert seen[-1][0] is mix and seen[-1][1] is stems and seen[-1][2] == rate and seen[-1][4] is progress


@pytest.mark.parametrize("rate", [32000, 22050, 96000])
def test_other_rates_are_rendered_at_48k_and_come_back_at_their_own(rate):
    stems = band_stems(4.0, rate)
    mix = band_mix(stems)
    calls = []
    results = L.render(mix, stems, rate, ["studio", "hall"], progress=lambda done, total: calls.append((done, total)))
    assert list(results) == ["studio", "hall"] and calls[-1] == (22, 22)
    source = integrated_lufs(mix, rate)
    for result in results.values():
        assert result.audio.shape == mix.shape and result.audio.dtype == np.float32  # the source's timeline
        assert np.isfinite(result.audio).all() and np.abs(result.audio).max() <= 1.0
        assert result.stem_mode == "stems6"
        # the numbers in the manifest describe the file at its own rate, against the song at its own rate
        assert result.source_lufs == pytest.approx(source, abs=1e-6)
        assert result.integrated_lufs == pytest.approx(integrated_lufs(result.audio, rate), abs=1e-6)
        assert abs(result.source_lufs - HEADROOM_DB - result.integrated_lufs) <= 0.3
        assert result.true_peak_db == pytest.approx(true_peak_db(result.audio), abs=1e-6)
        assert result.true_peak_db <= CEILING_DB + 0.05
    assert not np.array_equal(results["studio"].audio, results["hall"].audio)


def test_other_rates_render_from_the_mix_when_there_are_no_stems_and_keep_silence_silent():
    stems = band_stems(3.0, 32000)
    result = L.render(band_mix(stems), {}, 32000, ["studio"])["studio"]
    assert result.stem_mode == "mix" and result.audio.shape == (96000, 2)
    silent = L.render(np.zeros((16000, 2), np.float32), {"vocals": np.zeros((16000, 2), np.float32)}, 16000,
                      ["night"])["night"]
    assert silent.audio.shape == (16000, 2) and not silent.audio.any()


def test_a_hot_song_at_another_rate_still_ends_under_the_ceiling():
    stems = {name: np.clip(6.0 * stem, -1.0, 1.0) for name, stem in band_stems(4.0, 32000).items()}
    mix = np.clip(band_mix(stems), -1.0, 1.0)  # a brick of a master: clipped, about -6 LUFS
    result = L.render(mix, stems, 32000, ["studio"])["studio"]
    assert result.limiter_max_db > 0.0 and result.true_peak_db <= CEILING_DB + 0.05
    assert np.abs(result.audio).max() <= 1.0 and result.audio.shape == mix.shape
