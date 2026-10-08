"""The job's global deadline (design 2.4): executionTimeout − 30 s, checked between stages and inside the chunk
loops (separation progress hook, aligner/ASR batches). Running out ends the job with DEADLINE and the manifest is
still written, so the phone learns why."""

from __future__ import annotations

import time
from typing import Callable

from .errors import DEADLINE, WorkerError


class Deadline:
    def __init__(self, seconds: float, *, clock: Callable[[], float] = time.monotonic):
        self._clock = clock
        self._start = clock()
        self._end = self._start + max(0.0, seconds)

    def remaining(self) -> float:
        return self._end - self._clock()

    def elapsed_ms(self) -> int:
        return int(round((self._clock() - self._start) * 1000))

    def check(self, stage: str) -> None:
        if self.remaining() <= 0:
            raise WorkerError(DEADLINE, f"the job ran out of time during {stage}")

    def budget(self, limit_s: float) -> float:
        """A stage's own limit, never past the global deadline (at least 1 s so a subprocess can start)."""
        return max(1.0, min(limit_s, self.remaining()))


def job_deadline(execution_timeout_s: float, margin_s: float, policy: dict | None = None,
                 clock: Callable[[], float] = time.monotonic) -> Deadline:
    """RunPod doesn't hand the request's policy to the worker today, so the endpoint timeout (env) is the source;
    if a policy.executionTimeout ever arrives with the job, the smaller value wins."""
    seconds = float(execution_timeout_s)
    if isinstance(policy, dict):
        value = policy.get("executionTimeout")
        if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
            seconds = min(seconds, value / 1000.0)
    return Deadline(seconds - margin_s, clock=clock)
