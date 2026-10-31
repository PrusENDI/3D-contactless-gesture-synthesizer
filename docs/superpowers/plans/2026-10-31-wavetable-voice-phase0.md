# 阶段 0：波表音色链路 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让板上按音符速率读出上位机下发的 1024 点波表并输出正确音高，形成"手势 → 解算 → 下发 → 发声"的最小闭环。

**Architecture:** 复用已完成的上传链路（3 表 × 2 bank + CRC16 + APPLY），只把播放器的固定 46.875 Hz 相位步进换成外部增量（音符 → `v2_note_increment_rom` → 32 bit 相位），测试音符放在未实现的 `THRESHOLDS[7:0]`。上位机新增三个工具：抓轨迹、解算波表、分块下发。

**Tech Stack:** SystemVerilog（Gowin GW5A）、ModelSim `C:/modeltech64_10.6d/win64`、Gowin EDA V1.9.12.04、Python 3（只用标准库）、PowerShell（串口 I/O）。

**Spec:** `docs/system-design-2026-10-31.md`（阶段 0 部分）

## Global Constraints

- 器件 GW5A-LV25MG121NES：CLS 上限 11520（当前 11029）、LUT 23040（当前 20016）、BSRAM 56（当前 36）。阶段 0 预算 +10 LUT，不得超。
- 系统时钟 80 MHz（PLL 50 MHz × 16 / 10），音频 `sample_ce` = 48 kHz，传感实测 138 Hz。
- 编译必须 0 error **0 warning**；仿真必须带 `+define+V2_SIM`（否则 PLL 原语不解锁）。
- **不新增 CSR 地址**；测试音符用已定义但未实现的 `V2_CSR_THRESHOLDS = 0x30`。
- `THRESHOLDS[7:0] == 0` 时播放器必须保持现状（`increment = 65536`，46.875 Hz）。
- 波表格式：1024 点 × int16、一个周期、首点 = 相位 0、去 DC、峰值 ≤ 0.9 FS、限带 32 谐波、CRC16/CCITT-FALSE。
- UART：1 Mbaud，命令帧 11 字节（`A5 02 01 addr seq data[4] crc_hi crc_lo`，CRC 覆盖 byte 0..8），应答 22 字节，数据在 `[14:17]`（大端）。
- 每个 L3 构建记录位流 sha256；未跑的项必须写进报告。

## Review Focus

1. `THRESHOLDS[7:0] == 0` 的默认路径（46.875 Hz）——回归会让旧验收静默失效。
2. 音符不在 8 个五声内时 `increment == 0`（静音），必须与"播放器坏了"可区分。
3. APPLY 扫描期间读表——切换中的 bank 可能采到半个旧表。
4. 32 bit 相位在高音（C5，inc 46,819,719）每 91.8 采样溢出一次，索引必须天然 mod 1024。
5. 串口丢字节导致 22 字节帧错位——捕获工具必须识别并丢弃，而不是写进日志。

---

### Task 1: 单元测试脚手架 + 播放器测试（先红）

**Files:**
- Create: `scripts/sim_unit.py`
- Create: `tb/tb_wt_playback.sv`

**Interfaces:**
- Produces: `python scripts/sim_unit.py --tb tb_wt_playback`，退出码 0 = PASS，1 = FAIL/编译失败。后续任务都用它。

- [ ] **Step 1: 写失败测试 `tb/tb_wt_playback.sv`**

DUT 端口按 Task 2 的目标接口写（现在还不存在，所以会编译失败——这就是红）。

