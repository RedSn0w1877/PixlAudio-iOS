"""Which language a line is in, and which word-timing backend (if any) handles it.

v1 has one backend, Qwen3-ForcedAligner, which covers 11 languages. Everything else gets line timing (owner
decision: no Whisper in v1). **The Whisper hook:** a later backend (e.g. stable-ts + faster-whisper) implements
WordTimingBackend and is registered with `register_backend()` after the Qwen one; `backend_for()` then finds it
for the languages the aligner lacks (vi, th, id, ...), and nothing else in the pipeline changes.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from typing import Protocol, Sequence

import numpy as np

# ISO 639 code -> the language name Qwen3-ForcedAligner expects (model card: 11 languages).
ALIGNER_LANGUAGES = {
    "zh": "Chinese", "en": "English", "yue": "Cantonese", "fr": "French", "de": "German", "it": "Italian",
    "ja": "Japanese", "ko": "Korean", "pt": "Portuguese", "ru": "Russian", "es": "Spanish",
}

# Qwen3-ASR language names (qwen_asr.inference.utils.SUPPORTED_LANGUAGES) -> ISO 639 codes.
ASR_LANGUAGE_CODES = {
    "Chinese": "zh", "English": "en", "Cantonese": "yue", "Arabic": "ar", "German": "de", "French": "fr",
    "Spanish": "es", "Portuguese": "pt", "Indonesian": "id", "Italian": "it", "Korean": "ko", "Russian": "ru",
    "Thai": "th", "Vietnamese": "vi", "Japanese": "ja", "Turkish": "tr", "Hindi": "hi", "Malay": "ms",
    "Dutch": "nl", "Swedish": "sv", "Danish": "da", "Finnish": "fi", "Polish": "pl", "Czech": "cs",
    "Filipino": "fil", "Persian": "fa", "Greek": "el", "Romanian": "ro", "Hungarian": "hu", "Macedonian": "mk",
}
ASR_LANGUAGE_NAMES = {code: name for name, code in ASR_LANGUAGE_CODES.items()}


@dataclass(frozen=True)
class AlignRequest:
    """Align `text` against `audio` (mono float32, 16 kHz) that starts at `offset_s` in the song."""
    key: int
    text: str
    language: str
    audio: np.ndarray
    offset_s: float


@dataclass(frozen=True)
class Token:
    """One aligned unit, times in seconds relative to its window's audio."""
    text: str
    start_s: float
    end_s: float


class WordTimingBackend(Protocol):
    model_id: str

    def supports(self, language: str | None) -> bool:
        ...

    def align(self, requests: Sequence[AlignRequest]) -> list[list[Token] | None]:
        """One result per request; None when that request failed."""
        ...


_BACKENDS: list[WordTimingBackend] = []


def register_backend(backend: WordTimingBackend) -> None:
    _BACKENDS.append(backend)


def clear_backends() -> None:
    _BACKENDS.clear()


def backend_for(language: str | None) -> WordTimingBackend | None:
    for backend in _BACKENDS:
        if backend.supports(language):
            return backend
    return None


def word_timing_languages() -> list[str]:
    langs: set[str] = set()
    for backend in _BACKENDS:
        for code in list(ALIGNER_LANGUAGES) + list(ASR_LANGUAGE_CODES.values()):
            if backend.supports(code):
                langs.add(code)
    return sorted(langs)


def _script(ch: str) -> str | None:
    code = ord(ch)
    if 0xAC00 <= code <= 0xD7A3 or 0x1100 <= code <= 0x11FF or 0x3130 <= code <= 0x318F:
        return "hangul"
    if 0x3040 <= code <= 0x30FF or 0x31F0 <= code <= 0x31FF or 0xFF66 <= code <= 0xFF9F:
        return "kana"
    if (0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF or 0x20000 <= code <= 0x2CEAF
            or 0xF900 <= code <= 0xFAFF):
        return "han"
    if 0x0400 <= code <= 0x04FF:
        return "cyrillic"
    if 0x0E00 <= code <= 0x0E7F:
        return "thai"
    if 0x0600 <= code <= 0x06FF:
        return "arabic"
    if 0x0900 <= code <= 0x097F:
        return "devanagari"
    if 0x0370 <= code <= 0x03FF:
        return "greek"
    if 0x0590 <= code <= 0x05FF:
        return "hebrew"
    if ch.isalpha() and unicodedata.name(ch, "").startswith("LATIN"):
        return "latin"
    return None


def script_counts(text: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for ch in text:
        script = _script(ch)
        if script:
            counts[script] = counts.get(script, 0) + 1
    return counts


_NON_LATIN_LANGUAGES = {"ko", "ja", "zh", "yue", "ru", "uk", "bg", "sr", "mk", "be", "kk", "th", "ar", "fa", "ur",
                        "hi", "el", "he"}

# Latin letters that only Vietnamese uses (horn vowels, d-bar, and the dot/hook-above tone marks on vowels).
_VIETNAMESE = set("ơưđƠƯĐạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ")


def line_language(text: str, hint: str | None) -> str | None:
    """Best guess of a line's language from its script, using the job's hint to break ties. Korean and Japanese
    are told apart by script; Han-only lines follow a zh/yue/ja hint (default zh); Latin lines follow the hint
    (default en) unless they carry Vietnamese-only letters."""
    counts = script_counts(text)
    if not counts:
        return hint
    if counts.get("hangul"):
        return "ko"
    if counts.get("kana"):
        return "ja"
    if counts.get("han"):
        return hint if hint in ("zh", "yue", "ja") else "zh"
    dominant = max(counts, key=counts.get)
    if dominant == "latin":
        if any(ch in _VIETNAMESE for ch in text):
            return "vi"
        if hint == "vi":
            # Vietnamese is written with diacritics; a line of plain ASCII letters in a Vietnamese song is almost
            # always an English hook, which the aligner can time word by word.
            return "vi" if any(ord(ch) > 0x7F and ch.isalpha() for ch in text) else "en"
        # An English line in a Korean/Japanese/Chinese/Russian... song: the hint names the song, not the line.
        return hint if hint and hint not in _NON_LATIN_LANGUAGES else "en"
    return {
        "cyrillic": hint if hint in ("ru", "uk", "bg", "sr", "mk", "be", "kk") else "ru",
        "thai": "th", "arabic": hint if hint in ("ar", "fa", "ur") else "ar", "devanagari": "hi",
        "greek": "el", "hebrew": "he",
    }.get(dominant, hint)
