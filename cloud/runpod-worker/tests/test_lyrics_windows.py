"""VAD, the global offset check, line windows (synced and plain) and ASR phrases, on synthetic signals."""

import numpy as np
import pytest

from pixl_worker.lyrics import windows as W


def voice_track(segments, duration_s, seed=3):
    """16 kHz mono: quiet noise floor with loud 'voice' bursts at the given (start, end) seconds."""
    rng = np.random.default_rng(seed)
    x = (rng.standard_normal(int(duration_s * W.SR)) * 0.001).astype(np.float32)
    for s, e in segments:
        a, b = int(s * W.SR), int(e * W.SR)
        t = np.arange(b - a) / W.SR
        x[a:b] += (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    return x


def test_vad_finds_the_voiced_segments():
    segs = [(1.0, 3.0), (3.2, 4.0), (6.0, 9.5)]
    found = W.vad_segments(W.activity(voice_track(segs, 12)))
    # the 0.2 s gap is bridged; the 2 s gap is not
    assert len(found) == 2
    assert found[0][0] == pytest.approx(0.9, abs=0.15) and found[0][1] == pytest.approx(4.1, abs=0.15)
    assert found[1][0] == pytest.approx(5.9, abs=0.15) and found[1][1] == pytest.approx(9.6, abs=0.15)


def test_vad_on_silence():
    assert W.vad_segments(W.activity(np.zeros(16000 * 3, dtype=np.float32))) == []
    assert W.vad_segments(np.zeros(0, dtype=np.float32)) == []


def _song_segments(starts, length=2.5):
    return [(s, s + length) for s in starts]


def test_offset_detects_a_spoken_intro():
    line_starts = [10.0 + 4.0 * k for k in range(20)]
    vocals = _song_segments([s + 7.0 for s in line_starts])  # the video has a 7 s intro
    shift, verdict = W.estimate_offset(line_starts, vocals, 100.0)
    assert verdict == "applied" and shift == pytest.approx(7.0, abs=0.1)


def test_offset_keeps_good_times():
    line_starts = [10.0 + 4.0 * k for k in range(20)]
    vocals = _song_segments([s + 0.2 for s in line_starts])
    assert W.estimate_offset(line_starts, vocals, 100.0) == (0.0, "none")


def test_offset_unreliable_when_nothing_matches():
    line_starts = [10.0 + 4.0 * k for k in range(20)]
    vocals = [(50.0, 51.0), (90.0, 91.0)]
    assert W.estimate_offset(line_starts, vocals, 100.0)[1] == "unreliable"


def test_synced_windows_pad_cap_and_skip_empty_lines():
    starts = [12340, 15800, 19200, 23050, None]
    ends = [15800, None, None, None, None]
    texts = ["one", "two", "", "four", "five"]
    out = W.synced_windows(starts, ends, texts, 30.0)
    assert [o[0] for o in out] == [0, 1, 3]
    i, w0, w1, s, e = out[0]
    assert (w0, w1) == pytest.approx((10.84, 17.3)) and (s, e) == pytest.approx((12.34, 15.8))
    # line 1 runs to the next timed line (19.2 s, the empty one), line 3 (last) is capped at 15 s / song end
    assert out[1][4] == pytest.approx(19.2)
    assert out[2][4] == pytest.approx(30.0)
    shifted = W.synced_windows(starts, ends, texts, 30.0, offset_s=2.0)
    assert shifted[0][3] == pytest.approx(14.34)


def test_unsynced_windows_spread_lines_over_voiced_time():
    texts = ["short", "a much longer line with many words in it", "", "end"]
    segs = [(10.0, 20.0), (30.0, 40.0)]
    out = W.unsynced_windows(texts, segs, 60.0)
    assert [o[0] for o in out] == [0, 1, 3]
    starts = [o[3] for o in out]
    assert starts == sorted(starts) and starts[0] == pytest.approx(10.0)
    assert out[-1][4] == pytest.approx(40.0, abs=0.01)
    # the long line gets the most voiced time
    lengths = [o[4] - o[3] for o in out]
    assert lengths[1] > lengths[0] and lengths[1] > lengths[2]


def test_phrases_merge_and_split():
    segs = [(0.0, 2.0), (2.3, 4.0), (10.0, 40.0), (50.0, 50.3)]
    out = W.phrases(segs)
    assert out[0] == (0.0, 4.0)
    long_parts = [p for p in out if p[0] >= 10.0 and p[1] <= 40.0]
    assert len(long_parts) == 3 and all(p[1] - p[0] <= 12.0 + 1e-9 for p in long_parts)
    assert all(p[1] - p[0] >= 0.6 for p in out)  # the 0.3 s blip is dropped


def test_text_weight():
    assert W.text_weight("hello big world") == 3
    assert W.text_weight("사랑해요") == 4
    assert W.text_weight("我爱你 love") == 4
