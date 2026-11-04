#!/usr/bin/env python3
"""Switch which of the three wavetable slots the engine reads, and nothing else.

`0x60[1:0]` is the slot and `0x60[7:4]` the voice gain; the nine preset words do
not touch this register, and an upload always ends by writing it for the slot it
wrote.  So "the sound did not change" splits into two very different faults:

    python scripts/board_table.py                 # what is playing now?
    python scripts/board_table.py --table 1       # switch to slot 1
    python scripts/board_table.py --table 0 --check artifacts/wt/instruments/akwf-cello/frame1.bin

`--check` reads a few points of that slot back and compares them with a .bin, so
the answer is "these bytes are in the slot" rather than "it should be".
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, ".")
from host.v2_console import serial_port, link as linkmod  # noqa: E402
from host.v2_console.session import core  # noqa: E402

POINTS = (0, 1, 2, 3, 4, 8, 16, 32, 64, 128, 256, 512, 1023)


def describe(word: int) -> str:
    return "slot %d, gain shift %d, morph %d" % (word & 3, (word >> 4) & 0xF, (word >> 8) & 1)


def read_points(session, points) -> list[int]:
    values = []
    for index in points:
        session.write(0x64, index)
        values.append(session.read(0x68) & 0xFFFF)
    return values


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--table", type=int, choices=(0, 1, 2), help="slot to select")
    parser.add_argument("--shift", type=int, choices=range(16), help="voice gain shift")
    parser.add_argument("--check", type=Path, help=".bin to compare the selected slot with")
    args = parser.parse_args(argv)

    port = serial_port.SerialPort(args.port)
    session = core.Session(linkmod.Link(port))
    word = session.read(0x60)
    print("0x60 = 0x%08X  (%s)" % (word, describe(word)))
    print("0x7C = 0x%08X  (err %d, shadow valid %d, active version %d)"
          % (session.read(0x7C), (session.read(0x7C) >> 24) & 0xFF,
             (session.read(0x7C) >> 16) & 1, session.read(0x7C) & 0xFFFF))

    if args.table is not None or args.shift is not None:
        target = word
        if args.table is not None:
            target = (target & ~0x3) | args.table
        if args.shift is not None:
            target = (target & ~0xF0) | (args.shift << 4)
        session.write(0x60, target)
        word = session.read(0x60)
        print("-> 0x60 = 0x%08X  (%s)" % (word, describe(word)))

    if args.check is not None:
        # 0x68 only hands the host the memory in IDLE; in LIVE it returns the
        # sample the engine is reading right now, which is why the first version
        # of this reported "1/13 points" while the data was fine.
        mode = session.read(0x38) & 0x7
        session.write(0x14, 1)                    # STOP
        session.write(0x04, 0)                    # MODE = IDLE
        want = struct.unpack("<1024h", args.check.read_bytes())
        got = read_points(session, POINTS)
        same = sum(1 for a, b in zip(got, (want[i] & 0xFFFF for i in POINTS)) if a == b)
        print("slot %d vs %s: %d/%d points, first %s"
              % (word & 3, args.check.name, same, len(POINTS),
                 [v & 0xFFFF for v in got[:6]]))
        if mode:
            session.write(0x04, mode)
            print("mode restored to %d" % mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
