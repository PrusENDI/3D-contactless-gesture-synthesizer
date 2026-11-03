#!/usr/bin/env python3
"""Static + compiler gate for the V2 source tree.

The legacy tree failed in three ways that no existing script could see:

  * a second definition of `mgc3130_v2_top` living in `rtl/mgc3130_v2_top_dpb.sv`
    (100 MHz + DPB config) silently replaced the 80 MHz one, because ModelSim
    reports it as a *warning*:  (vlog-2275) '...' already exists and will be
    overwritten.
  * `patch_crc_payload_q` was assigned but never declared; the compiler reports
    that as (vlog-2730) Undefined variable -- an error, but only if someone
    reads the log.
  * the only top-level regression lived in `impl/`, which `.gitignore` excludes,
    so it was never versioned.

This gate makes all three hard failures with a non-zero exit status.

    python scripts/gate.py            # static checks only
    python scripts/gate.py --compile  # + ModelSim vlog, warnings are fatal
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
FILELIST = os.path.join(PROJECT, "filelist.f")

DEFAULT_VLOG = r"C:/modeltech64_10.6d/win64/vlog.exe"

# Messages that must never be ignored again.
FATAL_PATTERNS = [
    (re.compile(r"vlog-2275"), "duplicate module definition (silently overwrites a previous one)"),
    (re.compile(r"vlog-2730"), "undefined variable (implicit 1-bit net)"),
    (re.compile(r"vlog-2388"), "use before declaration"),
    (re.compile(r"Unresolved reference"), "unresolved module reference"),
]

MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_][\w$]*)", re.M)
PKG_RE = re.compile(r"^\s*package\s+([A-Za-z_][\w$]*)", re.M)
IMPORT_RE = re.compile(r"\b(?:import\s+)?([A-Za-z_][\w$]*)\s*::")


class Gate:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []
        self.notes: list[str] = []

    def fail(self, msg: str) -> None:
        self.failures.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def note(self, msg: str) -> None:
        self.notes.append(msg)


def strip_comments(text: str) -> str:
    """Remove // and /* */ so commented-out code cannot satisfy a check."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def read_filelist() -> list[str]:
    entries: list[str] = []
    with open(FILELIST, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            entries.append(line.replace("\\", "/"))
    return entries


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compile", action="store_true", help="also run ModelSim vlog")
    ap.add_argument("--vlog", default=os.environ.get("VLOG", DEFAULT_VLOG))
    args = ap.parse_args()

    g = Gate()

    # ---------------------------------------------------------------- layout --
    if not os.path.isfile(FILELIST):
        print("FAIL: filelist.f missing -- refusing to fall back to a wildcard")
        return 1
    entries = read_filelist()
    if not entries:
        print("FAIL: filelist.f is empty")
        return 1

    missing = [e for e in entries if not os.path.isfile(os.path.join(PROJECT, e))]
    for e in missing:
        g.fail("filelist entry does not exist: %s" % e)
    entries = [e for e in entries if e not in missing]

    # ------------------------------------------------------------ parse units --
    sources: dict[str, str] = {}
    for rel in entries:
        path = os.path.join(PROJECT, rel)
        raw = open(path, "rb").read()
        if raw.startswith(b"\xef\xbb\xbf"):
            g.fail("%s starts with a UTF-8 BOM" % rel)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            g.fail("%s is not valid UTF-8: %s" % (rel, exc))
            continue
        if "\r\n" in text:
            g.warn("%s uses CRLF line endings" % rel)
        if "\t" in text:
            g.warn("%s contains tab characters" % rel)
        sources[rel] = strip_comments(text)

    modules: dict[str, list[str]] = {}
    packages: dict[str, list[str]] = {}
    for rel, text in sources.items():
        for name in MODULE_RE.findall(text):
            modules.setdefault(name, []).append(rel)
        for name in PKG_RE.findall(text):
            packages.setdefault(name, []).append(rel)

    # duplicate definitions -- the mgc3130_v2_top trap
    for name, files in sorted(modules.items()):
        if len(files) > 1:
            g.fail("module '%s' is defined in %d files: %s"
                   % (name, len(files), ", ".join(files)))
    for name, files in sorted(packages.items()):
        if len(files) > 1:
            g.fail("package '%s' is defined in %d files: %s"
                   % (name, len(files), ", ".join(files)))

    # a .sv file with no module and no package is either dead or misnamed
    for rel, text in sources.items():
        if not MODULE_RE.findall(text) and not PKG_RE.findall(text):
            g.fail("%s defines neither a module nor a package" % rel)

    # ------------------------------------------------------- package ordering --
    seen_non_pkg = False
    for rel in entries:
        text = sources.get(rel, "")
        is_pkg = bool(PKG_RE.findall(text)) and not MODULE_RE.findall(text)
        if not is_pkg:
            seen_non_pkg = True
        elif seen_non_pkg:
            g.fail("%s is a package listed after a module; packages must come first" % rel)

    # ------------------------------------------------------- top identification --
    # More than one synthesis top is legitimate: the instrument (`v2_board_top`)
    # and the standalone DDS demo (`v2_demo_top`).  The list lives in
    # MANIFEST.json; every name in it must be a real, uninstantiated module, and
    # nothing else may be a root -- that is what keeps a dead module from hiding
    # behind the second top.
    manifest_path = os.path.join(PROJECT, "MANIFEST.json")
    expected_tops: list[str] = []
    if os.path.isfile(manifest_path):
        import json
        manifest = json.load(open(manifest_path, encoding="utf-8"))
        declared = manifest.get("expected_tops")
        if declared:
            expected_tops = [str(name) for name in declared]
        elif manifest.get("expected_top"):
            expected_tops = [str(manifest["expected_top"])]

    def refs_to(name: str) -> int:
        pattern = re.compile(r"\b%s\b" % re.escape(name))
        return sum(len(pattern.findall(t)) for t in sources.values()) - 1

    roots = [n for n in modules if refs_to(n) <= 0]
    roots.sort()
    if expected_tops:
        for name in expected_tops:
            if name not in modules:
                g.fail("declared top '%s' is not defined anywhere" % name)
            elif name not in roots:
                g.fail("declared top '%s' is instantiated by something else" % name)
        extra = [r for r in roots if r not in expected_tops]
        if extra:
            g.fail("additional uninstantiated module(s) besides the declared tops: %s "
                   "(second top candidate)" % ", ".join(extra))
        # The demo top must stay reachable only through its own build.  If the
        # production hierarchy ever names it, "the production netlist is
        # unchanged" stops being true (design section 5.1).
        for rel in sorted(sources):
            if rel.startswith("rtl/v2_demo"):
                continue
            if "v2_demo_" in sources[rel]:
                g.fail("%s references v2_demo_*; the demo top must not be part of "
                       "the production hierarchy" % rel)

    # unreferenced packages
    all_text = "\n".join(sources.values())
    for name, files in sorted(packages.items()):
        uses = len(IMPORT_RE.findall(all_text))
        if not re.search(r"\b%s\b" % re.escape(name), all_text.replace("package %s" % name, "")):
            g.fail("package '%s' (%s) is never referenced" % (name, files[0]))
        del uses

    g.note("modules: %d, packages: %d, files: %d" % (len(modules), len(packages), len(entries)))
    g.note("top: %s" % (", ".join(expected_tops) if expected_tops else "(undeclared)"))
    g.note("uninstantiated: %s" % (", ".join(roots) if roots else "none"))

    # --------------------------------------------------------------- compiler --
    if args.compile and not g.failures:
        lib = os.path.join(PROJECT, ".gate", "work")
        os.makedirs(os.path.dirname(lib), exist_ok=True)
        if os.path.isdir(lib):
            import shutil
            shutil.rmtree(lib)
        subprocess.run([os.path.join(os.path.dirname(args.vlog), "vlib.exe"), lib],
                       capture_output=True)
        cmd = [args.vlog, "-sv", "-work", lib] + [os.path.join(PROJECT, e) for e in entries]
        proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
        out = proc.stdout + proc.stderr
        for pattern, why in FATAL_PATTERNS:
            for line in out.splitlines():
                if pattern.search(line):
                    g.fail("compiler: %s -- %s" % (line.strip(), why))
        m = re.search(r"Errors:\s*(\d+),\s*Warnings:\s*(\d+)", out)
        if not m:
            g.fail("compiler produced no summary line; the command probably failed")
        else:
            errs, warns = int(m.group(1)), int(m.group(2))
            if errs:
                g.fail("compiler reported %d error(s)" % errs)
            elif warns:
                for line in out.splitlines():
                    if line.startswith("** Warning"):
                        g.fail("compiler warning treated as error: %s" % line.strip())
            g.note("compiler: %d error(s), %d warning(s)" % (errs, warns))

    # ------------------------------------------------------------------ report --
    for n in g.notes:
        print("  ..  " + n)
    for w in g.warnings:
        print("  !!  " + w)
    for f in g.failures:
        print("  XX  " + f)
    if g.failures:
        print("\nGATE: FAIL (%d)" % len(g.failures))
        return 1
    print("\nGATE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
