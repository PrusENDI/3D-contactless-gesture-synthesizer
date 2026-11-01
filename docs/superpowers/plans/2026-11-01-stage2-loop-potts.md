# 阶段 2（LOOP 轮廓 → Potts → 播放）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一圈 32 tick 的 LOOP 在板上走完“采轮廓 → Potts 分段 → 写 shadow → 圈末发布 → PLAY 出声”，上位机只发控制命令。

**Architecture:** 新增一个 tick 驱动、与 LIVE 解耦的轮廓采集块和一个 rest 净化块；Potts DP 只换常量与数据源；提交路径把 Potts 事件直接写进 store 的 shadow lead 轨，再由真实 scheduler 的圈末边界翻 bank；scheduler 从自由扫描改成每 tick 扫一遍。

**Tech Stack:** SystemVerilog（Gowin GW5A-LV25MG121NES，80 MHz），ModelSim `vlog/vsim`（`scripts/sim_unit.py`），Python 构建/板级脚本，`host/v2_potts_reference.py` 作为逐事件金标准。

**Spec:** `docs/superpowers/specs/2026-11-01-stage2-loop-potts-design.md`

## Global Constraints

- 圈长 `LOOP_TICKS = 32`；`tick = 15/BPM 秒`（`720000/BPM` 个 48 kHz 采样）。
- 轮廓值 = `cursor_y[15:6]`，0..1023；音级 = `{30,135,286,421,557,708,858,978}`（y 区间中点）。
- 音级表与 MIDI 分开：`level(k)` 用于误差，`note(k)` = `{55,57,60,62,64,67,69,72}` 用于事件输出。
- λ 默认 **21600**，写 `0x3C[15:0]`；`EV_CAP = 9`；`HORIZON = 32`。
- 新 CSR：`0x34` 轮廓读口（写索引、读自增）、`0x38` Potts 状态（只读）、`0x3C` λ（读写）。
  **不得改动 `0xB0`**（位流身份 `0x5A5A0003`）。
- 每个任务结束：`python scripts/gate.py --compile` 0 error / 0 warning；`python scripts/sim.py` 不得新增失败。
- 事件比对前两边都按 `tick` 升序排序（RTL 是回溯顺序）。
- 源文件 LF、无 BOM；提交信息写“改了什么 + 为什么”，`git add` 列具体文件。
- 端到端测试**禁止** `force loop_boundary`（这正是现 tb 掩盖缺陷的方式）。

## Review Focus

1. **手离开 1–3 拍**：短 rest 不能让 DP 无解（净化必须迭代到稳定；Task 3 与 Task 7 各有用例）。
2. **COMMIT 后不进 PLAY**：42.5 s 后 store 丢弃提交，必须能从 `0x38` 的 `commit_timeout` 看出来（Task 1、Task 7）。
3. **圈末最后一个音**：`tick+duration==32`，没有配对 OFF，必须由 `ALL_NOTES_OFF` 收掉、不留卡音（Task 7）。
4. **`selected_track != 0`**：`0x18` 清的是选中轨，若先选过别的轨，Potts 写 track 0 会卡在 EMIT（Task 7）。
5. **半途 COMMIT**：只采到 N<32 个 tick 时，未采部分是 rest，出音到 N 为止，不能出脏音（Task 2、Task 7）。

---

### Task 1: 让 store 在 commit pending 期间仍然可读

**Files:**
- Modify: `rtl/v2_loop_event_store_dpb.sv:74`
- Test: `tb/tb_loop_publish.sv`（新建）

