"""One serial stream carries both command replies and the 20 Hz telemetry snapshots."""

import unittest

from host.v2_console import frames, link


def reply_frame(seq: int, data: int = 0, err: int = 0, nack: bool = False) -> bytes:
    body = bytearray(20)
    body[0] = 0x5A
    body[1] = 0x02
    body[2] = 0x81 if nack else 0x80
    body[4] = seq & 0xFF
    body[14:18] = data.to_bytes(4, "big")
    body[19] = err
    crc = link.crc16(bytes(body))
    return bytes(body) + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


def telemetry_frame(seq: int, x: int, y: int, z: int) -> bytes:
    body = bytearray(20)
    body[0] = 0x5A
    body[1] = 0x02
    body[2] = 0x01
    body[3:5] = seq.to_bytes(2, "big")
    body[5:7] = x.to_bytes(2, "big")
    body[7:9] = y.to_bytes(2, "big")
    body[9:11] = z.to_bytes(2, "big")
    crc = link.crc16(bytes(body))
    return bytes(body) + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


def drain_replies(parser):
    out = []
    while True:
        reply = parser.next_reply()
        if reply is None:
            return out
        out.append(reply)


def drain_telemetry(parser):
    out = []
    while True:
        snapshot = parser.next_telemetry()
        if snapshot is None:
            return out
        out.append(snapshot)


class StreamParserTest(unittest.TestCase):
    def test_ack_and_telemetry_interleaved_are_separated(self):
        parser = frames.StreamParser()
        parser.feed(
            reply_frame(1, 0xAAAA)
            + telemetry_frame(9, 10, 20, 30)
            + telemetry_frame(10, 11, 21, 31)
            + reply_frame(2, 0xBBBB)
        )
        self.assertEqual([r.seq for r in drain_replies(parser)], [1, 2])
        self.assertEqual(len(drain_telemetry(parser)), 2)
        self.assertEqual(parser.dropped_bytes(), 0)

    def test_partial_frame_is_kept_until_complete(self):
        parser = frames.StreamParser()
        whole = reply_frame(5, 0x1234)
        parser.feed(whole[:13])
        self.assertIsNone(parser.next_reply())
        parser.feed(whole[13:])
        reply = parser.next_reply()
        self.assertEqual((reply.seq, reply.data), (5, 0x1234))

    def test_bad_crc_reply_is_dropped_not_returned(self):
        corrupted = reply_frame(6, 0x4321)[:19] + b"\x00\x00"
        self.assertIsNone(frames.parse_one(corrupted))

    def test_0x5a_inside_payload_does_not_start_a_frame(self):
        parser = frames.StreamParser()
        parser.feed(reply_frame(7, 0x5A5A5A5A) + reply_frame(8, 0x0001))
        self.assertEqual([r.seq for r in drain_replies(parser)], [7, 8])


if __name__ == "__main__":
    unittest.main()
