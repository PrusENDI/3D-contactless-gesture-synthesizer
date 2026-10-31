#!/usr/bin/env python3
"""Solve a captured hand trajectory into a 1024-point wavetable.

The board captures one swipe and streams cursor x/y over UART; this turns that
stream into one cycle of a wavetable, the same way the PC reference does it
("time de-normalisation"): the phase coordinate is built from the trajectory
itself, the amplitude is taken from the pitch axis, and the result is resampled
to 1024 points, DC-free, peak-normalised and band-limited to 32 harmonics.

    python host/wavetable_from_capture.py --in xy.jsonl --out lead.bin --phase arc
    python host/wavetable_from_capture.py --selftest

Only the standard library is used, so this runs anywhere the repo's other
scripts run.
"""

from __future__ import annotations

import argparse
import json
import math
import sys

N_POINTS = 1024
PEAK = int(0.9 * 32767)          # 29490
HARMONICS = 32
DEADZONE_COUNTS = 40.0           # ~3x the measured sensor jitter (10-13 counts)
IIR_ALPHA = 0.35
MEDIAN_WINDOW = 5
AXES = ("x", "y")


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def _median(values: list[float], window: int) -> list[float]:
    half = window // 2
    out = []
    for i in range(len(values)):
        lo, hi = max(0, i - half), min(len(values), i + half + 1)
        chunk = sorted(values[lo:hi])
        out.append(chunk[len(chunk) // 2])
    return out


def _smooth(values: list[float]) -> list[float]:
    """Median first (kills single-frame spikes), then a one-pole low pass."""
    med = _median(values, MEDIAN_WINDOW)
    out = [med[0]]
    for value in med[1:]:
        out.append(out[-1] + IIR_ALPHA * (value - out[-1]))
    return out


def _arc_phase(xs: list[float], ys: list[float], deadzone: float) -> list[float]:
    """Cumulative walked distance, with a deadzone so a resting hand adds none."""
    acc = [0.0]
    for i in range(1, len(xs)):
        step = math.hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1])
        acc.append(acc[-1] + (step if step >= deadzone else 0.0))
    span = acc[-1]
    if span <= 0.0:
        return [0.0] * len(xs)
    return [value / span for value in acc]


def _interp(phase: list[float], values: list[float], targets: list[float]) -> list[float]:
    out = []
    j = 0
    for target in targets:
        while j + 1 < len(phase) and phase[j + 1] < target:
            j += 1
        p0, p1 = phase[j], phase[min(j + 1, len(phase) - 1)]
        v0, v1 = values[j], values[min(j + 1, len(values) - 1)]
        ratio = 0.0 if p1 <= p0 else (target - p0) / (p1 - p0)
        ratio = min(1.0, max(0.0, ratio))
        out.append(v0 + (v1 - v0) * ratio)
    return out


def _band_limit(samples: list[float], harmonics: int) -> list[float]:
    """Keep harmonics 0..harmonics-1 (DC handled separately), zero the rest."""
    n = len(samples)
    re = [0.0] * n
    im = [0.0] * n
    for k in range(harmonics + 1):                       # DC + 32 harmonics
        cr = ci = 0.0
        for t, sample in enumerate(samples):
            angle = 2.0 * math.pi * k * t / n
            cr += sample * math.cos(angle)
            ci -= sample * math.sin(angle)
        re[k], im[k] = cr / n * 2.0, ci / n * 2.0
    re[0] /= 2.0
    im[0] = 0.0
    out = []
    for t in range(n):
        total = re[0]
        for k in range(1, harmonics + 1):
            angle = 2.0 * math.pi * k * t / n
            total += re[k] * math.cos(angle) - im[k] * math.sin(angle)
        out.append(total)
    return out


