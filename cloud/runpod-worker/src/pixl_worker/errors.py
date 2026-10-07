"""Error codes shared by the handler, the manifest and the schema (job.result.schema.json › error.code)."""

from __future__ import annotations

BAD_SCHEMA = "BAD_SCHEMA"
UNSUPPORTED_VERSION = "UNSUPPORTED_VERSION"
BAD_OP = "BAD_OP"
BAD_URL = "BAD_URL"
INPUT_TOO_LARGE = "INPUT_TOO_LARGE"
INPUT_MISMATCH = "INPUT_MISMATCH"
INPUT_MISSING = "INPUT_MISSING"
DOWNLOAD_FAILED = "DOWNLOAD_FAILED"
TOO_LONG = "TOO_LONG"
UNSUPPORTED_FORMAT = "UNSUPPORTED_FORMAT"
DECODE_FAILED = "DECODE_FAILED"
GPU_OOM = "GPU_OOM"
DEADLINE = "DEADLINE"
UPLOAD_FAILED = "UPLOAD_FAILED"
POISONED = "POISONED"
INTERNAL = "INTERNAL"

ALL_CODES = (
    BAD_SCHEMA, UNSUPPORTED_VERSION, BAD_OP, BAD_URL, INPUT_TOO_LARGE, INPUT_MISMATCH, INPUT_MISSING,
    DOWNLOAD_FAILED, TOO_LONG, UNSUPPORTED_FORMAT, DECODE_FAILED, GPU_OOM, DEADLINE, UPLOAD_FAILED, POISONED,
    INTERNAL,
)


class WorkerError(Exception):
    """A failure with a schema error code. `message` must already be safe to log and to store (no URLs, no
    signatures, no lyrics); `refresh_worker` asks RunPod to recycle the process after this job."""

    def __init__(self, code: str, message: str, *, refresh_worker: bool = False):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.refresh_worker = refresh_worker
