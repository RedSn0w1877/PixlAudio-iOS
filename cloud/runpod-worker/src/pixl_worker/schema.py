"""Validation of the job input, schema v1 (stdlib only; no torch, no jsonschema).

schema/v1/job.input.schema.json is the contract. This module re-checks every rule in it by hand, plus the
server-side caps from config.Caps, and returns a normalised, immutable Job. tests/test_schema.py runs the
golden examples and a set of broken inputs through both this module and jsonschema so the two cannot drift.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

from . import SUPPORTED_VERSIONS
from .config import Caps
from .errors import BAD_OP, BAD_SCHEMA, BAD_URL, UNSUPPORTED_VERSION, WorkerError

JOB_SCHEMA = "pixl.cloudstudio.job"
OPS = ("process", "selftest", "bench")
TASKS = ("instrumental", "vocals", "stems4", "lyrics")
EXTS = ("m4a", "mp3", "flac", "wav", "ogg", "opus", "webm")
STEM_SLOTS = ("instrumental", "vocals", "drums", "bass", "other")
PUT_SLOTS = STEM_SLOTS + ("lyrics", "manifest")
BENCH_STAGES = ("decode", "separate", "stems4", "align", "transcribe", "encode")

JOB_KEY_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VOLUME_KEY_RE = re.compile(r"^in/[0-9a-f-]{36}\.(m4a|mp3|flac|wav|ogg|opus|webm)$")
LANG_RE = re.compile(r"^[a-z]{2,3}([-_][A-Za-z0-9]{2,8})*$")
MAX_URL_LEN = 4096


@dataclass(frozen=True)
class LyricsLine:
    index: int
    start_ms: int | None
    end_ms: int | None
    text: str


@dataclass(frozen=True)
class LyricsRequest:
    mode: str  # align | transcribe | auto
    language: str | None  # primary subtag, lower case
    synced: bool
    lines: tuple[LyricsLine, ...]

    @property
    def has_text(self) -> bool:
        return any(line.text.strip() for line in self.lines)

    @property
    def effective_mode(self) -> str:
        """align or transcribe: auto aligns when there is text and transcribes otherwise."""
        if self.mode == "auto":
            return "align" if self.has_text else "transcribe"
        return self.mode


@dataclass(frozen=True)
class AudioRef:
    get: str | None
    delete: str | None
    key: str | None
    ext: str
    bytes: int
    sha256: str
    duration_ms: int


@dataclass(frozen=True)
class OutputSpec:
    codec: str  # aac | flac
    kbps: int
    put: dict  # slot -> url (presigned only)

    @property
    def stem_ext(self) -> str:
        return "m4a" if self.codec == "aac" else "flac"


@dataclass(frozen=True)
class Guard:
    manifest_get: str
    attempt_get: str
    attempt_put: str


@dataclass(frozen=True)
class BenchSpec:
    seconds: int
    stages: tuple[str, ...]
    crash: bool


@dataclass(frozen=True)
class Job:
    op: str
    job_key: str | None = None
    client_app: str | None = None
    client_build: str | None = None
    storage: str | None = None
    audio: AudioRef | None = None
    tasks: tuple[str, ...] = ()
    quality: str = "standard"
    lyrics: LyricsRequest | None = None
    output: OutputSpec | None = None
    guard: Guard | None = None
    bench: BenchSpec | None = None

    def wants(self, task: str) -> bool:
        return task in self.tasks

    def stem_slots(self) -> tuple[str, ...]:
        slots = []
        if self.wants("instrumental"):
            slots.append("instrumental")
        if self.wants("vocals"):
            slots.append("vocals")
        if self.wants("stems4"):
            slots.extend(("drums", "bass", "other"))
        return tuple(slots)

    def object_key(self, slot: str) -> str:
        """Canonical storage key for an output slot (design 2.3 layout)."""
        assert self.job_key is not None and self.output is not None
        if slot == "lyrics":
            return f"out/{self.job_key}/lyrics.json"
        if slot == "manifest":
            return f"out/{self.job_key}/manifest.json"
        if slot == "attempt":
            return f"out/{self.job_key}/attempt.json"
        return f"out/{self.job_key}/{slot}.{self.output.stem_ext}"


def _fail(message: str) -> WorkerError:
    return WorkerError(BAD_SCHEMA, message)


def _obj(value: Any, where: str, required: bool = True) -> dict | None:
    if value is None and not required:
        return None
    if not isinstance(value, dict):
        raise _fail(f"{where} must be an object")
    return value


def _int(value: Any, where: str, *, lo: int | None = None, hi: int | None = None, required: bool = True) -> int | None:
    if value is None and not required:
        return None
    # bool is an int subclass in Python; JSON booleans are not integers.
    if isinstance(value, bool) or not isinstance(value, int):
        raise _fail(f"{where} must be an integer")
    if lo is not None and value < lo:
        raise _fail(f"{where} must be >= {lo}")
    if hi is not None and value > hi:
        raise _fail(f"{where} must be <= {hi}")
    return value


def _str(value: Any, where: str, *, max_len: int | None = None, required: bool = True) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str):
        raise _fail(f"{where} must be a string")
    if max_len is not None and len(value) > max_len:
        raise _fail(f"{where} is longer than {max_len} characters")
    return value


def _enum(value: Any, where: str, allowed: tuple[str, ...], *, default: str | None = None) -> str:
    if value is None and default is not None:
        return default
    if not isinstance(value, str) or value not in allowed:
        raise _fail(f"{where} must be one of {', '.join(allowed)}")
    return value


def _bool(value: Any, where: str, default: bool) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        raise _fail(f"{where} must be true or false")
    return value


def url_path(url: str) -> str:
    """The decoded path of a URL (no query)."""
    return unquote(urlsplit(url).path)


def check_presigned_url(url: Any, where: str, caps: Caps, expected_path_suffix: str) -> str:
    """Syntax-level URL checks (no network): HTTPS, allowed host, default port, no credentials, a SigV4
    signature, and an object path ending in `expected_path_suffix` (so a job can only touch its own objects).
    storage.py re-checks the host and requires a public resolved IP at connection time."""
    if not isinstance(url, str) or not url:
        raise _fail(f"{where} must be a URL string")
    if len(url) > MAX_URL_LEN:
        raise WorkerError(BAD_URL, f"{where} is too long")
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise WorkerError(BAD_URL, f"{where} is not a valid URL") from None
    if parts.scheme != "https":
        raise WorkerError(BAD_URL, f"{where} must use https")
    if parts.username or parts.password or "@" in parts.netloc:
        raise WorkerError(BAD_URL, f"{where} must not carry credentials")
    if port not in (None, 443):
        raise WorkerError(BAD_URL, f"{where} must use the default https port")
    host = (parts.hostname or "").lower()
    if not host or not caps.host_allowed(host):
        raise WorkerError(BAD_URL, f"{where} host is not on the worker's allowlist")
    if parts.fragment:
        raise WorkerError(BAD_URL, f"{where} must not have a fragment")
    query = parse_qs(parts.query, keep_blank_values=True)
    signature = query.get("X-Amz-Signature", [""])
    if len(signature) != 1 or not re.fullmatch(r"[0-9a-f]{64}", signature[0]):
        raise WorkerError(BAD_URL, f"{where} is not a SigV4 presigned URL")
    path = url_path(url)
    if ".." in path.split("/") or "\\" in path:
        raise WorkerError(BAD_URL, f"{where} has an invalid path")
    if not path.endswith("/" + expected_path_suffix):
        raise WorkerError(BAD_URL, f"{where} does not point at {expected_path_suffix}")
    return url


def normalise_language(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not LANG_RE.match(value):
        raise _fail("lyrics.language must be an ISO 639 code such as ko, en or zh-Hant")
    return re.split(r"[-_]", value)[0].lower()


def validate_job(raw: Any, caps: Caps) -> Job:
    """Validate a job input (the `input` object of /run). Raises WorkerError with the schema's error codes."""
    if not isinstance(raw, dict):
        raise _fail("input must be an object")
    try:
        body_bytes = len(json.dumps(raw, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    except (TypeError, ValueError):
        raise _fail("input is not JSON-serialisable") from None
    if body_bytes > caps.max_body_kb * 1024:
        raise _fail(f"input is larger than {caps.max_body_kb} KB")

    v = raw.get("v")
    if isinstance(v, bool) or not isinstance(v, int) or v not in SUPPORTED_VERSIONS:
        raise WorkerError(UNSUPPORTED_VERSION, f"v must be one of {list(SUPPORTED_VERSIONS)}")
    op = raw.get("op")
    if op not in OPS:
        raise WorkerError(BAD_OP, f"op must be one of {', '.join(OPS)}")
    schema = raw.get("schema")
    if schema is not None and schema != JOB_SCHEMA:
        raise _fail(f"schema must be {JOB_SCHEMA}")

    if op == "selftest":
        return Job(op="selftest")
    if op == "bench":
        return Job(op="bench", bench=_bench(raw.get("bench")))

    if schema != JOB_SCHEMA:
        raise _fail(f"schema must be {JOB_SCHEMA}")
    job_key = raw.get("jobKey")
    if not isinstance(job_key, str) or not JOB_KEY_RE.match(job_key):
        raise _fail("jobKey must be a lower-case UUID")

    client = _obj(raw.get("client"), "client", required=False) or {}
    client_app = _str(client.get("app"), "client.app", max_len=64, required=False)
    client_build = _str(client.get("build"), "client.build", max_len=64, required=False)

    storage = _enum(raw.get("storage"), "storage", ("presigned", "volume"))

    tasks_raw = raw.get("tasks")
    if not isinstance(tasks_raw, list) or not tasks_raw:
        raise _fail("tasks must be a non-empty list")
    tasks: list[str] = []
    for task in tasks_raw:
        if task not in TASKS:
            raise _fail(f"tasks may only contain {', '.join(TASKS)}")
        if task in tasks:
            raise _fail("tasks must not repeat")
        tasks.append(task)

    separation = _obj(raw.get("separation"), "separation", required=False) or {}
    quality = _enum(separation.get("quality"), "separation.quality", ("standard", "best"), default="standard")

    output_raw = _obj(raw.get("output"), "output")
    codec = _enum(output_raw.get("codec"), "output.codec", ("aac", "flac"), default="aac")
    kbps = _int(output_raw.get("kbps"), "output.kbps", lo=128, hi=256, required=False) or 256
    output = OutputSpec(codec=codec, kbps=kbps, put={})

    audio = _audio(raw.get("audio"), storage, job_key, caps)

    put: dict = {}
    guard = None
    if storage == "presigned":
        put_raw = _obj(output_raw.get("put"), "output.put")
        needed = set()
        if "instrumental" in tasks:
            needed.add("instrumental")
        if "vocals" in tasks:
            needed.add("vocals")
        if "stems4" in tasks:
            needed.update(("drums", "bass", "other"))
        if "lyrics" in tasks:
            needed.add("lyrics")
        needed.add("manifest")
        for slot in sorted(needed):
            if slot not in put_raw:
                raise _fail(f"output.put.{slot} is required for the requested tasks")
        for slot, value in put_raw.items():
            if slot not in PUT_SLOTS:
                continue  # unknown slots are ignored (forward compatibility)
            if slot in STEM_SLOTS:
                name = f"{slot}.{output.stem_ext}"
            else:
                name = f"{slot}.json"
            put[slot] = check_presigned_url(value, f"output.put.{slot}", caps, f"out/{job_key}/{name}")
        guard_raw = _obj(raw.get("guard"), "guard", required=False)
        if guard_raw is not None:
            for name in ("manifestGet", "attemptGet", "attemptPut"):
                if name not in guard_raw:
                    raise _fail(f"guard.{name} is required when guard is present")
            guard = Guard(
                manifest_get=check_presigned_url(guard_raw["manifestGet"], "guard.manifestGet", caps,
                                                 f"out/{job_key}/manifest.json"),
                attempt_get=check_presigned_url(guard_raw["attemptGet"], "guard.attemptGet", caps,
                                                f"out/{job_key}/attempt.json"),
                attempt_put=check_presigned_url(guard_raw["attemptPut"], "guard.attemptPut", caps,
                                                f"out/{job_key}/attempt.json"),
            )
    output = OutputSpec(codec=codec, kbps=kbps, put=put)

    lyrics = None
    if "lyrics" in tasks:
        lyrics = _lyrics(raw.get("lyrics"), caps)
    elif raw.get("lyrics") is not None:
        _obj(raw.get("lyrics"), "lyrics")  # present but unused: still has to be an object

    if quality == "best" and audio.duration_ms > caps.best_max_audio_s * 1000:
        # Not an error: the worker falls back to standard and says so (pipeline adds the warning).
        pass

    return Job(
        op="process", job_key=job_key, client_app=client_app, client_build=client_build, storage=storage,
        audio=audio, tasks=tuple(tasks), quality=quality, lyrics=lyrics, output=output, guard=guard,
    )


def _audio(value: Any, storage: str, job_key: str, caps: Caps) -> AudioRef:
    audio = _obj(value, "audio")
    ext = _enum(audio.get("ext"), "audio.ext", EXTS)
    size = _int(audio.get("bytes"), "audio.bytes", lo=1)
    sha = audio.get("sha256")
    if not isinstance(sha, str) or not SHA256_RE.match(sha):
        raise _fail("audio.sha256 must be 64 lower-case hex characters")
    duration_ms = _int(audio.get("durationMs"), "audio.durationMs", lo=1)
    get = delete = key = None
    if storage == "presigned":
        if "get" not in audio:
            raise _fail("audio.get is required for presigned storage")
        get = check_presigned_url(audio.get("get"), "audio.get", caps, f"in/{job_key}.{ext}")
        if audio.get("delete") is not None:
            delete = check_presigned_url(audio.get("delete"), "audio.delete", caps, f"in/{job_key}.{ext}")
    else:
        key = audio.get("key")
        if not isinstance(key, str) or not VOLUME_KEY_RE.match(key):
            raise _fail("audio.key must look like in/<jobKey>.<ext>")
        if key != f"in/{job_key}.{ext}":
            raise _fail("audio.key must be in/<jobKey>.<ext> for this job")
    return AudioRef(get=get, delete=delete, key=key, ext=ext, bytes=size, sha256=sha, duration_ms=duration_ms)


def _lyrics(value: Any, caps: Caps) -> LyricsRequest:
    raw = _obj(value, "lyrics")
    mode = _enum(raw.get("mode"), "lyrics.mode", ("align", "transcribe", "auto"), default="auto")
    language = normalise_language(raw.get("language"))
    synced = _bool(raw.get("synced"), "lyrics.synced", True)
    lines_raw = raw.get("lines", [])
    if lines_raw is None:
        lines_raw = []
    if not isinstance(lines_raw, list):
        raise _fail("lyrics.lines must be a list")
    if len(lines_raw) > caps.max_lyrics_lines:
        raise _fail(f"lyrics.lines has more than {caps.max_lyrics_lines} lines")
    lines: list[LyricsLine] = []
    total_chars = 0
    last_start = -1
    for i, line_raw in enumerate(lines_raw):
        line = _obj(line_raw, f"lyrics.lines[{i}]")
        text = _str(line.get("text"), f"lyrics.lines[{i}].text", max_len=2000)
        total_chars += len(text)
        start = _int(line.get("startMs"), f"lyrics.lines[{i}].startMs", lo=0, required=False)
        end = _int(line.get("endMs"), f"lyrics.lines[{i}].endMs", lo=0, required=False)
        if synced and mode != "transcribe":
            if start is None:
                raise _fail(f"lyrics.lines[{i}].startMs is required when lyrics.synced is true")
            if start < last_start:
                raise _fail("lyrics.lines must be sorted by startMs")
            last_start = start
            if end is not None and end < start:
                raise _fail(f"lyrics.lines[{i}].endMs is before its startMs")
        lines.append(LyricsLine(index=i, start_ms=start, end_ms=end, text=text))
    if total_chars > caps.max_lyrics_chars:
        raise _fail(f"lyrics text is longer than {caps.max_lyrics_chars} characters")
    request = LyricsRequest(mode=mode, language=language, synced=synced, lines=tuple(lines))
    if mode == "align" and not request.has_text:
        raise _fail("lyrics.mode align needs at least one line of text")
    return request


def _bench(value: Any) -> BenchSpec:
    raw = _obj(value, "bench", required=False) or {}
    seconds = _int(raw.get("seconds"), "bench.seconds", lo=10, hi=900, required=False) or 240
    stages_raw = raw.get("stages")
    if stages_raw is None:
        stages = BENCH_STAGES
    else:
        if not isinstance(stages_raw, list) or any(s not in BENCH_STAGES for s in stages_raw):
            raise _fail(f"bench.stages may only contain {', '.join(BENCH_STAGES)}")
        if len(set(stages_raw)) != len(stages_raw):
            raise _fail("bench.stages must not repeat")
        stages = tuple(stages_raw)
    crash = _bool(raw.get("crash"), "bench.crash", False)
    return BenchSpec(seconds=seconds, stages=stages, crash=crash)
