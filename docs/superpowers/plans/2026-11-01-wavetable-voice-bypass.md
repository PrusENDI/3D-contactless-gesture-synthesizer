# 旁路表引擎（32 声部读表）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 PLAY 模式的 32 声部引擎从上传的波表取振荡器样本，使录好的 loop 回放时保留手绘音色与 morph position，而不是退回内部锯齿。

**Architecture:** 扫描管线（读 bank → 计算 → 写回）保持不变，只在每样本扫描结束后的 64 拍里跑一个「表引擎」：从相位缓冲取两个相位、读两帧表、按当前 position/frac 交叉淡化、写进样本缓冲；下一次扫描计算时把 `oscillator_value(...)` 换成样本缓冲里的值，后续的 stage/velocity/mix 衰减原样保留。

**Tech Stack:** SystemVerilog（Gowin GW5A / GW5A-LV25MG121NES，80 MHz），ModelSim `vlog/vsim`，Python 构建与板级脚本（`scripts/synth.py`、`scripts/sim.py`、`scripts/board_*.ps1`）。

**Spec:** `docs/superpowers/specs/2026-10-31-wavetable-3-frame-morph-design.md` §9

## Global Constraints

- 系统时钟 80 MHz，音频 48 kHz（`sample_ce` 每 1667 拍一次）；每样本时隙预算 **1667**，本阶段新增 **≈100 拍（6.0%）**。
- 波表几何固定：3 表 × 2 bank × 1024 × int16；`idx = phase[31:22]`；表幅度 0.9 FS。
- 表引擎固定缩放常数 **`WT_VOICE_SHIFT`，默认 4**，放在 `WT_SELECT(0x60)` 的空闲位 `[7:4]`；不新增 CSR 地址。
- 模式互斥：IDLE 旧读口给宿主；WT_PLAY / LIVE 走单声部路径；PLAY 走表引擎。PLAY 中宿主读 `WT_DATA(0x18)` 必须返回 0。
- 不改原有扫描管线的握手、事件接收时机与 voice stealing 行为。
- 每完成一个任务：`python scripts/gate.py --compile` 必须 0 error / 0 warning；`python scripts/sim.py` 不得新增失败；提交信息写清「改了什么 + 为什么」。
- 构建产物要记 `bitstream_sha256`；板测前先读 `0xB0` 确认是当前位流（隔夜掉电会丢 SRAM 配置）。
- 非目标：每声部独立 position、每声部相位插值、真实 ADSR。

## Review Focus

- **表未上传就进 PLAY**：应输出静音，不能输出随机噪声或满幅方波。
- **PLAY 与 LIVE 之间切换**：同帧同 position 下音量不应跳变（±3 dB 内），也不应出现咔嗒。
- **32 声部同时发声**：32 × 0.9 FS 直接求和会削顶，必须有 `WT_VOICE_SHIFT` 缩放，且缩放后峰值不得饱和。
- **宿主在 PLAY 中读 `WT_DATA`**：必须返回 0（读口所有权），返回旧值会让人误判上传状态。
- **刚进 PLAY 的第一个样本**：缓冲初值 0，允许静音 20.8 µs，但不能出现爆音或半个周期的错误样本。

---

### Task 1: 相位缓冲与样本缓冲

**Files:**
- Create: `rtl/v2_wt_voice_bufs.sv`
- Test: `tb/tb_wt_voice_bufs.sv`
- Modify: `filelist.f`（把新文件放在 `rtl/v2_wt_mix.sv` 之后）

**Interfaces:**
- Produces:
  ```systemverilog
  module v2_wt_voice_bufs #(parameter integer VOICES = 32) (
    input  logic clk, input logic rst_n,
    // 扫描侧：每拍一个声部，读样本、写相位
    input  logic        scan_en, input logic [4:0] scan_slot,
    input  logic        scan_phase_we,
    input  logic [31:0] scan_phase_a, input logic [31:0] scan_phase_b,
    output logic signed [15:0] scan_sample_a, output logic signed [15:0] scan_sample_b,
    // 表引擎侧：每拍一个声部，读相位、写样本
    input  logic        eng_en, input logic [4:0] eng_slot,
    output logic [31:0] eng_phase_a, output logic [31:0] eng_phase_b,
    input  logic        eng_sample_we,
    input  logic signed [15:0] eng_sample_a, input logic signed [15:0] eng_sample_b
  );
  ```

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_wt_voice_bufs.sv
// 复位后两侧读都为 0；写 slot 7 的相位与样本，下一拍读回一致；
// 写 slot 7 不影响 slot 8（寻址不串）。
```
断言用 `!==`，失败走 `$fatal(1, ...)`，与 `tb/tb_wt_mix.sv` 同风格。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_wt_voice_bufs`
Expected: FAIL（`v2_wt_voice_bufs` 未定义）

