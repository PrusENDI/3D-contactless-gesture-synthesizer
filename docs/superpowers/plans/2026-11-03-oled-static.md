# OLED 静态图实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 FPGA 上电后把一张 128×64 单色图写进 0.96" SSD1306 屏，之后停机，且不牺牲音频时序。

**Architecture:** 图预栅格化成 1024 字节（8 页 × 128 列，每字节 1 列 8 行）编进位流里当 ROM；`v2_oled_static` 用一个 FSM 上电后把初始化序列 + 全帧数据经 SPI（模式 0、≈1 MHz、MSB 优先）推给屏，写完回 IDLE。整块逻辑只占 BSRAM 1 块、无乘法、无新时钟域，并单独做区域约束以免挤压音频链。

**Tech Stack:** SystemVerilog（Gowin GW5A / 100 MHz）、ModelSim `scripts/sim_unit.py`、`scripts/gate.py`、`scripts/synth.py`（**全程只跑一次 P&R**）、Python 3（stdlib + 可选 Pillow）、PowerShell 板级脚本。

**Spec:** `docs/superpowers/specs/2026-11-03-oled-static-design.md`（型号、引脚表、初始化序列、资源预算、验收线都在那边，执行者两份都要读）。

## Global Constraints

- 引脚（已确认，来自 spec §4.1）：`oled_sck`=**J7**、`oled_mosi`=**K7**、`oled_res_n`=**L8**、`oled_dc`=**L7**、`oled_cs_n`=**K10**、`oled_blk`=**J10**；与现有 10 个脚及配置 flash 一族（IOT56/58/31）不重叠。
- **只允许一次 P&R 构建**（用户明确嫌布线慢）：Task 0–3 全部用 `gate.py --compile` + 仿真验证，P&R 只在 Task 4 跑一次。
- 资源硬线：**CLS ≤ 基线+150**、**worst ≥ −3.6 ns**、**DSP 仍 28/28**、BSRAM 34→35（只加 1 块）。
- 不许新增乘法（DSP 满）、不许新增时钟域（SPI 用慢使能）、不许 BSRAM 放图以外的用途。
- 改动不得触碰 LIVE/PLAY 音频链的任何现有锥；OLED 逻辑与顶层音频只有"上电脉冲"一条弱耦合。
- 文件 UTF-8 无 BOM、LF；`tri`/`before` 是保留字；`$fatal`/`$display` 里不做 `.` 字符串拼接。
- 每个 Task 结束：跑列出的命令、`git add` 具体文件、提交信息写明"改了什么 + 为什么"。

## Review Focus

1. **位序与方向**：SSD1306 页地址下每字节是**同一列上 8 个纵向像素、bit0 在最上**。写反了屏上是上下翻转或逐字节错位。→ Task 1 的 8×8 位图逐位断言 + Task 2 的 1024 数据字节比对。
2. **SPI 相位/位序**：模式 0（空闲低、上升沿采样）+ MSB 优先。反了就是全黑或花屏。→ Task 2 把 `sck/mosi` 解码成字节流并逐字节断言。
3. **上电时序**：`res_n` 必须先低 ≥3 µs 再释放、`blk` 使能、**初始化命令必须早于任何数据**。→ Task 2 断言顺序，并断言 `res_n` 有过低脉冲。
4. **引脚合法性**：被保留/复用的球 P&R 会报错。→ Task 4 的构建即是这条测试；失败时报出具体球号，不改设计硬凑。
5. **布局挤压**：本设计慢逻辑也会吃时序（器件是布局受限）。→ Task 4 的 `worst ≥ −3.6` 门槛 + `INS_LOC`；仍不达标就判定"放不下"并回退，不削现有功能。

---

## File Structure

