"""Unit tests for host/spectrum.py.

The tool reads Gowin's raw GAO capture (a "Data:" header, then rows of
"time_us, value") and counts peaks.  These tests build captures synthetically,
so the parser and the FFT are covered without the board.
"""

import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spectrum  # noqa: E402  (lives next to this test, host/ is not a package)


def write_capture(path: str, samples: list[int], column: str = "u_i2s/sample_latched[15:0]") -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("Groups:\n")
        fh.write("Data:\n")
        fh.write("time unit: us, %s, \n" % column)
        for index, value in enumerate(samples):
            fh.write("%.1f, %04x, \n" % (index * 1000.0 / 48000.0, value & 0xFFFF))


def synth(count: int, samples: int = 4096, amplitude: int = 900) -> list[int]:
    out = []
    for n in range(samples):
        total = 0.0
        for k in range(1, count + 1):
            total += amplitude * math.sin(2.0 * math.pi * 220.0 * k * n / 48000.0)
        out.append(max(-32768, min(32767, int(round(total)))))
    return out


class ReadCapture(unittest.TestCase):
    def test_reads_rows_and_the_named_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, [1, -2, 3])
            samples, name = spectrum.read_capture(path)
            self.assertEqual(samples, [1.0, -2.0, 3.0])
            self.assertIn("sample_latched", name)

    def test_two_s_complement_is_signed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, [-1, -32768, 0])
            samples, _ = spectrum.read_capture(path)
            self.assertEqual(samples, [-1.0, -32768.0, 0.0])

    def test_a_missing_data_section_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("nothing here\n")
            with self.assertRaises(ValueError):
                spectrum.read_capture(path)

    def test_an_unknown_column_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, [0])
            with self.assertRaises(ValueError):
                spectrum.read_capture(path, column="no_such_signal")


class Peaks(unittest.TestCase):
    def test_thirty_two_tones_are_thirty_two_peaks(self):
        peaks = spectrum.find_peaks([float(v) for v in synth(32)])
        self.assertEqual(len(peaks), 32)
        for index, (freq, _level) in enumerate(peaks, start=1):
            self.assertAlmostEqual(freq, 220.0 * index, delta=3.0 * 48000.0 / 4096)

    def test_one_tone_is_one_peak(self):
        peaks = spectrum.find_peaks([float(v) for v in synth(1)])
        self.assertEqual(len(peaks), 1)
        self.assertAlmostEqual(peaks[0][0], 220.0, delta=2.0 * 48000.0 / 4096)

    def test_silence_has_no_peaks(self):
        self.assertEqual(spectrum.find_peaks([0.0] * 1024), [])

    def test_a_short_capture_is_an_error(self):
        with self.assertRaises(ValueError):
            spectrum.find_peaks([0.0] * 8)


class CommandLine(unittest.TestCase):
    def test_expect_matches_and_mismatch_exits_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(8))
            self.assertEqual(spectrum.main(["--csv", path, "--expect", "8"]), 0)
            self.assertEqual(spectrum.main(["--csv", path, "--expect", "32"]), 2)

    def test_a_bad_file_exits_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("not a capture\n")
            self.assertEqual(spectrum.main(["--csv", path]), 1)


if __name__ == "__main__":
    unittest.main()
