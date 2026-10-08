"""Stage 6: word-timed lyrics from the isolated vocals. Pure orchestration over injected models, so the CPU tests
drive it with fakes.

- align (known lyrics): optional global offset check → one window per line → the word-timing backend for the
  line's language (Qwen3-ForcedAligner for its 11 languages) → map tokens back to the text → line timing where
  that isn't possible.
- transcribe (no lyrics): VAD phrases → Qwen3-ASR (lazy) → one line per phrase → words where a backend covers the
  language, line timing otherwise. The document is mode "transcribed" (the app shows "AI-written lyrics").
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Callable, Protocol, Sequence

import numpy as np

from ..errors import INTERNAL, WorkerError
from ..schema import LyricsRequest
from . import windows as W
from .languages import AlignRequest, backend_for, line_language
from .postprocess import LineResult, finalize, line_timed, make_doc, word_timed


class Transcriber(Protocol):
    model_id: str

    def transcribe(self, clips: Sequence[np.ndarray], language: str | None) -> list[tuple[str | None, str]]:
        ...


@dataclass
class LyricsOutcome:
    doc: dict
    warnings: list[str] = field(default_factory=list)
    aligner: str | None = None
    asr: str | None = None


def run_lyrics(request: LyricsRequest, vocals16k: np.ndarray, *,
               transcriber_factory: Callable[[], Transcriber] | None, deadline=None) -> LyricsOutcome:
    duration_s = len(vocals16k) / W.SR
    segments = W.vad_segments(W.activity(vocals16k))
    if request.effective_mode == "align":
        return _align_known(request, vocals16k, segments, duration_s, deadline)
    return _transcribe(request, vocals16k, segments, duration_s, transcriber_factory, deadline)


def _check(deadline) -> None:
    if deadline is not None:
        deadline.check("lyrics")


def _with_deadline(model, deadline, call):
    """Run `call()` with this job's deadline set on a shared model, and always take it off again: the aligner
    and the transcriber live for the whole process (FlashBoot resumes it), so a deadline left behind would end a
    later job that sets none (op bench) with DEADLINE."""
    if not hasattr(model, "deadline"):
        return call()
    model.deadline = deadline
    try:
        return call()
    finally:
        model.deadline = None


def _run_backends(requests: list[tuple[AlignRequest, object]], deadline) -> tuple[dict[int, list], str | None]:
    """Group requests by backend and run each group. Returns ({key: tokens|None}, model id used)."""
    by_backend: dict[int, tuple[object, list[AlignRequest]]] = {}
    for req, backend in requests:
        by_backend.setdefault(id(backend), (backend, []))[1].append(req)
    tokens: dict[int, list] = {}
    used = None
    for backend, reqs in by_backend.values():
        _check(deadline)
        results = _with_deadline(backend, deadline, lambda: backend.align(reqs))
        used = used or getattr(backend, "model_id", None)
        for req, result in zip(reqs, results):
            tokens[req.key] = result
    return tokens, used


def _align_known(request: LyricsRequest, vocals16k, segments, duration_s, deadline) -> LyricsOutcome:
    warnings: list[str] = []
    lines = request.lines
    texts = [line.text for line in lines]
    starts = [line.start_ms for line in lines]
    ends = [line.end_ms for line in lines]
    synced = request.synced and all(s is not None for s, t in zip(starts, texts) if t.strip())

    offset_s = 0.0
    if synced:
        shift, verdict = W.estimate_offset([s / 1000.0 for s, t in zip(starts, texts) if t.strip() and s is not None],
                                           segments, duration_s)
        if verdict == "applied":
            offset_s = shift
            warnings.append(f"lyrics: shifted the line times by {shift:+.1f} s to match the vocals")
        elif verdict == "unreliable":
            synced = False
            warnings.append("lyrics: the line times don't match the vocals; aligned them as plain lyrics")

    # window + fallback estimate per non-empty line
    plan: dict[int, tuple[float, float, float, float]] = {}
    if synced:
        for i, w0, w1, s, e in W.synced_windows(starts, ends, texts, duration_s, offset_s=offset_s):
            plan[i] = (w0, w1, s, e)
    else:
        for i, w0, w1, s, e in W.unsynced_windows(texts, segments, duration_s):
            plan[i] = (w0, w1, s, e)

    requests: list[tuple[AlignRequest, object]] = []
    unsupported: Counter = Counter()
    languages: Counter = Counter()
    line_lang: dict[int, str | None] = {}
    for i, (w0, w1, _, _) in plan.items():
        lang = line_language(texts[i], request.language)
        line_lang[i] = lang
        if lang:
            languages[lang] += 1
        backend = backend_for(lang)
        if backend is None:
            unsupported[lang or "unknown"] += 1
            continue
        requests.append((AlignRequest(key=i, text=texts[i], language=lang, audio=W.cut(vocals16k, w0, w1),
                                      offset_s=w0), backend))
    tokens, used = _run_backends(requests, deadline) if requests else ({}, None)

    results: list[LineResult] = []
    floor = 0.0
    fell_back = 0
    for i, line in enumerate(lines):
        if i not in plan:
            # empty line (or a line without a time): a zero-length marker where it sits
            if synced and line.start_ms is not None:
                t = line.start_ms / 1000.0 + offset_s
                nxt = next((s for s in starts[i + 1:] if s is not None), None)
                end = nxt / 1000.0 + offset_s if nxt is not None else t
                results.append(line_timed(i, line.text, t, max(t, end)))
            else:
                t = results[-1].end_s if results else 0.0
                results.append(line_timed(i, line.text, t, t))
            continue
        w0, _, est_s, est_e = plan[i]
        if i in tokens:
            result = word_timed(i, line.text, tokens[i], w0, (est_s, est_e), not_before_s=floor)
            if result.timing == "line":
                fell_back += 1
        else:
            result = line_timed(i, line.text, est_s, est_e, reason="unsupported language")
        results.append(result)
        floor = result.end_s if result.timing == "word" else result.start_s

    if fell_back:
        warnings.append(f"lyrics: {fell_back} line{'s' if fell_back != 1 else ''} fell back to line timing")
    for lang, count in sorted(unsupported.items()):
        warnings.append(f"lyrics: no word timing for language {lang} ({count} line{'s' if count != 1 else ''}, line timing)")

    language = request.language or (languages.most_common(1)[0][0] if languages else None)
    doc = make_doc("aligned", language, int(round(offset_s * 1000)), finalize(results))
    return LyricsOutcome(doc=doc, warnings=warnings, aligner=used)


_JUNK = re.compile(r"^[\W_]*$", re.UNICODE)


def _transcribe(request: LyricsRequest, vocals16k, segments, duration_s, transcriber_factory, deadline) -> LyricsOutcome:
    if transcriber_factory is None:
        raise WorkerError(INTERNAL, "transcription is not available on this worker")
    warnings: list[str] = []
    spans = W.phrases(segments)
    if not spans:
        doc = make_doc("transcribed", request.language, 0, [])
        return LyricsOutcome(doc=doc, warnings=["lyrics: no singing found to transcribe"])
    _check(deadline)
    transcriber = transcriber_factory()
    clips = [W.cut(vocals16k, s, e) for s, e in spans]
    recognised = _with_deadline(transcriber, deadline, lambda: transcriber.transcribe(clips, request.language))

    kept: list[tuple[int, float, float, str, str | None]] = []
    for (s, e), (lang, text) in zip(spans, recognised):
        text = " ".join(text.split())
        if not text or _JUNK.match(text):
            continue
        lang = lang or line_language(text, request.language)
        kept.append((len(kept), s, e, text, lang))

    requests: list[tuple[AlignRequest, object]] = []
    languages: Counter = Counter()
    unsupported: Counter = Counter()
    for key, s, e, text, lang in kept:
        if lang:
            languages[lang] += 1
        backend = backend_for(lang)
        if backend is None:
            unsupported[lang or "unknown"] += 1
            continue
        w0, w1 = max(0.0, s - 0.3), min(duration_s, e + 0.3)
        requests.append((AlignRequest(key=key, text=text, language=lang, audio=W.cut(vocals16k, w0, w1), offset_s=w0),
                         backend))
    tokens, used = _run_backends(requests, deadline) if requests else ({}, None)

    results: list[LineResult] = []
    floor = 0.0
    for key, s, e, text, lang in kept:
        if key in tokens:
            w0 = max(0.0, s - 0.3)
            result = word_timed(key, text, tokens[key], w0, (s, e), not_before_s=floor)
        else:
            result = line_timed(key, text, s, e)
        results.append(result)
        floor = result.end_s if result.timing == "word" else result.start_s
    for lang, count in sorted(unsupported.items()):
        warnings.append(f"lyrics: no word timing for language {lang} ({count} line{'s' if count != 1 else ''}, line timing)")
    language = request.language or (languages.most_common(1)[0][0] if languages else None)
    doc = make_doc("transcribed", language, 0, finalize(results))
    return LyricsOutcome(doc=doc, warnings=warnings, aligner=used, asr=getattr(transcriber, "model_id", None))
