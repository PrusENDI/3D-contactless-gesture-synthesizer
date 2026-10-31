# 波表三帧 morph 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 A/B/C 三张单周期表成为一张 3 帧波表，由全局 LFO 驱动 position 在 0→2→0 之间扫，相邻帧逐样本交叉淡化，在 WT_PLAY / LIVE 路径可听。

**Architecture:** 新增两个纯组合/时序小模块（`v2_wt_position` 管 LFO 与帧索引，`v2_wt_mix` 管交叉淡化），给现有 loader 加一条并行的第二读通道，其余全部在 `mgc3130_v2_top.sv` 里接线。不新增 BSRAM，不改上传协议，不改声部引擎。

**Tech Stack:** SystemVerilog、ModelSim 10.6d、Gowin EDA V1.9.12.04、PowerShell 5.1、Python 3（标准库）。

**Spec:** `docs/superpowers/specs/2026-10-31-wavetable-3-frame-morph-design.md`

## Global Constraints

- **在独立 worktree 中执行**（`using-git-worktrees`）：用户正在改 `rtl/mgc3130_v2_top.sv` 与
  `rtl/v2_live_rule_engine.sv`，在本工作区直接提交会把它们混进来。
- 每步结束必须 `python scripts/gate.py --compile` 通过：**0 error / 0 warning**。
- `filelist.f` 是唯一源。新模块必须**同一个任务里**同时加入 filelist 并在 `mgc3130_v2_top` 中实例化，否则 L0 报 `uninstantiated module`（gate.py:167-177）。
- 源文件 UTF-8 无 BOM、LF 换行、无 tab（gate.py:110-120 会记 warning）。
- 系统时钟 80 MHz，`sample_ce` 48 kHz（`v2_sample_scheduler`）。
- 上板构建走 `v2_board_top`，`PRESERVE_LOOP_PLANE` / `PRESERVE_POTTS_PLANE` 已硬接 0
  （`rtl/v2_board_top.sv:23-24`），不需要额外开关。
- position 定点 Q2.24：`1.0 = 26'h1000000`，`2.0 = 26'h2000000`；`frame_a = pos[25:24]`，`frame_b = min(frame_a+1, 2)`，`frac = pos[23:16]`。
- `WT_SELECT(0x60)` 写掩码 `0xFFFFFF07`，布局 `{step[22:0], 7'b0, morph_en, 7'b0, table[1:0]}`。
- 调试 `0xE8` 布局 `{4'b0, pos[25:8], live_active, live_gate, live_note[7:0]}`（低 10 bit 与现在一致）。
- 提交信息英文一行，写清"改了什么 + 为什么"；每个任务单独提交。

## Review Focus

1. `step=0` 或 `step` 接近端点：position 必须停在 0 / 2.0，不越界、不丢方向翻转。
2. 帧 B 未通过 APPLY（`wt_rd_valid1=0`）：输出必须退回帧 A，不能淡向静音。
3. `frame_a == frame_b`（position 落在整数点）：两个读通道同表同址，通道 1 不得读到旧字。
4. 模式切换（IDLE ↔ WT_PLAY/LIVE）：读口所有权切换不得把宿主或引擎的地址混进来。
5. 旧 host 只写 table（bit8=0）不得意外打开 morph。

---

### Task 1: position LFO 模块

**Files:**
- Create: `rtl/v2_wt_position.sv`
- Test: `tb/tb_wt_position.sv`
- Modify: `filelist.f`（`rtl/v2_tick_gen.sv` 之后插入一行）
- Modify: `rtl/mgc3130_v2_top.sv`（只加实例，输入接常量，输出悬空；Task 4 再接线）

**Interfaces:**
- Produces:
```systemverilog
module v2_wt_position (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        sample_ce,
  input  logic        morph_en,
  input  logic [22:0] step,      // Q2.24，每样本的 position 增量
  output logic [25:0] pos,       // 0 .. 26'h2000000
  output logic [1:0]  frame_a,
  output logic [1:0]  frame_b,
  output logic [7:0]  frac
);
```
- 行为：`morph_en` 上升沿把 `pos` 与方向复位为 0/up；`!morph_en` 时保持；
  `sample_ce && morph_en` 时按 `step` 加/减，到端点钳位并翻转方向。

