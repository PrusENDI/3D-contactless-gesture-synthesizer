"""pyserial behind the interface ``Link`` expects.

``Link`` calls ``port.read(n, timeout_s)``; pyserial 3.5 exposes ``read(size)`` and
carries the wait in ``timeout``. Bridging the two here, once, is what keeps the
console from dying with a TypeError on the first read of a real board.
"""

from __future__ import annotations


class SerialPort:
    """A serial port with the Link's read(n, timeout) shape."""

    def __init__(self, port_name: str, baud: int = 1_000_000, write_timeout: float = 0.4):
        import serial

        self._port = serial.Serial(
            port_name, baud, timeout=0, write_timeout=write_timeout
        )

    def write(self, data: bytes) -> None:
        self._port.write(data)

    def read(self, n: int, timeout_s: float) -> bytes:
        self._port.timeout = max(0.0, timeout_s)
        chunk = self._port.read(n)
        return chunk or b""

    def reset_input(self) -> None:
        self._port.reset_input_buffer()

    def close(self) -> None:
        self._port.close()

    @property
    def is_open(self) -> bool:
        return bool(self._port.is_open)
