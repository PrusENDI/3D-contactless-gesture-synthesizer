#!/usr/bin/env python3
"""Turn N captured gestures into N phase-aligned wavetable frames.

Each input is a 1024-point single-cycle table (int16 little endian), as produced
by host/wavetable_from_capture.py.  The morph engine crossfades adjacent frames,
so every frame's fundamental must start at phase 0; otherwise the midpoint of a
blend partially cancels and the sweep sounds thin.

    python host/wavetable_frames.py --in a.bin b.bin c.bin --out-dir frames --period 20
    python host/wavetable_frames.py --selftest
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

N_POINTS = 1024
PEAK = int(0.9 * 32767)


def fundamental(samples: list[float]) -> tuple[float, float]:
    """DFT bin 1 of one cycle: sum s[k] * exp(-j*2*pi*k/N)."""
    n = len(samples)
    re = 0.0
    im = 0.0
    for k, value in enumerate(samples):
        angle = 2.0 * math.pi * k / n
        re += value * math.cos(angle)
        im -= value * math.sin(angle)
    return re, im


def align_phase(samples: list[int]) -> list[int]:
    """Rotate the cycle so the fundamental starts at phase 0.

    A pure delay by d samples multiplies bin 1 by exp(-j*2*pi*d/N), so
    d = theta*N/(2*pi) removes the measured phase.  The shift is fractional; a
    linear interpolation of a <=32-harmonic cycle attenuates the top harmonic by
    less than 1%.
    """
    n = len(samples)
    re, im = fundamental(samples)
    if abs(re) < 1e-9 and abs(im) < 1e-9:
        rotated = [float(v) for v in samples]
    else:
        shift = math.atan2(im, re) * n / (2.0 * math.pi)
        rotated = []
        for k in range(n):
            x = (k - shift) % n
            i0 = int(math.floor(x))
            frac = x - i0
            i1 = (i0 + 1) % n
            rotated.append(samples[i0] * (1.0 - frac) + samples[i1] * frac)

    mean = sum(rotated) / n
    rotated = [v - mean for v in rotated]
    peak = max(abs(v) for v in rotated) or 1.0
    scaled = [v * (PEAK / peak) for v in rotated]
    return [max(-32768, min(32767, int(round(v)))) for v in scaled]


def lfo_step(period_seconds: float) -> int:
    """Position units per sample for one 0 -> 2.0 sweep in `period_seconds`."""
    if period_seconds <= 0:
        raise ValueError("period must be > 0")
    step = int(round((2 ** 25) / (period_seconds * 48000.0)))
    return max(1, min(0x7FFFFF, step))


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def selftest() -> int:
    n = N_POINTS
    frames = [
        [int(0.9 * 32767 * math.sin(2 * math.pi * k / n + ph)) for k in range(n)]
        for ph in (0.0, 1.0, 2.5)
    ]
    out = [align_phase(f) for f in frames]
    for i, f in enumerate(out):
        re, im = fundamental(f)
        ang = math.atan2(im, re)
        assert abs(ang) < 0.02, f"frame {i} phase {ang}"
        assert max(abs(v) for v in f) <= PEAK + 1, f"frame {i} peak"
    assert align_phase(frames[0]) == align_phase(frames[0]), "not deterministic"
    assert lfo_step(20.0) == 35 and lfo_step(1.0) == 699, "lfo step"
    print("WAVETABLE_FRAMES SELFTEST PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inputs", nargs=3, help="three 1024-point int16 tables")
    ap.add_argument("--out-dir", help="output directory for frame0..2.bin")
    ap.add_argument("--period", type=float, default=20.0, help="LFO seconds for one 0->2 sweep")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.inputs or not args.out_dir:
        print("XX  --in (three files) and --out-dir are required (or use --selftest)")
        return 1

    os.makedirs(args.out_dir, exist_ok=True)
    meta = {"lfo_step": lfo_step(args.period), "frames": []}
    for index, path in enumerate(args.inputs):
        raw = open(path, "rb").read()
        if len(raw) != N_POINTS * 2:
            print("XX  %s has %d bytes, expected %d" % (path, len(raw), N_POINTS * 2))
            return 1
        samples = [int.from_bytes(raw[i:i + 2], "little", signed=True) for i in range(0, len(raw), 2)]
        aligned = align_phase(samples)
        payload = b"".join(int(v).to_bytes(2, "little", signed=True) for v in aligned)
        out_path = os.path.join(args.out_dir, "frame%d.bin" % index)
        with open(out_path, "wb") as fh:
            fh.write(payload)
        re, im = fundamental(aligned)
        meta["frames"].append({
            "path": out_path, "crc16": crc16_ccitt_false(payload),
            "peak": max(abs(v) for v in aligned),
            "fundamental_rad": round(math.atan2(im, re), 6),
        })
    with open(os.path.join(args.out_dir, "frames.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    sys.exit(main())
