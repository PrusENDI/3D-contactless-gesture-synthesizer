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


def capture(rao: str, out_base: str, cable: str,
            force_timeout: int = 30, stop_timeout: int = 90) -> str:
    """Run one capture session.

    gao_sh only accepts .csv/.vcd/.prn/.gwd for -out, so the extension is added
    here.  -force_trigger_timeout guarantees capture even if the trigger never
    fires, and -stop_timeout bounds the session.
    """
    out_dir = os.path.dirname(out_base)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    csv_out = out_base if out_base.lower().endswith(".csv") else out_base + ".csv"
    rep_out = os.path.splitext(csv_out)[0] + ".json"
    cmd = [GAO_SH, "-gao", rao, "-cable", cable,
           "-out", csv_out, "-report", rep_out,
           "-force_trigger_timeout", str(force_timeout),
           "-stop_timeout", str(stop_timeout), "-overwrite"]
    print("run:", " ".join(cmd))
    # Do not capture child stdio through pipes: the sandbox denies pipe creation,
    # which made gao_sh look like it failed.  Let the tool write to our stdio.
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        raise SystemExit("gao_capture: gao_sh failed with %d" % proc.returncode)
    # gao_sh appends a per-core suffix (<stem>_core0.csv) and writes it late,
    # so glob the stem and retry briefly.
    import glob
    import time as _time
    candidates = [csv_out, out_base] + sorted(glob.glob(os.path.splitext(csv_out)[0] + "*core*.csv"))
    for _attempt in range(10):
        for candidate in candidates:
            if os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
                return candidate
        _time.sleep(1.0)
    raise SystemExit("gao_capture: gao_sh reported success but produced no capture file")

def decode(csv_path: str, layout: list[tuple[str, int]]) -> None:
    """Decode Gowin's capture format into a change timeline.

    The file has a "Groups:" block that lists only the buses, then a "Data:"
    section whose next line is the authoritative column header:
        "time unit: us, <sig>, <sig>, ...,"
    Each following row is "time, value, value, ...".  Buses are hex, single bits
    are 0/1, so every field parses as hex.
    """
    with open(csv_path, encoding="utf-8-sig", errors="replace") as fh:
        lines = [ln.rstrip("\r\n") for ln in fh]

    data_at = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith("Data:"):
            data_at = i
            break
    if data_at is None:
        raise SystemExit("gao_capture: no 'Data:' section in %s" % csv_path)

    header = [c.strip() for c in lines[data_at + 1].split(",")]
    while header and header[-1] == "":
        header.pop()
    names = header[1:]          # first column is the time stamp
    if not names:
        raise SystemExit("gao_capture: empty column header")
    print("columns: %d (%s ...)" % (len(names), names[0]))

    rows: list[tuple[str, list[int]]] = []
    for ln in lines[data_at + 2:]:
        if not ln.strip():
            continue
        fields = [f.strip() for f in ln.split(",")]
        if fields and fields[-1] == "":
            fields.pop()
        if len(fields) < 2:
            continue
        try:
            values = [int(f, 16) if f not in ("", "x", "z") else 0 for f in fields[1:]]
        except ValueError:
            continue
        rows.append((fields[0], values))
    if not rows:
        raise SystemExit("gao_capture: no sample rows")
    print("samples: %d, time span: %s .. %s us" % (len(rows), rows[0][0], rows[-1][0]))

    prev: list[int] | None = None
    changes = 0
    for stamp, values in rows:
        if prev is None:
            shown = {names[i]: hex(values[i]) for i in range(min(len(names), len(values))) if values[i]}
            print("t=%s initial: %s" % (stamp, shown))
        else:
            delta = [i for i in range(min(len(names), len(values), len(prev))) if values[i] != prev[i]]
            if delta:
                changes += 1
                text = ", ".join("%s:%x->%x" % (names[i].split("/")[-1], prev[i], values[i]) for i in delta)
                print("t=%8s us  %s" % (stamp, text))
        prev = values
    print("total change points: %d" % changes)
    if changes == 0:
        raise SystemExit("gao_capture: no signal changed - wrong trigger or dead design")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rao", default=os.path.join(PROJECT, "gao", "apply.rao"))
    ap.add_argument("--out", default=os.path.join(PROJECT, "artifacts", "gao", "apply_run1"))
    ap.add_argument("--cable", default="FT2CH")
    ap.add_argument("--force-trigger-timeout", type=int, default=30)
    ap.add_argument("--stop-timeout", type=int, default=90)
    ap.add_argument("--decode-only", default=None)
    args = ap.parse_args()

    layout = read_probe_layout(args.rao)
    print("probes: %d signals, %d bits total" % (len(layout), sum(w for _, w in layout)))
    csv_path = args.decode_only if args.decode_only else capture(args.rao, args.out, args.cable, args.force_trigger_timeout, args.stop_timeout)
    print("capture:", csv_path)
    decode(csv_path, layout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
