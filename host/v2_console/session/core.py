"""Session core: who owns the port, which mode is allowed, and what was recorded.

The board's mode is not readable from MODE (0x04 reads back 0); it lives in
STATUS[2:0]. Recording does not need MODE=2 either -- the RTL switches to RECORD
itself when 0x18 arms -- so this layer only offers the three user-visible modes.
"""

from __future__ import annotations

import datetime as _dt
import time as _time
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from .. import link as linkmod
from ..crc import crc16
from ..link import Link, Reply
from ..params import PARAM_ADDRS
from .log import JsonlLog

BOARD_ID = 0x5A5A0003
LIVE, RECORD, COMMIT, PLAY, ERROR, WT_PLAY = 1, 2, 3, 4, 5, 6
MODE_NAMES = {0: "IDLE", 1: "LIVE", 2: "RECORD", 3: "COMMIT", 4: "PLAY", 5: "ERROR", 6: "WT_PLAY"}

WT_SELECT = 0x60
WT_INDEX = 0x64
WT_DATA = 0x68
WT_LENGTH = 0x6C
WT_CRC = 0x70
WT_VERSION = 0x74
WT_APPLY = 0x78
WT_STATUS = 0x7C

APPLY_COMMIT = 0x80000000
APPLY_RETRIES = 4


def table_crc(samples: Sequence[int]) -> int:
    """CRC over MSB-first sample bytes; hashing the little-endian file is rejected."""
    return crc16(b"".join((sample & 0xFFFF).to_bytes(2, "big") for sample in samples))


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


@dataclass
class UploadResult:
    ok: bool
    active_version: int
    crc: int
    attempts: int
    elapsed_s: float


@dataclass
class ApplyResult:
    ok: bool
    failed_addr: int | None
    readbacks: dict
    clamped: dict


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

    # -- wavetable ----------------------------------------------------------

    def upload_table(
        self,
        samples: Sequence[int],
        table: int = 0,
        voice_shift: int = 2,
        morph: bool = False,
    ) -> UploadResult:
        """Upload one 1024-point table. Forces IDLE first, exactly like the script.

        Writing a table while one plays is NACKed, so the script drops to IDLE
        before the first byte; the caller re-enters its mode afterwards. The
        APPLY version must equal the active version read from WT_STATUS, or the
        three-way version match fails and the table is refused.
        """
        started = _time.monotonic()
        self.write(0x04, 0)
        self.write(WT_SELECT, table & 0x3)
        self.write(WT_LENGTH, len(samples))
        self.write(WT_INDEX, 0)
        for sample in samples:
            self.write(WT_DATA, sample & 0xFFFF)
        value = table_crc(samples)
        self.write(WT_CRC, value)
        active_version = self.read(WT_STATUS) & 0xFFFF
        self.write(WT_VERSION, active_version)

        attempts = 0
        ok = False
        for attempt in range(1, APPLY_RETRIES + 1):
            reply = self.write(WT_APPLY, APPLY_COMMIT | active_version)
            attempts = attempt
            # The script retries on a non-zero err byte, not on the ACK/NACK bit:
            # APPLY answers err=7 while the loader is still preparing, and a real
            # rejection (CRC/version) comes back the same way on every attempt.
            if not reply.nack and reply.err == 0:
                ok = True
                break
        if ok:
            select = ((1 if morph else 0) << 8) | ((voice_shift & 0xF) << 4) | (table & 0x3)
            self.write(WT_SELECT, select)
        return UploadResult(
            ok=ok,
            active_version=active_version,
            crc=value,
            attempts=attempts,
            elapsed_s=_time.monotonic() - started,
        )

    def read_table(self) -> list[int]:
        """Read the 1024 samples back. Only in IDLE: in PLAY the port returns 0."""
        self.require_mode(0)
        self.write(WT_INDEX, 0)
        return [self.read(WT_DATA) & 0xFFFF for _ in range(1024)]

    # -- presets ------------------------------------------------------------

    def apply_preset(self, preset) -> ApplyResult:
        """Write the nine words in ascending order, reading each one back.

        Nothing is atomic on the board, so the order is the verified one from
        board_tune.ps1 and a refusal stops the sequence where it happened: a
        half-applied preset is easier to reason about than a silent full one.
        """
        words = dict(preset.words)
        if 0x84 in words and (words[0x84] & 0x3FFFF) == 0:
            raise UnsafeParameter(
                "FX_A gain is 0: that silences PLAY and the preset would look applied"
            )
        readbacks: dict[int, int] = {}
        clamped: dict[int, tuple[int, int]] = {}
        for addr in PARAM_ADDRS:
            word = words[addr]
            reply = self.write(addr, word)
            if reply.nack or reply.err:
                return ApplyResult(False, addr, readbacks, clamped)
            back = self.read(addr)
            readbacks[addr] = back
            if back != word:
                clamped[addr] = (word, back)
        return ApplyResult(True, None, readbacks, clamped)

    def capture_preset(self, name: str, notes: str = "", bitstream: dict | None = None) -> "object":
        """Read the nine words from the board into a new preset."""
        from ..presets import Preset

        words = {addr: self.read(addr) for addr in PARAM_ADDRS}
        select = self.read(WT_SELECT)
        status = self.read(WT_STATUS)
        wavetable = {
            "table": select & 0x3,
            "version": status & 0xFFFF,
            "crc": self.read(WT_CRC) & 0xFFFF,
            "voice_shift": (select >> 4) & 0xF,
            "morph": bool((select >> 8) & 1),
        }
        return Preset(
            name=name,
            notes=notes,
            created=_dt.date.today().isoformat(),
            bitstream=dict(bitstream or {}),
            wavetable=wavetable,
            words=words,
        )
