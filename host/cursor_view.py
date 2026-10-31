#!/usr/bin/env python3
"""Cursor display: read the FPGA telemetry stream and draw the cursor position.

The board sends 22-byte snapshot frames at the rate set by TLM_CONTROL:

    0   0x5A   start of frame
    1   0x02   protocol version
    2   0x01   snapshot type
    3:5        sequence (16 bit)
    5:7        x  (16 bit)   <- cursor_x from the filter
    7:9        y  (16 bit)   <- cursor_y
    9:11       z  (16 bit)
    11..19     note/flags/bitmap/fifo/fault
    20:22      CRC16 over the first 20 bytes

Coordinates are the filter's 0..65535 range, centred at 32768.

Usage:
    python host/cursor_view.py --port COM4
    python host/cursor_view.py --console-only      # no window, prints positions
"""

from __future__ import annotations

import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:  # pragma: no cover - environment guard
    print("pyserial is required: pip install pyserial", file=sys.stderr)
    raise SystemExit(2)


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_command(op: int, addr: int, data: int, seq: int) -> bytes:
    frame = bytearray([0xA5, 0x02, op, addr, seq & 0xFF,
                       (data >> 24) & 0xFF, (data >> 16) & 0xFF, (data >> 8) & 0xFF, data & 0xFF])
    value = crc16(bytes(frame))
    frame += bytes([(value >> 8) & 0xFF, value & 0xFF])
    return bytes(frame)


def enable_telemetry(port, period: int = 2400) -> None:
    """TLM_CONTROL: bit0 enables snapshots, bits 31:16 are the period in samples."""
    word = ((period & 0xFFFF) << 16) | 1
    port.reset_input_buffer()
    port.write(build_command(0x02, 0x80, word, 1))
    time.sleep(0.05)
    port.reset_input_buffer()


def parse_frames(buffer: bytearray) -> list[tuple[int, int, int, int]]:
    """Return [(seq, x, y, z)] for every complete, CRC-valid snapshot frame."""
    out = []
    i = 0
    while i + 22 <= len(buffer):
        if buffer[i] == 0x5A and buffer[i + 1] == 0x02 and buffer[i + 2] == 0x01:
            frame = bytes(buffer[i:i + 22])
            if crc16(frame[:20]) == struct.unpack(">H", frame[20:22])[0]:
                seq = struct.unpack(">H", frame[3:5])[0]
                x, y, z = struct.unpack(">HHH", frame[5:11])
                out.append((seq, x, y, z))
                i += 22
                continue
        i += 1
    del buffer[:i]
    return out


def apply_flip(x: int, y: int, flip: str) -> tuple[int, int]:
    """The sensor axes can be mirrored by the physical mounting; flip here."""
    if flip in ("x", "both"):
        x = 65535 - x
    if flip in ("y", "both"):
        y = 65535 - y
    return x, y


def run_console(port, seconds: float, flip: str = "both") -> None:
    buf = bytearray()
    deadline = time.time() + seconds
    last = None
    while time.time() < deadline:
        buf += port.read(max(1, port.in_waiting))
        for seq, x, y, z in parse_frames(buf):
            x, y = apply_flip(x, y, flip)
            if (x, y) != last:
                print("seq=%5d  x=%5d  y=%5d  z=%5d   %s" % (seq, x, y, z, " " * (x * 40 // 65536) + "*"))
                last = (x, y)


def run_window(port, seconds: float, flip: str = "both") -> None:
    import tkinter as tk

    root = tk.Tk()
    root.title("MGC3130 cursor (FPGA telemetry)")
    size = 512
    canvas = tk.Canvas(root, width=size, height=size, bg="#101014", highlightthickness=0)
    canvas.pack()
    label = tk.Label(root, text="waiting for telemetry", fg="#cccccc", bg="#101014")
    label.pack(fill="x")
    state = {"dot": None, "trail": [], "frames": 0, "last": time.time()}
    buf = bytearray()
    deadline = time.time() + seconds if seconds > 0 else None

    def poll() -> None:
        nonlocal buf
        buf += port.read(max(1, port.in_waiting))
        frames = parse_frames(buf)
        for seq, x, y, z in frames:
            x, y = apply_flip(x, y, flip)
            px = int(x * (size - 1) / 65535)
            py = int(y * (size - 1) / 65535)
            state["trail"].append((px, py))
            if len(state["trail"]) > 400:
                state["trail"].pop(0)
            canvas.delete("trail")
            if len(state["trail"]) > 1:
                canvas.create_line(*[c for point in state["trail"] for c in point],
                                   fill="#2a6f97", width=2, tags="trail")
            canvas.delete("dot")
            canvas.create_oval(px - 5, py - 5, px + 5, py + 5, fill="#ffcc33", outline="", tags="dot")
            state["frames"] += 1
            label.config(text="seq=%d  x=%d  y=%d  z=%d  frames=%d" % (seq, x, y, z, state["frames"]))
        if deadline and time.time() > deadline and state["frames"]:
            root.destroy()
            return
        root.after(15, poll)

    root.after(15, poll)
    root.mainloop()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM4")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--seconds", type=float, default=0, help="0 means run until closed")
    ap.add_argument("--console-only", action="store_true")
    ap.add_argument("--flip", choices=["none", "x", "y", "both"], default="both",
                    help="mirror the axes; the sensor mounting decides the sign")
    args = ap.parse_args()

    try:
        port = serial.Serial(args.port, args.baud, timeout=0.2)
    except Exception as exc:  # pragma: no cover - hardware guard
        print("cannot open %s: %s" % (args.port, exc), file=sys.stderr)
        return 2

    enable_telemetry(port)
    try:
        if args.console_only:
            run_console(port, args.seconds or 10, args.flip)
        else:
            run_window(port, args.seconds, args.flip)
    finally:
        port.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
