"""op: process — the whole job for one song (design 2.3–2.4). Models and storage are injected, so the CPU tests
run this exact code with fakes; handler.py supplies the real ones.

Order: guard → caps → download → probe → decode → separate → [stems4] → [lyrics] → encode → upload outputs →
lyrics.json → manifest.json (always last) → delete the input (only after ok/partial) → clean up.
Any failure still writes an error manifest (so the phone learns why after /status has expired) and fails the
RunPod job with "<CODE>: <message>".
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np

from . import audio as A
from .config import Caps
from .deadline import Deadline
from .errors import DEADLINE, GPU_OOM, INTERNAL, POISONED, TOO_LONG, INPUT_TOO_LARGE, WorkerError
from .log import log, redact, redact_exception
from .lyrics.postprocess import summarize
from .lyrics.run import run_lyrics
from .schema import Job
from .storage import CONTENT_TYPES, TransientError

RESULT_SCHEMA = "pixl.cloudstudio.result"
ATTEMPT_SCHEMA = "pixl.cloudstudio.attempt"
TIMING_KEYS = ("coldStartMs", "downloadMs", "decodeMs", "separateMs", "stemsMs", "lyricsMs", "encodeMs", "uploadMs",
               "totalMs")


@dataclass
class Models:
    separator: Any  # .model_id, .vocals(mix, sr, quality=, progress=)
    stems4: Any = None  # .model_id, .stems(x, sr, progress=) — lazy
    transcriber_factory: Callable[[], Any] | None = None  # lazy Qwen3-ASR


@dataclass
class Context:
    caps: Caps
    worker: dict  # version, gitSha, gpu, vramGB, cuda
    storage_factory: Callable[[Job, Caps], Any]
    progress: Callable[[str], None] = lambda message: None
    cold_start_ms: int = 0
    clock: Callable[[], float] = time.monotonic


@dataclass
class _Run:
    job: Job
    timings: dict = field(default_factory=lambda: {k: 0 for k in TIMING_KEYS})
    warnings: list = field(default_factory=list)
    models: dict = field(default_factory=lambda: {"separator": None, "stems4": None, "aligner": None, "asr": None})
    input: dict | None = None
    outputs: dict = field(default_factory=dict)
    lyrics: dict | None = None
    status: str = "ok"
    refresh_worker: bool = False


def manifest(run: _Run, ctx: Context, error: WorkerError | None = None) -> dict:
    return {
        "schema": RESULT_SCHEMA, "v": 1, "jobKey": run.job.job_key,
        "status": "error" if error else run.status,
        "error": {"code": error.code, "message": redact(error.message)[:500]} if error else None,
        "warnings": list(run.warnings),
        "worker": dict(ctx.worker),
        "models": dict(run.models),
        "input": run.input,
        "outputs": {} if error else dict(run.outputs),
        "lyrics": None if error else run.lyrics,
        "timings": dict(run.timings),
    }


def _encode_json(doc: dict) -> bytes:
    return (json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


class _Stage:
    def __init__(self, run: _Run, key: str, clock):
        self.run, self.key, self.clock = run, key, clock

    def __enter__(self):
        self.t0 = self.clock()
        return self

    def __exit__(self, *exc):
        self.run.timings[self.key] += int(round((self.clock() - self.t0) * 1000))
        return False


def _progress_reporter(ctx: Context, deadline: Deadline, stage: str):
    last = {"pct": -10}

    def report(done: int, total: int) -> None:
        deadline.check(stage)
        pct = int(100 * done / max(1, total))
        if pct >= last["pct"] + 10 or pct == 100:
            last["pct"] = pct
            ctx.progress(f"{stage}:{min(100, pct)}")
    return report


def _guard(storage, job: Job, runpod_job_id: str) -> dict | None:
    """Design 2.3 Guard. Returns a finished manifest to hand back (duplicate) or None to carry on. Raises
    POISONED for a third delivery of the same RunPod job. Best effort when storage can't be read."""
    if not getattr(storage, "has_guard", False):
        return None
    try:
        existing = storage.get_guard_json("manifest")
    except (TransientError, WorkerError) as exc:
        log.warning("guard_unreadable", what="manifest", reason=type(exc).__name__)
        return None
    if (existing and existing.get("schema") == RESULT_SCHEMA and existing.get("jobKey") == job.job_key
            and existing.get("status") == "ok"
            and (existing.get("input") or {}).get("sha256") == job.audio.sha256):
        dup = dict(existing)
        dup["warnings"] = list(existing.get("warnings") or []) + ["duplicate"]
        return dup
    attempts = 0
    try:
        attempt = storage.get_guard_json("attempt")
    except (TransientError, WorkerError) as exc:
        log.warning("guard_unreadable", what="attempt", reason=type(exc).__name__)
        attempt = None
    if attempt and attempt.get("runpodJobId") == runpod_job_id:
        attempts = attempt.get("attempts") if isinstance(attempt.get("attempts"), int) else 0
        if attempts >= 2:
            raise WorkerError(POISONED, "RunPod delivered this job a third time after two attempts died; "
                                        "not processing it again", refresh_worker=True)
    marker = {"schema": ATTEMPT_SCHEMA, "v": 1, "runpodJobId": runpod_job_id, "attempts": attempts + 1,
              "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        storage.put_attempt(_encode_json(marker))
    except (TransientError, WorkerError) as exc:
        log.warning("guard_unwritable", reason=type(exc).__name__)
    return None


def _file_info(path: str) -> tuple[int, str]:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return os.path.getsize(path), digest.hexdigest()


def process(job: Job, runpod_job_id: str, models: Models, ctx: Context, deadline: Deadline) -> dict:
    """Run one process job. Returns the dict for RunPod: the manifest on ok/partial (and duplicate), or
    {"error": "<CODE>: <message>", "refresh_worker": bool} on error."""
    run = _Run(job=job)
    run.timings["coldStartMs"] = ctx.cold_start_ms
    t_start = ctx.clock()
    storage = ctx.storage_factory(job, ctx.caps)
    work_dir = os.path.join(ctx.caps.tmp_root, job.job_key)
    log.bind(jobKey=job.job_key, runpodJobId=runpod_job_id)
    log.info("job_start", tasks=list(job.tasks), quality=job.quality, storage=job.storage)
    try:
        duplicate = _guard(storage, job, runpod_job_id)
        if duplicate is not None:
            log.info("job_duplicate")
            return duplicate
        result = _process(job, run, models, ctx, deadline, storage, work_dir, t_start)
        log.info("job_done", status=run.status, ms=run.timings["totalMs"], warnings=len(run.warnings))
        return result
    except WorkerError as exc:
        return _fail(run, ctx, storage, exc, t_start)
    except Exception as exc:  # anything unexpected becomes INTERNAL, redacted
        text = str(exc)
        refresh = "CUDA" in text or "cuda" in text
        log.error("job_exception", error=type(exc).__name__, trace=redact_exception(exc))
        return _fail(run, ctx, storage, WorkerError(INTERNAL, f"unexpected {type(exc).__name__}",
                                                    refresh_worker=refresh), t_start)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        log.clear()


def _fail(run: _Run, ctx: Context, storage, exc: WorkerError, t_start: float) -> dict:
    run.timings["totalMs"] = int(round((ctx.clock() - t_start) * 1000))
    doc = manifest(run, ctx, exc)
    log.error("job_error", code=exc.code, message=exc.message)
    try:
        if run.job.storage == "volume" or "manifest" in (run.job.output.put if run.job.output else {}):
            storage.put_json("manifest", _encode_json(doc))
    except Exception as put_exc:
        log.warning("error_manifest_unwritable", reason=type(put_exc).__name__)
    return {"error": f"{exc.code}: {redact(exc.message)[:300]}",
            "refresh_worker": bool(exc.refresh_worker or run.refresh_worker)}


def _process(job: Job, run: _Run, models: Models, ctx: Context, deadline: Deadline, storage, work_dir: str,
             t_start: float) -> dict:
    caps = ctx.caps
    if job.audio.bytes > caps.max_input_bytes:
        raise WorkerError(INPUT_TOO_LARGE, f"the input is larger than {caps.max_input_mb} MB")
    if job.audio.duration_ms > caps.max_audio_s * 1000:
        raise WorkerError(TOO_LONG, f"the song is longer than {caps.max_audio_s // 60} minutes")
    os.makedirs(work_dir, exist_ok=True)
    clock = ctx.clock

    # 1 fetch
    deadline.check("download")
    ctx.progress("download:0")
    src = os.path.join(work_dir, f"input.{job.audio.ext}")
    with _Stage(run, "downloadMs", clock):
        storage.fetch_input(src, total_timeout=deadline.budget(120.0))

    # 2-3 probe + decode
    deadline.check("decode")
    ctx.progress("decode:0")
    with _Stage(run, "decodeMs", clock):
        info = A.probe(src, caps, timeout=deadline.budget(15.0))
        mix = A.decode(src, info, caps, work_dir, timeout=deadline.budget(60.0))
    sr = info.sample_rate
    frames = int(mix.shape[0])
    duration_ms = int(round(frames * 1000 / sr))
    run.input = {"codec": info.codec, "sampleRate": sr, "channels": info.channels, "decodedSamples": frames,
                 "durationMs": duration_ms, "sha256": job.audio.sha256}
    if abs(duration_ms - job.audio.duration_ms) > 2000:
        run.warnings.append(f"input: decoded {duration_ms / 1000:.1f} s, the app said {job.audio.duration_ms / 1000:.1f} s")
    try:
        os.remove(src)
    except OSError:
        pass

    # 4 separate
    quality = job.quality
    if quality == "best" and duration_ms > caps.best_max_audio_s * 1000:
        quality = "standard"
        run.warnings.append(f"separation: best quality is limited to {caps.best_max_audio_s // 60} minutes; used standard")
    deadline.check("separate")
    ctx.progress("separate:0")
    with _Stage(run, "separateMs", clock):
        vocals = models.separator.vocals(mix, sr, quality=quality,
                                         progress=_progress_reporter(ctx, deadline, "separate"))
        instrumental = (mix - vocals).astype(np.float32)
    run.models["separator"] = models.separator.model_id
    stems: dict[str, np.ndarray] = {}
    if job.wants("instrumental"):
        stems["instrumental"] = instrumental
    if job.wants("vocals"):
        stems["vocals"] = vocals.astype(np.float32)
    del mix

    # 5 stems4
    if job.wants("stems4"):
        if models.stems4 is None:
            raise WorkerError(INTERNAL, "4-stem separation is not available on this worker")
        deadline.check("stems4")
        ctx.progress("stems4:0")
        with _Stage(run, "stemsMs", clock):
            stems.update(models.stems4.stems(instrumental, sr, progress=_progress_reporter(ctx, deadline, "stems4")))
        run.models["stems4"] = models.stems4.model_id

    # 6 lyrics (a failure here leaves the instrumental intact: status partial)
    lyrics_doc = None
    if job.wants("lyrics"):
        ctx.progress("lyrics:0")
        with _Stage(run, "lyricsMs", clock):
            try:
                deadline.check("lyrics")
                vocals16k = A.to_mono_16k(vocals, sr)
                outcome = run_lyrics(job.lyrics, vocals16k, transcriber_factory=models.transcriber_factory,
                                     deadline=deadline)
                lyrics_doc = outcome.doc
                run.warnings.extend(outcome.warnings)
                run.models["aligner"] = outcome.aligner
                run.models["asr"] = outcome.asr
            except WorkerError as exc:
                run.status = "partial"
                run.refresh_worker = run.refresh_worker or exc.refresh_worker
                run.warnings.append(f"lyrics: failed ({exc.code}); the {'instrumental' if stems else 'job'} is complete")
                log.warning("lyrics_failed", code=exc.code, message=exc.message)
            except Exception as exc:
                run.status = "partial"
                run.warnings.append("lyrics: failed (INTERNAL); the instrumental is complete")
                log.error("lyrics_exception", error=type(exc).__name__, trace=redact_exception(exc))
                if "CUDA" in str(exc) or "cuda" in str(exc):
                    run.refresh_worker = True
    del vocals

    # 7 encode + upload (each output, then lyrics.json, then the manifest last). The deadline no longer
    # aborts here: the 30 s margin is for exactly this, and a finished separation is worth delivering.
    ctx.progress("upload:0")
    out_ext = job.output.stem_ext
    for slot, data in stems.items():
        path = os.path.join(work_dir, f"{slot}.{out_ext}")
        with _Stage(run, "encodeMs", clock):
            A.encode(data, sr, path, codec=job.output.codec, kbps=job.output.kbps, timeout=60.0)
            size, sha = _file_info(path)
        with _Stage(run, "uploadMs", clock):
            key = storage.put_file(slot, path, CONTENT_TYPES[out_ext])
        run.outputs[slot] = {"key": key, "bytes": size, "sha256": sha, "codec": job.output.codec,
                             "kbps": job.output.kbps if job.output.codec == "aac" else None,
                             "sampleRate": sr, "samples": int(data.shape[0])}
        try:
            os.remove(path)
        except OSError:
            pass
    stems.clear()
    if lyrics_doc is not None:
        body = _encode_json(lyrics_doc)
        with _Stage(run, "uploadMs", clock):
            key = storage.put_json("lyrics", body)
        run.lyrics = {"key": key, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(),
                      **summarize(lyrics_doc)}
    run.timings["totalMs"] = int(round((clock() - t_start) * 1000))
    doc = manifest(run, ctx)
    storage.put_json("manifest", _encode_json(doc))
    ctx.progress("done:100")

    # 8 cleanup: the input goes only after a usable result, so a failed job can be retried without re-uploading
    storage.delete_input()
    if run.refresh_worker:
        out = dict(doc)
        out["refresh_worker"] = True
        return out
    return doc
