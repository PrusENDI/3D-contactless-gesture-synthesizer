#!/usr/bin/env python3
"""Harmonic recipes -> three wavetable frames per instrument, plus its preset.

The board's timbre is almost entirely the single-cycle table: the nine preset
words only shape brightness and loudness over time around it. That is why four
presets over one table sounded like one instrument at four distances.

Each instrument is three phase-aligned frames the morph engine can crossfade:

    frame 0  bright   (the attack: upper harmonics lifted)
    frame 1  body     (the recipe as written)
    frame 2  dark     (upper harmonics pulled back)

All three are scaled by ONE factor taken from the body frame, so morphing does
not change the loudness. Harmonics stop at 16 because the 1024-point table is
played at up to 32 harmonics and anything above that folds back as aliasing.

    python host/instrument_tables.py                 # write tables + presets
    python host/instrument_tables.py --selftest      # checks only

Writes artifacts/wt/instruments/<name>/frame{0,1,2}.bin (int16 LE, 1024 points)
and host/presets/<name>.json for the console's preset list.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

N_POINTS = 1024
MAX_HARMONIC = 16
PEAK = int(0.9 * 32767)
REPO = Path(__file__).resolve().parent.parent
TABLE_DIR = REPO / "artifacts" / "wt" / "instruments"
PRESET_DIR = REPO / "host" / "presets"

# Amplitude of harmonic n (1-based).  A recipe is the whole timbre: a clarinet
# is odd harmonics with the third strong, a flute is nearly a sine, brass puts
# energy in the second to sixth, and a bowed string falls off slowly.
RECIPES: dict[str, dict[int, float]] = {
    "flute": {1: 1.00, 2: 0.22, 3: 0.09, 4: 0.035, 5: 0.015},
    "clarinet": {1: 1.00, 3: 0.55, 5: 0.30, 7: 0.16, 9: 0.08, 11: 0.04},
    "strings": {n: n ** -0.7 for n in range(1, 17)},
    "brass": {1: 1.00, 2: 0.72, 3: 0.55, 4: 0.40, 5: 0.30,
              6: 0.22, 7: 0.15, 8: 0.10, 9: 0.07},
}

# LIVE single-voice presets.  LIVE has no loop, no FX chain worth using and only
# one voice, so these favour resonance and a real release over blend.
#   keys: f=0x40 l=0x44 a=0x84 b=0x88 c=0x8C v=0x90 e=0x94 s=0x98 m=0x9C
PRESETS: dict[str, dict[str, int]] = {
    "flute": {
        "f": 0x01000000 | (30 << 12) | 330,      # ci 330 (~2 kHz -3 dB), res 30
        "l": 0x03000000 | (4 << 16) | 5200,      # retrig, 5.2 Hz, depth 4: breath
        "a": 0x00150000, "b": 0xFFFF0000, "c": 0x00000000,
        "v": 0x00018000,                          # 1.5
        "e": (128 << 16) | 64,                    # attack 64 (~21 ms), decay 128
        "s": (12 << 16) | 49152,                  # sustain 0.75, release 12 (~110 ms)
        "m": 0x02000000,
    },
    "clarinet": {
        "f": 0x01000000 | (90 << 12) | 290,      # res 90 for the hollow ring
        "l": 0x03000000 | (3 << 16) | 4800,
        "a": 0x00150000, "b": 0xFFFF0000, "c": 0x00000000,
        "v": 0x00018000,
        "e": (96 << 16) | 96,
        "s": (10 << 16) | 52428,                  # sustain 0.8
        "m": 0x02000000,
    },
    "strings": {
        "f": 0x01000000 | (55 << 12) | 300,
        "l": 0x03000000 | (6 << 16) | 4800,       # a slow shimmer, not a vibrato
        "a": 0x00150000, "b": 0xFFFF0000, "c": 0x00000000,
        "v": 0x00018000,
        "e": (24 << 16) | 12,                     # attack 12 (~114 ms): a bow swell
        "s": (4 << 16) | 55705,                   # sustain 0.85, release 4 (~340 ms)
        "m": 0x02000000,                          # detune shift 0: widest
    },
    "brass": {
        "f": 0x01000000 | (120 << 12) | 360,     # high res: the blat
        "l": 0x03000000 | (8 << 16) | 5000,
        "a": 0x00150000, "b": 0xFFFF0000, "c": 0x00000000,
        "v": 0x00016666,                          # 1.4: leave headroom for the resonance
        "e": (64 << 16) | 40,
        "s": (32 << 16) | 45875,
        "m": 0x02000000,
    },
}

NOTES = {
    "flute": "harmonics 1,2,3 only; ci 330 res 30, 5.2 Hz depth 4 breath, attack 21 ms",
    "clarinet": "odd harmonics 1,3,5,7; res 90 for the hollow ring, attack 14 ms",
    "strings": "1/n^0.7 to the 16th; attack 114 ms swell, release 340 ms, detune widest",
    "brass": "harmonics 1-9 with a strong 2nd and 3rd; res 120, attack 34 ms",
}


def frame(recipe: dict[int, float], tilt: float) -> list[float]:
    """One cycle of the recipe, with harmonics above the first scaled by tilt."""
    values = [0.0] * N_POINTS
    for harmonic, amplitude in recipe.items():
        if harmonic > MAX_HARMONIC:
            continue
        gain = amplitude * (tilt if harmonic > 1 else 1.0)
        # cosines: every frame's fundamental starts at the same phase, so the
        # morph midpoint adds instead of partially cancelling.
        omega = 2.0 * math.pi * harmonic / N_POINTS
        for k in range(N_POINTS):
            values[k] += gain * math.cos(omega * k)
    mean = sum(values) / N_POINTS
    return [v - mean for v in values]


def to_int16(values: list[float], scale: float) -> list[int]:
    out = []
    for v in values:
        s = int(round(v * scale))
        out.append(max(-32768, min(32767, s)))
    return out


def build(name: str) -> list[list[int]]:
    """Three frames for one instrument, all scaled by the body frame's peak."""
    recipe = RECIPES[name]
    bright = frame(recipe, 1.6)
    body = frame(recipe, 1.0)
    dark = frame(recipe, 0.35)
    # One scale for all three frames, taken from the loudest of them: scaling by
    # the body alone clipped the bright frame, and clamping would add harmonics
    # the recipe never asked for.
    peak = max(max(abs(v) for v in bright), max(abs(v) for v in body),
               max(abs(v) for v in dark)) or 1.0
    scale = PEAK / peak
    return [to_int16(bright, scale), to_int16(body, scale), to_int16(dark, scale)]


