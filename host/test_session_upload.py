"""Wavetable upload and read-back: the version dance, the MSB-first CRC, the IDLE rule."""

import unittest

from host.v2_console import crc, link
from host.v2_console.session import core
from host.test_link_fakes import ScriptedPort, reply_frame

BOARD_ID = 0x5A5A0003
SAMPLES = [0x0100 * i % 0x10000 for i in range(1024)]


def make_session(plan):
    """``plan`` holds one entry per reply: an int is the data word, a tuple adds err."""
    chunks = []
    for index, entry in enumerate(plan):
        data, err = entry if isinstance(entry, tuple) else (entry, 0)
        chunks.append(reply_frame(index + 1, data, err=err))
    return core.Session(link.Link(ScriptedPort(chunks=chunks), pacing_s=0.0, timeout_s=0.05))


def upload_plan(active_version=3, apply_err=0):
    """Replies in command order: connect, MODE, SELECT, INDEX, 1024 data, LENGTH, CRC,
    STATUS, VERSION, APPLY, SELECT-restore."""
    plan = [BOARD_ID, 0]
    plan += [0, 0, 0]
    plan += [0] * 1024
    plan += [0, 0, active_version, 0]
    plan += [(0, apply_err) if apply_err else 0]
    plan += [0]
    return plan


def frames_after_connect(session):
    return session.link._port.written[2:]


class UploadTest(unittest.TestCase):
    def test_upload_forces_idle_then_restores_wt_select_with_the_shift(self):
        session = make_session(upload_plan(active_version=3))
        session.connect()
        session.upload_table(SAMPLES, table=0, voice_shift=2)
        frames = frames_after_connect(session)
        self.assertEqual((frames[0][3], frames[0][5:9]), (0x04, b"\x00\x00\x00\x00"))
        self.assertEqual((frames[1][3], frames[1][5:9]), (0x60, b"\x00\x00\x00\x00"))
        self.assertEqual((frames[2][3], frames[2][5:9]), (0x64, b"\x00\x00\x00\x00"))
        self.assertEqual(frames[-1][3], 0x60)         # restore, with the voice shift
        self.assertEqual(int.from_bytes(frames[-1][5:9], "big"), 0x20)

    def test_length_is_written_after_the_samples(self):
        session = make_session(upload_plan())
        session.connect()
        session.upload_table(SAMPLES, table=0, voice_shift=2)
        addresses = [frame[3] for frame in frames_after_connect(session) if frame[2] == 0x02]
        self.assertLess(addresses.index(0x68), addresses.index(0x6C))
        self.assertEqual(addresses[addresses.index(0x6C) + 1], 0x70)

    def test_apply_word_adopts_the_active_version(self):
        session = make_session(upload_plan(active_version=3))
        session.connect()
        session.upload_table(SAMPLES, table=0, voice_shift=2)
        apply_frames = [f for f in frames_after_connect(session) if f[3] == 0x78]
        self.assertEqual(len(apply_frames), 1)
        self.assertEqual(int.from_bytes(apply_frames[0][5:9], "big"), 0x80000003)

    def test_crc_is_msb_first_over_the_sample_bytes(self):
        big_endian = b"".join(sample.to_bytes(2, "big") for sample in SAMPLES)
        self.assertEqual(core.table_crc(SAMPLES), crc.crc16(big_endian))
        session = make_session(upload_plan())
        session.connect()
        result = session.upload_table(SAMPLES, table=0, voice_shift=2)
        self.assertEqual(result.crc, crc.crc16(big_endian))

    def test_upload_aborts_when_a_sample_is_refused(self):
        plan = upload_plan()
        plan[5 + 100] = (0, 7)               # the 100th WT_DATA write comes back err=7
        session = make_session(plan)
        session.connect()
        with self.assertRaises(core.UploadRefused) as caught:
            session.upload_table(SAMPLES, table=0, voice_shift=2)
        self.assertEqual(caught.exception.addr, 0x68)
        self.assertEqual(caught.exception.index, 100)

    def test_apply_refused_then_accepted_is_retried(self):
        plan = upload_plan(apply_err=7)
        plan.insert(-1, (0, 0))              # the retry is answered with err=0
        session = make_session(plan)
        session.connect()
        result = session.upload_table(SAMPLES, table=0, voice_shift=2)
        self.assertTrue(result.ok)
        self.assertEqual(result.attempts, 2)

    def test_upload_can_verify_the_table_it_just_wrote(self):
        plan = upload_plan()
        plan += [0]                          # STATUS read for the read-back gate
        plan += [0]                          # WT_INDEX write
        plan += [sample & 0xFFFF for sample in SAMPLES]
        session = make_session(plan)
        session.connect()
        result = session.upload_table(SAMPLES, table=0, voice_shift=2, verify=True)
        self.assertTrue(result.ok)
        self.assertEqual(result.readback, [core.Session._signed(s) for s in SAMPLES])


class ReadBackTest(unittest.TestCase):
    def test_read_table_returns_1024_samples(self):
        plan = [BOARD_ID, 0, 0] + [0] + [0x1111] * 1024
        session = make_session(plan)
        session.connect()
        samples = session.read_table()
        self.assertEqual(samples, [0x1111] * 1024)

    def test_read_table_returns_signed_samples(self):
        plan = [BOARD_ID, 0, 0] + [0] + [0xFFFF] * 1024
        session = make_session(plan)
        session.connect()
        self.assertEqual(session.read_table()[0], -1)

    def test_read_table_refuses_in_play_without_sending_anything(self):
        plan = [BOARD_ID, 4, 4]          # STATUS says PLAY, on connect and on the gate
        session = make_session(plan)
        session.connect()
        before = session.link._port.written_count()
        with self.assertRaises(core.WrongMode):
            session.read_table()
        self.assertTrue(all(frame[2] == 0x01 for frame in session.link._port.written[before:]))


if __name__ == "__main__":
    unittest.main()
