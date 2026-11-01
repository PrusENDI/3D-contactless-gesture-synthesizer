# P2a Implementation Plan（滤波器 + LFO + 效果器接线 + 主音量）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在三条音频出口之后插入一个 24 dB/oct 梯形低通（ZDF 反馈、对数截止、共振）与一个多波形 LFO，并把 `v2_fx_lite` 已有的六个参数与一个主音量接到 CSR——全部默认透明，主机显式打开才改变音色。

**Architecture:** 控制面先在 `v2_contract_pkg` 里定义 6 个地址、写掩码与**唯一的 clamp 函数**（写入成功但值被夹住，不是 NACK）；顶层把这 6 个字变成寄存器，滤波/LFO/音量挂在 `i2s_sample` 的 mux 之后、I2S 之前，用 `sample_ce` 作时基（48 kHz），接受 1 个采样延迟；滤波器与 LFO 各自是独立模块，系数表由 Python 生成器产出并随源码提交。

**Tech Stack:** SystemVerilog（Gowin GW5A / 80 MHz，48 kHz 采样）、ModelSim `vlog/vsim`、`scripts/sim_unit.py`、`scripts/gate.py`、`scripts/sim.py`、`scripts/synth.py`、Python 3（生成器与黄金模型）、PowerShell 板级脚本。

**Spec:** `docs/superpowers/specs/2026-11-01-filter-lfo-design.md`（r3，含 §6 验收、§11 参数面、§12 预设映射）。执行者**两份都要读**。

## Global Constraints

- 只做 **P2a**：`0x40 FILTER`、`0x44 LFO`、`0x84/0x88/0x8C FX`、`0x90 VOLUME`。**`0x94/0x98/0x9C` 是 P2b，本轮一个字节都不碰，写入必须仍然 NACK。**
- 默认值必须让音色**逐位不变**：滤波旁路、LFO 关、`volume=0x10000`、`fx` 复位值 = 今天的编译配置（板上 `FX_ENABLE(1) FX_LEVEL(1)` → `0x0015_0000`；tb 里 `FX_ENABLE(0)` → `0x0001_0000`）。
- 时基是 **`sample_ce`**（48 kHz），不是 mux 后的 `i2s_sample_valid`；滤波器输出相对输入晚 **1 个采样**（20.8 µs），I2S 的 valid 不加延迟。
- 校验是 **clamp 不是 NACK**（`v2_csr_clamp()` 是唯一来源）；位掩码外的位仍由 `v2_csr_data_valid()` 拒绝。
- 每个任务结束：`python scripts/sim_unit.py --tb <tb>` 绿，`python scripts/gate.py --compile` 0 error / 0 warning，`python scripts/sim.py` 不超出基线（13 pass / 4 known-fail），源文件 **LF、无 BOM**，`git add <具体文件>` 提交。
  **两个例外（已核实机制）**：
  1. `filelist.f` 是**显式清单**（不是通配），Task 3/4/5 新建的 `.sv` **必须同时加进去**，否则 `sim_unit` 编译不到它；
  2. `gate.py` 有一条静态规则：除声明顶层外**不许有未例化的模块**。所以 Task 3/4/5 提交时 `gate.py` 会且只会报一条
     `additional uninstantiated module(s)`，并且**因为存在静态失败会跳过编译步骤**——那三个任务的**编译证据来自 `sim_unit`**
     （它编译整个 filelist + tb）。**Task 6 必须恢复干净的 `GATE: PASS`**，并把这条例外写进报告。
- 构建门（Task 7）：CLS ≤ 11300、worst slack ≥ −3.5 ns、新实例不进最差 25 条、违约端点数 ≤ 基线+50。
- 不动 `u_patch_bank`、不动 `v2_voice_engine_banked`、不动 `v2_fx_lite` 的内部 DSP。

## Review Focus

1. **旁路逐位透明**：`volume=0x10000` 且滤波旁路时，`i2s_sample` 必须与改动前逐位相同（Task 6）。
2. **时基只在 `sample_ce` 更新**：80 MHz 的每一拍都不许推进滤波器状态，否则系数表的同步读会错（Task 5）。
3. **LIVE 门关掉时状态仍推进**：`i2s_sample_valid` 在 LIVE 门关时没有脉冲，LFO 相位与滤波器状态**不能**被它冻住（Task 6）。
4. **满幅与共振不回绕**：4 倍满幅正弦进共振滤波器，输出必须是平顶，不能在零附近出现反相尖峰（Task 5）。
5. **P2b 的地址本轮必须仍然 NACK**：`0x9C` 写进去要报 BAD_ADDRESS，不能被半实现成"写成功但无效"（Task 2）。

