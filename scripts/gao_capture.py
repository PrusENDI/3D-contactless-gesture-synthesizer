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
    # gao_sh appends a per-core suffix (apply_run1_core0.csv), so glob the stem.`n    import glob`n    candidates = [csv_out, out_base] + sorted(glob.glob(os.path.splitext(csv_out)[0] + "*core*.csv"))`n    for candidate in candidates:
        if os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
            return candidate
    raise SystemExit("gao_capture: gao_sh reported success but produced no capture file")

def decode(csv_path: str, layout: list[tuple[str, int]]) -> None:
    """Decode Gowin's capture format into a change timeline.

    The file starts with "Groups:" and one line per group ("<name> =, <bits...>"),
    then one data row per sample: <index>, <value per group>.  Values are hex for
    buses and 0/1 for single bits, so the group order defines the columns and the
    .rao only tells us which group is which.
    """
    with open(csv_path, encoding="utf-8-sig", errors="replace") as fh:
        lines = [ln.rstrip("\r\n") for ln in fh]
    groups: list[str] = []
    data_lines: list[str] = []
    in_header = True
    for ln in lines:
        if not ln.strip():
            continue
        if in_header:
            if ln.strip().lower().startswith("groups"):
                continue
            if "=" in ln and not ln.split(",")[0].strip().isdigit():
                groups.append(ln.split("=")[0].strip())
                continue
            in_header = False
        data_lines.append(ln)
    if not data_lines:
        raise SystemExit("gao_capture: no data rows in %s" % csv_path)
    print("groups: %d, sample rows: %d" % (len(groups), len(data_lines)))

    # Map each .rao probe onto the group with the same name; fall back to position.
    name_to_col = {g: i for i, g in enumerate(groups)}
    columns: list[tuple[str, int]] = []
    for i, (name, _width) in enumerate(layout):
        col = name_to_col.get(name)
        if col is None:
            col = i if i < len(groups) else None
        columns.append((name, col))

    prev: dict[str, int] = {}
    changes = 0
    for row_no, ln in enumerate(data_lines):
        fields = [f.strip() for f in ln.split(",")]
        values: dict[str, int] = {}
        for name, col in columns:
            if col is None or col + 1 >= len(fields):
                continue
            raw = fields[col + 1]
            try:
                values[name] = int(raw, 16) if raw.lower().startswith("0x") or not raw.isdigit() else int(raw)
                if raw and not raw.isdigit() and raw.lower() not in ("x", "z"):
                    values[name] = int(raw, 16)
            except ValueError:
                values[name] = 0
        if row_no == 0:
            print("first sample:", {k.split('/')[-1]: hex(v) for k, v in values.items() if v})
        else:
            delta = {k: (prev[k], v) for k, v in values.items() if k in prev and prev[k] != v}
            if delta:
                changes += 1
                print("sample %5s  %s" % (fields[0], ", ".join(
                    "%s:%x->%x" % (k.split('/')[-1], a, b) for k, (a, b) in delta.items())))
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