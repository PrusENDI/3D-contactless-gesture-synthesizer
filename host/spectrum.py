#!/usr/bin/env python3
"""Count the spectral peaks of a GAO capture.

The demo bitstream plays N sine tones on 220*k Hz.  The evidence is a capture of
the I2S transmitter's own sample register at 48 kHz: 2048 points, 42.7 ms,
23.4 Hz per bin, so adjacent tones are nine bins apart.

    python host/spectrum.py --csv artifacts/gao/demo32.csv --expect 32
    python host/spectrum.py --csv artifacts/gao/demo1.csv --expect 1 --column muted

The input is Gowin's raw capture file (a "Data:" header line, then rows of
"time_us, value, ..." with hex values); this tool does not resample by time --
the capture clock IS the 48 kHz frame clock, so row order is sample order.

Standard library only: the repository's host tools do not depend on numpy.
"""

from __future__ import annotations

import argparse
import cmath
import math
import sys

SAMPLE_RATE = 48_000.0
TONE_STEP_HZ = 220.0


def read_capture(path: str, column: str | None = None, bits: int = 16) -> tuple[list[float], str]:
    """Return (samples, column name) from a Gowin GAO csv.

    Values are hex in the file and two's complement for signed buses, which is
    what the I2S sample register is.
    """
    with open(path, encoding="utf-8-sig", errors="replace") as fh:
        lines = [ln.rstrip("\r\n") for ln in fh]

    data_at = None
    for index, line in enumerate(lines):
        if line.strip().startswith("Data:"):
            data_at = index
            break
    if data_at is None:
        raise ValueError("%s has no 'Data:' section; is it a GAO capture?" % path)

    header = [cell.strip() for cell in lines[data_at + 1].split(",")]
    while header and header[-1] == "":
        header.pop()
    names = header[1:]
    if not names:
        raise ValueError("%s has an empty column header" % path)

    index = None
    if column is not None:
        for position, name in enumerate(names):
            if column in name:
                index = position
                break
        if index is None:
            raise ValueError("no column matches %r; columns are %s"
                             % (column, ", ".join(names)))
    else:
        index = len(names) - 1

    samples: list[float] = []
    sign = 1 << (bits - 1)
    span = 1 << bits
    for line in lines[data_at + 2:]:
        if not line.strip():
            continue
        fields = [cell.strip() for cell in line.split(",")]
        if fields and fields[-1] == "":
            fields.pop()
        if len(fields) < index + 2:
            continue
        raw = fields[index + 1]
        if raw in ("", "x", "z"):
            continue
        value = int(raw, 16) & (span - 1)
        if value & sign:
            value -= span
        samples.append(float(value))

    if not samples:
        raise ValueError("%s holds no sample rows" % path)
    return samples, names[index]


def windowed(samples: list[float]) -> list[float]:
    """Hann window; without it the neighbouring tones leak into each other."""
    n = len(samples)
    if n < 2:
        return list(samples)
    return [samples[i] * 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (n - 1)))
            for i in range(n)]


def fft(values: list[complex]) -> list[complex]:
    """Iterative radix-2 FFT; the length must be a power of two."""
    n = len(values)
    if n & (n - 1):
        raise ValueError("FFT length %d is not a power of two" % n)
    out = list(values)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    length = 2
    while length <= n:
        step = cmath.exp(-2j * math.pi / length)
        for start in range(0, n, length):
            w = 1 + 0j
            for offset in range(length // 2):
                even = out[start + offset]
                odd = out[start + offset + length // 2] * w
                out[start + offset] = even + odd
                out[start + offset + length // 2] = even - odd
                w *= step
        length <<= 1
    return out


def power_spectrum(samples: list[float]) -> list[float]:
    """Magnitude squared for bins 0..n/2-1 of the windowed signal."""
    n = len(samples)
    transform = fft([complex(v, 0.0) for v in windowed(samples)])
    return [abs(transform[k]) ** 2 for k in range(n // 2)]


def find_peaks(samples: list[float], sample_rate: float = SAMPLE_RATE,
               floor: float = 0.05, max_peaks: int = 64) -> list[tuple[float, float]]:
    """Local maxima above `floor` of the tallest peak, strongest first."""
    n = len(samples)
    if n & (n - 1):
        n = 1 << (n.bit_length() - 1)
        samples = samples[:n]
    if n < 64:
        raise ValueError("need at least 64 samples, got %d" % n)
    power = power_spectrum(samples)
    tallest = max(power[1:])
    if tallest <= 0:
        return []
    found: list[tuple[float, float]] = []
    for k in range(1, len(power) - 1):
        if power[k] >= power[k - 1] and power[k] > power[k + 1] and power[k] >= floor * tallest:
            freq = k * sample_rate / n
            found.append((freq, power[k] / tallest))
    found.sort(key=lambda item: item[0])
    return found[:max_peaks]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", required=True, help="GAO capture (raw gowin csv)")
    parser.add_argument("--column", default=None,
                        help="substring of the value column (default: the last one)")
    parser.add_argument("--bits", type=int, default=16, help="bus width of that column")
    parser.add_argument("--fs", type=float, default=SAMPLE_RATE,
                        help="sample rate of the capture clock (default 48 kHz)")
    parser.add_argument("--expect", type=int, default=None,
                        help="expected number of tones (220*k Hz)")
    parser.add_argument("--floor", type=float, default=0.05,
                        help="peak threshold, relative to the tallest peak")
    args = parser.parse_args(argv)

    try:
        samples, name = read_capture(args.csv, args.column, args.bits)
    except (OSError, ValueError) as exc:
        print("XX  %s" % exc)
        return 1

    size = 1 << (len(samples).bit_length() - 1)
    peaks = find_peaks(samples, args.fs, args.floor)
    print("capture : %s" % args.csv)
    print("column  : %s" % name)
    print("samples : %d (using %d, %.1f ms at %.0f Hz)"
          % (len(samples), size, 1000.0 * size / args.fs, args.fs))
    print("peaks   : %d" % len(peaks))
    print("  k   expect Hz    found Hz   rel. level")
    for index, (freq, level) in enumerate(peaks[:32], start=1):
        expected = TONE_STEP_HZ * index
        print("  %2d  %9.1f  %9.1f   %8.3f" % (index, expected, freq, level))

    if args.expect is None:
        return 0
    if len(peaks) != args.expect:
        print("XX  %d peaks, expected %d" % (len(peaks), args.expect))
        return 2
    tolerance = 2.0 * args.fs / size
    for index, (freq, _level) in enumerate(peaks, start=1):
        expected = TONE_STEP_HZ * index
        if abs(freq - expected) > tolerance:
            print("XX  peak %d at %.1f Hz, expected %.1f +- %.1f"
                  % (index, freq, expected, tolerance))
            return 2
    print("OK  %d peaks on 220*k Hz" % args.expect)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
