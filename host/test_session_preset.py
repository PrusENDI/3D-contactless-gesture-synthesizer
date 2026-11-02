"""Applying a preset: nine writes in ascending address order, each followed by a read-back."""

import unittest

from host.v2_console import link, params, presets
from host.v2_console.session import core
from host.test_link_fakes import ScriptedPort, reply_frame

BOARD_ID = 0x5A5A0003
WARM = presets.BOARD_TUNE_SEED["warm"]


def build(plan):
    chunks = []
    for index, entry in enumerate(plan):
        data, err = entry if isinstance(entry, tuple) else (entry, 0)
        chunks.append(reply_frame(index + 1, data, err=err))
    return core.Session(link.Link(ScriptedPort(chunks=chunks), pacing_s=0.0, timeout_s=0.05))


def preset_plan(words, readbacks=None, fail_at=None, fail_err=7):
    plan = [BOARD_ID, 0]
    for addr in params.PARAM_ADDRS:
        if addr == fail_at:
            plan.append((0, fail_err))
            break
        plan.append((0, 0))
        plan.append((readbacks or words)[addr])
    return plan


def warm_preset():
    return presets.Preset(name="warm", words=dict(WARM))


class ApplyTest(unittest.TestCase):
    def test_order_is_ascending_address(self):
        session = build(preset_plan(WARM))
        session.connect()
        session.apply_preset(warm_preset())
        writes = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertEqual(writes, list(params.PARAM_ADDRS))

    def test_every_word_is_read_back(self):
        session = build(preset_plan(WARM))
        session.connect()
        result = session.apply_preset(warm_preset())
        self.assertTrue(result.ok)
        self.assertEqual(result.readbacks, WARM)

    def test_nack_stops_at_that_word_and_reports_the_address(self):
        session = build(preset_plan(WARM, fail_at=0x94))
        session.connect()
        result = session.apply_preset(warm_preset())
        self.assertFalse(result.ok)
        self.assertEqual(result.failed_addr, 0x94)
        sent = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertNotIn(0x98, sent)
        self.assertNotIn(0x9C, sent)

    def test_clamped_word_is_reported_as_a_difference(self):
        readbacks = dict(WARM)
        readbacks[0x94] = 0x00400001          # attack written 0, board clamped it to 1
        session = build(preset_plan(WARM, readbacks=readbacks))
        session.connect()
        words = dict(WARM)
        words[0x94] = 0x00400000
        result = session.apply_preset(presets.Preset(name="x", words=words))
        self.assertTrue(result.ok)
        self.assertEqual(result.clamped[0x94], (0x00400000, 0x00400001))

    def test_fx_gain_zero_is_refused_before_writing_anything(self):
        session = build([BOARD_ID, 0])
        session.connect()
        before = session.link._port.written_count()
        broken = warm_preset()
        broken.words[0x84] = 0x000C0000        # enable + level, but gain 0 = silence in PLAY
        with self.assertRaises(core.UnsafeParameter):
            session.apply_preset(broken)
        self.assertEqual(session.link._port.written_count(), before)


if __name__ == "__main__":
    unittest.main()