---

### Task 0: 把构建门做成可执行的（`scripts/synth.py`）

**Files:**
- Modify: `scripts/synth.py:168-210`（资源/时序摘取段）
- Create: `host/test_synth_report.py`

**Interfaces:**
- Produces:
  - `parse_timing(tr_text: str, paths_text: str) -> dict` → keys `violations:int, tns:float, endpoints:int, fmax:float, worst_slack:float, worst_from:str`
  - `gate_fail(summary: dict) -> list[str]` → 空列表 = 通过；否则每项一行人话
  - CLI 新增 `--max-cls`（默认 11300）、`--min-slack`（默认 −3.5）、`--enforce`（给了才非零退出）

- [ ] **Step 1: 写失败测试 `host/test_synth_report.py`**

```python
import unittest
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import synth_report  # 见 Step 3：把纯函数从 synth.py 拆到这里

TR = """
<Numbers of Setup Violated Endpoints>:1401
clk_50m                                      setup           0.000           0
u_v2/u_clock/u_pll/CLKOUT0.default_gen_clk   setup           -1691.814       1401
1     u_v2/u_clock/u_pll/CLKOUT0.default_gen_clk   80.000(MHz)   63.639(MHz)   18      TOP
"""

PATHS = """=====
SETUP
-3.214
15.410
12.196
u_v2/u_v2_uart/frame[3]_7_s0/Q
u_v2/u_v2_uart/last_frame[9]_1_s0/CE
=====
SETUP
-3.204
15.400
12.196
u_v2/u_v2_uart/frame[3]_7_s0/Q
u_v2/u_v2_uart/last_frame[9]_5_s0/CE
"""


class ParseTiming(unittest.TestCase):
    def test_reads_the_four_numbers(self):
        t = synth_report.parse_timing(TR, PATHS)
        self.assertEqual(t["violations"], 1401)
        self.assertAlmostEqual(t["tns"], -1691.814)
        self.assertEqual(t["endpoints"], 1401)
        self.assertAlmostEqual(t["fmax"], 63.639)
        self.assertAlmostEqual(t["worst_slack"], -3.214)
        self.assertEqual(t["worst_from"], "u_v2/u_v2_uart/frame[3]_7_s0/Q")

    def test_missing_section_is_not_silent(self):
        with self.assertRaises(ValueError):
            synth_report.parse_timing("no numbers here", PATHS)


class Gate(unittest.TestCase):
    def test_pass(self):
        s = {"cls": 10900, "cls_max": 11520, "worst_slack": -3.0}
        self.assertEqual(synth_report.gate_fail(s, max_cls=11300, min_slack=-3.5), [])

    def test_cls_over(self):
        s = {"cls": 11400, "cls_max": 11520, "worst_slack": -3.0}
        self.assertEqual(len(synth_report.gate_fail(s, max_cls=11300, min_slack=-3.5)), 1)

    def test_slack_under(self):
        s = {"cls": 10900, "cls_max": 11520, "worst_slack": -5.0}
        self.assertEqual(len(synth_report.gate_fail(s, max_cls=11300, min_slack=-3.5)), 1)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python -m unittest host.test_synth_report -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'synth_report'`

- [ ] **Step 3: 实现 `scripts/synth_report.py`**

把摘取与判门做成纯函数（`synth.py` 只负责构建与调用），就是为了它们能被单测：

```python
def parse_timing(tr_text, paths_text):
    """Return the four numbers the build gate needs, or raise ValueError."""
```

`.tr` 里取：`Numbers of Setup Violated Endpoints>:(\d+)`、`default_gen_clk\s+setup\s+(-?[\d.]+)\s+(\d+)`、
`Actual Fmax\s+([\d.]+)\(MHz\)`；`.timing_paths` 里取第一条路径 = 第 3 行（下标 2）的 slack 与第 6 行（下标 5）的起点。
任何一项取不到就 `raise ValueError("missing ...")`——**不许返回 None 糊过去**。

- [ ] **Step 4: 跑测试确认通过**

Run: `python -m unittest host.test_synth_report -v`
Expected: `OK`（6 tests）

- [ ] **Step 5: 把它接进 `scripts/synth.py`**

