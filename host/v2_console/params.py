"""The nine parameter registers: fields, clamps and display units.

Values are copied from rtl/v2_contract_pkg.sv (write masks and the clamp table in
``v2_csr_clamp``) and docs/host-tools-and-gui-controls.md sections 3.7 and 3.8.

The board clamps instead of NACKing: a write inside the mask always succeeds, the
value stored may be smaller than the value sent, and only a read-back shows which.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class Field:
    name: str
    shift: int
    width: int
    lo: int
    hi: int
    unit: str

    def mask(self) -> int:
        return ((1 << self.width) - 1) << self.shift


@dataclass(frozen=True)
class Param:
    addr: int
    key: str
    mask: int
    fields: tuple[Field, ...]
    scope: str
    danger: str | None
    default: int

    def field(self, name: str) -> Field:
        for field in self.fields:
            if field.name == name:
                return field
        raise KeyError("%s has no field %s" % (hex(self.addr), name))


def _f(name, shift, width, lo, hi, unit) -> Field:
    return Field(name, shift, width, lo, hi, unit)


PARAMS: dict[int, Param] = {
    0x40: Param(
        addr=0x40,
        key="FILTER",
        mask=0x010FFFFF,
        fields=(
            _f("ci", 0, 12, 0, 423, "ci"),
            _f("res", 12, 8, 0, 255, "res"),
            _f("enable", 24, 1, 0, 1, "flag"),
        ),
        scope="all",
        danger=None,
        default=0x00000000,
    ),
    0x44: Param(
        addr=0x44,
        key="LFO",
        mask=0x3FFFFFFF,
        fields=(
            _f("rate_mhz", 0, 16, 0, 20000, "mhz"),
            _f("depth", 16, 8, 0, 255, "ci_depth"),
            _f("enable", 24, 1, 0, 1, "flag"),
            _f("retrig", 25, 1, 0, 1, "flag"),
            _f("unipolar", 26, 1, 0, 1, "flag"),
            _f("wave", 27, 3, 0, 7, "wave"),
        ),
        scope="all",
        danger=None,
        default=0x00000000,
    ),
    0x84: Param(
        addr=0x84,
        key="FX_A",
        mask=0x001FFFFF,
        fields=(
            _f("gain_q16", 0, 18, 0, 0x10000, "q16"),
            _f("level", 18, 2, 0, 3, "fx_level"),
            _f("enable", 20, 1, 0, 1, "flag"),
        ),
        scope="play",
        danger="gain 0 silences PLAY",
        default=0x00150000,
    ),
    0x88: Param(
        addr=0x88,
        key="FX_B",
        mask=0xFFFF03FF,
        fields=(
            _f("delay", 0, 10, 0, 1023, "samples"),
            _f("cutoff_q16", 16, 16, 0, 0xFFFF, "q16"),
        ),
        scope="play",
        danger=None,
        default=0xFFFF0000,
    ),
    0x8C: Param(
        addr=0x8C,
        key="FX_C",
        mask=0xFFFFFFFF,
        fields=(
            _f("feedback_q15", 0, 16, 0, 0x7333, "q15"),
            _f("reverb_mix_q15", 16, 16, 0, 0x7FFF, "q15"),
        ),
        scope="play",
        danger="feedback >= 1.0 runs away",
        default=0x00000000,
    ),
    0x90: Param(
        addr=0x90,
        key="VOLUME",
        mask=0x0003FFFF,
        fields=(_f("volume_q16", 0, 18, 0, 0x20000, "volume"),),
        scope="all",
        danger=None,
        default=0x00010000,
    ),
    0x94: Param(
        addr=0x94,
        key="ENV_AD",
        mask=0xFFFFFFFF,
        fields=(
            _f("attack_step", 0, 16, 1, 0xFFFF, "step"),
            _f("decay_step", 16, 16, 0, 0xFFFF, "step"),
        ),
        scope="play",
        danger="attack 0 never rises",
        default=0x01001000,
    ),
    0x98: Param(
        addr=0x98,
        key="ENV_SR",
        mask=0xFFFFFFFF,
        fields=(
            _f("sustain_level", 0, 16, 0, 0xFFFF, "q16"),
            _f("release_step", 16, 16, 1, 0xFFFF, "step"),
        ),
        scope="play",
        danger="release 0 deadlocks the event stream",
        default=0x0400C000,
    ),
    0x9C: Param(
        addr=0x9C,
        key="VOICE_MIX",
        mask=0xFFFF000F,
        fields=(
            _f("velocity_shift", 0, 2, 0, 3, "shift"),
            _f("detune_shift", 2, 2, 0, 3, "shift"),
            _f("glide_rate", 16, 16, 1, 0xFFFF, "glide"),
        ),
        scope="play",
        danger="glide 0 pins offset notes",
        default=0x02000000,
    ),
}

PARAM_ADDRS: tuple[int, ...] = tuple(sorted(PARAMS))


def _param(addr: int) -> Param:
    try:
        return PARAMS[addr]
    except KeyError:
        raise KeyError("0x%02X is not one of the nine parameter registers" % addr) from None


def get_field(addr: int, name: str, word: int) -> int:
    field = _param(addr).field(name)
    return (word >> field.shift) & ((1 << field.width) - 1)


def set_field(addr: int, word: int, name: str, value: int) -> int:
    field = _param(addr).field(name)
    cleared = word & ~field.mask()
    return cleared | ((value << field.shift) & field.mask())


def clamp(addr: int, word: int) -> int:
    """Mirror of ``v2_csr_clamp``: clamp inside the mask, then drop everything outside."""
    if addr not in PARAMS:
        return word
    clamped = word
    for field in PARAMS[addr].fields:
        value = (clamped >> field.shift) & ((1 << field.width) - 1)
        value = min(max(value, field.lo), field.hi)
        clamped = set_field(addr, clamped, field.name, value)
    return clamped & PARAMS[addr].mask


# -- display ---------------------------------------------------------------

_WAVE_NAMES = ("triangle", "sine", "saw", "square", "sample&hold")
_FX_LEVELS = ("dry", "+lowpass", "+delay", "+comb")


def display(addr: int, name: str, word: int) -> str:
    """Human-readable value for one field, with the unit the spec uses."""
    value = get_field(addr, name, word)
    unit = _param(addr).field(name).unit
    if unit == "ci":
        fc = 40.0 * 2.0 ** (value / 48.0)
        corner = 0.43 * fc
        return "%.1f kHz (-3 dB %.1f kHz)" % (fc / 1000.0, corner / 1000.0)
    if unit == "ci_depth":
        return "%.1f octaves" % (value * 5.3 / 255.0)
    if unit == "mhz":
        return "%.2f Hz" % (value / 1000.0)
    if unit == "step":
        if value == 0:
            return "inf"
        return "%.2f ms" % (65535.0 / value / 48.0) if value > 100 else "%.0f ms" % (65535.0 / value / 48.0)
    if unit in ("q16", "volume", "q15"):
        scale = 65535.0 if unit == "q15" else 65536.0
        ratio = value / scale
        db = 20.0 * math.log10(ratio) if ratio > 0 else float("-inf")
        if unit == "volume":
            return "%+.1f dB" % db
        return "%.0f%%%s" % (ratio * 100.0, (" (%+.1f dB)" % db) if ratio > 0 else "")
    if unit == "wave":
        return _WAVE_NAMES[value] if value < len(_WAVE_NAMES) else "wave %d" % value
    if unit == "fx_level":
        return _FX_LEVELS[value] if 0 <= value < len(_FX_LEVELS) else "level %d" % value
    if unit == "samples":
        return "%d samples" % (value + 1)
    if unit == "shift":
        return "shift %d" % value
    if unit == "glide":
        return "rate %d" % value
    if unit == "flag":
        return "on" if value else "off"
    if unit == "res":
        return "res %d" % value
    return str(value)