```systemverilog
module tb_wt_playback;
  logic clk = 0, rst_n = 0, sample_ce = 0, enable = 1;
  logic [9:0] index;
  logic signed [15:0] sample = 16'sd1000, out;
  logic valid;
  logic [31:0] increment;
  int wraps, samples, i;

  v2_wt_playback dut(.clk, .rst_n, .sample_ce, .enable, .index, .sample, .out, .valid, .increment);

  always #5 clk = ~clk;                       // 100 MHz 仿真时钟

  task automatic run(int signed_inc, int n_samples);
    increment = signed_inc; wraps = 0; samples = n_samples;
    @(negedge clk); rst_n = 1;
    for (i = 0; i < n_samples; i++) begin
      @(negedge clk); sample_ce = 1; @(negedge clk); sample_ce = 0;
      if (index == 10'd0 && i > 0) wraps++;
    end
  endtask

  initial begin
    run(32'd39370534, 48000);                 // A4 = 440 Hz
    if (wraps < 439 || wraps > 441) $fatal(1, "FAIL a4_wraps: %0d (expect 440)", wraps);
    $display("PASS a4_wraps = %0d", wraps);

    run(32'd65536, 48000);                    // 46.875 Hz legacy
    if (wraps < 46 || wraps > 47) $fatal(1, "FAIL legacy_wraps: %0d (expect 46..47)", wraps);
    $display("PASS legacy_wraps = %0d", wraps);

    run(32'd0, 4096);                         // silence
    if (wraps != 0) $fatal(1, "FAIL zero_increment_wraps: %0d", wraps);
    if (index != 10'd0) $fatal(1, "FAIL zero_increment_index: %0d", index);
    $display("PASS zero_increment");
    $finish;
  end
endmodule
```

- [ ] **Step 2: 写 `scripts/sim_unit.py`**

职责：编译 `filelist.f` + `tb/<name>.sv` + `prim_sim.v`，运行 `work.<name>`，任何 `FAIL`/`$fatal`/`Errors:` 非零即失败。命令行：

```
python scripts/sim_unit.py --tb tb_wt_playback
```

实现要点（与 `scripts/sim.py` 同款环境变量）：
- `MODELSIM_BIN`（默认 `C:/modeltech64_10.6d/win64`）、`PRIM_SIM`（默认 `C:/Gowin/Gowin_V1.9.12.04_x64/IDE/simlib/gw5a/prim_sim.v`）
- 运行目录 `.sim_unit`（每次清空），`vlib work` → `vlog -sv +define+V2_SIM -work work <filelist> tb/<tb>.sv <prim_sim>` → `vsim -c -novopt work.<tb> -do "run -all; quit -f"`
- 日志写 `sim_logs/unit_<tb>.log`
- 编译要求 `Errors: 0, Warnings: 0`；运行要求日志含 `PASS` 且不含 `FAIL`

- [ ] **Step 3: 运行，确认失败**

Run: `python scripts/sim_unit.py --tb tb_wt_playback`
Expected: 非零退出，编译错误提到 `increment` 端口不存在（`vlog-2110` 或类似）。

- [ ] **Step 4: 提交脚手架 + 红测试**

```bash
git add scripts/sim_unit.py tb/tb_wt_playback.sv
git commit -m "test: unit-test harness and failing wavetable playback test"
```

---

### Task 2: 播放器接受外部相位增量

**Files:**
- Modify: `rtl/v2_wt_playback.sv`（全文 47 行，替换相位部分）
- Test: `tb/tb_wt_playback.sv`（Task 1 已写）

**Interfaces:**
- Consumes: `increment[31:0]`（每 `sample_ce` 加一次）
- Produces: `index = phase[31:22]`（1024 点/周期）；`out/valid` 语义不变（`out` 比 `index` 晚一拍）

- [ ] **Step 1: 改端口与相位**

```systemverilog
module v2_wt_playback (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               enable,
    input  logic [31:0]        increment,   // NEW
    output logic [9:0]         index,
    input  logic signed [15:0] sample,
    output logic signed [15:0] out,
    output logic               valid
);
```

相位改为 32 bit：`phase <= phase + increment;`，`assign index = phase[31:22];`。
删除 `26'd65536` 常量；`out/valid` 寄存器逻辑一字不改。

- [ ] **Step 2: 运行单元测试**

Run: `python scripts/sim_unit.py --tb tb_wt_playback`
Expected: 三行 PASS（`a4_wraps`/`legacy_wraps`/`zero_increment`），退出码 0。

- [ ] **Step 3: 确认没有别的地方实例化这个模块**

Run: `rg -n "v2_wt_playback" rtl/ tb/`
Expected: 只有 `rtl/mgc3130_v2_top.sv` 一处实例化（下个任务改它）和本测试。

- [ ] **Step 4: 提交**

```bash
git add rtl/v2_wt_playback.sv
git commit -m "feat: wavetable playback takes an external phase increment"
```

---

