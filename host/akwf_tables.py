"""AKWF single cycles (CC0) -> three board frames and a preset.

The first set of tables was built from harmonic recipes, and that is exactly
where "they all sound like the same instrument" came from: a recipe is a
spectrum, and a spectrum without a body is a saw with a different name.  The
Adventure Kid collection is ~600 single cycles recorded from real instruments
and synths, released **CC0**, and mirrored as 1024-sample C headers
(``DatanoiseTV/AKWF_WaveForms_1024``).  One cycle of a real flute carries its
breath and its formants in the phase, which no recipe reproduces.

What this script does with one downloaded cycle:

1. picks the wave out of its family (a family holds ~100 waves; see ``--top``);
2. band-limits it to a harmonic count, because the table is played at up to
   392 Hz and harmonic 60+ would fold back as alias fizz;
3. makes three phase-aligned frames by scaling the harmonics of the *same*
   cycle (bright / body / dark), so the morph engine crossfades instead of
   cancelling;
4. writes ``artifacts/wt/instruments/<name>/frame{0,1,2}.bin`` and a preset
   whose nine words leave the filter and LFO off: the point is to hear the
   table, not the preset's opinions.

    python host/akwf_tables.py --list
    python host/akwf_tables.py --family eorgan --family flute --top 3
    python host/akwf_tables.py --all

Source and licence: https://github.com/DatanoiseTV/AKWF_WaveForms_1024
(the collection is CC0 1.0, see ``artifacts/akwf/LICENSE-CC0.txt``).
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CACHE = REPO / "artifacts" / "akwf"
TABLE_DIR = REPO / "artifacts" / "wt" / "instruments"
PRESET_DIR = REPO / "host" / "presets"

SOURCE = "https://raw.githubusercontent.com/DatanoiseTV/AKWF_WaveForms_1024/master/"
N_POINTS = 1024
SOURCE_POINTS = 1025          # the mirror keeps one extra sample (the cycle closes)
PEAK = int(0.9 * 32767)
MAX_HARMONIC = 512

# What "worth a preset" means numerically: enough harmonics under 33 to have a
# body, few enough that G4 does not fold the top of them back as alias.
INTENT = {"rich_min": 8, "rich_max": 26, "rich_target": 16}

# The families worth trying first: an organ and an electric piano are additive
# and calm, a flute and a violin are real bodies, an oboe is the reedy edge, and
# vgame is the bright chiptune one.  Each name is the header in the mirror.
FAMILIES = {
    "eorgan": "AKWF_eorgan.h",
    "epiano": "AKWF_epiano.h",
    "flute": "AKWF_flute.h",
    "violin": "AKWF_violin.h",
    "oboe": "AKWF_oboe.h",
    "cello": "AKWF_cello.h",
    "vgame": "AKWF_vgame.h",
    "fmsynth": "AKWF_fmsynth.h",
    "theremin": "AKWF_theremin.h",
    "clavinet": "AKWF_clavinet.h",
    "ebass": "AKWF_ebass.h",
    "hvoice": "AKWF_hvoice.h",
    "squ": "AKWF_squ.h",
    "saw": "AKWF_saw.h",
    "tri": "AKWF_tri.h",
    "sin": "AKWF_sin.h",
    "symetric": "AKWF_symetric.h",
}

# Per family: the three frame tilts and the envelope the preset starts with.
#   e = 0x94 (attack << 16 | decay), s = 0x98 (release << 16 | sustain)
SHAPES = {
    "eorgan":   {"tilt": (40, 26, 14), "e": (1 << 16) | 1, "s": (8 << 16) | 52428},
    "epiano":   {"tilt": (40, 26, 14), "e": (4 << 16) | 24, "s": (40 << 16) | 26214},
    "flute":    {"tilt": (28, 18, 10), "e": (64 << 16) | 128, "s": (12 << 16) | 49152},
    "violin":   {"tilt": (34, 22, 12), "e": (12 << 16) | 24, "s": (6 << 16) | 55705},
    "oboe":     {"tilt": (30, 20, 11), "e": (32 << 16) | 64, "s": (14 << 16) | 49152},
    "cello":    {"tilt": (34, 22, 12), "e": (12 << 16) | 20, "s": (5 << 16) | 55705},
    "vgame":    {"tilt": (40, 28, 16), "e": (1 << 16) | 1, "s": (6 << 16) | 55705},
    "fmsynth":  {"tilt": (36, 24, 13), "e": (2 << 16) | 4, "s": (16 << 16) | 39321},
    "theremin": {"tilt": (24, 16, 9),  "e": (40 << 16) | 96, "s": (10 << 16) | 52428},
    "clavinet": {"tilt": (40, 26, 14), "e": (2 << 16) | 16, "s": (24 << 16) | 39321},
    "ebass":    {"tilt": (30, 20, 11), "e": (4 << 16) | 12, "s": (24 << 16) | 45875},
    "hvoice":   {"tilt": (30, 20, 11), "e": (20 << 16) | 40, "s": (10 << 16) | 52428},
    "squ":      {"tilt": (40, 28, 16), "e": (1 << 16) | 1, "s": (6 << 16) | 55705},
    "saw":      {"tilt": (34, 24, 13), "e": (2 << 16) | 2, "s": (8 << 16) | 55705},
    "tri":      {"tilt": (24, 16, 9),  "e": (2 << 16) | 2, "s": (8 << 16) | 55705},
    "sin":      {"tilt": (8, 6, 4),    "e": (1 << 16) | 1, "s": (8 << 16) | 59000},
    "symetric": {"tilt": (34, 24, 13), "e": (2 << 16) | 2, "s": (8 << 16) | 55705},
}


# ------------------------------------------------------------------ fetching


def header_path(family: str) -> Path:
    if family not in FAMILIES:
        raise KeyError("%s is not one of the families: %s"
                       % (family, ", ".join(sorted(FAMILIES))))
    return CACHE / FAMILIES[family]


def fetch(family: str, timeout: int = 60) -> Path:
    """Download one header into the cache if it is not there yet."""
    path = header_path(family)
    if path.exists() and path.stat().st_size > 1024:
        return path
    import urllib.request

    path.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(SOURCE + FAMILIES[family], timeout=timeout) as reply:
        data = reply.read()
    path.write_bytes(data)
    return path


def read_license() -> Path:
    """Keep the CC0 text next to the raw data: the presets cite it."""
    path = CACHE / "LICENSE-CC0.txt"
    if not path.exists():
        import urllib.request

        url = ("https://raw.githubusercontent.com/"
               "KristofferKarlAxelEkstrand/AKWF-FREE/master/LICENSE.md")
        with urllib.request.urlopen(url, timeout=60) as reply:
            path.write_bytes(reply.read())
    return path


# -------------------------------------------------------------------- parsing


def parse(text: str) -> list[tuple[str, list[int]]]:
    """``const int16_t AKWF_x_0001[1025] = { ... };`` blocks, in file order."""
    out: list[tuple[str, list[int]]] = []
    name = ""
    body: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("const ") and "[" in line and "=" in line:
            name = line.split()[2].split("[")[0]
            body = [line.split("{", 1)[1]] if "{" in line else []
            if "}" in line:                       # a one-line array
                out.append((name, _numbers(" ".join(body))))
                name, body = "", []
            continue
        if not name:
            continue
        if "}" in line:
            body.append(line.split("}", 1)[0])
            out.append((name, _numbers(" ".join(body))))
            name, body = "", []
        else:
            body.append(line)
    return out


def _numbers(text: str) -> list[int]:
    return [int(token) for token in text.replace(";", " ").replace(",", " ").split()]


def read_family(family: str) -> list[tuple[str, list[int]]]:
    return parse(fetch(family).read_text(encoding="ascii", errors="replace"))


# ------------------------------------------------------------------ analysis


def _fft(values) -> list[complex]:
    """Iterative radix-2, in place on a copy."""
    n = len(values)
    a = [complex(v) for v in values]
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    length = 2
    while length <= n:
        angle = -2.0 * math.pi / length
        step = complex(math.cos(angle), math.sin(angle))
        for start in range(0, n, length):
            w = 1.0 + 0.0j
            half = length // 2
            for k in range(start, start + half):
                even = a[k]
                odd = a[k + half] * w
                a[k] = even + odd
                a[k + half] = even - odd
                w *= step
        length <<= 1
    return a


def _ifft(values) -> list[complex]:
    n = len(values)
    out = _fft([v.conjugate() for v in values])
    return [v.conjugate() / n for v in out]


def cycle(samples) -> list[float]:
    """The 1024-point cycle, DC removed; the mirror's 1025th sample is dropped."""
    values = [float(v) for v in samples[:N_POINTS]]
    mean = sum(values) / len(values)
    return [v - mean for v in values]


