#!/usr/bin/env bash
# Exports screenshot attachments from an .xcresult into <out>/<name>.png (names from XCTAttachment.name).
# Usage: ci/export-shots.sh <result.xcresult> <out-dir>
set -euo pipefail
bundle="$1"; out="$2"
raw="$out/.raw"
rm -rf "$out"; mkdir -p "$raw"
xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw"
python3 - "$raw" "$out" <<'PY'
import json, os, re, shutil, sys
raw, out = sys.argv[1], sys.argv[2]
with open(os.path.join(raw, "manifest.json")) as f:
    manifest = json.load(f)
found = []
def walk(node):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            found.append(node)
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(manifest)
count = 0
for a in found:
    src = os.path.join(raw, a["exportedFileName"])
    if not os.path.exists(src):
        continue
    name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
    stem, ext = os.path.splitext(name)
    # Xcode appends "_<index>_<UUID>" to the attachment name.
    stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem)
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem) or "attachment"
    dst = os.path.join(out, stem + (ext or ".png"))
    n = 2
    while os.path.exists(dst):
        dst = os.path.join(out, f"{stem}-{n}{ext or '.png'}"); n += 1
    shutil.copyfile(src, dst)
    count += 1
    print("exported", os.path.basename(dst))
print(f"{count} attachment(s) exported to {out}")
PY
rm -rf "$raw"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Screenshots"; ls "$out" | sed 's/^/- /'; } >> "$GITHUB_STEP_SUMMARY"
fi
