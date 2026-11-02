"""Frame construction and the CRC the board and the scripts already use."""

import unittest

from host.v2_console import link


class FrameTest(unittest.TestCase):
    def test_crc_selftest_known_value(self):
        # Same check value scripts/board_wt_upload.ps1 asserts before uploading.
        self.assertEqual(link.crc16(b"123456789"), link.CRC_SELFTEST)

    def test_frame_is_eleven_bytes_with_big_endian_payload(self):
        frame = link.build_frame(0x02, 0x68, 0x1234, 7)
        self.assertEqual(len(frame), 11)
        self.assertEqual(frame[:5], bytes([0xA5, 0x02, 0x02, 0x68, 7]))
        self.assertEqual(frame[7:9], bytes([0x12, 0x34]))
        crc = link.crc16(frame[:9])
        self.assertEqual(frame[9:11], bytes([(crc >> 8) & 0xFF, crc & 0xFF]))


if __name__ == "__main__":
    unittest.main()
