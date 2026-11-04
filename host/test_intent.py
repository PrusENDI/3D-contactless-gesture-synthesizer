"""The real-time intent engine: bands, registers, rhythm and melody labels.

The point of these tests is not "the classifier is right" in a musical sense --
that needs ears -- but that the *mechanics* are causal and stable: a note is
reported only after its band holds, close notes merge, the register follows a
slow median rather than a jittery value, and the rhythm labels distinguish an
even pulse from one that speeds up.
"""

import unittest

from host.v2_console.intent import (BAND_EDGES, Estimate, IntentEngine, band_of,
                                    register_of)

RATE = 200.0                      # samples per second used by every test
STEP = 1.0 / RATE

# A y value in the middle of each band, so the mapping cannot be ambiguous.
BAND_Y = (1900, 8600, 18300, 27000, 35600, 45300, 54900, 62600)


def feed(engine, plan, t=0.0):
    """``plan`` is [(seconds, band), ...]; returns the final time."""
    for seconds, band in plan:
        count = max(1, int(round(seconds * RATE)))
        for _ in range(count):
            engine.push(BAND_Y[band], t)
            t += STEP
    return t


class BandTest(unittest.TestCase):
    def test_the_edges_belong_to_the_band_above_them(self):
        self.assertEqual(band_of(0), 0)
        self.assertEqual(band_of(BAND_EDGES[0] - 1), 0)
        self.assertEqual(band_of(BAND_EDGES[0]), 1)
        self.assertEqual(band_of(BAND_EDGES[-1]), 7)
        self.assertEqual(band_of(65535), 7)

    def test_every_band_centre_maps_back_to_itself(self):
        for band, y in enumerate(BAND_Y):
            self.assertEqual(band_of(y), band)

    def test_the_register_is_thirds_of_the_travel(self):
        self.assertEqual(register_of(1000), "low")
        self.assertEqual(register_of(30000), "mid")
        self.assertEqual(register_of(60000), "high")


class OnsetTest(unittest.TestCase):
    def test_a_note_needs_the_band_to_hold(self):
        engine = IntentEngine()
        end = feed(engine, [(0.10, 3)])
        before = engine.estimate().onsets
        self.assertEqual(before, 1)                   # the sustained note
        engine.push(BAND_Y[5], end)                   # one sample in the new band
        self.assertEqual(engine.estimate().onsets, before)
        for index in range(1, 3):
            engine.push(BAND_Y[5], end + index * STEP)
        self.assertEqual(engine.estimate().onsets, before + 1)

    def test_two_changes_closer_than_the_floor_merge_into_one(self):
        engine = IntentEngine(min_note_s=0.2)
        start = feed(engine, [(0.10, 2)])
        engine.push(BAND_Y[4], start)
        for index in range(1, 4):
            engine.push(BAND_Y[4], start + index * STEP)
        # The next change arrives after ~20 ms, well under the 200 ms floor.
        engine.push(BAND_Y[5], start + 0.02)
        for index in range(1, 4):
            engine.push(BAND_Y[5], start + 0.02 + index * STEP)
        self.assertEqual(engine.estimate().onsets, 1)

    def test_a_still_hand_is_one_sustained_note_not_a_melody(self):
        engine = IntentEngine()
        feed(engine, [(1.0, 4)])
        estimate = engine.estimate()
        self.assertEqual(estimate.onsets, 1)         # the note it is holding
        self.assertEqual(estimate.melody, "flat")    # but no melody to speak of
        self.assertLess(estimate.confidence, 0.3)

    def test_one_sample_of_jitter_is_not_a_note(self):
        engine = IntentEngine()
        start = feed(engine, [(0.5, 4)])
        engine.push(BAND_Y[7], start)                 # a single spike
        feed(engine, [(0.5, 4)], start + STEP)
        self.assertEqual(engine.estimate().onsets, 1)


