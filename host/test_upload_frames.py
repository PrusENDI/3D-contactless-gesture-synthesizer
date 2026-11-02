"""Uploading the three morph frames: only what changed, with progress, then one SELECT."""

import unittest

from host.v2_console import link
from host.v2_console.session import core
from host.v2_console.wavetable import bar_step, select_word
from host.test_link_fakes import ScriptedPort, reply_frame

BOARD_ID = 0x5A5A0003
FRAME = [((i * 7919) % 4000) - 2000 for i in range(1024)]
OTHER = [((i * 104729) % 3000) - 1500 for i in range(1024)]


def build(plan):
    chunks = []
    for index, entry in enumerate(plan):
        data, err = entry if isinstance(entry, tuple) else (entry, 0)
        chunks.append(reply_frame(index + 1, data, err=err))
    return core.Session(link.Link(ScriptedPort(chunks=chunks), pacing_s=0.0, timeout_s=0.05))


def upload_plan(tables=3, active_version=2):
    """connect + per table: MODE, SELECT, INDEX, 1024 data, LENGTH, CRC, STATUS, VERSION, APPLY, SELECT."""
    plan = [BOARD_ID, 0]
    for _ in range(tables):
        plan += [0, 0, 0]
        plan += [0] * 1024
        plan += [0, 0, active_version, 0, 0, 0]
    plan += [0]                      # the final WT_SELECT
    return plan


class UploadFramesTest(unittest.TestCase):
    def test_three_frames_are_uploaded_and_the_morph_word_is_written_last(self):
        session = build(upload_plan(tables=3))
        session.connect()
        progress = []
        result = session.upload_frames(
            {0: FRAME, 1: OTHER, 2: FRAME},
            shift=2,
            morph=True,
            period_s=20.0,
            on_progress=lambda table, done, total: progress.append((table, done, total)),
        )
        self.assertTrue(result.ok)
        self.assertEqual(result.uploaded, (0, 1, 2))
        select_writes = [f for f in session.link._port.written if f[3] == 0x60]
        self.assertEqual(int.from_bytes(select_writes[-1][5:9], "big"),
                         select_word(0, 2, True, bar_step(20.0)))
        self.assertEqual(len(progress), 3 * 1024)

    def test_an_unchanged_frame_is_not_uploaded_again(self):
        session = build(upload_plan(tables=1) + [0] * 0)
        session.connect()
        result = session.upload_frames(
            {0: FRAME, 1: OTHER},
            shift=2,
            morph=True,
            period_s=20.0,
            uploaded={0: list(FRAME)},
        )
        self.assertEqual(result.uploaded, (1,))
        addresses = [f[3] for f in session.link._port.written if f[2] == 0x02]
        self.assertEqual(addresses.count(0x78), 1)          # exactly one APPLY

    def test_nothing_changed_still_writes_the_select_word(self):
        session = build([BOARD_ID, 0, 0])
        session.connect()
        result = session.upload_frames(
            {0: FRAME}, shift=3, morph=False, period_s=4.0, uploaded={0: list(FRAME)}
        )
        self.assertEqual(result.uploaded, ())
        last = session.link._port.written[-1]
        self.assertEqual(last[3], 0x60)
        self.assertEqual(int.from_bytes(last[5:9], "big"), select_word(0, 3, False, bar_step(4.0)))

    def test_a_refused_frame_stops_the_upload_and_reports_the_table(self):
        plan = upload_plan(tables=2)
        plan[5 + 500] = (0, 7)           # the 500th sample of the first frame is refused
        session = build(plan)
        session.connect()
        with self.assertRaises(core.UploadRefused):
            session.upload_frames({0: FRAME, 1: OTHER}, shift=2, morph=True, period_s=20.0)


if __name__ == "__main__":
    unittest.main()
