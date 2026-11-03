"""Unit tests for scripts/synth_report.py.

The build gate (docs/superpowers/specs/2026-11-01-filter-lfo-design.md §6) reads
four numbers out of the place-and-route report.  `scripts/synth.py` used to read
them from the wrong file, print None, and still exit 0, so "the build passed"
meant nothing.  The parsing and the gate live in their own module precisely so
they can be tested without a build.

Run: python -m unittest host.test_synth_report -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

import synth_report  # noqa: E402

# Trimmed copies of the real files, same shape and same numbers as
# impl/v2_board_top_vca_detune_mbox/impl/pnr/v2_board_top.{tr,timing_paths}.
TR = """<Numbers of Setup Violated Endpoints>:1401
<Numbers of Hold Violated Endpoints>:0

NO.                   Clock Name                   Constraint    Actual Fmax   Level   Entity
===== ============================================ ============= ============= ======= ========
1     u_v2/u_clock/u_pll/CLKOUT0.default_gen_clk   80.000(MHz)   63.639(MHz)   18      TOP
u_v2/u_clock/u_pll/CLKOUT0.default_gen_clk   setup           -1691.814       1401
u_v2/u_clock/u_pll/CLKOUT0.default_gen_clk   hold            0.000           0
"""

PATHS = """=====
SETUP
-3.214
18.188
14.974
u_v2/u_v2_uart/frame[3]_7_s0
2.778
3.023
u_v2/u_v2_uart/n5830_s0
=====
SETUP
-3.204
18.178
14.974
u_v2/u_v2_uart/frame[3]_7_s0
2.778
3.023
u_v2/u_v2_uart/n5817_s0
"""


class ParseTiming(unittest.TestCase):
    def test_reads_the_four_numbers(self):
        t = synth_report.parse_timing(TR, PATHS)
        self.assertEqual(t["violations"], 1401)
        self.assertAlmostEqual(t["tns"], -1691.814)
        self.assertEqual(t["endpoints"], 1401)
        self.assertAlmostEqual(t["fmax"], 63.639)
        self.assertAlmostEqual(t["worst_slack"], -3.214)
        self.assertEqual(t["worst_from"], "u_v2/u_v2_uart/frame[3]_7_s0")

    def test_stops_at_the_first_path(self):
        # A second, worse path further down must not overwrite the first one:
        # the report is sorted, so the head is the worst.
        t = synth_report.parse_timing(TR, PATHS)
        self.assertAlmostEqual(t["worst_slack"], -3.214)

    def test_missing_numbers_raise_instead_of_returning_none(self):
        with self.assertRaises(ValueError):
            synth_report.parse_timing("nothing here", PATHS)
        with self.assertRaises(ValueError):
            synth_report.parse_timing(TR, "nothing here")


class ParseResources(unittest.TestCase):
    RPT = """Logic                       | 15793/23040                         |  69%
Register                    | 8733/23280                          |  38%
CLS                         | 10510/11520                         |  92%
BSRAM                       | 37/56                               |  67%
DSP                         | 8/28                                |  29%
"""

    def test_reads_used_and_available(self):
        r = synth_report.parse_resources(self.RPT)
        self.assertEqual(r["cls"], 10510)
        self.assertEqual(r["cls_max"], 11520)
        self.assertEqual(r["dsp"], 8)
        self.assertEqual(r["bsram"], 37)

    def test_missing_cls_raises(self):
        with self.assertRaises(ValueError):
            synth_report.parse_resources(self.RPT.replace("CLS", "XXX"))


class Gate(unittest.TestCase):
    PASS = {"cls": 10900, "cls_max": 11520, "worst_slack": -3.0}

    def test_clean_build_passes(self):
        self.assertEqual(synth_report.gate_fail(self.PASS, max_cls=11300, min_slack=-3.5), [])

    def test_over_cls_fails(self):
        bad = dict(self.PASS, cls=11400)
        self.assertEqual(len(synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5)), 1)

    def test_slack_under_fails(self):
        bad = dict(self.PASS, worst_slack=-5.0)
        self.assertEqual(len(synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5)), 1)

    def test_unknown_slack_is_not_a_pass(self):
        # A build whose timing could not be read must fail the gate, not slip
        # through as if it had no violations.
        bad = {"cls": 10900, "cls_max": 11520, "worst_slack": None}
        self.assertEqual(len(synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5)), 1)

    def test_both_problems_are_reported(self):
        bad = {"cls": 11400, "cls_max": 11520, "worst_slack": -5.0}
        self.assertEqual(len(synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5)), 2)


class GateOnFmax(unittest.TestCase):
    """The demo bitstream gates on fmax; production keeps its old behaviour."""

    PASS = {"cls": 900, "cls_max": 11520, "worst_slack": 1.0, "fmax": 120.0}

    def test_a_low_fmax_fails_when_a_floor_is_set(self):
        bad = dict(self.PASS, fmax=62.7)
        problems = synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5, min_fmax=80.0)
        self.assertEqual(len(problems), 1)
        self.assertIn("62.7", problems[0])

    def test_no_floor_means_no_fmax_problem(self):
        bad = dict(self.PASS, fmax=62.7)
        self.assertEqual(synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5), [])

    def test_unknown_fmax_fails_when_a_floor_is_set(self):
        bad = {"cls": 900, "cls_max": 11520, "worst_slack": 1.0, "fmax": None}
        problems = synth_report.gate_fail(bad, max_cls=11300, min_slack=-3.5, min_fmax=80.0)
        self.assertEqual(len(problems), 1)


class ReadRunFindsItsTop(unittest.TestCase):
    """One run directory, one top, whatever it is called."""

    def _write(self, tmp: str, top: str) -> None:
        pnr = os.path.join(tmp, "impl", "pnr")
        os.makedirs(pnr, exist_ok=True)
        for suffix, body in ((".rpt.txt", ParseResources.RPT), (".tr", TR),
                             (".timing_paths", PATHS)):
            with open(os.path.join(pnr, top + suffix), "w", encoding="utf-8") as fh:
                fh.write(body)

    def test_discovers_the_demo_top(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self._write(tmp, "v2_demo_top")
            summary = synth_report.read_run(tmp)
            self.assertEqual(summary["cls"], 10510)
            self.assertAlmostEqual(summary["fmax"], 63.639)

    def test_two_tops_must_be_disambiguated(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self._write(tmp, "v2_demo_top")
            self._write(tmp, "v2_board_top")
            with self.assertRaises(ValueError):
                synth_report.read_run(tmp)
            summary = synth_report.read_run(tmp, top="v2_board_top")
            self.assertEqual(summary["cls"], 10510)


if __name__ == "__main__":
    unittest.main()
