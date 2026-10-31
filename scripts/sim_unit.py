#!/usr/bin/env python3
"""Compile and run ONE unit testbench against the project filelist.

The top-level regression (scripts/sim.py) runs tb_sim_top and compares against a
baseline of known failures.  That is the wrong instrument for a single module:
its runtime is minutes and a new assertion name shows up as a "regression" even
when it is a new feature.  This runner compiles the same filelist plus one small
testbench and requires the run to print PASS and no FAIL.

    python scripts/sim_unit.py --tb tb_wt_playback
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
FILELIST = os.path.join(PROJECT, "filelist.f")

BIN = os.environ.get("MODELSIM_BIN", r"C:/modeltech64_10.6d/win64")
PRIM_SIM = os.environ.get(
    "PRIM_SIM", r"C:/Gowin/Gowin_V1.9.12.04_x64/IDE/simlib/gw5a/prim_sim.v"
)


def read_filelist() -> list[str]:
    out = []
    with open(FILELIST, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if line and not line.startswith("#"):
                out.append(os.path.join(PROJECT, line.replace("\\", "/")))
    return out


def run(cmd: list[str], cwd: str, log: str) -> tuple[int, str]:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    text = proc.stdout + proc.stderr
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "w", encoding="utf-8") as fh:
        fh.write(text)
    return proc.returncode, text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tb", required=True, help="testbench module name, e.g. tb_wt_playback")
    args = ap.parse_args()

    tb = os.path.join(PROJECT, "tb", args.tb + ".sv")
    if not os.path.isfile(tb):
        print("XX  testbench not found: %s" % tb)
        return 1
    if not os.path.isfile(PRIM_SIM):
        print("XX  prim_sim.v not found: %s" % PRIM_SIM)
        return 1

    srcs = read_filelist()
    run_dir = os.path.join(PROJECT, ".sim_unit")
    if os.path.isdir(run_dir):
        shutil.rmtree(run_dir)
    os.makedirs(run_dir, exist_ok=True)

    vlib = os.path.join(BIN, "vlib.exe")
    vlog = os.path.join(BIN, "vlog.exe")
    vsim = os.path.join(BIN, "vsim.exe")

    run([vlib, "work"], run_dir, os.path.join(run_dir, "vlib.log"))
    code, text = run(
        [vlog, "-sv", "+define+V2_SIM", "-work", "work"] + srcs + [tb, PRIM_SIM],
        run_dir,
        os.path.join(PROJECT, "sim_logs", "unit_%s_compile.log" % args.tb),
    )
    m = re.search(r"Errors:\s*(\d+),\s*Warnings:\s*(\d+)", text)
    if code != 0 or not m or int(m.group(1)) or int(m.group(2)):
        print("XX  compile failed: %s" % (m.group(0) if m else "no summary"))
        for line in text.splitlines():
            if line.startswith("** "):
                print("    " + line.strip())
        return 1
    print("compile clean: 0 errors, 0 warnings")

    log = os.path.join(PROJECT, "sim_logs", "unit_%s.log" % args.tb)
    code, text = run(
        [vsim, "-c", "-novopt", "work." + args.tb, "-do", "run -all; quit -f"], run_dir, log
    )
    lines = [l.lstrip("#").strip() for l in text.splitlines()]
    passes = [l for l in lines if l.startswith("PASS")]
    fails = [l for l in lines if l.startswith("FAIL") or "Fatal" in l]
    # Elaboration failures (a port that does not exist yet) show up here, not in
    # the compile log; without them a red run prints nothing useful.
    errs = [l for l in lines if l.startswith("** Error") or l.startswith("Error loading")]
    for line in passes:
        print("  " + line)
    for line in fails:
        print("  XX  " + line)
    for line in errs[:5]:
        print("  XX  " + line)
    ok = bool(passes) and not fails
    print("UNIT %s: %s" % (args.tb, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
