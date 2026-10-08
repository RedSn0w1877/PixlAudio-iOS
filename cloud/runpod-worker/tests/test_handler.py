"""handler.Worker: dispatch, the error contract RunPod sees, cold-start accounting, the selftest answer (validated
against its schema), the rejection manifest, and that no URL or signature ever reaches a returned error."""

import json

import jsonschema
import numpy as np

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
    assert out == {"error": "INTERNAL: unexpected RuntimeError"}