- [ ] **Step 1: 写失败的 testbench**

`tb/tb_wt_position.sv`（风格照 `tb/tb_tick_gen.sv`：`$fatal` + `PASS` 打印）：

```systemverilog
module tb_wt_position;
  localparam logic [25:0] ONE = 26'h1000000, TWO = 26'h2000000;
  logic clk = 0, rst_n = 0, sample_ce = 0, morph_en = 0;
  logic [22:0] step = 23'd65536;
  logic [25:0] pos; logic [1:0] frame_a, frame_b; logic [7:0] frac;
  int i;

  v2_wt_position dut(.clk, .rst_n, .sample_ce, .morph_en, .step,
                     .pos, .frame_a, .frame_b, .frac);
  always #5 clk = ~clk;

  task automatic tick(input int n);
    for (i = 0; i < n; i++) begin
      @(negedge clk); sample_ce = 1;
      @(negedge clk); sample_ce = 0;
    end
  endtask

  initial begin
    repeat (3) @(negedge clk); rst_n = 1; morph_en = 1; repeat (2) @(negedge clk);
    if (pos !== 26'd0) $fatal(1, "FAIL reset pos=%0h", pos);

    tick(512);                                  // 2^25 / 2^16 = 512
    if (pos !== TWO) $fatal(1, "FAIL up end pos=%0h", pos);
    if (!(frame_a == 2'd2 && frame_b == 2'd2 && frac == 8'd0))
      $fatal(1, "FAIL end frame a=%0d b=%0d frac=%0d", frame_a, frame_b, frac);
    tick(512);
    if (pos !== 26'd0) $fatal(1, "FAIL down end pos=%0h", pos);
    $display("PASS period 512 up and down");

    step = 23'd0;                                // 停住
    tick(100);
    if (pos !== 26'd0) $fatal(1, "FAIL step0 moved pos=%0h", pos);
    $display("PASS step 0 holds");

    dut.pos = 26'h0C00000;                       // 0.75
    if (!(frame_a == 2'd0 && frame_b == 2'd1 && frac == 8'hC0))
      $fatal(1, "FAIL 0.75 mapping");
    dut.pos = 26'h1800000;                       // 1.5
    if (!(frame_a == 2'd1 && frame_b == 2'd2 && frac == 8'h80))
      $fatal(1, "FAIL 1.5 mapping");
    dut.pos = 26'h2000000;                       // 2.0
    if (!(frame_a == 2'd2 && frame_b == 2'd2 && frac == 8'd0))
      $fatal(1, "FAIL 2.0 mapping");
    $display("PASS frame mapping");

    dut.pos = 26'h1234000;                       // 非零，验证 enable 沿复位
    morph_en = 0; tick(2); morph_en = 1; tick(1);
    if (pos > 26'h100000) $fatal(1, "FAIL morph_en rising did not reset pos=%0h", pos);
    $display("PASS enable reset");
    $display("TB_WT_POSITION PASS");
    $finish;
  end
endmodule
```

- [ ] **Step 2: 跑，确认失败**

Run: `python scripts/sim_unit.py --tb tb_wt_position`
Expected: `XX testbench not found` 不成立，但编译失败 `v2_wt_position` undefined，`UNIT tb_wt_position: FAIL`。

- [ ] **Step 3: 实现 `rtl/v2_wt_position.sv`**

要点：`morph_en` 用一级寄存器做上升沿检测；方向用 `dir_up` 寄存器；加/减前判断
`pos >= TWO - step` / `pos <= step` 并钳位；`frame_a = pos[25:24]`，
`frame_b = (frame_a == 2'd2) ? 2'd2 : frame_a + 2'd1`，`frac = pos[23:16]`。

- [ ] **Step 4: 跑通**

Run: `python scripts/sim_unit.py --tb tb_wt_position`
Expected: `PASS period 512 up and down`、`PASS step 0 holds`、`PASS frame mapping`、
`PASS enable reset`、`UNIT tb_wt_position: PASS`。

