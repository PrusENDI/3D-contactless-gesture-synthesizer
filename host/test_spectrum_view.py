"""Unit tests for host/spectrum_view_model.py (no Tk needed)."""

import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spectrum_view_model as model  # noqa: E402

SAMPLE_COLUMN = "u_i2s/sample_latched[15:0]"
COUNT_COLUMN = "u_seq/demo_tone_count[5:0]"


def write_capture(path: str, samples: list[int], tone_count: int | None = None) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("Groups:\nData:\n")
        header = ["time unit: us", COUNT_COLUMN, SAMPLE_COLUMN]
        fh.write(", ".join(header) + ", \n")
        for index, value in enumerate(samples):
            count = tone_count if tone_count is not None else 0
            fh.write("%.1f, %02x, %04x, \n" % (index * 1000.0 / 48000.0, count, value & 0xFFFF))


def synth(tones: list[int], samples: int = 4096, amplitude: int = 900) -> list[int]:
    out = []
    for n in range(samples):
        total = 0.0
        for k in tones:
            total += amplitude * math.sin(2.0 * math.pi * 220.0 * k * n / 48000.0)
        out.append(max(-32768, min(32767, int(round(total)))))
    return out


class Analyze(unittest.TestCase):
    def test_thirty_two_tones_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(range(1, 33)), tone_count=32)
            result = model.analyze(path, expected=32)
            self.assertEqual(result.peaks_found, 32)
            self.assertEqual(result.missing, [])
            self.assertEqual(result.stray, 0)
            self.assertTrue(result.ok)
            self.assertEqual(result.tone_count, 32)
            self.assertIn("32/32", result.verdict)

    def test_a_missing_tone_is_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(range(1, 33)), tone_count=32)
            # A capture with only 31 tones: k=5 is absent.
            write_capture(path, synth([k for k in range(1, 33) if k != 5]), tone_count=32)
            result = model.analyze(path, expected=32)
            self.assertEqual(result.missing, [5])
            self.assertFalse(result.ok)
            self.assertIn("5", result.verdict)

    def test_extra_peaks_are_stray_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(range(1, 33)), tone_count=32)
            result = model.analyze(path, expected=8)
            self.assertEqual(result.peaks_found, 8)
            self.assertGreater(result.stray, 0)
            self.assertFalse(result.ok)

    def test_wrong_segment_is_reported_as_wrong_segment(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(range(1, 9)), tone_count=8)
            result = model.analyze(path, expected=32)
            self.assertFalse(result.segment_ok)
            self.assertIn("抓错段", result.verdict)

    def test_frequency_error_is_reported_in_bins(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(range(1, 33)), tone_count=32)
            result = model.analyze(path, expected=32)
            for peak in result.peaks:
                self.assertLess(abs(peak.error_bins), 2.0, "k=%d off by %.2f bins"
                                % (peak.k, peak.error_bins))


class CaptureLookup(unittest.TestCase):
    def test_a_core0_suffix_is_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(tmp, "run_core0.csv")
            write_capture(real, synth(range(1, 3)))
            self.assertEqual(model.resolve_capture(os.path.join(tmp, "run")), real)

    def test_a_missing_file_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                model.resolve_capture(os.path.join(tmp, "nothing"))


class Curve(unittest.TestCase):
    def test_curve_is_ordered_and_normalised(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "cap.csv")
            write_capture(path, synth(range(1, 33)), tone_count=32)
            values, bin_hz, _peak = model.curve(path)
            self.assertGreater(len(values), 64)
            # Decimation for the drawing can skip the exact peak bin, so the top
            # of the curve is at most 0 dB and within a fraction of it.
            self.assertLessEqual(max(values), 0.0)
            self.assertGreater(max(values), -0.5)
            self.assertAlmostEqual(bin_hz, 48000.0 / 4096)


if __name__ == "__main__":
    unittest.main()
