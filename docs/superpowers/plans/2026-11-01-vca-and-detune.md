# VCA + 力度 + 失谐 实施计划（2026-11-01）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让包络真正乘到音频上（VCA），让力度成为包络的幅度因子，并给每声部两个振荡器加一点由力度控制的失谐。

**Architecture:** 全部改动集中在 `v2_voice_engine_banked`：在"计算"级把 `rd_envelope × rd_gain` 乘成一个 16 位增益（1 个 DSP，寄存），在"累加"级用它乘本声部的振荡器和（再 1 个 DSP），于是包络与力度一起成为幅度；失谐在**激活**那一刻写进 `step_b`/`target_b`，并把 `phase_b` 预置成半周期，宽度由力度的两位做移位选择（纯移位，不用 DSP）。

**Tech Stack:** SystemVerilog（Gowin GW5A / 80 MHz）、ModelSim `scripts/sim_unit.py`、`scripts/sim.py`、`scripts/gate.py`、`scripts/synth.py`、PowerShell 板级脚本。

**Spec:** `docs/superpowers/plans/2026-11-01-expression-roadmap.md`（P1：力度 + VCA；并入了 P1 的"D. 力度 → 失谐宽度"）

## Global Constraints

- 只做 P1：**VCA + 力度 + 失谐**；颤音、滑音、滤波包络、每振荡器包络、64 路申报、LIVE 合并、效果器、可视化都不做。
- 不动 CSR、不动 `v2_contract_pkg.sv`：力度来自手势（Z→`velocity_control`→事件 `[63:56]`），失谐由力度派生。
- 四段包络常数保持不变：`ATTACK_STEP 4096`、`DECAY_STEP 256`、`SUSTAIN_LEVEL 49152`、`RELEASE_STEP 1024`（16 位，每采样一步）。
- 锯齿路径（`USE_WT_SOURCE=0`）与波表路径（=1）必须走同一个 VCA。
- 每个任务结束：`python scripts/sim_unit.py --tb <tb>` 绿、`python scripts/gate.py --compile` 0/0、`python scripts/sim.py` 不新增失败；源文件 LF、无 BOM；提交信息写"改了什么 + 为什么"，`git add` 列具体文件。
- 已知会变的既有断言：`tb_voice_wt_source` / `tb_wt_voice_poly` / `tb_top_wt_voice` 里所有"绝对电平"期望都会因为 VCA 变小，必须按新物理改（见 Task 1）。

## Review Focus

1. **激活后的第一个采样**：包络从 0 开始，VCA 后应为静音并逐采样上升，不能出现爆音或直接满幅。
2. **32 声部满幅**：VCA 之后仍要走饱和器，`|mixed_sample| ≤ 32767`，不能回绕。
3. **失谐的起点**：两个振荡器若相位相同，会先同相 1 个周期再散开；`phase_b` 必须在激活时预置半周期。
4. **力度 0**：`gain=0` 时该声部必须**完全静音**（amp=0），而不是"最小音量"。
5. **锯齿路径**：`USE_WT_SOURCE=0` 的旧用例仍要听到同样的 VCA 行为（`tb_voice_engine_banked` 不检查电平，但 `sim.py` 的 13 条断言必须不回归）。

---

### Task 1: VCA —— 包络与力度乘到幅度上

**Files:**
- Modify: `rtl/v2_voice_engine_banked.sv`（`calc_*` 声明、calc 级、累加级）
- Test: `tb/tb_voice_vca.sv`（新建）
- Modify: `tb/tb_voice_wt_source.sv`、`tb/tb_wt_voice_poly.sv`、`tb/tb_top_wt_voice.sv`（绝对电平期望）

**Interfaces:**
- Produces: 寄存器 `logic signed [15:0] calc_env_gain;`（在 rd→calc 边界寄存 `(rd_envelope × rd_gain) >>> 8`），累加级使用 `calc_osc_sum × calc_env_gain >>> 16`。
- 行为：`mixed_sample = saturate(Σ_voice (osc_sum × (env × gain >> 8) >> 16))`；`gain` 来自事件 `[63:56]`（0..255），`env` 稳态 = 49152。

- [x] **Step 1: 写失败测试 `tb/tb_voice_vca.sv`**

用例（`USE_WT_SOURCE=1`、常量样本 `wt_sample_a = wt_sample_b = 2047`、`USE_GOWIN_RAM=1`）：