| 文件 | 责任 |
| --- | --- |
| `host/oled_image.py`（新） | 图片 → 1024 字节 `.mem`；`--preview` 出 ASCII 便于人眼核对；`--selftest` |
| `host/test_oled_image.py`（新） | 位序/页打包/长度/自检 |
| `rtl/v2_oled_static.sv`（新） | 图 ROM + 初始化序列 ROM + 刷屏 FSM + SPI 字节机 |
| `rtl/v2_oled_rom.sv`（新，可能不需要） | 仅当 Gowin 不吃 `initial` 初始化 BSRAM 时才要：运行期写入版 |
| `tb/tb_oled_static.sv`（新） | 解码 SPI 字节流，断言初始化/寻址/数据/停机 |
| `rtl/v2_board_top.sv`（改） | 6 个输出端口 + 实例化 |
| `constr/mgc3130_v2.cst`（改） | 6 条 `IO_LOC` + `IO_PORT` |
| `artifacts/oled/*.mem`（生成物，忽略） | 图像数据 |

---

### Task 0: 引脚与端口（语法门先过）

**Files:**
- Modify: `rtl/v2_board_top.sv`（端口列表 + 顶端常量驱动）
- Modify: `constr/mgc3130_v2.cst`

**Interfaces:**
- Produces: 顶层端口 `oled_sck, oled_mosi, oled_dc, oled_cs_n, oled_res_n, oled_blk`（全部 `output wire`），Task 2/3 在此接模块。

- [ ] **Step 1: 加 6 个端口并暂时接常量**

端口按 spec §4.1 命名；`assign oled_blk = 1'b1;`（极性待板上确认），其余先接 `1'b0`/`1'b1` 的空闲电平（`sck=0, mosi=0, dc=0, cs_n=1, res_n=1`）。

- [ ] **Step 2: 加约束**

```tcl
IO_LOC  "oled_sck"   J7;
IO_LOC  "oled_mosi"  K7;
IO_LOC  "oled_res_n" L8;
IO_LOC  "oled_dc"    L7;
IO_LOC  "oled_cs_n"  K10;
IO_LOC  "oled_blk"   J10;
```
每条配 `IO_PORT "..." IO_TYPE=LVCMOS33 DRIVE=8 PULL_MODE=NONE BANK_VCCIO=3.3;`。

- [ ] **Step 3: 语法门**

Run: `python scripts/gate.py --compile`
Expected: `GATE: PASS`，0 error 0 warning（只是语法；引脚合法性要等 Task 4 的 P&R）。

- [ ] **Step 4: 提交**

```bash
git add rtl/v2_board_top.sv constr/mgc3130_v2.cst
git commit -m "feat(oled): reserve the five SPI pins and the backlight enable"
```

---

### Task 1: 图片生成器（纯主机，可 TDD）

**Files:**
- Create: `host/oled_image.py`、`host/test_oled_image.py`

**Interfaces:**
- Produces: `load_frame(path) -> list[int]`（1024 个 0..255，页优先）、`to_bytes(frame) -> bytes`、`preview(frame) -> str`；CLI `python host/oled_image.py --in <png|pgm> --out artifacts/oled/<name>.mem [--preview]`；`--selftest`。

- [ ] **Step 1: 写失败测试**

```python
def test_page_bit_order():
    # 8x8：只有最上一行全亮 -> 第 0 页所有字节 == 0x01（bit0 = 最上）
    frame = [[1]*8 + [0]*56][0]      # 见实现里的二维模型
    out = to_bytes(load_from_bitmap([[1]*8] + [[0]*8 for _ in range(7)]))
    assert len(out) == 1024
    assert out[0] == 0x01 and out[1] == 0x01

def test_length_and_pages():
    out = to_bytes(load_from_bitmap([[0]*128 for _ in range(64)]))
    assert len(out) == 1024
    assert set(out) == {0}
```

- [ ] **Step 2: 运行确认失败**

Run: `python -m unittest host.test_oled_image -v`
Expected: FAIL（模块不存在）

- [ ] **Step 3: 实现**

图模型是 `rows[64][128]`（0/1）；`frame[page*128 + col] = sum(rows[page*8 + bit][col] << bit for bit in range(8))`。
输入：`--in *.pgm`（P5，纯 stdlib 解析）；`*.png` 走 Pillow（bundled），导入失败则提示"先转 PGM"。灰度 >127 记为 1。
`--preview` 输出 64 行 × 128 列的 `#`/`.`。

