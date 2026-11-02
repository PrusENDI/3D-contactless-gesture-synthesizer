"""Assisted recording: arm at a known bar, gate on coverage, diagnose only after retries."""

import unittest

from host.v2_console import link
from host.v2_console.session import core, record_flow
from host.test_link_fakes import ScriptedPort, reply_frame

BOARD_ID = 0x5A5A0003


def build(plan):
    chunks = []
    for index, entry in enumerate(plan):
        data, err = entry if isinstance(entry, tuple) else (entry, 0)
        chunks.append(reply_frame(index + 1, data, err=err))
    return core.Session(link.Link(ScriptedPort(chunks=chunks), pacing_s=0.0, timeout_s=0.05))


def arm_session():
    # connect(2) + 0x08 + 0x0C + 0x18
    session = build([BOARD_ID, 0, 0, 0, 0])
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

    def test_arm_selects_the_track_then_prepares(self):
        session, _ = arm_session()
        writes = [frame[3] for frame in session.link._port.written if frame[2] == link.OP_WRITE]
        self.assertEqual(writes[1:3], [0x0C, 0x18])

    def test_armed_state_is_reported(self):
        _, flow = arm_session()
        self.assertEqual(flow.state, record_flow.ARMED)


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

    def test_commit_writes_then_reads_the_committed_count(self):
        session, flow = arm_session()
        flow.accept_take([100] * 32)
        session.link._port.chunks.extend(
            [reply_frame(6, 0), reply_frame(7, 0), reply_frame(8, 5 << 21)]
        )
        self.assertEqual(flow.commit(), 5)


class ContourTest(unittest.TestCase):
    def test_contour_read_zeroes_the_pointer_first(self):
        session, flow = arm_session()
        queued = [reply_frame(6, record_flow.FULL_BIT)]
        queued += [reply_frame(7, 0)]
        queued += [reply_frame(index + 8, index) for index in range(32)]
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
