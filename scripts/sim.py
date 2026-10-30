#!/usr/bin/env python3
"""Compile and run the top-level regression against both memory models.

Why a baseline file
-------------------
The DUT still has open defects (reply error codes for rejection reasons, the
retry-after-commit semantics, a debug CSR that is compiled out by default), so
a naive "all assertions must pass" runner would be red for reasons unrelated to
whatever is being changed, and people stop looking at it.

Instead, the known-failing assertion names are recorded in
`sim_baseline.json`.  A run passes when the observed failures are a *subset* of
the recorded ones; any new failing name is reported as a regression and fails
the run.  `--update-baseline` re-records the set, so churn is explicit.

    python scripts/sim.py                 # both RAM models
    python scripts/sim.py --ram 0
    python scripts/sim.py --trace         # + CSR command/apply/reply monitor
    python scripts/sim.py --update-baseline
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
FILELIST = os.path.join(PROJECT, "filelist.f")
BASELINE = os.path.join(PROJECT, "sim_baseline.json")

BIN = os.environ.get("MODELSIM_BIN", r"C:/modeltech64_10.6d/win64")
PRIM_SIM = os.environ.get(
    "PRIM_SIM", r"C:/Gowin/Gowin_V1.9.12.04_x64/IDE/simlib/gw5a/prim_sim.v"
)

PASS_RE = re.compile(r"^PASS\s+(.+?)\s*=")
FAIL_NAMED_RE = re.compile(r"^FAIL\s+(.+?):")
SUMMARY_RE = re.compile(r"TB_TOP_CSR_GATE\s+(PASS|FAIL)")


def norm(line: str) -> str:
    """ModelSim prefixes every console line with '# ' when run with -c."""
    return line.lstrip("#").strip()


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
    ap.add_argument("--ram", choices=["0", "1", "both"], default="both")
    ap.add_argument("--trace", action="store_true", help="enable the CSR trace monitor")
    ap.add_argument("--update-baseline", action="store_true")
    args = ap.parse_args()

    ram_models = ["0", "1"] if args.ram == "both" else [args.ram]
    if not os.path.isfile(PRIM_SIM):
        print("XX  prim_sim.v not found: %s" % PRIM_SIM)
        print("    set PRIM_SIM, or the design cannot elaborate (GSR)")
        return 1

    srcs = read_filelist()
    extra = [
        os.path.join(PROJECT, "tb", "tb_top_csr_gate.sv"),
        os.path.join(PROJECT, "tb", "tb_sim_top.sv"),
    ]
    if args.trace:
        extra.append(os.path.join(PROJECT, "tb", "mon_csr_trace.sv"))

    # ModelSim resolves `work` relative to the working directory, so the library
    # is created as <run>/work and every command runs from <run>.
    run_dir = os.path.join(PROJECT, ".sim")
    if os.path.isdir(run_dir):
        shutil.rmtree(run_dir)
    os.makedirs(run_dir, exist_ok=True)

    vlib = os.path.join(BIN, "vlib.exe")
    vlog = os.path.join(BIN, "vlog.exe")
    vsim = os.path.join(BIN, "vsim.exe")

    print("compiling %d source files%s" % (len(srcs), " + trace" if args.trace else ""))
    run([vlib, "work"], run_dir, os.path.join(run_dir, "vlib.log"))
    defines = ["+define+V2_SIM"] + (["+define+CSR_TRACE"] if args.trace else [])
    code, text = run([vlog, "-sv"] + defines + ["-work", "work"] + srcs + extra + [PRIM_SIM],
                     run_dir, os.path.join(run_dir, "vlog.log"))
    m = re.search(r"Errors:\s*(\d+),\s*Warnings:\s*(\d+)", text)
    if code != 0 or not m or int(m.group(1)) or int(m.group(2)):
        print("XX  compile failed: %s" % (m.group(0) if m else "no summary"))
        for line in text.splitlines():
            if line.startswith("** "):
                print("    " + line.strip())
        return 1
    print("compile clean: 0 errors, 0 warnings")

    baseline = {"known_failing": [], "known_failing_reason": {}}
    if os.path.isfile(BASELINE):
        baseline = json.load(open(BASELINE, encoding="utf-8"))
    known = set(baseline.get("known_failing", []))

    results = {}
    overall_ok = True

    for ram in ram_models:
        log = os.path.join(PROJECT, "sim_logs", "ram%s.log" % ram)
        print("\n--- GOWIN_RAM=%s ---" % ram)
        t0 = time.time()
        code, text = run(
            [vsim, "-c", "-novopt", "-gGOWIN_RAM=%s" % ram, "work.tb_sim_top",
             "-do", "run -all; quit -f"],
            run_dir, log,
        )
        elapsed = time.time() - t0

        lines = [norm(l) for l in text.splitlines()]
        passed = [m.group(1).strip() for m in map(PASS_RE.match, lines) if m]
        failed = [m.group(1).strip() for m in map(FAIL_NAMED_RE.match, lines) if m]
        generic = [l for l in lines if l.startswith("FAIL:")]
        malformed = sum(1 for l in lines if "malformed reply" in l)
        summary = SUMMARY_RE.search(text)

        results[ram] = {"passed": passed, "failed": failed, "generic": generic,
                        "malformed": malformed, "elapsed": elapsed,
                        "exit": code, "summary": summary.group(1) if summary else None}

        print("  assertions passed : %d" % len(passed))
        print("  assertions failed : %d" % len(failed))
        if malformed:
            print("  malformed replies : %d  (>>> testbench buffer bug, not a DUT result)" % malformed)
        print("  simulator exit    : %s   wall %0.1f s" % (code, elapsed))

        if summary is None:
            print("  XX  the testbench never reached its final verdict (hangs or fatal early)")
            tail = [l for l in text.splitlines() if l.startswith("**")][-5:]
            for l in tail:
                print("      " + l.strip())
            overall_ok = False
            continue

        new = [f for f in failed if f not in known]
        if new:
            print("  XX  NEW failing assertions:")
            for f in new:
                print("        - %s" % f)
            overall_ok = False
        for f in failed:
            if f in known:
                print("  ..  known failing: %s" % f)
        for g in generic:
            print("  XX  %s" % g)
            overall_ok = False

    if args.update_baseline:
        recorded = sorted({f for r in results.values() for f in r["failed"]})
        payload = {
            "recorded_from": "scripts/sim.py --update-baseline",
            "ram_models": ram_models,
            "known_failing": recorded,
            "known_failing_reason": baseline.get("known_failing_reason", {}),
        }
        with open(BASELINE, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
        print("\nbaseline updated: %d known-failing assertion(s)" % len(recorded))
        return 0

    if len(ram_models) == 2:
        a, b = (results[r] for r in ram_models)
        same = (sorted(a["passed"]) == sorted(b["passed"])
                and sorted(a["failed"]) == sorted(b["failed"]))
        print("\nRAM=0 vs RAM=1 identical: %s" % ("yes" if same else "NO -- investigate"))
        if not same:
            overall_ok = False

    print("\nSIM: %s" % ("PASS" if overall_ok else "FAIL"))
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