- [ ] **Step 3: 实现 `v2_wt_voice_bufs`**

两个 `VOICES × 32` 的寄存器阵列（相位）与 `VOICES × 32`（样本，`{a,b}` 各 16 bit）。读是组合的（`assign` 索引），写在 `clk` 上升沿；复位清零全部内容。不用 BSRAM（32×64 bit 太小，Gowin 会拆成 LUT，反而省事且时序可控）。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_wt_voice_bufs`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_wt_voice_bufs.sv tb/tb_wt_voice_bufs.sv filelist.f
git commit -m "feat: phase and sample buffers for the 32-voice wavetable path"
```

---

### Task 2: 表引擎（每声部 2 拍）

**Files:**
- Create: `rtl/v2_wt_voice_engine.sv`
- Test: `tb/tb_wt_voice_engine.sv`
- Modify: `filelist.f`

**Interfaces:**
- Consumes: Task 1 的 `v2_wt_voice_bufs`；`v2_wt_mix`（`a, b, frac → out`）。
- Produces:
  ```systemverilog
  module v2_wt_voice_engine #(
    parameter integer VOICES = 32,
    parameter logic [3:0] SHIFT_DEFAULT = 4'd4
  ) (
    input  logic clk, input logic rst_n, input logic sample_ce,
    input  logic [1:0] frame_a, input logic [1:0] frame_b,
    input  logic [7:0] frac, input logic [3:0] shift,
    input  logic [31:0] phase_a_in, input logic [31:0] phase_b_in,   // 从 bufs 组合读出
    output logic [4:0]  slot,
    output logic        rd_en0, output logic [1:0] rd_table0, output logic [9:0] rd_index0,
    output logic        rd_en1, output logic [1:0] rd_table1, output logic [9:0] rd_index1,
    input  logic signed [15:0] rd_sample0, input logic signed [15:0] rd_sample1,
    input  logic        rd_valid0, input logic        rd_valid1,
    output logic        sample_we,
    output logic signed [15:0] sample_a, output logic signed [15:0] sample_b
  );
  ```

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_wt_voice_engine.sv
// 固定 frame_a=0/frame_b=1、frac=0x80、shift=0、相位已知；
// 用行为级 1024 点表当读回应答（tb 内 mem 数组，1 拍延迟）；
// 断言 slot 依次 0..31、每声部恰好 2 拍；
// frac=0 时 sample_a 必须等于 A[idx] 的混音结果，sample_b 同相位 B；
// 与 tb 内独立算出的期望值逐声部比较。
```
同时断言：`sample_we` 在 32 声部走完后只再拉高一拍（收尾），不会长期为 1。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_wt_voice_engine`
Expected: FAIL（模块未定义）

- [ ] **Step 3: 实现 `v2_wt_voice_engine`**

状态机：`E_IDLE → E_REQ0 → E_WAIT0 → E_REQ1 → E_WAIT1 → E_NEXT`。`rd_index = phase[31:22]`；第 1 拍读 `(frame_a, idx_a)` 与 `(frame_b, idx_a)`，第 2 拍读 `(frame_a, idx_b)` 与 `(frame_b, idx_b)`；两次都过 `v2_wt_mix`（`frac`），结果 `>> shift` 写入样本缓冲的 a/b。`rd_valid` 缺失时该声部写 0（表未上传 → 静音）。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_wt_voice_engine`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_wt_voice_engine.sv tb/tb_wt_voice_engine.sv filelist.f
git commit -m "feat: two-cycle-per-voice wavetable engine that fills the sample buffer"
```

---

### Task 3: 声部引擎改用样本缓冲（参数化，默认关闭）

**Files:**
- Modify: `rtl/v2_voice_engine_banked.sv`（端口 + `calc_osc_sum` 赋值处）
- Test: `tb/tb_voice_wt_source.sv`（新建）
- Modify: `tb/tb_voice_engine_banked.sv`（保持原用例不改，作为回归）

