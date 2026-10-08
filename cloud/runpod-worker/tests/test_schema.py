"""The golden examples are the contract with the iOS app (PixlNet decodes them). Every example must validate
against its JSON Schema, and the stdlib validator must agree with jsonschema on good and broken inputs."""

import copy
import json

import jsonschema
import pytest

from conftest import EXAMPLES, load_example, load_schema
from pixl_worker import errors
from pixl_worker.config import load_caps
from pixl_worker.schema import validate_job

SCHEMA_FOR = {
    "job.input": "job.input",
    "run.request": "job.input",
    "job.result": "job.result",
    "selftest.result": "selftest.result",
    "attempt": "attempt",
    "lyrics": "lyrics",
}


def _schema_name(file_name: str) -> str:
    for prefix, schema in SCHEMA_FOR.items():
        if file_name.startswith(prefix):
            return schema
    raise AssertionError(f"no schema for {file_name}")


ALL_EXAMPLES = sorted(p.name for p in EXAMPLES.glob("*.json"))


def test_every_schema_is_valid_draft_2020_12():
    for name in set(SCHEMA_FOR.values()):
        jsonschema.Draft202012Validator.check_schema(load_schema(name))


@pytest.mark.parametrize("name", ALL_EXAMPLES)
def test_example_validates_against_its_schema(name):
    doc = load_example(name)
    if name.startswith("run.request"):
        assert set(doc) == {"input", "policy"}
        assert doc["policy"] == {"ttl": 259200000, "executionTimeout": 900000}
        doc = doc["input"]
    jsonschema.Draft202012Validator(load_schema(_schema_name(name))).validate(doc)


@pytest.mark.parametrize("name", [n for n in ALL_EXAMPLES if n.startswith("job.input")])
def test_stdlib_validator_accepts_input_examples(name, caps):
    job = validate_job(load_example(name), caps)
    assert job.op == load_example(name)["op"]


def test_examples_are_lf_utf8_and_pretty():
    for path in EXAMPLES.glob("*.json"):
        raw = path.read_bytes()
        assert b"\r\n" not in raw, path.name
        text = raw.decode("utf-8")
        assert text == json.dumps(json.loads(text), ensure_ascii=False, indent=2) + "\n", path.name


def test_process_example_normalises(caps):
    job = validate_job(load_example("job.input.process.json"), caps)
    assert job.job_key == "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10"
    assert job.tasks == ("instrumental", "lyrics")
    assert job.lyrics.language == "ko" and job.lyrics.synced and job.lyrics.effective_mode == "align"
    assert job.lyrics.lines[3].end_ms is None
    assert job.output.codec == "aac" and job.output.kbps == 256
    assert set(job.output.put) == {"instrumental", "lyrics", "manifest"}
    assert job.guard is not None
    assert job.object_key("instrumental") == f"out/{job.job_key}/instrumental.m4a"
    assert job.stem_slots() == ("instrumental",)


def test_last_in_batch_is_optional_and_false_by_default(caps):
    assert validate_job(load_example("job.input.process.json"), caps).last_in_batch is True
    for name in ("job.input.transcribe.json", "job.input.volume.json"):
        assert "policy" not in load_example(name)
        assert validate_job(load_example(name), caps).last_in_batch is False
    doc = _process()
    doc["policy"] = {}
    assert validate_job(doc, caps).last_in_batch is False
    doc["policy"] = {"last_in_batch": False, "future": 1}  # unknown policy fields are ignored, like everywhere
    assert validate_job(doc, caps).last_in_batch is False
    jsonschema.Draft202012Validator(load_schema("job.input")).validate(doc)
    assert validate_job({"v": 1, "op": "selftest", "policy": {"last_in_batch": True}}, caps).last_in_batch is False


def test_transcribe_example_is_auto_transcribe(caps):
    job = validate_job(load_example("job.input.transcribe.json"), caps)
    assert job.lyrics.effective_mode == "transcribe"
    assert job.output.codec == "flac" and job.object_key("instrumental").endswith("instrumental.flac")
    assert job.guard is None and job.quality == "best"


