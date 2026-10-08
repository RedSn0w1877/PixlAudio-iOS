"""Fetch the small model files in weights.lock (kind `small`: configs, tokenizers, the bag yaml) by their pinned
URLs and verify each file's size and sha256. Runs in the Dockerfile's `small` stage. Stdlib only.

    python fetch_small.py --lock weights.lock --out /models

The large files are not fetched here: each is an `ADD --link --checksum` line in the Dockerfile, which BuildKit
verifies and caches by checksum (ci/check_weights.py keeps those lines and weights.lock in step).
`parse_lock()` is the one reader of weights.lock; ci/check_weights.py imports it.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass

KINDS = ("large", "small")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MODELS_ROOT = "/models/"


@dataclass(frozen=True)
class Row:
    line: int
    kind: str
    slot: str
    sha256: str
    bytes: int
    license: str
    dest: str
    url: str


class LockError(ValueError):
    pass


def parse_lock(text: str) -> list[Row]:
    """Rows of weights.lock: `kind slot sha256 bytes license dest url`, whitespace-separated; `#` starts a
    comment line. Raises LockError on a malformed row."""
    rows: list[Row] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 7:
            raise LockError(f"weights.lock:{number}: expected 7 columns, found {len(parts)}")
        kind, slot, sha, size, license_, dest, url = parts
        if kind not in KINDS:
            raise LockError(f"weights.lock:{number}: kind must be large or small")
        if not SHA256_RE.match(sha):
            raise LockError(f"weights.lock:{number}: sha256 must be 64 lower-case hex digits")
        if not size.isdigit() or int(size) <= 0:
            raise LockError(f"weights.lock:{number}: bytes must be a positive integer")
        if not dest.startswith(MODELS_ROOT) or ".." in dest.split("/") or dest.endswith("/"):
            raise LockError(f"weights.lock:{number}: dest must be a file path under {MODELS_ROOT}")
        if not url.startswith("https://"):
            raise LockError(f"weights.lock:{number}: url must be https")
        rows.append(Row(number, kind, slot, sha, int(size), license_, dest, url))
    dests = [row.dest for row in rows]
    duplicates = sorted({d for d in dests if dests.count(d) > 1})
    if duplicates:
        raise LockError(f"weights.lock: duplicate dest {duplicates[0]}")
    return rows


def _download(url: str, dest: str, expect_size: int, expect_sha: str, *, tries: int = 4,
              opener=urllib.request.urlopen, sleep=time.sleep) -> None:
    last = "unknown"
    for attempt in range(tries):
        tmp = dest + ".part"
        try:
            digest = hashlib.sha256()
            size = 0
            with opener(urllib.request.Request(url, headers={"User-Agent": "pixl-cloud-worker-build"}),
                        timeout=60) as resp, open(tmp, "wb") as fh:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > expect_size:
                        raise LockError(f"{os.path.basename(dest)}: larger than the {expect_size} bytes in weights.lock")
                    digest.update(chunk)
                    fh.write(chunk)
            if size != expect_size:
                raise LockError(f"{os.path.basename(dest)}: {size} bytes, weights.lock says {expect_size}")
            if digest.hexdigest() != expect_sha:
                raise LockError(f"{os.path.basename(dest)}: sha256 {digest.hexdigest()} does not match weights.lock")
            os.replace(tmp, dest)
            return
        except LockError:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            last = f"{type(exc).__name__}: {exc}"
            if os.path.exists(tmp):
                os.remove(tmp)
            sleep(min(30.0, 2.0 * (2 ** attempt)))
    raise LockError(f"{os.path.basename(dest)}: download failed after {tries} tries ({last})")


def fetch(rows: list[Row], out_root: str, **kwargs) -> int:
    count = 0
    for row in rows:
        if row.kind != "small":
            continue
        dest = os.path.join(out_root, row.dest[len(MODELS_ROOT):])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        _download(row.url, dest, row.bytes, row.sha256, **kwargs)
        count += 1
        print(f"ok {row.slot:8s} {row.dest} ({row.bytes} bytes)", flush=True)
    return count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch and verify the small model files in weights.lock")
    parser.add_argument("--lock", default="weights.lock")
    parser.add_argument("--out", default="/models")
    args = parser.parse_args(argv)
    try:
        with open(args.lock, encoding="utf-8") as fh:
            rows = parse_lock(fh.read())
        count = fetch(rows, args.out)
    except LockError as exc:
        print(f"fetch_small: {exc}", file=sys.stderr)
        return 1
    print(f"fetch_small: {count} files verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
