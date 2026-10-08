"""Token → text offsets (UTF-16), monotonic times, minimum word length, collapse fallback, and the example file
rebuilt from its own offsets."""

import pytest

from conftest import load_example
from pixl_worker.lyrics.languages import Token, line_language
from pixl_worker.lyrics.postprocess import finalize, map_tokens, summarize, make_doc, utf16_offsets, word_timed


def utf16_slice(text, c0, c1):
    return text.encode("utf-16-le")[2 * c0: 2 * c1].decode("utf-16-le")


def test_example_words_rebuild_from_offsets():
    doc = load_example("lyrics.aligned.json")
    for line in doc["lines"]:
        spans = map_tokens(line["text"], [w["text"] for w in line["words"]])
        assert spans == [(w["c0"], w["c1"]) for w in line["words"]], line["text"]
        for w in line["words"]:
            kept = "".join(ch for ch in utf16_slice(line["text"], w["c0"], w["c1"]) if ch.isalnum() or ch == "'")
            assert kept == w["text"]


@pytest.mark.parametrize("text,tokens,spans", [
    ("Hello, world!", ["Hello", "world"], [(0, 5), (7, 12)]),
    ("rock-n-roll baby", ["rocknroll", "baby"], [(0, 11), (12, 16)]),
    ("don’t stop", ["dont", "stop"], [(0, 5), (6, 10)]),
    ("I'm here", ["I'm", "here"], [(0, 3), (4, 8)]),
    ("我爱你 love", ["我", "爱", "你", "love"], [(0, 1), (1, 2), (2, 3), (4, 8)]),
    ("😀 smile 😀 again", ["smile", "again"], [(3, 8), (12, 17)]),  # emoji are two UTF-16 units
    ("𠀋𠀋 go", ["𠀋", "𠀋", "go"], [(0, 2), (2, 4), (5, 7)]),  # astral CJK
    ("aab", ["ab"], [(1, 3)]),  # retry after a false start
    ("사랑해요 정말", ["사랑", "해요", "정말"], [(0, 2), (2, 4), (5, 7)]),
])
def test_map_tokens(text, tokens, spans):
    assert map_tokens(text, tokens) == spans
    for (c0, c1), token in zip(spans, tokens):
        assert "".join(ch for ch in utf16_slice(text, c0, c1) if ch.isalnum() or ch == "'") == token


def test_map_tokens_rejects_tokens_not_in_the_text():
    assert map_tokens("hello world", ["goodbye"]) is None
    assert map_tokens("hello", ["hello", "again"]) is None
    assert map_tokens("hello", [""]) is None


def test_utf16_offsets():
    assert utf16_offsets("a😀b") == [0, 1, 3, 4]


def test_word_timed_builds_monotonic_words_with_minimum_length():
    tokens = [Token("Hello", 0.50, 0.50), Token("world", 0.45, 0.90)]
    line = word_timed(3, "Hello, world", tokens, window_start_s=10.0, fallback=(10.0, 12.0))
    assert line.timing == "word"
    (w1, w2) = line.words
    assert w1["startMs"] == 10500 and w1["endMs"] == 10550  # 50 ms minimum
    assert w2["startMs"] >= w1["endMs"]  # never goes backwards
    assert (w1["c0"], w1["c1"], w2["c0"], w2["c1"]) == (0, 5, 7, 12)


def test_word_timed_respects_the_previous_line():
    tokens = [Token("again", 0.0, 0.4)]
    line = word_timed(1, "again", tokens, window_start_s=5.0, fallback=(5.0, 6.0), not_before_s=5.2)
    assert line.words[0]["startMs"] == 5200


@pytest.mark.parametrize("tokens,reason", [
    (None, "no words"),
    ([], "no words"),
    ([Token("nope", 0, 1)], "words did not match the text"),
    ([Token("a", 1, 1), Token("b", 1, 1), Token("c", 1, 1.2)], "collapsed"),
])
def test_word_timed_falls_back_to_line_timing(tokens, reason):
    line = word_timed(0, "a b c", tokens, window_start_s=0.0, fallback=(2.0, 4.0))
    assert line.timing == "line" and line.words == [] and line.reason == reason
    assert (line.start_s, line.end_s) == (2.0, 4.0)


def test_finalize_and_summary():
    a = word_timed(0, "one two", [Token("one", 0.1, 0.3), Token("two", 0.4, 0.6)], 1.0, (1.0, 2.0))
    b = word_timed(1, "three", None, 0.0, (0.5, 3.0))  # line timing, starts before line 0: clamped forward
    lines = finalize([a, b])
    assert lines[1]["startMs"] >= lines[0]["startMs"] and lines[1]["timing"] == "line"
    doc = make_doc("aligned", "en", 0, lines)
    assert summarize(doc) == {"mode": "aligned", "language": "en", "lines": 2, "wordTimedLines": 1, "words": 2,
                              "offsetMs": 0}


@pytest.mark.parametrize("text,hint,expected", [
    ("별빛 아래", "ko", "ko"),
    ("(Oh-oh) Stay with me", "ko", "en"),
    ("君の名は", None, "ja"),
    ("我爱你", None, "zh"),
    ("我爱你", "yue", "yue"),
    ("Hôm nay trời đẹp quá", None, "vi"),
    ("Tôi yêu em", "vi", "vi"),  # no vi-only letter, but diacritics in a Vietnamese song
    ("Baby I love you", "vi", "en"),  # plain ASCII in a Vietnamese song: an English hook
    ("Bonjour tout le monde", "fr", "fr"),
    ("Привет", None, "ru"),
    ("สวัสดี", None, "th"),
    ("...", "de", "de"),
])
def test_line_language(text, hint, expected):
    assert line_language(text, hint) == expected
