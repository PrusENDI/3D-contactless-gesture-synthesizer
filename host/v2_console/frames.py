"""Frame parsing for the one serial stream that carries both kinds of 22-byte frame.

A command reply has frame[2] in {0x80 ACK, 0x81 NACK}; a telemetry snapshot has
frame[2] == 0x01. Both are 22 bytes with a CRC16 over the first 20, so the only
way to tell them apart is byte 2 -- never the length and never the arrival order.
"""

from __future__ import annotations

from dataclasses import dataclass

from .link import VERSION, crc16

FRAME_LEN = 22
# Replies and telemetry start with 0x5A; a command starts with 0xA5. Mixing the
# two constants silently drops every valid frame, so they live in different names.
TLM_SOF = 0x5A
TLM_ACK = 0x80
TLM_NACK = 0x81
TLM_SNAPSHOT = 0x01


@dataclass(frozen=True)
class Reply:
    """One command reply. ``nack`` is True when the board refused the command."""

    ok: bool
    nack: bool
    err: int
    seq: int
    data: int


@dataclass(frozen=True)
class Telemetry:
    """One 22-byte snapshot. The cursor fields are what a live view draws."""

    seq: int
    x: int
    y: int
    z: int
    note: int
    flags: int
    tick: int
    voices: int
    fifo: int
    fault: int


def parse_one(frame: bytes) -> Reply | Telemetry | None:
    """Decode exactly one 22-byte frame, or None when it is not a valid frame."""
    if len(frame) != FRAME_LEN or frame[0] != TLM_SOF or frame[1] != VERSION:
        return None
    if crc16(frame[:20]) != int.from_bytes(frame[20:22], "big"):
        return None
    kind = frame[2]
    if kind in (TLM_ACK, TLM_NACK):
        return Reply(
            ok=kind == TLM_ACK,
            nack=kind == TLM_NACK,
            err=frame[19],
            seq=frame[4],
            data=int.from_bytes(frame[14:18], "big"),
        )
    if kind == TLM_SNAPSHOT:
        return Telemetry(
            seq=int.from_bytes(frame[3:5], "big"),
            x=int.from_bytes(frame[5:7], "big"),
            y=int.from_bytes(frame[7:9], "big"),
            z=int.from_bytes(frame[9:11], "big"),
            note=frame[11],
            flags=frame[12],
            tick=frame[13],
            voices=int.from_bytes(frame[14:18], "big"),
            fifo=frame[18],
            fault=frame[19],
        )
    return None


class StreamParser:
    """Incremental parser. An incomplete frame stays buffered until the rest arrives.

    A byte that does not start a valid frame is skipped one at a time, which is
    what makes 0x5A inside a payload harmless: the CRC decides, not the marker.
    """

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._dropped = 0
        self._replies: list[Reply] = []
        self._telemetry: list[Telemetry] = []

    def feed(self, chunk: bytes) -> None:
        self._buffer += chunk
        self._drain()

    def next_reply(self) -> Reply | None:
        return self._replies.pop(0) if self._replies else None

    def next_telemetry(self) -> Telemetry | None:
        return self._telemetry.pop(0) if self._telemetry else None

    def dropped_bytes(self) -> int:
        return self._dropped

    def _drain(self) -> None:
        index = 0
        total = len(self._buffer)
        while index < total:
            if self._buffer[index] != TLM_SOF:
                index += 1
                self._dropped += 1
                continue
            if total - index < FRAME_LEN:
                break
            decoded = parse_one(bytes(self._buffer[index : index + FRAME_LEN]))
            if decoded is None:
                index += 1
                self._dropped += 1
                continue
            if isinstance(decoded, Reply):
                self._replies.append(decoded)
            else:
                self._telemetry.append(decoded)
            index += FRAME_LEN
        if index:
            del self._buffer[:index]
