"""Keep the shared library of renders inside R2's free tier (docs/handoff/2026-11-10-plans/cloud-audio-spec.md,
section 3: "storage must stay free"). Stdlib, plus `cryptography` to open the built-in keys, exactly like e2e.py.

    CLOUD_DEFAULTS_KEY=<base64> python3 deploy/library_janitor.py [--dry-run] [--limit-gb 8] [--blob FILE]

R2 stores 10 GB for free. Every finished render lives under lib/ in the bucket for 30 days (the bucket's own
lifecycle rule), and a busy month could go past the free tier before the rule gets to it. So once a day
(cloud-library-janitor.yml) this script:

1. opens the committed App/Resources/CloudDefaults.enc with CLOUD_DEFAULTS_KEY and masks every value in it;
2. lists everything under lib/ (ListObjectsV2, 1000 keys a page) and adds it up;
3. if that is over the limit (8 GB, which leaves 2 GB of the free tier for uploads and results), deletes
   renders until it is under: first the ones nobody can use (audio whose manifest never arrived, older than an
   hour; renders of an older library version), then the oldest first. A render is its manifest (.json) and its
   audio (.flac): the manifest goes FIRST, so a half-deleted render is never advertised, and its audio is only
   touched once the manifest is gone.

Nothing else in the bucket is listed or touched, and nothing is deleted while the library is under the limit.
The repository is public, so its logs are: only counts and sizes are printed. Never a key, a video id, a URL or a
response body. Without the secret (a fork, or before the keys were baked) it says so and succeeds.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from e2e import DEFAULT_BLOB, PLACEHOLDER_KEY, R2, E2EError, decode_key, open_blob, say  # noqa: E402
from runpod_api import mask  # noqa: E402

PREFIX = "lib/"
GB = 1_000_000_000  # decimal, the smaller reading of "10 GB free": under this limit is under either
DEFAULT_LIMIT_GB = 8.0
PAGE = 1000
MAX_PAGES = 5000  # five million objects: far beyond anything 10 GB of renders can be
ORPHAN_AGE_S = 3600.0  # audio is uploaded seconds before its manifest; an hour without one means it never came
KEY_RE = re.compile(r"^lib/v(\d+)/[^/]+/[^/]+$")
_NS = re.compile(r"^\{[^}]*\}")


@dataclass(frozen=True)
class Obj:
    key: str
    size: int
    modified: float  # seconds since the epoch; 0 when the listing's date could not be read


@dataclass
class Render:
    """The objects of one render: lib/v<N>/<videoId>/<slot>.json and .flac (any other extension counts too)."""
    stem: str
    objects: list[Obj] = field(default_factory=list)

    @property
    def size(self) -> int:
        return sum(o.size for o in self.objects)

    @property
    def manifest(self) -> Obj | None:
        return next((o for o in self.objects if o.key.endswith(".json")), None)

    @property
    def version(self) -> int:
        match = KEY_RE.match(self.objects[0].key) if self.objects else None
        return int(match.group(1)) if match else -1

    @property
    def modified(self) -> float:
        """When the render was finished: its manifest's date (written last), else its newest object's."""
        manifest = self.manifest
        return manifest.modified if manifest is not None else max(o.modified for o in self.objects)

    def deletion_order(self) -> list[Obj]:
        """The manifest first, then the rest: a render is never advertised without its audio."""
        return sorted(self.objects, key=lambda o: (not o.key.endswith(".json"), o.key))


def parse_time(text: str | None) -> float:
    try:
        return datetime.fromisoformat((text or "").strip().replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return 0.0


def parse_page(body: bytes) -> tuple[list[Obj], str | None]:
    """One ListObjectsV2 answer: (its objects, the continuation token or None when the listing is complete)."""
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        raise E2EError("the bucket's listing is not XML") from None
    if _NS.sub("", root.tag) != "ListBucketResult":
        raise E2EError("the bucket's answer is not a listing")
    objects: list[Obj] = []
    token, truncated = None, False
    for child in root:
        tag = _NS.sub("", child.tag)
        if tag == "Contents":
            fields = {_NS.sub("", item.tag): (item.text or "") for item in child}
            key = fields.get("Key", "")
            try:
                size = int(fields.get("Size", ""))
            except ValueError:
                raise E2EError("the bucket's listing has an object without a size") from None
            if key and size >= 0:
                objects.append(Obj(key=key, size=size, modified=parse_time(fields.get("LastModified"))))
        elif tag == "NextContinuationToken":
            token = (child.text or "").strip() or None
        elif tag == "IsTruncated":
            truncated = (child.text or "").strip().lower() == "true"
    if truncated and not token:
        raise E2EError("the bucket's listing says there is more but gives no continuation token")
    return objects, (token if truncated else None)


def list_library(r2: R2, *, prefix: str = PREFIX, max_pages: int = MAX_PAGES) -> list[Obj]:
    """Every object under lib/ (all pages). Anything the bucket returns outside the prefix is ignored."""
    objects: list[Obj] = []
    token: str | None = None
    for _ in range(max_pages):
        query = [("list-type", "2"), ("prefix", prefix), ("max-keys", str(PAGE))]
        if token:
            query.append(("continuation-token", token))
        page, token = parse_page(r2.request("GET", "", what="list lib/ (R2 ListObjectsV2)", query=tuple(query)))
        objects.extend(o for o in page if o.key.startswith(prefix))
        if token is None:
            return objects
    raise E2EError(f"the listing of lib/ did not end after {max_pages} pages")


def group(objects: list[Obj]) -> list[Render]:
    renders: dict[str, Render] = {}
    for obj in objects:
        stem = obj.key.rsplit(".", 1)[0] if "." in obj.key.rsplit("/", 1)[-1] else obj.key
        renders.setdefault(stem, Render(stem)).objects.append(obj)
    return list(renders.values())


def plan(renders: list[Render], limit_bytes: int, *, now: float) -> list[Render]:
    """The renders to delete, in order, so that what stays is at or under the limit. Nothing when it already is.
    First what no phone can use (audio without a manifest for over an hour; renders of an older library version
    than the newest one present), each group oldest first, then complete renders oldest first. A manifest on its
    own (an enhanced.json saying nothing was restored, about 1 KB) goes last of all: deleting it frees nothing
    and would only make phones ask again."""
    total = sum(r.size for r in renders)
    if total <= limit_bytes:
        return []
    newest_version = max((r.version for r in renders), default=-1)

    def rank(render: Render) -> tuple[int, float, str]:
        orphan = render.manifest is None and now - render.modified >= ORPHAN_AGE_S
        stale = render.version < newest_version
        note = render.manifest is not None and len(render.objects) == 1
        return (0 if orphan else 1 if stale else 3 if note else 2, render.modified, render.stem)

    chosen: list[Render] = []
    for render in sorted(renders, key=rank):
        if total <= limit_bytes:
            break
        chosen.append(render)
        total -= render.size
    return chosen


def delete_render(r2: R2, render: Render) -> tuple[int, int, str | None]:
    """Delete one render, manifest first. Returns (objects deleted, bytes freed, what went wrong or None). When
    an object cannot be deleted the rest of the render is left as it is, so a manifest that is still there keeps
    its audio. An object that is already gone (404) counts as deleted."""
    deleted = freed = 0
    for obj in render.deletion_order():
        if not obj.key.startswith(PREFIX):  # belt and braces: this script only ever deletes inside lib/
            return deleted, freed, "an object outside lib/ was about to be deleted"
        try:
            r2.request("DELETE", obj.key, what="delete (R2 DELETE)", expect=(200, 204, 404))
        except E2EError as exc:
            return deleted, freed, str(exc)
        deleted += 1
        freed += obj.size
    return deleted, freed, None


def gb(size: int) -> str:
    return f"{size / GB:.2f} GB"


def run(r2: R2, *, limit_bytes: int, dry_run: bool, now: float | None = None) -> int:
    now = time.time() if now is None else now
    try:
        objects = list_library(r2)
    except E2EError as exc:
        say(f"::error::library janitor FAILED: {exc}")
        return 1
    renders = group(objects)
    total = sum(o.size for o in objects)
    complete = sum(1 for r in renders if r.manifest is not None and len(r.objects) > 1)
    notes = sum(1 for r in renders if r.manifest is not None and len(r.objects) == 1)
    say(f"library: {len(objects)} objects, {gb(total)} of {gb(limit_bytes)}: {complete} renders with audio, "
        f"{notes} manifests without audio, {len(renders) - complete - notes} audio files without a manifest")
    doomed = plan(renders, limit_bytes, now=now)
    if not doomed:
        say("library janitor: under the limit, nothing to delete")
        return 0
    size = sum(r.size for r in doomed)
    oldest_days = max(0.0, (now - min(r.modified for r in doomed)) / 86400.0)
    if dry_run:
        say(f"library janitor (dry run): would delete {len(doomed)} renders, {gb(size)}, the oldest "
            f"{oldest_days:.1f} days old, leaving {gb(total - size)}")
        return 0
    removed = objects_gone = freed = 0
    failures: list[str] = []
    for render in doomed:
        count, bytes_freed, problem = delete_render(r2, render)
        objects_gone += count
        freed += bytes_freed
        if problem is None:
            removed += 1
        else:
            failures.append(problem)
            if len(failures) >= 5:  # storage is refusing: stop, tomorrow's run starts from a fresh listing
                break
    say(f"library janitor: deleted {removed} renders ({objects_gone} objects), freed {gb(freed)}, the oldest "
        f"{oldest_days:.1f} days old; the library is now {gb(total - freed)}")
    if failures:
        say(f"::error::library janitor: {len(failures)} renders could not be deleted ({failures[0]})")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--blob", type=Path, default=DEFAULT_BLOB)
    parser.add_argument("--limit-gb", type=float, default=DEFAULT_LIMIT_GB)
    parser.add_argument("--dry-run", action="store_true", help="say what would be deleted, delete nothing")
    args = parser.parse_args(argv)
    dry_run = args.dry_run or os.environ.get("JANITOR_DRY_RUN", "").strip().lower() == "true"
    if not 0.0 <= args.limit_gb <= 10.0:
        say("::error::library janitor: --limit-gb must be between 0 and 10 (the free tier)")
        return 1
    key_text = os.environ.get("CLOUD_DEFAULTS_KEY", "")
    mask(key_text.strip())
    if not key_text.strip():
        say("::notice::library janitor: the CLOUD_DEFAULTS_KEY secret is not set here, so there is no bucket to "
            "look at (a fork, or the keys were never baked). Nothing done.")
        return 0
    try:
        key = decode_key(key_text)
        if key == decode_key(PLACEHOLDER_KEY):
            say("::notice::library janitor: CLOUD_DEFAULTS_KEY is the public placeholder key. Nothing done.")
            return 0
        keys = open_blob(args.blob.read_bytes(), key)
    except E2EError as exc:
        say(f"::error::library janitor FAILED: {exc}")
        return 1
    except OSError:
        say("::error::library janitor FAILED: the blob could not be read")
        return 1
    say("blob: opened with CLOUD_DEFAULTS_KEY (every value masked)")
    try:
        return run(R2(keys), limit_bytes=int(args.limit_gb * GB), dry_run=dry_run)
    except Exception as exc:  # noqa: BLE001 - a traceback could carry a URL or a value: the type only
        say(f"::error::library janitor FAILED: unexpected {type(exc).__name__}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
