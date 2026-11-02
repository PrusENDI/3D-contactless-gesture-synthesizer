# P2b Implementation Plan（语音参数：包络四段 / 力度深度 / 失谐宽度 / 滑音速率）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 32 声部引擎里四个编译期常数（包络四段）和三个行为常数（力度影响幅度、失谐宽度、滑音速率）变成上位机可写的寄存器，默认值与今天逐位相同。

**Architecture:** 控制面在 `v2_contract_pkg` 里加三个地址（`0x94/0x98/0x9C`）与 clamp；顶层把它们解包成**一条 `voice_cfg` 打包总线**送进 `v2_voice_engine_banked`，引擎内部把这七个量替换原来的 `localparam`；力度与失谐都**只用移位**（DSP 已满，且移位让默认值天然逐位保持）。

**Tech Stack:** SystemVerilog（Gowin GW5A / 80 MHz / 48 kHz）、ModelSim `scripts/sim_unit.py`、`scripts/gate.py`、`scripts/sim.py`、`scripts/synth.py`（已带构建门）、PowerShell 板级脚本。

**Spec:** `docs/superpowers/specs/2026-11-01-filter-lfo-design.md` §11.3（P2b 语义）、§11.6（clamp 表）、§11.1（地址表）。执行者两份都要读。

## Global Constraints

- 只做 P2b：`0x94 ENV_AD`、`0x98 ENV_SR`、`0x9C VOICE_MIX`。**不动**已验收的 P2a 链路（滤波/LFO/FX/音量）与 P1 的 VCA/失谐逻辑结构。
- **默认值必须逐位保持现状**：`attack 4096 / decay 256 / sustain 49152 / release 1024`、
  `velocity_shift 0`、`detune_shift 0`、`glide_rate 512`。任何既有 tb 断言不得因默认值改动。
- **不许新增乘法**：DSP 已 28/28 满。力度影响与失谐宽度都只能移位（见 §11.3 的修正）。
- 包络四段与 glide 的下界是 **1**（`release_step=0` 会让包络永不归零 → `active[]` 不清 → `event_ready` 卡死，
  这是 spec §11.6 记录的**死锁**）；sustain 可为 0。
- 每个任务结束：`python scripts/sim_unit.py --tb <tb>` 绿、`python scripts/gate.py --compile` 0/0、
  `python scripts/sim.py` 不超基线（13 pass / 4 known-fail）、源文件 LF/无 BOM、`git add <具体文件>` 提交。
- 构建门（`scripts/synth.py` 内置）：`CLS ≤ 11300`、`worst ≥ −3.5`。CLS 现在 10894/11520，
  P2b 预算 ~180，**如果撞 11300**：先做 Task 3（还时序/腾布局），再决定是否拆任务。

## Review Focus

1. **默认逐位不变**：所有既有声部 tb 在 `V2_VOICE_CFG_DEFAULT` 下必须给出与 HEAD 完全相同的数值（Task 1）。
2. **`release_step` 下界**：写 0 必须被 clamp 到 1，否则整条事件流死锁（Task 0 的契约测试）。
3. **失谐仍随力度变化**：`detune_shift` 是**加**在力度选定宽度上的，默认 0 时行为与 P1 一字不差（Task 1）。
4. **包络时间真的可调**：写到顶（65535）与写到 1 时，起音到顶的采样数必须差两个数量级（Task 1）。
5. **引擎端口只加一条总线**：7 个既有 tb 各只加一行 `.voice_cfg(...)`，不许改其它连接（Task 1）。

---

### Task 0: 契约——三个地址、掩码、clamp、默认打包值

**Files:**
- Modify: `rtl/v2_contract_pkg.sv`
- Modify: `tb/tb_contract_clamp.sv`

**Interfaces:**
- Produces:
  - `V2_CSR_ENV_AD=8'h94`、`V2_CSR_ENV_SR=8'h98`、`V2_CSR_VOICE_MIX=8'h9C`
  - 写掩码：`0xFFFFFFFF`、`0xFFFFFFFF`、`0xFFFF000F`
  - `localparam logic [95:0] V2_VOICE_CFG_DEFAULT`（布局见 Task 1）
  - `v2_csr_clamp()` 增加三条分支

- [ ] **Step 1: 扩展失败测试 `tb/tb_contract_clamp.sv`**