### Task 3: 顶层把测试音符接到播放器

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`（CSR 复位段 ~724、读写段 ~769/~888、实例化 ~631）
- Test: `tb/tb_top_csr_gate.sv`（追加一条 CSR 断言）

**Interfaces:**
- Consumes: `V2_CSR_THRESHOLDS = 0x30`（`v2_contract_pkg`，写掩码 `0xFFFFFFFF`）
- Produces: `thresholds_reg[31:0]`；`wt_increment = (thresholds_reg[7:0] == 0) ? 32'd65536 : note_increment(thresholds_reg[7:0])`

- [ ] **Step 1: 写失败断言（`tb/tb_top_csr_gate.sv`）**

在已有 CSR 用例表末尾加一条，名字必须是 `thresholds_roundtrip`：

```systemverilog
// write 0x30 = 0x00000045 (note 69), read back
csr_write(8'h30, 32'h0000_0045);
check("thresholds_roundtrip", csr_read(8'h30) == 32'h0000_0045);
```

（`csr_write`/`check` 用该文件已有的同名辅助函数；若名字不同，用文件里现成的写/读/断言辅助。）

- [ ] **Step 2: 跑回归确认红**

Run: `python scripts/sim.py --ram 1`
Expected: 出现 NEW failing assertion `thresholds_roundtrip`（读回 0）。

- [ ] **Step 3: 实现 CSR 寄存器**

在复位段加 `thresholds_reg <= 32'd0;`；写段加

```systemverilog
if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_THRESHOLDS) thresholds_reg <= cmd_data;
```

读段加 `V2_CSR_THRESHOLDS: rsp_data <= thresholds_reg;`。

- [ ] **Step 4: 驱动播放器增量**

`import v2_contract_pkg::*;` 已在作用域内则直接复用；否则实例化 ROM：

```systemverilog
logic [31:0] wt_note_increment;
v2_note_increment_rom u_wt_note_increment(.note(thresholds_reg[7:0]), .increment(wt_note_increment));
assign wt_increment = (thresholds_reg[7:0] == 8'd0) ? 32'd65536 : wt_note_increment;
```

并把 `wt_increment` 接到 `u_wt_playback.increment`。

- [ ] **Step 5: 跑回归**

Run: `python scripts/sim.py`
Expected: `RAM=0 vs RAM=1 identical: yes`，失败集合仍是基线子集，`thresholds_roundtrip` 通过。

- [ ] **Step 6: 编译门禁 + 构建**

Run: `python scripts/gate.py --compile`
Expected: `0 errors, 0 warnings`。
Run: `python scripts/synth.py --run-id wt_p0`
Expected: `synth_summary.json` 里 `exit_code: 0`，`violations` 为 0；记录 `bitstream_sha256`；CLS 增量 ≤ +10。

- [ ] **Step 7: 提交**

```bash
git add rtl/mgc3130_v2_top.sv tb/tb_top_csr_gate.sv
git commit -m "feat: THRESHOLDS[7:0] selects the WT_PLAY test note"
```

---

### Task 4: 抓一段手部轨迹

**Files:**
- Create: `scripts/board_capture_xy.ps1`
- Create: `host/fixtures/xy_capture_sample.jsonl`（10 行夹具，供 Task 5 使用）

**Interfaces:**
- Produces: JSONL，每行 `{"seq":<int>,"x":<0..65535>,"y":<0..65535>}`，按采集顺序追加。
- Consumes: 现有调试 CSR——`0xF0` = `cursor_x`，`0xD8` = `cursor_y`（`scripts/board_cursor_trace.ps1` 已在用）。

- [ ] **Step 1: 写脚本**

参数：`-Port COM4 -Baud 1000000 -Seconds 3 -Out artifacts/board/xy.jsonl`。
循环体（无 sleep）：
1. `Read-Csr 0xF0` → x；`Read-Csr 0xD8` → y（复用 `board_cursor_trace.ps1` 里的 11 字节帧构造与 CRC16）；
2. **坏帧丢弃**：任一 `Read-Csr` 返回 `$null`（22 字节没收齐）则跳过整对，不写日志；
3. 追加一行 JSONL，`seq` 自增。

- [ ] **Step 2: 自测（无板）**

加 `-Fixture <path>` 模式：从文件读预置的 22 字节应答块，走同一条解析路径；配一个 10 行的夹具文件。
Run: `pwsh -File scripts/board_capture_xy.ps1 -Fixture host/fixtures/xy_capture_sample.jsonl`
Expected: 输出 10 行、`x`/`y` 都在 0..65535、`seq` 连续、退出码 0。

