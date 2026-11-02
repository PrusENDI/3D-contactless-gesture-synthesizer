"""Preset files: nine register words plus the identity of the sound around them."""

import json
import unittest

from host.v2_console import presets


class SeedTest(unittest.TestCase):
    def test_seed_words_are_the_board_tune_script_values(self):
        # Copied verbatim from scripts/board_tune.ps1:38-43.
        self.assertEqual(presets.BOARD_TUNE_SEED["warm"][0x40], 0x01048120)
        self.assertEqual(presets.BOARD_TUNE_SEED["flat"][0x90], 0x00010000)
        self.assertEqual(presets.BOARD_TUNE_SEED["pluck"][0x88], 0x500000FF)

    def test_files_on_disk_carry_the_script_words(self):
        for name, words in presets.BOARD_TUNE_SEED.items():
            loaded = presets.load(presets.preset_path(name))
            self.assertEqual(loaded.words, words, name)


class RoundTripTest(unittest.TestCase):
    def test_roundtrip_keeps_the_document_identical(self):
        with open(presets.preset_path("warm"), encoding="utf-8") as handle:
            document = json.load(handle)
        self.assertEqual(presets.to_json(presets.from_json(document)), document)

    def test_missing_parameter_is_rejected(self):
        with open(presets.preset_path("warm"), encoding="utf-8") as handle:
            document = json.load(handle)
        del document["words"]["0x94"]
        with self.assertRaises(presets.PresetError) as caught:
            presets.from_json(document)
        self.assertIn("0x94", str(caught.exception))

    def test_lowercase_hex_keys_are_accepted(self):
        # Hand-edited files are exactly the Review Focus case; the key case must not decide.
        with open(presets.preset_path("warm"), encoding="utf-8") as handle:
            document = json.load(handle)
        document["words"] = {key.lower(): value for key, value in document["words"].items()}
        self.assertEqual(presets.from_json(document).words, presets.BOARD_TUNE_SEED["warm"])

    def test_out_of_mask_word_is_reported_not_silently_kept(self):
        with open(presets.preset_path("warm"), encoding="utf-8") as handle:
            document = json.load(handle)
        document["words"]["0x9C"] = 0x0000FFFF
        with self.assertRaises(presets.PresetError) as caught:
            presets.from_json(document)
        self.assertIn("0x9C", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