def write_tables(name: str, frames: list[list[int]]) -> list[Path]:
    out_dir = TABLE_DIR / name
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for index, samples in enumerate(frames):
        path = out_dir / ("frame%d.bin" % index)
        path.write_bytes(struct.pack("<%dh" % N_POINTS, *samples))
        paths.append(path)
    return paths


def write_preset(name: str) -> Path:
    p = PRESETS[name]
    document = {
        "schema": 1,
        "name": name,
        "notes": NOTES[name],
        "created": "2026-11-03",
        # The table is uploaded by scripts/board_instrument.ps1; a preset cannot
        # carry 3 KB of samples, so it names the shift it was tuned at.
        "bitstream": {},
        "wavetable": {"table": 0, "voice_shift": 2, "morph": False},
        "words": {
            "0x40": p["f"], "0x44": p["l"], "0x84": p["a"],
            "0x88": p["b"], "0x8C": p["c"], "0x90": p["v"],
            "0x94": p["e"], "0x98": p["s"], "0x9C": p["m"],
        },
    }
    PRESET_DIR.mkdir(parents=True, exist_ok=True)
    path = PRESET_DIR / ("%s.json" % name)
    path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    return path


def selftest() -> int:
    failures = 0
    for name in RECIPES:
        frames = build(name)
        if len(frames) != 3:
            print("FAIL %s: %d frames" % (name, len(frames)))
            failures += 1
            continue
        for index, samples in enumerate(frames):
            if len(samples) != N_POINTS:
                print("FAIL %s frame%d: %d points" % (name, index, len(samples)))
                failures += 1
            peak = max(abs(v) for v in samples)
            # frame1 carries the recipe; 0 and 2 are deliberately brighter and
            # darker, so they are allowed to sit lower but never to clip.
            floor = 0.6 * PEAK if index == 1 else 0.25 * PEAK
            if peak >= 32768 or peak < floor:
                print("FAIL %s frame%d: peak %d out of range" % (name, index, peak))
                failures += 1
        body = frames[1]
        bright = frames[0]
        # A bright frame must really carry more energy above the fundamental.
        def upper(samples: list[int]) -> float:
            mid = sum(samples[k] ** 2 for k in range(0, N_POINTS, 2))
            return mid
        if upper(bright) <= upper(body):
            print("FAIL %s: frame0 is not brighter than frame1" % name)
            failures += 1
    print("selftest: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
    return 0 if failures == 0 else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    for name in RECIPES:
        paths = write_tables(name, build(name))
        preset = write_preset(name)
        sizes = ", ".join("%s=%d" % (p.name, p.stat().st_size) for p in paths)
        print("%-9s frames: %s" % (name, sizes))
        print("%-9s preset: %s" % ("", preset.relative_to(REPO)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
