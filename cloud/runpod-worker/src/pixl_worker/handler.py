"""RunPod Serverless entry point: `python -u -m pixl_worker.handler`.

At start the process loads the separator and the aligner once (their load is billed once per process, then
FlashBoot keeps the worker warm); Qwen3-ASR and htdemucs_ft load lazily on first use. Each job is validated
(schema v1 + server caps) and dispatched to pipeline.process, selftest or bench. Nothing here ever logs or
returns a URL, a signature or lyrics.
"""

from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable

_PROCESS_T0 = time.monotonic()

from . import WORKER_VERSION  # noqa: E402
from . import pipeline  # noqa: E402
from . import selftest as st  # noqa: E402
from .config import Caps, load_caps  # noqa: E402
from .deadline import job_deadline  # noqa: E402
from .errors import INTERNAL, WorkerError  # noqa: E402
from .log import log, redact, redact_exception  # noqa: E402
from .schema import validate_job  # noqa: E402
from .storage import make_storage, sweep_volume  # noqa: E402

MODELS_DIR = os.environ.get("PIXL_MODELS_DIR", "/models")
SEP_CONFIG = os.path.join(MODELS_DIR, "sep", "config.yaml")
SEP_CKPT = os.path.join(MODELS_DIR, "sep", "bs_roformer_ft1_anvuew_sdr_12.55.ckpt")
ALIGNER_DIR = os.path.join(MODELS_DIR, "aligner")
ASR_DIR = os.path.join(MODELS_DIR, "asr")
DEMUCS_DIR = os.path.join(MODELS_DIR, "demucs")


class Worker:
    """Holds the loaded models and turns RunPod jobs into results. Constructed once per process."""

    def __init__(self, caps: Caps, models: pipeline.Models, worker_info: dict, cold_start_ms: int,
                 models_state: Callable[[], dict], progress: Callable[[dict, str], None] = lambda job, m: None,
                 storage_factory=make_storage):
        self.caps = caps
        self.models = models
        self.worker_info = worker_info
        self.cold_start_ms = cold_start_ms
        self.models_state = models_state
        self.progress = progress
        self.storage_factory = storage_factory

    def _take_cold_start(self) -> int:
        value, self.cold_start_ms = self.cold_start_ms, 0
        return value

    def handle(self, job: dict) -> dict:
        runpod_job_id = str(job.get("id") or "unknown")[:200]
        try:
            spec = validate_job(job.get("input"), self.caps)
        except WorkerError as exc:
            log.error("job_rejected", code=exc.code, message=exc.message, runpodJobId=runpod_job_id)
            return {"error": f"{exc.code}: {exc.message}"}
        try:
            if spec.op == "selftest":
                return st.selftest(self.worker_info, self.models_state(), self._take_cold_start())
            if spec.op == "bench":
                return st.bench(spec.bench, caps=self.caps, worker=self.worker_info,
                                separator=self.models.separator, stems4=self.models.stems4,
                                transcriber_factory=self.models.transcriber_factory,
                                cold_start_ms=self._take_cold_start(),
                                progress=lambda message: self.progress(job, message))
            deadline = job_deadline(self.caps.execution_timeout_s, self.caps.deadline_margin_s, job.get("policy"))
            ctx = pipeline.Context(caps=self.caps, worker=self.worker_info, storage_factory=self.storage_factory,
                                   progress=lambda message: self.progress(job, message),
                                   cold_start_ms=self._take_cold_start())
            return pipeline.process(spec, runpod_job_id, self.models, ctx, deadline)
        except WorkerError as exc:
            return {"error": f"{exc.code}: {redact(exc.message)}", "refresh_worker": exc.refresh_worker}
        except Exception as exc:  # last resort: never let a traceback (which may hold a URL) reach RunPod
            log.error("handler_exception", error=type(exc).__name__, trace=redact_exception(exc))
            return {"error": f"{INTERNAL}: unexpected {type(exc).__name__}"}


def gpu_info() -> dict:
    info = {"version": WORKER_VERSION, "gitSha": os.environ.get("PIXL_WORKER_GIT_SHA", "unknown")[:12],
            "gpu": None, "vramGB": None, "cuda": None}
    try:
        import torch

        info["cuda"] = torch.version.cuda
        if torch.cuda.is_available():
            props = torch.cuda.get_device_properties(0)
            info["gpu"] = props.name
            info["vramGB"] = round(props.total_memory / (1024 ** 3), 1)
    except Exception:
        pass
    return info


class _LazyTranscriber:
    """Loads Qwen3-ASR on first use (billed only for the jobs that need it), once, thread-safely."""

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self._instance = None

    @property
    def loaded(self) -> bool:
        return self._instance is not None

    def __call__(self):
        with self._lock:
            if self._instance is None:
                from .lyrics.transcribe import QwenTranscriber

                t0 = time.monotonic()
                self._instance = QwenTranscriber(self.path)
                log.info("asr_loaded", ms=int((time.monotonic() - t0) * 1000))
            return self._instance


def load_models() -> tuple[pipeline.Models, Callable[[], dict]]:
    from .lyrics.align import MODEL_ID as ALIGNER_ID, QwenAligner
    from .lyrics.languages import register_backend
    from .lyrics.transcribe import MODEL_ID as ASR_ID
    from .separate import SEPARATOR_ID, STEMS4_ID, RoformerSeparator, Stems4

    separator = RoformerSeparator(SEP_CONFIG, SEP_CKPT)
    aligner = QwenAligner(ALIGNER_DIR)
    register_backend(aligner)
    stems4 = Stems4(DEMUCS_DIR)
    transcriber = _LazyTranscriber(ASR_DIR) if os.path.isdir(ASR_DIR) else None
    models = pipeline.Models(separator=separator, stems4=stems4 if stems4.available() else None,
                             transcriber_factory=transcriber)

    def state() -> dict:
        return {
            SEPARATOR_ID: True,
            ALIGNER_ID: True,
            ASR_ID: (True if transcriber.loaded else "lazy") if transcriber else False,
            STEMS4_ID: (True if stems4.loaded else "lazy") if stems4.available() else False,
        }
    return models, state


def main() -> None:
    caps = load_caps()
    log.info("boot", pid=os.getpid(), hosts=len(caps.allowed_host_suffixes))
    if not caps.allowed_host_suffixes:
        log.warning("no_allowed_hosts", note="PIXL_ALLOWED_HOST_SUFFIXES is empty: presigned jobs will fail BAD_URL")
    if os.path.isdir(caps.volume_root):
        removed = sweep_volume(caps.volume_root)
        log.info("volume_swept", removed=removed)
    os.makedirs(caps.tmp_root, exist_ok=True)
    models, state = load_models()
    cold_ms = int((time.monotonic() - _PROCESS_T0) * 1000)
    info = gpu_info()
    log.info("models_loaded", ms=cold_ms, gpu=info["gpu"], vramGB=info["vramGB"], cuda=info["cuda"])

    import runpod

    def progress(job: dict, message: str) -> None:
        try:
            runpod.serverless.progress_update(job, message)
        except Exception:
            pass

    worker = Worker(caps, models, info, cold_ms, state, progress)
    runpod.serverless.start({"handler": worker.handle})


if __name__ == "__main__":
    main()