**Interfaces:**
- Consumes: `v2_loop_event_store_dpb`（现有端口）、`v2_loop_scheduler`（现有端口）。
- Produces: 无新端口；只改读口门控 `read_enable && !busy` → `read_enable && !copy_active`。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_loop_publish.sv
// store(op5 PREPARE_RECORD) → 写 2 个 NOTE_ON 到 track 0 slot 0/1 → op3 COMMIT_REQUEST
// → scheduler run=1，loop_tick 每 4 拍走 0..31
// 断言：commit_pending 在被观察窗口内被清、loop_boundary 恰好 1 次、
//       active_valid=1、scheduler 发出的两个事件 tick 为 0 和 16。
// 若读口被 commit_pending 断开，scheduler 永远拿不到 read_valid → boundary 不出现 → $fatal。
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_loop_publish`
Expected: FAIL（`loop_boundary never seen`）

- [ ] **Step 3: 改门控**

`rtl/v2_loop_event_store_dpb.sv:74`：`read_enable && !busy` → `read_enable && !copy_active`。
理由：复制期间读 active 会与 shadow 写冲突；`commit_pending` 期间读 active 是安全的，
而它是 scheduler 产生边界的前提。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_loop_publish`
Expected: `PASS`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_loop_event_store_dpb.sv tb/tb_loop_publish.sv
git commit -m "fix: keep the loop store readable while a commit is pending"
```

---

### Task 2: 轮廓采集块

**Files:**
- Create: `rtl/v2_loop_contour_capture.sv`
- Test: `tb/tb_loop_contour_capture.sv`（新建）
- Modify: `filelist.f`（放在 `rtl/v2_loop_scheduler.sv` 之后）

**Interfaces:**
- Produces:
  ```systemverilog
  module v2_loop_contour_capture #(parameter integer K = 32) (
    input  logic clk, rst_n, arm,
    input  logic tick_pulse, input logic [6:0] mtick,
    input  logic [15:0] y, input logic engaged,
    input  logic [4:0] rd_index, output logic [15:0] rd_data,
    output logic [K-1:0] valid_mask, output logic full
  );
  ```
  `rd_data = {6'd0, mem[rd_index]}`（16 bit、非负）。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_loop_contour_capture.sv：四个用例
// 1) arm 落在 tick=5：tick 6..31 期间 rd_data/full 都不动；到下一个 tick 0 起才写；
//    第 32 个 tick 后 full=1，rd_data[0..31] == 写入的 y>>6 序列。
// 2) engaged=0 的 tick 对应 valid_mask 位为 0。
// 3) re-arm：清空、full=0，再等一个 tick 0 重新采。
// 4) 半途：arm 后只给 10 个 tick，full=0，且 sample[10..31]==0、valid_mask[10..31]==0。
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_loop_contour_capture`
Expected: FAIL（模块未定义）

- [ ] **Step 3: 实现**

`arm` 上升沿：清 `mem`/`valid_mask`，`full<=0`，`armed<=1`，`wr<=0`，`waiting_zero<=1`。
`waiting_zero && tick_pulse && mtick[4:0]==0` → `waiting_zero<=0`。
`armed && !waiting_zero && tick_pulse` → 写 `mem[wr]=y[15:6]`、`valid_mask[wr]=engaged`、
`wr++`；`wr==K-1` 时 `full<=1`、`armed<=0`。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_loop_contour_capture`
Expected: `PASS`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_loop_contour_capture.sv tb/tb_loop_contour_capture.sv filelist.f
git commit -m "feat: tick-driven contour capture that starts at tick 0"
```

---

### Task 3: rest 净化（RTL + 参考）

**Files:**
- Create: `rtl/v2_loop_rest_purify.sv`、`tb/tb_loop_rest_purify.sv`
- Modify: `host/v2_potts_reference.py`、`host/test_v2_potts_reference.py`
- Modify: `filelist.f`

**Interfaces:**
- Produces:
  ```systemverilog
  module v2_loop_rest_purify #(parameter integer K = 32) (
    input  logic clk, rst_n, start, input logic [K-1:0] raw_valid,
    output logic [K-1:0] purified_valid, output logic busy, output logic done
  );
  ```
  Python 侧：`purify_valid(mask: int, k: int = 32) -> int`。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_loop_rest_purify.sv 与 host 测试共用下面 6 个用例（Python 侧同样断言）
// A) 全 1 → 全 1；B) 全 0 → 全 0
// C) 16 个 1、2 个 0、14 个 1 → 全 1（2 拍 rest 被吸收）
// D) 16 个 1、5 个 0、11 个 1 → rest 保留
// E) 前 2 拍是 0、后 30 拍是 1 → 保留（首个 run 允许短）
// F) 1×8、0×2、1×2、0×20 → 两个 0 run 都吸收 → 全 1
//     （这条能抓住“只对原始 mask 扫一趟”的实现）
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_loop_rest_purify` 与
`python -m unittest host.test_v2_potts_reference -v`
Expected: 都 FAIL（无 `v2_loop_rest_purify` / 无 `purify_valid`）

- [ ] **Step 3: 实现**

