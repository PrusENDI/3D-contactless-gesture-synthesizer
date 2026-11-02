"""Serial transport for the board: frame construction and CRC.

The wire format is frozen in rtl/v2_contract_pkg.sv and in every board_*.ps1
script: an 11-byte command (A5 02 op addr seq d31..d24 d23..d16 d15..d8 d7..d0
crc_hi crc_lo) with CRC16-CCITT-FALSE over the first nine bytes.
"""

from __future__ import annotations

# CRC16-CCITT-FALSE over b"123456789"; both the board scripts and this module
# refuse to run when their own implementation disagrees with it.
CRC_SELFTEST = 0x29B1

SOF = 0xA5
VERSION = 0x02
OP_READ = 0x01
OP_WRITE = 0x02


def crc16(data: bytes) -> int:
    """CRC16-CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_frame(op: int, addr: int, data: int, seq: int) -> bytes:
    """One 11-byte command frame. The payload is big-endian, as on the wire."""
    frame = bytearray(
        [
            SOF,
            VERSION,
            op & 0xFF,
            addr & 0xFF,
            seq & 0xFF,
            (data >> 24) & 0xFF,
            (data >> 16) & 0xFF,
            (data >> 8) & 0xFF,
            data & 0xFF,
        ]
    )
    value = crc16(bytes(frame))
    frame += bytes([(value >> 8) & 0xFF, value & 0xFF])
    return bytes(frame)
