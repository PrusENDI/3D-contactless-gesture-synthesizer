"""Regression for the integer-note Potts reference.

Ported from mgc3130_uart/tools/test_v2_potts_reference.py (same five cases).
Run from the repo root:

    python -m unittest host.test_v2_potts_reference -v
"""
import unittest

from host.v2_potts_reference import NOTES, PottsEvent, solve


class PottsTests(unittest.TestCase):
    def test_constant_and_min_length(self):
        e = solve([60] * 128, lambda_q16=65536, min_length=4)
        self.assertEqual(len(e), 1)
        self.assertEqual((e[0].tick, e[0].duration, e[0].note), (0, 128, 60))

    def test_change_and_rest(self):
        x = [57] * 64 + [67] * 64
        e = solve(x, lambda_q16=0, min_length=4)
        self.assertEqual([(a.tick, a.duration, a.note) for a in e],
                         [(0, 64, 57), (64, 64, 67)])
        e = solve([57] * 128, rest_mask=(1 << 64) - 1, lambda_q16=0, min_length=4)
        self.assertEqual(e[0].tick, 64)
        self.assertEqual(e[0].duration, 64)

    def test_bounded_input(self):
        self.assertLessEqual(len(solve([i % 5 + 57 for i in range(128)])), 32)

    def test_full_rest_and_lambda(self):
        self.assertEqual(solve([57] * 128, rest_mask=(1 << 128) - 1), [])
        alternating = [57 if i % 2 == 0 else 67 for i in range(128)]
        self.assertLessEqual(len(solve(alternating, lambda_q16=65536)),
                             len(solve(alternating, lambda_q16=0)))

    def test_tie_prefers_low_degree(self):
        e = solve([58] * 128, lambda_q16=0)
        self.assertEqual(e[0].note, 57)


if __name__ == "__main__":
    unittest.main()