- [ ] **Step 5: 接进顶层（只接线，先禁用）**

`filelist.f` 在 `rtl/v2_tick_gen.sv` 后加 `rtl/v2_wt_position.sv`；
`mgc3130_v2_top.sv` 里加实例，`.morph_en(1'b0), .step(23'd0)`，输出先不接。
这一步是为了让 L0 不报 uninstantiated module。

- [ ] **Step 6: 闸门 + 提交**

Run: `python scripts/gate.py --compile` → `0 error / 0 warning`。
```bash
git add rtl/v2_wt_position.sv tb/tb_wt_position.sv filelist.f rtl/mgc3130_v2_top.sv
git commit -m "feat: add Q2.24 wavetable position LFO with frame/frac mapping"
```

---

### Task 2: 交叉淡化模块

**Files:**
- Create: `rtl/v2_wt_mix.sv`
- Test: `tb/tb_wt_mix.sv`
- Modify: `filelist.f`、`rtl/mgc3130_v2_top.sv`（同 Task 1 Step 5 的方式）

**Interfaces:**
```systemverilog
module v2_wt_mix (
  input  logic signed [15:0] a,
  input  logic signed [15:0] b,
  input  logic        [7:0]  frac,
  output logic signed [15:0] out
);
```
- `out = a + ((b - a) * frac) >>> 8`，有符号，截断向负无穷；`frac=0` 时严格等于 `a`。

- [ ] **Step 1: 写失败的 testbench**

`tb/tb_wt_mix.sv`，用 `v2_wt_mix dut(...)`，断言：

```systemverilog
// frac 0/128/255
check(16'sd0, 16'sd32767, 8'd0,    16'sd0);      // 0
check(16'sd0, 16'sd32767, 8'd128,  16'sd16383);  // (32767*128)>>>8
check(16'sd0, 16'sd32767, 8'd255,  16'sd32639);
check(16'sd1234, 16'sd1234, 8'd200, 16'sd1234);  // a==b
check(-16'sd32768, 16'sd32767, 8'd128, -16'sd1);
```
`check` 用 `$fatal` 打印 got/want，通过时打印 `PASS`。

- [ ] **Step 2: 跑，确认失败**

Run: `python scripts/sim_unit.py --tb tb_wt_mix`
Expected: 编译失败，`UNIT tb_wt_mix: FAIL`。

- [ ] **Step 3: 实现 `rtl/v2_wt_mix.sv`**

17 bit 有符号差值 × 8 bit → 25 bit 乘积，算术右移 8 位回 16 bit。

- [ ] **Step 4: 跑通**

Run: `python scripts/sim_unit.py --tb tb_wt_mix` → `UNIT tb_wt_mix: PASS`。

- [ ] **Step 5: 进 filelist 并在顶层实例化（禁用）**

`.a(16'sd0), .b(16'sd0), .frac(8'd0)`，输出不接。

- [ ] **Step 6: 闸门 + 提交**

Run: `python scripts/gate.py --compile`。
```bash
git add rtl/v2_wt_mix.sv tb/tb_wt_mix.sv filelist.f rtl/mgc3130_v2_top.sv
git commit -m "feat: add 8-bit-frac crossfade mixer for wavetable frames"
```

---

### Task 3: loader 第二读通道

**Files:**
- Modify: `rtl/v2_wavetable_loader.sv`（读口 190-197、215、232-240 附近）
- Test: `tb/tb_wt_dual_read.sv`

**Interfaces:**
- Produces（新增端口，旧端口全部保留）：
```systemverilog
input  logic [1:0]  wt_rd_table0, wt_rd_table1,
input  logic [9:0]  wt_rd_index0, wt_rd_index1,
output logic signed [15:0] wt_rd_sample0, wt_rd_sample1,
output logic        wt_rd_valid0,  wt_rd_valid1,
```
- 语义：通道 0/1 各自用**寄存后的表号**选择 `mem_rd_data`（DPB 输出晚 1 拍）；
  `wt_rd_valid*` = 该表 active bank 的 `covered_count == BLOCKS`。