RTL：`start` 后进入 32 步循环，对 `pur` 寄存器就地重写（**用更新后的值继续比较**）：

```
i = 1..K-1：若 pur[i] != pur[i-1]：若 (i - run_start) < 4 且 run_start != 0 →
            pur[run_start..i-1] = pur[run_start-1]；run_start = i
循环结束再处理尾段（长度 <4 且 run_start != 0 → 吸收）
```

Python：同一算法，用列表就地重写，返回整数 mask。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_loop_rest_purify`、`python -m unittest host.test_v2_potts_reference -v`
Expected: 均 PASS

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_loop_rest_purify.sv tb/tb_loop_rest_purify.sv filelist.f host/v2_potts_reference.py host/test_v2_potts_reference.py
git commit -m "feat: absorb rests shorter than MIN_LENGTH so the Potts DP always has a path"
```

---

### Task 4: Potts 换常量与数据源

**Files:**
- Modify: `rtl/v2_potts_commit_fsm.sv`（`level()`/`note()` 两张表、`d` 0..7、`last_cell` 判据）
- Modify: `rtl/mgc3130_v2_top.sv`（contour 接采集 RAM、rest_mask 接净化输出、λ 接新寄存器）
- Modify: `host/v2_potts_reference.py`（`LEVELS`/`NOTES`/`horizon`/净化）、`host/test_v2_potts_reference.py`
- Test: `tb/tb_v2_potts_commit_fsm.sv`（改期望）、`tb/tb_v2_potts_commit.sv`（改输入）

**Interfaces:**
- Consumes: Task 2 的 `rd_data/valid_mask`、Task 3 的 `purified_valid`。
- Produces: `potts_lambda` 寄存器（`0x3C` 写、复位 21600），接 `u_potts.lambda_q16`。

- [ ] **Step 1: 改测试为失败期望**

```systemverilog
// tb_v2_potts_commit_fsm.sv：contour = [30]*8 + [978]*24，λ=0
// 期望 2 个事件、按 tick 升序后为 (t0,d8,note55) 与 (t8,d24,note72)
// tb_v2_potts_commit.sv（H128）：contour = [135]*64 + [978]*64，λ=0，期望 ≥2 个事件
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_v2_potts_commit_fsm`
Expected: FAIL（现实现按 5 个 note 级、且 contour 被当成音高号，事件音高不是 55/72）

- [ ] **Step 3: 实现**

`level(k)`/`note(k)` 两张 `case` 表（值见 Global Constraints 与 spec §5.1）；
`function` 里把 `note(d)` 替换为 `level(d)` 参与误差、`note(d)` 只用于 `temp_event[71:64]`；
`d` 循环到 7，`last_cell` 判据 `d==7`；λ 端口接 `potts_lambda`。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_v2_potts_commit_fsm`、`python scripts/sim_unit.py --tb tb_v2_potts_commit`
Expected: 均 PASS

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_potts_commit_fsm.sv rtl/mgc3130_v2_top.sv host/v2_potts_reference.py host/test_v2_potts_reference.py tb/tb_v2_potts_commit_fsm.sv tb/tb_v2_potts_commit.sv
git commit -m "feat: Potts fits the y-space contour against eight pentatonic levels"
```

---

### Task 5: 提交写口（commit writer）

**Files:**
- Create: `rtl/v2_loop_commit_writer.sv`、`tb/tb_loop_commit_writer.sv`
- Modify: `rtl/mgc3130_v2_top.sv`（实例化、写口 owner mux、摘掉声部引擎那条 Potts 支路）
- Modify: `rtl/v2_contract_pkg.sv`（`0x34/0x38/0x3C` 地址、掩码、读路由）
- Modify: `filelist.f`

**Interfaces:**
- Produces:
  ```systemverilog
  module v2_loop_commit_writer (
    input  logic clk, rst_n, kick,            // kick = 0x28 写脉冲
    output logic potts_start,                 // 一拍
    input  logic potts_busy, potts_done,      // 来自 DP
    input  logic potts_event_valid, output logic potts_event_ready,
    input  logic [95:0] potts_event_data,
    input  logic store_write_ready,           // owner 期间直连 store
    output logic store_write_valid, output logic [4:0] store_write_slot,
    output logic commit_request,              // 送 store 的 op3
    output logic run, output logic done, output logic [5:0] count
  );
  ```
  `run` 期间 `store_write_track` 固定 0（由 top 接常量）。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_loop_commit_writer.sv
