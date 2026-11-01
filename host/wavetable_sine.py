#!/usr/bin/env python3
"""Write one 1024-point wavetable frame as int16 little endian.

The board uploader (`scripts/board_wt_upload.ps1 -Bin ...`) reads exactly this
layout: 1024 samples, int16, little endian, no header.

    python host/wavetable_sine.py --out artifacts/wt/voice_sine.bin
    python host/wavetable_sine.py --out artifacts/wt/voice_square.bin --wave square
"""
import argparse
import math
import os
import struct

FS = 32767


def sample(wave, i, n, amplitude):
    phase = 2.0 * math.pi * i / n
    if wave == "sine":
        value = math.sin(phase)
    elif wave == "square":
        value = 1.0 if math.sin(phase) >= 0.0 else -1.0
    elif wave == "saw":
        value = 2.0 * (i / n) - 1.0
    else:
        raise SystemExit("unknown wave %r" % wave)
    return int(round(amplitude * FS * value))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--wave", default="sine", choices=("sine", "square", "saw"))
    ap.add_argument("--points", type=int, default=1024)
    ap.add_argument("--amplitude", type=float, default=0.9)
    args = ap.parse_args()

    data = b"".join(struct.pack("<h", sample(args.wave, i, args.points, args.amplitude))
                    for i in range(args.points))
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(data)
    print("%s: %d samples, %d bytes, %s at %.2f FS"
          % (args.out, args.points, len(data), args.wave, args.amplitude))


if __name__ == "__main__":
    main()
