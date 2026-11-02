"""Preset files: nine register words plus the identity of the sound around them.

The patch bank was removed from the RTL (0x48-0x5C now NACK), so a preset can only
live on the host. Words are stored raw -- never slider positions -- so a file can
be replayed without the UI and compared against a read-back byte for byte.

The four seed presets are the ones scripts/board_tune.ps1 already applies on the
board; they are imported, not re-derived.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from .params import PARAM_ADDRS, PARAMS

PRESET_DIR = Path(__file__).resolve().parent.parent / "presets"

# Verbatim from scripts/board_tune.ps1:38-43 (f/l/a/b/c/v/e/s/m in that order).
BOARD_TUNE_SEED: dict[str, dict[int, int]] = {
    "warm": {
        0x40: 0x01048120,
        0x44: 0x030C015E,
        0x84: 0x00110000,
        0x88: 0x600001FF,
        0x8C: 0x00003000,
        0x90: 0x00018000,
        0x94: 0x00400040,
        0x98: 0x00108CCD,
        0x9C: 0x02000000,
    },
    "pluck": {
        0x40: 0x01060138,
        0x44: 0x03080258,
        0x84: 0x00190000,
        0x88: 0x500000FF,
        0x8C: 0x00002800,
        0x90: 0x00018000,
        0x94: 0x00200400,
        0x98: 0x00204CCD,
        0x9C: 0x02000000,
    },
    "space": {
        0x40: 0x01028114,
        0x44: 0x032004C8,
        0x84: 0x001C0000,
        0x88: 0x700003FF,
        0x8C: 0x40002E66,
        0x90: 0x00014000,
        0x94: 0x00200020,
        0x98: 0x0008599A,
        0x9C: 0x02000000,
    },
    "flat": {
        0x40: 0x00000000,
        0x44: 0x00000000,
        0x84: 0x00150000,
        0x88: 0xFFFF0000,
        0x8C: 0x00000000,
        0x90: 0x00010000,
        0x94: 0x01001000,
        0x98: 0x0400C000,
        0x9C: 0x02000000,
    },
}

_SEED_NOTES = {
    "warm": "low-pass ci=288 res=72, 350 mHz triangle LFO depth 12, slow attack/release, dry, volume 1.5",
    "pluck": "ci=312 res=96, fast attack, short decay, 256-sample slap with 0.31 feedback, volume 1.5",
    "space": "ci=276 res=40, 1.2 Hz LFO depth 32, level 3 comb -- clips to DC with four tracks, use it on few voices",
    "flat": "every default, for A/B against the raw sound",
}


class PresetError(ValueError):
    """A preset file that cannot be applied without lying about what it stores."""


@dataclass
class Preset:
    name: str
    notes: str = ""
    created: str = ""
    bitstream: dict = field(default_factory=dict)
    wavetable: dict = field(default_factory=dict)
    words: dict[int, int] = field(default_factory=dict)
    schema: int = 1


def preset_path(name: str) -> Path:
    return PRESET_DIR / ("%s.json" % name)


def to_json(preset: Preset) -> dict:
    return {
        "schema": preset.schema,
        "name": preset.name,
        "notes": preset.notes,
        "created": preset.created,
        "bitstream": dict(preset.bitstream),
        "wavetable": dict(preset.wavetable),
        "words": {"0x%02X" % addr: preset.words[addr] for addr in PARAM_ADDRS},
    }


def from_json(document: dict) -> Preset:
    raw_words = document.get("words", {})
    # Hand-edited files are the case this validation exists for, so the key's case
    # must not decide whether a word is found.
    by_address = {}
    for key, value in raw_words.items():
        try:
            by_address[int(str(key), 16)] = int(value)
        except (TypeError, ValueError):
            raise PresetError("%r is not a hexadecimal register address" % (key,)) from None
    words: dict[int, int] = {}
    for addr in PARAM_ADDRS:
        key = "0x%02X" % addr
        if addr not in by_address:
            raise PresetError("preset has no word for %s" % key)
        value = by_address[addr]
        if value < 0 or value > 0xFFFFFFFF:
            raise PresetError("%s is not a 32-bit word: %d" % (key, value))
        outside = value & ~PARAMS[addr].mask
        if outside:
            raise PresetError(
                "%s has bits outside its write mask 0x%08X (0x%08X); the board would NACK it"
                % (key, PARAMS[addr].mask, outside)
            )
        words[addr] = value
    for addr in by_address:
        if addr not in PARAM_ADDRS:
            raise PresetError("0x%02X is not one of the nine parameter registers" % addr)
    return Preset(
        name=str(document.get("name", "")),
        notes=str(document.get("notes", "")),
        created=str(document.get("created", "")),
        bitstream=dict(document.get("bitstream", {})),
        wavetable=dict(document.get("wavetable", {})),
        words=words,
        schema=int(document.get("schema", 1)),
    )


def load(path: Path) -> Preset:
    with open(path, encoding="utf-8") as handle:
        return from_json(json.load(handle))


def save(preset: Preset, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(to_json(preset), handle, ensure_ascii=False, indent=2)
        handle.write("\n")