- 约束：两张表相同时只置一次读使能，两通道同址同数据；**同表不同址是非法用法**，不做仲裁。

- [ ] **Step 1: 写失败的 testbench**

`tb/tb_wt_dual_read.sv`：实例化 loader（`USE_GOWIN_RAM=0`），用与
`tb/tb_top_csr_gate.sv:174-216` 相同的上传序列直接驱动 loader 端口，把两张表写满：

- 表 0 图案 `p0[k] = (k * 3) & 0x7FFF`，表 1 图案 `p1[k] = (0x7FFF - k * 5) & 0x7FFF`；
- CRC 用 loader 里同一个 MSB-first `crc16_sample` 函数（在 tb 里复制一份）；
- 版本按 T1→T4 的规则：先 `wt_version_reg = 0`，APPLY 后 active 变 1；第二张表用 1。

断言：

```systemverilog
// 各自读
rd(2'd0, 10'd5, 2'd1, 10'd7);
if (s0 !== p0[5]) $fatal(1, "FAIL ch0 %0h", s0);
if (s1 !== p1[7]) $fatal(1, "FAIL ch1 %0h", s1);
// 同表同址
rd(2'd0, 10'd9, 2'd0, 10'd9);
if (s0 !== s1) $fatal(1, "FAIL same-table mismatch %0h/%0h", s0, s1);
if (!(v0 && v1)) $fatal(1, "FAIL valid not set");
// 从未 APPLY 的表 2：valid 必须为 0（上层据此退回帧 A）
rd(2'd0, 10'd1, 2'd2, 10'd1);
if (v1 !== 1'b0) $fatal(1, "FAIL unapplied table reports valid");
$display("TB_WT_DUAL_READ PASS");
```

- [ ] **Step 2: 跑，确认失败**

Run: `python scripts/sim_unit.py --tb tb_wt_dual_read`
Expected: 编译失败（端口不存在），`UNIT tb_wt_dual_read: FAIL`。

- [ ] **Step 3: 实现第二读通道**

`always_comb` 里：`mem_rd_en[ct][bank] = (ct==wt_rd_table0) || (ct==wt_rd_table1)`；
地址 `(ct==wt_rd_table1) ? wt_rd_index1 : wt_rd_index0`；两个新表号各打一拍寄存器，
用寄存值选 `mem_rd_data`。旧通道 `wt_read_*` 一行不改。

- [ ] **Step 4: 跑通**

Run: `python scripts/sim_unit.py --tb tb_wt_dual_read` → `UNIT tb_wt_dual_read: PASS`。

- [ ] **Step 5: 闸门 + 提交**

Run: `python scripts/gate.py --compile`。
```bash
git add rtl/v2_wavetable_loader.sv tb/tb_wt_dual_read.sv
git commit -m "feat: add a second registered read channel to the wavetable loader"
```

---

### Task 4: 顶层接线、CSR 与 0xE8

**Files:**
- Modify: `rtl/v2_contract_pkg.sv`（`V2_CSR_WT_SELECT_WRITE_MASK`、两个 shift 常量）
- Modify: `rtl/mgc3130_v2_top.sv`（读口驱动、音频 mux、CSR 读回、0xE8）
- Modify: `tb/tb_top_csr_gate.sv`（新增两条断言）

**Interfaces:**
- Consumes: Task 1-3 的模块与端口。
- Produces: `wt_morph_en`、`wt_lfo_step[22:0]`、`wt_pos[25:0]`；`WT_SELECT` 新布局。

- [ ] **Step 1: 先在顶层 tb 里写失败的断言**

`tb/tb_top_csr_gate.sv` 在 T4 之后、`if (errors == 0)` 之前插入：

