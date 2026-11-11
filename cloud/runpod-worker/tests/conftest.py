import json
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

SCHEMA_DIR = ROOT / "schema" / "v1"
EXAMPLES = SCHEMA_DIR / "examples"
EXAMPLE_HOST = "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"


def load_example(name: str):
    return json.loads((EXAMPLES / name).read_text(encoding="utf-8"))


def load_schema(name: str):
    return json.loads((SCHEMA_DIR / f"{name}.schema.json").read_text(encoding="utf-8"))


@pytest.fixture
def caps():
    from pixl_worker.config import load_caps

    return load_caps({"PIXL_ALLOWED_HOST_SUFFIXES": EXAMPLE_HOST, "PIXL_TMP_ROOT": "unused"})


def band_stems(seconds: float = 5.0, sample_rate: int = 44100, seed: int = 5) -> dict:
    """Six synthetic stems shaped like a band, each (frames, 2) float32: a centred voice with pauses, drums a
    little left of centre, a centred bass, a guitar on the left, a piano on the right and a wide noisy pad.
    Deterministic. Their sum (see band_mix) is a quiet mix whose render never needs the limiter."""
    import numpy as np

    rng = np.random.default_rng(seed)
    frames = int(round(seconds * sample_rate))
    t = np.arange(frames, dtype=np.float64) / sample_rate

    def stereo(left, right):
        return np.stack([left, right], axis=1).astype(np.float32)

    f0 = 220.0 * (1.0 + 0.01 * np.sin(2 * np.pi * 5.5 * t))
    phase = 2 * np.pi * np.cumsum(f0) / sample_rate
    voice = sum((0.10 / k) * np.sin(k * phase) for k in (1, 2, 3, 5)) * ((t % 2.0) < 1.5)
    hits = np.zeros(frames)
    burst = rng.standard_normal(2400) * np.exp(-np.arange(2400) / 350.0)
    for start in range(0, frames - 2400, sample_rate // 2):
        hits[start:start + 2400] += 0.25 * burst
    bass = 0.16 * np.sin(2 * np.pi * 55.0 * t)
    guitar = 0.07 * np.sin(2 * np.pi * 330.0 * t) + 0.04 * np.sin(2 * np.pi * 662.0 * t + 0.4)
    piano = 0.07 * np.sin(2 * np.pi * 523.0 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.7 * t))
    pad = 0.02 * rng.standard_normal((frames, 2))
    return {
        "vocals": stereo(voice, voice), "drums": stereo(hits, 0.8 * hits), "bass": stereo(bass, bass),
        "guitar": stereo(guitar, 0.3 * guitar), "piano": stereo(0.3 * piano, piano), "other": pad.astype(np.float32),
    }


def band_mix(stems: dict):
    import numpy as np

    return np.sum([stems[name] for name in sorted(stems)], axis=0, dtype=np.float32)
