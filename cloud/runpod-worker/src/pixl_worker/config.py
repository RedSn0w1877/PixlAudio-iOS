"""Server-side safety caps (design 2.4). Read from the environment once per process; the app cannot raise them."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

DEFAULT_FORMATS = ("mov", "mp4", "m4a", "3gp", "3g2", "mj2", "mp3", "flac", "wav", "ogg", "matroska", "webm", "aac")
DEFAULT_CODECS = ("aac", "mp3", "mp3float", "flac", "alac", "opus", "libopus", "vorbis", "libvorbis")
# pcm_* is allowed by prefix (see Caps.codec_allowed).


def _int(env: dict, name: str, default: int, lo: int, hi: int) -> int:
    raw = env.get(name)
    if raw is None or str(raw).strip() == "":
        return default
    try:
        value = int(str(raw).strip())
    except ValueError:
        return default
    return max(lo, min(hi, value))


def _list(env: dict, name: str, default: tuple[str, ...]) -> tuple[str, ...]:
    raw = env.get(name)
    if raw is None or str(raw).strip() == "":
        return default
    return tuple(p.strip().lower() for p in str(raw).split(",") if p.strip())


@dataclass(frozen=True)
class Caps:
    max_input_mb: int = 60
    max_audio_s: int = 900
    best_max_audio_s: int = 480
    max_lyrics_lines: int = 500
    max_lyrics_chars: int = 20000
    max_body_kb: int = 256
    execution_timeout_s: int = 900
    deadline_margin_s: int = 30
    allowed_host_suffixes: tuple[str, ...] = ()
    allowed_formats: tuple[str, ...] = DEFAULT_FORMATS
    allowed_codecs: tuple[str, ...] = DEFAULT_CODECS
    allow_crash_test: bool = False
    tmp_root: str = "/tmp/pixl"
    volume_root: str = "/runpod-volume"
    extra: dict = field(default_factory=dict)

    @property
    def max_input_bytes(self) -> int:
        return self.max_input_mb * 1024 * 1024

    def codec_allowed(self, codec: str) -> bool:
        codec = (codec or "").lower()
        return codec in self.allowed_codecs or codec.startswith("pcm_")

    def host_allowed(self, host: str) -> bool:
        """Exact match or a subdomain of an allowed suffix. An empty list allows nothing (fail closed)."""
        host = (host or "").lower().rstrip(".")
        for suffix in self.allowed_host_suffixes:
            suffix = suffix.lower().strip().lstrip(".").rstrip(".")
            if not suffix:
                continue
            if host == suffix or host.endswith("." + suffix):
                return True
        return False


def load_caps(env: dict | None = None) -> Caps:
    env = dict(os.environ if env is None else env)
    return Caps(
        max_input_mb=_int(env, "PIXL_MAX_INPUT_MB", 60, 1, 2048),
        max_audio_s=_int(env, "PIXL_MAX_AUDIO_S", 900, 10, 7200),
        best_max_audio_s=_int(env, "PIXL_BEST_MAX_AUDIO_S", 480, 0, 7200),
        max_lyrics_lines=_int(env, "PIXL_MAX_LYRICS_LINES", 500, 0, 5000),
        max_lyrics_chars=_int(env, "PIXL_MAX_LYRICS_CHARS", 20000, 0, 200000),
        max_body_kb=_int(env, "PIXL_MAX_BODY_KB", 256, 1, 10240),
        execution_timeout_s=_int(env, "PIXL_EXECUTION_TIMEOUT_S", 900, 60, 7 * 24 * 3600),
        deadline_margin_s=_int(env, "PIXL_DEADLINE_MARGIN_S", 30, 0, 600),
        allowed_host_suffixes=_list(env, "PIXL_ALLOWED_HOST_SUFFIXES", ()),
        allowed_formats=_list(env, "PIXL_ALLOWED_FORMATS", DEFAULT_FORMATS),
        allowed_codecs=_list(env, "PIXL_ALLOWED_CODECS", DEFAULT_CODECS),
        allow_crash_test=env.get("PIXL_ALLOW_CRASH_TEST", "") == "1",
        tmp_root=env.get("PIXL_TMP_ROOT", "/tmp/pixl"),
        volume_root=env.get("PIXL_VOLUME_ROOT", "/runpod-volume"),
    )
