"""Canvas coordinates. Every view draws in (u, v) inside [0, 1]^2 with v up.

The transform takes coordinates that have *already* been flipped: flip is a
property of the sensor mounting and belongs to the code that reads the frame,
not to the painter.
"""

from __future__ import annotations

SENSOR_MAX = 65535.0
LOOP_TICKS = 31.0
CONTOUR_MAX = 1023.0
WAVE_POINTS = 1023.0


def sensor_to_uv(x: int, y: int) -> tuple[float, float]:
    """Live cursor: x across, y up (the caller has applied flip)."""
    return (x / SENSOR_MAX, 1.0 - y / SENSOR_MAX)


def loop_to_uv(tick: int, contour: int) -> tuple[float, float]:
    """One contour point: tick across a 32-tick bar, 10-bit contour up."""
    return (tick / LOOP_TICKS, contour / CONTOUR_MAX)


def wave_to_uv(index: int, sample: float) -> tuple[float, float]:
    """Wavetable sample in -1..+1, centred vertically."""
    return (index / WAVE_POINTS, (1.0 + sample) / 2.0)