- [ ] **Step 3: 提交**

```bash
git add scripts/board_capture_xy.ps1 host/fixtures/xy_capture_sample.jsonl
git commit -m "feat: capture cursor x/y to JSONL over UART"
```

---

### Task 5: 弧长相位解算器

**Files:**
- Create: `host/wavetable_from_capture.py`
- Test: built-in `--selftest`（本项目 Python 工具不引入 pytest，脚本自带断言并以退出码报告）

**Interfaces:**
- Consumes: Task 4 的 JSONL
- Produces: `wavetable_from_capture.py --in xy.jsonl --out lead.bin --phase arc|time|x --axis y`
  输出 1024 × little-endian int16，另写 `lead.json`（`{"len":1024,"peak":…,"mean":…,"harmonics":32,"crc16":…}`）。

- [ ] **Step 1: 写 selftest（先红）**

`--selftest` 生成合成轨迹并断言四条：

```python
# 1 Hz 正弦、x 单调、200 Hz 采 400 点
xs = [i/(N-1) for i in range(N)]
ys = [0.5 + 0.4*sin(2*pi*i/(N/2)) for i in range(N)]
tbl = solve(xs, ys, phase="x", axis="y", n=1024)
assert len(tbl) == 1024
assert abs(mean(tbl)) < 1.0
assert abs(max(abs(v) for v in tbl) - 0.9*32767) <= 1
assert correlation(tbl, resample_reference()) > 0.99
# 确定性
assert solve(xs, ys, phase="x") == solve(xs, ys, phase="x")
```

谐波断言：对结果做 64 点 DFT，第 33 次及以上的能量总和 < −60 dBFS（相对基波）。

- [ ] **Step 2: 运行确认红**

Run: `python host/wavetable_from_capture.py --selftest`
Expected: `ModuleNotFoundError`/`AttributeError`（`solve` 不存在），退出码非 0。

- [ ] **Step 3: 实现解算**

```python
def solve(xs, ys, phase="arc", axis="y", n=1024, deadzone=40.0, iir=0.35, median=5) -> list[int]
```

顺序（严格按此实现）：
1. 每轴 `median`(5) 中值滤波 → 再用 `iir` 做一阶低通（`y = y + 0.35*(x-y)`）；
2. 相位：`arc` → `ds = hypot(dx, dy)`，`ds < deadzone` 记 0，累加后归一；
   `time` → 按序号线性归一；`x` → 按 x 线性归一（要求 x 单调，否则报错退出）；
3. 重采样到 `n` 点（线性插值）；
4. 去均值、峰值归一到 `0.9*32767`、四舍五入为 int；
5. 限带：对结果做 32 次谐波的 DFT → 截断 → IDFT；
6. 再归一到 0.9 FS，返回。

- [ ] **Step 4: 运行 selftest**

Run: `python host/wavetable_from_capture.py --selftest`
Expected: 四类断言全过，打印 `SELFTEST PASS`，退出码 0。

- [ ] **Step 5: 用夹具跑一次真实输入**

Run: `python host/wavetable_from_capture.py --in host/fixtures/xy_capture_sample.jsonl --out artifacts/wt/test.bin`
Expected: 生成 `test.bin`（2048 字节）与 `test.json`，退出码 0。

- [ ] **Step 6: 提交**

```bash
git add host/wavetable_from_capture.py
git commit -m "feat: arc-length phase solver for the wavetable"
```

---

### Task 6: 分块下发 + CRC + APPLY

**Files:**
- Create: `scripts/board_wt_upload.ps1`

**Interfaces:**
- Consumes: `lead.bin`（1024 × int16）
- Produces: 1024 次 `WT_INDEX`(`0x64`) 写 + `WT_DATA`(`0x68`) 写 → `WT_CRC`(`0x70`) 写 → `WT_VERSION`(`0x74`) 写 → `WT_APPLY`(`0x78`) 写（表号在 `WT_SELECT[1:0]`，`0x60`）

- [ ] **Step 1: 写脚本（含已知向量自测）**

先写 `Get-Crc16` 的自测：CRC16/CCITT-FALSE of ASCII `"123456789"` 必须等于 `0x29B1`，不等则退出 1。

