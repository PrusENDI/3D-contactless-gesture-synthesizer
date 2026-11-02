"""Normalised canvas coordinates and the display list three views share."""

import unittest

from host.v2_console.canvas import mapping, primitives


class MappingTest(unittest.TestCase):
    def test_live_mapping_takes_already_flipped_coordinates(self):
        # The caller applies flip; v is up, so y=0 lands at the top of the canvas.
        self.assertEqual(mapping.sensor_to_uv(0, 0), (0.0, 1.0))
        self.assertEqual(mapping.sensor_to_uv(65535, 65535), (1.0, 0.0))
        self.assertEqual(mapping.sensor_to_uv(65535, 0), (1.0, 1.0))

    def test_loop_mapping_is_32_ticks_by_10_bit_contour(self):
        self.assertEqual(mapping.loop_to_uv(0, 0), (0.0, 0.0))
        self.assertEqual(mapping.loop_to_uv(31, 1023), (1.0, 1.0))

    def test_wave_mapping_keeps_signed_samples_centred(self):
        self.assertEqual(mapping.wave_to_uv(0, -1.0), (0.0, 0.0))
        self.assertEqual(mapping.wave_to_uv(1023, 1.0), (1.0, 1.0))
        self.assertAlmostEqual(mapping.wave_to_uv(511, 0.0)[1], 0.5)


class DisplayListTest(unittest.TestCase):
    def test_layer_order_is_fixed(self):
        self.assertEqual(primitives.LAYER_ORDER, ("static", "loop_live", "live"))

    def test_drawing_groups_by_layer_in_order(self):
        drawing = primitives.Drawing()
        drawing.add(primitives.Marker(0.5, 0.5, layer="live"))
        drawing.add(primitives.Path([(0.0, 0.0)], layer="static"))
        drawing.add(primitives.Band(0.0, 1.0, 0.0, 0.5, layer="loop_live"))
        grouped = drawing.by_layer()
        self.assertEqual(list(grouped), list(primitives.LAYER_ORDER))
        self.assertIsInstance(grouped["static"][0], primitives.Path)
        self.assertIsInstance(grouped["live"][0], primitives.Marker)

    def test_drawing_rejects_an_unknown_layer(self):
        with self.assertRaises(ValueError):
            primitives.Drawing().add(primitives.Marker(0.0, 0.0, layer="cursor"))


if __name__ == "__main__":
    unittest.main()
