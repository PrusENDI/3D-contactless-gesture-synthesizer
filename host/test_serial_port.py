"""The real pyserial adapter, tested against a pyserial-shaped double.

pyserial 3.5's ``read`` takes only ``size``. ``Link`` calls ``read(n, timeout_s)``,
so the adapter is the one place that bridges the two; without it the console dies
with a TypeError on the first read of a real board.

The adapter must also never assign ``.timeout`` after open: pyserial's setter
reconfigures the port, and on Windows that flushes the driver buffers, which is
how a reply loses its first bytes.
"""

import time
import unittest

from host.v2_console.serial_port import SerialPort


class PyserialLike:
    """Only the attributes pyserial actually exposes: ``read(size)``, ``in_waiting``."""

    def __init__(self, incoming=b"", fail_on_write=False, chunk_size=None):
        self.incoming = incoming
        self.written = []
        self.closed = False
        self.reconfigures = 0
        self._fail_on_write = fail_on_write
        self._chunk = chunk_size
        self._timeout = 0

    @property
    def timeout(self):
        return self._timeout

    @timeout.setter
    def timeout(self, value):
        self._timeout = value
        self.reconfigures += 1

    def write(self, data):
        if self._fail_on_write:
            raise OSError("port closed")
        self.written.append(bytes(data))
        return len(data)

    @property
    def in_waiting(self):
        return min(len(self.incoming), self._chunk or len(self.incoming))

    def read(self, size=1):
        take = min(size, len(self.incoming))
        chunk, self.incoming = self.incoming[:take], self.incoming[take:]
        return chunk

    def reset_input_buffer(self):
        self.incoming = b""

    def close(self):
        self.closed = True


class StrictTimeoutPort(PyserialLike):
    """A port whose ``timeout`` cannot be reassigned, like a port that must not reconfigure."""

    @PyserialLike.timeout.setter
    def timeout(self, value):
        raise AssertionError("reconfiguring the port would flush buffered bytes")


def adapter(inner):
    port = SerialPort.__new__(SerialPort)
    port._port = inner
    return port


class AdapterTest(unittest.TestCase):
    def test_read_takes_a_timeout_and_returns_what_pyserial_has(self):
        inner = PyserialLike(incoming=b"\x5a\x02")
        self.assertEqual(adapter(inner).read(4096, 0.05), b"\x5a\x02")

    def test_read_of_an_idle_port_is_empty_bytes_not_none(self):
        started = time.monotonic()
        self.assertEqual(adapter(PyserialLike()).read(4096, 0.02), b"")
        self.assertGreaterEqual(time.monotonic() - started, 0.01)

    def test_read_reassembles_a_frame_delivered_in_chunks(self):
        inner = PyserialLike(incoming=b"\x5a\x02\x80\x00", chunk_size=2)
        self.assertEqual(adapter(inner).read(4096, 0.05), b"\x5a\x02\x80\x00")

    def test_read_never_reconfigures_the_port(self):
        port = adapter(StrictTimeoutPort(b"\x5a\x02"))
        self.assertEqual(port.read(4096, 0.02), b"\x5a\x02")

    def test_write_reaches_the_underlying_port(self):
        inner = PyserialLike()
        adapter(inner).write(b"abc")
        self.assertEqual(inner.written, [b"abc"])

    def test_a_write_failure_surfaces_as_oserror_for_link_to_translate(self):
        with self.assertRaises(OSError):
            adapter(PyserialLike(fail_on_write=True)).write(b"abc")

    def test_close_closes_the_underlying_port(self):
        inner = PyserialLike()
        adapter(inner).close()
        self.assertTrue(inner.closed)


if __name__ == "__main__":
    unittest.main()
