"""Spatial audio for headphones: a binaural render of a song from its stems, in six profiles.

NumPy only (no torch, no SciPy), deterministic, and unit-tested on the CPU. The contract with the rest of the
worker and with the apps is docs/handoff/2026-11-10-plans/cloud-audio-spec.md.

    from pixl_worker.spatial import render_profiles, PROFILE_IDS, ENGINE_ID
"""

from .profiles import ENGINE_ID, PROFILE_IDS, PROFILES, STEM_NAMES
from .render import CEILING_DB, HEADROOM_DB, SpatialResult, render_profiles

__all__ = ["CEILING_DB", "ENGINE_ID", "HEADROOM_DB", "PROFILE_IDS", "PROFILES", "STEM_NAMES", "SpatialResult",
           "render_profiles"]
