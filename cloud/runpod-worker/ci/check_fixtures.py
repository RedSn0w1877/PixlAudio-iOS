"""Fail when the app's copies of the worker's contract files drift from the originals (design 2.3). Stdlib only.

    python ci/check_fixtures.py

Two sets of files have their single source of truth here and byte-identical copies in the app:

- schema/v1/examples/ (the job, result and manifest examples). The app's tests decode copies in
  Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/ (added with step P1). Every file there must be
  byte-identical to the example of the same name. Until that folder exists this passes with a notice.
- schema/v1/spatial/ (the on-device Spatial audio tables and their golden output, written by
  `python -m pixl_worker.spatial.preview --out schema/v1/spatial`; never edited by hand). The app ships the tables
  as a resource and its tests replay the golden file, so a file of the same name anywhere under App/Resources/ or
  under a Fixtures folder of Packages/PixlCore/Tests/ must be byte-identical to the original
  (docs/handoff/2026-11-10-plans/cloud-audio-spec.md, section 7). No copy yet is fine; a copy that differs, by one
  byte or one line ending, is not: both platforms must compute from the same numbers as the cloud renderer.
"""

from __future__ import annotations

import sys
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1]
# cloud/runpod-worker -> the repository root (inside the test container the worker is /t, with no repo around it)
REPO = WORKER.parents[1] if len(WORKER.parents) > 1 else WORKER
EXAMPLES = WORKER / "schema" / "v1" / "examples"
APP_COPIES = REPO / "Packages" / "PixlCore" / "Tests" / "PixlNetTests" / "Fixtures" / "cloud"
SPATIAL = WORKER / "schema" / "v1" / "spatial"
APP_RESOURCES = REPO / "App" / "Resources"
PACKAGE_TESTS = REPO / "Packages" / "PixlCore" / "Tests"


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


def spatial_copies(originals: Path = SPATIAL, resources: Path = APP_RESOURCES,
                   package_tests: Path = PACKAGE_TESTS) -> list[tuple[Path, Path]]:
    """(original, copy) for every app-side file named like a file of schema/v1/spatial/: anywhere under
    App/Resources/, and anywhere under a folder called Fixtures inside Packages/PixlCore/Tests/."""
    pairs: list[tuple[Path, Path]] = []
    if not originals.is_dir():
        return pairs
    for original in sorted(originals.glob("*.json")):
        found: list[Path] = []
        if resources.is_dir():
            found += resources.rglob(original.name)
        if package_tests.is_dir():
            found += [p for p in package_tests.rglob(original.name) if "Fixtures" in p.relative_to(package_tests).parts]
        pairs += [(original, copy) for copy in sorted(set(found)) if copy.is_file()]
    return pairs


def spatial_drift(originals: Path = SPATIAL, resources: Path = APP_RESOURCES,
                  package_tests: Path = PACKAGE_TESTS, repo: Path = REPO) -> list[str]:
    problems = []
    for original, copy in spatial_copies(originals, resources, package_tests):
        if original.read_bytes() != copy.read_bytes():
            try:
                where = copy.relative_to(repo).as_posix()
            except ValueError:
                where = copy.as_posix()
            problems.append(f"{where}: differs from cloud/runpod-worker/schema/v1/spatial/{original.name} "
                            "(copy the file again; never edit either by hand)")
    return problems


def main() -> int:
    problems: list[str] = []
    if APP_COPIES.is_dir():
        problems += drift()
    else:
        print("check_fixtures: the app has no copies yet (Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud)")
    copies = spatial_copies()
    if copies:
        problems += spatial_drift()
        print(f"check_fixtures: {len(copies)} app copies of the spatial tables checked")
    else:
        print("check_fixtures: the app has no copies of schema/v1/spatial yet (App/Resources, "
              "Packages/PixlCore/Tests/*/Fixtures)")
    for problem in problems:
        print(problem, file=sys.stderr)
    print(f"check_fixtures: {len(problems)} drifted file(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
