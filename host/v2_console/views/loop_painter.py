"""LOOP canvas: 32 ticks across, eight pitch bands up, one path per engaged run.

A gap (engaged low, so no contour value) is drawn as a break, not as a line
through zero: the gap is the thing a blind recording cannot hear.
"""

from __future__ import annotations

from ..canvas import mapping, primitives

NOTE_NAMES = ("G3", "A3", "C4", "D4", "E4", "G4", "A4", "C5")


def segments(contour) -> list:
    """Split a 32-value contour into runs of non-zero ticks, keeping tick indices."""
    runs: list = []
    current: list = []
    for tick, value in enumerate(contour):
        if value == 0:
            if current:
                runs.append(current)
                current = []
            continue
        current.append(mapping.loop_to_uv(tick, value))
    if current:
        runs.append(current)
    return runs


def paint_loop(contours: dict, live=None, playhead_u: float = 0.0) -> primitives.Drawing:
    drawing = primitives.Drawing()

    for index, name in enumerate(NOTE_NAMES):
        drawing.add(
            primitives.Band(
                0.0,
                1.0,
                index / len(NOTE_NAMES),
                (index + 1) / len(NOTE_NAMES),
                color_key="bands",
                label=name,
                layer=primitives.STATIC,
            )
        )
    drawing.add(primitives.Grid(32, len(NOTE_NAMES), layer=primitives.STATIC))

    for track, contour in sorted(contours.items()):
        for run in segments(contour):
            drawing.add(
                primitives.Path(run, width=2.0, color_key="track%d" % track, layer=primitives.STATIC)
            )

    if live is not None:
        for run in segments(live):
            drawing.add(primitives.Path(run, width=2.0, color_key="live", layer=primitives.LOOP_LIVE))

    drawing.add(
        primitives.Band(playhead_u, playhead_u, 0.0, 1.0, color_key="playhead", layer=primitives.LOOP_LIVE)
    )
    return drawing