`main()` 里把当前从 `.rpt.txt` 取的那些（现在打印 `None`）换成读
`impl/<run>/impl/pnr/v2_board_top.tr` 与 `v2_board_top.timing_paths`，走 `parse_timing()`；
构建摘要里多打印一行 `gate   : OK / FAIL(...)`；`--enforce` 时非零退出。

- [ ] **Step 6: 用一个已有构建验证（不重新构建）**

Run: `python scripts/synth_report.py --run-dir impl/v2_board_top_vca_detune_mbox`
Expected: 打出 `violations=1401 tns=-1691.814 fmax=63.639 worst=-3.214`，`gate: OK`。

- [ ] **Step 7: 提交**

```bash
git add scripts/synth_report.py scripts/synth.py host/test_synth_report.py
git commit -m "feat: make the build gate executable instead of a printed None"
```

---

### Task 1: 契约——6 个地址、掩码、唯一的 clamp 函数

**Files:**
- Modify: `rtl/v2_contract_pkg.sv`（地址枚举 ~122、写掩码 ~169、位段常量 ~221、`v2_csr_access` ~354、`v2_csr_write_mask` ~385）
- Create: `tb/tb_contract_clamp.sv`

**Interfaces:**
- Produces:
  - `V2_CSR_FILTER=8'h40`, `V2_CSR_LFO=8'h44`, `V2_CSR_FX_A=8'h84`, `V2_CSR_FX_B=8'h88`, `V2_CSR_FX_C=8'h8C`, `V2_CSR_VOLUME=8'h90`
  - 写掩码：`0x010FFFFF`、`0x3FFFFFFF`、`0x001FFFFF`、`0xFFFF03FF`、`0xFFFFFFFF`、`0x0003FFFF`
  - `function automatic logic [31:0] v2_csr_clamp(input logic [7:0] address, input logic [31:0] data);`

- [ ] **Step 1: 写失败测试 `tb/tb_contract_clamp.sv`**

按 spec §11.6 逐行断言（每条一行 `expect`）：ci>423→423；rate>20000→20000；`FX_A` 的 gain>0x10000→0x10000；
`FX_C` 的 feedback>0x7333→0x7333、reverb_mix>0x7FFF→0x7FFF；`VOLUME`>0x20000→0x20000；
其余地址原样返回（含 `0x9C`：**本轮不 clamp、不改语义**）。

```systemverilog
import v2_contract_pkg::*;
task automatic expect(input logic [7:0] addr, input logic [31:0] in, input logic [31:0] want);
  logic [31:0] got;
  got = v2_csr_clamp(addr, in);
  if (got !== want) $fatal(1, "0x%02h 0x%08h -> 0x%08h, expected 0x%08h", addr, in, got, want);
endtask
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_contract_clamp`
Expected: FAIL —— `v2_csr_clamp` 未定义

- [ ] **Step 3: 改契约**

1. 地址：把 `V2_CSR_DIAG_AUDIO/ROUTER` 改名成 `V2_CSR_FILTER/LFO`，加 `FX_A/FX_B/FX_C/VOLUME`；
2. 删掉 `V2_CSR_DIAG_*_UNDERRUN/PEAK/DROP/FIFO_LEVEL_SHIFT` 四个常量与两条 `WRITE_MASK=0`；
3. `v2_csr_access()`：把这六个从 RO 列表移到 RW（`default` 分支已是 RW，只需从 RO 列表删掉）；
4. `v2_csr_write_mask()`：按 §11.1 给掩码；
5. 加 `v2_csr_clamp()`：用 `case (address)`，逐个字段夹（`ci` 用 `>423 ? 423`；`rate` 用 `>20000 ? 20000` …），
   最后 `return (clamped & write_mask)`——**保证不会留下掩码外的位**。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_contract_clamp`
Expected: `UNIT tb_contract_clamp: PASS`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_contract_pkg.sv tb/tb_contract_clamp.sv
git commit -m "feat: six P2a CSRs with one clamp function in the contract"
```

---

