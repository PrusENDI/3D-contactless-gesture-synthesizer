"""The controls the demo storyboard needs: parameter writes, modes, readouts, identity."""

import unittest
from types import SimpleNamespace

from host.v2_console import params
from host.v2_console.views.shell import ConsoleModel


class FakeSession:
    identity = SimpleNamespace(board_id=0x5A5A0003, mode=0)

    def __init__(self, mode=0):
        self.mode = mode
        self.writes = []
        self.regs = {}
        self.readout_data = {}

    def status(self):
        return SimpleNamespace(mode=self.mode, loop_active=False, fault=0)

    def write(self, addr, data):
        self.writes.append((addr, data))
        # The board clamps parameter writes instead of NACKing them.
        self.regs[addr] = params.clamp(addr, data) if addr in params.PARAMS else data & 0xFFFFFFFF
        return SimpleNamespace(nack=False, err=0, data=0)

    def read(self, addr):
        return self.regs.get(addr, 0)

    def set_mode(self, mode):
        self.mode = mode

    def stop(self):
        self.mode = 0

    def read_registers(self):
        return {addr: self.read(addr) for addr in params.PARAM_ADDRS}

    def readouts(self):
        return self.readout_data


class ParamWriteTest(unittest.TestCase):
    def test_set_param_writes_then_reads_the_value_back(self):
        session = FakeSession()
        model = ConsoleModel(session)
        message = model.set_param(0x40, 0x01048120)
        self.assertEqual(session.regs[0x40], 0x01048120)
        self.assertIn("0x40", message)

    def test_a_clamped_value_is_reported_as_such(self):
        session = FakeSession()
        session.regs[0x94] = 0x00000001          # the board clamps attack 0 to 1
        model = ConsoleModel(session)
        message = model.set_param(0x94, 0x00000000)
        self.assertIn("clamp", message.lower())

    def test_out_of_mask_bits_are_refused_before_sending(self):
        session = FakeSession()
        model = ConsoleModel(session)
        with self.assertRaises(ValueError):
            model.set_param(0x9C, 0x0000FFFF)
        self.assertEqual(session.writes, [])

    def test_read_all_params_returns_the_nine_words(self):
        session = FakeSession()
        for addr in params.PARAM_ADDRS:
            session.regs[addr] = addr * 0x01010101 & 0xFFFFFFFF
        words = ConsoleModel(session).read_params()
        self.assertEqual(sorted(words), list(params.PARAM_ADDRS))


class FieldWriteTest(unittest.TestCase):
    def test_moving_one_slider_keeps_the_other_fields_of_that_register(self):
        session = FakeSession()
        session.regs[0x94] = 0x01000000            # decay 0x0100, attack 0
        model = ConsoleModel(session)
        model.read_params()
        model.write_field(0x94, "attack_step", 0x0400)
        self.assertEqual(session.regs[0x94], 0x01000400)


class ModeTest(unittest.TestCase):
    def test_mode_buttons_reach_the_board(self):
        session = FakeSession()
        model = ConsoleModel(session)
        for mode, name in ((1, "LIVE"), (4, "PLAY"), (6, "WT_PLAY")):
            message = model.set_mode(mode)
            self.assertEqual(session.mode, mode)
            self.assertIn(name, message)

    def test_arp_toggle_sets_thresholds_bit_23_and_keeps_low_below_high(self):
        session = FakeSession()
        session.regs[0x30] = (0x1000 << 16) | 60
        model = ConsoleModel(session)
        model.set_arp(True)
        word = session.regs[0x30]
        self.assertTrue((word >> 23) & 1)
        self.assertLess(word & 0xFFFF, (word >> 16) & 0xFFFF)
        self.assertEqual(model.arp_on(), True)

    def test_bpm_is_reported_read_only(self):
        session = FakeSession()
        session.regs[0x08] = 47
        self.assertEqual(ConsoleModel(session).bpm(), 47)


class ReadoutTest(unittest.TestCase):
    def test_readouts_decode_note_gate_and_voice_state(self):
        session = FakeSession()
        session.readout_data = {"note": 0x40, "gate": True, "active": True, "z": 12000,
                                "voices": 3, "steals": 0, "overflow": 0}
        readouts = ConsoleModel(session).readouts()
        self.assertEqual(readouts["note"], 0x40)
        self.assertTrue(readouts["gate"])
        self.assertEqual(readouts["voices"], 3)

    def test_status_line_carries_the_numbers_the_storyboard_shows(self):
        session = FakeSession()
        session.readout_data = {"note": 0x40, "gate": True, "active": True, "z": 12000,
                                "voices": 3, "steals": 0, "overflow": 0}
        model = ConsoleModel(session)
        model.readouts()
        line = model.status_line()
        self.assertIn("voices 3", line)
        self.assertIn("note 64", line)


class IdentityTest(unittest.TestCase):
    def test_identity_shows_the_board_id_and_the_table_version(self):
        session = FakeSession()
        session.regs[0x7C] = 3
        text = ConsoleModel(session).identity_text()
        self.assertIn("5A5A0003", text)
        self.assertIn("v3", text)


if __name__ == "__main__":
    unittest.main()
