"""Where to look for each line (design 2.4, stage 6). Pure numpy, no models.

- `activity()` and `vad_segments()`: an energy voice-activity detector on the separated vocals (16 kHz mono).
- `estimate_offset()`: the global shift between the sent line starts and the vocals (spoken intros, radio edits).
- `synced_windows()`: each line's own time ±1.5 s, capped (the aligner takes at most 180 s per call).
- `unsynced_windows()`: plain lyrics (no times) spread over the voiced parts in proportion to their length.
- `phrases()`: VAD segments merged into ASR-sized phrases for transcription.
"""

from __future__ import annotations

from typing import Sequence

import numpy as np

SR = 16000
HOP_S = 0.02
PAD_S = 1.5
MAX_WINDOW_S = 180.0  # qwen_asr MAX_FORCE_ALIGN_INPUT_SECONDS
MAX_LINE_S = 15.0


def activity(vocals16k: np.ndarray, *, hop_s: float = HOP_S) -> np.ndarray:
    """RMS level per hop in dB (relative to full scale)."""
    hop = max(1, int(round(SR * hop_s)))
    n = len(vocals16k) // hop
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    frames = vocals16k[: n * hop].astype(np.float32).reshape(n, hop)
    rms = np.sqrt(np.mean(frames * frames, axis=1) + 1e-12)
    return (20.0 * np.log10(rms + 1e-9)).astype(np.float32)


def vad_segments(level_db: np.ndarray, *, hop_s: float = HOP_S, rel_db: float = -30.0, floor_db: float = -50.0,
                 min_voice_s: float = 0.2, min_gap_s: float = 0.3, pad_s: float = 0.1) -> list[tuple[float, float]]:
    """Voiced segments: level above max(floor, loud-reference + rel_db), with short gaps bridged and short blips
    dropped. The reference is the 95th percentile of the track's level, so quiet mixes still work."""
    if level_db.size == 0:
        return []
    reference = float(np.percentile(level_db, 95))
    threshold = max(floor_db, reference + rel_db)
    voiced = level_db > threshold
    segments: list[list[float]] = []
    start = None
    for i, v in enumerate(voiced):
        if v and start is None:
            start = i
        elif not v and start is not None:
            segments.append([start * hop_s, i * hop_s])
            start = None
    if start is not None:
        segments.append([start * hop_s, len(voiced) * hop_s])
    merged: list[list[float]] = []
    for seg in segments:
        if merged and seg[0] - merged[-1][1] < min_gap_s:
            merged[-1][1] = seg[1]
        else:
            merged.append(seg)
    total = len(voiced) * hop_s
    out = []
    for s, e in merged:
        if e - s < min_voice_s:
            continue
        out.append((max(0.0, s - pad_s), min(total, e + pad_s)))
    return out


def estimate_offset(line_starts_s: Sequence[float], segments: Sequence[tuple[float, float]], duration_s: float, *,
                    max_shift_s: float = 30.0, step_s: float = 0.05, tolerance_s: float = 0.4,
                    min_score: float = 0.35, min_gain: float = 0.15, min_shift_s: float = 1.0
                    ) -> tuple[float, str]:
    """How far the sent line times are off the vocals. Scores each candidate shift by the share of line starts
    that land within ±tolerance of a voice onset (a VAD segment start), over ±max_shift.

    Returns (shift_s, verdict): verdict is "applied" (shift > min_shift and clearly better than no shift),
    "none" (no shift needed, or not clearly better), or "unreliable" (neither the best shift nor zero reaches
    min_score: the times don't match these vocals, so the caller aligns as if unsynced)."""
    starts = np.asarray([s for s in line_starts_s if s is not None], dtype=np.float64)
    onsets = np.asarray([s for s, _ in segments], dtype=np.float64)
    if starts.size < 4 or onsets.size < 2:
        return 0.0, "none"
    n = int(np.ceil((duration_s + 2 * max_shift_s) / step_s)) + 1
    grid = np.zeros(n, dtype=np.int32)
    # Mark every grid cell within ±tolerance of an onset (grid index 0 = time -max_shift).
    for onset in onsets:
        lo = int(np.floor((onset - tolerance_s + max_shift_s) / step_s))
        hi = int(np.ceil((onset + tolerance_s + max_shift_s) / step_s))
        grid[max(0, lo): min(n, hi + 1)] = 1
    shifts = np.arange(-max_shift_s, max_shift_s + step_s / 2, step_s)
    base = np.round((starts + max_shift_s) / step_s).astype(np.int64)
    scores = np.empty(shifts.size, dtype=np.float64)
    for k, shift in enumerate(shifts):
        idx = base + int(round(shift / step_s))
        valid = (idx >= 0) & (idx < n)
        scores[k] = grid[idx[valid]].sum() / starts.size
    zero_k = int(np.argmin(np.abs(shifts)))
    zero = scores[zero_k]
    best_score = scores.max()
    # The best score usually holds over a plateau (±tolerance around the true shift): take each plateau's centre
    # and prefer the one closest to zero.
    is_best = scores >= best_score - 1e-9
    centres = []
    k = 0
    while k < scores.size:
        if is_best[k]:
            j = k
            while j + 1 < scores.size and is_best[j + 1]:
                j += 1
            centres.append((shifts[k] + shifts[j]) / 2.0)
            k = j + 1
        else:
            k += 1
    best_shift = float(min(centres, key=abs))
    if best_score < min_score and zero < min_score:
        return 0.0, "unreliable"
    if abs(best_shift) >= min_shift_s and best_score >= zero + min_gain:
        return round(best_shift, 2), "applied"
    return 0.0, "none"


