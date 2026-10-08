"""Fail when the app's copies of the schema examples drift from the worker's (design 2.3). Stdlib only.

    python ci/check_fixtures.py

schema/v1/examples/ is the single source of truth. The app's tests decode copies in
Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/ (added with step P1). Every file there must be
byte-identical to the example of the same name. Until that folder exists this passes with a notice.
"""

from __future__ import annotations

import sys
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1]
# cloud/runpod-worker -> the repository root (inside the test container the worker is /t, with no repo around it)
REPO = WORKER.parents[1] if len(WORKER.parents) > 1 else WORKER
EXAMPLES = WORKER / "schema" / "v1" / "examples"
APP_COPIES = REPO / "Packages" / "PixlCore" / "Tests" / "PixlNetTests" / "Fixtures" / "cloud"


def drift(examples: Path = EXAMPLES, copies: Path = APP_COPIES) -> list[str]:
    if not copies.is_dir():
        return []
    problems = []
    for copy in sorted(copies.glob("*.json")):
        source = examples / copy.name
        if not source.is_file():
            problems.append(f"{copy.name}: no such example in cloud/runpod-worker/schema/v1/examples")
        elif source.read_bytes() != copy.read_bytes():
            problems.append(f"{copy.name}: differs from cloud/runpod-worker/schema/v1/examples/{copy.name}")
    return problems


def main() -> int:
    if not APP_COPIES.is_dir():
        print("check_fixtures: the app has no copies yet (Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud)")
        return 0
    problems = drift()
    for problem in problems:
        print(problem, file=sys.stderr)
    print(f"check_fixtures: {len(problems)} drifted file(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