- [ ] **Step 4: 通过**

Run: `python -m unittest host.test_oled_image -q` → `OK`；`python host/oled_image.py --selftest` → `selftest: PASS`

- [ ] **Step 5: 生成第一张图（李萨如静帧）并提交**

```bash
python host/oled_image.py --selftest
git add host/oled_image.py host/test_oled_image.py
git commit -m "feat(oled): turn an image into the panel's 1024-byte page layout"
```

---

### Task 2: `v2_oled_static` 与字节流 bench

**Files:**
- Create: `rtl/v2_oled_static.sv`、`tb/tb_oled_static.sv`、（必要时）`rtl/v2_oled_rom.sv`

**Interfaces:**
- Consumes: `.mem` 内容（Task 1 的格式）
- Produces（Task 3 依赖）：`module v2_oled_static #(parameter integer SPI_DIV = 100) (input clk, rst_n, start, output sck, mosi, dc, cs_n, res_n, blk, output busy, done)`；图 ROM 端口 `img_addr`/`img_data`（同步读，1 拍延迟），由顶层提供的 ROM 模块驱动。

- [ ] **Step 1: 写 bench（先失败）**

`tb/tb_oled_static.sv` 用一个 8 字节的假图（`img_data = addr`），捕获 `sck/mosi/cs_n/dc` 并解码成字节流，断言：
1. 前段是初始化序列，逐字节等于 spec §5.1 的表；
2. 每页开头是 `0xB0|page`，随后两条列地址 `0x00|(col&0xF)`、`0x10|(col>>4)`；
3. 数据字节序列等于 `img_data[0..1023]`；
4. `res_n` 在最早有过 ≥3 µs 的低脉冲；
5. `done` 之后 `sck` 不再翻转（跑 1000 拍断言无跳变）。

Run: `python scripts/sim_unit.py --tb tb_oled_static` → FAIL（模块不存在）

- [ ] **Step 2: 实现模块**

- 复位后：`res_n=0` 计满 3 µs（`SPI_DIV` 换算）→ 释放 → 等待 → 初始化序列 → 8 页循环写 → `done=1`。
- SPI：`spi_ce`（1 MHz 慢使能）驱动；每字节 8 拍 MSB 优先，`dc` 在字节前设好，`cs_n` 包住整字节。
- **图 ROM 的两种实现**二选一：① `(* ram_style="block" *) reg [7:0] mem [0:1023]` + `initial $readmemh`（Gowin 能推断 BSRAM 初始化就用这个）；② 若综合报不支持，则改成"上电由 FSM 从一个小 ROM/常量表写入 BSRAM"（多 ~40 LUT，仍 1 BSRAM）。实现者在报告里说明选了哪种与依据。

- [ ] **Step 3: 通过**

Run: `python scripts/sim_unit.py --tb tb_oled_static` → PASS（四条断言全过）

- [ ] **Step 4: 提交**

```bash
git add rtl/v2_oled_static.sv tb/tb_oled_static.sv
git commit -m "feat(oled): one-shot SSD1306 writer with a byte-stream bench"
```

---

### Task 3: 接进顶层 + 第一张真图 + 全量回归

**Files:**
- Modify: `rtl/v2_board_top.sv`（替换 Task 0 的常量驱动）
- Create: `artifacts/oled/logo.mem`（由 Task 1 生成，artifacts 已忽略）

**Interfaces:**
- Consumes: Task 0 的端口、Task 2 的 `v2_oled_static`

- [ ] **Step 1: 实例化并把图 ROM 接上**

`start` 用"复位释放后延迟一个小计数器"的一次脉冲；`img_addr/img_data` 接图 ROM；6 个端口从常量改为模块输出。

- [ ] **Step 2: 语法门 + 全套仿真不回归**

