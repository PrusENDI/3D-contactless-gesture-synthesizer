"""The nine parameter registers, their clamps and their display units.

Every value here is copied from rtl/v2_contract_pkg.sv (write mask + clamp table)
and docs/host-tools-and-gui-controls.md section 3.7/3.8.
"""

import unittest

from host.v2_console import params


class ClampTest(unittest.TestCase):
    def test_clamp_matches_contract_table(self):
        self.assertEqual(params.clamp(0x40, 0x00000FFF), 0x000001A7)  # ci 0xFFF -> 423
        self.assertEqual(params.clamp(0x40, 0x010FFFFF), 0x010FF1A7)  # nothing outside the mask survives
        self.assertEqual(params.clamp(0x44, 0xFFFFFFFF), 0x3FFF4E20)  # rate -> 20000
        self.assertEqual(params.clamp(0x8C, 0xFFFFFFFF), 0x7FFF7333)  # feedback / reverb-mix ceilings
        self.assertEqual(params.clamp(0x90, 0xFFFFFFFF), 0x00020000)  # volume 2.0
        self.assertEqual(params.clamp(0x94, 0x00000000), 0x00000001)  # attack 0 -> 1, or the voice never rises
        self.assertEqual(params.clamp(0x98, 0x00000000), 0x00010000)  # release 0 -> 1, or the stream deadlocks
        self.assertEqual(params.clamp(0x9C, 0x00000000), 0x00010000)  # glide 0 -> 1

    def test_unknown_address_passes_through(self):
        self.assertEqual(params.clamp(0x00, 0xFFFFFFFF), 0xFFFFFFFF)


class FieldTest(unittest.TestCase):
    def test_every_field_roundtrips(self):
        for addr, param in params.PARAMS.items():
            for field in param.fields:
                value = field.hi if field.hi else field.lo
                word = params.set_field(addr, 0, field.name, value)
                self.assertEqual(params.get_field(addr, field.name, word), value, (hex(addr), field.name))

    def test_setting_a_field_leaves_its_neighbours_alone(self):
        word = params.set_field(0x94, 0x00550000, "attack_step", 0x1234)
        self.assertEqual(params.get_field(0x94, "decay_step", word), 0x0055)
        self.assertEqual(params.get_field(0x94, "attack_step", word), 0x1234)


class DisplayTest(unittest.TestCase):
    def test_cutoff_shows_the_frequency_and_the_effective_corner(self):
        # ci=288: 40 * 2^(288/48) = 2560 Hz, 4-pole -3 dB at 0.43 * fc
        self.assertEqual(params.display(0x40, "ci", 0x120), "2.6 kHz (-3 dB 1.1 kHz)")

    def test_envelope_step_is_a_time(self):
        # 65535 / 4096 / 48 kHz = 0.333 ms
        self.assertEqual(params.display(0x94, "attack_step", 0x1000), "0.33 ms")

    def test_volume_is_a_gain_in_db(self):
        self.assertEqual(params.display(0x90, "volume_q16", 0x18000), "+3.5 dB")
        self.assertEqual(params.display(0x90, "volume_q16", 0x10000), "+0.0 dB")


if __name__ == "__main__":
    unittest.main()