**Interfaces:**
- Consumes: Task 1 的缓冲输出。
- Produces: `v2_voice_engine_banked` 新端口
  ```systemverilog
  parameter integer USE_WT_SOURCE = 0,
  // 仅 USE_WT_SOURCE=1 时使用：
  input  logic signed [15:0] wt_sample_a, input logic signed [15:0] wt_sample_b
  ```

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_voice_wt_source.sv
// USE_WT_SOURCE=1，喂常量 wt_sample_a=1000/wt_sample_b=0，发一个 NOTE_ON(velocity=127)；
// 断言输出 == attenuate(1000, stage, gain, mix_a)（用 tb 内同公式独立算），
// 并且再发一个 NOTE_ON 改变音高后输出不变（说明不再看内部相位）。
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_voice_wt_source`
Expected: FAIL（端口不存在）

- [ ] **Step 3: 实现**

`calc_osc_sum <= attenuate(USE_WT_SOURCE ? {1'b0,wt_sample_a} : osc_a, ...)` 形式：把现有 `oscillator_value(...)` 的结果先存进局部信号，再用参数在它与 `wt_sample_*` 之间二选一交给 `attenuate`。`attenuate` 内部逻辑不动。

- [ ] **Step 4: 跑测试确认通过（含回归）**

Run: `python scripts/sim_unit.py --tb tb_voice_wt_source`
Run: `python scripts/sim.py`
Expected: 两个都 PASS，`sim.py` 不新增失败。

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_voice_engine_banked.sv tb/tb_voice_wt_source.sv
git commit -m "feat: let the voice engine take oscillator samples from the wavetable buffer"
```

---

### Task 4: 顶层接线与读口所有权

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`
- Modify: `rtl/v2_contract_pkg.sv`（`WT_SELECT` 写掩码与 `WT_VOICE_SHIFT` 字段）
- Test: `tb/tb_top_wt_voice.sv`（新建）

**Interfaces:**
- Consumes: Task 1/2/3 的模块。
- Produces:
  - `wt_shift = wt_select_reg[7:4]`（复位值 4），接入 `v2_wt_voice_engine.shift`；
  - 读口 mux：`wt_rd_table0/index0` 与 `1` 在 `mode_play` 时改由表引擎驱动，其余模式保持现有单声部接线；
  - `WT_DATA(0x18)` 读回在 `mode_play` 时固定 0。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_top_wt_voice.sv
// 用 V2_SIM 顶层例化，上传一张常量表（全部 0x3000）到表 0；
// 进 PLAY，发 NOTE_ON(69)；
// 断言：mixed_sample 非零且等于 attenuate(0x3000>>shift, ...) 的可接受范围（±1 LSB）；
// 断言：PLAY 中读 WT_DATA 返回 0；回到 IDLE 后读回仍正常。
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_top_wt_voice`
Expected: FAIL（PLAY 输出仍是锯齿）

- [ ] **Step 3: 实现接线**

实例化 `u_wt_voice_bufs` 与 `u_wt_voice_engine`；把扫描侧的 `bank_rd_addr`（已有 `scan_slot`）接到 bufs 的 `scan_slot`，把相位写使能与 `calc_osc_sum` 同拍；引擎的 `slot` 接到 bufs 的 `eng_slot`；读口用 `mode_play` 选择。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_top_wt_voice`
Run: `python scripts/sim.py`
Expected: PASS，且 `sim.py` 不新增失败。

- [ ] **Step 5: 提交**

```bash
git add rtl/mgc3130_v2_top.sv rtl/v2_contract_pkg.sv tb/tb_top_wt_voice.sv
git commit -m "feat: PLAY reads the wavetable through the bypass engine; WT_DATA reads 0 in PLAY"
```

---

### Task 5: 多声部回归与满负荷

**Files:**
- Test: `tb/tb_wt_voice_poly.sv`（新建）
- Modify: `scripts/sim_baseline.json`（仅在确认新用例稳定后）

- [ ] **Step 1: 写测试**

```systemverilog
// tb/tb_wt_voice_poly.sv
// 32 个 NOTE_ON（不同音高）→ 断言 active_voice_count==32、无 voice_overflow；
// 32 声部同时发声时 |mixed_sample| <= 32767（不削顶）；
// 逐个关闭声部后重新计数正确。
```

- [ ] **Step 2: 跑测试**

Run: `python scripts/sim_unit.py --tb tb_wt_voice_poly`
Expected: PASS

- [ ] **Step 3: 提交**

```bash
git add tb/tb_wt_voice_poly.sv
git commit -m "test: 32 simultaneous voices through the wavetable path do not clip"
```

---

### Task 6: 板上验收（PLAY 与 LIVE 同一音色）

**Files:**
- Create: `scripts/board_wt_voice_play.ps1`
- Modify: `docs/system-design-2026-10-31.md`（阶段 1.5 行）、`docs/progress-2026-11-01.md`
- Modify: `gao/voice_spectrum.rao`（新建；参考 `gao/tick_period.rao` 的结构）

**Interfaces:**
- Consumes: 前五个任务的产物位流。

- [ ] **Step 1: 写脚本**

`board_wt_voice_play.ps1`：上传一帧 → 写 `WT_SELECT`（含 `shift`）→ 进 PLAY → 发一串 NOTE_ON → 读 `STATUS` 与 `active_voice_count`；只用带序号校验的发送函数；结束时回 IDLE。

- [ ] **Step 2: 构建并烧录**

Run: `python scripts/synth.py --run-id wt_voice_play`
Run: `powershell -File scripts\board_wt_voice_play.ps1 -Port COM4`
Expected: `APPLY err=0`、`STATUS` 进入 PLAY、`active_voice_count > 0`；记录 `bitstream_sha256`。

- [ ] **Step 3: GAO 对比频谱**

同一帧、同一 position 下分别录 LIVE 与 PLAY 各一段（48 kHz 采样时钟、4096 行）：
Run: `python scripts/gao_capture.py --rao gao/voice_spectrum.rao --out artifacts/gao/voice_play.csv`
Expected: 两条频谱的 1–16 次谐波相对幅度差 **≤ 3 dB**，基频一致。

- [ ] **Step 4: 记录结论并提交**

把位流 sha256、`0xD4`/`0xE8` 读数、频谱差写进 `docs/progress-2026-11-01.md`。

```bash
git add scripts/board_wt_voice_play.ps1 gao/voice_spectrum.rao docs/progress-2026-11-01.md docs/system-design-2026-10-31.md
git commit -m "feat: PLAY bypass wavetable engine accepted on board (spectrum within 3 dB of LIVE)"
```

---

## Self-Review

**1. Spec coverage**

| Spec §9 要求 | 任务 |
| --- | --- |
| 相位缓冲 32×64 / 样本缓冲 32×32 | Task 1 |
| 表引擎每声部 2 拍、两帧读、交叉淡化复用单声部模块 | Task 2 |
| 声部引擎只改 `calc_osc_sum` 来源 | Task 3 |
| 读口所有权（PLAY 用表引擎，PLAY 中 `WT_DATA` 返回 0） | Task 4 |
| `WT_VOICE_SHIFT` 默认 4、放在 `WT_SELECT[7:4]` | Task 4 |
| 仿真：单声部参考一致 / 1/8/32 音通过 | Task 2、4、5 |
| 板上：LIVE 与 PLAY 频谱 ±3 dB、切换无跳变 | Task 6 |
| 时序预算 ≤100 拍 | Task 2（状态机 2 拍 × 32 + 收尾），Task 4 后跑 `gate.py` 复核 |

缺口：spec 的「1/8/32 音 test mode」在仓库里是 `tb/tb_voice_engine_banked.sv` 的既有用例；Task 3 明确保留它作回归，不再单列任务。

**2. Step scan**：每个 Step 只有一件事（写测试 / 跑红 / 实现 / 跑绿 / 提交），代码块只出现在测试与签名处。

**3. Type consistency**：`scan_slot/eng_slot`、`rd_sample0/1`、`rd_valid0/1`、`wt_sample_a/b`、`shift[3:0]` 在三个任务间名称与位宽一致。

**4. Review Focus 对应**：表未上传 → Task 2（`rd_valid` 缺失写 0）；削顶 → Task 5；`WT_DATA` 返回 0 → Task 4；切换跳变与首样本 → Task 6（板测）。LIVE/PLAY 音量跳变没有自动化测试，放 Task 6 的人工判据。

**5. Proportion**：计划约为 spec §9 的 2 倍长度，主要由测试与接口定义构成，没有复制实现体。
