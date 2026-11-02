"""The only module that turns a Drawing into Tk items.

Colours are semantic keys, so a theme change never touches a painter.
"""

from __future__ import annotations

from . import primitives

COLORS = {
    "grid": "#2a2d31",
    "bands": "#16161a",
    "trail": "#2a6f97",
    "live": "#ffcc33",
    "wave": "#7ec8e3",
    "warn": "#c0392b",
    "playhead": "#ff8c42",
    "track0": "#7ec8e3",
    "track1": "#9bd97a",
    "track2": "#d7a1f9",
    "track3": "#f9d77e",
    "guide": "#263c4d",
    "guide_now": "#3e6b8c",
    "dot": "#555555",
    "text": "#888888",
}


# Set once by ui/theme.py at window start-up. Canvas text carries no font of its
# own, so without this the corner labels ignore the Chinese font and the DPI.
FONT = ("Microsoft YaHei UI", 9)


def configure(font=None, colors: dict | None = None) -> None:
    """Let the window choose the font and override any semantic colour."""
    global FONT
    if font is not None:
        FONT = tuple(font)
    if colors:
        COLORS.update(colors)


def _color(key: str) -> str:
    return COLORS.get(key, "#ffffff")


def _point(canvas, u: float, v: float) -> tuple[float, float]:
    width = max(1, canvas.winfo_width())
    height = max(1, canvas.winfo_height())
    return (u * (width - 1), (1.0 - v) * (height - 1))


def draw(canvas, drawing) -> None:
    """Repaint one Drawing. Layers are drawn in their fixed order."""
    canvas.delete("all")
    grouped = drawing.by_layer()
    for layer in primitives.LAYER_ORDER:
        for item in grouped[layer]:
            _draw_one(canvas, item)


def _draw_one(canvas, item) -> None:
    if isinstance(item, primitives.Band):
        x0, y0 = _point(canvas, item.u0, item.v1)
        x1, y1 = _point(canvas, item.u1, item.v0)
        canvas.create_rectangle(
            x0, y0, max(x1, x0 + 1), max(y1, y0 + 1),
            fill=_color(item.color_key), outline="",
        )
        if item.label:
            canvas.create_text(
                x0 + 4, (y0 + y1) / 2, text=item.label, fill=_color("text"), anchor="w", font=FONT
            )
    elif isinstance(item, primitives.Path):
        points = [_point(canvas, u, v) for u, v in item.points]
        if len(points) > 1:
            flat = [coordinate for point in points for coordinate in point]
            canvas.create_line(*flat, fill=_color(item.color_key), width=item.width, smooth=False)
    elif isinstance(item, primitives.Marker):
        x, y = _point(canvas, item.u, item.v)
        radius = 5 if item.shape == "circle" else 2
        canvas.create_oval(x - radius, y - radius, x + radius, y + radius,
                           fill=_color("live" if item.shape == "circle" else "dot"), outline="")
    elif isinstance(item, primitives.Text):
        x, y = _point(canvas, item.u, item.v)
        canvas.create_text(x, y, text=item.text, fill=_color("text"), anchor=item.anchor, font=FONT)
    elif isinstance(item, primitives.Grid):
        width = canvas.winfo_width()
        height = canvas.winfo_height()
        for index in range(1, item.n_u):
            x = index * width / item.n_u
            canvas.create_line(x, 0, x, height, fill=_color(item.color_key))
        for index in range(1, item.n_v):
            y = index * height / item.n_v
            canvas.create_line(0, y, width, y, fill=_color(item.color_key))
