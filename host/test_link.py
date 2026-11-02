"""Frame construction and the CRC the board and the scripts already use."""

import unittest

from host.v2_console import link
from host.test_link_fakes import ScriptedPort, reply_frame


class FrameTest(unittest.TestCase):
    def test_crc_selftest_known_value(self):
        # Same check value scripts/board_wt_upload.ps1 asserts before uploading.
        self.assertEqual(link.crc16(b"123456789"), link.CRC_SELFTEST)

    def test_frame_is_eleven_bytes_with_big_endian_payload(self):
        frame = link.build_frame(0x02, 0x68, 0x1234, 7)
        self.assertEqual(len(frame), 11)
        self.assertEqual(frame[:5], bytes([0xA5, 0x02, 0x02, 0x68, 7]))
        self.assertEqual(frame[7:9], bytes([0x12, 0x34]))
        crc = link.crc16(frame[:9])
        self.assertEqual(frame[9:11], bytes([(crc >> 8) & 0xFF, crc & 0xFF]))


class LinkTest(unittest.TestCase):
    """The board answers one command at a time and replays its cache for duplicates."""

    def test_stale_reply_with_wrong_seq_is_discarded(self):
        port = ScriptedPort(chunks=[reply_frame(6, 0xDEAD), reply_frame(1, 0x1234)])
        link_ = link.Link(port, pacing_s=0.0, timeout_s=0.2)
        reply = link_.command(link.OP_READ, 0xB0)
        self.assertEqual((reply.seq, reply.data), (1, 0x1234))
        self.assertEqual(port.written_count(), 1)

    def test_missing_reply_is_resent_with_the_same_sequence(self):
        port = ScriptedPort(chunks=[reply_frame(1, 0x1234)], stall_until_write=2)
        link_ = link.Link(port, pacing_s=0.0, timeout_s=0.03)
        reply = link_.command(link.OP_READ, 0xB0)
        self.assertEqual(reply.data, 0x1234)
        self.assertEqual(port.written[0], port.written[1])

    def test_no_reply_raises_link_lost(self):
        link_ = link.Link(ScriptedPort(chunks=[]), pacing_s=0.0, timeout_s=0.02)
        with self.assertRaises(link.LinkLost):
            link_.command(link.OP_READ, 0xB0)

    def test_port_that_closes_midway_raises_link_lost(self):
        link_ = link.Link(ScriptedPort(chunks=[], die_on_write=2), pacing_s=0.0, timeout_s=0.02)
        with self.assertRaises(link.LinkLost):
            link_.command(link.OP_READ, 0xB0)

    def test_nack_is_returned_not_raised(self):
        port = ScriptedPort(chunks=[reply_frame(1, 0, err=0x07, nack=True)])
        reply = link.Link(port, pacing_s=0.0, timeout_s=0.2).command(link.OP_WRITE, 0x9C, 0xFFFF)
        self.assertTrue(reply.nack)
        self.assertEqual(reply.err, 0x07)

    def test_burst_keeps_order_and_returns_every_reply(self):
        port = ScriptedPort(chunks=[reply_frame(s, s * 0x100) for s in (1, 2, 3)])
        replies = link.Link(port, pacing_s=0.0, timeout_s=0.2).burst(
            [(link.OP_READ, 0x40, 0), (link.OP_READ, 0x44, 0), (link.OP_READ, 0x90, 0)]
        )
        self.assertEqual([r.seq for r in replies], [1, 2, 3])
        self.assertEqual([r.data for r in replies], [0x100, 0x200, 0x300])

    def test_burst_resent_commands_keep_their_original_seq(self):
        # The board replays its cached reply for a byte-identical duplicate, so a
        # resend must reuse the seq -- a fresh one would execute the write twice.
        port = ScriptedPort(
            chunks=[reply_frame(1, 0xAA), reply_frame(2, 0xBB)], stall_until_write=3
        )
        replies = link.Link(port, pacing_s=0.0, timeout_s=0.03).burst(
            [(link.OP_WRITE, 0x40, 1), (link.OP_WRITE, 0x44, 2)]
        )
        self.assertEqual([r.seq for r in replies], [1, 2])
        self.assertEqual(port.written[2], port.written[0])
        self.assertEqual(port.written[3], port.written[1])


    def test_burst_refuses_to_resend_behind_an_accepted_reply(self):
        # The board treats a duplicate as "same seq as the last frame, identical
        # bytes". Once a later command was accepted, resending an earlier one would
        # execute it a second time -- a WT_DATA write would land twice.
        port = ScriptedPort(chunks=[reply_frame(1, 0xAA), reply_frame(3, 0xCC)])
        with self.assertRaises(link.LinkLost):
            link.Link(port, pacing_s=0.0, timeout_s=0.03).burst(
                [(link.OP_WRITE, 0x68, 1), (link.OP_WRITE, 0x68, 2), (link.OP_WRITE, 0x68, 3)]
            )
        self.assertEqual(port.written_count(), 3)


if __name__ == "__main__":
    unittest.main()
