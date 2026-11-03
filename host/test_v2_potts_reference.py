"""Regression for the y-space Potts reference.

The contour is cursor_y>>6, the fit uses LEVELS and the event carries NOTES, the
same two tables the hardware uses.  Run from the repo root:

    python -m unittest host.test_v2_potts_reference -v
"""
import unittest

from host.v2_potts_reference import LEVELS, NOTES, PottsEvent, purify_valid, solve


class PottsTests(unittest.TestCase):
    def test_purify_matches_the_hardware_cases(self):
        # Same seven cases as tb/tb_loop_rest_purify.sv.
        cases = [
            (0xFFFFFFFF, 0xFFFFFFFF),   # all data
            (0x00000000, 0x00000000),   # all rest
            (0xFFFCFFFF, 0xFFFFFFFF),   # two-tick rest absorbed
            (0xFFE0FFFF, 0xFFE0FFFF),   # five-tick rest kept
            (0xFFFF0FFF, 0xFFFF0FFF),   # exactly four ticks kept
            (0xFFFFFFFC, 0xFFFFFFFC),   # short first run kept
            (0x00000CFF, 0x00000FFF),   # two short runs collapse in a row
        ]
        for raw, expected in cases:
            self.assertEqual(purify_valid(raw, 32), expected, hex(raw))

    def test_exact_h32_event_stream(self):
        # The same contour and the same expectation as tb_v2_potts_commit_fsm:
        # level 30 is note 55, level 978 is the top note 67 (G4) in the
        # G-natural-minor scale.
        contour = [30] * 8 + [978] * 24
        events = solve(contour, lambda_q16=0, min_length=4, horizon=32)
        got = sorted((e.tick, e.duration, e.note) for e in events)
        self.assertEqual(got, [(0, 8, 55), (8, 24, 67)])

    def test_constant_and_min_length(self):
        e = solve([30] * 32, lambda_q16=21600, min_length=4, horizon=32)
        self.assertEqual(len(e), 1)
        self.assertEqual((e[0].tick, e[0].duration, e[0].note), (0, 32, 55))

    def test_change_and_rest(self):
        contour = [30] * 16 + [978] * 16
        e = solve(contour, lambda_q16=0, min_length=4, horizon=32)
        self.assertEqual([(a.tick, a.duration, a.note) for a in e],
                         [(0, 16, 55), (16, 16, 67)])
        # A full rest on the first half forces the note to start at tick 16.
        e = solve(contour, rest_mask=(1 << 16) - 1, lambda_q16=0, horizon=32)
        self.assertEqual([(a.tick, a.duration, a.note) for a in e], [(16, 16, 67)])

    def test_bounded_input(self):
        contour = [LEVELS[i % len(LEVELS)] for i in range(32)]
        self.assertLessEqual(len(solve(contour, horizon=32)), 8)

    def test_full_rest_is_silent(self):
        self.assertEqual(solve([30] * 32, rest_mask=(1 << 32) - 1, horizon=32), [])

    def test_tie_prefers_low_degree(self):
        e = solve([58] * 32, lambda_q16=0, horizon=32)
        self.assertEqual(e[0].note, 55)


if __name__ == "__main__":
    unittest.main()
