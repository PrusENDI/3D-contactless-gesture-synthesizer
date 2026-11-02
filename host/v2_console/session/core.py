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


class UploadRefused(RuntimeError):
    """The loader refused a sample or the CRC; the table is left incomplete."""

    def __init__(self, addr: int, index: int | None, reply):
        self.addr = addr
        self.index = index
        self.reply = reply
        where = "" if index is None else " at sample %d" % index
        super().__init__("0x%02X refused%s (err=0x%02X)" % (addr, where, reply.err))


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
    readback: list | None = None


@dataclass
class ApplyResult:
    ok: bool
    failed_addr: int | None
    readbacks: dict
    clamped: dict


@dataclass
class FramesUploadResult:
    ok: bool
    uploaded: tuple
    select: int
    elapsed_s: float


def _addr(text: str) -> int:
    return int(text, 16)


class Session:
    """One serial owner. Every command goes through :meth:`_cmd`, which logs it."""

    def __init__(self, link: Link, log_path: Path | None = None):
        self.link = link
        self.log = JsonlLog(log_path)
        self.identity: Identity | None = None

    # -- transport wrapper --------------------------------------------------

    def _cmd(self, op: int, addr: int, data: int = 0, attempts: int | None = None) -> Reply:
        try:
            reply = self.link.command(op, addr, data, attempts=attempts)
        except Exception as exc:
            # A lost command is evidence too: a log with only successes cannot
            # explain why a take or an upload ended early.
            self.log.append(
                {
                    "t": _dt.datetime.now().isoformat(timespec="milliseconds"),
                    "op": "READ" if op == linkmod.OP_READ else "WRITE",
                    "addr": "0x%02X" % addr,
                    "data": "0x%08X" % data,
                    "error": str(exc),
                }
            )
            raise
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

    def read(self, addr: int, attempts: int | None = None) -> int:
        return self._cmd(linkmod.OP_READ, addr, attempts=attempts).data

    def write(self, addr: int, data: int, attempts: int | None = None) -> Reply:
        return self._cmd(linkmod.OP_WRITE, addr, data, attempts=attempts)

    # -- identity and mode --------------------------------------------------

    def connect(self) -> Identity:
        board_id = self.read(0xB0)
        if board_id != BOARD_ID:
            raise WrongBitstream(
                "0xB0=0x%08X, expected 0x%08X: flash the current bitstream before using the console"
                % (board_id, BOARD_ID)
            )
        status = self.status()
        self.identity = Identity(board_id, status.mode, status.loop_active, status.fault)
        return self.identity

    def status(self, attempts: int | None = None) -> Status:
        word = self.read(0x00, attempts=attempts)
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

    def readouts(self, attempts: int | None = None) -> dict:
        """One screenful of state: the note the hand is on, and the voice engine's load.

        Reading these costs four commands, so the window caches the result instead of
        asking per redraw. The probe page write is the contour pointer as well, which
        is why this must not run while a contour is being read.
        """
        live = self.read(0xE8, attempts=attempts)
        self.write(0x34, 2, attempts=attempts)
        page2 = self.read(0xF8, attempts=attempts)
        return {
            "note": live & 0xFF,
            "gate": bool((live >> 8) & 1),
            "active": bool((live >> 9) & 1),
            "z": self.read(0xE0, attempts=attempts),
            "voices": (page2 >> 17) & 0x3F,
            "steals": page2 & 0xFFFF,
            "overflow": (page2 >> 16) & 1,
        }

    # -- wavetable ----------------------------------------------------------

    def upload_table(
        self,
        samples: Sequence[int],
        table: int = 0,
        voice_shift: int = 2,
        morph: bool = False,
        verify: bool = False,
        on_sample=None,
    ) -> UploadResult:
        """Upload one 1024-point table, following board_wt_upload.ps1 step for step.

        Writing a table while one plays is NACKed, so the script drops to IDLE and
        waits 150 ms before the first byte; every sample's reply is checked because
        the loader NACKs (err=7) while it is not ready, and silently continuing
        leaves a table with holes that still passes APPLY.
        """
        started = _time.monotonic()
        self.write(0x04, 0)
        # board_wt_upload.ps1:96 sleeps 150 ms here for the loader to release the
        # read port. Without it the first WT_DATA can come back refused.
        _time.sleep(0.15)
        self.write(WT_SELECT, table & 0x3)
        self.write(WT_INDEX, 0)
        for index, sample in enumerate(samples):
            reply = self.write(WT_DATA, sample & 0xFFFF)
            if reply.nack or reply.err:
                raise UploadRefused(WT_DATA, index, reply)
            if on_sample is not None:
                on_sample(index, len(samples))
        # The script writes the length after the samples, not before.
        self.write(WT_LENGTH, len(samples))
        value = table_crc(samples)
        reply = self.write(WT_CRC, value)
        if reply.nack or reply.err:
            raise UploadRefused(WT_CRC, None, reply)
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
        readback = self.read_table() if (verify and ok) else None
        return UploadResult(
            ok=ok,
            active_version=active_version,
            crc=value,
            attempts=attempts,
            elapsed_s=_time.monotonic() - started,
            readback=readback,
        )

    def read_table(self, points: int = 1024) -> list[int]:
        """Read ``points`` samples back, as signed int16. Only in IDLE: PLAY returns 0.

        The loader advances its index on a *write*, never on a read, so every point
        needs its own WT_INDEX write first -- board_readback.ps1 does exactly that,
        and reading the same index 1024 times returns one sample 1024 times.
        """
        self.require_mode(0)
        samples = []
        for index in range(points):
            self.write(WT_INDEX, index)
            samples.append(self._signed(self.read(WT_DATA)))
        return samples

    @staticmethod
    def _signed(word: int) -> int:
        value = word & 0xFFFF
        return value - 0x10000 if value & 0x8000 else value

    def upload_frames(
        self,
        frames: dict,
        shift: int = 2,
        morph: bool = True,
        period_s: float = 20.0,
        uploaded: dict | None = None,
        on_progress=None,
    ) -> FramesUploadResult:
        """Upload the three morph frames, skipping any that are already on the board.

        Nothing is atomic, so the SELECT word that turns the morph on is written
        once, after the last table, and a refused sample stops everything: a
        half-uploaded morph would sweep between an old frame and a new one.
        """
        from ..wavetable import bar_step, select_word

        started = _time.monotonic()
        baseline = uploaded or {}
        changed = [
            table
            for table in sorted(frames)
            if [int(v) for v in frames[table]] != [int(v) for v in baseline.get(table, [])]
        ]
        for table in changed:
            self.upload_table(
                frames[table],
                table=table,
                voice_shift=shift,
                on_sample=lambda index, total, table=table: (
                    on_progress(table, index, total) if on_progress is not None else None
                ),
            )
        word = select_word(0, shift, morph, bar_step(period_s))
        self.write(WT_SELECT, word)
        return FramesUploadResult(
            ok=True,
            uploaded=tuple(changed),
            select=word,
            elapsed_s=_time.monotonic() - started,
        )

    # -- presets ------------------------------------------------------------

    def apply_preset(self, preset) -> ApplyResult:
        """Write the nine words in ascending order, reading each one back.

        Nothing is atomic on the board, so the order is the verified one from
        board_tune.ps1, and either a refusal or a read-back that differs from the
        file stops the sequence where it happened: a preset that was stored as
        something other than what the file says has to look failed, not green.
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
                return ApplyResult(False, addr, readbacks, clamped)
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
