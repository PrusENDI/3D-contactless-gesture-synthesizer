"""The live view: a cursor trail that keeps quiet when no hand is in the field."""

import unittest

from host.v2_console import frames
from host.v2_console.canvas import primitives
from host.v2_console.views import live_painter
from host.v2_console.telemetry import TelemetryBuffer


def snapshot(seq: int, x: int = 32768, y: int = 32768, z: int = 3000) -> frames.Telemetry:
    return frames.Telemetry(
        seq=seq, x=x, y=y, z=z, note=60, flags=0, tick=0, voices=0, fifo=0, fault=0
    )


class BufferTest(unittest.TestCase):
    def test_no_frames_means_waiting_not_an_error(self):
        self.assertTrue(TelemetryBuffer().waiting())

    def test_waiting_stops_after_a_frame(self):
        buf = TelemetryBuffer()
        buf.push(snapshot(1))
        self.assertFalse(buf.waiting())

    def test_trail_is_capped_and_ends_at_the_last_frame(self):
        buf = TelemetryBuffer()
        for index in range(500):
            buf.push(snapshot(index, x=index))
        trail = buf.trail(400)
        self.assertEqual(len(trail), 400)
        self.assertEqual(trail[-1], (499, 32768))


class PainterTest(unittest.TestCase):
    def test_corners_and_cursor(self):
        buf = TelemetryBuffer()
        buf.push(snapshot(1))
        drawing = live_painter.paint_live(buf)
        live = drawing.by_layer()["live"]
        markers = [item for item in live if isinstance(item, primitives.Marker)]
        self.assertEqual(len(markers), 1)
        self.assertAlmostEqual(markers[0].u, 32768 / 65535, places=4)
        self.assertAlmostEqual(markers[0].v, 1.0 - 32768 / 65535, places=4)
        static = drawing.by_layer()["static"]
        self.assertGreaterEqual(len([item for item in static if isinstance(item, primitives.Marker)]), 4)
        self.assertIn("65535,0", [item.text for item in static if isinstance(item, primitives.Text)])

    def test_flip_is_applied_before_mapping(self):
        buf = TelemetryBuffer()
        buf.push(snapshot(1, x=0, y=0))
        marker = [i for i in live_painter.paint_live(buf, flip="y").by_layer()["live"]
                  if isinstance(i, primitives.Marker)][0]
        self.assertAlmostEqual(marker.v, 0.0, places=4)

    def test_no_frames_draws_corners_only(self):
        drawing = live_painter.paint_live(TelemetryBuffer())
        self.assertEqual(drawing.by_layer()["live"], [])
        self.assertGreaterEqual(len(drawing.by_layer()["static"]), 4)


if __name__ == "__main__":
    unittest.main()
