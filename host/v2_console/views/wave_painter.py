"""Wavetable view: one path over 1024 samples, plus marks where a read-back differs."""

from __future__ import annotations

from ..canvas import mapping, primitives


def paint_wave(samples, diff=None) -> primitives.Drawing:
    """``samples`` are int16 words; ``diff`` is an optional per-index mask of differences."""
    drawing = primitives.Drawing()
    drawing.add(primitives.Grid(8, 4, layer=primitives.STATIC))

    points = [
        mapping.wave_to_uv(index, max(-1.0, min(1.0, sample / 32768.0)))
        for index, sample in enumerate(samples)
    ]
    drawing.add(primitives.Path(points, width=1.5, color_key="wave", layer=primitives.STATIC))

    if diff:
        for index, changed in enumerate(diff):
            if not changed:
                continue
            u = mapping.wave_to_uv(index, 0.0)[0]
            drawing.add(
                primitives.Band(u, u, 0.0, 1.0, color_key="warn", label="diff", layer=primitives.STATIC)
            )
    return drawing
