"""JSON-lines logging with redaction (design 2.6).

One JSON object per line on stdout (RunPod captures it). Fields: ts, level, event, jobKey, runpodJobId, stage, ms,
gpu, vramPeakMB, worker, plus event-specific fields. URLs are logged as host/path only, and any presigned query
(X-Amz-*) is stripped from free text, exceptions and tracebacks. Lyrics, titles and job bodies are never logged:
callers pass only counts and codes.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import traceback
from typing import Any
from urllib.parse import urlsplit

from . import WORKER_VERSION

_LEVELS = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}
_URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.IGNORECASE)
_AMZ_RE = re.compile(r"(X-Amz-[A-Za-z-]+)=[^&\s\"'<>]*", re.IGNORECASE)
_SIG_RE = re.compile(r"\b[0-9a-f]{64}\b")
_BEARER_RE = re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+")
_KEYVAL_RE = re.compile(r"(?i)\b(api[_-]?key|authorization|token|secret)([\"']?\s*[:=]\s*[\"']?)(?!bearer\b)[^\s\"',}]+")


def safe_url(url: str | None) -> str:
    """host/path of a URL; never its query (which holds the signature)."""
    if not url:
        return ""
    try:
        parts = urlsplit(url)
    except ValueError:
        return "<invalid url>"
    return f"{parts.hostname or ''}{parts.path}"


def redact(text: Any) -> str:
    """Make arbitrary text safe to log or store: URLs → host/path, X-Amz params and 64-hex signatures removed,
    bearer tokens masked."""
    s = str(text)
    s = _URL_RE.sub(lambda m: safe_url(m.group(0)), s)
    s = _AMZ_RE.sub(lambda m: f"{m.group(1)}=<redacted>", s)
    s = _BEARER_RE.sub(lambda m: f"{m.group(1)} <redacted>", s)
    s = _KEYVAL_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}<redacted>", s)
    s = _SIG_RE.sub("<hex64>", s)
    return s


def redact_exception(exc: BaseException, *, limit: int = 8) -> str:
    tb = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__, limit=limit))
    return redact(tb)


class Logger:
    def __init__(self, stream=None, level: str | None = None):
        self._stream = stream or sys.stdout
        self._level = _LEVELS.get((level or os.environ.get("PIXL_LOG_LEVEL", "INFO")).upper(), 20)
        self.context: dict[str, Any] = {}
        self.worker = f"{WORKER_VERSION}+{os.environ.get('PIXL_WORKER_GIT_SHA', 'unknown')[:12]}"

    def bind(self, **fields: Any) -> None:
        self.context.update({k: v for k, v in fields.items() if v is not None})

    def clear(self) -> None:
        self.context.clear()

    def log(self, level: str, event: str, **fields: Any) -> None:
        if _LEVELS.get(level, 20) < self._level:
            return
        record: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + f".{int(time.time() * 1000) % 1000:03d}Z",
            "level": level,
            "event": event,
            "worker": self.worker,
        }
        record.update(self.context)
        for key, value in fields.items():
            if value is None:
                continue
            if isinstance(value, str):
                value = redact(value)
            record[key] = value
        try:
            line = json.dumps(record, ensure_ascii=False, default=lambda o: redact(o))
        except (TypeError, ValueError):
            line = json.dumps({"ts": record["ts"], "level": "ERROR", "event": "log_failed", "for": event})
        self._stream.write(line + "\n")
        self._stream.flush()

    def info(self, event: str, **fields: Any) -> None:
        self.log("INFO", event, **fields)

    def warning(self, event: str, **fields: Any) -> None:
        self.log("WARNING", event, **fields)

    def error(self, event: str, **fields: Any) -> None:
        self.log("ERROR", event, **fields)

    def debug(self, event: str, **fields: Any) -> None:
        self.log("DEBUG", event, **fields)


log = Logger()
