"""The Chinese chrome: pure functions only, no window and no board."""

import unittest

from host.v2_console import params, telemetry
from host.v2_console.ui import theme, zh


class FakeRoot:
    """Only the one call ``theme.px`` makes."""

    def __init__(self, dpi):
        self._dpi = dpi

    def winfo_fpixels(self, _unit):
        return self._dpi


class TestStrings(unittest.TestCase):
    def test_a_missing_key_is_returned_so_the_paint_loop_never_raises(self):
        self.assertEqual(zh.t("no.such.key"), "no.such.key")

    def test_known_key_formats_its_arguments(self):
        self.assertEqual(zh.t("status.frames", 17), "17 帧")

    def test_mode_names_cover_every_rtl_mode(self):
        for mode in range(7):
            self.assertNotEqual(zh.mode_name(mode), str(mode))

    def test_every_parameter_and_field_has_a_chinese_name(self):
        for addr, param in params.PARAMS.items():
            self.assertIn(addr, zh.PARAM_NAMES)
            for field in param.fields:
                self.assertNotEqual(
                    zh.field_name(addr, field.name), field.name,
                    "%s %s has no translation" % (hex(addr), field.name),
                )

    def test_every_parameter_with_a_danger_note_has_a_chinese_one(self):
        for addr, param in params.PARAMS.items():
            if param.danger:
                self.assertTrue(zh.danger_name(addr), "%s" % hex(addr))


class TestDisplayWords(unittest.TestCase):
    def test_wave_names_are_translated(self):
        word = params.PARAMS[0x44].fields[-1]
        self.assertEqual(params.display(0x44, "wave", 3 << word.shift), "square")
        self.assertEqual(zh.localize(params.display(0x44, "wave", 3 << word.shift)), "方波")

    def test_units_keep_their_symbols(self):
        text = zh.localize(params.display(0x88, "delay", 462))
        self.assertIn("采样", text)
        self.assertIn("463", text)


class TestPixelScale(unittest.TestCase):
    def test_a_96_dpi_screen_gets_the_written_size(self):
        self.assertEqual(theme.px(FakeRoot(96.0), 10), 10)

    def test_a_144_dpi_screen_gets_one_and_a_half_times(self):
        self.assertEqual(theme.px(FakeRoot(144.0), 10), 15)

    def test_never_returns_zero_for_a_tiny_size(self):
        self.assertGreaterEqual(theme.px(FakeRoot(96.0), 0), 1)


class TestTelemetryStillStarts(unittest.TestCase):
    def test_the_buffer_reports_waiting_before_the_first_frame(self):
        buffer = telemetry.TelemetryBuffer()
        self.assertTrue(buffer.waiting())
        self.assertEqual(buffer.trail(10), [])


if __name__ == "__main__":
    unittest.main()
