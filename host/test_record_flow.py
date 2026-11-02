"""Assisted recording: arm at a known bar, gate on coverage, wait for the DP, publish."""

import unittest

from host.v2_console import link
from host.v2_console.session import core, record_flow
from host.test_link_fakes import ScriptedPort, reply_frame

BOARD_ID = 0x5A5A0003
STATUS_IDLE = 0


def build(plan):
    chunks = []
    for index, entry in enumerate(plan):
        data, err = entry if isinstance(entry, tuple) else (entry, 0)
        chunks.append(reply_frame(index + 1, data, err=err))
    return core.Session(link.Link(ScriptedPort(chunks=chunks), pacing_s=0.0, timeout_s=0.05))


def feed(session, values):
    """Queue replies for the commands that follow, numbered from the link's next seq."""
    start = session.link._seq + 1
    for offset, entry in enumerate(values):
        data, err = entry if isinstance(entry, tuple) else (entry, 0)
        session.link._port.chunks.append(reply_frame(start + offset, data, err=err))


def arm_session(mode=0):
    # connect(2) + 0x08 write + 0x08 read-back + 0x0C write + 0x18 write
    session = build([BOARD_ID, mode, 0, 120, 0, 0])
    session.connect()
    flow = record_flow.RecordFlow(session, track=1)
    flow.arm()
    return session, flow


class ArmTest(unittest.TestCase):
    def test_arm_forces_bpm_120_before_anything_else(self):
        session, _ = arm_session()
        writes = [frame for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertEqual(writes[0][3], 0x08)
        self.assertEqual(int.from_bytes(writes[0][5:9], "big"), 120)

    def test_arm_reads_the_bpm_back(self):
        session, _ = arm_session()
        reads = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_READ]
        self.assertEqual(reads[-1], 0x08)

    def test_arm_selects_the_track_then_prepares(self):
        session, _ = arm_session()
        writes = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertEqual(writes[1:3], [0x0C, 0x18])

    def test_arm_refuses_a_track_outside_the_contract(self):
        session = build([BOARD_ID, 0, 0, 0, 0, 120])
        session.connect()
        before = session.link._port.written_count()
        with self.assertRaises(record_flow.FlowError):
            record_flow.RecordFlow(session, track=6).arm()
        self.assertEqual(session.link._port.written_count(), before)

    def test_arm_refuses_when_the_bpm_does_not_read_back(self):
        session = build([BOARD_ID, 0, 0, 0, 0, 0x3C])   # 60 BPM came back
        session.connect()
        flow = record_flow.RecordFlow(session, track=0)
        with self.assertRaises(record_flow.FlowError):
            flow.arm()


class CoverageTest(unittest.TestCase):
    def test_coverage_counts_non_zero_ticks(self):
        self.assertEqual(record_flow.coverage([0] * 30 + [1, 2]), 2)

    def test_below_threshold_retries_twice_then_diagnoses(self):
        session, flow = arm_session()
        session.link._port.chunks.extend(
            reply_frame(6 + index, value)
            for index, value in enumerate([0, 0, 0x1234, 0x2345, 0])
        )
        results = [flow.accept_take([100] * 29 + [0, 0, 0]) for _ in range(3)]
        self.assertEqual(results, ["retry", "retry", "diagnose"])
        diagnostic = [frame[3] for frame in session.link._port.written[-4:]]
        self.assertEqual(diagnostic, [0xEC, 0xEC, 0xDC, 0xE0])

    def test_covered_take_is_ready_to_commit(self):
        _, flow = arm_session()
        self.assertEqual(flow.accept_take([100] * 32), "ok")
        self.assertEqual(flow.state, record_flow.REVIEWED)


class CommitTest(unittest.TestCase):
    def test_commit_before_a_take_is_refused_without_sending(self):
        session, flow = arm_session()
        before = session.link._port.written_count()
        with self.assertRaises(record_flow.FlowError):
            flow.commit()
        self.assertEqual(session.link._port.written_count(), before)

    def test_commit_waits_for_done_before_reading_the_count(self):
        session, flow = arm_session()
        flow.accept_take([100] * 32)
        # 0x28 write, two not-done polls, one done, 0x34=1, then the count
        feed(session, [0, 0, 0, 1, 0, 5 << 21])
        self.assertEqual(flow.commit(timeout_s=1.0), 5)
        polls = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_READ]
        self.assertGreaterEqual(polls.count(0x38), 3)

    def test_publish_enters_play_and_waits_for_the_boundary(self):
        session, flow = arm_session()
        flow.accept_take([100] * 32)
        feed(session, [0, 1, 0, 5 << 21])
        flow.commit(timeout_s=1.0)
        feed(session, [0, 1 << 6, 0])
        flow.publish(timeout_s=1.0)
        self.assertEqual(flow.state, record_flow.ROLLED)
        writes = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertIn(0x04, writes)

    def test_a_still_frame_counter_and_zero_z_is_not_engaged(self):
        # 0xE0 is cursor_last_z; with no valid cursor it stays 0, which the naive
        # "z < 30000 means engaged" rule reads as a hand on the pad.
        session, flow = arm_session()
        feed(session, [5, 5, 0x100, 0])
        diagnostic = flow.diagnose()
        self.assertFalse(diagnostic["sensor_alive"])
        self.assertFalse(diagnostic["engaged"])


class ContourTest(unittest.TestCase):
    def test_contour_read_zeroes_the_pointer_first(self):
        session, flow = arm_session()
        queued = [reply_frame(7, record_flow.FULL_BIT)]
        queued += [reply_frame(8, 0)]
        queued += [reply_frame(index + 9, index) for index in range(32)]
        session.link._port.chunks.extendleft(reversed(queued))
        flow.poll()
        self.assertEqual(flow.state, record_flow.CAPTURED)
        contour = flow.contour()
        self.assertEqual(len(contour), 32)
        self.assertEqual(contour[:3], [0, 1, 2])
        writes = [frame for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertEqual((writes[-1][3], int.from_bytes(writes[-1][5:9], "big")), (0x34, 0))


if __name__ == "__main__":
    unittest.main()
