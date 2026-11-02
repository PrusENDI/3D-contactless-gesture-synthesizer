"""The wavetable view: 1024 samples as one path, with differences called out."""

import unittest

from host.v2_console.canvas import primitives
from host.v2_console.views import wave_painter


def paths(drawing):
    return [item for item in drawing.by_layer()["static"] if isinstance(item, primitives.Path)]


class WaveTest(unittest.TestCase):
    def test_1024_points_become_one_path(self):
        drawing = wave_painter.paint_wave([0] * 1024)
        found = paths(drawing)
        self.assertEqual(len(found), 1)
        self.assertEqual(len(found[0].points), 1024)

    def test_differing_samples_are_marked_as_warnings(self):
        diff = [1] + [0] * 1023
        drawing = wave_painter.paint_wave([0] * 1024, diff=diff)
        warns = [item for item in drawing.by_layer()["static"] if item.color_key == "warn"]
        self.assertTrue(warns)

    def test_constant_table_sits_on_the_centre_line(self):
        points = paths(wave_painter.paint_wave([0] * 1024))[0].points
        self.assertEqual({v for _, v in points}, {0.5})

    def test_signed_extremes_reach_both_edges(self):
        # int16 is -32768..32767, so the positive extreme sits one LSB below the edge.
        points = paths(wave_painter.paint_wave([-32768, 32767]))[0].points
        self.assertAlmostEqual(points[0][1], 0.0)
        self.assertGreater(points[1][1], 0.999)


if __name__ == "__main__":
    unittest.main()
