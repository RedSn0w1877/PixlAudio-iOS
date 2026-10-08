"""`pip check` for the image's deps stage, with two exceptions spelled out instead of ignoring the whole check.

    python3 pip_check.py --save-baseline base.txt     # before installing the lock: record the base image's state
    python3 pip_check.py --baseline base.txt          # after: fail on any NEW problem

1. Problems the pytorch/pytorch base image already had (its dev tools) are not ours: they are recorded before the
   lock is installed and only new lines fail.
2. qwen-asr is installed without its dependencies on purpose (requirements.in): exactly these five may be
   missing — its demo apps' gradio, flask, sox, qwen-omni-utils and pytz. Anything else qwen-asr (or anyone)
   is missing, or any version conflict, fails the build.
Stdlib only.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

QWEN_ASR_SKIPPED = {"gradio", "flask", "sox", "qwen-omni-utils", "pytz"}
_MISSING = re.compile(r"^(?P<pkg>\S+) \S+ requires (?P<dep>[A-Za-z0-9_.-]+), which is not installed\.$")


def _norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def pip_check_lines() -> list[str]:
    proc = subprocess.run([sys.executable, "-m", "pip", "check"], capture_output=True, text=True)
    lines = [line.strip() for line in (proc.stdout + proc.stderr).splitlines() if line.strip()]
    return [line for line in lines if not line.startswith("No broken requirements")]


def allowed(line: str) -> bool:
    match = _MISSING.match(line)
    return bool(match and _norm(match["pkg"]) == "qwen-asr" and _norm(match["dep"]) in QWEN_ASR_SKIPPED)


def new_problems(lines: list[str], baseline: set[str]) -> list[str]:
    return [line for line in lines if line not in baseline and not allowed(line)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--save-baseline")
    group.add_argument("--baseline")
    args = parser.parse_args(argv)
    lines = pip_check_lines()
    if args.save_baseline:
        with open(args.save_baseline, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + ("\n" if lines else ""))
        print(f"pip check baseline: {len(lines)} pre-existing line(s) in the base image")
        return 0
    with open(args.baseline, encoding="utf-8") as fh:
        baseline = {line.strip() for line in fh if line.strip()}
    problems = new_problems(lines, baseline)
    for line in problems:
        print(f"pip check: {line}", file=sys.stderr)
    skipped = sum(1 for line in lines if allowed(line))
    print(f"pip check: {len(problems)} new problem(s); {skipped} expected qwen-asr demo deps not installed")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
