"""Live cursor view: corner references, a trail, and the cursor itself."""

from __future__ import annotations

from ..canvas import mapping, primitives

TRAIL_POINTS = 400


def _flip(x: int, y: int, flip: str) -> tuple[int, int]:
    if flip in ("x", "both"):
        x = 65535 - x
    if flip in ("y", "both"):
        y = 65535 - y
    return x, y


def paint_live(buffer, flip: str = "y") -> primitives.Drawing:
    """Corner references are static; the cursor and its trail repaint every frame.

    Flip belongs to the acquisition boundary; with no separate acquisition layer
    yet, this painter applies it before the mapping so the mapping stays pure.
    """
    drawing = primitives.Drawing()
    for cx, cy, tag, anchor in (
        (0.0, 0.0, "0,65535", "sw"),
        (1.0, 0.0, "65535,65535", "se"),
        (0.0, 1.0, "0,0", "nw"),
        (1.0, 1.0, "65535,0", "ne"),
    ):
        drawing.add(primitives.Marker(cx, cy, shape="dot", layer=primitives.STATIC))
        drawing.add(primitives.Text(cx, cy, tag, anchor=anchor, layer=primitives.STATIC))
    drawing.add(primitives.Grid(2, 2, layer=primitives.STATIC))

    trail = [(mapping.sensor_to_uv(*_flip(x, y, flip))) for x, y in buffer.trail(TRAIL_POINTS)]
    if len(trail) > 1:
        drawing.add(primitives.Path(trail, width=2.0, color_key="trail", layer=primitives.LIVE))
    if trail:
        drawing.add(primitives.Marker(trail[-1][0], trail[-1][1], shape="circle", layer=primitives.LIVE))
    return drawing
