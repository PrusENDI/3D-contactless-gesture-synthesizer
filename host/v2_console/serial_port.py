"""pyserial behind the interface ``Link`` expects.

``Link`` calls ``port.read(n, timeout_s)``; pyserial 3.5 exposes ``read(size)`` and
carries the wait in ``timeout``. The adapter sets that timeout **once** and polls
``in_waiting`` instead: pyserial's ``timeout`` setter reconfigures the port, and
on Windows the reconfiguration flushes the driver buffers, which shows up as a
reply that is missing its first bytes.
"""

from __future__ import annotations

import time


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
        deadline = time.monotonic() + max(0.0, timeout_s)
        buffer = bytearray()
        while True:
            waiting = self._port.in_waiting
            if waiting:
                buffer += self._port.read(min(waiting, n - len(buffer)))
                if len(buffer) >= n:
                    break
            if time.monotonic() >= deadline:
                break
            time.sleep(0.001)
        return bytes(buffer[:n])

    def reset_input(self) -> None:
        self._port.reset_input_buffer()

    def close(self) -> None:
        self._port.close()

    @property
    def is_open(self) -> bool:
        return bool(self._port.is_open)
