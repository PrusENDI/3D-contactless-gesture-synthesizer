"""Session core: who owns the port, which mode is allowed, and what was recorded.

The board's mode is not readable from MODE (0x04 reads back 0); it lives in
STATUS[2:0]. Recording does not need MODE=2 either -- the RTL switches to RECORD
itself when 0x18 arms -- so this layer only offers the three user-visible modes.
"""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass
from pathlib import Path

from .. import link as linkmod
from ..link import Link, Reply
from .log import JsonlLog

BOARD_ID = 0x5A5A0003
LIVE, RECORD, COMMIT, PLAY, ERROR, WT_PLAY = 1, 2, 3, 4, 5, 6
MODE_NAMES = {0: "IDLE", 1: "LIVE", 2: "RECORD", 3: "COMMIT", 4: "PLAY", 5: "ERROR", 6: "WT_PLAY"}


class WrongBitstream(RuntimeError):
    """0xB0 is not 0x5A5A0003: the board is running some other bitstream."""


class WrongMode(RuntimeError):
    """The command needs a mode the board is not in. Nothing was sent."""


class UnsafeParameter(ValueError):
    """A parameter value the console refuses to send because it silences the board."""


@dataclass
class Identity:
    board_id: int
    mode: int
    loop_active: bool
    fault: int


@dataclass
class Status:
    mode: int
    loop_active: bool
    fault: int


def _addr(text: str) -> int:
    return int(text, 16)


class Session:
    """One serial owner. Every command goes through :meth:`_cmd`, which logs it."""

    def __init__(self, link: Link, log_path: Path | None = None):
        self.link = link
        self.log = JsonlLog(log_path)

    # -- transport wrapper --------------------------------------------------

    def _cmd(self, op: int, addr: int, data: int = 0) -> Reply:
        reply = self.link.command(op, addr, data)
        self.log.append(
            {
                "t": _dt.datetime.now().isoformat(timespec="milliseconds"),
                "seq": reply.seq,
                "op": "READ" if op == linkmod.OP_READ else "WRITE",
                "addr": "0x%02X" % addr,
                "data": "0x%08X" % (reply.data if op == linkmod.OP_READ else data),
                "err": reply.err,
                "nack": reply.nack,
            }
        )
        return reply

    def read(self, addr: int) -> int:
        return self._cmd(linkmod.OP_READ, addr).data

    def write(self, addr: int, data: int) -> Reply:
        return self._cmd(linkmod.OP_WRITE, addr, data)

    # -- identity and mode --------------------------------------------------

    def connect(self) -> Identity:
        board_id = self.read(0xB0)
        if board_id != BOARD_ID:
            raise WrongBitstream(
                "0xB0=0x%08X, expected 0x%08X: flash the current bitstream before using the console"
                % (board_id, BOARD_ID)
            )
        status = self.status()
        return Identity(board_id, status.mode, status.loop_active, status.fault)

    def status(self) -> Status:
        word = self.read(0x00)
        return Status(mode=word & 0x7, loop_active=bool((word >> 8) & 1), fault=(word >> 9) & 0x1FFF)

    def require_mode(self, *allowed: int) -> Status:
        status = self.status()
        if status.mode not in allowed:
            names = ", ".join(MODE_NAMES.get(mode, str(mode)) for mode in allowed)
            raise WrongMode(
                "board is in %s, this needs %s" % (MODE_NAMES.get(status.mode, status.mode), names)
            )
        return status

    def set_mode(self, mode: int) -> None:
        if mode not in (LIVE, PLAY, WT_PLAY):
            raise ValueError("the console only enters LIVE(1), PLAY(4) or WT_PLAY(6), not %r" % (mode,))
        self.write(0x04, mode)

    def stop(self) -> None:
        # STOP's data must be exactly 1; writing 0 is NACKed and the loop keeps playing.
        self.write(0x14, 1)

    def close_telemetry(self) -> None:
        # board_cursor.ps1 leaves the stream on, and then every later command
        # sees a 22-byte snapshot where it expected its reply.
        self.write(0x80, 0)