Run: `python scripts/gate.py --compile` → `GATE: PASS`（0/0）
Run: `python scripts/sim.py` → `SIM: PASS`（13 pass / 4 known-fail，`RAM=0 vs RAM=1 identical: yes`）
Run: `python scripts/sim_unit.py --tb tb_oled_static` → PASS
Run: `python scripts/sim_unit.py --tb tb_live_engine` 与 `--tb tb_live_arp_step` → PASS（确认音频链未被扰动）

- [ ] **Step 3: 提交**

```bash
git add rtl/v2_board_top.sv
git commit -m "feat(oled): drive the panel from the board top"
```

---

### Task 4: **唯一一次** P&R 构建 + 区域约束

**Files:**
- Modify: `rtl/v2_board_top.sv`（如需要，加 `(* keep *)` 或实例名以便 `INS_LOC` 定位）

- [ ] **Step 1: 先无约束构建一次？不——直接带约束构建**

用 `INS_LOC` 把 `u_oled` 与 `u_oled_rom` 钉到远离音频/UART 的一角（坐标按实际 floorplan 填；`synth.tcl` 里加 `ins_loc` 段落）。

Run: `python scripts/synth.py --run-id oled_static`
Expected: `SYNTH: PASS`、`gate: OK`；**CLS ≤ 基线+150**、**worst ≥ −3.6 ns**、`dsp 28/28`、`bsram 34→35`。

- [ ] **Step 2: 不达标时的唯一一次调整**

只允许调 `INS_LOC` 区域一次并重建（新 run id）。仍不达标 → 停下报告"放不下"，**不削任何现有功能**（spec §7）。

- [ ] **Step 3: 记录四个数并提交**

```bash
git add rtl/v2_board_top.sv impl/  # impl 若被忽略则只提交源码
git commit -m "build: the static OLED fits at <CLS> and <worst>"
```

---

### Task 5: 板上验收

- [ ] **Step 1: 烧录与身份**

`board_program.ps1 -Operation 4` → `PROGRAM PASS`；读 `0xB0` 确认 `0x5A5A0003`。

- [ ] **Step 2: 看屏**

上电后屏上应出现图。**若全黑**，按顺序排查并记录：① `oled_blk` 反相试一次；② 用 `--preview` 核对 `.mem` 是否非空；③ 把图换成"全屏点亮"版本确认是接线而不是数据。

- [ ] **Step 3: 音频未被影响**

LIVE 敲一下、PLAY 放一段，与加屏之前听感一致；`STATUS`/`voices` 正常。

- [ ] **Step 4: 文档 + 提交**

`docs/progress-2026-11-03.md`（新建）记：型号、引脚、四个资源/时序数、屏上看到什么、`blk` 极性结论；`docs/HANDOFF.md` 更新下一步。

```bash
git add docs/progress-2026-11-03.md docs/HANDOFF.md
git commit -m "docs: the static OLED is on the panel, with the pin and blk findings"
```

---

## Self-Review

**1. Spec coverage**：型号/引脚（Task 0）、图格式与 BSRAM（Task 1/2）、初始化与 SPI 时序（Task 2）、资源与时序硬线（Task 4）、板上排查顺序（Task 5）。spec §9 的五条"留给计划"全部落到任务里。

**2. Step scan**：每步一条命令 + 一个可判定结果，或一处签名/字段定义；没有"处理边界情况"这类空步。

**3. Type consistency**：端口名在 Task 0/2/3 一致（`oled_sck, oled_mosi, oled_dc, oled_cs_n, oled_res_n, oled_blk`）；`.mem` 长度 1024 在 Task 1/2/5 一致；`img_addr/img_data` 同步读 1 拍延迟在 Task 2/3 一致。

**4. Review Focus 对应**：1→Task 1 Step 1 + Task 2 断言③；2→Task 2 断言①；3→Task 2 断言④；4→Task 4；5→Task 4 的硬线与"放不下就回退"。

**5. Proportion**：计划约 150 行，实现约 200 行 RTL + 1 个 tb + 1 个主机脚本。
