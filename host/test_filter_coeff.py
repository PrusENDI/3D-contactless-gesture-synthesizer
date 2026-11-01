"""Unit tests for the ladder coefficient table and the float gold model.

Two artefacts are pinned here, both from
``docs/superpowers/specs/2026-11-01-filter-lfo-design.md`` 5.2-5.3:

* ``rtl/v2_filter_coeffs.sv`` -- the 1024x16 BSRAM the ladder reads (G[0..511],
  R[512..767]).  It is generated, committed, and must match the formulas here;
  a hand edit is exactly what this test exists to catch.
* ``host/filter_reference.py`` -- the float model Task 5 compares the RTL
  against.  Its -3 dB column has to reproduce the measured table in the spec,
  otherwise the RTL would be "verified" against a wrong reference.

Run: python -m unittest host.test_filter_coeff -v
"""

import math
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import filter_coeff  # noqa: E402
import filter_reference as ref  # noqa: E402

FS = 48000.0
CI_MAX = 423
R_BASE = 512
R_COUNT = 256
MEM_DEPTH = 1024

SV_PATH = os.path.join(HERE, "..", "rtl", "v2_filter_coeffs.sv")


def q16(value):
    """Round a fraction of full scale into 16-bit Q16, half away from zero."""
    return int(math.floor(value + 0.5))


def ideal_fc(ci):
    return 40.0 * 2.0 ** (min(ci, CI_MAX) / 48.0)


def ideal_g(ci):
    q = math.tan(math.pi * ideal_fc(ci) / FS)
    return q16(65536.0 * q / (1.0 + q))


def ideal_r(ridx):
    x = ridx * 0.94 / 255.0
    return q16(65536.0 / (1.0 + x))


class GTable(unittest.TestCase):
    def test_g_is_the_tpt_coefficient(self):
        for ci in range(CI_MAX + 1):
            q = math.tan(math.pi * ideal_fc(ci) / FS)
            self.assertEqual(filter_coeff.g_value(ci), q16(65536.0 * q / (1.0 + q)),
                             "G[%d]" % ci)

    def test_g_matches_the_measured_spec_column(self):
        # spec 5.3 publishes both fc and G; the generator must reproduce them.
        for ci, g_float in ((0, 0.00261), (96, 0.01036), (144, 0.02052),
                            (192, 0.04023), (240, 0.07747), (288, 0.14467),
                            (336, 0.25829), (384, 0.44215), (423, 0.70649)):
            self.assertLessEqual(abs(filter_coeff.g_value(ci) - 65536.0 * g_float), 2.0,
                                 "G[%d] vs spec column" % ci)

    def test_g_is_monotone_and_clamped(self):
        # G rises with ci because it rises with fc: spec 5.3 runs 0.00261 at
        # ci=0 to 0.70649 at ci=423 (the plan text says "decreasing"; the spec
        # column and the formula q/(1+q) both say increasing).
        prev = filter_coeff.g_value(0)
        for ci in range(1, CI_MAX + 1):
            cur = filter_coeff.g_value(ci)
            self.assertGreater(cur, prev, "G must rise with ci, at ci=%d" % ci)
            prev = cur
        top = filter_coeff.g_table()
        self.assertEqual(len(top), 512)
        for ci in range(CI_MAX + 1, len(top)):
            self.assertEqual(top[ci], top[CI_MAX], "ci=%d must clamp to ci=423" % ci)

    def test_g_fits_in_a_16_bit_word(self):
        for ci in range(MEM_DEPTH):
            self.assertGreater(filter_coeff.g_value(ci), 0)
            self.assertLessEqual(filter_coeff.g_value(ci), 0xFFFF)


class RTable(unittest.TestCase):
    def test_r_is_the_reciprocal_table(self):
        table = filter_coeff.r_table()
        self.assertEqual(len(table), R_COUNT)
        self.assertEqual(table[0], 65536)
        self.assertEqual(table[255], ideal_r(255))
        for ridx in range(R_COUNT):
            self.assertEqual(table[ridx], ideal_r(ridx), "R[%d]" % ridx)
        # x = ridx*0.94/255 spans [0, 0.94]; 1/(1+0.94) is the smallest entry.
        self.assertEqual(table[-1], 33781)

    def test_r_is_monotone_decreasing(self):
        table = filter_coeff.r_table()
        for ridx in range(1, R_COUNT):
            self.assertLess(table[ridx], table[ridx - 1], "R[%d]" % ridx)