```systemverilog
// 1) velocity=255 的 NOTE_ON
send_note_on(note=69, vel=255);
// 激活后第一个出样：包络为 0 → 必须恰好 0
check(first_sample == 0, "the first sample after note on must be silent");
// 2) 等到稳态（>120 采样）：env=49152、amp=(49152*255)>>8=48960
//    每声部 = 2 * (2047 >> (2+0+0))  [sustain 阶段、vel255/mix128 → 3 bit 衰减取 2? 按现行 att 计算]
//    期望 = (osc_sum * 48960) >> 16
// 3) velocity=0 的 NOTE_ON：任何采样都必须为 0（amp=0）
// 4) velocity=128 与 velocity=255 在稳态的峰值比 = 128:255（±1 LSB）
```

断言用 `!==` + `$fatal(1, ...)`，失败信息要带实测值与期望值。

- [x] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_voice_vca`
Expected: FAIL（`calc_env_gain` 未定义 / 首个采样非 0 / 力度不影响峰值）

- [x] **Step 3: 实现**

`rtl/v2_voice_engine_banked.sv`：

1. 在 `calc_*` 声明区加 `logic [15:0] calc_env_gain;`（复位 0）；
2. rd→calc 边界（与 `calc_envelope`/`calc_gain` 同一段）：`calc_env_gain <= (rd_envelope * rd_gain) >>> 8;`
   —— 1 个 16×8 乘法，结果 ≤ 65280；
3. 累加级（`if (calc_valid && calc_active)` 与 `calc_valid && calc_last` 两处用到 `calc_osc_sum` 的地方）：
   引入 `wire signed [47:0] calc_osc_vca = ($signed(calc_osc_sum[31:0]) * $signed({1'b0, calc_env_gain})) >>> 16;`
   —— 32×16 乘法，`calc_osc_sum` 实际范围 ≤ ±65536，取 `[31:0]` 安全；
   把 `mix_acc <= mix_acc + calc_osc_sum;` 与 `mixed_sample <= ... saturate_sample(mix_acc + calc_osc_sum)` 两处的
   `calc_osc_sum` 换成 `calc_osc_vca`。

- [x] **Step 4: 更新三个既有 tb 的绝对电平期望（同一物理，不是放宽）**

| tb | 旧期望 | 新期望 |
| --- | --- | --- |
| `tb_voice_wt_source` | 首样 = `att(1000,…)` = 31 | 先等到稳态（≥120 采样）再比：`(att(1000,…) * ((49152*127)>>8)) >> 16` |
| `tb_wt_voice_poly` | 单声部峰值 16382；32 声部饱和 32767 | 单声部 `(16382 * ((49152*255)>>8)) >> 16`；32 声部仍应饱和到 32767 |
| `tb_top_wt_voice` | 第一个 PLAY 采样 = 48 | 等到稳态（≥120 采样）再比：`(48 * ((49152*127)>>8)) >> 16`，并保留"斜坡推进 34 单位"用例（斜坡斜率会同比缩小，期望值按同一因子重算） |

- [x] **Step 5: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_voice_vca`、`--tb tb_voice_wt_source`、`--tb tb_wt_voice_poly`、`--tb tb_top_wt_voice`
Expected: 四个都 PASS

- [x] **Step 6: 提交**

```bash
git add rtl/v2_voice_engine_banked.sv tb/tb_voice_vca.sv tb/tb_voice_wt_source.sv tb/tb_wt_voice_poly.sv tb/tb_top_wt_voice.sv
git commit -m "feat: multiply the envelope and velocity into the voice amplitude"
```

---

### Task 2: 失谐 —— 两个振荡器频率不同、相位错开、宽度跟力度

**Files:**
- Modify: `rtl/v2_voice_engine_banked.sv`（`direct_note_on` 的 bank 写、`pending_activate` 的 bank 写）
- Test: `tb/tb_voice_detune.sv`（新建）

**Interfaces:**
- Produces: 激活时 `step_a = rom_step`、`step_b = rom_step - (rom_step >>> shift)`，
  `target_a = step_a`、`target_b = step_b`，`phase_b = 32'h8000_0000`；
  `shift = 11 - gain[7:6]`（gain=0..255 → shift 11/10/9/8 → 0.05%/0.10%/0.20%/0.39%）。
- 复用现成信号：`rom_step`（note ROM 输出）、`event_data[63:56]`（gain）、`steal_base_step_pending`（抢声部路径的基准步进）。

- [x] **Step 1: 写失败测试 `tb/tb_voice_detune.sv`**

用例（常量样本 `wt_sample_a = wt_sample_b = 8191`，`USE_WT_SOURCE=1`）：

```systemverilog
// 1) NOTE_ON(69, vel=255)：读回 dut.state_bank 的 bank 字不方便，
//    改为行为断言：连续 4096 个采样里 mixed_sample 的包络内峰值必须出现
//    "拍频"——相邻 512 采样窗口的峰值差 ≥ 1 LSB（同相时差值恒 0）。
// 2) NOTE_ON(69, vel=0)：两个 step 应完全相同（shift 最大→失谐趋近 0？不，
//    gain=0 时 shift=11，失谐 = rom_step>>11 ≈ 0.05%，仍有拍频；因此改为断言
//    gain=0 时幅度为 0（VCA 已保证），本用例只断言 vel=255 与 vel=64
//    的拍频周期不同：窗口峰值序列的过零间隔比 ≈ 4:1（±1 窗口）。
// 3) 断言 phase_b 被预置：单声部、两振荡器同期时，用 held 相位检查
//    dut.state_bank 读回值不可行 → 改为断言"激活后第 1 个采样不等于
//    2×单振荡器样本"（同相会等于 2×，错开半周期后不等）。
```

（若行为断言太脆，允许把 `tb` 的检查改成"读取 `dut` 内部 `bank_wr_data` 的期望字段"——
tb 已在多处直接引用 `dut.*` 内部信号，这是本仓库既有做法。）

- [x] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_voice_detune`
Expected: FAIL（两个振荡器完全同相，无拍频/首样等于 2×）

- [x] **Step 3: 实现**

`rtl/v2_voice_engine_banked.sv` 的 `direct_note_on` 分支：

```verilog
logic [3:0] det_shift = 4'd11 - event_data[63:6];   // gain[7:6] ∈ 0..3
logic [31:0] det = rom_step >> det_shift;
bank_wr_data[31:0]    = 32'd0;          // phase_a
bank_wr_data[63:32]   = 32'h8000_0000;  // phase_b: 半周期错开
bank_wr_data[95:64]   = rom_step;       // step_a
bank_wr_data[127:96]  = rom_step - det; // step_b: 失谐
bank_wr_data[159:128] = rom_step;       // target_a
bank_wr_data[191:160] = rom_step - det; // target_b
```

`pending_activate`（抢声部）分支同样处理，基准用 `steal_base_step_pending`、力度用 `steal_velocity_pending`。

- [x] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_voice_detune`、`--tb tb_voice_vca`、`--tb tb_wt_voice_poly`
Expected: PASS

- [x] **Step 5: 提交**

```bash
git add rtl/v2_voice_engine_banked.sv tb/tb_voice_detune.sv
git commit -m "feat: detune the second oscillator of each voice, scaled by velocity"
```

---

### Task 3: 回归、构建、板上听感与文档

**Files:**
- Modify: `docs/progress-2026-11-01.md`
- Modify: `docs/superpowers/plans/2026-11-01-expression-roadmap.md`（把 P1 标为完成）

- [x] **Step 1: 回归**

Run: `python scripts/gate.py --compile`、`python scripts/sim.py`、`python scripts/test_potts_plane.py`
Expected: GATE PASS / SIM PASS（13 pass、4 条基线失败、RAM=0/1 一致）/ POTTS PLANE PASS

- [x] **Step 2: 构建**

Run: `python scripts/synth.py --run-id vca_detune`
Expected: `SYNTH: PASS`；记录 Logic/Register/CLS/DSP/BSRAM + setup 违约数/TNS/worst/Fmax 与 sha256

- [x] **Step 3: 烧录并确认身份**

Run: `powershell -File ".../board_program.ps1" -FsFile <impl/v2_board_top_vca_detune/impl/pnr/v2_board_top.fs> -Operation 4`
Expected: `PROGRAM PASS`；随后读 `0xB0 = 0x5A5A0003`

- [x] **Step 4: 板上听感（需要手）**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 1`
Expected: 录制/提交/播放/STOP 全过；听感：音头有起音、尾音有衰减、两振荡器有厚度。
**判据只写听到什么，不写"通过"。**

- [x] **Step 5: 记录并提交**

把资源/时序、`0xB0`、听感与未验证项写进 `docs/progress-2026-11-01.md`：

```bash
git add docs/progress-2026-11-01.md docs/superpowers/plans/2026-11-01-expression-roadmap.md
git commit -m "docs: VCA and detune landed; evidence and what was heard"
```

---

## Self-Review

**1. Spec coverage**：路线图 P1 的三项（VCA、力度、失谐 D）分别落在 Task 1（VCA + 力度）与 Task 2（失谐）；
P2/P3 不在本计划内，路线图已写明。

**2. Step scan**：每步只做一件事（写测试 / 跑红 / 实现 / 跑绿 / 提交）；
Task 2 的测试允许"读 `dut` 内部字段"，因为纯行为断言（拍频）对仿真窗口不敏感，仓里有先例。

**3. Type consistency**：`calc_env_gain`（16 bit）、`calc_osc_vca`（48 bit）在 Task 1 定义并使用；
Task 2 只改 `direct_note_on`/`pending_activate` 的 bank 字，不引入新类型。

**4. Review Focus 对应**：1→Task 1 Step 1 用例 1；2→`tb_wt_voice_poly`（Task 1 Step 4）；
3→Task 2 Step 3 的 `phase_b` 预置；4→Task 1 用例 3；5→Task 3 Step 1 的 `sim.py`。

**5. Proportion**：本计划约 150 行，实现约 40 行 RTL + 3 个 tb 的期望更新，不含实现体。

---

## 实施记录（2026-11-01，Task 1 `5337ac0` / Task 2 `97da308`）

### Task 1：VCA 与计划的三处偏差

1. **16 位乘法宽度陷阱（计划里没写，红测抓出来的）**。计划 Step 3 写的是
   `calc_env_gain <= (rd_envelope * rd_gain) >>> 8;`——Verilog 会把乘法按**目标宽度**定尺寸，
   24 位乘积被截成 16 位：`49152*255` 变成 `61440`，稳态应该 1528 却只有 1 LSB。
   改成 `envelope_gain()` 函数（内部 24 位变量）后正确。**这是必须先写红测的原因**：
   只看"有声部、有声音"不会发现音量小了 3000 倍。
2. **稳态电平比计划预估的乐观**：`att()` 的力度分档是 `>192 不加`、`128..191 +1`、
   `64..127 +2`，所以 vel=127 走的是 **+2** 档（计划里按 +1 估），
   于是 `tb_voice_wt_source` 稳态是 46 而不是 93；`tb_top_wt_voice` 是 71 而不是 142。
   tb 里用同一公式算期望，注释按实测改。
3. **`tb_voice_vca` 用例 4 的 128:255 断言改成 192:255**：128 与 255 落在**不同**的
   `att()` 力度档（128 多衰减 1 位），比不出来。改用同一档的 192:255（差 ≤1 LSB），
   另外单独用公式精确断言 128 的稳态值。这是对计划"±1 LSB"期望的必要修正。

实测值（可手算复核）：vel 255 → 1528、vel 192 → 1150、vel 128 → 383、vel 0 → 0；
单声部满幅波表 → 12238；顶层常量表 `0x3000 >>> 4` → 71；起音首采样恒为 0。

### Task 2：失谐的实现比计划多一处，测试换成"看 bank 字 + 首次写回"

1. **`target_b` 必须一起失谐**（计划只写了 `target_b = step_b`，等价于 pitch=0 的情形）。
   若 target 仍是基准步进而 step 是失谐步进，`bounded_step` 会以 ≤512/采样把 step 拉回 target，
   失谐在约 300 个采样内消失。实现为
   `target_b = detuned_step(apply_delta(base, -pitch), gain)`。
2. **测试不看拍频，看激活字与首次写回**：拍频周期 ≈ 256 个音周期（约 2.8 万采样），
   仿真窗口不划算。`tb_voice_detune` 直接采样 `dut.bank_wr_data`（三条写路径各自的有效周期），
   再检查 slot 0 的**首次扫描写回**：`phase_a = base`、`phase_b = 0x80000000 + base - det`，
   即"半周期预置真的进了累加器，且两个累加器从第一个采样起就不同速"。
3. **`tb_top_wt_voice` 的斜坡窗口从 120 采样改到 95**：`phase_b` 预置半周期后，
   第二个振荡器读表索引提前 512 点，约 115 采样就撞到表尾回绕，会在窗口里塞进 −511×63 的跳变。
4. **已知限制（未修，记录在此）**：`REVOICE`（LIVE 模式下给持续音改音高/音色）把两个振荡器的
   target 都写成对称值，`bounded_step` 会在几百采样内把失谐抹平。PLAY（打分的路径）不发 REVOICE，
   所以不受影响；LIVE 的持续音改调会变回"单振荡器"音色。要修就把失谐挪到 calc 级
   （`calc_step_b` 由 `bounded_step` 结果派生），代价是热路径多一个 32 位移位 + 减法。
5. **音符 ROM 只有 8 个音高**（55/57/60/62/64/67/69/72），其余返回 0。tb 里的音名必须取这 8 个之一，
   否则 `rom_step = 0`、失谐恒为 0（`tb_voice_detune` 的抢声部用例就是先踩到这点才发现）。
