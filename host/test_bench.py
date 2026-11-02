"""The burst bench logic, driven by a fake port so the arithmetic is testable."""

import unittest

from host.v2_console import bench
from host.v2_console.link import Link
from host.test_link_fakes import ScriptedPort, reply_frame


def link_with(count, err=0):
    return Link(
        ScriptedPort(chunks=[reply_frame(index + 1, 0, err=err) for index in range(count)]),
        pacing_s=0.0,
        timeout_s=0.05,
    )


class BurstTest(unittest.TestCase):
    def test_clean_burst_reports_every_reply_accepted(self):
        report = bench.run_burst(link_with(32), 32, 320)
        self.assertEqual((report.accepted, report.lost), (32, 0))
        self.assertTrue(report.safe())

    def test_a_refused_word_is_not_counted_as_accepted(self):
        report = bench.run_burst(link_with(8, err=7), 8, 320)
        self.assertEqual(report.accepted, 0)
        self.assertFalse(report.safe())

    def test_recommend_picks_the_fastest_safe_cadence(self):
        reports = [
            bench.BurstReport(8, 500, 8, 0.01, 0),
            bench.BurstReport(8, 320, 8, 0.01, 0),
            bench.BurstReport(8, 200, 5, 0.01, 3),
        ]
        self.assertEqual(bench.recommend(reports), 320)

    def test_recommend_is_none_when_nothing_was_safe(self):
        self.assertIsNone(bench.recommend([bench.BurstReport(8, 200, 5, 0.01, 3)]))


if __name__ == "__main__":
    unittest.main()
