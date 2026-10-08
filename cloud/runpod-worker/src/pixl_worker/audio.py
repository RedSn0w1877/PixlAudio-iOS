"""ffprobe/ffmpeg wrappers (design 2.4 stages 2, 3 and 7).

Safety: ffprobe and ffmpeg only ever see a local file we downloaded, with `-protocol_whitelist file` and a demuxer
allowlist (`-format_whitelist`), so a crafted input can't make them read other files or URLs (no hls, no concat).
Every subprocess uses an argument list (never a shell) and a timeout. Exactly one audio stream is accepted;
cover art (an attached_pic video stream) is ignored, any other video stream is refused, and decoding maps
0:a:0 only.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass

import numpy as np

from .config import Caps
from .errors import DECODE_FAILED, INTERNAL, TOO_LONG, UNSUPPORTED_FORMAT, WorkerError
from .log import redact

FFMPEG = os.environ.get("PIXL_FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("PIXL_FFPROBE", "ffprobe")
BASE = ["-nostdin", "-hide_banner", "-loglevel", "error"]
PROBE_BASE = ["-hide_banner", "-loglevel", "error"]  # ffprobe has no -nostdin
# The sample rates ffmpeg's native AAC encoder takes; any other rate it resamples silently (192 kHz -> 96 kHz).
AAC_SAMPLE_RATES = frozenset((96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350))


@dataclass(frozen=True)
class Probe:
    demuxer: str
    format_name: str
    codec: str
    sample_rate: int
    channels: int
    duration_s: float
    has_cover: bool


def _run(args: list[str], *, timeout: float, what: str, code: str) -> subprocess.CompletedProcess:
    try:
        proc = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise WorkerError(code, f"{what} took longer than {int(timeout)} s") from None
    except FileNotFoundError:
        raise WorkerError(INTERNAL, f"{what}: binary not found") from None
    if proc.returncode != 0:
        lines = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        detail = redact(lines[-1] if lines else "no output")[:200]
        raise WorkerError(code, f"{what} failed ({detail})")
    return proc


def _input_guards(caps: Caps) -> list[str]:
    return ["-protocol_whitelist", "file", "-format_whitelist", ",".join(caps.allowed_formats)]


def probe(path: str, caps: Caps, *, timeout: float = 15.0) -> Probe:
    args = [FFPROBE, *PROBE_BASE, *_input_guards(caps), "-print_format", "json", "-show_format", "-show_streams",
            "-i", path]
    proc = _run(args, timeout=timeout, what="ffprobe", code=UNSUPPORTED_FORMAT)
    try:
        info = json.loads(proc.stdout.decode("utf-8", "replace") or "{}")
    except ValueError:
        raise WorkerError(UNSUPPORTED_FORMAT, "ffprobe returned no usable description") from None
    return parse_probe(info, caps)


def parse_probe(info: dict, caps: Caps) -> Probe:
    fmt = info.get("format") or {}
    format_name = str(fmt.get("format_name") or "")
    names = [n for n in format_name.split(",") if n]
    # The first name is the demuxer ffprobe used; decoding forces it with -f.
    if not names or names[0] not in caps.allowed_formats:
        raise WorkerError(UNSUPPORTED_FORMAT, f"container {format_name or 'unknown'} is not allowed")
    audio, cover = [], False
    for stream in info.get("streams") or []:
        kind = stream.get("codec_type")
        if kind == "audio":
            audio.append(stream)
        elif kind == "video":
            if (stream.get("disposition") or {}).get("attached_pic") == 1:
                cover = True
            else:
                raise WorkerError(UNSUPPORTED_FORMAT, "the file contains a video stream")
        # data/subtitle streams (chapters, timecodes) are ignored: decoding maps 0:a:0 only.
    if len(audio) != 1:
        raise WorkerError(UNSUPPORTED_FORMAT, f"expected exactly one audio stream, found {len(audio)}")
    stream = audio[0]
    codec = str(stream.get("codec_name") or "")
    if not caps.codec_allowed(codec):
        raise WorkerError(UNSUPPORTED_FORMAT, f"codec {codec or 'unknown'} is not allowed")
    try:
        sample_rate = int(stream.get("sample_rate") or 0)
        channels = int(stream.get("channels") or 0)
    except (TypeError, ValueError):
        sample_rate, channels = 0, 0
    if sample_rate < 8000 or sample_rate > 192000 or channels < 1 or channels > 8:
        raise WorkerError(UNSUPPORTED_FORMAT, "unusual sample rate or channel count")
    duration = _float(fmt.get("duration")) or _float(stream.get("duration")) or 0.0
    if duration > caps.max_audio_s:
        raise WorkerError(TOO_LONG, f"the song is longer than {caps.max_audio_s // 60} minutes")
    return Probe(demuxer=names[0], format_name=format_name,
                 codec=codec, sample_rate=sample_rate, channels=channels, duration_s=duration, has_cover=cover)


def _float(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def decode(path: str, info: Probe, caps: Caps, work_dir: str, *, timeout: float = 60.0) -> np.ndarray:
    """Decode the single audio stream to float32 stereo at its own sample rate (edit lists honoured, so AAC
    priming is removed). Returns an array shaped (frames, 2)."""
    raw = os.path.join(work_dir, "decoded.f32")
    args = [FFMPEG, *BASE, *_input_guards(caps), "-f", info.demuxer, "-i", path,
            "-map", "0:a:0", "-vn", "-sn", "-dn", "-ac", "2", "-c:a", "pcm_f32le", "-f", "f32le", "-y", raw]
    _run(args, timeout=timeout, what="ffmpeg decode", code=DECODE_FAILED)
    try:
        data = np.fromfile(raw, dtype="<f4")
    finally:
        try:
            os.remove(raw)
        except OSError:
            pass
    if data.size < 2 or data.size % 2:
        raise WorkerError(DECODE_FAILED, "the decoder produced no audio")
    samples = data.reshape(-1, 2)
    if not np.isfinite(samples).all():
        samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    if samples.shape[0] > (caps.max_audio_s + 1) * info.sample_rate:
        raise WorkerError(TOO_LONG, f"the song is longer than {caps.max_audio_s // 60} minutes")
    return samples


def encode(samples: np.ndarray, sample_rate: int, out_path: str, *, codec: str, kbps: int,
           timeout: float = 60.0) -> None:
    """Encode (frames, 2) float32 to AAC-LC in MP4 (+faststart) or to 16-bit FLAC."""
    raw = out_path + ".f32"
    np.ascontiguousarray(samples, dtype="<f4").tofile(raw)
    try:
        args = [FFMPEG, *BASE, "-f", "f32le", "-ar", str(sample_rate), "-ac", "2", "-i", raw]
        if codec == "aac":
            args += ["-c:a", "aac", "-b:a", f"{int(kbps)}k", "-movflags", "+faststart", "-f", "mp4"]
        else:
            args += ["-c:a", "flac", "-sample_fmt", "s16", "-f", "flac"]
        args += ["-y", out_path]
        _run(args, timeout=timeout, what="ffmpeg encode", code=INTERNAL)
    finally:
        try:
            os.remove(raw)
        except OSError:
            pass


def resample(x: np.ndarray, sr_from: int, sr_to: int) -> np.ndarray:
    """Resample along axis 0. Uses soxr (shipped with librosa) when present, else linear interpolation (tests)."""
    if sr_from == sr_to:
        return x
    try:
        import soxr  # type: ignore

        return soxr.resample(np.ascontiguousarray(x, dtype=np.float32), sr_from, sr_to, quality="HQ").astype(np.float32)
    except ImportError:
        n_out = int(round(x.shape[0] * sr_to / sr_from))
        t_in = np.arange(x.shape[0]) / sr_from
        t_out = np.arange(n_out) / sr_to
        if x.ndim == 1:
            return np.interp(t_out, t_in, x).astype(np.float32)
        return np.stack([np.interp(t_out, t_in, x[:, c]) for c in range(x.shape[1])], axis=1).astype(np.float32)


def fit_length(x: np.ndarray, frames: int) -> np.ndarray:
    """Trim or zero-pad along axis 0 to exactly `frames`."""
    if x.shape[0] == frames:
        return x
    if x.shape[0] > frames:
        return x[:frames]
    pad = np.zeros((frames - x.shape[0],) + x.shape[1:], dtype=x.dtype)
    return np.concatenate([x, pad], axis=0)


def to_mono_16k(x: np.ndarray, sample_rate: int) -> np.ndarray:
    mono = x.mean(axis=1) if x.ndim == 2 else x
    return resample(mono.astype(np.float32), sample_rate, 16000)


def ffmpeg_version() -> str | None:
    try:
        out = subprocess.run([FFMPEG, "-hide_banner", "-version"], capture_output=True, timeout=10).stdout
        first = out.decode("utf-8", "replace").splitlines()[0]
        return first.split()[2] if first.startswith("ffmpeg version") else first[:60]
    except Exception:
        return None
