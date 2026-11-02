"""LOOP canvas: 32 ticks across, eight pitch bands up, one path per engaged run."""

import unittest

from host.v2_console import phase
from host.v2_console.canvas import primitives
from host.v2_console.views import loop_painter

BAND_LABELS = ["G3", "A3", "C4", "D4", "E4", "G4", "A4", "C5"]


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
        labels = [item.label for item in drawing.by_layer()[primitives.STATIC]
                  if isinstance(item, primitives.Band)]
        self.assertEqual(labels, BAND_LABELS)

    def test_playhead_is_the_only_moving_item(self):
        drawing = loop_painter.paint_loop({0: [100] * 32}, live=None, playhead_u=0.25)
        moving = drawing.by_layer()[primitives.LOOP_LIVE]
        self.assertEqual(len(moving), 1)
        self.assertAlmostEqual(moving[0].u0, 0.25)

    def test_live_take_is_drawn_in_the_moving_layer(self):
        drawing = loop_painter.paint_loop({}, live=[100] * 8, playhead_u=0.0)
        self.assertEqual(len(paths(drawing, primitives.LOOP_LIVE)), 1)


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
