#!/usr/bin/env python3
"""Run the whole stage-2 (LOOP/Potts) evidence set with one command.

The stage-2 RTL has no single regression that covers it: `scripts/sim.py` only
runs the top CSR gate, and per-module benches are invoked one at a time.  This
runner replays every piece of evidence the stage-2 design relies on:

  1. tb_v2_potts_commit       HORIZON=128 commit FSM (register dp table)
  2. tb_v2_potts_commit_fsm   HORIZON=32 board profile (DPB dp table)
  3. tb_mgc3130_v2_top_potts  top integration (contour capture, COMMIT, swap)
  4. host.test_v2_potts_reference   the integer-note golden reference

    python scripts/test_potts_plane.py
    python scripts/test_potts_plane.py --skip-sim    # reference test only
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)

SIMS = ("tb_v2_potts_commit",
        "tb_v2_potts_commit_fsm",
        "tb_loop_contour_capture",
        "tb_loop_rest_purify",
        "tb_loop_commit_writer",
        "tb_loop_scheduler_tick",
        "tb_loop_publish",
        "tb_stage2_loop_e2e")


def run(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, cwd=PROJECT, text=True, errors="replace",
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-sim", action="store_true", help="only run the reference tests")
    args = ap.parse_args()

    results: list[tuple[str, bool, str]] = []

    if not args.skip_sim:
        for tb in SIMS:
            code, text = run([sys.executable, os.path.join(HERE, "sim_unit.py"), "--tb", tb])
            print(text, end="" if text.endswith("\n") else "\n")
            verdict = next((l.strip() for l in text.splitlines() if l.startswith("UNIT ")), "")
            results.append((tb, code == 0 and verdict.endswith("PASS"), verdict))

    code, text = run([sys.executable, "-m", "unittest", "host.test_v2_potts_reference", "-v"])
    print(text, end="" if text.endswith("\n") else "\n")
    results.append(("host.test_v2_potts_reference", code == 0, text.strip().splitlines()[-1]))

    print("=" * 72)
    failed = 0
    for name, ok, detail in results:
        print("%-32s %s  %s" % (name, "PASS" if ok else "FAIL", detail))
        failed += 0 if ok else 1
    print("POTTS PLANE: %s" % ("PASS" if not failed else "FAIL (%d)" % failed))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
