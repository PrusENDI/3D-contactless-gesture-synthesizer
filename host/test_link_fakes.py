"""Test doubles for the serial port: scripted replies, no hardware, no sleeps to speak of."""

from __future__ import annotations

import time
from collections import deque

from host.v2_console import link


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


class ScriptedPort:
    """A port that hands out queued byte chunks and can die on a chosen write.

    An empty queue returns b"" after a short sleep so a caller's timeout logic
    sees a real idle wait instead of a busy spin.
    """

    def __init__(
        self,
        chunks: list[bytes] | None = None,
        die_on_write: int | None = None,
        stall_until_write: int | None = None,
    ):
        self.chunks: deque[bytes] = deque(chunks or [])
        self.written: list[bytes] = []
        self.dead = False
        self._die_on_write = die_on_write
        self._stall_until_write = stall_until_write

    def write(self, data: bytes) -> None:
        if self.dead:
            raise OSError("port closed")
        self.written.append(bytes(data))
        if self._die_on_write is not None and len(self.written) >= self._die_on_write:
            self.dead = True

    def read(self, n: int, timeout_s: float) -> bytes:
        if self.dead:
            raise OSError("port closed")
        if self._stall_until_write is not None and len(self.written) < self._stall_until_write:
            time.sleep(min(timeout_s, 0.005))
            return b""
        if not self.chunks:
            time.sleep(min(timeout_s, 0.005))
            return b""
        return self.chunks.popleft()

    def reset_input(self) -> None:
        self.chunks.clear()

    def close(self) -> None:
        self.dead = True

    def written_count(self) -> int:
        return len(self.written)
