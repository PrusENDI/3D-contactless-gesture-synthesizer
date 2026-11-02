"""The shell's model: what each tab draws, what is allowed, and what the buttons do."""

import unittest
from types import SimpleNamespace

from host.v2_console import frames, presets
from host.v2_console.canvas import primitives
from host.v2_console.views.shell import ConsoleModel

WARM = presets.BOARD_TUNE_SEED["warm"]


class FakeSession:
    def __init__(self, mode=0):
        self.mode = mode
        self.status_calls = 0
        self.stops = 0
        self.uploads = 0

    def status(self):
        self.status_calls += 1
        return SimpleNamespace(mode=self.mode, loop_active=False, fault=0)

    def stop(self):
        self.stops += 1

    def apply_preset(self, preset):
        return SimpleNamespace(ok=True, failed_addr=None, clamped={})

    def read_table(self):
        return [0] * 1024

    def upload_table(self, samples, table=0, voice_shift=2, morph=False, verify=False):
        self.uploads += 1
        return SimpleNamespace(ok=True, active_version=1, crc=0, attempts=1, elapsed_s=0.0, readback=None)


def frame(seq, x=32768, y=32768):
    return frames.Telemetry(seq=seq, x=x, y=y, z=3000, note=60, flags=0, tick=0, voices=0, fifo=0, fault=0)


class PermissionTest(unittest.TestCase):
    def test_params_stay_editable_in_play_but_the_table_does_not(self):
        # Design 14.2: the nine parameters are writable in PLAY ("tune while it
        # plays"); only upload and read-back need IDLE.
        play = ConsoleModel(FakeSession(mode=4))
        self.assertTrue(play.can_edit_params())
        self.assertFalse(play.can_write_table())
        idle = ConsoleModel(FakeSession(mode=0))
        self.assertTrue(idle.can_write_table())


class DrawingTest(unittest.TestCase):
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

    def test_tone_tab_reports_the_preset_instead_of_drawing_the_cursor(self):
        model = ConsoleModel(FakeSession())
        model.preset_name = "warm"
        texts = [item.text for item in model.drawing("tone").primitives
                 if isinstance(item, primitives.Text)]
        self.assertTrue(any("warm" in text for text in texts))


class StatusTest(unittest.TestCase):
    def test_status_is_cached_so_the_window_does_not_command_every_frame(self):
        session = FakeSession()
        model = ConsoleModel(session)
        first = model.cached_status()
        model.cached_status()
        self.assertEqual(session.status_calls, 1)
        self.assertEqual(first.mode, 0)

    def test_status_line_names_the_mode(self):
        self.assertIn("PLAY", ConsoleModel(FakeSession(mode=4)).status_line())


class ActionTest(unittest.TestCase):
    def test_stop_reaches_the_session(self):
        session = FakeSession()
        ConsoleModel(session).stop()
        self.assertEqual(session.stops, 1)

    def test_apply_preset_reports_the_name(self):
        session = FakeSession()
        message = ConsoleModel(session).apply_preset(presets.Preset(name="warm", words=dict(WARM)))
        self.assertIn("warm", message)

    def test_upload_is_refused_in_play_before_touching_the_board(self):
        session = FakeSession(mode=4)
        with self.assertRaises(RuntimeError):
            ConsoleModel(session).upload([0] * 1024, table=0, voice_shift=2)
        self.assertEqual(session.uploads, 0)

    def test_readback_returns_a_message_with_the_sample_count(self):
        message = ConsoleModel(FakeSession()).readback()
        self.assertIn("1024", message)


if __name__ == "__main__":
    unittest.main()