// 1) kick 后 potts_start 一拍，run=1，不发 commit_request
// 2) 送 3 个事件（store_write_ready 每拍 1），断言 slot 依次 0/1/2、commit_request 只在
//    potts_done 之后出现一次、done=1、count=3
// 3) store_write_ready 先低 5 拍：事件保持、potts_event_ready=0、slot 不前进
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_loop_commit_writer`
Expected: FAIL（模块未定义）

- [ ] **Step 3: 实现**

`kick` 置 `run<=1`、`slot<=0`；`run && !busy_seen` 发 `potts_start` 一拍；
`run` 期间 `store_write_valid=potts_event_valid`、`store_write_slot=slot`、
`potts_event_ready=store_write_ready`，每成功一拍 `slot++`；
`potts_done && !event_valid` 后置 `commit_request` 一拍、`run<=0`、`done<=1`。
top 里：写口 mux `run ? writer_* : recorder_*`；`voice_event_valid/data` 三元里删掉 Potts 项；
`potts_event_ready` 只由 writer 驱动。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_loop_commit_writer`、`python scripts/gate.py --compile`
Expected: PASS / `0 error(s), 0 warning(s)`

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_loop_commit_writer.sv tb/tb_loop_commit_writer.sv rtl/mgc3130_v2_top.sv rtl/v2_contract_pkg.sv filelist.f
git commit -m "feat: commit writes the Potts events straight into the shadow lead track"
```

---

### Task 6: scheduler 每 tick 扫一遍 + LOOP_TICKS

**Files:**
- Modify: `rtl/v2_loop_scheduler.sv`（扫描门控、`LOOP_TICKS` 参数、边界条件）
- Modify: `rtl/mgc3130_v2_top.sv`（`loop_tick` 接 `tick_now[4:0]`、传 `LOOP_TICKS=32`、`tick_pulse` 接入）
- Test: `tb/tb_loop_scheduler_tick.sv`（新建）

**Interfaces:**
- Consumes: store 读口（Task 1）。
- Produces: `v2_loop_scheduler #(.LOOP_TICKS(32), ...)`，新增输入 `tick_start`。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb/tb_loop_scheduler_tick.sv
// store 桩里放 2 个事件（tick 0 / tick 16）；tick_start 每 200 拍脉冲一次，loop_tick 随之递增
// 断言：一个 tick 窗口内同一事件只发一次（窗口 200 拍）；loop_tick==31 的窗口末 boundary 恰好 1 次；
//       32 个窗口内事件总数 == 2
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_loop_scheduler_tick`
Expected: FAIL（现实现自由扫描：一个窗口内同一事件被发多次）

- [ ] **Step 3: 实现**

`tick_start` 置 `scan_active<=1`、`slot<=0`、`track<=0`、`pass<=0`；
只有 `scan_active` 时 `read_enable` 才有效；扫完 pass2 的最后一槽 → `scan_active<=0`，
若 `loop_tick==LOOP_TICKS-1` 则走现有 `boundary_stage` 流程。
所有 tick 比较把 `loop_tick` 零扩展到 7 bit，`end_tick` 保持 7 bit（32 永不匹配）。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_loop_scheduler_tick`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add rtl/v2_loop_scheduler.sv rtl/mgc3130_v2_top.sv tb/tb_loop_scheduler_tick.sv
git commit -m "feat: scan the loop once per musical tick instead of free-running"
```

---

### Task 7: 端到端 top 测试（替换会撒谎的旧 tb）

**Files:**
- Create: `tb/tb_stage2_loop_e2e.sv`
- Delete: `tb/tb_mgc3130_v2_top_potts.sv`（它靠 `force dut.loop_boundary` 才通过）
- Modify: `scripts/test_potts_plane.py`（把 `tb_mgc3130_v2_top_potts` 换成 `tb_stage2_loop_e2e`）

**Interfaces:**
- Consumes: Task 1–6 的全部产物。

- [ ] **Step 1: 写端到端测试**

```systemverilog
// tb/tb_stage2_loop_e2e.sv（不得出现 force loop_boundary）
// 1) 0x0C=1（先选到别的轨）→ 0x0C=0 → 0x18=1 → 断言输入进 RECORD
// 2) 给 32 个 tick、每 tick 4 个 cursor 帧（y 走 30→978 的斜坡，engaged=1 除 tick 12..13 为 0）
// 3) 轮询 0x38：full=1
// 4) 0x28=1 → 轮询 0x38 done=1，且 overflow=0、commit_timeout=0
// 5) 0x04=4 → 推进 3 圈 tick：断言 loop_boundary 出现、active_bank 切换、active_voice_count 曾 >0
// 6) 断言 0x34 连读 32 次拿到的轮廓 == 注入的 y>>6
// 7) 断言圈末有 ALL_NOTES_OFF（没有卡音）：全部 tick 走完后 active_voice_count==0
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_stage2_loop_e2e`
Expected: FAIL（0x34/0x38 未实现或提交路径未接）

- [ ] **Step 3: 修到通过**

只允许改 top 的接线与 CSR 解码；若发现 Task 1–6 的设计缺陷，回到对应任务加用例再修。

- [ ] **Step 4: 跑全部证据**

Run: `python scripts/test_potts_plane.py`
Expected: `POTTS PLANE: PASS`（含新的 e2e）

- [ ] **Step 5: 提交**

```bash
git add tb/tb_stage2_loop_e2e.sv scripts/test_potts_plane.py
git rm tb/tb_mgc3130_v2_top_potts.sv
git commit -m "test: end-to-end stage-2 loop without forcing the loop boundary"
```

---

### Task 8: 构建与上板

**Files:**
- Create: `scripts/board_stage2_loop.ps1`
- Modify: `docs/progress-2026-11-01.md`

- [ ] **Step 1: 构建**

Run: `python scripts/synth.py --run-id stage2_loop`
Expected: `SYNTH: PASS` + `bitstream_sha256`；记录时序 slack（`impl/stage2_loop/impl/pnr/v2_board_top.rpt.txt`）。

- [ ] **Step 2: 写脚本并上板**

`board_stage2_loop.ps1`：`0x0C=0 → 0x18=1 → 等 full → 0x28=1 → 等 done → MODE=4`，
每步带序列号校验；结束回 IDLE。

Run: `powershell -File scripts\board_stage2_loop.ps1 -Port COM4`
Expected: `full=1`、`done=1`、`commit_timeout=0`、PLAY 有声音。

- [ ] **Step 3: 记录证据**

把 `bitstream_sha256`、`0x38` 读数、连续两圈的 `0xD4` 事件增量写进 `docs/progress-2026-11-01.md`。

- [ ] **Step 4: 提交**

```bash
git add scripts/board_stage2_loop.ps1 docs/progress-2026-11-01.md
git commit -m "feat: stage-2 loop accepted on board (32-tick contour plays through PLAY)"
```

---

## Self-Review

**1. Spec coverage**

| Spec 章节 | 任务 |
| --- | --- |
| §4 采集块（等 tick 0、顺序 32 点） | Task 2 |
| §5.1 双表、λ `0x3C`、HORIZON 32 | Task 4 |
| §5.2 rest 净化 | Task 3 |
| §5.3 末段与比对顺序 | Task 4（参考排序）、Task 7（ALL_NOTES_OFF） |
| §6 提交写口、摘掉声部引擎支路、读口门控、选 lead 轨 | Task 1、Task 5、Task 7 |
| §7 每 tick 扫描、`LOOP_TICKS`、`loop_tick`、圈末顺序 | Task 6 |
| §8 CSR `0x34/0x38/0x3C` | Task 5 |
| §9 上位机协议 | Task 7、Task 8 |
| §10 验收（含“禁止 force boundary”） | Task 1、Task 7 |
| §11 风险 | Task 8 记录 slack |

**2. Step 扫描**：每步只做一件事（写测试 / 跑红 / 实现 / 跑绿 / 提交），代码块只出现在测试与签名处。

**3. 类型一致性**：`rd_data`(16) / `valid_mask`(K) / `purified_valid`(K) / `store_write_slot`(5) /
`potts_lambda`(16) 在任务间一致；`LOOP_TICKS` 在 Task 6 定义、Task 7 使用。

**4. Review Focus 对应**：1→Task 3/7；2→Task 1/7；3→Task 7；4→Task 7 步骤 1 的第一条；5→Task 2/7。

**5. 比例**：计划约 1.4 倍 spec 长度，主要为测试与接口定义，没有复制实现体。
