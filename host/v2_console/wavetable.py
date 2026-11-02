"""From a hand trajectory to a three-frame morph table.

The solver and the phase aligner already exist and are tested
(``host/wavetable_from_capture.py``, ``host/wavetable_frames.py``); this module is
the thin layer the console needs: trajectory -> table, three frames -> aligned
frames, and the WT_SELECT word that turns the morph on.
"""

from __future__ import annotations

from host.wavetable_frames import align_phase, lfo_step
from host.wavetable_from_capture import solve

MIN_TRAJECTORY = 32
SAMPLE_RATE = 48000
MAX_STEP = (1 << 23) - 1


def table_from_trajectory(points, n: int = 1024) -> list[int]:
    """Arc-length resample of (x, y) samples into one 1024-point cycle at 0.9 FS."""
    if len(points) < MIN_TRAJECTORY:
        raise ValueError(
            "a frame needs at least %d trajectory samples, got %d" % (MIN_TRAJECTORY, len(points))
        )
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return solve(xs, ys, phase="arc", axis="y", n=n)


def align_frames(frames) -> list[list[int]]:
    """Rotate every frame so its fundamental starts at phase 0.

    Without this the midpoint of a crossfade partially cancels and the sweep
    sounds thin, which is the whole reason host/wavetable_frames.py exists.
    """
    return [align_phase([int(sample) for sample in frame]) for frame in frames]


def bar_step(period_s: float) -> int:
    """WT_SELECT[31:9]: one 0..2 sweep in the given number of seconds."""
    step = int(lfo_step(max(0.01, period_s)))
    return min(step, MAX_STEP)


def select_word(table: int, shift: int, morph: bool, step: int) -> int:
    """The WT_SELECT write that makes the morph audible."""
    return (
        ((step & MAX_STEP) << 9)
        | ((1 if morph else 0) << 8)
        | ((shift & 0xF) << 4)
        | (table & 0x3)
    )
