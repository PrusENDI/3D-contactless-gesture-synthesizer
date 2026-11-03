"""AKWF cycles -> board frames: parsing, DC, band limiting, frame scaling.

The parts that can be wrong without a sound to hear: the array parser (a header
holds 100+ arrays), the DC removal (a cycle with an offset clicks once per
cycle), the band limit (harmonic 60 at G4 folds back as fizz), and the one
scale for all three frames (a per-frame normalisation makes the morph a volume
ride instead of a timbre move).
"""

import json
import math
import struct
import tempfile
import unittest
from pathlib import Path

from host import akwf_tables as akwf


def sine(frequency, count=1024, amplitude=1.0, offset=0.0):
    return [offset + amplitude * math.sin(2.0 * math.pi * frequency * k / count)
            for k in range(count)]


class ParseTest(unittest.TestCase):
    HEADER = """// Converted by AKWF2Teensy from AKWF_test_0001.wav.
// AKWF2Teensy - Beerware by Datanoise.net.
const int16_t AKWF_test_0001[1025] = {
   1, 2, 3,
   -4, -5, -6
};
const int16_t AKWF_test_0002[1025] = {
   7, 8,
   9
};
"""

    def test_every_array_is_read_with_its_own_name(self):
        parsed = akwf.parse(self.HEADER)
        self.assertEqual([name for name, _ in parsed],
                         ["AKWF_test_0001", "AKWF_test_0002"])
        self.assertEqual(parsed[0][1], [1, 2, 3, -4, -5, -6])
        self.assertEqual(parsed[1][1], [7, 8, 9])

    def test_a_family_name_maps_to_its_header(self):
        self.assertEqual(akwf.header_path("flute").name, "AKWF_flute.h")
        with self.assertRaises(KeyError):
            akwf.header_path("nonsense")


class CycleTest(unittest.TestCase):
    def test_the_extra_closing_sample_is_dropped_and_dc_is_removed(self):
        samples = [int(1000 + 500 * math.sin(2 * math.pi * k / 1024)) for k in range(1024)]
        samples.append(samples[0])                      # the mirror's 1025th
        values = akwf.cycle(samples)
        self.assertEqual(len(values), 1024)
        self.assertAlmostEqual(sum(values) / len(values), 0.0, places=6)

    def test_the_band_limit_keeps_the_fundamental_and_scales_by_cutoff_over_k(self):
        samples = [int(10000 * (math.sin(2 * math.pi * k / 1024)
                                + 0.5 * math.sin(2 * math.pi * 30 * k / 1024)))
                   for k in range(1024)]
        before = akwf.spectrum(akwf.cycle(samples))
        after = akwf.spectrum(akwf.tilt(samples, 8))
        self.assertAlmostEqual(after[1] / before[1], 1.0, places=2)
        # (cutoff/k)**2 for the harmonic above the cutoff, and nothing else moves
        self.assertAlmostEqual(after[30] / before[30], (8.0 / 30.0) ** 2, delta=0.02)
        # below the cutoff nothing moves
        self.assertAlmostEqual(after[1] / before[1], 1.0, places=6)

    def test_a_cutoff_at_the_nyquist_harmonic_is_a_no_op(self):
        samples = [int(8000 * math.sin(2 * math.pi * k / 1024)) for k in range(1024)]
        plain = akwf.cycle(samples)
        tilted = akwf.tilt(samples, 512)
        worst = max(abs(a - b) for a, b in zip(plain, tilted))
        self.assertLess(worst, 1.0)


class ScoreTest(unittest.TestCase):
    def test_a_balanced_square_beats_a_narrow_pulse(self):
        square = [10000 if k < 512 else -10000 for k in range(1024)]
        pulse = [10000 if k < 60 else -1000 for k in range(1024)]
        self.assertGreater(akwf.score(akwf.features(square)),
                           akwf.score(akwf.features(pulse)))


class FrameTest(unittest.TestCase):
    def setUp(self):
        self.samples = [int(12000 * (math.sin(2 * math.pi * k / 1024)
                                     + 0.4 * math.sin(2 * math.pi * 9 * k / 1024)))
                        for k in range(1024)]

    def test_three_frames_of_1024_int16(self):
        block = akwf.frames(self.samples, (40, 26, 14))
        self.assertEqual(len(block), 3)
        for values in block:
            self.assertEqual(len(values), 1024)
            self.assertTrue(all(-32768 <= v <= 32767 for v in values))

    def test_one_scale_for_all_three_frames(self):
        block = akwf.frames(self.samples, (40, 26, 14))
        peak = max(max(abs(v) for v in values) for values in block)
        self.assertLessEqual(peak, akwf.PEAK)
        self.assertGreaterEqual(peak, akwf.PEAK - 2)    # the loudest frame pins it

    def test_the_dark_frame_has_less_high_harmonic_energy(self):
        bright, _body, dark = akwf.frames(self.samples, (40, 26, 6))
        self.assertGreater(akwf.spectrum(bright)[9], akwf.spectrum(dark)[9])


class PresetTest(unittest.TestCase):
    def test_the_preset_has_nine_words_and_the_body_frame(self):
        document = akwf.preset("akwf-test", "flute", "AKWF_flute_0001")
        self.assertEqual(sorted(document["words"]),
                         ["0x40", "0x44", "0x84", "0x88", "0x8C",
                          "0x90", "0x94", "0x98", "0x9C"])
        self.assertEqual(document["wavetable"]["table"], 1)
        self.assertFalse(document["wavetable"]["morph"])
        self.assertEqual(document["words"]["0x40"], 0)      # filter off
        self.assertEqual(document["words"]["0x44"], 0)      # no LFO
        self.assertIn("CC0", document["source"])

    def test_the_preset_written_to_disk_is_json(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "p.json"
            path.write_text(json.dumps(akwf.preset("x", "flute", "w")), encoding="utf-8")
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["name"], "x")


if __name__ == "__main__":
    unittest.main()
