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
    "library.render": "library.render",
}
# RunPod's own request policy next to `input`: three days in the queue at most, and the endpoint's time limit
# (deploy/endpoint.json). A job with library tasks does more work and gets the whole 30 minutes; the worker's own
# deadline (PIXL_EXECUTION_TIMEOUT_S minus 30 s) only fits inside the limit the phone sends when it sends this one.
RUN_POLICY = {
    "run.request.json": {"ttl": 259200000, "executionTimeout": 900000},
    "run.request.spatial.json": {"ttl": 259200000, "executionTimeout": 1800000},
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
        assert doc["policy"] == RUN_POLICY[name]
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
    assert "stems6" in job.bench.stages and "render" in job.bench.stages  # the default bench covers the spatial path
    with pytest.raises(errors.WorkerError):
        validate_job({"v": 1, "op": "bench", "bench": {"stages": ["mine"]}}, caps)


# ---- the shared library: the spatial task (cloud-audio-spec.md, section 4) ---------------------------------

HOST = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/pixl-cloud-studio"
SIG = "X-Amz-Signature=" + "a" * 64
VIDEO = "J7p4bzqLvCw"
LIB = f"lib/v1/{VIDEO}"
INPUT_SCHEMA = jsonschema.Draft202012Validator(load_schema("job.input"))


def _spatial():
    return copy.deepcopy(load_example("job.input.spatial.json"))


def test_the_library_version_lives_in_one_place():
    from pixl_worker import library, schema

    assert library.LIB_V == 1 and schema.LIB_V is library.LIB_V
    assert load_schema("job.input")["$defs"]["library"]["properties"]["v"]["const"] == library.LIB_V
    assert library.audio_key(VIDEO, "sp-studio") == f"lib/v{library.LIB_V}/{VIDEO}/sp-studio.flac"
    assert library.manifest_key(VIDEO, "sp-night") == f"lib/v{library.LIB_V}/{VIDEO}/sp-night.json"
    for name in ALL_EXAMPLES:  # every example that names a library object names this version
        text = (EXAMPLES / name).read_text(encoding="utf-8")
        assert "lib/v" not in text.replace(f"lib/v{library.LIB_V}/", ""), name


def test_the_schemas_list_the_renderers_profiles_and_the_workers_tasks_and_stages():
    from pixl_worker import schema
    from pixl_worker.spatial import PROFILE_IDS

    job_input, result, render = load_schema("job.input"), load_schema("job.result"), load_schema("library.render")
    assert tuple(job_input["$defs"]["profile"]["enum"]) == PROFILE_IDS
    assert tuple(job_input["properties"]["tasks"]["items"]["enum"]) == schema.TASKS
    assert tuple(job_input["$defs"]["bench"]["properties"]["stages"]["items"]["enum"]) == schema.BENCH_STAGES
    library_block = result["properties"]["library"]["oneOf"][1]["properties"]
    assert tuple(library_block["renders"]["propertyNames"]["enum"]) == PROFILE_IDS
    assert tuple(render["properties"]["profile"]["enum"]) == PROFILE_IDS
    assert "|".join(PROFILE_IDS) in render["$defs"]["audio"]["properties"]["key"]["pattern"]
    assert job_input["$defs"]["library"]["properties"]["renders"]["maxItems"] == len(PROFILE_IDS)
    spatial = next(rule for rule in job_input["allOf"]
                   if rule["if"]["properties"].get("tasks", {}).get("contains") == {"const": "spatial"})
    assert spatial["then"]["required"] == ["library"]


def test_spatial_example_normalises(caps):
    job = validate_job(load_example("job.input.spatial.json"), caps)
    assert job.tasks == ("spatial",) and not job.wants_own_outputs() and job.stem_slots() == ()
    lib = job.library
    assert lib.video_id == VIDEO and lib.source_itag == 251 and lib.source_codec == "opus"
    assert [t.slot for t in lib.renders] == ["sp-studio"]
    studio = lib.target("sp-studio")
    assert studio.profile == "studio" and f"/{LIB}/sp-studio.flac?" in studio.audio_put
    assert f"/{LIB}/sp-studio.json?" in studio.manifest_put and f"/{LIB}/sp-studio.json?" in studio.manifest_get
    assert set(job.output.put) == {"manifest"} and job.guard is not None and job.last_in_batch
    with pytest.raises(KeyError):
        lib.target("sp-wide")
    # the /run body's input is the same job
    assert load_example("run.request.spatial.json")["input"] == load_example("job.input.spatial.json")


def test_combined_example_keeps_its_own_outputs_and_defaults(caps):
    job = validate_job(load_example("job.input.spatial.combined.json"), caps)
    assert job.tasks == ("instrumental", "spatial") and job.wants_own_outputs() and job.stem_slots() == ("instrumental",)
    assert [t.profile for t in job.library.renders] == ["night", "hall"]  # the order they were asked for
    assert job.library.renders[0].manifest_get and job.library.renders[1].manifest_get is None
    assert job.library.source_itag == 140


def test_library_is_ignored_without_its_tasks(caps):
    for junk in ("anything", 7, {"v": 99, "videoId": "nope", "renders": "x"}, []):
        doc = _process()
        doc["library"] = junk
        assert validate_job(doc, caps).library is None
        INPUT_SCHEMA.validate(doc)
    doc = load_example("job.input.volume.json")  # the volume fallback still works for the older tasks
    doc["library"] = {"v": 2}
    assert validate_job(doc, caps).library is None


def test_spatial_is_the_only_library_task(caps):
    # Enhanced audio was cut before release (2026-11-11): "enhance" is no task, like any other unknown name.
    doc = _spatial()
    doc["tasks"] = ["spatial", "enhance"]
    with pytest.raises(errors.WorkerError) as info:
        validate_job(doc, caps)
    assert info.value.code == errors.BAD_SCHEMA
    with pytest.raises(jsonschema.ValidationError):
        INPUT_SCHEMA.validate(doc)


def test_optional_library_fields(caps):
    doc = _spatial()
    del doc["library"]["source"], doc["library"]["renders"][0]["manifestGet"]
    job = validate_job(doc, caps)
    INPUT_SCHEMA.validate(doc)
    assert (job.library.source_itag, job.library.source_codec) == (None, None)
    assert job.library.renders[0].manifest_get is None
    doc["library"]["source"] = {"codec": "aac", "future": True}
    doc["library"]["future"] = [1, 2]
    doc["library"]["renders"][0]["future"] = "x"
    job = validate_job(doc, caps)
    INPUT_SCHEMA.validate(doc)
    assert (job.library.source_itag, job.library.source_codec) == (None, "aac")


def test_all_six_profiles_in_one_job(caps):
    from pixl_worker.spatial import PROFILE_IDS

    doc = _spatial()
    doc["library"]["renders"] = [
        {"profile": p, "audioPut": f"{HOST}/{LIB}/sp-{p}.flac?{SIG}", "manifestPut": f"{HOST}/{LIB}/sp-{p}.json?{SIG}",
         "manifestGet": f"{HOST}/{LIB}/sp-{p}.json?{SIG}"} for p in reversed(PROFILE_IDS)]
    job = validate_job(doc, caps)
    INPUT_SCHEMA.validate(doc)
    assert [t.profile for t in job.library.renders] == list(reversed(PROFILE_IDS))


def _library_mutations():
    """(description, mutate(doc), expected stdlib code, jsonschema also rejects?) on job.input.spatial.json."""

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

    def volume(doc):
        doc["storage"] = "volume"
        doc["audio"]["key"] = f"in/{doc['jobKey']}.flac"

    def seven(doc):
        doc["library"]["renders"] = doc["library"]["renders"] * 7

    def twice(doc):
        doc["library"]["renders"].append(copy.deepcopy(doc["library"]["renders"][0]))

    render = ["library", "renders", 0]
    jk = "3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804"
    return [
        ("library missing", delp(["library"]), errors.BAD_SCHEMA, True),
        ("library null", setp(["library"], None), errors.BAD_SCHEMA, True),
        ("library not an object", setp(["library"], "v1"), errors.BAD_SCHEMA, True),
        ("library.v 2", setp(["library", "v"], 2), errors.UNSUPPORTED_VERSION, True),
        ("library.v 0", setp(["library", "v"], 0), errors.UNSUPPORTED_VERSION, True),
        ("library.v missing", delp(["library", "v"]), errors.UNSUPPORTED_VERSION, True),
        ("library.v true", setp(["library", "v"], True), errors.UNSUPPORTED_VERSION, True),
        ("library.v a string", setp(["library", "v"], "1"), errors.UNSUPPORTED_VERSION, True),
        ("videoId missing", delp(["library", "videoId"]), errors.BAD_SCHEMA, True),
        ("videoId too short", setp(["library", "videoId"], VIDEO[:-1]), errors.BAD_SCHEMA, True),
        ("videoId with a slash", setp(["library", "videoId"], "J7p4bzqLv/w"), errors.BAD_SCHEMA, True),
        ("videoId is a Spotify id", setp(["library", "videoId"], "0VjIjW4GlUZAMYd2vXMi3b"), errors.BAD_SCHEMA, True),
        ("videoId a number", setp(["library", "videoId"], 12345678901), errors.BAD_SCHEMA, True),
        ("videoId with a line break", setp(["library", "videoId"], VIDEO + "\n"), errors.BAD_SCHEMA, False),
        ("source not an object", setp(["library", "source"], "opus"), errors.BAD_SCHEMA, True),
        ("itag a string", setp(["library", "source", "itag"], "251"), errors.BAD_SCHEMA, True),
        ("itag true", setp(["library", "source", "itag"], True), errors.BAD_SCHEMA, True),
        ("itag negative", setp(["library", "source", "itag"], -1), errors.BAD_SCHEMA, True),
        ("itag beyond 32 bits", setp(["library", "source", "itag"], 2 ** 31), errors.BAD_SCHEMA, True),
        ("codec too long", setp(["library", "source", "codec"], "x" * 17), errors.BAD_SCHEMA, True),
        ("codec a number", setp(["library", "source", "codec"], 251), errors.BAD_SCHEMA, True),
        ("renders missing", delp(["library", "renders"]), errors.BAD_SCHEMA, True),
        ("renders empty", setp(["library", "renders"], []), errors.BAD_SCHEMA, True),
        ("renders an object", setp(["library", "renders"], {}), errors.BAD_SCHEMA, True),
        ("seven renders", seven, errors.BAD_SCHEMA, True),
        ("the same profile twice", twice, errors.BAD_SCHEMA, False),
        ("render not an object", setp(render, "studio"), errors.BAD_SCHEMA, True),
        ("profile missing", delp(render + ["profile"]), errors.BAD_SCHEMA, True),
        ("unknown profile", setp(render + ["profile"], "cinema"), errors.BAD_SCHEMA, True),
        ("profile in capitals", setp(render + ["profile"], "Studio"), errors.BAD_SCHEMA, True),
        ("audioPut missing", delp(render + ["audioPut"]), errors.BAD_SCHEMA, True),
        ("manifestPut missing", delp(render + ["manifestPut"]), errors.BAD_SCHEMA, True),
        ("audioPut not a string", setp(render + ["audioPut"], 5), errors.BAD_SCHEMA, True),
        ("audioPut of another profile", setp(render + ["audioPut"], f"{HOST}/{LIB}/sp-wide.flac?{SIG}"),
         errors.BAD_URL, False),
        ("audioPut of another video", setp(render + ["audioPut"], f"{HOST}/lib/v1/AAAAAAAAAAA/sp-studio.flac?{SIG}"),
         errors.BAD_URL, False),
        ("audioPut of another library version",
         setp(render + ["audioPut"], f"{HOST}/lib/v2/{VIDEO}/sp-studio.flac?{SIG}"), errors.BAD_URL, False),
        ("audioPut into the job's own folder", setp(render + ["audioPut"], f"{HOST}/out/{jk}/sp-studio.flac?{SIG}"),
         errors.BAD_URL, False),
        ("audioPut at the manifest", setp(render + ["audioPut"], f"{HOST}/{LIB}/sp-studio.json?{SIG}"),
         errors.BAD_URL, False),
        ("audioPut unsigned", setp(render + ["audioPut"], f"{HOST}/{LIB}/sp-studio.flac"), errors.BAD_URL, False),
        ("audioPut dot-dot", setp(render + ["audioPut"], f"{HOST}/x/../{LIB}/sp-studio.flac?{SIG}"),
         errors.BAD_URL, False),
        ("manifestPut at the audio", setp(render + ["manifestPut"], f"{HOST}/{LIB}/sp-studio.flac?{SIG}"),
         errors.BAD_URL, False),
        ("manifestPut on another host",
         setp(render + ["manifestPut"], f"https://evil.example.com/{LIB}/sp-studio.json?{SIG}"), errors.BAD_URL, False),
        ("manifestGet of another profile", setp(render + ["manifestGet"], f"{HOST}/{LIB}/sp-wide.json?{SIG}"),
         errors.BAD_URL, False),
        ("manifestGet outside the renders", setp(render + ["manifestGet"], f"{HOST}/{LIB}/other.json?{SIG}"),
         errors.BAD_URL, False),
        ("manifestGet over http", setp(render + ["manifestGet"], f"http{HOST[5:]}/{LIB}/sp-studio.json?{SIG}"),
         errors.BAD_URL, True),
        ("no manifest put", delp(["output", "put", "manifest"]), errors.BAD_SCHEMA, True),
        ("the volume fallback has no library", volume, errors.BAD_SCHEMA, True),
    ]


@pytest.mark.parametrize("desc,mutate,code,schema_rejects", _library_mutations(),
                         ids=[m[0] for m in _library_mutations()])
def test_broken_library_blocks_are_rejected(desc, mutate, code, schema_rejects, caps):
    doc = _spatial()
    INPUT_SCHEMA.validate(doc)
    mutate(doc)
    with pytest.raises(errors.WorkerError) as info:
        validate_job(doc, caps)
    assert info.value.code == code, (desc, info.value.message)
    assert "://" not in info.value.message and "X-Amz" not in info.value.message
    if schema_rejects:
        with pytest.raises(jsonschema.ValidationError):
            INPUT_SCHEMA.validate(doc)
    else:  # a rule only the worker can check (whose object a URL names, a repeated profile)
        INPUT_SCHEMA.validate(doc)


def test_an_older_worker_would_refuse_the_new_tasks_by_name():
    # 1.0.0 answers BAD_SCHEMA "tasks may only contain ...": the phone must not send library tasks to it.
    from pixl_worker import schema

    assert schema.LIBRARY_TASKS == ("spatial",)
    assert schema.TASKS[:4] == ("instrumental", "vocals", "stems4", "lyrics")


def test_render_manifest_schema_rejects_what_a_phone_must_not_trust():
    validator = jsonschema.Draft202012Validator(load_schema("library.render"))
    jsonschema.Draft202012Validator.check_schema(load_schema("library.render"))
    spatial = load_example("library.render.spatial.json")
    validator.validate(spatial)

    def broken(doc, path, value):
        doc = copy.deepcopy(doc)
        target = doc
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        return doc

    bad = [
        broken(spatial, ["audio"], None),                       # a spatial render always has a file
        broken(spatial, ["profile"], None),
        broken(spatial, ["profile"], "cinema"),
        broken(spatial, ["loudness"], None),
        broken(spatial, ["render", "engine"], None),
        broken(spatial, ["render", "stemMode"], "stems8"),
        broken(spatial, ["audio", "key"], "lib/v1/J7p4bzqLvCw/sp-cinema.flac"),
        broken(spatial, ["audio", "key"], "out/3d9f0c52-7a41-4e8b-b6f3-91c2d5e7a804/sp-studio.flac"),
        broken(spatial, ["audio", "bits"], 24),
        broken(spatial, ["audio", "sha256"], "abc"),
        broken(spatial, ["videoId"], "short"),
        broken(spatial, ["v"], 2),
        broken(spatial, ["schema"], "pixl.cloudstudio.result"),
        broken(spatial, ["createdAt"], "yesterday"),
        broken(spatial, ["kind"], "enhanced"),                  # spatial is the only kind
        broken(spatial, ["render", "stems"], None),             # it always names the separator
        broken(spatial, ["render", "stemMode"], None),
        broken(spatial, ["audio", "key"], "lib/v1/J7p4bzqLvCw/enhanced.flac"),
    ]
    for doc in bad:
        with pytest.raises(jsonschema.ValidationError):
            validator.validate(doc)
    # what the manifest of spec 3.1 has, and nothing it does not
    assert set(spatial["source"]) == {"itag", "codec", "sampleRate", "decodedSamples", "sha256"}
    assert spatial["render"] == {"engine": "pixl-spatial-1", "stems": "open-cascade-6", "stemMode": "stems6"}
    # what the example promises about level (spec 3.1)
    assert spatial["loudness"]["headroomDb"] == 4.0
    assert abs(spatial["loudness"]["sourceLufs"] - spatial["loudness"]["headroomDb"]
               - spatial["loudness"]["integratedLufs"]) <= 0.3


def test_result_examples_for_library_jobs():
    validator = jsonschema.Draft202012Validator(load_schema("job.result"))
    ok, exists, partial = (load_example(f"job.result.spatial{suffix}.json") for suffix in ("", ".exists", ".partial"))
    assert ok["library"] == {"videoId": VIDEO, "libV": 1, "renders": {"studio": "ok"}, "stemMode": "stems6"}
    assert ok["outputs"]["sp-studio"]["key"] == f"{LIB}/sp-studio.flac"
    assert exists["library"]["renders"] == {"studio": "exists"} and exists["library"]["stemMode"] is None
    assert partial["status"] == "partial" and partial["library"]["renders"]["hall"] == "failed"
    assert set(partial["outputs"]) == {"instrumental", "sp-night"}  # an older output next to a library one
    for doc in (ok, exists, partial):  # spec section 4: these timings and models, these progress stages
        assert "stems6Ms" in doc["timings"] and "renderMs" in doc["timings"] and "stems6" in doc["models"]
    for field, value in ((["library", "renders"], {"cinema": "ok"}), (["library", "renders"], {"studio": "done"}),
                         (["library", "renders"], {"studio": "not_needed"}), (["library", "stemMode"], "stems5"),
                         (["outputs", "sp-studio", "key"], "lib/J7p4bzqLvCw/sp-studio.flac")):
        doc = copy.deepcopy(ok)
        target = doc
        for key in field[:-1]:
            target = target[key]
        target[field[-1]] = value
        with pytest.raises(jsonschema.ValidationError):
            validator.validate(doc)
    # A 1.0.0 manifest (no library, no new timings or models) is still valid: old results stay readable.
    old = load_example("job.result.ok.json")
    assert "library" not in old and "renderMs" not in old["timings"] and "stems6" not in old["models"]
    validator.validate(old)