def synced_windows(starts_ms: Sequence[int | None], ends_ms: Sequence[int | None], texts: Sequence[str],
                   duration_s: float, *, offset_s: float = 0.0, pad_s: float = PAD_S,
                   max_line_s: float = MAX_LINE_S) -> list[tuple[int, float, float, float, float]]:
    """(index, window_start, window_end, line_start, line_end) of each non-empty line: its own span (end = endMs,
    else the next line's start, capped at max_line_s), shifted by offset_s; the window adds ±pad_s. All clamped
    to the song. The line span is the fallback when word timing isn't possible."""
    out = []
    n = len(texts)
    for i in range(n):
        if not texts[i].strip() or starts_ms[i] is None:
            continue
        start = starts_ms[i] / 1000.0 + offset_s
        if ends_ms[i] is not None and ends_ms[i] > starts_ms[i]:
            end = ends_ms[i] / 1000.0 + offset_s
        else:
            nxt = next((starts_ms[j] for j in range(i + 1, n) if starts_ms[j] is not None and starts_ms[j] > starts_ms[i]),
                       None)
            end = (nxt / 1000.0 + offset_s) if nxt is not None else start + max_line_s
        end = min(end, start + max_line_s)
        start, end = max(0.0, min(start, duration_s)), max(0.0, min(end, duration_s))
        w0 = max(0.0, start - pad_s)
        w1 = min(duration_s, end + pad_s)
        if w1 - w0 < 0.3:
            continue
        out.append((i, w0, min(w1, w0 + MAX_WINDOW_S), start, max(start, end)))
    return out


def text_weight(text: str) -> int:
    """Rough sung length of a line: CJK/kana/hangul characters count one each, other words count one each."""
    weight = 0
    word = False
    for ch in text:
        code = ord(ch)
        if 0x3040 <= code <= 0x30FF or 0x4E00 <= code <= 0x9FFF or 0xAC00 <= code <= 0xD7A3 or 0x3400 <= code <= 0x4DBF:
            weight += 1
            word = False
        elif ch.isalnum():
            if not word:
                weight += 1
            word = True
        else:
            word = False
    return weight


def unsynced_windows(texts: Sequence[str], segments: Sequence[tuple[float, float]], duration_s: float, *,
                     pad_s: float = PAD_S) -> list[tuple[int, float, float, float, float]]:
    """Plain lyrics: lay the non-empty lines end to end over the voiced time, each taking a share proportional to
    its weight, then map back to song time. Returns (index, window_start, window_end, est_start, est_end): the
    padded window for the aligner and the estimate itself (used as line timing when alignment fails)."""
    idx = [i for i, t in enumerate(texts) if t.strip()]
    if not idx:
        return []
    segs = [(s, e) for s, e in segments if e > s] or [(0.0, duration_s)]
    voiced_total = sum(e - s for s, e in segs)
    weights = [max(1, text_weight(texts[i])) for i in idx]
    total_w = float(sum(weights))
    cum = np.concatenate([[0.0], np.cumsum([e - s for s, e in segs])])

    def to_song_time(v: float) -> float:
        v = min(max(v, 0.0), voiced_total)
        k = int(np.searchsorted(cum, v, side="right") - 1)
        k = min(max(k, 0), len(segs) - 1)
        return segs[k][0] + (v - cum[k])

    out = []
    acc = 0.0
    for i, w in zip(idx, weights):
        v0 = acc / total_w * voiced_total
        acc += w
        v1 = acc / total_w * voiced_total
        s, e = to_song_time(v0), to_song_time(max(v0, v1 - 1e-6))
        if e <= s:
            e = min(duration_s, s + 0.5)
        w0, w1 = max(0.0, s - pad_s), min(duration_s, e + pad_s)
        out.append((i, w0, min(w1, w0 + MAX_WINDOW_S), s, e))
    return out


def phrases(segments: Sequence[tuple[float, float]], *, max_s: float = 12.0, join_gap_s: float = 0.6,
            min_s: float = 0.6) -> list[tuple[float, float]]:
    """Merge VAD segments into ASR phrases of at most max_s (joining across gaps shorter than join_gap_s) and
    split longer ones evenly. Phrases shorter than min_s are dropped (Qwen3-ASR needs at least 0.5 s)."""
    merged: list[list[float]] = []
    for s, e in segments:
        if merged and s - merged[-1][1] < join_gap_s and e - merged[-1][0] <= max_s:
            merged[-1][1] = e
        else:
            merged.append([s, e])
    out: list[tuple[float, float]] = []
    for s, e in merged:
        length = e - s
        if length < min_s:
            continue
        parts = int(np.ceil(length / max_s))
        step = length / parts
        for k in range(parts):
            out.append((s + k * step, s + (k + 1) * step))
    return out


def cut(vocals16k: np.ndarray, start_s: float, end_s: float) -> np.ndarray:
    a = max(0, int(round(start_s * SR)))
    b = min(len(vocals16k), int(round(end_s * SR)))
    return np.ascontiguousarray(vocals16k[a:b], dtype=np.float32)
