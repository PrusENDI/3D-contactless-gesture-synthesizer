"""LOOP canvas: 32 ticks across, eight pitch bands up, one path per engaged run."""

import unittest

from host.v2_console import phase, score as score_mod
from host.v2_console.canvas import primitives
from host.v2_console.views import loop_painter

BAND_LABELS = ["G3", "A3", "C4", "D4", "E4", "G4", "A4", "C5"]
SCORE_DIR = score_mod.SCORE_DIR


def paths(drawing, layer=primitives.STATIC):
    return [item for item in drawing.by_layer()[layer] if isinstance(item, primitives.Path)]


class PaintTest(unittest.TestCase):
    def test_gap_splits_the_path(self):
        contour = [100] * 10 + [0] * 3 + [400] * 19
        drawing = loop_painter.paint_loop({0: contour}, live=None, playhead_u=0.0)
        found = paths(drawing)
        self.assertEqual(len(found), 2)
        self.assertEqual(sum(len(path.points) for path in found), 29)

    def test_eight_bands_are_labelled_with_the_note_names(self):
        drawing = loop_painter.paint_loop({}, live=None, playhead_u=0.0)
        labels = [item.text for item in drawing.by_layer()[primitives.LIVE]
                  if isinstance(item, primitives.Text)]
        self.assertEqual(labels, BAND_LABELS)

    def test_playhead_is_the_only_moving_item(self):
        drawing = loop_painter.paint_loop({0: [100] * 32}, live=None, playhead_u=0.25)
        moving = drawing.by_layer()[primitives.LOOP_LIVE]
        self.assertEqual(len(moving), 1)
        self.assertAlmostEqual(moving[0].u0, 0.25)

    def test_live_take_is_drawn_in_the_moving_layer(self):
        drawing = loop_painter.paint_loop({}, live=[100] * 8, playhead_u=0.0)
        self.assertEqual(len(paths(drawing, primitives.LOOP_LIVE)), 1)


class GuideTest(unittest.TestCase):
    """The score under the take: bands from the hardware, cells for the armed track."""

    def setUp(self):
        self.score = score_mod.load(SCORE_DIR / "c-am-vamp-4s.json")

    def guide(self, track=2, tick=0):
        return loop_painter.paint_loop({}, score=self.score, guide_track=track, tick=tick)

    def cells(self, drawing, key):
        return [item for item in drawing.by_layer()[primitives.STATIC]
                if isinstance(item, primitives.Band) and item.color_key == key]

    def test_the_strips_are_the_hardware_bands_not_equal_slices(self):
        strips = self.cells(self.guide(), "bands")
        self.assertEqual(len(strips), 8)
        # The G3 strip ends where the board starts hearing A3 (y < 3855 -> 60).
        self.assertAlmostEqual(strips[0].v1, 60 / score_mod.CONTOUR_MAX, places=6)
        for lower, upper in zip(strips, strips[1:]):
            self.assertAlmostEqual(lower.v1, upper.v0, places=9)
        self.assertAlmostEqual(strips[-1].v1, 1.0, places=6)
        g3 = strips[0].v1 - strips[0].v0
        a3 = strips[1].v1 - strips[1].v0
        self.assertGreater(a3, 2 * g3)

    def test_the_armed_track_is_filled_in_and_every_track_is_a_line(self):
        drawing = self.guide(track=2)
        filled = self.cells(drawing, "guide")
        self.assertEqual(len(filled), len(self.score.track(2).segments))
        lines = [item for item in drawing.by_layer()[primitives.STATIC]
                 if isinstance(item, primitives.Path)]
        self.assertEqual(len(lines), sum(len(track.segments) for track in self.score.tracks))

    def test_the_current_tick_is_highlighted_at_the_wanted_height(self):
        drawing = self.guide(track=2, tick=8)
        now = self.cells(drawing, "guide_now")
        self.assertEqual(len(now), 1)
        low, high = score_mod.band_of(67)          # track 2 wants G4 from tick 8
        self.assertAlmostEqual(now[0].v0, low / score_mod.CONTOUR_MAX, places=6)
        self.assertAlmostEqual(now[0].u0, 8 / 31.0, places=6)

    def test_without_a_score_nothing_guide_like_is_drawn(self):
        drawing = loop_painter.paint_loop({0: [100] * 32}, live=None, playhead_u=0.0)
        keys = {getattr(item, "color_key", "") for item in drawing.primitives}
        self.assertNotIn("guide", keys)
        self.assertNotIn("guide_now", keys)


class PhaseTest(unittest.TestCase):
    def test_a_bar_is_four_seconds_at_bpm_120(self):
        anchor = phase.PhaseAnchor()
        anchor.force_bar(now=100.0)
        self.assertAlmostEqual(anchor.u(now=104.0), 0.0, places=3)
        self.assertAlmostEqual(anchor.u(now=102.0), 0.5, places=3)
        self.assertAlmostEqual(anchor.u(now=101.0), 0.25, places=3)

    def test_reanchor_moves_the_origin(self):
        anchor = phase.PhaseAnchor()
        anchor.force_bar(now=100.0)
        anchor.reanchor(now=102.0)
        self.assertAlmostEqual(anchor.u(now=103.0), 0.25, places=3)


if __name__ == "__main__":
    unittest.main()
