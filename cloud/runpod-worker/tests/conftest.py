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
