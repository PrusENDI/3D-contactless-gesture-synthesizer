"""Measure the write-path burst cadence on the board.

    python scripts/gui_burst_bench.py --port COM4 --count 1024

Writes zero samples to WT_DATA at three cadences and reports how many the board
accepted. It never APPLYs and never changes WT_SELECT, but it does overwrite the
shadow copy of whatever table is loaded -- re-upload before using that table.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.v2_console import bench  # noqa: E402
from host.v2_console.link import Link, LinkLost  # noqa: E402
from host.v2_console.serial_port import SerialPort  # noqa: E402

CADENCES_US = (320, 400, 500)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=1_000_000)
    parser.add_argument("--count", type=int, default=1024)
    parser.add_argument("--pacing-us", type=int, nargs="*", default=list(CADENCES_US))
    args = parser.parse_args()

    port = SerialPort(args.port, args.baud)
    link = Link(port, timeout_s=0.5)
    try:
        board_id = link.command(0x01, 0xB0).data
        print("0xB0=0x%08X" % board_id)
        if board_id != 0x5A5A0003:
            print("wrong bitstream; refusing to measure")
            return 3
        reports = []
        for pacing_us in args.pacing_us:
            # The loader advances its own pointer on every WT_DATA write, so put it
            # back to 0 before each cadence; otherwise the burst walks off the end.
            link.command(0x02, 0x64, 0)
            try:
                report = bench.run_burst(link, args.count, pacing_us)
            except LinkLost as exc:
                print("pacing=%d us: %s" % (pacing_us, exc))
                continue
            reports.append(report)
            print(
                "pacing=%4d us  accepted=%4d/%d  elapsed=%.3f s  %.0f cmd/s  lost=%d"
                % (report.pacing_us, report.accepted, report.count, report.elapsed_s,
                   report.rate_per_s(), report.lost)
            )
        best = bench.recommend(reports)
        print("safe cadence: %s" % ("%d us" % best if best else "none -- keep one-at-a-time"))
        return 0 if best else 4
    finally:
        port.close()


if __name__ == "__main__":
    raise SystemExit(main())
