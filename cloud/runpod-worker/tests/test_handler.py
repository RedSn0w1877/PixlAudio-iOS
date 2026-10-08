"""handler.Worker: dispatch, the error contract RunPod sees, cold-start accounting, the selftest answer (validated
against its schema), the rejection manifest, that no URL or signature ever reaches a returned error, and when the
worker asks RunPod to stop it (refresh_worker) without changing the job's output."""

import asyncio
import copy
import json

import jsonschema
import numpy as np
import pytest

from conftest import EXAMPLE_HOST, load_example, load_schema
from pixl_worker import handler, pipeline
from pixl_worker.config import load_caps

SELFTEST = jsonschema.Draft202012Validator(load_schema("selftest.result"))
INFO = {"version": "1.0.0", "gitSha": "abc1234def56", "gpu": None, "vramGB": None, "cuda": None}


class Sep:
    model_id = "fake-separator"

    def vocals(self, mix, sr, *, quality="standard", progress=None):
        return (mix * 0.5).astype(np.float32)


def make_worker(tmp_path, written=None):
    caps = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_TMP_ROOT": str(tmp_path)})
    written = written if written is not None else []

    def factory(job, caps_):
        class Store:
            def put_json(self, slot, data):
                written.append((slot, json.loads(data)))
        return Store()

    return handler.Worker(caps, pipeline.Models(separator=Sep()), INFO, 4321,
                          lambda: {"anvuew-bs-roformer-ft1": True, "qwen3-asr-1.7b": "lazy"},
                          storage_factory=factory), written


def test_selftest_answer_matches_its_schema_and_reports_caps(tmp_path):
    worker, _ = make_worker(tmp_path)
    out = worker.handle({"id": "j1", "input": {"v": 1, "op": "selftest"}})
    SELFTEST.validate(out)
    assert out["supported"] == [1] and out["coldStartMs"] == 4321
    assert out["caps"]["maxInputMB"] == 160 and out["caps"]["hostsConfigured"] == 1
    assert worker.handle({"id": "j2", "input": {"v": 1, "op": "selftest"}})["coldStartMs"] == 0  # first job only


def test_unknown_version_and_op_fail_fast(tmp_path):
    worker, _ = make_worker(tmp_path)
    assert worker.handle({"id": "j", "input": {"v": 9, "op": "selftest"}})["error"].startswith("UNSUPPORTED_VERSION:")
    assert worker.handle({"id": "j", "input": {"v": 1, "op": "mine-bitcoin"}})["error"].startswith("BAD_OP:")
    assert worker.handle({"id": "j", "input": None})["error"].startswith("BAD_SCHEMA:")


def test_a_rejected_process_job_writes_its_error_manifest(tmp_path):
    worker, written = make_worker(tmp_path)
    doc = load_example("job.input.process.json")
    doc["audio"]["get"] = doc["audio"]["get"].replace(EXAMPLE_HOST, "attacker.example.com")
    out = worker.handle({"id": "j", "input": doc})
    assert out["error"].startswith("BAD_URL:")
    assert "X-Amz" not in out["error"] and "attacker" not in out["error"]
    (slot, manifest), = written
    assert slot == "manifest" and manifest["error"]["code"] == "BAD_URL"


def test_bench_crash_flag_is_refused_without_the_test_switch(tmp_path):
    worker, _ = make_worker(tmp_path)
    out = worker.handle({"id": "j", "input": {"v": 1, "op": "bench", "bench": {"crash": True}}})
    assert out["error"].startswith("BAD_SCHEMA:")


def test_bench_runs_the_stages_it_can(tmp_path):
    worker, _ = make_worker(tmp_path)
    out = worker.handle({"id": "j", "input": {"v": 1, "op": "bench", "bench": {"seconds": 10, "stages": ["separate"]}}})
    assert out["status"] == "ok" and "separate" in out["stagesMs"] and out["coldStartMs"] == 4321