class RegisterTest(unittest.TestCase):
    def test_a_high_phrase_reads_high(self):
        engine = IntentEngine()
        feed(engine, [(0.4, 6), (0.4, 7)])
        self.assertEqual(engine.estimate().register, "high")

    def test_a_low_phrase_reads_low(self):
        engine = IntentEngine()
        feed(engine, [(0.4, 0), (0.4, 1)])
        self.assertEqual(engine.estimate().register, "low")

    def test_one_short_glitch_does_not_move_the_register(self):
        engine = IntentEngine()
        start = feed(engine, [(0.6, 1)])
        feed(engine, [(0.05, 7)], start)              # 50 ms spike
        feed(engine, [(0.3, 1)], start + 0.05)
        self.assertEqual(engine.estimate().register, "low")


class RhythmTest(unittest.TestCase):
    def test_equal_gaps_read_even(self):
        engine = IntentEngine()
        feed(engine, [(0.2, (i % 4)) for i in range(10)])
        self.assertEqual(engine.estimate().rhythm, "even")

    def test_gaps_that_shrink_read_accelerating(self):
        engine = IntentEngine()
        plan = [(0.40, 2), (0.36, 4), (0.30, 3), (0.24, 5), (0.18, 2), (0.12, 4)]
        feed(engine, plan)
        self.assertEqual(engine.estimate().rhythm, "accelerating")

    def test_gaps_that_grow_read_slowing(self):
        engine = IntentEngine()
        plan = [(0.12, 2), (0.18, 4), (0.24, 3), (0.30, 5), (0.36, 2), (0.40, 4)]
        feed(engine, plan)
        self.assertEqual(engine.estimate().rhythm, "slowing")

    def test_a_2_to_1_figure_reads_dotted(self):
        engine = IntentEngine()
        plan = [(0.13, 2), (0.26, 4), (0.13, 3), (0.26, 5), (0.13, 2), (0.26, 4)]
        feed(engine, plan)
        self.assertEqual(engine.estimate().rhythm, "dotted")

    def test_too_few_notes_is_free_not_a_guess(self):
        engine = IntentEngine()
        feed(engine, [(0.2, 2), (0.2, 4)])
        self.assertEqual(engine.estimate().rhythm, "free")


class MelodyTest(unittest.TestCase):
    def test_a_rise_is_ascending_and_stepwise(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (2, 3, 4, 5, 6)])
        estimate = engine.estimate()
        self.assertEqual(estimate.melody, "ascending")
        self.assertEqual(estimate.figures, "stepwise")

    def test_a_fall_is_descending(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (6, 5, 4, 3, 2)])
        self.assertEqual(engine.estimate().melody, "descending")

    def test_up_then_down_is_an_arch(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (2, 4, 6, 7, 6, 4, 2)])
        self.assertEqual(engine.estimate().melody, "arch")

    def test_down_then_up_is_a_valley(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (6, 4, 2, 0, 2, 4, 6)])
        self.assertEqual(engine.estimate().melody, "valley")

    def test_big_leaps_read_arpeggio(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (0, 3, 6, 3, 0)])
        self.assertEqual(engine.estimate().figures, "arpeggio")

    def test_alternating_notes_read_wave(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (2, 5, 2, 5, 2, 5)])
        self.assertEqual(engine.estimate().melody, "wave")


class ShapeTest(unittest.TestCase):
    def test_an_empty_engine_is_confident_about_nothing(self):
        estimate = IntentEngine().estimate()
        self.assertIsInstance(estimate, Estimate)
        self.assertEqual(estimate.confidence, 0.0)
        self.assertEqual(estimate.onsets, 0)

    def test_the_line_renders_without_notes(self):
        self.assertIn("conf=0.00", IntentEngine().estimate().line())

    def test_confidence_rises_with_a_real_phrase(self):
        engine = IntentEngine()
        feed(engine, [(0.2, band) for band in (2, 3, 4, 5, 6)])
        self.assertGreater(engine.estimate().confidence, 0.5)

    def test_the_engine_does_not_grow_without_bound(self):
        engine = IntentEngine()
        feed(engine, [(0.05, band % 8) for band in range(400)])
        self.assertLess(len(engine._t), 400)          # the window is trimmed


if __name__ == "__main__":
    unittest.main()
