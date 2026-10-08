"""ffprobe/ffmpeg wrappers. parse_probe is tested on canned ffprobe JSON everywhere; the real-binary tests run
when ffmpeg is installed (the Docker test target installs it)."""

import os
import shutil
import subprocess

import numpy as np
import pytest

from pixl_worker import audio as A
from pixl_worker import errors
from pixl_worker.config import load_caps

CAPS = load_caps({})
HAVE_FFMPEG = shutil.which(A.FFMPEG) is not None and shutil.which(A.FFPROBE) is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")


def probe_json(format_name="mov,mp4,m4a,3gp,3g2,mj2", streams=None, duration="241.0"):
    return {
        "format": {"format_name": format_name, "duration": duration},
        "streams": streams if streams is not None else [
            {"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "channels": 2}],
    }


def test_parse_probe_accepts_m4a_with_cover_art():
    info = A.parse_probe(probe_json(streams=[
        {"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "channels": 2},
        {"codec_type": "video", "codec_name": "mjpeg", "disposition": {"attached_pic": 1}},
        {"codec_type": "data", "codec_name": "bin_data"},
    ]), CAPS)
    assert info.demuxer == "mov" and info.codec == "aac" and info.has_cover and info.sample_rate == 44100


@pytest.mark.parametrize("streams,why", [
    ([{"codec_type": "video", "codec_name": "h264", "disposition": {"attached_pic": 0}},
      {"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "channels": 2}], "video"),
    ([], "no audio"),
    ([{"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100", "channels": 2}] * 2, "two audio"),
    ([{"codec_type": "audio", "codec_name": "dts", "sample_rate": "48000", "channels": 6}], "codec"),
])
def test_parse_probe_rejects(streams, why):
    with pytest.raises(errors.WorkerError) as info:
        A.parse_probe(probe_json(streams=streams), CAPS)
    assert info.value.code == errors.UNSUPPORTED_FORMAT, why


@pytest.mark.parametrize("fmt", ["hls", "concat", "image2", "lavfi"])
def test_parse_probe_rejects_dangerous_demuxers(fmt):
    with pytest.raises(errors.WorkerError) as info:
        A.parse_probe(probe_json(format_name=fmt), CAPS)
    assert info.value.code == errors.UNSUPPORTED_FORMAT


def test_parse_probe_duration_cap():
    with pytest.raises(errors.WorkerError) as info:
        A.parse_probe(probe_json(duration="901.0"), CAPS)
    assert info.value.code == errors.TOO_LONG


def test_pcm_codecs_by_prefix():
    info = A.parse_probe(probe_json(format_name="wav", streams=[
        {"codec_type": "audio", "codec_name": "pcm_s24le", "sample_rate": "48000", "channels": 2}]), CAPS)
    assert info.demuxer == "wav" and info.sample_rate == 48000


def test_resample_and_fit_length():
    x = np.stack([np.linspace(-1, 1, 48000), np.linspace(1, -1, 48000)], axis=1).astype(np.float32)
    y = A.resample(x, 48000, 44100)
    assert abs(y.shape[0] - 44100) <= 1 and y.shape[1] == 2
    assert A.fit_length(y, 44100).shape == (44100, 2)
    assert A.fit_length(y[:100], 150)[120:].sum() == 0
    mono = A.to_mono_16k(x, 48000)
    assert mono.ndim == 1 and abs(mono.shape[0] - 16000) <= 1


def _make(path, args):
    subprocess.run([A.FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", *args, "-y", str(path)],
                   check=True, capture_output=True)


@needs_ffmpeg
def test_real_round_trip_m4a_with_cover(tmp_path):
    cover = tmp_path / "cover.png"
    _make(cover, ["-f", "lavfi", "-i", "color=c=red:s=64x64", "-frames:v", "1"])
    src = tmp_path / "in.m4a"
    _make(src, ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3", "-i", str(cover),
                "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-b:a", "128k", "-c:v", "png",
                "-disposition:v:0", "attached_pic", "-ac", "2"])
    info = A.probe(str(src), CAPS)
    assert info.has_cover and info.codec == "aac" and info.demuxer == "mov"
    mix = A.decode(str(src), info, CAPS, str(tmp_path))
    assert mix.shape[1] == 2
    # edit lists honoured: 3 s of audio, priming removed (within one AAC frame)
    assert abs(mix.shape[0] - 3 * 44100) <= 1024
    out = tmp_path / "out.m4a"
    A.encode(mix, 44100, str(out), codec="aac", kbps=256)
    again = A.decode(str(out), A.probe(str(out), CAPS), CAPS, str(tmp_path))
    assert abs(again.shape[0] - mix.shape[0]) <= 1024
    flac = tmp_path / "out.flac"
    A.encode(mix, 44100, str(flac), codec="flac", kbps=0)
    info_flac = A.probe(str(flac), CAPS)
    assert info_flac.codec == "flac"
    assert A.decode(str(flac), info_flac, CAPS, str(tmp_path)).shape[0] == mix.shape[0]  # FLAC is sample-exact


@needs_ffmpeg
def test_real_48k_flac_keeps_its_rate(tmp_path):
    src = tmp_path / "in.flac"
    _make(src, ["-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=2", "-ac", "2", "-c:a", "flac"])
    info = A.probe(str(src), CAPS)
    assert info.sample_rate == 48000
    assert A.decode(str(src), info, CAPS, str(tmp_path)).shape[0] == 96000


@needs_ffmpeg
def test_real_video_file_is_refused(tmp_path):
    src = tmp_path / "clip.mp4"
    _make(src, ["-f", "lavfi", "-i", "color=c=blue:s=64x64:d=1", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=1", "-c:v", "mpeg4", "-c:a", "aac", "-shortest"])
    with pytest.raises(errors.WorkerError) as info:
        A.probe(str(src), CAPS)
    assert info.value.code == errors.UNSUPPORTED_FORMAT


@needs_ffmpeg
def test_real_hls_playlist_is_refused(tmp_path):
    playlist = tmp_path / "evil.m4a"
    playlist.write_text("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nfile:///etc/passwd\n#EXT-X-ENDLIST\n")
    with pytest.raises(errors.WorkerError) as info:
        A.probe(str(playlist), CAPS)
    assert info.value.code == errors.UNSUPPORTED_FORMAT


@needs_ffmpeg
def test_real_garbage_is_refused(tmp_path):
    junk = tmp_path / "junk.m4a"
    junk.write_bytes(os.urandom(4096))
    with pytest.raises(errors.WorkerError) as info:
        A.probe(str(junk), CAPS)
    assert info.value.code == errors.UNSUPPORTED_FORMAT


def test_ffmpeg_missing_is_internal(monkeypatch, tmp_path):
    monkeypatch.setattr(A, "FFPROBE", str(tmp_path / "no-such-ffprobe"))
    with pytest.raises(errors.WorkerError) as info:
        A.probe(str(tmp_path / "x.m4a"), CAPS)
    assert info.value.code == errors.INTERNAL
