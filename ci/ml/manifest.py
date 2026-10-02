"""Builds models-v1.json from the conversion reports in `dist` (one entry per published model asset).

Usage: python3 manifest.py <dist> <out.json> [--previous old.json] [--kept name.tar ...]
An asset listed in --kept was not re-uploaded, so its entry is copied from the previous manifest.
"""

import argparse
import glob
import json
import os

parser = argparse.ArgumentParser()
parser.add_argument("dist")
parser.add_argument("out")
parser.add_argument("--previous")
parser.add_argument("--kept", nargs="*", default=[])
args = parser.parse_args()

previous = {}
if args.previous and os.path.exists(args.previous):
    with open(args.previous) as f:
        previous = {m["file"]: m for m in json.load(f).get("models", [])}

models = {}
for entry in previous.values():
    models[entry["file"]] = entry
for path in sorted(glob.glob(os.path.join(args.dist, "*-report.json"))):
    with open(path) as f:
        report = json.load(f)
    asset = report.get("asset")
    if not report.get("passed") or not asset:
        continue
    if asset["file"] in args.kept and asset["file"] in previous:
        continue
    attempts = report.get("attempts", [])
    asset["parity"] = attempts[-1]["units"] if attempts else {}
    models[asset["file"]] = asset

with open(args.out, "w") as f:
    json.dump({"release": "models-v1", "models": sorted(models.values(), key=lambda m: m["file"])}, f, indent=2,
              sort_keys=True)
    f.write("\n")
print(open(args.out).read())
