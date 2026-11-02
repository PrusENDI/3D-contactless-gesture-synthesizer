"""Session identity, the mode gate and the evidence log.

The board is one serial port with one owner; a mode-dependent command that is
sent in the wrong mode is refused by the hardware in ways that are easy to
misread, so the gate here refuses it before a single byte goes out.
"""

import json
import tempfile
import unittest
from pathlib import Path

from host.v2_console import link
from host.v2_console.session import core, log
from host.test_link_fakes import ScriptedPort, reply_frame

BOARD_ID = 0x5A5A0003


def make_link(chunks):
    return link.Link(ScriptedPort(chunks=chunks), pacing_s=0.0, timeout_s=0.05)


def status_word(mode=0, loop_active=0, fault=0):
    return (fault << 9) | (loop_active << 8) | mode


class ConnectTest(unittest.TestCase):
    def test_wrong_bitstream_raises_before_any_write_command(self):
        session = core.Session(make_link([reply_frame(1, 0x00000000)]))
        with self.assertRaises(core.WrongBitstream):
            session.connect()
        self.assertTrue(all(frame[2] == link.OP_READ for frame in session.link._port.written))

    def test_connect_returns_identity_and_mode(self):
        session = core.Session(make_link([reply_frame(1, BOARD_ID), reply_frame(2, status_word(mode=4, loop_active=1))]))
        identity = session.connect()
        self.assertEqual(identity.board_id, BOARD_ID)
        self.assertEqual((identity.mode, identity.loop_active), (4, True))


class ModeGateTest(unittest.TestCase):
    def test_require_mode_rejects_without_writing(self):
        session = core.Session(
            make_link(
                [
                    reply_frame(1, BOARD_ID),
                    reply_frame(2, status_word(mode=4)),
                    reply_frame(3, status_word(mode=4)),
                ]
            )
        )
        session.connect()
        before = session.link._port.written_count()
        with self.assertRaises(core.WrongMode):
            session.require_mode(0)
        new_frames = session.link._port.written[before:]
        self.assertTrue(all(frame[2] == link.OP_READ for frame in new_frames))

    def test_set_mode_only_accepts_the_three_live_modes(self):
        session = core.Session(make_link([reply_frame(1, BOARD_ID), reply_frame(2, status_word()), reply_frame(3, 0)]))
        session.connect()
        for bad in (0, 2, 3, 5, 7):
            with self.assertRaises(ValueError):
                session.set_mode(bad)

    def test_stop_writes_one(self):
        session = core.Session(make_link([reply_frame(1, BOARD_ID), reply_frame(2, status_word()), reply_frame(3, 0)]))
        session.connect()
        session.stop()
        self.assertEqual(session.link._port.written[-1][3], 0x14)
        self.assertEqual(session.link._port.written[-1][5:9], b"\x00\x00\x00\x01")


class TelemetryTest(unittest.TestCase):
    def test_closing_telemetry_writes_zero_to_0x80(self):
        session = core.Session(make_link([reply_frame(1, BOARD_ID), reply_frame(2, status_word()), reply_frame(3, 0)]))
        session.connect()
        session.close_telemetry()
        last = session.link._port.written[-1]
        self.assertEqual((last[2], last[3]), (link.OP_WRITE, 0x80))
        self.assertEqual(last[5:9], b"\x00\x00\x00\x00")


class LogTest(unittest.TestCase):
    def test_every_command_leaves_one_jsonl_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "session.jsonl"
            session = core.Session(
                make_link([reply_frame(1, BOARD_ID), reply_frame(2, status_word()), reply_frame(3, 0x1234)]),
                log_path=path,
            )
            session.connect()
            session._cmd(link.OP_READ, 0x40)
            lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(len(lines), 3)
            self.assertEqual(set(lines[0]), {"t", "seq", "op", "addr", "data", "err", "nack"})
            self.assertEqual(lines[-1]["addr"], "0x40")
            self.assertEqual(lines[-1]["data"], "0x00001234")


class JsonlLogTest(unittest.TestCase):
    def test_none_path_is_silent(self):
        silent = log.JsonlLog(None)
        silent.append({"op": "READ"})


if __name__ == "__main__":
    unittest.main()
