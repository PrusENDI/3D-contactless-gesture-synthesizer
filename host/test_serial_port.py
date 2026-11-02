"""The real pyserial adapter, tested against a pyserial-shaped double.

pyserial 3.5's ``read`` takes only ``size``. ``Link`` calls ``read(n, timeout_s)``,
so the adapter is the one place that bridges the two; without it the console dies
with a TypeError on the first read of a real board.
"""

import unittest

from host.v2_console.serial_port import SerialPort


class PyserialLike:
    """Only the attributes pyserial actually exposes: ``read(size)`` and ``timeout``."""

    def __init__(self, incoming=b"", fail_on_write=False):
        self.incoming = incoming
        self.written = []
        self.timeout = None
        self.closed = False
        self._fail_on_write = fail_on_write

    def write(self, data):
        if self._fail_on_write:
            raise OSError("port closed")
        self.written.append(bytes(data))
        return len(data)

    def read(self, size=1):
        chunk, self.incoming = self.incoming[:size], self.incoming[size:]
        return chunk

    def reset_input_buffer(self):
        self.incoming = b""

    def close(self):
        self.closed = True


def adapter(inner):
    port = SerialPort.__new__(SerialPort)
    port._port = inner
    return port


class AdapterTest(unittest.TestCase):
    def test_read_takes_a_timeout_and_returns_what_pyserial_has(self):
        inner = PyserialLike(incoming=b"\x5a\x02")
        self.assertEqual(adapter(inner).read(4096, 0.05), b"\x5a\x02")
        self.assertEqual(inner.timeout, 0.05)

    def test_read_of_an_idle_port_is_empty_bytes_not_none(self):
        self.assertEqual(adapter(PyserialLike()).read(4096, 0.0), b"")

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
