"""Stage 6 orchestration (lyrics.run) with fake models: known lyrics aligned per line, the global offset check,
line timing for languages without a word-timing backend (no Whisper in v1) and the hook that adds one later,
and transcription ("AI-written lyrics") for songs without lyrics."""

import jsonschema
import numpy as np
import pytest

from conftest import load_schema
from pixl_worker import errors
from pixl_worker.errors import WorkerError
from pixl_worker.lyrics import languages
from pixl_worker.lyrics import windows as W
from pixl_worker.lyrics.languages import Token
from pixl_worker.lyrics.postprocess import is_kept_char
from pixl_worker.lyrics.run import run_lyrics
from pixl_worker.schema import LyricsLine, LyricsRequest

LYRICS = jsonschema.Draft202012Validator(load_schema("lyrics"))


def voice(segments, duration_s):
    rng = np.random.default_rng(5)
    x = (rng.standard_normal(int(duration_s * W.SR)) * 0.001).astype(np.float32)
    for s, e in segments:
        a, b = int(s * W.SR), int(e * W.SR)
        t = np.arange(b - a) / W.SR
        x[a:b] += (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    return x


class Backend:
    def __init__(self, langs, model_id="fake-aligner"):
        self.langs, self.model_id, self.calls = set(langs), model_id, []

    def supports(self, language):
        return language in self.langs

    def align(self, requests):
        self.calls.append([(r.key, r.language, r.offset_s) for r in requests])
        out = []
        for r in requests:
            words = [w for w in ("".join(c for c in w if is_kept_char(c)) for w in r.text.split()) if w]
            span = len(r.audio) / W.SR
            step = span / (len(words) + 1)
            out.append([Token(w, step * (k + 0.5), step * (k + 1.1)) for k, w in enumerate(words)])
        return out


@pytest.fixture(autouse=True)
def clean_backends():
    languages.clear_backends()
    yield
    languages.clear_backends()


def request(lines, *, mode="auto", language="en", synced=True):
    return LyricsRequest(mode=mode, language=language, synced=synced,
                         lines=tuple(LyricsLine(i, s, e, t) for i, (s, e, t) in enumerate(lines)))


PHRASES = [(2.0, 5.0), (6.0, 9.0), (10.0, 13.0), (14.0, 17.0), (18.0, 21.0)]
TEXTS = ["first line here", "second line now", "third one sings", "fourth goes on", "and the fifth"]


def test_known_lyrics_get_word_timing_inside_their_lines():
    backend = Backend({"en"})
    languages.register_backend(backend)
    lines = [(int(s * 1000), int(e * 1000), t) for (s, e), t in zip(PHRASES, TEXTS)]
    out = run_lyrics(request(lines), voice(PHRASES, 24), transcriber_factory=None)
    LYRICS.validate(out.doc)
    assert out.doc["mode"] == "aligned" and out.doc["offsetMs"] == 0 and out.aligner == "fake-aligner"
    assert [line["timing"] for line in out.doc["lines"]] == ["word"] * 5
    for line, (s, e) in zip(out.doc["lines"], PHRASES):
        assert s * 1000 - 1600 <= line["startMs"] and line["endMs"] <= e * 1000 + 1600
    starts = [w["startMs"] for line in out.doc["lines"] for w in line["words"]]
    assert starts == sorted(starts)
    assert out.warnings == []


def test_a_spoken_intro_shifts_every_line():
    languages.register_backend(Backend({"en"}))
    shifted = [(s + 6.0, e + 6.0) for s, e in PHRASES]  # the video has a 6 s intro the catalog LRC lacks
    lines = [(int(s * 1000), int(e * 1000), t) for (s, e), t in zip(PHRASES, TEXTS)]
    out = run_lyrics(request(lines), voice(shifted, 30), transcriber_factory=None)
    assert 5500 <= out.doc["offsetMs"] <= 6500
    assert any("shifted the line times" in w for w in out.warnings)
    assert out.doc["lines"][0]["startMs"] >= 6000


def test_languages_without_a_backend_fall_back_to_line_timing():
    languages.register_backend(Backend({"en"}))  # the Qwen aligner's 11 languages; vi isn't one
    lines = [(2000, 5000, "Tôi yêu em nhiều lắm"), (6000, 9000, "hello there friend")]
    out = run_lyrics(request(lines, language="vi"), voice(PHRASES[:2], 12), transcriber_factory=None)
    LYRICS.validate(out.doc)
    assert [line["timing"] for line in out.doc["lines"]] == ["line", "word"]
    assert out.doc["lines"][0]["words"] == []
    assert any("no word timing for language vi" in w for w in out.warnings)


def test_the_whisper_hook_a_second_backend_takes_the_languages_the_first_lacks():
    qwen, later = Backend({"en", "ko"}, "qwen"), Backend({"vi", "th"}, "whisper-later")
    languages.register_backend(qwen)
    languages.register_backend(later)
    lines = [(2000, 5000, "Tôi yêu em nhiều lắm"), (6000, 9000, "hello there friend")]
    out = run_lyrics(request(lines, language="vi"), voice(PHRASES[:2], 12), transcriber_factory=None)
    assert [line["timing"] for line in out.doc["lines"]] == ["word", "word"]
    assert later.calls and qwen.calls
    assert sorted(languages.word_timing_languages()) == ["en", "ko", "th", "vi"]


def test_plain_lyrics_are_spread_over_the_voiced_parts():
    languages.register_backend(Backend({"en"}))
    lines = [(None, None, t) for t in TEXTS]
    out = run_lyrics(request(lines, synced=False), voice(PHRASES, 24), transcriber_factory=None)
    LYRICS.validate(out.doc)
    assert all(line["timing"] == "word" for line in out.doc["lines"])
    assert out.doc["lines"][0]["startMs"] >= 1000


class FakeASR:
    model_id = "fake-asr"

    def __init__(self, texts):
        self.texts = list(texts)

    def transcribe(self, clips, language):
        return [("en", self.texts[k] if k < len(self.texts) else "") for k in range(len(clips))]


def test_no_lyrics_are_transcribed_and_marked_ai_written():
    languages.register_backend(Backend({"en"}))
    loads = []

    def factory():
        loads.append(1)
        return FakeASR(["la la sing", "  ", "...", "we go on"])

    out = run_lyrics(request([], mode="auto", language=None), voice(PHRASES[:4], 18), transcriber_factory=factory)
    LYRICS.validate(out.doc)
    assert out.doc["mode"] == "transcribed" and out.asr == "fake-asr" and loads == [1]
    assert [line["text"] for line in out.doc["lines"]] == ["la la sing", "we go on"]  # blank and junk dropped
    assert all(line["timing"] == "word" for line in out.doc["lines"])
    assert out.doc["language"] == "en"


def test_transcription_without_a_model_fails_cleanly():
    with pytest.raises(WorkerError) as info:
        run_lyrics(request([], mode="transcribe"), voice(PHRASES[:1], 6), transcriber_factory=None)
    assert info.value.code == errors.INTERNAL


def test_silence_transcribes_to_nothing():
    out = run_lyrics(request([], mode="transcribe"), np.zeros(W.SR * 5, dtype=np.float32),
                     transcriber_factory=lambda: FakeASR([]))
    assert out.doc["lines"] == [] and any("no singing" in w for w in out.warnings)
