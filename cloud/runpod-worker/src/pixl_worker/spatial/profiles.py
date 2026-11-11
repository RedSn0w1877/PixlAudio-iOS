"""The six listening profiles. Numbers only; render.py and preview.py give them meaning.

Angles are degrees (0 = front, positive = left, elevation positive = up), distances metres. A stem's centred
content sits at azimuth 0; what is left of its left and right channels sits at +width and -width. Levels between
stems are the mix's own: `gain_db` is for a deliberate nudge only (Intimate's voice).

Rooms are shoeboxes: `size` is (depth, width, height), the listener faces +depth and +width is to their left.
`reflect` is the amplitude reflection of each wall: (back, front, right, left, floor, ceiling); see room.py for why
the side walls are the lively ones and why the listener sits off the centre line (the nearer side wall is a little
softer, so both ears still get the same early energy). `er_db` and `rev_db` are the energy of the early
reflections and of the late reverb relative to the direct sound of a centred source, so they read like a mixing
desk: Studio is dry on purpose (pop masters carry their own reverb), Hall is the wet one.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace

STEM_NAMES = ("vocals", "drums", "bass", "guitar", "piano", "other")
PROFILE_IDS = ("studio", "wide", "intimate", "hall", "surround", "night")
ENGINE_ID = "pixl-spatial-1"


@dataclass(frozen=True)
class Stage:
    width: float
    dist: float = 1.9
    center_el: float = 0.0
    side_el: float = 0.0
    gain_db: float = 0.0
    er: float = 1.0
    rev: float = 1.0
    center: float = 1.0


@dataclass(frozen=True)
class Room:
    size: tuple[float, float, float]
    listener: tuple[float, float, float]
    reflect: tuple[float, float, float, float, float, float]
    damp_hz: float
    er_db: float
    er_max_s: float
    rt60: tuple[float, float, float]  # at 125 Hz, 1 kHz, 8 kHz
    rev_db: float
    mix_time_s: float
    order: int = 3


@dataclass(frozen=True)
class Preview:
    """The on-device version: two virtual speakers at +/- theta, optionally the side signal sent to a second pair,
    and a short sparse room."""
    theta: float
    wet_db: float
    start_ms: float
    end_ms: float
    rt60: float
    side_theta: float = 0.0
    side_gain: float = 0.0


@dataclass(frozen=True)
class Profile:
    id: str
    name: str
    stages: dict[str, Stage]
    mix_stage: Stage
    room: Room
    preview: Preview
    shelf_db: float = 0.0       # high shelf above 7 kHz (Night)
    leveler: float = 0.0        # 0..1, how much loud and quiet passages are pulled together (Night)
    seed: int = 1
    crossover_hz: float = 110.0
    extra: dict = field(default_factory=dict)

    def stage(self, stem: str) -> Stage:
        return self.stages.get(stem) or self.stages["other"]


_STUDIO = Profile(
    id="studio", name="Studio", seed=11,
    stages={
        "vocals": Stage(width=22, dist=1.7, center_el=4, er=0.7, rev=0.7),
        "drums": Stage(width=32, dist=1.9, er=0.8, rev=0.6),
        "bass": Stage(width=12, dist=1.9, er=0.4, rev=0.2),
        "guitar": Stage(width=48, dist=2.0),
        "piano": Stage(width=42, dist=2.0),
        "other": Stage(width=58, dist=2.1, rev=1.1),
    },
    mix_stage=Stage(width=34, dist=1.9),
    room=Room(size=(6.8, 6.0, 3.0), listener=(2.7, 3.5, 1.25), reflect=(0.40, 0.25, 0.72, 0.56, 0.12, 0.20),
              damp_hz=7000, er_db=-11.0, er_max_s=0.07, rt60=(0.34, 0.28, 0.20), rev_db=-17.0, mix_time_s=0.045),
    preview=Preview(theta=30, wet_db=-17, start_ms=9, end_ms=70, rt60=0.28),
)

_WIDE = Profile(
    id="wide", name="Wide", seed=23,
    stages={
        "vocals": Stage(width=28, dist=1.8, center_el=4, er=0.7, rev=0.7),
        "drums": Stage(width=44, dist=2.0, er=0.8, rev=0.6),
        "bass": Stage(width=14, dist=2.0, er=0.4, rev=0.2),
        "guitar": Stage(width=72, dist=2.1),
        "piano": Stage(width=62, dist=2.1),
        "other": Stage(width=88, dist=2.2, rev=1.1),
    },
    mix_stage=Stage(width=55, dist=2.0),
    room=Room(size=(7.8, 7.2, 3.2), listener=(3.1, 4.2, 1.25), reflect=(0.45, 0.25, 0.76, 0.60, 0.12, 0.20),
              damp_hz=7000, er_db=-10.5, er_max_s=0.08, rt60=(0.42, 0.36, 0.25), rev_db=-16.0, mix_time_s=0.05),
    preview=Preview(theta=52, wet_db=-16, start_ms=10, end_ms=80, rt60=0.36, side_theta=100, side_gain=0.35),
)

_INTIMATE = Profile(
    id="intimate", name="Intimate", seed=37,
    stages={
        "vocals": Stage(width=16, dist=0.9, center_el=3, gain_db=1.5, er=0.6, rev=0.5),
        "drums": Stage(width=26, dist=1.6, gain_db=-0.5, er=0.8, rev=0.6),
        "bass": Stage(width=10, dist=1.6, er=0.4, rev=0.2),
        "guitar": Stage(width=38, dist=1.6),
        "piano": Stage(width=34, dist=1.6),
        "other": Stage(width=44, dist=1.7),
    },
    mix_stage=Stage(width=26, dist=1.4),
    room=Room(size=(4.8, 4.2, 2.6), listener=(1.9, 2.45, 1.2), reflect=(0.30, 0.20, 0.60, 0.46, 0.10, 0.15),
              damp_hz=6000, er_db=-16.0, er_max_s=0.05, rt60=(0.24, 0.20, 0.14), rev_db=-24.0, mix_time_s=0.035),
    preview=Preview(theta=22, wet_db=-24, start_ms=6, end_ms=45, rt60=0.20),
)

_HALL = Profile(
    id="hall", name="Concert Hall", seed=53,
    stages={
        "vocals": Stage(width=10, dist=9.0, center_el=2, er=0.8, rev=0.8),
        "drums": Stage(width=18, dist=10.5, er=0.8, rev=0.7),
        "bass": Stage(width=8, dist=10.0, er=0.5, rev=0.3),
        "guitar": Stage(width=26, dist=10.0),
        "piano": Stage(width=24, dist=10.0),
        "other": Stage(width=34, dist=11.0, rev=1.1),
    },
    mix_stage=Stage(width=22, dist=10.0),
    room=Room(size=(38.0, 26.0, 15.0), listener=(15.0, 15.0, 1.4), reflect=(0.70, 0.55, 0.88, 0.78, 0.10, 0.60),
              damp_hz=5000, er_db=-9.5, er_max_s=0.16, rt60=(2.0, 1.7, 1.0), rev_db=-9.5, mix_time_s=0.09, order=2),
    preview=Preview(theta=24, wet_db=-10, start_ms=24, end_ms=180, rt60=1.2, side_theta=110, side_gain=0.25),
)

_SURROUND = Profile(
    id="surround", name="Surround", seed=71,
    stages={
        "vocals": Stage(width=26, dist=1.8, center_el=6, er=0.7, rev=0.7),
        "drums": Stage(width=40, dist=2.0, er=0.8, rev=0.6),
        "bass": Stage(width=14, dist=2.0, er=0.4, rev=0.2),
        "guitar": Stage(width=100, dist=2.0),
        "piano": Stage(width=70, dist=2.0),
        "other": Stage(width=128, dist=2.0, side_el=18, rev=1.1),
    },
    mix_stage=Stage(width=75, dist=2.0),
    room=Room(size=(7.4, 6.8, 3.1), listener=(3.7, 3.9, 1.25), reflect=(0.55, 0.35, 0.74, 0.62, 0.12, 0.22),
              damp_hz=7000, er_db=-9.5, er_max_s=0.08, rt60=(0.48, 0.42, 0.28), rev_db=-14.5, mix_time_s=0.05),
    preview=Preview(theta=38, wet_db=-14, start_ms=10, end_ms=90, rt60=0.42, side_theta=120, side_gain=0.6),
)

_NIGHT = replace(
    _STUDIO, id="night", name="Night", seed=89, shelf_db=-2.5, leveler=0.5,
    stages={name: replace(stage, width=round(stage.width * 0.9)) for name, stage in _STUDIO.stages.items()},
    room=replace(_STUDIO.room, rev_db=-19.0),
    preview=Preview(theta=28, wet_db=-19, start_ms=9, end_ms=70, rt60=0.28),
)

PROFILES: dict[str, Profile] = {p.id: p for p in (_STUDIO, _WIDE, _INTIMATE, _HALL, _SURROUND, _NIGHT)}
assert tuple(PROFILES) == PROFILE_IDS
