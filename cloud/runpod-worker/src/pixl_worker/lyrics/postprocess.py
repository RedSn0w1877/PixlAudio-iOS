"""Turn aligner tokens into pixl.cloudstudio.lyrics v1 lines (design 2.3 lyrics.json, 2.4 stage 6 post-process).

The aligner strips punctuation and splits lines into words (or single CJK characters), so its tokens are not
substrings of the line. `map_tokens` walks the original text and gives each token its [c0, c1) span in UTF-16
code units, which is what the app needs to rebuild the words exactly (Swift String.utf16 offsets). Then times are
made monotonic, every word gets at least 50 ms, and a line whose words collapse falls back to line timing.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass, field
from typing import Sequence

from .languages import Token

MIN_WORD_S = 0.05
LYRICS_SCHEMA = "pixl.cloudstudio.lyrics"


def is_kept_char(ch: str) -> bool:
    """Mirror of Qwen3ForceAlignProcessor.is_kept_char: letters, numbers and the ASCII apostrophe."""
    if ch == "'":
        return True
    cat = unicodedata.category(ch)
    return cat.startswith("L") or cat.startswith("N")


def utf16_offsets(text: str) -> list[int]:
    """offsets[i] = UTF-16 position of code point i (len(text)+1 entries)."""
    out = [0]
    for ch in text:
        out.append(out[-1] + (2 if ord(ch) > 0xFFFF else 1))
    return out


def map_tokens(text: str, tokens: Sequence[str]) -> list[tuple[int, int]] | None:
    """[c0, c1) UTF-16 spans of each token in `text`, in order, or None if the tokens don't fit the text.

    Characters before a token starts are skipped (spaces, punctuation); inside a token only non-kept characters
    may be skipped (so "rock-n-roll" matches the token "rocknroll" and spans the hyphens)."""
    offsets = utf16_offsets(text)
    pos = 0
    spans: list[tuple[int, int]] = []
    for token in tokens:
        if not token:
            return None
        i, j, start = pos, 0, None
        while i < len(text) and j < len(token):
            ch = text[i]
            if ch == token[j]:
                if start is None:
                    start = i
                j += 1
                i += 1
            elif start is None or not is_kept_char(ch):
                i += 1
            else:
                # A letter that isn't the token's next one: this wasn't the token after all; retry one later.
                i, j, start = start + 1, 0, None
        if j < len(token) or start is None:
            return None
        spans.append((offsets[start], offsets[i]))
        pos = i
    return spans


@dataclass
class LineResult:
    index: int
    text: str
    start_s: float
    end_s: float
    timing: str  # word | line
    words: list[dict] = field(default_factory=list)
    reason: str | None = None  # why it fell back to line timing


def line_timed(index: int, text: str, start_s: float, end_s: float, reason: str | None = None) -> LineResult:
    start_s = max(0.0, start_s)
    return LineResult(index=index, text=text, start_s=start_s, end_s=max(start_s, end_s), timing="line",
                      reason=reason)


def word_timed(index: int, text: str, tokens: Sequence[Token] | None, window_start_s: float,
               fallback: tuple[float, float], *, not_before_s: float = 0.0) -> LineResult:
    """Build one line from aligner tokens (times relative to the window). Falls back to line timing (with the
    fallback times) when there are no tokens, they don't match the text, or they collapse."""
    if not tokens:
        return line_timed(index, text, *fallback, reason="no words")
    spans = map_tokens(text, [t.text for t in tokens])
    if spans is None:
        return line_timed(index, text, *fallback, reason="words did not match the text")
    raw = [(window_start_s + float(t.start_s), window_start_s + float(t.end_s)) for t in tokens]
    zero = sum(1 for s, e in raw if e - s <= 1e-3)
    if len(raw) >= 2 and zero * 2 > len(raw):
        return line_timed(index, text, *fallback, reason="collapsed")
    times: list[list[float]] = []
    floor = max(0.0, not_before_s)
    for s, e in raw:
        s = max(s, floor)
        e = max(e, s + MIN_WORD_S)
        times.append([s, e])
        floor = e
    span = times[-1][1] - times[0][0]
    if len(times) >= 3 and span < 0.08 * len(times):
        return line_timed(index, text, *fallback, reason="collapsed")
    words = []
    for (c0, c1), token, (s, e) in zip(spans, tokens, times):
        words.append({"startMs": int(round(s * 1000)), "endMs": int(round(e * 1000)), "text": token.text,
                      "c0": c0, "c1": c1})
    return LineResult(index=index, text=text, start_s=times[0][0], end_s=times[-1][1], timing="word", words=words)


def finalize(lines: list[LineResult]) -> list[dict]:
    """Order-preserving clean-up across lines: start times never go backwards, ends never precede starts.
    Returns the JSON line objects."""
    out = []
    last_start = 0.0
    for line in lines:
        start = max(line.start_s, last_start, 0.0)
        end = max(line.end_s, start)
        last_start = start
        out.append({
            "i": line.index,
            "startMs": int(round(start * 1000)),
            "endMs": int(round(end * 1000)),
            "text": line.text,
            "timing": line.timing,
            "words": line.words if line.timing == "word" else [],
        })
    return out


def make_doc(mode: str, language: str | None, offset_ms: int, lines: list[dict]) -> dict:
    return {"schema": LYRICS_SCHEMA, "v": 1, "mode": mode, "language": language, "offsetMs": int(offset_ms),
            "lines": lines}


def summarize(doc: dict) -> dict:
    lines = doc["lines"]
    return {
        "mode": doc["mode"],
        "language": doc["language"],
        "lines": len(lines),
        "wordTimedLines": sum(1 for line in lines if line["timing"] == "word"),
        "words": sum(len(line["words"]) for line in lines),
        "offsetMs": doc.get("offsetMs", 0),
    }