class Reference(unittest.TestCase):
    def test_reference_matches_the_spec_table(self):
        # spec 5.3, 4-pole -3 dB column, +-5%: the tolerance the plan allows.
        for ci, hz in ((0, 18.0), (96, 70.0), (144, 139.0), (192, 278.0),
                       (240, 557.0), (288, 1120.0), (336, 2290.0),
                       (384, 5060.0), (423, 12300.0)):
            got = ref.minus3db(ci)
            self.assertLessEqual(abs(got - hz) / hz, 0.05,
                                 "minus3db(%d)=%.1f Hz, spec %.0f Hz" % (ci, got, hz))

    def test_reference_rise_stops_at_ci_423(self):
        self.assertAlmostEqual(ref.minus3db(423), ref.minus3db(500), places=6)

    def test_peak_is_about_15db_and_uniform(self):
        # spec 5.2: K=3.75 peaks at +14.0..+15.2 dB, a 1.2 dB spread from
        # 40 Hz to 18 kHz -- the property one-sample feedback lost.
        peaks = [ref.peak_db(ci, 255) for ci in (48, 192, 336)]
        for ci, db in zip((48, 192, 336), peaks):
            self.assertGreaterEqual(db, 14.0, "peak at ci=%d" % ci)
            self.assertLessEqual(db, 15.5, "peak at ci=%d" % ci)
        self.assertLessEqual(max(peaks) - min(peaks), 1.5)

    def test_peak_rises_with_resonance(self):
        # A plain ladder drops its passband gain by 1/(1+K), so the absolute
        # peak is NOT monotone at low res (0 / -3.5 / +0.3 / +14.7 dB for
        # res 0/85/170/255).  The monotone quantity is peak above DC -- the
        # resonance the knob is supposed to add.  Task 5 must measure this one.
        peaks = [ref.peak_db(192, r) for r in (0, 85, 170, 255)]
        self.assertAlmostEqual(peaks[0], 0.0, places=2)
        # 1 Hz is within 2.3e-5 dB of DC, hence places=4 rather than 6.
        self.assertAlmostEqual(ref.ladder_db(192, 85, 1.0), ref.dc_db(192, 85), places=4)
        relative = [ref.peak_db(192, r) - ref.dc_db(192, r) for r in (0, 85, 170, 255)]
        self.assertAlmostEqual(relative[0], 0.0, places=2)
        for low, high in zip(relative, relative[1:]):
            self.assertLess(low, high)
        self.assertGreaterEqual(relative[-1], 20.0, "res=255 must actually resonate")

    def test_emit_tb_prints_the_task5_constants(self):
        text = ref.emit_tb()
        for name, value in (("F_MINUS3DB_CI96_HZ", ref.minus3db(96)),
                            ("F_MINUS3DB_CI192_HZ", ref.minus3db(192)),
                            ("F_MINUS3DB_CI288_HZ", ref.minus3db(288)),
                            ("PEAK_DB_CI48_RES255", ref.peak_db(48, 255)),
                            ("PEAK_DB_CI192_RES255", ref.peak_db(192, 255)),
                            ("PEAK_DB_CI336_RES255", ref.peak_db(336, 255))):
            m = re.search(r"%s\s*=\s*([-\d.]+)" % name, text)
            self.assertIsNotNone(m, "emit_tb is missing %s" % name)
            self.assertAlmostEqual(float(m.group(1)), value, places=1)
        self.assertTrue(text.isascii(), "emit_tb must stay ASCII (cp936 console)")


class EmittedModule(unittest.TestCase):
    def setUp(self):
        with open(SV_PATH, "rb") as fh:
            self.raw = fh.read()
        self.text = self.raw.decode("utf-8")

    def test_file_is_utf8_without_bom_and_lf_only(self):
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"), "BOM in a .sv")
        self.assertNotIn(b"\r", self.raw, "CRLF in a .sv")
        self.assertNotIn("\t", self.text, "tab in a .sv")

    def test_ports_and_registered_read(self):
        body = self.text
        self.assertRegex(body, r"module\s+v2_filter_coeffs\s*\(")
        self.assertRegex(body, r"input\s+logic\s+clk\b")
        self.assertRegex(body, r"input\s+logic\s+\[\s*9\s*:\s*0\s*\]\s+addr\b")
        self.assertRegex(body, r"output\s+logic\s+\[\s*15\s*:\s*0\s*\]\s+dout\b")
        self.assertRegex(body, r"localparam\s+int\s+R_BASE\s*=\s*512\s*;")
        self.assertRegex(body, r"logic\s+\[\s*15\s*:\s*0\s*\]\s+mem\s*\[\s*0\s*:\s*1023\s*\]")
        # Registered read: dout must be clocked, never a bare "assign dout = mem[addr]".
        self.assertRegex(body, r"always_ff\s*@\s*\(\s*posedge\s+clk\s*\)[^;]*dout\s*<=\s*mem\s*\[\s*addr\s*\]")
        self.assertNotRegex(body, r"assign\s+dout\s*=")
        self.assertIn("host/filter_coeff.py", body)
        self.assertIn("must not be edited", body.lower())

    def test_memory_matches_the_generator(self):
        values = {}
        for m in re.finditer(r"mem\s*\[\s*(\d+)\s*\]\s*=\s*16'h([0-9a-fA-F]{4})\s*;", self.text):
            index = int(m.group(1))
            self.assertNotIn(index, values, "mem[%d] assigned twice" % index)
            values[index] = int(m.group(2), 16)
        self.assertEqual(sorted(values), list(range(MEM_DEPTH)),
                         "the initial block must define all 1024 words")
        g = filter_coeff.g_table()
        r = filter_coeff.r_table()
        for index in range(MEM_DEPTH):
            if index < R_BASE:
                want = min(g[index], 0xFFFF)
            elif index < R_BASE + R_COUNT:
                want = min(r[index - R_BASE], 0xFFFF)
            else:
                want = 0
            self.assertEqual(values[index], want, "mem[%d]" % index)

    def test_emit_is_reproducible(self):
        # Re-running the generator must not change a committed byte.
        self.assertEqual(filter_coeff.emit_source(), self.text)


if __name__ == "__main__":
    unittest.main()
