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


def test_only_library_jobs_get_the_endpoints_longer_limit():
    from pixl_worker.config import load_caps
    from pixl_worker.deadline import CLASSIC_EXECUTION_TIMEOUT_S, time_limit_s

    # The endpoint allows 1800 s since worker 1.1.0. A phone still sends every job without library tasks with
    # policy.executionTimeout 900,000, which the worker never sees: such a job must still end itself at 870 s.
    assert load_caps({}).execution_timeout_s == 1800 and CLASSIC_EXECUTION_TIMEOUT_S == 900
    assert time_limit_s(1800, library_job=True) == 1800 and time_limit_s(1800, library_job=False) == 900
    assert time_limit_s(600, library_job=True) == 600 and time_limit_s(600, library_job=False) == 600  # env wins
    clock = Clock()
    assert job_deadline(time_limit_s(1800, True), 30, None, clock=clock).remaining() == pytest.approx(1770)
    assert job_deadline(time_limit_s(1800, False), 30, None, clock=clock).remaining() == pytest.approx(870)
