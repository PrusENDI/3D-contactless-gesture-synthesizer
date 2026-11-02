"""Display-list primitives. Painters build these; only the renderer imports tkinter."""

from __future__ import annotations

from dataclasses import dataclass, field

LAYER_ORDER: tuple[str, ...] = ("static", "loop_live", "live")

STATIC, LOOP_LIVE, LIVE = LAYER_ORDER


@dataclass
class Path:
    points: list
    closed: bool = False
    width: float = 1.0
    color_key: str = "live"
    layer: str = STATIC


@dataclass
class Band:
    u0: float
    u1: float
    v0: float
    v1: float
    color_key: str = "bands"
    label: str = ""
    layer: str = STATIC


@dataclass
class Marker:
    u: float
    v: float
    shape: str = "circle"
    label: str = ""
    layer: str = LIVE


@dataclass
class Text:
    u: float
    v: float
    text: str
    anchor: str = "center"
    layer: str = STATIC


@dataclass
class Grid:
    n_u: int
    n_v: int
    layer: str = STATIC


@dataclass
class Drawing:
    """An ordered list of primitives tagged with one of the three layers."""

    primitives: list = field(default_factory=list)

    def add(self, primitive) -> None:
        if primitive.layer not in LAYER_ORDER:
            raise ValueError("layer must be one of %s, got %r" % (LAYER_ORDER, primitive.layer))
        self.primitives.append(primitive)

    def by_layer(self) -> dict:
        grouped = {name: [] for name in LAYER_ORDER}
        for primitive in self.primitives:
            grouped[primitive.layer].append(primitive)
        return grouped
