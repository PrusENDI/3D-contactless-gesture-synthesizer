"""Trajectory to table, phase alignment, and the WT_SELECT word the morph needs."""

import unittest

from host.v2_console import wavetable
from host.wavetable_frames import fundamental, lfo_step


def circle(n=200, radius=20000, cx=32768, cy=32768):
    import math

    return [
        (int(cx + radius * math.cos(2 * math.pi * i / n)),
         int(cy + radius * math.sin(2 * math.pi * i / n)))
        for i in range(n)
    ]


class TableTest(unittest.TestCase):
    def test_trajectory_becomes_1024_points_at_nine_tenths_full_scale(self):
        table = wavetable.table_from_trajectory(circle())
        self.assertEqual(len(table), 1024)
        self.assertEqual(max(abs(sample) for sample in table), 29490)

    def test_table_is_band_limited_and_has_no_dc_offset(self):
        table = wavetable.table_from_trajectory(circle())
        self.assertLess(abs(sum(table) / len(table)), 200)

    def test_same_trajectory_gives_the_same_table(self):
        points = circle()
        self.assertEqual(
            wavetable.table_from_trajectory(points), wavetable.table_from_trajectory(points)
        )

    def test_a_short_trajectory_is_rejected_rather_than_producing_silence(self):
        with self.assertRaises(ValueError):
            wavetable.table_from_trajectory(circle(n=8))


class AlignTest(unittest.TestCase):
    def test_alignment_puts_every_frame_fundamental_at_phase_zero(self):
        table = wavetable.table_from_trajectory(circle())
        rotated = table[256:] + table[:256]
        aligned = wavetable.align_frames([table, rotated])
        for frame in aligned:
            _re, _im = fundamental(frame)
            angle = abs(__import__("cmath").phase(complex(_re, _im)))
            self.assertLess(angle, 0.05)

    def test_alignment_keeps_the_peak(self):
        table = wavetable.table_from_trajectory(circle())
        aligned = wavetable.align_frames([table])[0]
        self.assertEqual(max(abs(sample) for sample in aligned), 29490)


class SelectWordTest(unittest.TestCase):
    def test_step_matches_the_documented_formula(self):
        # step = round(2**25 / (period_s * 48000))
        self.assertEqual(wavetable.bar_step(20.0), lfo_step(20.0))
        self.assertEqual(wavetable.bar_step(4.0), 175)

    def test_select_word_carries_table_shift_morph_and_step(self):
        word = wavetable.select_word(table=1, shift=2, morph=True, step=35)
        self.assertEqual(word & 0x3, 1)
        self.assertEqual((word >> 4) & 0xF, 2)
        self.assertEqual((word >> 8) & 1, 1)
        self.assertEqual(word >> 9, 35)

    def test_select_word_matches_the_register_mask(self):
        word = wavetable.select_word(table=2, shift=15, morph=True, step=0x7FFFFF)
        self.assertEqual(word & ~0xFFFFFFF7, 0)


if __name__ == "__main__":
    unittest.main()
