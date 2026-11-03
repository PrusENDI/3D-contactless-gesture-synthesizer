#!/usr/bin/env python3
"""Read the P2 build gate out of a Gowin place-and-route run.

`scripts/synth.py` used to pull the timing numbers out of
`impl/pnr/<top>.rpt.txt`, where they do not exist: it printed `violations: None`
and `fmax: None` and still exited 0, so "SYNTH: PASS" said nothing about timing
or area.  The four numbers live in `<top>.tr` (violated endpoints, TNS, Fmax) and
`<top>.timing_paths` (the worst path), and CLS lives in `<top>.rpt.txt`.

This module exists so that the gate can be tested without a build, and so that a
missing number fails loudly instead of turning into None.

    python scripts/synth_report.py --run-dir impl/v2_board_top_vca_detune_mbox
    python scripts/synth_report.py --run-dir impl/<run> --enforce   # exit 2 on fail
"""

from __future__ import annotations

import argparse
import os
import re
import sys

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NUM = r"-?\d+(?:\.\d+)?"


def parse_resources(rpt_text: str) -> dict[str, int]:
    """CLS / DSP / BSRAM / Logic / Register used and available, from rpt.txt."""
    out: dict[str, int] = {}
    for key, name in (("cls", "CLS"), ("dsp", "DSP"), ("bsram", "BSRAM"),
                      ("logic", "Logic"), ("register", "Register")):
        m = re.search(r"^\s*%s\s+\|\s*(\d+)/(\d+)" % name, rpt_text, re.MULTILINE)
        if not m:
            if key == "cls":
                raise ValueError("missing the CLS row in the resource report")
            continue
        out[key] = int(m.group(1))
        out[key + "_max"] = int(m.group(2))
    return out


def parse_timing(tr_text: str, paths_text: str) -> dict[str, object]:
    """The four gate numbers plus the start point of the worst path."""
    m = re.search(r"Numbers of Setup Violated Endpoints>:(\d+)", tr_text)
    if not m:
        raise ValueError("missing 'Numbers of Setup Violated Endpoints'")
    violations = int(m.group(1))

    m = re.search(r"default_gen_clk\s+setup\s+(" + NUM + r")\s+(\d+)", tr_text)
    if not m:
        raise ValueError("missing the per-clock setup row (TNS / endpoints)")
    tns = float(m.group(1))
    endpoints = int(m.group(2))

    m = re.search(r"\(MHz\)\s+(" + NUM + r")\(MHz\)", tr_text)
    if not m:
        raise ValueError("missing the 'Actual Fmax' row")
    fmax = float(m.group(1))

    lines = [line.strip() for line in paths_text.splitlines()]
    if len(lines) < 6 or lines[0] != "=====" or lines[1] != "SETUP":
        raise ValueError("missing the first path in .timing_paths")
    try:
        worst_slack = float(lines[2])
    except ValueError:
        raise ValueError("the first path does not start with a slack number")

    return {
        "violations": violations,
        "tns": tns,
        "endpoints": endpoints,
        "fmax": fmax,
        "worst_slack": worst_slack,
        "worst_from": lines[5],
    }


def gate_fail(summary: dict, max_cls: int, min_slack: float,
              min_fmax: float | None = None) -> list[str]:
    """Empty list means the build may go on the board; each string is a reason not to.

    `min_fmax` is opt-in: production keeps its historical CLS/slack gate, and the
    demo bitstream (small enough that 80 MHz should be easy) asks for the fmax
    floor explicitly.  A None floor means the criterion is not applied at all.
    """
    problems: list[str] = []
    cls = summary.get("cls")
    if cls is None:
        problems.append("CLS unknown (resource report had no CLS row)")
    elif cls > max_cls:
        problems.append("CLS %d over the %d limit" % (cls, max_cls))
    slack = summary.get("worst_slack")
    if slack is None:
        problems.append("worst slack unknown (timing report could not be read)")
    elif slack < min_slack:
        problems.append("worst slack %.3f ns under the %.3f ns floor" % (slack, min_slack))
    if min_fmax is not None:
        fmax = summary.get("fmax")
        if fmax is None:
            problems.append("fmax unknown (timing report could not be read)")
        elif fmax < min_fmax:
            problems.append("fmax %.3f MHz under the %.3f MHz floor" % (fmax, min_fmax))
    return problems


def find_top(pnr: str, top: str | None = None) -> str:
    """Which top a run directory was built for.

    Gowin names every report after the project, and `scripts/synth.py` names the
    project after the top, so the single `*.rpt.txt` in `impl/pnr` is the answer.
    Passing a name is still allowed and checks that it is really there.
    """
    if top is not None:
        if not os.path.isfile(os.path.join(pnr, top + ".rpt.txt")):
            raise ValueError("missing %s" % os.path.join(pnr, top + ".rpt.txt"))
        return top
    found = sorted(name[:-len(".rpt.txt")] for name in os.listdir(pnr)
                   if name.endswith(".rpt.txt")) if os.path.isdir(pnr) else []
    if not found:
        raise ValueError("no *.rpt.txt in %s -- is this a place-and-route run?" % pnr)
    if len(found) > 1:
        raise ValueError("%s holds %d tops (%s); name one with --top"
                         % (pnr, len(found), ", ".join(found)))
    return found[0]


def read_run(run_dir: str, top: str | None = None) -> dict:
    """Everything the gate needs, from one impl/<run> directory."""
    pnr = os.path.join(run_dir, "impl", "pnr")
    top = find_top(pnr, top)

    def text(name: str) -> str:
        path = os.path.join(pnr, name)
        if not os.path.isfile(path):
            raise ValueError("missing %s" % path)
        return open(path, encoding="utf-8", errors="replace").read()

    summary = parse_resources(text(top + ".rpt.txt"))
    summary.update(parse_timing(text(top + ".tr"), text(top + ".timing_paths")))
    return summary


def print_summary(summary: dict, problems: list[str]) -> None:
    print("cls       : %s/%s" % (summary.get("cls"), summary.get("cls_max")))
    print("dsp/bsram : %s / %s" % (summary.get("dsp"), summary.get("bsram")))
    print("endpoints : %s (tns %.3f ns)" % (summary.get("endpoints"), summary.get("tns")))
    print("fmax      : %.3f MHz" % summary.get("fmax"))
    print("worst     : %.3f ns from %s" % (summary.get("worst_slack"), summary.get("worst_from")))
    if problems:
        for problem in problems:
            print("gate      : FAIL - %s" % problem)
    else:
        print("gate      : OK")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True,
                    help="impl/<run> directory, e.g. impl/v2_board_top_vca_detune_mbox")
    ap.add_argument("--max-cls", type=int, default=11300)
    ap.add_argument("--min-slack", type=float, default=-3.5)
    ap.add_argument("--min-fmax", type=float, default=None,
                    help="optional fmax floor in MHz (the demo build uses 80)")
    ap.add_argument("--top", default=None,
                    help="top to read when the run directory holds more than one")
    ap.add_argument("--enforce", action="store_true",
                    help="exit 2 when the gate fails instead of only printing it")
    args = ap.parse_args(argv)

    run_dir = args.run_dir if os.path.isabs(args.run_dir) else os.path.join(PROJECT, args.run_dir)
    try:
        summary = read_run(run_dir, args.top)
    except ValueError as exc:
        print("XX  %s" % exc)
        return 1
    problems = gate_fail(summary, args.max_cls, args.min_slack, args.min_fmax)
    print_summary(summary, problems)
    return 2 if (problems and args.enforce) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
