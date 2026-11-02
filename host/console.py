#!/usr/bin/env python3
"""MGC3130 synth console.

    python host/console.py --port COM4

One serial owner, four tabs, and a reference bar for blind recording. The window
never changes the board's mode by itself; closing it closes the telemetry stream
and, if the loop is still playing, stops it (design section 8.7).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from v2_console.link import Link, LinkLost  # noqa: E402
from v2_console.session import core  # noqa: E402
from v2_console.views.shell import ConsoleModel, ConsoleWindow  # noqa: E402

TLM_CONTROL = 0x80
TLM_PERIOD = 240          # 200 frames per second, the sensor's own rate


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=1_000_000)
    parser.add_argument("--no-telemetry", action="store_true", help="do not start the cursor stream")
    args = parser.parse_args()

    import serial

    try:
        port = serial.Serial(args.port, args.baud, timeout=0.02, write_timeout=0.4)
    except Exception as exc:
        print("cannot open %s: %s" % (args.port, exc), file=sys.stderr)
        return 2

    link = Link(port, timeout_s=0.4)
    session = core.Session(link)
    try:
        identity = session.connect()
    except (core.WrongBitstream, LinkLost) as exc:
        print(str(exc), file=sys.stderr)
        port.close()
        return 3
    print("board 0x%08X, mode %s" % (identity.board_id, core.MODE_NAMES.get(identity.mode, identity.mode)))

    if not args.no_telemetry:
        session.write(TLM_CONTROL, ((TLM_PERIOD & 0xFFFF) << 16) | 1)

    model = ConsoleModel(session)

    def pump() -> None:
        for snapshot in link.pump():
            model.buffer.push(snapshot)

    window = ConsoleWindow(model, port_name=args.port, pump=pump)
    try:
        return window.run()
    finally:
        try:
            if session.status().mode == core.PLAY:
                session.stop()
            session.close_telemetry()
        except (LinkLost, OSError):
            pass
        finally:
            port.close()


if __name__ == "__main__":
    raise SystemExit(main())
