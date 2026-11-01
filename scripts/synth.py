#!/usr/bin/env python3
"""Single, parametrised synthesis entry point.

The legacy tree holds 78 hand-written `synth_*.tcl` scripts, one per debug round,
each embedding its own copy of the file list.  That is how the build drifted away
from the source tree: `rtl/` could gain a file (or a second definition of the
top) without any build noticing.

Here the project file is *generated* from `filelist.f`, so the simulator, the
gate and the synthesizer cannot disagree about which files are the design.

    python scripts/synth.py --run-id r1234            # syn + pnr
    python scripts/synth.py --run-id r1234 --syn-only  # syn only (fast)
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

import synth_report

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
FILELIST = os.path.join(PROJECT, "filelist.f")
IPLIST = os.path.join(PROJECT, "ip", "filelist_ip.f")

GOWIN_ROOT = os.environ.get("GOWIN_ROOT", r"C:\Gowin\Gowin_V1.9.12.04_x64")
DEVICE_XML = ('<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device>')
TOP = "v2_board_top"
PROJECT_NAME = "v2_board_top"

GPRJ_HEAD = ('<?xml version="1.0"?><!DOCTYPE gowin-fpga-project><Project>'
             '<Template>FPGA</Template><Version>5</Version>' + DEVICE_XML + '<FileList>')
GPRJ_TAIL = '</FileList></Project>'


def read_filelist(path: str = FILELIST) -> list[str]:
    out = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if line and not line.startswith("#"):
                out.append(line.replace("\\", "/"))
    return out


def build_gprj(entries: list[str], gprj_path: str, gao: str | None = None) -> None:
    """Emit the project file.  Paths are relative to the .gprj's directory."""
    rel_dir = os.path.relpath(os.path.dirname(gprj_path), PROJECT)
    depth = 0 if rel_dir == "." else rel_dir.count(os.sep) + 1
    prefix = "../" * depth
    parts = [GPRJ_HEAD]
    for rel in entries:
        parts.append('<File path="%s%s" type="file.verilog" enable="1"/>' % (prefix, rel))
    if gao:
        parts.append('<File path="%s%s" type="file.gao" enable="1"/>' % (prefix, gao.replace("\\", "/")))
    for cst in ("constr/mgc3130_v2.cst", "constr/mgc3130_v2_top_observable.sdc"):
        kind = "file.cst" if cst.endswith(".cst") else "file.sdc"
        parts.append('<File path="%s%s" type="%s" enable="1"/>' % (prefix, cst, kind))
    parts.append(GPRJ_TAIL)
    with open(gprj_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("".join(parts))


def extract(text: str, patterns: dict[str, str]) -> dict[str, str | None]:
    found: dict[str, str | None] = {}
    for key, pat in patterns.items():
        m = re.search(pat, text)
        found[key] = m.group(0).strip() if m else None
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--syn-only", action="store_true")
    ap.add_argument("--max-cls", type=int, default=11300,
                    help="build gate: CLS must stay at or below this (design doc section 6)")
    ap.add_argument("--min-slack", type=float, default=-3.5,
                    help="build gate: worst setup slack floor in ns (design doc section 6)")
    ap.add_argument("--gao", default=None, help="GAO probe definition (.rao) to instrument the build")
    args = ap.parse_args()

    run_id = args.run_id
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$", run_id):
        print("XX  run-id must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
        return 1

    ip_entries = read_filelist(IPLIST) if os.path.isfile(IPLIST) else []
    entries = ip_entries + read_filelist()
    missing = [e for e in entries if not os.path.isfile(os.path.join(PROJECT, e))]
    if missing:
        print("XX  filelist entries missing: %s" % ", ".join(missing))
        return 1
    extra = [c for c in ("constr/mgc3130_v2.cst", "constr/mgc3130_v2_top_observable.sdc")
             if not os.path.isfile(os.path.join(PROJECT, c))]
    if extra:
        print("XX  constraints missing: %s" % ", ".join(extra))
        return 1

    run_dir = os.path.join(PROJECT, "impl", "%s_%s" % (PROJECT_NAME, run_id))
    if os.path.isdir(run_dir):
        print("XX  refusing to reuse %s" % run_dir)
        return 1
    os.makedirs(run_dir)

    gprj = os.path.join(run_dir, PROJECT_NAME + ".gprj")
    build_gprj(entries, gprj, args.gao)

    tcl = os.path.join(run_dir, "synth.tcl")
    steps = [
        "open_project {%s}" % gprj.replace("\\", "/"),
        "set_option -top_module %s" % TOP,
        "set_option -verilog_std sysv2017",
        "# E2 is the board oscillator and is multiplexed with CPU/SSPI functions.",
        "set_option -use_sspi_as_gpio 1",
        "set_option -use_cpu_as_gpio 1",
        'puts "V2_SYNTH_BEGIN"',
        "run syn",
        'puts "V2_SYNTH_PASS"',
    ]
    if not args.syn_only:
        steps += ['puts "V2_PNR_BEGIN"', "run pnr", 'puts "V2_PNR_PASS"']
    steps.append("exit")
    with open(tcl, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(steps) + "\n")

    gw_sh = os.path.join(GOWIN_ROOT, "IDE", "bin", "gw_sh.exe")
    if not os.path.isfile(gw_sh):
        print("XX  gw_sh not found: %s" % gw_sh)
        return 1

    env = dict(os.environ)
    env["GOWIN_HOME"] = GOWIN_ROOT
    env["GW_HOME"] = GOWIN_ROOT
    env["Path"] = os.path.join(GOWIN_ROOT, "IDE", "bin") + ";" + env.get("Path", "")

    print("run dir  : %s" % run_dir)
    print("sources  : %d" % len(entries))
    print("top      : %s" % TOP)
    log_path = os.path.join(run_dir, "gw_sh.log")
    t0 = time.time()
    # gw_sh resolves its bundled Tcl and plugins relative to its own bin
    # directory, so it is launched from there.
    proc = subprocess.run([gw_sh, tcl], cwd=os.path.join(GOWIN_ROOT, "IDE", "bin"),
                          env=env, capture_output=True, text=True, errors="replace")
    elapsed = time.time() - t0
    out = proc.stdout + proc.stderr
    with open(log_path, "w", encoding="utf-8") as fh:
        fh.write(out)

    ok = proc.returncode == 0 and "V2_SYNTH_PASS" in out and (
        args.syn_only or "V2_PNR_PASS" in out)
    print("exit     : %d   wall %0.1f s" % (proc.returncode, elapsed))
    if not ok:
        errors = [l.strip() for l in out.splitlines() if l.lstrip().startswith("ERROR")]
        if errors:
            print("XX  %d synthesizer error(s):" % len(errors))
            for line in errors[:20]:
                print("    " + line)
        else:
            print("XX  build did not reach its PASS marker")
            for line in out.splitlines()[-25:]:
                print("    " + line.rstrip())
        return 1

    # Resource / timing evidence, straight from the generated reports.  The
    # timing numbers do not live in rpt.txt (the old code looked there, printed
    # None and still exited 0); synth_report reads .tr and .timing_paths and
    # turns them into the build gate of the P2 design, so a build cannot claim
    # PASS while being slower or fuller than the agreed thresholds.
    summary: dict[str, object] = {
        "run_id": run_id, "run_dir": os.path.relpath(run_dir, PROJECT),
        "top": TOP, "sources": len(entries), "syn_only": args.syn_only,
        "wall_seconds": round(elapsed, 1), "exit_code": proc.returncode,
    }
    pnr_dir = os.path.join(run_dir, "impl", "pnr")
    syn_dir = os.path.join(run_dir, "impl", "gwsynthesis")

    rpt = os.path.join(pnr_dir, PROJECT_NAME + ".rpt.txt")
    if os.path.isfile(rpt):
        text = open(rpt, encoding="utf-8", errors="replace").read()
        summary["resources"] = extract(text, {
            "logic": r"Logic\s*\|\s*\d+/\d+",
            "register": r"Register\s*\|\s*\d+/\d+",
            "cls": r"CLS\s*\|\s*\d+/\d+",
        })

    gate_problems: list[str] = []
    if not args.syn_only:
        try:
            report = synth_report.read_run(run_dir)
        except ValueError as exc:
            print("XX  the build reports cannot be read: %s" % exc)
            return 1
        summary["resources"] = {
            "logic": "%d/%d" % (report["logic"], report["logic_max"]),
            "register": "%d/%d" % (report["register"], report["register_max"]),
            "cls": "%d/%d" % (report["cls"], report["cls_max"]),
            "dsp": "%d/%d" % (report.get("dsp", 0), report.get("dsp_max", 0)),
            "bsram": "%d/%d" % (report.get("bsram", 0), report.get("bsram_max", 0)),
        }
        summary["timing"] = {
            "constraint_mhz": 80.0,
            "fmax_mhz": report["fmax"],
            "setup_violated_endpoints": report["violations"],
            "tns_ns": report["tns"],
            "worst_slack_ns": report["worst_slack"],
            "worst_from": report["worst_from"],
        }
        gate_problems = synth_report.gate_fail(report, args.max_cls, args.min_slack)
        summary["gate"] = {"max_cls": args.max_cls, "min_slack": args.min_slack,
                           "problems": gate_problems}

    fs = os.path.join(pnr_dir, PROJECT_NAME + ".fs")
    if not os.path.isfile(fs):
        gao_fs = os.path.join(pnr_dir, "ao_0.fs")   # GAO-instrumented build
        if os.path.isfile(gao_fs):
            fs = gao_fs
    if os.path.isfile(fs):
        import hashlib
        summary["bitstream_sha256"] = hashlib.sha256(open(fs, "rb").read()).hexdigest()

    with open(os.path.join(run_dir, "synth_summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")

    for key in ("resources", "timing", "bitstream_sha256", "gate"):
        if key in summary:
            print("%-9s: %s" % (key, summary[key]))
    if gate_problems:
        print("XX  GATE: FAIL (%d)" % len(gate_problems))
        for problem in gate_problems:
            print("    " + problem)
        print("\nbuild produced a bitstream, but it must not go on the board")
        return 2
    print("\nSYNTH: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
