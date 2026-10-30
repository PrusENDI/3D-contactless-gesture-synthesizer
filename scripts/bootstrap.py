#!/usr/bin/env python3
"""Materialise the clean V2 source tree from a pinned revision of the legacy repo.

Why this exists
---------------
The legacy worktree (`mgc3130_uart/.worktrees/v2-integration`) grew to:

  rtl/*.sv   71 files, of which only 30 participate in the build
  sim/*.sv   100+ files, incl. `v2_voice_engine_mux.task8-mailbox-split-backup.sv`

and it defined module `mgc3130_v2_top` twice (80 MHz `mgc3130_v2_top.sv` and
100 MHz + DPB `mgc3130_v2_top_dpb.sv`) plus `v2_potts_commit_fsm` twice.
ModelSim reports the duplicate only as a *warning*:

    ** Warning: b_top.sv(1): (vlog-2275) 'dupmod' already exists and will be
       overwritten.

so a wildcard compile silently kept the 100 MHz top and produced garbled UART
bytes (CLKS_PER_BIT=100 instead of 80).  Nothing downstream could tell.

This script copies *only* the files the build consumes, in dependency order,
from one pinned git revision, and records a sha256 manifest so the tree can be
reproduced and audited.

Usage
-----
    python scripts/bootstrap.py --source "<legacy repo>/.worktrees/v2-integration"
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)

# Ordered exactly as the synthesis project listed them: packages first, then
# leaf modules, then the integration top.  Order is part of the contract.
CURATED_RTL = [
    "v2_contract_pkg.sv",
    "v2_input_pkg.sv",
    "v2_touch_info_decoder.sv",
    "mgc3130_input_latch.sv",
    "v2_input_calibration.sv",
    "v2_position_validity.sv",
    "v2_cursor_filter_timed.sv",
    "v2_live_rule_engine.sv",
    "v2_loop_event_recorder.sv",
    "v2_loop_event_store_dpb.sv",
    "v2_loop_scheduler.sv",
    "v2_potts_commit_fsm.sv",
    "v2_note_increment_rom.sv",
    "v2_voice_state_bank.sv",
    "v2_voice_engine_banked.sv",
    "v2_fx_lite.sv",
    "v2_patch_bank.sv",
    "v2_wavetable_loader.sv",
    "v2_clock_gen.sv",
    "v2_reset_sync.sv",
    "v2_sample_scheduler.sv",
    "i2s_pcm5102a_tx.sv",
    "uart_rx.sv",
    "uart_tx.sv",
    "v2_uart_link.sv",
    "v2_telemetry_snapshot.sv",
    "mgc3130_reader.sv",
    "mgc3130_v2_top.sv",
    "v2_test_mode.sv",
]

# Modules that exist in the filelist but are never instantiated by another file.
# Exactly one of these may be the declared top; anything else is dead code.
EXPECTED_TOP = "v2_board_top"

# Vendor IP needed by the synthesis build.  `mgc3130_reader` instantiates
# Gowin_I2C_Master (name from top_define.vh, body an encrypted .vp core); without
# these the synthesizer stops with EX3937 "Instantiating unknown module".
VENDOR_IP = [
    ("ip/gowin_i2c_master/I2C_MASTER.vp", "file.verilog"),
    ("ip/gowin_i2c_master/I2C_MASTER_TOP.v", "file.verilog"),
]
VENDOR_IP_AUX = [
    "ip/gowin_i2c_master/top_define.vh",
    "ip/gowin_i2c_master/static_macro_define.vh",
    "ip/gowin_i2c_master/README.md",
]

PATCHES: list[dict] = []


def record_patch(name: str, reason: str) -> None:
    PATCHES.append({"file": name, "reason": reason})


def git_show(repo: str, rev: str, path: str) -> str:
    proc = subprocess.run(
        ["git", "-C", repo, "show", f"{rev}:{path}"],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise SystemExit(
            "git show failed for %s: %s"
            % (path, proc.stderr.decode("utf-8", "replace").strip())
        )
    return proc.stdout.decode("utf-8")


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read().replace("\r\n", "\n")


def write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------- patches ----

def fix_top_declaration_order(text: str) -> str:
    """Make `mgc3130_v2_top.sv` compile as SystemVerilog.

    Two defects live in the committed revision:

    1. `patch_crc_payload_q` is assigned in an always_ff but never declared.
    2. `patch_crc_valid_q` / `patch_crc_payload_q` are referenced by the
       `v2_patch_bank` instance (line ~479) *before* their declaration block
       (line ~518).  ModelSim rejects use-before-declaration with vlog-2388 and
       refuses to emit the module at all.

    The fix moves the P1 declaration block above the instance and adds the
    missing payload register.  The `assign wt_index_load_src = ...` line stays
    where it was, so `cmd_valid` (declared at line 449) is still in scope.
    """
    decl_block = (
        "// P1: one-shot CSR side effects are registered one cycle so the destination\n"
        "// register (wt_expected_crc / wt_select_index / patch_expected_crc / apply payload)\n"
        "// already holds the new value when the loader or patch bank samples the strobe.\n"
        "// WT_DATA is deliberately NOT delayed: it relies on same-cycle ready/valid.\n"
        "logic wt_crc_valid_src, wt_index_load_src, patch_crc_valid_src, wt_apply_valid_src;\n"
        "logic wt_crc_valid_q, wt_index_load_q, patch_crc_valid_q, wt_apply_valid_q;\n"
        "logic [15:0] wt_apply_payload_q;\n"
    )
    if decl_block not in text:
        raise SystemExit("P1 declaration block not found; revision drifted")

    # (a) drop the original block (declarations only; the assign stays put)
    text = text.replace(decl_block, "", 1)

    # (b) re-insert it, with the missing payload register, before v2_patch_bank
    anchor = "    v2_patch_bank #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) u_patch_bank ("
    if anchor not in text:
        raise SystemExit("v2_patch_bank instantiation not found")

    new_block = (
        "    // P1: one-shot CSR side effects are registered one cycle so the destination\n"
        "    // register (wt_expected_crc / wt_select_index / patch_expected_crc / apply payload)\n"
        "    // already holds the new value when the loader or patch bank samples the strobe.\n"
        "    // WT_DATA is deliberately NOT delayed: it relies on same-cycle ready/valid.\n"
        "    // NOTE: these must be declared before the instances that consume them.\n"
        "    logic wt_crc_valid_src, wt_index_load_src, patch_crc_valid_src, wt_apply_valid_src;\n"
        "    logic wt_crc_valid_q, wt_index_load_q, patch_crc_valid_q, wt_apply_valid_q;\n"
        "    logic [15:0] wt_apply_payload_q;\n"
        "    logic [15:0] patch_crc_payload_q;\n"
        "\n"
    )
    text = text.replace(anchor, new_block + anchor, 1)
    return text


def fix_board_top(text: str) -> str:
    """Turn the diagnostic probe wrapper into the one, explicit board top.

    The legacy build synthesised `sim/v2_top_fullpath_probe.sv`, i.e. the only
    real top-level module lived in the simulation directory.  Keeping a module
    named `*_probe` as the shipping top is how "which top did we build?"
    became ambiguous, so it is renamed rather than copied verbatim.
    """
    if "module v2_top_fullpath_probe" not in text:
        raise SystemExit("probe module header not found; revision drifted")
    text = text.replace("module v2_top_fullpath_probe", "module v2_board_top", 1)
    header = (
        "// Board top: the single synthesis top of this project.\n"
        "//\n"
        "// Renamed from `sim/v2_top_fullpath_probe.sv` of the legacy tree; the body\n"
        "// (parameter set and port map) is unchanged.  The preserve switches make the\n"
        "// real reader/Loop/Potts planes reachable for attribution, which is what the\n"
        "// board build has always targeted.\n"
    )
    # drop the old three-line provenance comment, keep the new header
    lines = text.split("\n")
    while lines and lines[0].startswith("//"):
        lines.pop(0)
    return header + "\n".join(lines)


def fix_testbench(text: str) -> str:
    """Repair the top-level regression's own two defects.

    (a) `rxbuf` is written as `rxbuf[rx_bytes % 256]` but was read as
        `rxbuf[base+n]`.  Past 256 received bytes every read runs off the end and
        yields X, which produced 1033 bogus "malformed reply" lines that masked
        real behaviour.

    (b) `$display("PASS %0s = ...", what)` drops the first character of the
        assertion name, because `%0s` is a numeric format.  The trimmed names
        then cannot be matched against the baseline, so use `%s`.

    (c) `expect_eq` declared the name as `input [255:0] what`, i.e. at most 32
        characters.  A string literal assigned to a packed vector is
        right-justified, so the 33-character name "expected CRC reached the
        uploader" lost its *first* character and printed as "xpected CRC ...".
        Widen the argument rather than shortening the name.
    """
    import re

    def repl(match: "re.Match[str]") -> str:
        idx = match.group(1)
        return "rxbuf[(base + %s) %% 256]" % idx if idx.strip() not in ("", "n") else match.group(0)

    fixed = re.sub(r"rxbuf\[base \+ (\d+)\]", repl, text)
    fixed = fixed.replace("rxbuf[base + n]", "rxbuf[(base + n) % 256]")
    fixed = fixed.replace("rxbuf[base]", "rxbuf[base % 256]")
    if fixed == text:
        raise SystemExit("testbench rxbuf pattern not found; revision drifted")

    before = fixed
    fixed = fixed.replace('$display("FAIL %0s: got', '$display("FAIL %s: got')
    fixed = fixed.replace('$display("PASS %0s =', '$display("PASS %s =')
    fixed = fixed.replace("input [255:0] what", "input [511:0] what")
    if fixed == before:
        raise SystemExit("testbench $display format not found; revision drifted")
    return fixed


# ------------------------------------------------------------------ main -----

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="legacy v2-integration worktree")
    ap.add_argument("--rev", default="HEAD")
    args = ap.parse_args()

    repo = os.path.abspath(args.source)
    rev = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--short", args.rev],
        capture_output=True, text=True, check=True,
    ).stdout.strip()

    manifest = {
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source_repo": repo,
        "source_rev": rev,
        "expected_top": EXPECTED_TOP,
        "files": [],
        "patches": PATCHES,
    }

    os.makedirs(os.path.join(PROJECT, "rtl"), exist_ok=True)

    for name in CURATED_RTL:
        text = git_show(repo, rev, "rtl/" + name)
        if name == "mgc3130_v2_top.sv":
            before = text
            text = fix_top_declaration_order(text)
            record_patch(
                "rtl/" + name,
                "declare patch_crc_payload_q and hoist the P1 declaration block above "
                "v2_patch_bank so the file compiles (vlog-2388 / vlog-2730)",
            )
            assert text != before
        write_text(os.path.join(PROJECT, "rtl", name), text)
        manifest["files"].append(
            {"path": "rtl/" + name, "sha256": sha256(os.path.join(PROJECT, "rtl", name)),
             "origin": "%s:rtl/%s" % (rev, name)}
        )

    # board top
    board = fix_board_top(git_show(repo, rev, "sim/v2_top_fullpath_probe.sv"))
    write_text(os.path.join(PROJECT, "rtl", "v2_board_top.sv"), board)
    manifest["files"].append(
        {"path": "rtl/v2_board_top.sv",
         "sha256": sha256(os.path.join(PROJECT, "rtl", "v2_board_top.sv")),
         "origin": "%s:sim/v2_top_fullpath_probe.sv (module renamed)" % rev}
    )
    record_patch("rtl/v2_board_top.sv", "renamed from the probe wrapper; body unchanged")

    # testbench: untracked in the legacy tree (impl/ is gitignored), so it is
    # copied from the working tree and becomes versioned here.
    tb_src = os.path.join(repo, "impl", "ms_uartrx", "tb_top_csr_gate.sv")
    if not os.path.isfile(tb_src):
        raise SystemExit("testbench not found: " + tb_src)
    tb_text = fix_testbench(read_text(tb_src))
    write_text(os.path.join(PROJECT, "tb", "tb_top_csr_gate.sv"), tb_text)
    manifest["files"].append(
        {"path": "tb/tb_top_csr_gate.sv",
         "sha256": sha256(os.path.join(PROJECT, "tb", "tb_top_csr_gate.sv")),
         "origin": "working-tree impl/ms_uartrx/tb_top_csr_gate.sv (was untracked)"}
    )
    record_patch(
        "tb/tb_top_csr_gate.sv",
        "rxbuf read index aligned with the mod-256 write index; %0s -> %s so assertion "
        "names survive; assertion-name argument widened 256 -> 512 bits",
    )

    # vendor IP: mgc3130_reader instantiates Gowin_I2C_Master, whose name comes
    # from top_define.vh and whose body is an encrypted .vp core.  Without it the
    # synthesizer fails with EX3937 "Instantiating unknown module".
    for rel in [p for p, _kind in VENDOR_IP] + VENDOR_IP_AUX:
        dest = os.path.join(PROJECT, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            text = git_show(repo, rev, rel)
        except SystemExit:
            text = read_text(os.path.join(repo, rel))
        write_text(dest, text)
        manifest["files"].append(
            {"path": rel, "sha256": sha256(dest), "origin": "%s:%s" % (rev, rel)}
        )

    ip_list = [
        "# Vendor IP consumed by the synthesis project only.",
        "# The encrypted core (.vp) cannot be compiled by ModelSim, so these files",
        "# are deliberately kept out of filelist.f.",
        "",
    ] + [rel for rel, _kind in VENDOR_IP]
    write_text(os.path.join(PROJECT, "ip", "filelist_ip.f"), "\n".join(ip_list) + "\n")

    # constraints
    for name in ("mgc3130_v2.cst", "mgc3130_v2_top_observable.sdc"):
        text = git_show(repo, rev, name)
        if name.endswith(".sdc"):
            text = text.replace(
                "# V2 board input is 50 MHz.  The internal GW5A PLL generates the only\n"
                "# free-running system clock at 100 MHz; the PLL model/implementation exposes\n"
                "# the generated clock automatically as u_v2/u_clock/u_pll/CLKOUT0.",
                "# V2 board input is 50 MHz.  The internal GW5A PLLA generates the only\n"
                "# free-running system clock: IDIV=1, FBDIV=1, MDIV=16 -> 800 MHz VCO,\n"
                "# ODIV0=10 -> 80 MHz (see rtl/v2_clock_gen.sv).  The PLL implementation\n"
                "# exposes the generated clock automatically, so no create_generated_clock\n"
                "# is needed here.  The port/signal name `clk_sys_100m` is a leftover and\n"
                "# does NOT describe 100 MHz.",
            )
            record_patch("constr/" + name, "corrected the stale '100 MHz' comment (PLL output is 80 MHz)")
        write_text(os.path.join(PROJECT, "constr", name), text)
        manifest["files"].append(
            {"path": "constr/" + name, "sha256": sha256(os.path.join(PROJECT, "constr", name)),
             "origin": "%s:%s" % (rev, name)}
        )

    # filelist.f -- the single source of truth for both sim and synth
    fl = [
        "# Single source of truth for the V2 build.",
        "# Consumers: scripts/gate.py, scripts/sim.py, scripts/synth.py.",
        "# Order matters: packages first, then leaves, then the integration top.",
        "# NEVER compile rtl/*.sv with a wildcard -- that is what let a second",
        "# definition of mgc3130_v2_top silently win.",
        "",
    ]
    fl += ["rtl/" + name for name in CURATED_RTL]
    fl.append("rtl/v2_board_top.sv")
    write_text(os.path.join(PROJECT, "filelist.f"), "\n".join(fl) + "\n")

    write_text(os.path.join(PROJECT, "MANIFEST.json"),
               json.dumps(manifest, indent=2) + "\n")

    print("source : %s @ %s" % (repo, rev))
    print("files  : %d rtl + 1 tb + 2 constr + 1 filelist" % len(CURATED_RTL))
    print("patches: %d" % len(PATCHES))
    for p in PATCHES:
        print("  - %-28s %s" % (p["file"], p["reason"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