### Task 2: 顶层——6 个寄存器、写分支、读回

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`（寄存器声明 ~591-600、写分支 ~1280-1310、读回 `case` ~1139、复位 ~1060-1075）
- Create: `tb/tb_top_p2_csr.sv`

**Interfaces:**
- Consumes: Task 1 的地址、掩码、`v2_csr_clamp`
- Produces（供 Task 6 使用）：`logic [31:0] filter_ctrl, lfo_ctrl, fx_a, fx_b, fx_c, volume_reg;`
  以及解包后的 `ci_reg[11:0]`、`res_reg[7:0]`、`filter_en`、`lfo_en`、`lfo_rate_mhz[15:0]`、`lfo_depth[7:0]`、
  `lfo_retrig`、`lfo_unipolar`、`lfo_wave[2:0]`、`fx_enable_reg`、`fx_level_reg[1:0]`、`fx_gain_reg[17:0]`、
  `fx_cutoff_reg[15:0]`、`fx_delay_reg[9:0]`、`fx_feedback_reg[15:0]`、`fx_reverb_reg[15:0]`

> **Task 1 已落地的事实**（`c868b8e`）：`0x84–0x90` 原本叫 `V2_CSR_TLM_STATUS/LATENCY/PEAK/RMS`，
> 现在**已改名**成 `FX_A/FX_B/FX_C/VOLUME`（同一个地址，避免 case 重复导致 vlog 警告），
> 那四个 `TLM_*_SHIFT` 常量已删；`0x94/0x98/0x9C` 保持原名、RO、掩码 0。
> 因此 Task 7 的 GUI 文档要写清"PEAK/RMS 这两个名字已经不存在"。

- [ ] **Step 1: 写失败测试 `tb/tb_top_p2_csr.sv`**

复用 `tb/tb_top_wt_voice.sv` 的 `inject_control()`（11 字节帧 + 等回复 + 查 `rsp_error`）。断言：

1. 复位读回：`0x40=0`、`0x44=0`、`0x84=0x0001_0000`（该 tb 用 `FX_ENABLE(0)`）、`0x88=0xFFFF_0000`、`0x8C=0`、`0x90=0x0001_0000`；
2. 写读往返：写 `0x40=0x0101_00C5` 读回相同（ci=0xC5、res=0x10、enable=1；位段 `[11:0]`/`[19:12]`/`[24]`）；
3. clamp：写 `0x40` 的 ci=0xFFF → 读回 `0x0000_01A7`（423 = `0x1A7`，**不是 `0x1AF`**）；
   写 `0x8C=0xFFFF_FFFF` → 读回 `0x7FFF_7333`；
4. **P2b 未实现**：写 `0x9C` 必须 `rsp_error == 8'h02`（BAD_ADDRESS）；
5. 掩码外的位：**写 `0x90 = 0xFFFF_FFFF` 会被 `v2_csr_data_valid()` 拒成 BAD_DATA（`0x07`）且寄存器不变**
   （UART 链路比 clamp 更早拒绝掩码外位——Task 2 实现时核实）；再用**掩码内**的 `0x0003_FFFF` 写一次，
   读回 `0x0002_0000`（夹到 2.0 并清掉掩码外的位）。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_top_p2_csr`
Expected: FAIL —— 读回 0（地址还是 RO）或写被 NACK

- [ ] **Step 3: 实现**

1. 声明 6 个 32 位寄存器 + 复位值（见 Global Constraints）；
2. 写分支（与既有 `if (cmd_op == V2_OP_WRITE && cmd_address == …)` 同款）：
   `filter_ctrl <= v2_csr_clamp(V2_CSR_FILTER, cmd_data);` … 六个；
3. 读回 `case` 里加六个分支；
4. 解包成 Task 6 要用的具名信号（组合赋值即可，不要另写逻辑）。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_top_p2_csr`
Expected: `UNIT tb_top_p2_csr: PASS`

- [ ] **Step 5: 回归门**

Run: `python scripts/gate.py --compile` → `GATE: PASS`
Run: `python scripts/sim.py` → `SIM: PASS`（13/4，RAM=0/1 一致）

- [ ] **Step 6: 提交**

```bash
git add rtl/mgc3130_v2_top.sv tb/tb_top_p2_csr.sv
git commit -m "feat: latch the six P2a CSRs through the contract clamp"
```

---

### Task 3: 系数表生成器 + 浮点黄金模型

**Files:**
- Create: `host/filter_reference.py`（黄金模型：TPT 一极点、4 极点 ZDF、`minus3db(ci)`、`peak_at_res(ci,res)`）
- Create: `host/filter_coeff.py`（生成器，写 `rtl/v2_filter_coeffs.sv`）
- Create: `rtl/v2_filter_coeffs.sv`（**生成物，提交**，头部写明 `generated by host/filter_coeff.py`）
- Create: `host/test_filter_coeff.py`

