"""Fail when the Dockerfile and weights.lock disagree (design 2.1). Stdlib only.

    python ci/check_weights.py [--dockerfile Dockerfile] [--lock weights.lock]

Checks:
- every `ADD` of a URL carries `--checksum=sha256:<hex>`, `--link` and `--chmod=644`, and matches a `large` row of
  weights.lock exactly (sha256, url, dest);
- the `final` stage ADDs every `large` row, once; other stages may only repeat rows (the CI smoke stage);
- Hugging Face URLs name a 40-hex commit revision, never a branch such as `main`;
- the `final` stage has no RUN (see the Dockerfile's header for why);
- the syntax frontend, every global ARG used as a base image and every external FROM are pinned by @sha256 digest;
- weights.lock itself parses (fetch_small.parse_lock), so a malformed row fails here before any download.
"""

from __future__ import annotations

import argparse
import re
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fetch_small import LockError, parse_lock  # noqa: E402

HF_URL = re.compile(r"^https://huggingface\.co/[^/]+/[^/]+/resolve/(?P<rev>[^/]+)/.+$")
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")


def instructions(text: str) -> list[tuple[int, str, str]]:
    """(line number, INSTRUCTION, rest) with backslash continuations joined and comments dropped."""
    out: list[tuple[int, str, str]] = []
    buf, start = "", 0
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.rstrip()
        if not buf and (not line.strip() or line.lstrip().startswith("#")):
            continue
        if buf and line.lstrip().startswith("#"):
            continue  # comment lines inside a continued instruction are ignored by the Dockerfile parser
        if not buf:
            start = number
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        word, _, rest = buf.strip().partition(" ")
        out.append((start, word.upper(), rest.strip()))
        buf = ""
    if buf:
        word, _, rest = buf.strip().partition(" ")
        out.append((start, word.upper(), rest.strip()))
    return out


def check(dockerfile: str, lock_text: str) -> list[str]:
    errors: list[str] = []
    try:
        rows = parse_lock(lock_text)
    except LockError as exc:
        return [str(exc)]
    large = {(r.sha256, r.url, r.dest): r for r in rows if r.kind == "large"}
    for row in rows:
        match = HF_URL.match(row.url)
        if match and not re.fullmatch(r"[0-9a-f]{40}", match["rev"]):
            errors.append(f"weights.lock:{row.line}: Hugging Face URL must pin a commit revision, not {match['rev']!r}")

    first = dockerfile.splitlines()[0] if dockerfile else ""
    if not (first.startswith("# syntax=") and DIGEST.search(first.strip())):
        errors.append("Dockerfile:1: the # syntax= frontend must be pinned by @sha256 digest")

    global_args: dict[str, str] = {}
    stage = None
    seen_final: dict[tuple, int] = {}
    stages: list[str] = []
    for number, word, rest in instructions(dockerfile):
        if word == "ARG" and stage is None:
            name, _, default = rest.partition("=")
            global_args[name.strip()] = default.strip()
            continue
        if word == "FROM":
            parts = rest.split()
            image = parts[0]
            stage = parts[2].lower() if len(parts) >= 3 and parts[1].upper() == "AS" else None
            stages.append(stage or "")
            ref = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", image)
            if ref:
                value = global_args.get(ref.group(1), "")
                if not DIGEST.search(value):
                    errors.append(f"Dockerfile:{number}: ARG {ref.group(1)} must default to an image pinned by @sha256")
            elif image.lower() not in stages[:-1] and not DIGEST.search(image):
                errors.append(f"Dockerfile:{number}: FROM {image} must be pinned by @sha256 digest")
            continue
        if word == "RUN" and stage == "final":
            errors.append(f"Dockerfile:{number}: the final stage must not RUN anything")
        if word != "ADD":
            continue
        tokens = shlex.split(rest)
        flags = [t for t in tokens if t.startswith("--")]
        args = [t for t in tokens if not t.startswith("--")]
        if len(args) != 2 or not args[0].startswith(("http://", "https://")):
            continue  # local ADDs are fine (none today)
        url, dest = args
        checksum = next((f.split("=", 1)[1] for f in flags if f.startswith("--checksum=")), None)
        if checksum is None or not checksum.startswith("sha256:"):
            errors.append(f"Dockerfile:{number}: ADD of a URL needs --checksum=sha256:<hex>")
            continue
        if "--link" not in flags:
            errors.append(f"Dockerfile:{number}: ADD of a weight file needs --link")
        if "--chmod=644" not in flags:
            errors.append(f"Dockerfile:{number}: ADD of a weight file needs --chmod=644")
        key = (checksum[len("sha256:"):], url, dest)
        if key not in large:
            errors.append(f"Dockerfile:{number}: ADD {dest} does not match any large row of weights.lock "
                          "(sha256, url and dest must all agree)")
            continue
        if stage == "final":
            if key in seen_final:
                errors.append(f"Dockerfile:{number}: {dest} is added twice in the final stage")
            seen_final[key] = number
    if "final" not in stages:
        errors.append("Dockerfile: no stage named final")
    for key, row in large.items():
        if key not in seen_final:
            errors.append(f"weights.lock:{row.line}: {row.dest} has no ADD line in the final stage")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dockerfile", default=str(ROOT / "Dockerfile"))
    parser.add_argument("--lock", default=str(ROOT / "weights.lock"))
    args = parser.parse_args(argv)
    errors = check(Path(args.dockerfile).read_text(encoding="utf-8"), Path(args.lock).read_text(encoding="utf-8"))
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print("check_weights: Dockerfile and weights.lock agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