写序（每步都校验 ACK 的状态码，`0`=ACCEPTED）：
```
WT_SELECT = table(0..2)
for i in 0..1023: WT_INDEX = i; WT_DATA = sample[i]
WT_CRC = crc16(bytes)
WT_VERSION = version
WT_APPLY = (version << 16) | table
读回 WT_STATUS(0x7C) 等 APPLY 完成；超时 500 ms 退出 1
```

- [ ] **Step 2: 自测（无板，dry-run）**

加 `-DryRun`：只打印将发送的命令序列与 CRC，不发串口。
Run: `pwsh -File scripts/board_wt_upload.ps1 -Bin artifacts/wt/test.bin -DryRun`
Expected: 打印 `crc16=0x29B1` 的自测通过、1024 条写、APPLY 帧，退出码 0。

- [ ] **Step 3: 板上跑一次并读回**

Run: `pwsh -File scripts/board_wt_upload.ps1 -Bin artifacts/wt/test.bin -Port COM4`
Expected: 每步 ACK，最后 `APPLIED`；随后 `scripts/board_readback.ps1` 的 1024 点读回校验通过（该脚本已存在）。

- [ ] **Step 4: 提交**

```bash
git add scripts/board_wt_upload.ps1
git commit -m "feat: wavetable upload with CRC and APPLY"
```

---

### Task 7: 板上音高验收

**Files:**
- Create: `scripts/board_wt_accept.ps1`
- Create: `artifacts/board/wt_accept.md`（结果记录，含位流 sha256）

**Interfaces:**
- Consumes: Task 6 的上传脚本、`MODE`(`0x04`) 写 `WT_PLAY`、`THRESHOLDS`(`0x30`) 写音符
- Produces: 一份带通过/失败逐条的 markdown 报告

- [ ] **Step 1: 写脚本**

对每个音符跑一遍：写 `THRESHOLDS = note`，写 `MODE = WT_PLAY`，用 `scripts/gao_capture.py` 抓 I2S 数据 20 ms，数相邻上升沿间隔的均值 → 换算频率，与期望值比 ±0.5%。

音符与期望周期（48 kHz）：`69 → 109.09`、`55 → 244.90`、`64 → 145.63`、`72 → 91.80`。

- [ ] **Step 2: 跑板上验收**

Run: `pwsh -File scripts/board_wt_accept.ps1 -Port COM4 -BitstreamSha256 <sha>`
Expected: 四条 `PASS`；任何一条超差则退出 1 并把实测值写进报告。

- [ ] **Step 3: 验证 A/B 表不同（Review Focus 3 的测试）**

上传正弦到表 A、上传方波到表 B，各抓 20 ms，断言两份波形的三次谐波比差异 > 20 dB（证明读的是表，且没有读到切换中的 bank）。

- [ ] **Step 4: 验证默认路径没回归（Review Focus 1）**

写 `THRESHOLDS = 0`，重抓：周期必须是 46.875 Hz（1024 采样/周期）±0.5%。

- [ ] **Step 5: 验证五声音级之外是静音而不是故障（Review Focus 2）**

写 `THRESHOLDS = 61`（不在 ROM 里）：预期输出全零，且 `live_fault/loop_fault` 不变；报告写"静音符合预期"。

- [ ] **Step 6: 提交报告**

```bash
git add scripts/board_wt_accept.ps1 artifacts/board/wt_accept.md
git commit -m "test: phase-0 board acceptance for wavetable pitch"
```

---

## Self-Review

- **Spec coverage**：§3.2 三处改动 → Task 2/3（表选择 A/B/C 已存在，Task 7 Step 3 验证）；§3.3 解算器 → Task 5；§3.4 六条验收 → Task 7 的四条 + Task 5 的四条 + Task 6 的读回；§1 上行 → Task 4。
- **Step scan**：每个 step 只做一件事，代码块只出现在测试断言与端口定义处；实现体的算法（解算顺序、CRC 写序）逐条列出，因为签名和测试决定不了它们。
- **Type consistency**：`increment[31:0]`（Task 2）→ `wt_increment`（Task 3）→ `inc = f/48000×2^32`（Task 5 的期望值、Task 7 的周期）三处一致。
- **Review Focus 的测试归属**：1 → Task 7 Step 4；2 → Task 7 Step 5；3 → Task 7 Step 3；4 → Task 1 的 `a4_wraps`/高音用例；5 → Task 4 Step 2 的坏帧丢弃。
