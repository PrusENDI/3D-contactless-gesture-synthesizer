"""The score: eight playable notes, the guide bands, and a take's hit rate."""

import json
import unittest
from pathlib import Path

from host.v2_console import score

SCORE_DIR = Path(__file__).resolve().parent / "scores"
# The midpoints host/v2_potts_reference.py fits to, which are the band centres.
# G natural minor: 55 57 58 60 62 63 65 67.
LEVEL = {55: 30, 57: 135, 58: 286, 60: 421, 62: 557, 63: 707, 65: 858, 67: 978}


def contour_of(target):
    return [LEVEL[note] if note else 0 for note in target]


class BandTest(unittest.TestCase):
    def test_no_value_is_a_rest_not_the_bottom_note(self):
        self.assertIsNone(score.note_of(0))

    def test_each_edge_belongs_to_the_note_above_it(self):
        self.assertEqual(score.note_of(59), 55)
        self.assertEqual(score.note_of(60), 57)
        self.assertEqual(score.note_of(210), 57)
        self.assertEqual(score.note_of(211), 58)
        self.assertEqual(score.note_of(1023), 67)

    def test_every_note_maps_back_from_its_own_band(self):
        for note in score.NOTES:
            low, high = score.band_of(note)
            self.assertEqual(score.note_of((low + high) // 2), note)

    def test_a_note_the_rom_cannot_play_has_no_band(self):
        with self.assertRaises(KeyError):
            score.band_of(61)

    def test_bands_are_contiguous_and_cover_the_whole_range(self):
        bands = score.edges()
        self.assertEqual(len(bands), len(score.NOTES))
        self.assertEqual(bands[0][0], 0)
        self.assertEqual(bands[-1][1], score.CONTOUR_MAX)
        for lower, upper in zip(bands, bands[1:]):
            self.assertEqual(lower[1], upper[0])


class LoadTest(unittest.TestCase):
    def setUp(self):
        self.score = score.load(SCORE_DIR / "c-am-vamp-4s.json")

    def test_the_shipped_score_has_four_tracks_and_a_name(self):
        self.assertEqual(self.score.name, "c-am-vamp-4s")
        self.assertEqual([track.index for track in self.score.tracks], [0, 1, 2, 3])

    def test_repeated_notes_become_one_hold(self):
        bass = self.score.track(0)
        self.assertEqual([(segment.start, segment.end, segment.note) for segment in bass.segments],
                         [(0, 16, 55), (16, 32, 57)])

    def test_a_track_fills_every_tick_of_the_bar(self):
        for index in range(4):
            self.assertEqual(len(self.score.targets(index)), score.TICKS)
            self.assertNotIn(0, self.score.targets(index))

    def test_the_two_chords_are_the_ones_in_the_score(self):
        bar = {index: {self.score.targets(index)[start] for start in (0, 16)} for index in range(4)}
        self.assertEqual(bar, {0: {55, 57}, 1: {60}, 2: {58, 60}, 3: {65}})
        self.assertEqual([self.score.targets(3)[8], self.score.targets(3)[24]], [67, 67])

    def test_wrong_tick_count_is_named(self):
        document = {"schema": 1, "name": "x", "bpm": 120, "ticks": 16,
                    "tracks": [{"track": 0, "notes": [[0, 55]]}]}
        with self.assertRaises(score.ScoreError) as caught:
            score.parse(document)
        self.assertIn("32", str(caught.exception))

    def test_a_tempo_the_recorder_cannot_force_is_refused(self):
        document = {"schema": 1, "name": "x", "bpm": 100, "ticks": 32,
                    "tracks": [{"track": 0, "notes": [[0, 55]]}]}
        with self.assertRaises(score.ScoreError) as caught:
            score.parse(document)
        self.assertIn("120", str(caught.exception))

    def test_a_note_the_rom_cannot_play_is_refused(self):
        document = {"schema": 1, "name": "x", "bpm": 120, "ticks": 32,
                    "tracks": [{"track": 0, "notes": [[0, 59]]}]}
        with self.assertRaises(score.ScoreError) as caught:
            score.parse(document)
        self.assertIn("59", str(caught.exception))

    def test_ticks_must_ascend(self):
        document = {"schema": 1, "name": "x", "bpm": 120, "ticks": 32,
                    "tracks": [{"track": 0, "notes": [[8, 55], [4, 57]]}]}
        with self.assertRaises(score.ScoreError):
            score.parse(document)

    def test_a_tick_past_the_bar_is_refused(self):
        document = {"schema": 1, "name": "x", "bpm": 120, "ticks": 32,
                    "tracks": [{"track": 0, "notes": [[32, 55]]}]}
        with self.assertRaises(score.ScoreError):
            score.parse(document)

    def test_the_same_track_twice_is_refused(self):
        document = {"schema": 1, "name": "x", "bpm": 120, "ticks": 32,
                    "tracks": [{"track": 0, "notes": [[0, 55]]}, {"track": 0, "notes": [[0, 57]]}]}
        with self.assertRaises(score.ScoreError):
            score.parse(document)

    def test_a_broken_file_says_which_file(self):
        path = SCORE_DIR / "not-a-score.json"
        path.write_text("{ not json", encoding="utf-8")
        try:
            with self.assertRaises(score.ScoreError) as caught:
                score.load(path)
            self.assertIn("not-a-score", str(caught.exception))
        finally:
            path.unlink()

    def test_every_shipped_score_loads(self):
        for path in sorted(SCORE_DIR.glob("*.json")):
            score.load(path)


class JudgeTest(unittest.TestCase):
    def setUp(self):
        self.score = score.load(SCORE_DIR / "c-am-vamp-4s.json")
        self.target = self.score.targets(2)

    def test_a_take_that_follows_the_score_scores_full_marks(self):
        report = score.judge(contour_of(self.target), self.target)
        self.assertEqual((report.ok, report.engaged, report.ticks), (32, 32, 32))
        self.assertEqual(report.fraction(), "32/32")

    def test_one_wrong_height_names_that_tick(self):
        contour = contour_of(self.target)
        contour[5] = LEVEL[67]
        report = score.judge(contour, self.target)
        self.assertEqual(report.ok, 31)
        self.assertEqual(report.wrong, (5,))

    def test_a_tick_without_a_hand_is_a_miss_not_a_skip(self):
        contour = contour_of(self.target)
        contour[9] = 0
        report = score.judge(contour, self.target)
        self.assertEqual(report.ok, 31)
        self.assertEqual(report.engaged, 31)

    def test_a_short_take_counts_its_missing_tail(self):
        report = score.judge(contour_of(self.target)[:20], self.target)
        self.assertEqual(report.ok, 20)
        self.assertEqual(len(report.wrong), 12)


class ShippedScoreTest(unittest.TestCase):
    def test_the_json_on_disk_is_the_piece_that_was_reviewed(self):
        document = json.loads((SCORE_DIR / "c-am-vamp-4s.json").read_text(encoding="utf-8"))
        self.assertEqual([entry["notes"] for entry in document["tracks"]],
                         [[[0, 55], [8, 55], [16, 57], [24, 57]],
                          [[0, 60], [8, 60], [16, 60], [24, 60]],
                          [[0, 58], [8, 62], [16, 60], [24, 62]],
                          [[0, 65], [8, 67], [16, 65], [24, 67]]])


if __name__ == "__main__":
    unittest.main()
