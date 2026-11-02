"""Wavetable view: the recorded frames, the one being looked at, and read-back diffs.

The morph frames used to share one canvas and the last capture overwrote the one
before it, so A/B/C could be recorded but never seen together -- and the thing the
LFO actually plays (the blend) was not drawn at all.
"""

from __future__ import annotations

from ..canvas import mapping, primitives

FRAME_COLOURS = ("track0", "track1", "track2")


def _points(samples):
    return [
        mapping.wave_to_uv(index, max(-1.0, min(1.0, sample / 32768.0)))
        for index, sample in enumerate(samples)
    ]


def paint_wave(samples, diff=None, frames=None, current=None) -> primitives.Drawing:
    """``samples`` are int16 words; ``diff`` is an optional per-index mask of differences.

    ``frames`` (optional) is ``{0: [...], 1: [...], 2: [...]}``: every recorded morph
    frame is drawn thin in its own colour, and ``current`` (the frame on screen) is
    drawn thick. With no ``frames`` this is exactly the single-table view.
    """
    drawing = primitives.Drawing()
    drawing.add(primitives.Grid(8, 4, layer=primitives.STATIC))

    if frames:
        for table, frame in sorted(frames.items()):
            if not frame:
                continue
            thick = table == current
            drawing.add(
                primitives.Path(
                    _points(frame),
                    width=2.5 if thick else 1.0,
                    color_key="wave" if thick else FRAME_COLOURS[table % 3],
                    layer=primitives.STATIC,
                )
            )
            drawing.add(
                primitives.Text(
                    0.004, 0.94 - 0.05 * table, "ABCD"[table],
                    anchor="w", layer=primitives.LIVE,
                )
            )
    else:
        drawing.add(primitives.Path(_points(samples), width=1.5, color_key="wave",
                                    layer=primitives.STATIC))

    if diff:
        for index, changed in enumerate(diff):
            if not changed:
                continue
            u = mapping.wave_to_uv(index, 0.0)[0]
            drawing.add(
                primitives.Band(u, u, 0.0, 1.0, color_key="warn", label="diff", layer=primitives.STATIC)
            )
    return drawing
