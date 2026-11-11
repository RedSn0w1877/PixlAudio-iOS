"""op: process — the whole job for one song (design 2.3–2.4; the library tasks: cloud-audio-spec.md, section 4).
Models and storage are injected, so the CPU tests run this exact code with fakes; handler.py supplies the real ones.

Order: guard → caps → download → probe → decode →
  the job's own outputs (out/<jobKey>/): separate → [stems4] → [lyrics] → encode → upload outputs → lyrics.json →
  the shared library (lib/v<LIB_V>/<videoId>/, tasks spatial and enhance): library checks (what is already there
  is skipped) → cutoff analysis → [restore] → [enhanced out] → stems6 → render each missing profile → encode →
  upload its audio → upload its manifest →
manifest.json (always last) → delete the input (only after ok/partial) → clean up.
A job runs the part its tasks ask for, or both; the vocal separation is then done once and shared.
Any failure still writes an error manifest (so the phone learns why after /status has expired) and fails the
RunPod job with "<CODE>: <message>". A failure of lyrics next to stems, or of one library output, leaves the rest
intact (status partial); when nothing at all was delivered it is the job's error, and the input stays for a retry.
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
from . import library as L
from . import restore as R
from .config import Caps
from .deadline import Deadline
from .errors import (DEADLINE, GPU_OOM, INPUT_MISSING, INPUT_TOO_LARGE, INTERNAL, POISONED, TOO_LONG,
                     UNSUPPORTED_FORMAT, WorkerError)
from .log import log, redact, redact_exception
from .lyrics.postprocess import summarize
from .lyrics.run import run_lyrics
from .schema import JOB_KEY_RE, Job, OutputSpec, check_presigned_url
from .storage import CONTENT_TYPES, TransientError, download_budget_s

RESULT_SCHEMA = "pixl.cloudstudio.result"
ATTEMPT_SCHEMA = "pixl.cloudstudio.attempt"
TIMING_KEYS = ("coldStartMs", "downloadMs", "decodeMs", "separateMs", "stemsMs", "lyricsMs", "restoreMs", "stems6Ms",
               "renderMs", "encodeMs", "uploadMs", "totalMs")
LIBRARY_ENCODE_TIMEOUT_S = 180.0  # a 15-minute render is 170 MB of 16-bit samples for ffmpeg's FLAC encoder


@dataclass
class Models:
    separator: Any  # .model_id, .vocals(mix, sr, quality=, progress=)
    stems4: Any = None  # .model_id, .stems(x, sr, progress=) — lazy
    transcriber_factory: Callable[[], Any] | None = None  # lazy Qwen3-ASR
    stems6: Any = None  # .model_id, .stems(mix, sr, quality=, vocals=, progress=) -> {stem: array} — lazy inside
    restorer: Any = None  # restore.Restorer: .model_id, .available(), .restore(mix, sr, cutoff_hz, progress=)


@dataclass
class Context:
    caps: Caps
    worker: dict  # version, gitSha, gpu, vramGB, cuda
    storage_factory: Callable[[Job, Caps], Any]
    progress: Callable[[str], None] = lambda message: None
    cold_start_ms: int = 0
    clock: Callable[[], float] = time.monotonic
    now: Callable[[], float] = time.time  # wall clock, for a library manifest's createdAt


@dataclass
class _Run:
    job: Job
    timings: dict = field(default_factory=lambda: {k: 0 for k in TIMING_KEYS})
    warnings: list = field(default_factory=list)
    models: dict = field(default_factory=lambda: {"separator": None, "stems4": None, "aligner": None, "asr": None,
                                                  "stems6": None, "restorer": None})
    input: dict | None = None
    outputs: dict = field(default_factory=dict)
    lyrics: dict | None = None
    library: dict | None = None  # the library tasks' outcome (job.result.schema.json › library)
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
        "library": None if error else run.library,
        "timings": dict(run.timings),
    }


def _encode_json(doc: dict) -> bytes:
    return (json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def write_rejection(raw: Any, caps: Caps, exc: WorkerError, worker: dict, storage_factory) -> bool:
    """A process job that failed validation (BAD_SCHEMA, UNSUPPORTED_VERSION, BAD_URL, ...) still gets an error
    manifest when its own manifest slot can be trusted: a valid jobKey plus an output.put.manifest URL that passes
    every URL check on its own (presigned), or the volume's out/<jobKey>/ (volume). Without it a phone that
    collects from storage after /status expired would see a "lost" job and resubmit a request that can never
    succeed. Returns True when the manifest was written."""
    if not isinstance(raw, dict) or raw.get("op") != "process":
        return False
    job_key = raw.get("jobKey")
    if not isinstance(job_key, str) or not JOB_KEY_RE.match(job_key):
        return False
    storage_mode = raw.get("storage")
    put: dict = {}
    if storage_mode == "presigned":
        output = raw.get("output") if isinstance(raw.get("output"), dict) else {}
        slots = output.get("put") if isinstance(output.get("put"), dict) else {}
        try:
            put["manifest"] = check_presigned_url(slots.get("manifest"), "output.put.manifest", caps,
                                                  f"out/{job_key}/manifest.json")
        except WorkerError:
            return False
    elif storage_mode != "volume":
        return False
    job = Job(op="process", job_key=job_key, storage=storage_mode, output=OutputSpec(codec="aac", kbps=256, put=put))
    doc = manifest(_Run(job=job), Context(caps=caps, worker=worker, storage_factory=storage_factory), exc)
    try:
        storage_factory(job, caps).put_json("manifest", _encode_json(doc))
    except Exception as put_exc:  # best effort: the RunPod job still fails with the code
        log.warning("rejection_manifest_unwritable", reason=type(put_exc).__name__)
        return False
    return True


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


def _earlier_result(storage, job: Job, statuses: tuple[str, ...]) -> dict | None:
    """The finished manifest an earlier run of this job (same jobKey and input sha256) left in storage, marked
    as a duplicate, or None. Best effort: unreadable storage is None."""
    if not getattr(storage, "has_guard", False):
        return None
    try:
        existing = storage.get_guard_json("manifest")
    except (TransientError, WorkerError) as exc:
        log.warning("guard_unreadable", what="manifest", reason=type(exc).__name__)
        return None
    if (existing and existing.get("schema") == RESULT_SCHEMA and existing.get("jobKey") == job.job_key
            and existing.get("status") in statuses
            and (existing.get("input") or {}).get("sha256") == job.audio.sha256):
        dup = dict(existing)
        dup["warnings"] = list(existing.get("warnings") or []) + ["duplicate"]
        return dup
    return None


def _guard(storage, job: Job, runpod_job_id: str) -> dict | None:
    """Design 2.3 Guard. Returns a finished manifest to hand back (duplicate) or None to carry on. Raises
    POISONED for a third delivery of the same RunPod job. Best effort when storage can't be read."""
    if not getattr(storage, "has_guard", False):
        return None
    duplicate = _earlier_result(storage, job, ("ok",))
    if duplicate is not None:
        return duplicate
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
        if exc.code == INPUT_MISSING:
            # The input goes only after an ok or partial result. So when it's gone and that result is still in
            # storage, this is a resend of a finished job (a lost /run response, or a guard read that failed at
            # the start): hand the result back rather than overwrite its manifest with an error, which would
            # strand the delivered outputs and make the phone upload and pay for the song again.
            earlier = _earlier_result(storage, job, ("ok", "partial"))
            if earlier is not None:
                log.info("job_duplicate", reason="input already used by a finished run")
                return earlier
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