追加断言（每条一行 `expect`）：`0x94` 的 attack/decay 写 0 → 夹到 1；`0x98` 的 release 写 0 → 夹到 1；
sustain 写 0 → 保持 0；`0x9C` 的 `[1:0]`/`[3:2]` 写 3 → 保持 3；`glide_rate` 写 0 → 夹到 1；
`v2_csr_access()` 对这三个地址返回 RW。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_contract_clamp`
Expected: FAIL —— `V2_CSR_ENV_AD` 未定义

- [ ] **Step 3: 实现**

按 spec §11.1 加三个地址与掩码；`v2_csr_clamp()` 里按字段夹（`attack/decay/release` 下界 1，
`velocity_shift`/`detune_shift` 上界 3，`glide_rate` 下界 1）；定义
`V2_VOICE_CFG_DEFAULT = {glide_rate=512, detune_shift=0, velocity_shift=0, release=1024, sustain=49152, decay=256, attack=4096}`。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_contract_clamp` → `PASS`；`python scripts/gate.py --compile` → `GATE: PASS`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_contract_pkg.sv tb/tb_contract_clamp.sv
git commit -m "feat: three P2b CSRs, their clamp floors and the packed default"
```

---

### Task 1: 引擎——`voice_cfg` 总线替换七个常数

**Files:**
- Modify: `rtl/v2_voice_engine_banked.sv`
- Modify: `tb/tb_voice_engine_banked.sv`、`tb_voice_vca.sv`、`tb_voice_wt_source.sv`、`tb_voice_detune.sv`、`tb_wt_voice_poly.sv`、`tb_top_wt_voice.sv`、`tb_top_p2_csr.sv`（各加一行端口连接）
- Create: `tb/tb_voice_cfg.sv`

**Interfaces:**
- Consumes: `V2_VOICE_CFG_DEFAULT`（Task 0）
- Produces（Task 2 依赖）:
  ```systemverilog
  input logic [95:0] voice_cfg   // {glide_rate[15:0], detune_shift[1:0], velocity_shift[1:0],
                                 //  release[15:0], sustain[15:0], decay[15:0], attack[15:0]}
  ```

- [ ] **Step 1: 写失败测试 `tb/tb_voice_cfg.sv`**

用例（`USE_WT_SOURCE=1`，常量样本，`USE_GOWIN_RAM=1`）：
1. **默认不变**：`voice_cfg = V2_VOICE_CFG_DEFAULT` 时，`NOTE_ON` 后起音到顶的采样数 = 16、稳态电平 = 1528（与 `tb_voice_vca` 同值）；
2. **起音可调**：`attack = 65535` 时起音到顶的采样数 ≥ 32000；`attack = 1` 时 ≤ 2；
3. **释放可调**：`release = 1` 时 `NOTE_OFF` 后 2 个采样内 `active_voice_count` 归零；`release = 65535` 时 200 个采样后仍 > 0；
4. **力度深度**：`velocity_shift = 0` 时 vel 255 与 vel 128 的稳态电平不同（1528 vs 383）；`velocity_shift = 3` 时两者差距缩到 1/8 以内（允许 ±2 LSB），**且都不为 0**；
5. **失谐宽度**：`detune_shift = 0` 时 vel 255 的 `step_a−step_b` 等于 P1 的值（153791，从 bank 字读）；`detune_shift = 2` 时等于其 1/4（±1）；
6. **滑音速率**：`glide_rate = 512`（默认）与 `4095` 下，同一 `REVOICE` 音高偏移到达目标所需采样数之比约 8:1。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_voice_cfg` → FAIL（无 `voice_cfg` 端口）

- [ ] **Step 3: 实现**

1. 加端口 `input logic [95:0] voice_cfg`；
2. 解包成七个内部信号，**替换** `ATTACK_STEP/DECAY_STEP/SUSTAIN_LEVEL/RELEASE_STEP` 四个 localparam 的用法
   （保留 localparam 作为复位/文档值即可删除）；
3. `bounded_step()` 的 `512` 换成 `glide_rate`；
4. `detuned_step(base, gain)` 的移位改成 `11 − gain[7:6] + detune_shift`（夹到 ≤15）；
5. 激活路径（`steal_*_pending` 那条）里把 store 的 gain 改成
   `255 − ((255 − velocity) >> velocity_shift)`（两处：`pending_activate` 写 bank、以及
   `attenuate_sample()` 读到的 `gain` 字段——后者自动跟随，不需要改函数）；
6. 七个既有 tb 各加一行 `.voice_cfg(V2_VOICE_CFG_DEFAULT)`（用 `` `include `` 或直接 import 契约包）。

- [ ] **Step 4: 跑测试确认通过 + 既有 tb 不回归**

Run: `python scripts/sim_unit.py --tb tb_voice_cfg` → PASS
Run: 逐个 `--tb tb_voice_engine_banked / tb_voice_vca / tb_voice_wt_source / tb_voice_detune / tb_wt_voice_poly / tb_top_wt_voice / tb_top_p2_csr` → 全 PASS
Run: `python scripts/sim.py` → `SIM: PASS`（13/4）

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_voice_engine_banked.sv tb/tb_voice_cfg.sv tb/tb_voice_engine_banked.sv tb/tb_voice_vca.sv tb/tb_voice_wt_source.sv tb/tb_voice_detune.sv tb/tb_wt_voice_poly.sv tb/tb_top_wt_voice.sv tb/tb_top_p2_csr.sv
git commit -m "feat: envelope times, velocity depth, detune width and glide rate become registers"
```

---