def test_selftest_without_schema_field_is_fine(caps):
    assert validate_job({"v": 1, "op": "selftest"}, caps).op == "selftest"


def _process():
    return copy.deepcopy(load_example("job.input.process.json"))


def _mutations():
    """(description, mutate(doc), expected stdlib code, jsonschema also rejects?)"""

    def setp(path, value):
        def f(doc):
            target = doc
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
        return f

    def delp(path):
        def f(doc):
            target = doc
            for key in path[:-1]:
                target = target[key]
            del target[path[-1]]
        return f

    good_sig = "X-Amz-Signature=" + "a" * 64
    host = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/pixl-cloud-studio"
    jk = "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10"
    return [
        ("v 2", setp(["v"], 2), errors.UNSUPPORTED_VERSION, True),
        ("v true", setp(["v"], True), errors.UNSUPPORTED_VERSION, True),
        ("op", setp(["op"], "explode"), errors.BAD_OP, True),
        ("schema name", setp(["schema"], "pixl.other"), errors.BAD_SCHEMA, True),
        ("jobKey upper", setp(["jobKey"], jk.upper()), errors.BAD_SCHEMA, True),
        ("no tasks", setp(["tasks"], []), errors.BAD_SCHEMA, True),
        ("bad task", setp(["tasks"], ["karaoke"]), errors.BAD_SCHEMA, True),
        ("dup task", setp(["tasks"], ["lyrics", "lyrics"]), errors.BAD_SCHEMA, True),
        ("lyrics missing", delp(["lyrics"]), errors.BAD_SCHEMA, True),
        ("bytes string", setp(["audio", "bytes"], "7712345"), errors.BAD_SCHEMA, True),
        ("sha upper", setp(["audio", "sha256"], "A" * 64), errors.BAD_SCHEMA, True),
        ("ext", setp(["audio", "ext"], "exe"), errors.BAD_SCHEMA, True),
        ("kbps", setp(["output", "kbps"], 320), errors.BAD_SCHEMA, True),
        ("codec", setp(["output", "codec"], "mp3"), errors.BAD_SCHEMA, True),
        ("no manifest put", delp(["output", "put", "manifest"]), errors.BAD_SCHEMA, True),
        ("no lyrics put", delp(["output", "put", "lyrics"]), errors.BAD_SCHEMA, False),
        ("quality", setp(["separation", "quality"], "ultra"), errors.BAD_SCHEMA, True),
        ("mode", setp(["lyrics", "mode"], "guess"), errors.BAD_SCHEMA, True),
        ("lang", setp(["lyrics", "language"], "Korean"), errors.BAD_SCHEMA, True),
        ("synced line without start", delp(["lyrics", "lines", 0, "startMs"]), errors.BAD_SCHEMA, False),
        ("unsorted lines", setp(["lyrics", "lines", 1, "startMs"], 1), errors.BAD_SCHEMA, False),
        ("http url", setp(["audio", "get"], f"http://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/b/in/{jk}.m4a?{good_sig}"),
         errors.BAD_URL, True),
        ("foreign host", setp(["audio", "get"], f"https://evil.example.com/in/{jk}.m4a?{good_sig}"), errors.BAD_URL, False),
        ("other account", setp(["audio", "get"], f"https://ffff.r2.cloudflarestorage.com/b/in/{jk}.m4a?{good_sig}"),
         errors.BAD_URL, False),
        ("unsigned", setp(["audio", "get"], f"{host}/in/{jk}.m4a"), errors.BAD_URL, False),
        ("wrong object", setp(["audio", "get"], f"{host}/in/00000000-0000-0000-0000-000000000000.m4a?{good_sig}"),
         errors.BAD_URL, False),
        ("put to input", setp(["output", "put", "instrumental"], f"{host}/in/{jk}.m4a?{good_sig}"), errors.BAD_URL, False),
        ("port", setp(["audio", "get"], f"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com:8443/b/in/{jk}.m4a?{good_sig}"),
         errors.BAD_URL, False),
        ("userinfo", setp(["audio", "get"], f"https://u:p@0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/b/in/{jk}.m4a?{good_sig}"),
         errors.BAD_URL, False),
        ("dotdot", setp(["audio", "get"], f"{host}/x/../in/{jk}.m4a?{good_sig}"), errors.BAD_URL, False),
        ("guard incomplete", delp(["guard", "attemptPut"]), errors.BAD_SCHEMA, True),
        ("policy not an object", setp(["policy"], "last"), errors.BAD_SCHEMA, True),
        ("last_in_batch not a boolean", setp(["policy", "last_in_batch"], "yes"), errors.BAD_SCHEMA, True),
        ("last_in_batch a number", setp(["policy", "last_in_batch"], 1), errors.BAD_SCHEMA, True),
    ]