def test_unexpected_exceptions_become_INTERNAL_without_details(tmp_path, monkeypatch):
    worker, _ = make_worker(tmp_path)

    def explode(*args, **kwargs):
        raise RuntimeError("https://x.r2.cloudflarestorage.com/in/a.m4a?X-Amz-Signature=" + "a" * 64)

    monkeypatch.setattr(handler.st, "selftest", explode)
    out = worker.handle({"id": "j", "input": {"v": 1, "op": "selftest"}})
    assert out == {"error": "INTERNAL: unexpected RuntimeError", "refresh_worker": True}  # a selftest: stop after it


def test_bench_never_inherits_a_finished_jobs_deadline(tmp_path):
    from pixl_worker.deadline import Deadline
    from pixl_worker.lyrics import languages

    class Aligner:
        model_id = "fake-aligner"

        def __init__(self):
            self.deadline = Deadline(0)  # long expired: what an earlier process job used to leave behind

        def supports(self, language):
            return language == "en"

        def align(self, requests):
            if self.deadline is not None:
                self.deadline.check("lyrics")
            return [[] for _ in requests]

    languages.clear_backends()
    languages.register_backend(Aligner())
    try:
        worker, _ = make_worker(tmp_path)
        out = worker.handle({"id": "j", "input": {"v": 1, "op": "bench",
                                                  "bench": {"seconds": 10, "stages": ["align"]}}})
    finally:
        languages.clear_backends()
    assert out.get("status") == "ok", out
    assert "align" in out["stagesMs"] and out["stagesMs"]["alignWindows"] == 2


# ---- stopping the worker after the jobs nothing follows (refresh_worker) -----------------------------------

RESULT = jsonschema.Draft202012Validator(load_schema("job.result"))


def sdk_view(returned: dict) -> tuple[dict, bool]:
    """What runpod 1.12.0 makes of a handler's dict (serverless/modules/rp_job.py, run_job): it pops `error` and
    `refresh_worker`, the rest is the job's output, and a truthy refresh_worker becomes `stopPod: True`."""
    out = dict(returned)
    out.pop("error", None)
    stop = bool(out.pop("refresh_worker", None))
    return out, stop


def canned_process(monkeypatch, result: dict, seen: list):
    def process(spec, runpod_job_id, models, ctx, deadline):
        seen.append(spec)
        return copy.deepcopy(result)

    monkeypatch.setattr(handler.pipeline, "process", process)


def test_selftest_and_bench_stop_the_worker_and_keep_their_output(tmp_path):
    worker, _ = make_worker(tmp_path)
    out = worker.handle({"id": "j1", "input": {"v": 1, "op": "selftest"}})
    assert out["refresh_worker"] is True
    output, stop = sdk_view(out)
    assert stop and "refresh_worker" not in output
    SELFTEST.validate(output)
    assert output["caps"]["maxInputMB"] == 160  # the answer the phone and the deploy read is unchanged
    out = worker.handle({"id": "j2", "input": {"v": 1, "op": "bench", "bench": {"seconds": 10, "stages": ["separate"]}}})
    output, stop = sdk_view(out)
    assert stop and output["status"] == "ok" and "separate" in output["stagesMs"]


def test_a_refused_selftest_or_bench_still_stops_the_worker(tmp_path):
    worker, _ = make_worker(tmp_path)
    out = worker.handle({"id": "j", "input": {"v": 9, "op": "selftest"}})
    assert out["error"].startswith("UNSUPPORTED_VERSION:") and out["refresh_worker"] is True
    out = worker.handle({"id": "j", "input": {"v": 1, "op": "bench", "bench": {"crash": True}}})
    assert out["error"].startswith("BAD_SCHEMA:") and out["refresh_worker"] is True


def test_the_last_job_of_a_burst_stops_the_worker_and_its_manifest_is_unchanged(tmp_path, monkeypatch):
    manifest = load_example("job.result.ok.json")
    seen = []
    canned_process(monkeypatch, manifest, seen)
    worker, _ = make_worker(tmp_path)
    doc = load_example("job.input.process.json")
    assert doc["policy"] == {"last_in_batch": True}
    out = worker.handle({"id": "j", "input": doc})
    assert seen[-1].last_in_batch is True
    assert out["refresh_worker"] is True
    output, stop = sdk_view(out)
    assert stop
    expected = dict(manifest)
    expected.pop("error")  # runpod pops `error` (null on ok) from every dict output, flag or not
    assert output == expected
    RESULT.validate({**output, "error": None})