### Task 2: 顶层——三个寄存器与解包

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`
- Modify: `tb/tb_top_p2_csr.sv`

**Interfaces:**
- Consumes: Task 0 的地址/掩码/clamp、Task 1 的 `voice_cfg` 端口

- [ ] **Step 1: 扩展失败测试 `tb/tb_top_p2_csr.sv`**

追加：三个地址的复位值（`0x94=0x0100_1000`（decay=256/attack=4096）、`0x98=0xC000_4000`（release=1024/sustain=49152）、
`0x9C=0x0200_0000`（glide=512））、往返、以及 **clamp**：写 `0x94` 的低半字 0 → 读回 `0x0100_0001`；
写 `0x9C = 0x0000_003F` → 只保留 `[3:0]` 的两位字段 → 读回 `0x0000_000F`。
**并且 `0x9C` 现在必须 ACK（不再是 BAD_ADDRESS）**。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_top_p2_csr` → FAIL

- [ ] **Step 3: 实现**

加三个 32 位寄存器（复位值如上）、三条 `v2_csr_clamp` 写入、三条读回、以及 `voice_cfg` 的组合拼接送进引擎。

- [ ] **Step 4: 跑测试确认通过 + 回归**

Run: `--tb tb_top_p2_csr` PASS；`gate.py --compile` PASS；`sim.py` PASS；`test_potts_plane.py` PASS

- [ ] **Step 5: 提交**

```bash
git add rtl/mgc3130_v2_top.sv tb/tb_top_p2_csr.sv
git commit -m "feat: expose the P2b parameters and drive voice_cfg"
```

---

### Task 3: 还时序余量（`v2_fx_lite` 增益寄存）

**Files:**
- Modify: `rtl/v2_fx_lite.sv`（约 5 行）

- [ ] **Step 1: 加一拍寄存**

在增益乘法后、低通之前加一级 `sample_ce` 寄存（`gain_q`），使
`0x84` 的增益到 `delay_mem` 写数据的路径被切断。行为只多 1 个采样延迟，`level=0` 时不可闻。

- [ ] **Step 2: 验证**

Run: `python scripts/sim_unit.py --tb tb_fx_delay` → PASS（回声周期不变；若因多一拍变成 `delay+2`，更新该 tb 的期望并说明）
Run: `python scripts/synth.py --run-id p2b_fxreg` → 期望 `worst > -4.007`（目标 −3.9 以内）、CLS 不涨

- [ ] **Step 3: 提交**

```bash
git add rtl/v2_fx_lite.sv tb/tb_fx_delay.sv
git commit -m "perf: register the fx gain so the P2b build has timing headroom"
```

---

### Task 4: 构建门 + 板上验收 + 文档

- [ ] **Step 1: 构建**

Run: `python scripts/synth.py --run-id p2b_voice_params`（新 run id）
Expected: `SYNTH: PASS`、`gate: OK`（CLS ≤11300、worst ≥−3.5）。若 CLS 超 11300 → 先报告，不要自己砍功能。

- [ ] **Step 2: 烧录 + 身份**

`board_program.ps1 -Operation 4` → `PROGRAM PASS`，随后 `0xB0 = 0x5A5A0003`。

- [ ] **Step 3: 板上验收（要手/耳朵）**

1. 三个地址写读回自证（像 `board_filter_demo.ps1` 那样每步读回）；
2. `0x94` 把 attack 改大（如 `0x0100_FFFF` 只改 attack 低半字）→ 用 LOOP 播放，听**音头变软**；
3. `0x9C[1:0]=3` → 手从远到近摆，听**力度差别变小**；
4. `0x9C[3:2]=3` → 听**失谐变窄**（厚度减少）。
判据只写"听到什么"，没量到就写"未验证"。

- [ ] **Step 4: 文档 + 提交**

`docs/progress-2026-11-01.md` 记四个时序数、sha256、听感；`docs/HANDOFF.md` 改成 P2b 完成；
`docs/host-tools-and-gui-controls.md` 补三行寄存器与"力度深度是 2 位移位、失谐宽度是叠加移位"的语义。

```bash
git add docs/progress-2026-11-01.md docs/HANDOFF.md docs/host-tools-and-gui-controls.md
git commit -m "docs: P2b landed - resources, timing, what was heard"
```

---

## Self-Review

**1. Spec coverage**：§11.3 的四组参 → Task 1（引擎）+ Task 2（CSR）；§11.6 的 clamp 下界 → Task 0；
§11.1 的地址表 → Task 0；"不许新增乘法" → Task 1 第 4/5 条（移位）。

**2. Step scan**：每步一条命令 + 一个可判定的期望，或一处签名/字段定义。没有"处理边界情况"这类空步。

**3. Type consistency**：`voice_cfg[95:0]` 的布局在 Task 0 定义、Task 1 解包、Task 2 拼接，三处一致；
`V2_VOICE_CFG_DEFAULT` 由 Task 0 提供，Task 1 的七个 tb 与 `tb_voice_cfg` 共用。

**4. Review Focus 对应**：1→Task 1 第 1 条；2→Task 0 Step 1；3→Task 1 第 5 条；4→Task 1 第 2 条；5→Task 1 第 6 条。

**5. Proportion**：约 190 行计划，实现约 150 行 RTL + 1 个新 tb + 8 处一行改动 + 3 个 csr 扩展。

**已知缺口**：`mix 默认值` 这一轮不做（`0x9C` 位段已满，且只影响 LIVE 单声部）；
P2c（预设接线）仍未做。
