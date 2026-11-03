"""The OLED framebuffer packing: bit order, page order, PGM input, RTL output.

The panel's layout is the one thing that cannot be debugged by looking at the
code later, so it is pinned here: bit 0 is the top pixel, page 0 holds rows
0..7, and the RTL that holds the bytes is generated from the same list.
"""

import tempfile
import unittest
from pathlib import Path

from host import oled_image as oled


def rows_of(pattern):
    """64 x 128 rows, lit where ``pattern(x, y)`` is true."""
    return [[1 if pattern(x, y) else 0 for x in range(oled.WIDTH)]
            for y in range(oled.HEIGHT)]


class PackingTest(unittest.TestCase):
    def test_the_top_row_is_bit_zero_of_every_column(self):
        frame = oled.from_rows(rows_of(lambda x, y: y == 0))
        self.assertEqual(frame[0], 0x01)
        self.assertEqual(frame[oled.WIDTH - 1], 0x01)
        self.assertEqual(set(frame[oled.WIDTH:]), {0})   # nothing leaked

    def test_the_second_row_is_bit_one(self):
        frame = oled.from_rows(rows_of(lambda x, y: y == 1))
        self.assertEqual(frame[0], 0x02)

    def test_row_eight_starts_page_one_not_bit_eight(self):
        frame = oled.from_rows(rows_of(lambda x, y: y == 8))
        self.assertEqual(frame[0], 0x00)
        self.assertEqual(frame[1 * oled.WIDTH], 0x01)

    def test_eight_rows_of_one_column_make_0xff(self):
        frame = oled.from_rows(rows_of(lambda x, y: x == 5))
        self.assertEqual(frame[5], 0xFF)
        self.assertEqual(len(frame), oled.SIZE)
        self.assertEqual(sum(1 for byte in frame if byte), oled.PAGES)

    def test_a_dark_frame_is_1024_zero_bytes(self):
        frame = oled.blank()
        self.assertEqual(len(oled.to_bytes(frame)), 1024)
        self.assertEqual(set(frame), {0})

    def test_a_wrong_size_frame_is_refused(self):
        with self.assertRaises(ValueError):
            oled.to_bytes([0] * 1000)
        with self.assertRaises(ValueError):
            oled.from_rows([[0] * oled.WIDTH] * 63)

    def test_the_round_trip_keeps_every_pixel(self):
        frame = oled.from_rows(rows_of(lambda x, y: (x * 7 + y * 3) % 5 == 0))
        self.assertEqual(oled.from_rows(oled.to_rows(frame)), frame)


class PreviewTest(unittest.TestCase):
    def test_preview_is_64_rows_of_128_characters(self):
        lines = oled.preview(oled.blank()).splitlines()
        self.assertEqual(len(lines), 64)
        self.assertEqual({len(line) for line in lines}, {128})

    def test_preview_shows_ink_where_the_frame_has_ink(self):
        frame = oled.from_rows(rows_of(lambda x, y: y == 10 and x < 4))
        lines = oled.preview(frame).splitlines()
        self.assertEqual(lines[10][:4], "####")
        self.assertEqual(lines[10][4], ".")


class LoadTest(unittest.TestCase):
    def test_a_pgm_is_thresholded_and_padded(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "tiny.pgm"
            path.write_bytes(b"P5\n3 2\n255\n" + bytes([0, 200, 128, 127, 255, 1]))
            frame = oled.load_frame(path)
        rows = oled.to_rows(frame)
        self.assertEqual(len(frame), oled.SIZE)
        self.assertEqual(rows[0][:3], [0, 1, 1])     # > 127 is ink, 128 is ink
        self.assertEqual(rows[1][:3], [0, 1, 0])
        self.assertEqual(sum(sum(row) for row in rows), 3)

    def test_a_pgm_with_a_comment_parses(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "commented.pgm"
            path.write_bytes(b"P5\n# made by hand\n2 1\n255\n" + bytes([0, 255]))
            frame = oled.load_frame(path)
        self.assertEqual(oled.to_rows(frame)[0][:2], [0, 1])

    def test_a_truncated_pgm_names_the_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "short.pgm"
            path.write_bytes(b"P5\n4 4\n255\n" + bytes([0, 1]))
            with self.assertRaises(ValueError) as caught:
                oled.load_frame(path)
            self.assertIn("short.pgm", str(caught.exception))

    def test_an_unknown_extension_is_refused(self):
        with self.assertRaises(ValueError):
            oled.load_rows(Path("picture.tiff-fake"))


class OutputTest(unittest.TestCase):
    def test_mem_is_one_hex_byte_per_line(self):
        frame = oled.blank()
        frame[0] = 0x5A
        with tempfile.TemporaryDirectory() as folder:
            path = oled.write_mem(frame, Path(folder) / "logo.mem")
            lines = path.read_text(encoding="ascii").splitlines()
        self.assertEqual(len(lines), 1024)
        self.assertEqual(lines[0], "5a")
        self.assertEqual(lines[1], "00")

    def test_rtl_assigns_all_1024_bytes_and_is_lf_only(self):
        frame = oled.blank()
        frame[0] = 0x81
        text = oled.render_rtl(frame)
        self.assertIn("mem[   0] = 8'h81;", text)
        self.assertIn("mem[1023] = 8'h00;", text)
        self.assertIn('ram_style = "block"', text)
        self.assertIn("always_ff @(posedge clk) data <= mem[addr];", text)
        self.assertEqual(text.count(" = 8'h"), 1024)
        self.assertNotIn("\r", text)
        self.assertFalse(text.startswith("\ufeff"))
        self.assertTrue(text.endswith("endmodule\n"))

    def test_the_demo_frames_have_ink_and_a_border(self):
        frame = oled.demo_lissajous()
        self.assertEqual(len(frame), oled.SIZE)
        rows = oled.to_rows(frame)
        self.assertTrue(rows[0][0] and rows[0][127])       # top border corners
        self.assertTrue(rows[63][0] and rows[63][127])     # bottom corners
        self.assertGreater(sum(sum(row) for row in rows), 200)
        checker = oled.to_rows(oled.demo_checker())
        self.assertNotEqual(checker[1][1], checker[1][9])  # cells alternate


class SelftestTest(unittest.TestCase):
    def test_the_built_in_selftest_passes(self):
        oled.selftest()                                    # raises on failure


if __name__ == "__main__":
    unittest.main()