```systemverilog
// WT_SELECT 新布局：step[22:0] | morph_en<<8 | table
host_cmd(8'h02, 8'h60, 32'h0024_6901, rtype, rerr, rdata);   // step=0x1234, morph=1, table=1
host_cmd(8'h01, 8'h60, 32'd0, rtype, rerr, rdata);
expect_eq(rdata, 32'h0024_6901, "wt_select_morph_roundtrip");
host_cmd(8'h02, 8'h60, 32'h0000_0001, rtype, rerr, rdata);   // 只写 table
host_cmd(8'h01, 8'h60, 32'd0, rtype, rerr, rdata);
expect_eq(rdata, 32'h0000_0001, "wt_select_no_morph_when_bit8_clear");
```
注意 `0x0024_6901` 的低 3 bit 是 1（table=1），bit8=1（morph）。

- [ ] **Step 2: 跑，确认失败**

Run: `python scripts/sim_unit.py --tb tb_top_csr_gate`
Expected: `FAIL wt_select_morph_roundtrip`（旧掩码把高位截掉），`UNIT tb_top_csr_gate: FAIL`。

- [ ] **Step 3: 改 contract 与顶层**

- `V2_CSR_WT_SELECT_WRITE_MASK` → `32'hFFFFFF07`；
  加 `V2_CSR_WT_SELECT_MORPH_EN_SHIFT=8`、`V2_CSR_WT_SELECT_LFO_STEP_SHIFT=9`。
- 顶层用 `wt_select_table = cmd_data[1:0]`、`wt_morph_en = cmd_data[8]`、
  `wt_lfo_step = cmd_data[31:9]`；读回 `{wt_lfo_step, 7'd0, wt_morph_en, 7'd0, wt_select_table}`。
- 读口：`wt_rd_table0 = (mode_wt_play||mode_live) ? (wt_morph_en ? wt_frame_a : wt_select_table) : wt_select_table`，
  `wt_rd_table1` 同理用 `wt_frame_b`；两个 index 都接 `wt_read_index_sel`。
- 音频：`wt_table_sample = (wt_morph_en && wt_rd_valid1) ? wt_mix_out : wt_rd_sample0`，
  送进 `v2_wt_playback.sample`（原来的 `wt_read_sample`）；帧 B 未 APPLY 时自动退回帧 A；
  `wt_quiet` 与包络路径不动。
- `v2_wt_position` 的 `morph_en` 接 `wt_morph_en && (mode_wt_play||mode_live)`，`step` 接 `wt_lfo_step`。
- `0xE8` 改为 `{4'd0, wt_pos[25:8], live_active, live_gate, live_active_note}`。

- [ ] **Step 4: 跑通**

Run: `python scripts/sim_unit.py --tb tb_top_csr_gate`
Expected: `PASS wt_select_morph_roundtrip`、`PASS wt_select_no_morph_when_bit8_clear`、
`TB_TOP_CSR_GATE PASS`。

- [ ] **Step 5: 全回归**

Run: `python scripts/gate.py --compile` → `0 error / 0 warning`。
Run: `python scripts/sim.py` → 失败集 ⊆ `sim_baseline.json`。

- [ ] **Step 6: 提交**

```bash
git add rtl/v2_contract_pkg.sv rtl/mgc3130_v2_top.sv tb/tb_top_csr_gate.sv
git commit -m "feat: wire 3-frame morph into WT_SELECT, the table read path and 0xE8"
```

---

### Task 5: 上位机相位对齐工具

**Files:**
- Create: `host/wavetable_frames.py`

**Interfaces:**
- CLI：`python host/wavetable_frames.py --in a.bin b.bin c.bin --out-dir frames --period 20`
- 输出：`frames/frame0.bin`…`frame2.bin`、`frames/frames.json`
  （含每帧 crc16、基波相位、`lfo_step`）。
- 函数：`align_phase(samples: list[int]) -> list[int]`、
  `lfo_step(period_seconds: float) -> int`（`round(2**25 / (period*48000))`，钳位 1..0x7FFFFF）。

- [ ] **Step 1: 写 `--selftest`（先失败）**