@pytest.mark.parametrize("desc,mutate,code,schema_rejects", _mutations(), ids=[m[0] for m in _mutations()])
def test_broken_inputs_are_rejected(desc, mutate, code, schema_rejects, caps):
    doc = _process()
    mutate(doc)
    with pytest.raises(errors.WorkerError) as info:
        validate_job(doc, caps)
    assert info.value.code == code, (desc, info.value.message)
    # Messages are stored in manifests and logs: they must never echo a URL or a signature.
    assert "://" not in info.value.message and "X-Amz" not in info.value.message
    if schema_rejects:
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(load_schema("job.input")).validate(doc)


def test_unknown_fields_are_ignored(caps):
    doc = _process()
    doc["future"] = {"anything": True}
    doc["audio"]["futureField"] = 1
    doc["output"]["put"]["futureSlot"] = "whatever"
    assert validate_job(doc, caps).op == "process"
    jsonschema.Draft202012Validator(load_schema("job.input")).validate(doc)


def test_empty_allowlist_fails_closed():
    with pytest.raises(errors.WorkerError) as info:
        validate_job(_process(), load_caps({}))
    assert info.value.code == errors.BAD_URL


def test_body_cap(caps):
    doc = _process()
    doc["padding"] = "x" * (300 * 1024)
    with pytest.raises(errors.WorkerError) as info:
        validate_job(doc, caps)
    assert info.value.code == errors.BAD_SCHEMA


def test_lyrics_caps():
    from conftest import EXAMPLE_HOST

    small = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_MAX_LYRICS_LINES": "2"})
    with pytest.raises(errors.WorkerError):
        validate_job(_process(), small)
    chars = load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_MAX_LYRICS_CHARS": "10"})
    with pytest.raises(errors.WorkerError):
        validate_job(_process(), chars)


def test_stems4_needs_three_slots(caps):
    doc = _process()
    doc["tasks"] = ["instrumental", "stems4"]
    del doc["lyrics"]
    with pytest.raises(errors.WorkerError) as info:
        validate_job(doc, caps)
    assert "drums" in info.value.message or "bass" in info.value.message or "other" in info.value.message


def test_volume_key_must_match_job(caps):
    doc = load_example("job.input.volume.json")
    doc["audio"]["key"] = "in/00000000-0000-0000-0000-000000000000.m4a"
    with pytest.raises(errors.WorkerError):
        validate_job(doc, caps)


def test_language_tags_normalise(caps):
    doc = _process()
    doc["lyrics"]["language"] = "zh-Hant"
    assert validate_job(doc, caps).lyrics.language == "zh"
    doc["lyrics"]["language"] = "yue"
    assert validate_job(doc, caps).lyrics.language == "yue"


def test_bench_defaults(caps):
    job = validate_job({"v": 1, "op": "bench"}, caps)
    assert job.bench.seconds == 240 and "separate" in job.bench.stages and job.bench.crash is False
    with pytest.raises(errors.WorkerError):
        validate_job({"v": 1, "op": "bench", "bench": {"stages": ["mine"]}}, caps)