**Interfaces:**
- Produces:
  - `rtl/v2_filter_coeffs.sv`：`module v2_filter_coeffs(input logic clk, input logic [9:0] addr, output logic [15:0] dout);`
    `localparam int R_BASE = 512;` —— `addr 0..511` = `G[ci]`（Q16，`round(65536·q/(1+q))`，`q=tan(π·fc/fs)`，`fc=40·2^(ci/48)`，ci>423 取 423 的值）；
    `addr 512..767` = `R[ridx]` = `round(65536/(1+x))`，`x = ridx * 0.94 / 255`（覆盖 x∈[0,0.94]，见 spec §5.3）
  - `host/filter_reference.py`：`minus3db(ci) -> float`、`peak_db(ci, res) -> float`
  - CLI：`python host/filter_coeff.py --emit` 重新生成 `.sv`；`python host/filter_reference.py --emit-tb`
    打印 Task 5 要用的常数（三档 ci 的 −3 dB 频率、res=255 的三档峰值）

- [ ] **Step 1: 写失败测试 `host/test_filter_coeff.py`**

```python
class Table(unittest.TestCase):
    def test_g_is_the_tpt_coefficient(self):
        # ci=48 -> fc=80 Hz -> q=tan(pi*80/48000) -> G=q/(1+q)
    def test_g_is_monotone_and_clamped(self):
        # G 随 ci 单调下降；ci>423 与 ci=423 相同
    def test_r_is_the_reciprocal_table(self):
        # R[0]=65536；R 随 ridx 单调下降；R[255] ~ 65536/(1+0.94)
    def test_reference_matches_the_spec_table(self):
        # spec §5.3：ci=96 -> 70 Hz、ci=192 -> 278 Hz、ci=288 -> 1.12 kHz（±5%）
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python -m unittest host.test_filter_coeff -v`
Expected: FAIL —— 模块不存在

- [ ] **Step 3: 实现两个脚本 + 生成文件**

生成器写出 768 行 `mem[n] = 16'hXXXX;` 的 `initial` 块（Gowin 用 `initial` 推断 BSRAM 是标准做法；
若 Task 7 的构建显示它被摊成 LUT，退回 `$readmemh` + 由 `synth.py` 拷进 run 目录，见 Task 7 的备注）。

- [ ] **Step 4: 跑测试确认通过并生成文件**

Run: `python -m unittest host.test_filter_coeff -v` → `OK`
Run: `python host/filter_coeff.py --emit` → 生成 `rtl/v2_filter_coeffs.sv`（768 项）
Run: `python host/filter_reference.py --emit-tb` → 记下三档 −3 dB 频率与三个峰值，Task 5 用

- [ ] **Step 5: 编译门**

Run: `python scripts/gate.py --compile` → `GATE: PASS`（模块此时还没人例化，只要求能编译）

- [ ] **Step 6: 提交**

```bash
git add host/filter_reference.py host/filter_coeff.py host/test_filter_coeff.py rtl/v2_filter_coeffs.sv
git commit -m "feat: generate the ladder coefficient table and a float reference model"
```

---

### Task 4: LFO 模块（多波形 / 单极 / 重触发）

**Files:**
- Create: `rtl/v2_lfo_triangle.sv`
- Create: `tb/tb_lfo_triangle.sv`

**Interfaces:**
- Produces:

```systemverilog
module v2_lfo_triangle (
    input  logic clk, rst_n, sample_ce,
    input  logic [15:0] rate_mhz,     // 0..20000
    input  logic [7:0]  depth,        // ci 单位
    input  logic        enable, retrig, trigger, unipolar,
    input  logic [2:0]  waveform,     // 0 tri 1 sin 2 saw 3 square 4 S&H
    output logic signed [12:0] offset_ci   // -255..+255；unipolar 时 0..255
);
```

- [ ] **Step 1: 写失败测试 `tb/tb_lfo_triangle.sv`**

1. **周期**：`rate_mhz=1000`（1 Hz）时，三角从 -depth 升到 +depth 再回到 -depth 用 **48000** 个 `sample_ce`（±2%）；
2. **depth=0**：任何波形、任何 `sample_ce` 数，`offset_ci` 恒为 0；
3. **单极**：`unipolar=1` 时所有采样 `offset_ci >= 0`，峰值为 `+depth`；
4. **波形**：三角在两半周期内线性；方波只有 `+depth/-depth` 两个值且各占一半；锯齿一处回绕、其余单调；
   正弦首四分之一单调上升且端点误差 <5%；S&H 在一段内恒定、换段时跳变；
