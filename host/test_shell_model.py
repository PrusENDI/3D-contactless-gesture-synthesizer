"""The shell's model: what each tab draws and whether the config area is allowed to edit."""

import unittest

from host.v2_console.canvas import primitives
from host.v2_console.views.shell import ConsoleModel
from host.v2_console import frames
from host.v2_console.telemetry import TelemetryBuffer

BOARD_ID = 0x5A5A0003


class FakeSession:
    def __init__(self, mode=0):
        self.mode = mode
        self.writes = []

    def status(self):
        class Status:
            pass

        status = Status()
        status.mode = self.mode
        status.loop_active = False
        status.fault = 0
        return status


def frame(seq, x=32768, y=32768):
    return frames.Telemetry(seq=seq, x=x, y=y, z=3000, note=60, flags=0, tick=0, voices=0, fifo=0, fault=0)


class ModelTest(unittest.TestCase):
    def test_config_is_editable_only_in_idle(self):
        self.assertTrue(ConsoleModel(FakeSession(mode=0)).editable())
        self.assertFalse(ConsoleModel(FakeSession(mode=4)).editable())

    def test_live_tab_has_no_live_items_until_a_frame_arrives(self):
        model = ConsoleModel(FakeSession())
        self.assertEqual(model.drawing("live").by_layer()[primitives.LIVE], [])
        model.buffer.push(frame(1))
        self.assertTrue(model.drawing("live").by_layer()[primitives.LIVE])

    def test_wave_tab_draws_the_table_it_was_given(self):
        model = ConsoleModel(FakeSession())
        model.table = [0] * 1024
        paths = [p for p in model.drawing("wave").by_layer()[primitives.STATIC]
                 if isinstance(p, primitives.Path)]
        self.assertEqual(len(paths[0].points), 1024)

    def test_loop_tab_shows_the_contour_it_holds(self):
        model = ConsoleModel(FakeSession())
        model.contours[0] = [100] * 32
        paths = [p for p in model.drawing("loop").by_layer()[primitives.STATIC]
                 if isinstance(p, primitives.Path)]
        self.assertEqual(len(paths), 1)

    def test_status_line_names_the_mode(self):
        self.assertIn("PLAY", ConsoleModel(FakeSession(mode=4)).status_line())


if __name__ == "__main__":
    unittest.main()