@dataclass
class _Buffers:
    """The decoded song and, once the job separated them for its own outputs, its vocals. One holder is passed
    down so each stage can let go of an array the moment nothing needs it any more (a 15-minute song is 350 MB
    per array, and the spatial renderer needs room of its own)."""
    mix: np.ndarray | None
    vocals: np.ndarray | None = None


def _delivered(run: _Run) -> bool:
    """Did the job produce anything a phone can use (a stem, lyrics, or a library output that is there now)?"""
    library = run.library or {}
    states = list((library.get("renders") or {}).values()) + [library.get("enhanced")]
    return bool(run.outputs) or run.lyrics is not None or any(s in ("ok", "exists", "not_needed") for s in states)


def _own_outputs(job: Job, run: _Run, models: Models, ctx: Context, deadline: Deadline, storage, work_dir: str,
                 buffers: _Buffers, sr: int, quality: str) -> WorkerError | None:
    """Stages 4-7 for the tasks whose results go into the job's own out/<jobKey>/ folder: separate → [stems4] →
    [lyrics] → encode and upload each stem, then lyrics.json. Returns the lyrics' failure when the job goes on
    without them (None otherwise); every other failure raises. On return buffers.vocals holds the vocals for the
    library stage, when there is one, so the vocal separation never runs twice."""
    clock = ctx.clock
    mix = buffers.mix
    failure: WorkerError | None = None

    # 4 separate
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
    if job.library is None:
        buffers.mix = None  # only the library stage renders from the mix

    # 5 stems4
    if job.wants("stems4"):
        if models.stems4 is None:
            raise WorkerError(INTERNAL, "4-stem separation is not available on this worker")
        deadline.check("stems4")
        ctx.progress("stems4:0")
        with _Stage(run, "stemsMs", clock):
            stems.update(models.stems4.stems(instrumental, sr, progress=_progress_reporter(ctx, deadline, "stems4")))
        run.models["stems4"] = models.stems4.model_id
    del instrumental

    # 6 lyrics. With stems requested, a failure here leaves them intact (status partial). When lyrics are the only
    # output (a song that already has its instrumental), a failure is the job's failure: an error manifest with the
    # code, and the input stays for a retry (partial would delete it and report a result with nothing in it). With
    # library tasks still to come the job goes on, and fails with this code only if they deliver nothing either.
    lyrics_doc = None
    if job.wants("lyrics"):
        ctx.progress("lyrics:0")
        kept = "the instrumental is complete" if "instrumental" in stems else "the other outputs are complete"
        note = f"; {kept}" if stems else ""
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
                log.warning("lyrics_failed", code=exc.code, message=exc.message)
                if not stems and job.library is None:
                    raise
                failure = exc
                run.status = "partial"
                run.refresh_worker = run.refresh_worker or exc.refresh_worker
                run.warnings.append(f"lyrics: failed ({exc.code}){note}")
            except Exception as exc:
                log.error("lyrics_exception", error=type(exc).__name__, trace=redact_exception(exc))
                cuda = "CUDA" in str(exc) or "cuda" in str(exc)
                failure = WorkerError(INTERNAL, f"lyrics failed unexpectedly ({type(exc).__name__})",
                                      refresh_worker=cuda)
                if not stems and job.library is None:
                    raise failure from None
                run.status = "partial"
                run.refresh_worker = run.refresh_worker or cuda
                run.warnings.append(f"lyrics: failed (INTERNAL){note}")
    if job.library is not None:
        buffers.vocals = vocals
    del vocals

    # 7 encode + upload (each output, then lyrics.json; the manifest comes last, after any library work). The
    # deadline no longer aborts here: the 30 s margin is for exactly this, and a finished separation is worth
    # delivering.
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
    return failure