5. **重触发**：`retrig=1` 时给 `trigger` 一个脉冲，相位归零（`offset_ci` 立刻回到 `-depth`）；
   `retrig=0` 时 `trigger` 无影响；
6. **`enable=0`**：输出 0，但内部相位**继续推进**（把相位从层次引用读出来断言）。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_lfo_triangle`
Expected: FAIL —— 模块不存在

- [ ] **Step 3: 实现**

32 位相位累加：`inc = (rate_mhz * 45813) >> 9`（Q9 的 2³²/48000/1000，误差 <0.1%）；
三角 `tri = phase[31] ? ~phase[30:0] : phase[30:0]`（31 位，`0..2^31-1`），
双极 `b = $signed({1'b0, tri}) - 32'sd(1<<30)`（落在 `[-2^30, 2^30)`）；
正弦可用三次多项式 `sin(πx/2) ≈ x(3-x²)/2`（`x = b/2^30`，误差 0.5%，不需要查表）；
`offset_ci = (b * $signed({1'b0, depth})) >>> 30`（depth=255 → ±255）；`unipolar` 时取 `|offset_ci|`；
`enable=0` 时输出 0 但相位照走。`width: offset_ci` 是 `signed [12:0]`。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_lfo_triangle` → `UNIT tb_lfo_triangle: PASS`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_lfo_triangle.sv tb/tb_lfo_triangle.sv
git commit -m "feat: multi-waveform LFO driving the cutoff index in the log domain"
```

---

### Task 5: 梯形滤波器模块（TPT ×4 + ZDF + 饱和）

**Files:**
- Create: `rtl/v2_ladder_lp.sv`
- Create: `tb/tb_filter_ladder.sv`

**Interfaces:**
- Produces:

```systemverilog
module v2_ladder_lp (
    input  logic clk, rst_n, sample_ce,
    input  logic signed [15:0] audio_in,
    input  logic [11:0] ci,          // 0..423（上游已 clamp）
    input  logic [7:0]  res,         // 0..255 -> K = res*3.75/256
    output logic signed [15:0] audio_out,
    output logic        out_valid    // 每次 sample_ce 之后恰好一个脉冲
);
```

内部例化 Task 3 的 `v2_filter_coeffs`（一个读口，两个周期分别读 G 与 R）。

- [ ] **Step 1: 写失败测试 `tb/tb_filter_ladder.sv`**

用 `sample_ce` 驱动（周期 20 个时钟即可），每次等 `out_valid`。断言：

1. **延迟**：同一个冲激，`audio_out` 出现在**下一个** `sample_ce` 之后（不是同一个）；
2. **−3 dB 三点**：`res=0`，白噪声/正弦扫频测 `ci = 96 / 192 / 288`，与 Task 3 产出的常数比，容差 ±15%；
3. **共振单调**：`ci=192`，`res = 0/85/170/255` 的峰值单调上升，`res=255` 时 `spec 常数 +15 dB ±2 dB`；
4. **共振均匀**：`res=255` 在 `ci = 48 / 192 / 336` 三处峰值差 ≤ 3 dB（这是 ZDF 才有的性质）；
5. **不发散**：扫描 `ci 0..423 × res {0,128,255}`，每点 2000 采样，`|audio_out| ≤ 32767` 且无单调增长；
6. **饱和不回绕**：4 倍满幅正弦进 `res=255`，输出是平顶，且不出现与输入反相的尖峰；
7. **只有 `sample_ce` 才更新**：两个 `sample_ce` 之间，`audio_out` 保持不变（Review Focus 2）。

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_filter_ladder`
Expected: FAIL —— 模块不存在

- [ ] **Step 3: 实现**

按 spec §5.2：`v_i = G(u_i − s_i)`、`y_i = v_i + s_i`、`s_i ← y_i + v_i`；
`S = (1−G)(G³s₁ + G²s₂ + G s₃ + s₄)`、`u = (x − K·S)/(1 + K·G⁴)`（用 R 表查 `1/(1+x)`）、
输出冲一次 int16 饱和。乘加分层交给实现者，但**必须在 1667 个时钟内出一个样本**。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_filter_ladder` → `UNIT tb_filter_ladder: PASS`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_ladder_lp.sv tb/tb_filter_ladder.sv
git commit -m "feat: 24 dB/oct zero-delay-feedback ladder low-pass with uniform resonance"
```

---

### Task 6: 顶层接线（滤波 + LFO + 音量 + FX 参数）

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`（mux ~658、fx 例化 ~600-605、`fx_quiet` ~629、i2s 例化 ~659）
- Create: `tb/tb_filter_chain.sv`、`tb/tb_fx_delay.sv`

**Interfaces:**
- Consumes: Task 2 的解包信号、Task 4 的 `v2_lfo_triangle`、Task 5 的 `v2_ladder_lp`

- [ ] **Step 1: 写失败测试 `tb/tb_fx_delay.sv`**

`v2_fx_lite` 从没被测过。用 `level=2`、`delay_samples=10`、`feedback=0x4000`、`gain=0x10000`：
一个冲激进，第 11 个 `sample_ce` 出现回声、再往后每隔 10 个采样出现一次且逐次减半（±2 LSB）。

- [ ] **Step 2: 写失败测试 `tb/tb_filter_chain.sv`**

例化 Task 2 解包后的三件套（LFO → ci 相加 clamp → 滤波器 → 音量），断言：

1. **旁路逐位透明**：`filter_en=0`、`volume=0x10000` → 输出与输入逐位相同（Review Focus 1）；
2. **LIVE 门关掉仍推进**：把 `sample_ce` 继续给、但把 `i2s_sample_valid` 拉低 4800 个采样，
   LFO 相位仍前进、滤波器仍更新（Review Focus 3）；
3. **音量**：`volume=0x8000` → 输出是输入的一半（±1 LSB）；`0x20000` → 两倍但不过 int16；
4. **LFO 扫动**：`lfo_en=1, depth=64, rate=2000` 时，ci 的峰值与谷值相差 128（±2）。

- [ ] **Step 3: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_fx_delay`、`--tb tb_filter_chain`
Expected: 两个都 FAIL

- [ ] **Step 4: 实现接线**

1. 把现在的 `assign i2s_sample = …mux…` 改名成 `i2s_sample_raw`；
2. 例化 `v2_lfo_triangle`（`trigger` = 进入 PLAY 的边沿：`mode_play && !mode_play_q`），
   `ci_total = (ci_reg + offset_ci)` 夹到 `[0,423]`；
3. 例化 `v2_ladder_lp`（`sample_ce` 使能），旁路 = 输出二选一（滤波器照常跑）；
4. 主音量：`(s2(sel) * volume_reg) >>> 16` 再饱和，`volume=0x10000` 时逐位等于输入；
5. `v2_fx_lite` 的七个端口改接 Task 2 的寄存器（复位值 = 今天的编译配置）。

- [ ] **Step 5: 跑测试确认通过 + 回归**

Run: 两个 `sim_unit` → PASS
Run: `python scripts/gate.py --compile` → `GATE: PASS`
Run: `python scripts/sim.py` → `SIM: PASS`（13/4，RAM=0/1 一致）
Run: `python scripts/test_potts_plane.py` → `POTTS PLANE: PASS`

- [ ] **Step 6: 提交**

```bash
git add rtl/mgc3130_v2_top.sv tb/tb_filter_chain.sv tb/tb_fx_delay.sv
git commit -m "feat: put the ladder, the LFO and the master volume into the audio chain"
```

---

### Task 7: 构建门、板上 A/B、文档

**Files:**
- Modify: `docs/progress-2026-11-01.md`、`docs/HANDOFF.md`、`docs/host-tools-and-gui-controls.md`
- 构建产物：`impl/v2_board_top_p2a/`

- [ ] **Step 1: 构建**

Run: `python scripts/synth.py --run-id p2a_master_volume`（run id 不得重复，`synth.py` 拒绝复用）
Expected: `SYNTH: PASS`；`gate: OK`（Task 0 的输出）。若 `gate: FAIL`：**停下来先改结构**，
（a）CLS 超 → 按 spec §11.4 把 P2a 拆成 P2a-1/P2a-2；（b）slack 超 → 加流水；（c）新实例进最差 25 条 → 看是不是系数表被摊成 LUT。
**备注**：若 BSRAM 数没从 37 涨到 38，说明 `initial` 表没被推断成 BSRAM，改成 `$readmemh` + `synth.py` 拷 `.mi` 进 run 目录，重跑本步。

- [ ] **Step 2: 记录四个数**

从 `impl/v2_board_top_p2a_master_volume/impl/pnr/v2_board_top.tr` 与 `.timing_paths` 抄：
CLS / 违约端点数 / TNS / worst / Fmax / worst 起点，写进 progress。

- [ ] **Step 3: 烧录并确认身份**

Run: `powershell -File "…/board_program.ps1" -FsFile impl/v2_board_top_p2a_master_volume/impl/pnr/v2_board_top.fs -Operation 4`
Expected: `PROGRAM PASS`，随后 `0xB0 = 0x5A5A0003`。

- [ ] **Step 4: 板上验收（要手/耳朵）**

1. 默认（全旁路）跑 `board_wt_voice_play.ps1` → PASS，且听感与 P1 结束时一致；
2. 写 `0x40 = 0x0100_00C0`（使能 + ci=192）→ 听"变暗"；
3. 写 `0x44 = 0x0180_0500`（使能 + 1280 mHz + 深度 128）→ 听"扫动"；
4. 写 `0x84 = 0x0015_0000 | 档位`（档位 2 = 加延迟，`0x88` 里设 `delay=4800`、`cutoff=0xFFFF`；`0x8C` 里设 `feedback=0x4000`）→ 听回声；
5. `0x90 = 0x0002_0000` → 听整体变响（不破音）。
**判据只写听到什么，不写"通过"。**

- [ ] **Step 5: 文档**

progress 记：四个时序数、sha256、板上听到的每一条、未验证项（如 GAO 频谱）；
HANDOFF 改成"P2a 完成 / P2b 待 P2a 的 CLS 决定"；GUI 文档补 6 个寄存器与三条"只作用于 PLAY"的说明。

- [ ] **Step 6: 提交**

```bash
git add docs/progress-2026-11-01.md docs/HANDOFF.md docs/host-tools-and-gui-controls.md
git commit -m "docs: P2a landed - resources, timing, what was heard"
```

---

## Self-Review

**1. Spec coverage**

| spec 要求 | 任务 |
| --- | --- |
| §5.2 结构（TPT×4 + ZDF + 饱和） | Task 5 |
| §5.3 系数/截止映射（G 表、R 表） | Task 3（生成）+ Task 5（用） |
| §5.4 截止上限的诚实说法（−3 dB 12.3 kHz） | Task 5 第 2 条（ci=288 校验）+ Task 7 文档 |
| §5.5 LFO（三角、对数域、depth） | Task 4 |
| §5.6 时基 `sample_ce`、1 采样延迟、旁路=输出选择 | Task 5 第 1/7 条、Task 6 第 1 条 |
| §5.7/§11.1 控制面、掩码、复位值 | Task 1 + Task 2 |
| §11.2 FX 语义（enable 不管 gain/cutoff、档位、clamp） | Task 1（clamp）+ Task 6（接线）+ Task 7（文档） |
| §11.2-6 LFO 波形/重触发/单极 | Task 4 |
| §6 构建门（CLS/worst/新锥/端点数） | Task 0（工具）+ Task 7（执行） |
| §11.6 clamp 表 | Task 1 |
| §12 预设映射 | 不在本计划（P2c） |

**2. Step scan**：每步给的是"一个签名 + 一份断言"或"一条命令 + 期望输出"；
没有"处理边界情况"这类空步。Task 4 的正弦实现留了两个可接受选项并给了容差（0.5%/5%），因为签名与测试已决定其行为。

**3. Type consistency**：`offset_ci` 是 `signed [12:0]`（±255），Task 6 里与 `ci_reg[11:0]` 相加后夹到 `[0,423]`；
`v2_csr_clamp` 在 Task 1 定义、Task 2 调用，签名一致；`v2_filter_coeffs` 的 `R_BASE=512` 在 Task 3 定义、Task 5 使用。

**4. Review Focus 对应**：1→Task 6 第 1 条；2→Task 5 第 7 条；3→Task 6 第 2 条；4→Task 5 第 6 条；5→Task 2 第 4 条。五条都有测试。

**5. Proportion**：本计划约 330 行，实现约 700 行 RTL + 4 个 tb + 2 个 Python 工具；计划只钉接口、数值与断言，不含实现体。

**已知缺口（写在这里，别假装没有）**：P2b（0x94/0x98/0x9C）按 spec §11.4 等 P2a 的 CLS 数字再规划；
§12 的预设接线是 P2c。