def spectrum(values) -> list[float]:
    return [abs(v) for v in _fft(values)[:N_POINTS // 2 + 1]]


def features(samples) -> dict:
    """What decides whether a cycle is worth a preset (see :func:`score`)."""
    values = cycle(samples)
    bins = spectrum(values)
    total = sum(v * v for v in bins[1:]) or 1e-9
    peak = max(abs(v) for v in values) or 1.0
    rms = math.sqrt(sum(v * v for v in values) / len(values)) or 1e-9
    fundamental = bins[1] / (max(bins[1:]) or 1e-9)
    alias = sum(v * v for v in bins[33:]) / total
    positive = sum(1 for v in values if v > 0.0) / len(values)
    # How many harmonics are within 30 dB of the loudest one under 33.  Too few
    # and the wave is a sine with a name; too many and it is a buzz.
    loudest = max(bins[1:33]) or 1e-9
    rich = sum(1 for value in bins[1:33] if value >= loudest * 10.0 ** (-30.0 / 20.0))
    return {
        "fundamental": 20.0 * math.log10(fundamental) if fundamental > 0 else -99.0,
        "alias": alias,
        "crest": peak / rms,
        "dc": sum(samples[:N_POINTS]) / N_POINTS,
        "balance": abs(positive - 0.5),
        "rich": rich,
    }


def score(info: dict) -> float:
    """Higher is better.  Three things this score learned the hard way:

    * a wave whose fundamental is everything is a sine with a name -- the first
      version of this score picked exactly those, and a flute that is a sine is
      why the presets sounded thin (``rich`` now has to be 8..26);
    * a narrow pulse has a strong fundamental and no alias energy either, so
      ``balance`` keeps the duty cycle near 50 % (``squ`` used to pick pulses);
    * anything past harmonic 32 folds back at G4, so ``alias`` is a penalty.
    """
    penalty = 0.0
    penalty += max(0, INTENT["rich_min"] - info["rich"]) * 1.5     # too pure
    penalty += max(0, info["rich"] - INTENT["rich_max"]) * 1.0     # too buzzy
    penalty += max(0.0, info["alias"] - 0.05) * 60.0               # alias fizz
    penalty += max(0.0, info["crest"] - 4.0) * 2.0                 # spiky = harsh
    penalty += max(0.0, info["balance"] - 0.15) * 20.0             # odd duty cycle
    penalty += max(0.0, -9.0 - info["fundamental"]) * 1.0          # no fundamental
    # Among the waves that pass, prefer the middle of the road: a rich spectrum
    # and a smooth envelope.  Without this every acceptable wave ties at 0 and
    # the pick is just "the first one in the file".
    penalty += abs(info["rich"] - INTENT["rich_target"]) * 0.15
    penalty += info["crest"] * 0.20
    return -penalty


def rank(waves) -> list[tuple[float, str, list[int]]]:
    scored = []
    for name, samples in waves:
        if len(samples) < N_POINTS:
            continue
        scored.append((score(features(samples)), name, samples))
    scored.sort(key=lambda item: -item[0])
    return scored


# -------------------------------------------------------------------- frames


def tilt(samples, cutoff: int, order: float = 2.0, limit: float = 4.0):
    """Scale harmonics relative to ``cutoff``, keep the phase.

    ``order > 0`` attenuates above the cutoff, ``order < 0`` lifts it (that is
    what makes a "bright" frame bright instead of merely less dull).  ``limit``
    caps the lift so a quiet top end cannot be pushed into the clipping the
    normalisation would then undo.
    """
    values = cycle(samples)
    bins = _fft(values)
    for k in range(1, N_POINTS // 2 + 1):
        gain = 1.0 if k <= cutoff else (cutoff / k) ** order
        gain = max(0.0, min(limit, gain))
        bins[k] *= gain
        if k != N_POINTS - k:
            bins[N_POINTS - k] *= gain
    bins[0] = 0.0
    return [v.real for v in _ifft(bins)]


def frames(samples, cutoffs) -> list[list[int]]:
    """Bright / body / dark from one cycle, all scaled by the same factor.

    The bright frame lifts what the body keeps, so the morph moves between two
    different spectra rather than between two equal ones (the first version only
    ever attenuated, and on these instrument cycles that changed nothing the ear
    can use).
    """
    bright = tilt(samples, cutoffs[0], order=-1.0)
    body = tilt(samples, cutoffs[1], order=2.0)
    dark = tilt(samples, cutoffs[2], order=2.0)
    cycles = (bright, body, dark)
    peak = max(max(abs(v) for v in values) for values in cycles) or 1.0
    scale = PEAK / peak
    return [[max(-32768, min(32767, int(round(v * scale)))) for v in values]
            for values in cycles]


# -------------------------------------------------------------------- presets


def preset(name: str, family: str, wave: str, table: int = 1) -> dict:
    """``table`` is the *body* frame: with morph off the engine plays one table,
    and the bright frame is the attack, not the sound to judge."""
    shape = SHAPES[family]
    words = {
        "0x40": 0x00000000,        # filter off: judge the table, not a cutoff
        "0x44": 0x00000000,        # no LFO
        "0x84": 0x00150000,
        "0x88": 0xFFFF0000,
        "0x8C": 0x00000000,
        "0x90": 0x00018000,
        "0x94": shape["e"],
        "0x98": shape["s"],
        "0x9C": 0x02000000,
    }
    return {
        "schema": 1,
        "name": name,
        "notes": "%s, one cycle, band-limited to %d/%d/%d harmonics"
                 % (wave, shape["tilt"][0], shape["tilt"][1], shape["tilt"][2]),
        "created": "2026-11-03",
        "source": "AKWF (Adventure Kid, CC0) via DatanoiseTV/AKWF_WaveForms_1024",
        "wavetable": {"table": table, "voice_shift": 2, "morph": False},
        "words": words,
    }


# --------------------------------------------------------------------- build


def build(family: str, index: int = 0, name: str | None = None) -> tuple[str, Path, Path]:
    """Rank the family, take one wave, write its three frames and its preset."""
    waves = read_family(family)
    if not waves:
        raise RuntimeError("%s: no arrays parsed" % FAMILIES[family])
    ranked = rank(waves)
    if index >= len(ranked):
        raise IndexError("%s has %d ranked waves" % (family, len(ranked)))
    _score, wave_name, samples = ranked[index]
    preset_name = name or ("akwf-" + family)
    shape = SHAPES[family]
    block = frames(samples, shape["tilt"])

    out_dir = TABLE_DIR / preset_name
    out_dir.mkdir(parents=True, exist_ok=True)
    for frame_index, values in enumerate(block):
        (out_dir / ("frame%d.bin" % frame_index)).write_bytes(
            struct.pack("<%dh" % N_POINTS, *values))
    target = PRESET_DIR / (preset_name + ".json")
    target.write_text(json.dumps(preset(preset_name, family, wave_name),
                                 indent=2, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    return wave_name, out_dir, target


def list_families() -> None:
    for family in sorted(FAMILIES):
        path = header_path(family)
        if path.exists():
            print("%-10s %5d waves  %s" % (family, len(read_family(family)), path.name))
        else:
            print("%-10s (not downloaded: %s)" % (family, path.name))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true", help="families and wave counts")
    parser.add_argument("--family", action="append", default=[],
                        help="family to build (repeatable)")
    parser.add_argument("--top", type=int, default=0,
                        help="print the N best waves of each family and stop")
    parser.add_argument("--index", type=int, default=0,
                        help="which ranked wave to use (0 = best)")
    parser.add_argument("--all", action="store_true", help="build every family")
    parser.add_argument("--license", action="store_true", help="fetch the CC0 text")
    args = parser.parse_args(argv)

    if args.license:
        print(read_license())
        return 0
    if args.list:
        list_families()
        return 0
    families = sorted(FAMILIES) if args.all else args.family
    if not families:
        parser.error("give --family NAME, --all, --list or --license")

    for family in families:
        waves = read_family(family)
        ranked = rank(waves)
        if args.top:
            print("%s:" % family)
            for position, (value, wave, _samples) in enumerate(ranked[:args.top]):
                print("  %d  %-24s score %7.2f" % (position, wave, value))
            continue
        wave, _out_dir, target = build(family, index=args.index)
        print("%-10s <- %-24s  %s" % (family, wave, target.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