```python
def selftest() -> int:
    n = 1024
    frames = [
        [int(0.9 * 32767 * math.sin(2 * math.pi * k / n + ph)) for k in range(n)]
        for ph in (0.0, 1.0, 2.5)
    ]
    out = [align_phase(f) for f in frames]
    for i, f in enumerate(out):
        re, im = fundamental(f)
        ang = math.atan2(im, re)
        assert abs(ang) < 0.02, f"frame {i} phase {ang}"
        assert max(abs(v) for v in f) <= int(0.9 * 32767) + 1
    assert align_phase(frames[0]) == align_phase(frames[0]), "not deterministic"
    assert lfo_step(20.0) == 35 and lfo_step(1.0) == 699
    print("WAVETABLE_FRAMES SELFTEST PASS")
```

- [ ] **Step 2: 跑，确认失败**

Run: `python host/wavetable_frames.py --selftest`
Expected: `ImportError`/`AttributeError`，非零退出。

- [ ] **Step 3: 实现**

- `fundamental(samples)`：`Σ s[k]·e^{-j2πk/N}` 的实部/虚部。
- `align_phase`：`Δ = atan2(im, re) / (2π) * N`；对循环缓冲做**分数延迟**（线性插值）；
  再去 DC、峰值归一到 `int(0.9*32767)`。线性插值在 32 次谐波处衰减 <1%，可接受。
- `lfo_step` 按上式，`period=0` 报错。

- [ ] **Step 4: 跑通**

Run: `python host/wavetable_frames.py --selftest` → `WAVETABLE_FRAMES SELFTEST PASS`。

- [ ] **Step 5: 提交**

```bash
git add host/wavetable_frames.py
git commit -m "feat: phase-align N gesture frames and compute the LFO step for the morph table"
```

---

### Task 6: 板级脚本

**Files:**
- Modify: `scripts/board_wt_upload.ps1`（新增 `-PostSelect <uint32>`：APPLY 成功后补写一次 `WT_SELECT`）
- Create: `scripts/board_wt_morph.ps1`（三次上传 + 最后一次带 `-PostSelect`）

**Interfaces:**
- `board_wt_upload.ps1` 现有参数不变；新增可选 `-PostSelect`，`-DryRun` 时打印最终 `WT_SELECT` 字。
- `board_wt_morph.ps1 -Frame0 a.bin -Frame1 b.bin -Frame2 c.bin -Period 20 [-DryRun]`。

- [ ] **Step 1: 先写 DryRun 断言（失败）**

`board_wt_morph.ps1 -DryRun` 必须打印且退出 0：

```
MORPH PLAN: 3 tables, step=<n>, select=0x<8hex>
```

