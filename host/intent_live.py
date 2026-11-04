#!/usr/bin/env python3
"""Watch the board's cursor stream and print what the hand seems to be doing.

    python host/intent_live.py                  # 200 Hz, one line every 100 ms
    python host/intent_live.py --rate 500       # faster stream, finer onsets
    python host/intent_live.py --json           # one JSON object per update

The board only sends telemetry while ``0x80`` bit 0 is set; the period field is
in 48 kHz samples, so ``--rate 200`` writes ``(240 << 16) | 1``.  The stream is
turned off again on exit, because leaving it on is what made every later board
script fail with ``SEQ MISMATCH``.

Latency, measured from the start of a gesture:

* a change of scale degree is reported after ``confirm`` samples (~15 ms at 200 Hz);
* the register needs ~0.6 s of travel;
* the rhythm and melody labels need 3-4 notes and settle in ~0.3-0.6 s.

Nothing here writes anything except ``0x80``; this tool only listens.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.v2_console import link as linkmod, serial_port  # noqa: E402
from host.v2_console.intent import IntentEngine  # noqa: E402
from host.v2_console.session import core  # noqa: E402

SAMPLE_RATE = 48000
TLM_CONTROL = 0x80

# y in the middle of each scale degree, for the synthetic gesture.
BAND_Y = (1900, 8600, 18300, 27000, 35600, 45300, 54900, 62600)


def demo(rate: int, hz: float, as_json: bool) -> int:
    """A rising-then-falling run: up 2 3 4 5, down 6 5 4 3, 150 ms a note."""
    bands = [2, 3, 4, 5, 6, 5, 4, 3]
    hold = 0.15
    per_note = max(1, int(round(hold * rate)))
    engine = IntentEngine(rate_hz=rate)
    step = 1.0 / rate
    t = 0.0
    next_print = 0.0
    for index in range(per_note * len(bands)):
        band = bands[min(len(bands) - 1, index // per_note)]
        engine.push(BAND_Y[band], t)
        t += step
        if t >= next_print:
            estimate = engine.estimate()
            if as_json:
                print(json.dumps({"t": round(t, 2), "y": estimate.y,
                                  "register": estimate.register,
                                  "rhythm": estimate.rhythm,
                                  "melody": estimate.melody,
                                  "figures": estimate.figures,
                                  "tempo_ms": round(estimate.tempo_ms),
                                  "confidence": round(estimate.confidence, 2)}),
                      flush=True)
            else:
                print("%6.2fs  %s" % (t, estimate.line()), flush=True)
            next_print = t + 1.0 / hz
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--rate", type=int, default=200,
                        help="telemetry frames per second (20..1000)")
    parser.add_argument("--hz", type=float, default=10.0,
                        help="how often to print an estimate")
    parser.add_argument("--seconds", type=float, default=0.0,
                        help="stop after this long (0 = run until Ctrl-C)")
    parser.add_argument("--json", action="store_true", help="one JSON object per line")
    parser.add_argument("--demo", action="store_true",
                        help="no board: drive the engine with a synthetic gesture")
    args = parser.parse_args(argv)

    rate = max(20, min(1000, args.rate))
    period = max(1, int(round(SAMPLE_RATE / rate)))
    word = (period << 16) | 1

    if args.demo:
        return demo(rate, args.hz, args.json)

    port = serial_port.SerialPort(args.port)
    link = linkmod.Link(port)
    session = core.Session(link)
    engine = IntentEngine(rate_hz=rate)

    session.write(TLM_CONTROL, word)
    if not args.json:
        print("# %s at %d Hz (period %d samples); Ctrl-C to stop"
              % (args.port, rate, period))
    started = time.monotonic()
    last_print = 0.0
    frames = 0
    try:
        while True:
            now = time.monotonic()
            for frame in link.pump():
                engine.push(frame.y, now)
                frames += 1
            if now - last_print >= 1.0 / args.hz:
                estimate = engine.estimate()
                if args.json:
                    print(json.dumps({
                        "t": round(now - started, 2),
                        "y": estimate.y,
                        "register": estimate.register,
                        "rhythm": estimate.rhythm,
                        "melody": estimate.melody,
                        "figures": estimate.figures,
                        "tempo_ms": round(estimate.tempo_ms),
                        "confidence": round(estimate.confidence, 2),
                        "notes": list(estimate.notes),
                        "frames": frames,
                    }), flush=True)
                else:
                    print("%6.2fs  %s" % (now - started, estimate.line()), flush=True)
                last_print = now
            if args.seconds and now - started >= args.seconds:
                break
            time.sleep(0.002)
    except KeyboardInterrupt:
        pass
    finally:
        session.write(TLM_CONTROL, 0)
        if not args.json:
            print("# stopped after %d frames" % frames)
    return 0


if __name__ == "__main__":
    sys.exit(main())