def solve(xs, ys, phase: str = "arc", axis: str = "y", n: int = N_POINTS,
          deadzone: float = DEADZONE_COUNTS) -> list[int]:
    if len(xs) < 4:
        raise ValueError("need at least 4 samples")
    sx, sy = _smooth([float(v) for v in xs]), _smooth([float(v) for v in ys])
    if phase == "arc":
        coord = _arc_phase(sx, sy, deadzone)
    elif phase == "time":
        coord = [i / (len(sx) - 1) for i in range(len(sx))]
    elif phase == "x":
        lo, hi = min(sx), max(sx)
        if hi - lo <= 0.0:
            raise ValueError("x is constant, cannot use --phase x")
        coord = [(v - lo) / (hi - lo) for v in sx]
        for i in range(1, len(coord)):
            if coord[i] + 1e-9 < coord[i - 1]:
                raise ValueError("x is not monotonic; use --phase arc or time")
    else:
        raise ValueError("unknown phase mode: %r" % phase)

    amp = sy if axis == "y" else sx
    raw = _interp(coord, amp, [k / n for k in range(n)])

    mean = sum(raw) / n
    raw = [v - mean for v in raw]
    peak = max(abs(v) for v in raw) or 1.0
    raw = [v * (PEAK / peak) for v in raw]

    limited = _band_limit(raw, HARMONICS)
    peak = max(abs(v) for v in limited) or 1.0
    return [int(round(v * (PEAK / peak))) for v in limited]


def _selftest() -> int:
    n = 400
    xs = [i / (n - 1) for i in range(n)]
    ys = [0.5 + 0.4 * math.sin(2 * math.pi * i / n) for i in range(n)]

    table = solve(xs, ys, phase="x")
    assert len(table) == 1024, "length"
    mean = sum(table) / len(table)
    assert abs(mean) < 1.0, "dc %r" % mean
    peak = max(abs(v) for v in table)
    assert abs(peak - PEAK) <= 1, "peak %r" % peak
    assert solve(xs, ys, phase="x") == table, "not deterministic"

    # The table must reproduce the drawn shape: compare against the ideal cycle.
    ideal = [math.sin(2 * math.pi * k / 1024) for k in range(1024)]
    num = sum(a * b for a, b in zip(table, ideal))
    den = math.sqrt(sum(a * a for a in table) * sum(b * b for b in ideal))
    corr = num / den
    assert corr > 0.99, "correlation %r" % corr

    # Band limit: everything above harmonic 32 must be far down.
    energy_hi = 0.0
    energy_lo = 0.0
    for k in range(1, 256):
        cr = ci = 0.0
        for t in range(0, 1024, 2):
            angle = 2.0 * math.pi * k * t / 1024
            cr += table[t] * math.cos(angle)
            ci -= table[t] * math.sin(angle)
        power = cr * cr + ci * ci
        if k <= 32:
            energy_lo += power
        else:
            energy_hi += power
    ratio_db = 10.0 * math.log10(max(energy_hi, 1e-12) / max(energy_lo, 1e-12))
    assert ratio_db < -60.0, "harmonic leakage %r dB" % ratio_db

    print("PASS length=1024 dc=%.3f peak=%d corr=%.4f harmonics=%.1f dB"
          % (mean, peak, corr, ratio_db))
    print("SELFTEST PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", help="JSONL capture with seq/x/y")
    ap.add_argument("--out", help="output table (.bin, 1024 x int16 little endian)")
    ap.add_argument("--phase", choices=("arc", "time", "x"), default="arc")
    ap.add_argument("--axis", choices=AXES, default="y")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()
    if not args.inp or not args.out:
        print("XX  --in and --out are required (or use --selftest)")
        return 1

    xs, ys = [], []
    with open(args.inp, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            xs.append(float(row["x"]))
            ys.append(float(row["y"]))
    if len(xs) < 4:
        print("XX  capture has %d samples, need at least 4" % len(xs))
        return 1

    table = solve(xs, ys, phase=args.phase, axis=args.axis)
    payload = b"".join(int(v).to_bytes(2, "little", signed=True) for v in table)
    with open(args.out, "wb") as fh:
        fh.write(payload)
    meta = {
        "len": len(table), "peak": max(abs(v) for v in table),
        "mean": round(sum(table) / len(table), 3), "harmonics": HARMONICS,
        "phase": args.phase, "axis": args.axis, "samples": len(xs),
        "crc16": crc16_ccitt_false(payload),
    }
    with open(args.out.rsplit(".", 1)[0] + ".json", "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
    print(json.dumps(meta))
    return 0


if __name__ == "__main__":
    sys.exit(main())