class _LibraryStage:
    """The spatial and enhance tasks (cloud-audio-spec.md, section 4), after the job's own outputs:

        library checks → cutoff analysis → [restore] → [enhanced out] → stems6 → render the missing profiles →
        for each: encode → upload its audio → upload its manifest

    Each output ends in one of the states ok, exists, failed (and not_needed for enhanced). Nothing here raises:
    a failure marks the outputs it costs as failed and is remembered, and _process decides whether the job is
    partial (something was delivered) or an error (nothing was)."""

    def __init__(self, job: Job, run: _Run, models: Models, ctx: Context, deadline: Deadline, storage,
                 work_dir: str):
        self.job, self.run, self.models, self.ctx = job, run, models, ctx
        self.deadline, self.storage, self.work_dir = deadline, storage, work_dir
        self.spec = job.library
        self.failure: WorkerError | None = None
        self.block = {"videoId": self.spec.video_id, "libV": L.LIB_V, "renders": {}, "enhanced": None,
                      "restore": None, "stemMode": None}
        run.library = self.block

    # ---- bookkeeping ------------------------------------------------------------------------------------
    def _set(self, target, state: str) -> None:
        if target.profile is None:
            self.block["enhanced"] = state
        else:
            self.block["renders"][target.profile] = state

    def _failed(self, targets, exc: WorkerError, during: str) -> None:
        log.warning("library_failed", during=during, code=exc.code, message=exc.message,
                    slots=[t.slot for t in targets])
        self.run.refresh_worker = self.run.refresh_worker or exc.refresh_worker
        for target in targets:
            self._set(target, "failed")
            self.run.warnings.append(f"library: {target.slot} failed ({exc.code})")
        if targets:
            self.run.status = "partial"
            self.failure = self.failure or exc

    def _guarded(self, targets, during: str, fn):
        """(True, fn()) or, when it fails, (False, the WorkerError) with `targets` marked failed."""
        try:
            return True, fn()
        except WorkerError as exc:
            error = exc
        except MemoryError:
            error = WorkerError(INTERNAL, f"the worker ran out of memory during {during}", refresh_worker=True)
        except Exception as exc:
            log.error("library_exception", during=during, error=type(exc).__name__, trace=redact_exception(exc))
            cuda = "CUDA" in str(exc) or "cuda" in str(exc)
            error = WorkerError(INTERNAL, f"{during} failed unexpectedly ({type(exc).__name__})", refresh_worker=cuda)
        self._failed(targets, error, during)
        return False, error

    def _existing(self, target) -> dict | None:
        """The finished render that is already in the library for this output, or None: make it."""
        try:
            doc = self.storage.get_library_manifest(target.slot)
        except Exception as exc:  # asking is best effort; any doubt means "make it"
            log.warning("library_manifest_unreadable", slot=target.slot, reason=type(exc).__name__)
            return None
        return doc if L.manifest_matches(doc, video_id=self.spec.video_id, slot=target.slot) else None

    # ---- the stage --------------------------------------------------------------------------------------
    def _state(self, target) -> str | None:
        return self.block["enhanced"] if target.profile is None else self.block["renders"].get(target.profile)

    def run_all(self, buffers: _Buffers, sr: int, quality: str) -> WorkerError | None:
        """Run the whole stage. Lets go of buffers.mix and buffers.vocals. Returns the first failure, if any."""
        try:
            self._run(buffers, sr, quality)
        except Exception as exc:  # a slip in this stage must not cost the outputs that are already delivered
            log.error("library_exception", during="library", error=type(exc).__name__, trace=redact_exception(exc))
            unfinished = [t for t in self.spec.targets() if self._state(t) is None]
            self._failed(unfinished, WorkerError(INTERNAL, f"the library stage failed unexpectedly "
                                                           f"({type(exc).__name__})"), "library")
        finally:
            buffers.mix = buffers.vocals = None
        return self.failure

    def _run(self, buffers: _Buffers, sr: int, quality: str) -> None:
        spec, run = self.spec, self.run
        # library checks: whatever is already there is not made again
        pending = []
        for target in spec.targets():
            existing = self._existing(target)
            if existing is None:
                pending.append(target)
                continue
            entry = L.existing_output(existing)
            if entry is not None:
                run.outputs[target.slot] = entry
            # An enhanced.json without audio says nothing was restored: there is no file to fetch.
            self._set(target, "exists" if entry is not None else "not_needed")
        log.info("library_checked", exists=len(spec.targets()) - len(pending), pending=len(pending))
        if not pending:
            return  # the job ends ok at once: no analysis, no separation
        renders = [t for t in pending if t.profile is not None]
        enhanced = next((t for t in pending if t.profile is None), None)
        frames = int(buffers.mix.shape[0])

        # cutoff analysis, then the restoration when there is something to restore and a model to do it
        done, plan = self._guarded(pending, "restore", lambda: self._analyse(buffers.mix, sr))
        if not done:
            return
        cutoff, run_model, info = plan
        restored = None
        if run_model:
            done, outcome = self._guarded([enhanced] if enhanced is not None else [], "restore",
                                          lambda: self._restore(buffers.mix, sr, cutoff))
            if done:
                restored = outcome
                info = R.RestoreInfo(True, self.models.restorer.model_id, None, info.cutoff_hz)
                run.models["restorer"] = self.models.restorer.model_id
            else:
                # No enhanced file then. The renders are still made, from the song as it is, and their
                # manifests say `restore.reason: failed` (`info` already does).
                run.warnings.append(f"restore: failed ({outcome.code}); the song was left as it is")
        self.block["restore"] = {**info.as_dict(), "cutoffHz": info.cutoff_hz}
        source = {"itag": spec.source_itag, "codec": spec.source_codec, "sampleRate": sr, "decodedSamples": frames,
                  "sha256": self.job.audio.sha256, "cutoffHz": info.cutoff_hz}

        # enhanced out: the restored song, or just the note that nothing was restored (so phones don't ask again)
        if enhanced is not None and self.block["enhanced"] is None:
            if restored is not None:
                self._guarded([enhanced], "enhanced", lambda: self._deliver_enhanced(enhanced, restored, buffers.mix,
                                                                                     sr, source, info))
            else:
                self._guarded([enhanced], "enhanced", lambda: self._note_not_restored(enhanced, source, info))
        if restored is not None:
            buffers.mix, buffers.vocals = restored, None  # the renders are made from the restored song
            restored = None

        # stems6 → render → encode and upload each render, its manifest last
        if not renders:
            return
        done, stems = self._guarded(renders, "stems6", lambda: self._stems6(buffers, sr, quality))
        if not done:
            return
        done, results = self._guarded(renders, "render",
                                      lambda: self._render(buffers.mix, stems, sr, [t.profile for t in renders]))
        stems = None
        buffers.mix = buffers.vocals = None
        if not done:
            return
        self.ctx.progress("upload:0")
        stems_id = self.models.stems6.model_id
        for target in renders:
            result = results.pop(target.profile)
            self._guarded([target], "upload", lambda: self._deliver_render(target, result, sr, source, info, stems_id))
            result = None

    # ---- the steps --------------------------------------------------------------------------------------
    def _analyse(self, mix: np.ndarray, sr: int):
        self.deadline.check("restore")
        with _Stage(self.run, "restoreMs", self.ctx.clock):
            cutoff = R.detect_cutoff_hz(mix, sr)
        run_model, info = R.decide(cutoff, self.spec.restore, self.models.restorer)
        return cutoff, run_model, info

    def _restore(self, mix: np.ndarray, sr: int, cutoff: float) -> np.ndarray:
        self.deadline.check("restore")
        self.ctx.progress("restore:0")
        with _Stage(self.run, "restoreMs", self.ctx.clock):
            restored = self.models.restorer.restore(mix, sr, cutoff,
                                                    progress=_progress_reporter(self.ctx, self.deadline, "restore"))
        restored = np.asarray(restored, dtype=np.float32)
        if restored.shape != mix.shape:
            raise WorkerError(INTERNAL, "the restoration changed the song's length")
        return restored

    def _stems6(self, buffers: _Buffers, sr: int, quality: str) -> dict:
        if self.models.stems6 is None:
            raise WorkerError(INTERNAL, "six-stem separation is not available on this worker")
        self.deadline.check("stems6")
        self.ctx.progress("stems6:0")
        own_vocals = buffers.vocals is not None
        with _Stage(self.run, "stems6Ms", self.ctx.clock):
            stems = self.models.stems6.stems(buffers.mix, sr, quality=quality, vocals=buffers.vocals,
                                             progress=_progress_reporter(self.ctx, self.deadline, "stems6"))
        buffers.vocals = None  # it is one of the stems now
        self.run.models["stems6"] = self.models.stems6.model_id
        if not own_vocals:
            self.run.models["separator"] = getattr(self.models.separator, "model_id", None)
        return stems

    def _render(self, mix: np.ndarray, stems: dict, sr: int, profiles: list) -> dict:
        self.deadline.check("render")
        self.ctx.progress("render:0")
        with _Stage(self.run, "renderMs", self.ctx.clock):
            results = L.render(mix, stems, sr, profiles,
                               progress=_progress_reporter(self.ctx, self.deadline, "render"))
        modes = sorted({result.stem_mode for result in results.values()})
        self.block["stemMode"] = modes[0] if modes else None  # one preparation, so one mode for all of them
        return results

    def _put_flac(self, slot: str, audio: np.ndarray, sr: int) -> dict:
        """Encode (16-bit, dithered) and upload one library file. Returns its `outputs` entry."""
        path = os.path.join(self.work_dir, f"{slot}.flac")
        try:
            with _Stage(self.run, "encodeMs", self.ctx.clock):
                L.encode_flac16(audio, sr, path, timeout=LIBRARY_ENCODE_TIMEOUT_S)
                size, sha = _file_info(path)
            with _Stage(self.run, "uploadMs", self.ctx.clock):
                key = self.storage.put_library_audio(slot, path)
        finally:
            try:
                os.remove(path)
            except OSError:
                pass
        return L.output_entry(key, size, sha, sr, int(audio.shape[0]))

    def _put_manifest(self, slot: str, entry: dict | None, loudness: dict | None, source: dict, info, *,
                      engine: str | None = None, stems: str | None = None, stem_mode: str | None = None) -> None:
        audio = None
        if entry is not None:
            audio = L.audio_block(entry["key"], entry["bytes"], entry["sha256"], entry["sampleRate"], entry["samples"])
        doc = L.render_manifest(video_id=self.spec.video_id, slot=slot, audio=audio, loudness=loudness,
                                source=source, engine=engine, stems=stems, stem_mode=stem_mode,
                                restore=info.as_dict(), worker=self.ctx.worker, created_at=L.utc_now(self.ctx.now()))
        with _Stage(self.run, "uploadMs", self.ctx.clock):
            self.storage.put_library_manifest(slot, _encode_json(doc))

    def _deliver_render(self, target, result, sr: int, source: dict, info, stems_id: str) -> None:
        entry = self._put_flac(target.slot, result.audio, sr)
        loudness = L.loudness_block(result.integrated_lufs, result.source_lufs, L.HEADROOM_DB, result.true_peak_db,
                                    result.limiter_max_db)
        self._put_manifest(target.slot, entry, loudness, source, info, engine=L.ENGINE_ID,
                           stems=stems_id if result.stem_mode != "mix" else None, stem_mode=result.stem_mode)
        self.run.outputs[target.slot] = entry
        self._set(target, "ok")

    def _deliver_enhanced(self, target, restored: np.ndarray, mix: np.ndarray, sr: int, source: dict, info) -> None:
        loudness = L.stereo_loudness(restored, mix, sr)  # not lowered: the restored song has the source's level
        entry = self._put_flac(target.slot, restored, sr)
        self._put_manifest(target.slot, entry, loudness, source, info)
        self.run.outputs[target.slot] = entry
        self._set(target, "ok")

    def _note_not_restored(self, target, source: dict, info) -> None:
        self._put_manifest(target.slot, None, None, source, info)
        self._set(target, "not_needed")


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
        storage.fetch_input(src, total_timeout=deadline.budget(download_budget_s(job.audio.bytes)))

    # 2-3 probe + decode
    deadline.check("decode")
    ctx.progress("decode:0")
    with _Stage(run, "decodeMs", clock):
        info = A.probe(src, caps, timeout=deadline.budget(15.0))
        if job.output.codec == "aac" and job.stem_slots() and info.sample_rate not in A.AAC_SAMPLE_RATES:
            # ffmpeg would quietly resample (192 kHz -> 96 kHz), so the stem's rate and sample count would not be
            # the input's and the phone's import check would reject it after a billed separation. Fail before it.
            raise WorkerError(UNSUPPORTED_FORMAT, f"AAC output can't keep a {info.sample_rate} Hz input's sample "
                                                  "rate; ask for flac output")
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

    quality = job.quality
    if quality == "best" and duration_ms > caps.best_max_audio_s * 1000:
        quality = "standard"
        run.warnings.append(f"separation: best quality is limited to {caps.best_max_audio_s // 60} minutes; used standard")

    # The parts of a job that may fail without failing it (lyrics next to stems, each library output) report here;
    # the first one becomes the job's error when in the end nothing at all was delivered.
    first_failure: WorkerError | None = None
    buffers = _Buffers(mix=mix)
    del mix
    if job.wants_own_outputs():
        first_failure = _own_outputs(job, run, models, ctx, deadline, storage, work_dir, buffers, sr, quality)
    if job.library is not None:
        library_failure = _LibraryStage(job, run, models, ctx, deadline, storage, work_dir).run_all(buffers, sr, quality)
        first_failure = first_failure or library_failure
    buffers.mix = buffers.vocals = None
    if first_failure is not None and not _delivered(run):
        raise first_failure
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
