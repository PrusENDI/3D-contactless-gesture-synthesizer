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

    def upload_table(self, samples, table=0, voice_shift=2, morph=False, verify=False, on_sample=None):
        self.uploads += 1
        self.on_sample = on_sample
        return SimpleNamespace(ok=True, active_version=1, crc=0, attempts=1, elapsed_s=0.0, readback=None)

    def upload_frames(self, frames, shift=2, morph=True, period_s=20.0, uploaded=None, on_progress=None):
        self.uploaded_this_call = (dict(frames),)
        changed = tuple(t for t in sorted(frames) if frames[t] != (uploaded or {}).get(t))
        return SimpleNamespace(ok=True, uploaded=changed, select=0, elapsed_s=0.0)


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


class FrameTest(unittest.TestCase):
    def test_capture_fills_the_next_free_slot_in_order(self):
        import math

        model = ConsoleModel(FakeSession())
        points = [
            (int(32768 + 20000 * math.cos(2 * math.pi * i / 200)),
             int(32768 + 20000 * math.sin(2 * math.pi * i / 200)))
            for i in range(200)
        ]
        model.capture_frame(points)
        model.capture_frame(points)
        self.assertEqual(sorted(model.frames), [0, 1])
        self.assertEqual(len(model.frames[0]), 1024)

    def test_capture_needs_a_long_enough_trajectory(self):
        with self.assertRaises(ValueError):
            ConsoleModel(FakeSession()).capture_frame([(0, 0)] * 5)

    def test_upload_sends_only_the_changed_frames(self):
        session = FakeSession()
        model = ConsoleModel(session)
        model.frames = {0: [1] * 1024, 1: [2] * 1024}
        model.uploaded_frames = {0: [1] * 1024}
        model.upload_frames(shift=2, morph=True, period_s=20.0)
        self.assertEqual(session.uploaded_this_call, ({0: [1] * 1024, 1: [2] * 1024},))

    def test_upload_refuses_with_no_frames(self):
        with self.assertRaises(RuntimeError):
            ConsoleModel(FakeSession()).upload_frames(shift=2, morph=True, period_s=20.0)


class UploadProgressTest(unittest.TestCase):
    """上传 .bin… ran 18 s with a motionless bar: no on_sample was passed."""

    def test_the_bin_upload_forwards_a_progress_callback(self):
        session = FakeSession()
        ConsoleModel(session).upload([0] * 1024, on_progress=lambda done, total: None)
        self.assertIsNotNone(session.on_sample)

    def test_a_file_that_is_not_one_table_is_refused_before_uploading(self):
        session = FakeSession()
        with self.assertRaises(RuntimeError) as caught:
            ConsoleModel(session).upload([0] * 512)
        self.assertIn("1024", str(caught.exception))
        self.assertEqual(session.uploads, 0)


class FrameSlotTest(unittest.TestCase):
    """A full A/B/C used to be a dead end: no slot to record into, no way to clear."""

    TRAJECTORY = [(1000 + 12 * i, 2000 + 9 * i) for i in range(64)]

    def full(self):
        model = ConsoleModel(FakeSession())
        model.frames = {0: [1] * 1024, 1: [2] * 1024, 2: [3] * 1024}
        return model

    def test_a_named_slot_is_overwritten(self):
        model = self.full()
        model.capture_frame(self.TRAJECTORY, index=1)
        self.assertEqual(model.displayed_frame, 1)
        self.assertNotEqual(model.frames[1], [2] * 1024)
        self.assertEqual(model.frames[0], [1] * 1024)

    def test_clearing_makes_room_for_three_new_frames(self):
        model = self.full()
        model.uploaded_frames = dict(model.frames)
        model.clear_frames()
        self.assertEqual(model.frames, {})
        self.assertEqual(model.uploaded_frames, {})
        self.assertEqual(model._next_frame_slot(), 0)

    def test_without_a_slot_a_fourth_frame_is_refused(self):
        model = self.full()
        with self.assertRaises(RuntimeError):
            model.capture_frame(self.TRAJECTORY)


if __name__ == "__main__":
    unittest.main()
