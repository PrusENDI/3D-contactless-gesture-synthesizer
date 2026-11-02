"""LOOP canvas: 32 ticks across, eight pitch bands up, one path per engaged run.

A gap (engaged low, so no contour value) is drawn as a break, not as a line
through zero: the gap is the thing a blind recording cannot hear.

The bands are the hardware's own y intervals, not eight equal slices: a contour
point is drawn at ``y >> 6`` and the note is chosen from the same value, so a
point drawn inside the "E4" strip is a point the board hears as E4.  With a
score loaded, every track's part is drawn on those bands and the track being
recorded is filled in, which is what makes a blind take playable.
"""

from __future__ import annotations

from ..canvas import mapping, primitives
from .. import score as score_mod

NOTE_NAMES = score_mod.NAME_OF
CONTOUR_MAX = mapping.CONTOUR_MAX
LABEL_U = 0.006


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


def _u(tick: float) -> float:
    return min(1.0, max(0.0, tick / mapping.LOOP_TICKS))


def _band_v(note: int) -> tuple[float, float]:
    low, high = score_mod.band_of(note)
    return low / CONTOUR_MAX, high / CONTOUR_MAX


def paint_loop(
    contours: dict,
    live=None,
    playhead_u: float = 0.0,
    score=None,
    guide_track: int | None = None,
    tick: int | None = None,
) -> primitives.Drawing:
    drawing = primitives.Drawing()

    for note in score_mod.NOTES:
        low, high = _band_v(note)
        drawing.add(
            primitives.Band(
                0.0, 1.0, low, high,
                color_key="bands",
                layer=primitives.STATIC,
            )
        )
        # On top, not inside the strip: a filled guide cell would hide a label
        # drawn before it, and the label is the thing that says where the hand goes.
        drawing.add(
            primitives.Text(
                LABEL_U, (low + high) / 2.0, NOTE_NAMES[note],
                anchor="w", layer=primitives.LIVE,
            )
        )

    if score is not None:
        _paint_guide(drawing, score, guide_track, tick)

    drawing.add(primitives.Grid(32, len(score_mod.NOTES), layer=primitives.STATIC))

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


def _paint_guide(drawing, score, guide_track, tick) -> None:
    """The score under the take: filled cells for the armed track, lines for the rest."""
    for track in score.tracks:
        armed = guide_track is not None and track.index == guide_track
        for segment in track.segments:
            low, high = _band_v(segment.note)
            u0, u1 = _u(segment.start), _u(segment.end)
            if armed:
                drawing.add(
                    primitives.Band(u0, u1, low, high, color_key="guide", layer=primitives.STATIC)
                )
            drawing.add(
                primitives.Path(
                    [(u0, (low + high) / 2.0), (u1, (low + high) / 2.0)],
                    width=3.0 if armed else 1.5,
                    color_key="track%d" % track.index,
                    layer=primitives.STATIC,
                )
            )

    if guide_track is None or tick is None:
        return
    wanted = score.targets(guide_track)[min(score.ticks - 1, max(0, tick))]
    if not wanted:
        return
    low, high = _band_v(wanted)
    drawing.add(
        primitives.Band(_u(tick), _u(tick + 1), low, high, color_key="guide_now", layer=primitives.STATIC)
    )
