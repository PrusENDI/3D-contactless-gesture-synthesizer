"""CRC16-CCITT-FALSE, the one checksum the wire format and the wavetable use.

It lives in its own module so the frame parser and the transport can share it
without importing each other.
"""

from __future__ import annotations

# CRC16-CCITT-FALSE over b"123456789"; scripts/board_wt_upload.ps1 asserts the
# same value before it uploads a table.
CRC_SELFTEST = 0x29B1


def crc16(data: bytes) -> int:
    """CRC16-CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc
