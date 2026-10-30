#!/usr/bin/env python3
"""Capture a GAO trace and decode it into a change timeline.

The probe set is defined by the .rao file, not by this script: the signal order and
bus grouping are read back out of the XML, so changing probes never requires editing
Python.  Requires the instrumented bitstream (built with synth.py --gao) to be
programmed first, and the GAO cable to be free (programming and capturing are
serialised on the same JTAG link).

Usage:
    python scripts/gao_capture.py --rao gao/apply.rao --out artifacts/gao/apply_run1
    python scripts/gao_capture.py --rao gao/apply.rao --decode-only artifacts/gao/apply_run1.csv
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAO_SH = r"C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gao_sh.exe"


def read_probe_layout(rao_path: str) -> list[tuple[str, int]]:
    """Return the capture order as [(name, width), ...] (buses before single bits)."""
    root = ET.parse(rao_path).getroot()
    core = root.find(".//AoCore")
    if core is None:
        raise SystemExit("gao_capture: no <AoCore> in %s" % rao_path)
    layout: list[tuple[str, int]] = []
    for node in core.findall("./SignalList/*"):
        if node.tag == "Signal" and node.text:
            layout.append((node.text.strip(), 1))
        elif node.tag == "Bus":
            bits = [b.text.strip() for b in node.findall("Signal") if b.text]
            name = node.get("name") or bits[0]
            layout.append((name, len(bits)))
    if not layout:
        raise SystemExit("gao_capture: %s defines no signals" % rao_path)
    return layout


def capture(rao: str, out_base: str, cable: str) -> str:
    out_dir = os.path.dirname(out_base)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    cmd = [GAO_SH, "-gao", rao, "-cable", cable, "-out", out_base]
    print("run:", " ".join(cmd))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        raise SystemExit("gao_capture: gao_sh failed with %d" % proc.returncode)
    for candidate in (out_base + ".csv", out_base):
        if os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
            return candidate
    raise SystemExit("gao_capture: gao_sh reported success but produced no capture file")


def decode(csv_path: str, layout: list[tuple[str, int]]) -> None:
    """Print a change timeline: cycle, then every signal whose value changed."""
    with open(csv_path, newline="", encoding="utf-8-sig") as fh:
        rows = list(csv.reader(fh))
    if not rows:
        raise SystemExit("gao_capture: empty capture")
    header, data = rows[0], rows[1:]
    if not data:
        raise SystemExit("gao_capture: capture has a header but no samples")
    print("header columns: %d, sample rows: %d" % (len(header), len(data)))
    print("rao probe count: %d (header may add index/time columns)" % len(layout))

    # Map probe names to columns by substring match; GAO headers use the leaf name
    # and may decorate buses, so match on the leaf and on the bus name.
    def leaf(name: str) -> str:
        return name.split("/")[-1]

    columns: list[tuple[str, int, list[int]]] = []
    used: set[int] = set()
    for name, width in layout:
        wanted = leaf(name)
        idxs: list[int] = []
        for i, col in enumerate(header):
            if i in used:
                continue
            if wanted in col or col.strip() == name:
                idxs.append(i)
                used.add(i)
                if len(idxs) == width:
                    break
        if len(idxs) != width:
            print("WARN: probe %s width %d matched %d columns" % (name, width, len(idxs)))
        columns.append((name, width, idxs))

    prev: dict[str, int] = {}
    changes = 0
    for cycle, row in enumerate(data):
        current: dict[str, int] = {}
        for name, width, idxs in columns:
            value = 0
            for bit, col in enumerate(idxs):
                try:
                    if row[col].strip() not in ("0", ""):
                        value |= 1 << bit
                except IndexError:
                    pass
            current[name] = value
        if next(iter(current.values()), 0) is None:  # pragma: no cover
            continue
        if cycle == 0:
            print("cycle 0 initial:", {k: hex(v) for k, v in current.items() if v})
        else:
            delta = {k: (prev[k], v) for k, v in current.items() if k in prev and prev[k] != v}
            if delta:
                changes += 1
                text = ", ".join("%s:%x->%x" % (k.split('/')[-1], a, b) for k, (a, b) in delta.items())
                print("cycle %5d  %s" % (cycle, text))
        prev = current
    print("total change points: %d" % changes)
    if changes == 0:
        raise SystemExit("gao_capture: no signal ever changed - wrong trigger, wrong cable or dead design")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rao", default=os.path.join(PROJECT, "gao", "apply.rao"))
    ap.add_argument("--out", default=os.path.join(PROJECT, "artifacts", "gao", "apply_run1"))
    ap.add_argument("--cable", default="FT2CH")
    ap.add_argument("--decode-only", default=None)
    args = ap.parse_args()

    layout = read_probe_layout(args.rao)
    print("probes: %d signals, %d bits total" % (len(layout), sum(w for _, w in layout)))
    csv_path = args.decode_only if args.decode_only else capture(args.rao, args.out, args.cable)
    print("capture:", csv_path)
    decode(csv_path, layout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