def test_jobs_before_the_last_keep_the_worker_warm(tmp_path, monkeypatch):
    manifest = load_example("job.result.ok.json")
    seen = []
    canned_process(monkeypatch, manifest, seen)
    worker, _ = make_worker(tmp_path)
    for policy in (None, {}, {"last_in_batch": False}):
        doc = load_example("job.input.process.json")
        if policy is None:
            del doc["policy"]  # an older app: no policy at all
        else:
            doc["policy"] = policy
        out = worker.handle({"id": "j", "input": doc})
        assert seen[-1].last_in_batch is False
        assert "refresh_worker" not in out, policy
        assert out == manifest


def test_a_failed_last_job_still_stops_the_worker(tmp_path, monkeypatch):
    seen = []
    canned_process(monkeypatch, {"error": "DEADLINE: the job ran out of time", "refresh_worker": False}, seen)
    worker, _ = make_worker(tmp_path)
    out = worker.handle({"id": "j", "input": load_example("job.input.process.json")})
    assert out == {"error": "DEADLINE: the job ran out of time", "refresh_worker": True}
    # A worker that has to recycle itself (GPU_OOM, CUDA) still does, last of a burst or not.
    canned_process(monkeypatch, {"error": "GPU_OOM: out of memory", "refresh_worker": True}, seen)
    doc = load_example("job.input.process.json")
    del doc["policy"]
    assert worker.handle({"id": "j", "input": doc})["refresh_worker"] is True


def test_a_rejected_last_job_still_stops_the_worker(tmp_path):
    worker, written = make_worker(tmp_path)
    doc = load_example("job.input.process.json")
    doc["audio"]["get"] = doc["audio"]["get"].replace(EXAMPLE_HOST, "attacker.example.com")
    out = worker.handle({"id": "j", "input": doc})
    assert out["error"].startswith("BAD_URL:") and out["refresh_worker"] is True
    assert written and written[0][1]["error"]["code"] == "BAD_URL"
    doc["policy"]["last_in_batch"] = "yes"  # not a boolean: refused, and not taken as true either
    out = worker.handle({"id": "j", "input": doc})
    assert out["error"].startswith(("BAD_URL:", "BAD_SCHEMA:")) and "refresh_worker" not in out


def test_refresh_reason():
    assert handler.refresh_reason({"op": "selftest"}) == "selftest"
    assert handler.refresh_reason({"op": "bench"}) == "bench"
    assert handler.refresh_reason({"op": "process", "policy": {"last_in_batch": True}}) == "last_in_batch"
    for raw in (None, "x", [], {"op": "process"}, {"op": "process", "policy": True},
                {"op": "process", "policy": {"last_in_batch": 1}}, {"op": "process", "policy": {"lastInBatch": True}}):
        assert handler.refresh_reason(raw) is None, raw


def test_the_real_runpod_sdk_turns_the_flag_into_stopPod_and_keeps_the_output(tmp_path, monkeypatch):
    """The same contract against the installed runpod (the image has 1.12.0; the CPU test stage doesn't)."""
    pytest.importorskip("runpod")
    from runpod.serverless.modules.rp_job import run_job

    manifest = load_example("job.result.ok.json")
    canned_process(monkeypatch, manifest, [])
    worker, _ = make_worker(tmp_path)
    expected = dict(manifest)
    expected.pop("error")

    last = asyncio.run(run_job(worker.handle, {"id": "j1", "input": load_example("job.input.process.json")}))
    assert last == {"output": expected, "stopPod": True}

    doc = load_example("job.input.process.json")
    del doc["policy"]
    warm = asyncio.run(run_job(worker.handle, {"id": "j2", "input": doc}))
    assert warm == {"output": expected}

    selftest = asyncio.run(run_job(worker.handle, {"id": "j3", "input": {"v": 1, "op": "selftest"}}))
    assert selftest["stopPod"] is True and "refresh_worker" not in selftest["output"]
    SELFTEST.validate(selftest["output"])
