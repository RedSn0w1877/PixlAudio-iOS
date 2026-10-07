import pytest

from pixl_worker.deadline import Deadline, job_deadline
from pixl_worker.errors import DEADLINE, WorkerError


class Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


def test_deadline_counts_down_and_raises():
    clock = Clock()
    d = Deadline(10, clock=clock)
    d.check("separate")
    clock.t += 9.5
    assert 0.4 < d.remaining() < 0.6
    assert d.budget(60) == pytest.approx(1.0)  # never below 1 s so a subprocess can start
    clock.t += 1
    with pytest.raises(WorkerError) as info:
        d.check("separate")
    assert info.value.code == DEADLINE and "separate" in info.value.message


def test_job_deadline_uses_env_minus_margin_and_respects_a_smaller_policy():
    clock = Clock()
    assert job_deadline(900, 30, None, clock=clock).remaining() == pytest.approx(870)
    assert job_deadline(900, 30, {"executionTimeout": 600000}, clock=clock).remaining() == pytest.approx(570)
    assert job_deadline(900, 30, {"executionTimeout": 7200000}, clock=clock).remaining() == pytest.approx(870)
    assert job_deadline(900, 30, {"executionTimeout": True}, clock=clock).remaining() == pytest.approx(870)
