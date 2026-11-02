#!/usr/bin/env python3
"""MGC3130 synth console.

    python host/console.py --port COM4

One serial owner, four tabs, presets on disk, and a reference bar for blind
recording. The window never changes the board's mode by itself; closing it closes
the telemetry stream and, if the loop is still playing, stops it (design 8.7).

Needs pyserial, tkinter and ttkbootstrap (the only part that needs the last one
is the window; the model, the link and the tests run without it).
"""

from __future__ import annotations

import argparse
import datetime
import sys
from pathlib import Path

# Import the package the same way the tests do (`host.v2_console`), or the modules
# that reach back into `host.*` fail only when launched as a script.
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from host.v2_console import presets as preset_store  # noqa: E402
from host.v2_console.link import Link, LinkLost  # noqa: E402
from host.v2_console.serial_port import SerialPort  # noqa: E402
from host.v2_console.session import core  # noqa: E402
from host.v2_console.views.shell import ConsoleModel, ConsoleWindow  # noqa: E402

TLM_CONTROL = 0x80
TLM_PERIOD = 240          # 200 frames per second, the sensor's own rate


def load_presets() -> list:
    loaded = []
    for path in sorted(preset_store.PRESET_DIR.glob("*.json")):
        try:
            loaded.append(preset_store.load(path))
        except preset_store.PresetError as exc:
            print("skipping %s: %s" % (path.name, exc), file=sys.stderr)
    return loaded


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=1_000_000)
    parser.add_argument("--no-telemetry", action="store_true", help="do not start the cursor stream")
    parser.add_argument("--log", default=None, help="session JSONL path (default artifacts/console/)")
    args = parser.parse_args()

    # The window is the only part that needs ttkbootstrap; failing here is cheap
    # and says what to install, instead of an ImportError from inside Tk.
    try:
        import ttkbootstrap  # noqa: F401
    except ImportError:
        print("the console window needs ttkbootstrap: python -m pip install ttkbootstrap",
              file=sys.stderr)
        return 5

    try:
        port = SerialPort(args.port, args.baud)
    except Exception as exc:
        print("cannot open %s: %s" % (args.port, exc), file=sys.stderr)
        return 2

    log_path = args.log or (
        REPO_ROOT
        / "artifacts"
        / "console"
        / ("session-%s.jsonl" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    )
    link = Link(port, timeout_s=0.4)
    session = core.Session(link, log_path=Path(log_path))
    try:
        identity = session.connect()
    except (core.WrongBitstream, LinkLost) as exc:
        print(str(exc), file=sys.stderr)
        port.close()
        return 3
    print("board 0x%08X, mode %s, log %s"
          % (identity.board_id, core.MODE_NAMES.get(identity.mode, identity.mode), log_path))

    if not args.no_telemetry:
        session.write(TLM_CONTROL, ((TLM_PERIOD & 0xFFFF) << 16) | 1)

    model = ConsoleModel(session)

    def pump() -> None:
        for snapshot in link.pump():
            model.buffer.push(snapshot)

    try:
        window = ConsoleWindow(model, port_name=args.port, pump=pump, presets=load_presets())
    except Exception as exc:
        print("cannot open the window: %s" % exc, file=sys.stderr)
        _shutdown(session, port)
        return 4

    # One line of proof for the display: a 144 dpi screen must report 1.5x here,
    # or the window is 96 dpi content that Windows stretches and blurs.
    print("window %s, %.2f px per point, dpi awareness %d"
          % (window.root.winfo_geometry(), window.root.tk.call("tk", "scaling"), window.dpi_awareness))

    try:
        return window.run()
    finally:
        _shutdown(session, port)

def _shutdown(session, port) -> None:
    """Each step independent: a lost link must not leave the telemetry stream on."""
    for step in (
        lambda: session.stop() if session.status().mode == core.PLAY else None,
        session.close_telemetry,
        port.close,
    ):
        try:
            step()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