- [ ] **Step 2: 跑，确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_wt_morph.ps1 -Frame0 a.bin -Frame1 b.bin -Frame2 c.bin -Period 20 -DryRun`
Expected: 脚本不存在，非零退出。

- [ ] **Step 3: 实现**

`board_wt_morph.ps1` 依次调用 `board_wt_upload.ps1` 三次（第 3 次带
`-PostSelect ((step -shl 9) -bor 0x100 -bor 2)`）；每步检查退出码。
`-PostSelect` 用与上传脚本相同的 `X` 函数写 `0x60`，并校验 `err=0`。

- [ ] **Step 4: 跑通 DryRun**

Run: 同 Step 2，Expected: 打印 `MORPH PLAN: 3 tables, step=35, select=0x00004702` 并退出 0
（`35<<9 = 0x4600`，`| 0x100`，`| table 2` = `0x4702`）。

- [ ] **Step 5: 提交**

```bash
git add scripts/board_wt_upload.ps1 scripts/board_wt_morph.ps1
git commit -m "feat: upload three frames and set the morph LFO in one board script"
```

---

### Task 7: 文档同步 + GAO + 上板验收

**Files:**
- Modify: `docs/DEBUG-AND-FLASH.md`（`0xE8` 高 18 bit = `pos[25:8]`；`WT_SELECT` 新布局）
- Modify: `host/cursor_view.py`（解 `0xE8` 低 10 bit 不变；新增 position 显示）
- Create: `gao/wt_morph.rao`

- [ ] **Step 1: 写 GAO 探针文件**

`gao/wt_morph.rao`：`sample_clock` = `clk_sys_100m`，`storage_depth=2048`，
信号 `wt_pos[25:8]`、`wt_frame_a`、`wt_frame_b`、`wt_frac`、`wt_rd_sample0`、`wt_rd_sample1`、`wt_table_sample`；
必须包含 `<Expressions type="Static"><Expression>M0</Expression></Expressions>`。

- [ ] **Step 2: 文档与显示同步**

`DEBUG-AND-FLASH.md` 的调试表加一行：`0xE8` 高 18 bit = `pos[25:8]`（仅 `V2_DEBUG_CSR=1`）。
`cursor_view.py` 只加显示，不改低 10 bit 的解析。

- [ ] **Step 3: 全量闸门**

Run: `python scripts/gate.py --compile` → `0 error / 0 warning`。
Run: `python scripts/sim.py` → 失败集 ⊆ baseline。
Run: `python scripts/synth.py --run-id morph1` → `SYNTH: PASS`，记录 `bitstream_sha256`
与**违约端点数**（必须 0）；这是**听感/功能**用的位流。
Run: `python scripts/synth.py --run-id morph1_gao --gao gao/wt_morph.rao` → 同样记录 sha256
与违约端点数；这是**抓波形**用的位流。

- [ ] **Step 4: 上板**

1. 烧 `impl/v2_board_top_morph1/impl/pnr/v2_board_top.fs`（绝对路径，`-Operation 4`）；
2. 等 3–5 s，读 `0xB0` == `0x5A5A0003`；
3. `python host/wavetable_frames.py --in sine.bin saw.bin square.bin --out-dir frames --period 20`；
4. `powershell -File scripts/board_wt_morph.ps1 -Frame0 frames/frame0.bin ... -Period 20`；
5. `python host/cursor_view.py --console-only --seconds 10`：`0xE8[27:10]` 应单调变化，
   10 s 内翻转周期 ≈ 20.6 s（用两次翻转之间的时间算，±2%）；
6. 扫表期间重传帧 C，听感无中断；
7. 听感：正弦→锯齿→方波→锯齿→正弦，无咔嗒、无中点塌陷。

- [ ] **Step 5: GAO 抓一次**

先烧 `impl/v2_board_top_morph1_gao/impl/pnr/ao_0.fs`（先烧后抓，GAO 与烧录共用 JTAG），
再跑：
Run: `python scripts/gao_capture.py --rao gao/wt_morph.rao --out artifacts/gao/morph1.csv --force-trigger-timeout 90`
Expected: 抓到 `wt_frac` 真实跳变（`change points > 0`），窗口 = 2048/80 MHz = 25.6 µs 并写进报告。

- [ ] **Step 6: 提交**

```bash
git add docs/DEBUG-AND-FLASH.md host/cursor_view.py gao/wt_morph.rao
git commit -m "docs: record the morph register layout and add its GAO probe"
```

---

## Self-Review

- **Spec 覆盖**：§4.1 帧语义（Task 1/3/4）、§4.2 position（Task 1）、§4.3 双读（Task 3）、
  §4.4 寄存器（Task 4）、§4.5 模式行为（Task 4 Step 3）、§4.6 host（Task 5/6）、
  §6 验收（Task 7）、§6.7 文档同步（Task 7）。§9 阶段 1.5 属于下一个计划，本计划不覆盖。
- **步长**：每个 Step 只有一件事；测试先写后实现；每个任务独立提交。
- **类型一致**：`wt_rd_table0/1`、`wt_rd_index0/1`、`wt_rd_sample0/1`、`wt_rd_valid0/1`
  在 Task 3 定义、Task 4 使用，名称一致；`wt_morph_en`/`wt_lfo_step`/`wt_pos` 在 Task 4 定义并在 Task 7 使用。
- **Review Focus 对应**：1→Task 1 Step 1；2→Task 3 Step 1 / Task 4；3→Task 3 Step 1；
  4→Task 4 Step 3 与 `tb_top_csr_gate`；5→Task 4 Step 1 第二条断言。
- **比例**：计划约 380 行，规格约 350 行；没有贴实现代码，只给签名、常量与断言。
