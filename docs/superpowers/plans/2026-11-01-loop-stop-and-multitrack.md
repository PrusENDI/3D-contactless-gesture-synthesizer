# LOOP 停止播放与多轨提交 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 loop 能干净地停下来（不留挂音），并能把六轨各录一遍、同时播放。

**Architecture:** 停止不靠复位声部引擎，而是在离开 PLAY 时向声部引擎注入一次 `ALL_NOTES_OFF`，让它走正常的释放尾音（约 1.3 ms）后静音；多轨复用现有 store 的六轨与 scheduler 的六轨扫描，只把提交路径里写死的 track 0 换成“提交时锁存的 selected_track”。

**Tech Stack:** SystemVerilog（Gowin GW5A，80 MHz）、ModelSim（`scripts/sim_unit.py`）、PowerShell 板级脚本、`scripts/synth.py`。

**Spec:** `docs/superpowers/specs/2026-11-01-stage2-loop-potts-design.md`（阶段 2 主体）；本计划新增的决定写在下面的 Global Constraints 里。

## Global Constraints

- 音符释放靠 `NOTE_OFF`/`ALL_NOTES_OFF` → 声部进入 releasing → 包络每采样减 1024，约 64 采样（1.3 ms）后声部释放。
- 停止语义：离开 PLAY（`MODE=IDLE` 或 `0x14 STOP`）必须**先发一次 `ALL_NOTES_OFF`**，再让调度器停下；不要用复位声部引擎的办法硬切（会有咔哒，且 LIVE↔PLAY 切换会断尾音）。
- 多轨：store 六轨 × 32 槽；scheduler 每 tick 扫六轨；一次提交只写一轨。
- 提交用的轨号必须在 `0x28` 那一刻**锁存**（`commit_track`），此后宿主改 `0x0C` 不影响正在进行的提交。
- 每轨的事件上限：`EV_CAP = HORIZON/MIN_LENGTH + 1 = 9`（H32）。
- 每个任务结束：`python scripts/sim_unit.py --tb <tb>` 绿、`python scripts/test_potts_plane.py` 不新增失败。
- 源文件 LF、无 BOM；提交信息写“改了什么 + 为什么”，`git add` 列具体文件。

## Review Focus

1. **停止时正在响的音**：`STOP` 落在音符中间，必须有 `ALL_NOTES_OFF` 到达声部引擎，`active_voice_count` 在若干个采样内回到 0（Task 1）。
2. **STOP 与提交并发**：提交进行中收到 STOP，DP 必须中止、不得留下 `commit_pending` 或半写轨道（Task 1）。
3. **换轨不串轨**：提交过程中宿主写 `0x0C` 不能改变这次提交的目标轨（Task 3）。
4. **多轨同时发声**：两轨播放时最多 2 个同时音符，`voices` 观测到 2，且不触发抢声部（Task 3）。
5. **LIVE↔PLAY 切换**：切回去时上一模式的尾音必须被收掉，不能拖到新模式里（Task 1）。

---

### Task 1: 离开 PLAY 时发 ALL_NOTES_OFF

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`
- Test: `tb/tb_stage2_loop_e2e.sv`

**Interfaces:**
- Consumes: `loop_event_*`（scheduler 输出）、`mode_play`。
- Produces: 声部引擎在离开 PLAY 时收到一个 `EV_ALL_NOTES_OFF` 事件（type `4'd5`），之后自行释放。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb_stage2_loop_e2e.sv，在已有 PLAY 断言之后追加：
// 1) 在某个音正在响时（dut.active_voice_count > 0）写 0x14 STOP；
// 2) 断言接下来的 200 个采样内出现一次 type=5 的 loop 事件；
// 3) 断言 dut.active_voice_count 回到 0。
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_stage2_loop_e2e`
Expected: FAIL（`no ALL_NOTES_OFF after STOP`）

- [ ] **Step 3: 实现**

`mode_play` 下降沿置一个 `leave_play_oneshot`；在 `loop_event_valid` 的 mux 之外，用同一个 `voice_event_*` 入口优先注入
`{type=5, track=0, tick=loop_tick, note=0}` 一拍，等 `voice_event_ready` 后清除。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_stage2_loop_e2e`
Expected: PASS，且断言 3 看到 `active_voice_count==0`

- [ ] **Step 5: 提交**

```bash
git add rtl/mgc3130_v2_top.sv tb/tb_stage2_loop_e2e.sv
git commit -m "fix: send ALL_NOTES_OFF when the loop leaves PLAY"
```

---

### Task 2: 板级脚本收尾停播并校验静音

**Files:**
- Modify: `scripts/board_stage2_loop.ps1`

- [ ] **Step 1: 改脚本**

播放观测结束后：写 `0x14`（STOP）→ 等 300 ms → 读 page 2，若 `voices != 0` 打印 `FAIL: note still sounding after STOP` 并返回非零；否则打印 `STOPPED cleanly` 再退出。

- [ ] **Step 2: 在板上验证**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_stage2_loop.ps1 -Port COM4`
Expected: 结束时 `STOPPED cleanly`，耳朵确认静音。

- [ ] **Step 3: 提交**

```bash
git add scripts/board_stage2_loop.ps1
git commit -m "feat: stop the loop and verify silence at the end of the board run"
```

---

### Task 3: 多轨提交

**Files:**
- Modify: `rtl/mgc3130_v2_top.sv`
- Modify: `tb/tb_stage2_loop_e2e.sv`（新增两轨用例）
- Modify: `scripts/board_stage2_loop.ps1`（`-Tracks` 参数，默认 1）

**Interfaces:**
- Produces:
  ```systemverilog
  logic [2:0] commit_track;   // 0x28 那一刻锁存 selected_track
  ```
  writer 的 `write_track`、提交前的 clear 都用 `commit_track`；`commit_track` 在提交结束前不变。

- [ ] **Step 1: 写失败测试**

```systemverilog
// tb_stage2_loop_e2e.sv 新增用例（复用现有注入方式）：
// 1) 0x0C=0 → 0x18 → 采 32 tick（斜坡 A）→ 0x28 → 等 done；
// 2) 0x0C=1 → 0x18 → 采 32 tick（恒定高音）→ 0x28 → 等 done；
// 3) MODE=PLAY，推进两圈后断言 voices 曾等于 2，
//    且 track0 的第一条事件音高与 track1 的不同（用 dut.u_store 的读口或事件流观察）。
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python scripts/sim_unit.py --tb tb_stage2_loop_e2e`
Expected: FAIL（第二次提交写到了 track 0，把第一条覆盖掉；voices 只到 1）

- [ ] **Step 3: 实现**

`0x28` 的 kick 处锁存 `commit_track <= selected_track`；clear 用 `commit_track`；writer 的 `store_write_track`
（现由 top 常量 `3'd0` 驱动）改为 `commit_track`；`commit_track` 在 writer `done` 后才允许再变。

- [ ] **Step 4: 跑测试确认通过**

Run: `python scripts/sim_unit.py --tb tb_stage2_loop_e2e`
Expected: PASS（voices 见到 2，两轨事件并存）

- [ ] **Step 5: 提交**

```bash
git add rtl/mgc3130_v2_top.sv tb/tb_stage2_loop_e2e.sv scripts/board_stage2_loop.ps1
git commit -m "feat: commit to the selected track so the loop can hold six parts"
```

---

### Task 4: 回归、构建与板级验收

**Files:**
- Modify: `docs/progress-2026-11-01.md`

- [ ] **Step 1: 回归**

Run: `python scripts/test_potts_plane.py`、`python scripts/sim.py`
Expected: `POTTS PLANE: PASS`；`SIM: PASS`（失败集不超出基线）

- [ ] **Step 2: 构建并烧录**

Run: `python scripts/synth.py --run-id loop_stop_multitrack`
Run: `powershell -File "C:/weizijian/documents/gowin fpga/mgc3130_uart/.worktrees/v2-integration/scripts/board_program.ps1" -FsFile <impl/.../v2_board_top.fs> -Operation 4`
Expected: `SYNTH: PASS` + `PROGRAM PASS`；记录 `bitstream_sha256`

- [ ] **Step 3: 两轨板测**

Run: `powershell -File scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 2`
Expected: 两次 `commit done`，`play voices` 见到 ≥2，`steals=0`，结束 `STOPPED cleanly`

- [ ] **Step 4: 记录并提交**

把 sha256、两次 contour 回读、`voices` 峰值、STOP 后 voices=0 写进进度文档。

```bash
git add docs/progress-2026-11-01.md
git commit -m "docs: loop stop and two-track playback accepted on board"
```

---

## Self-Review

**1. Spec coverage**

| 需求 | 任务 |
| --- | --- |
| 停止不留挂音 | Task 1、Task 2 |
| 多轨各录一遍并同时播放 | Task 3、Task 4 |
| 换轨不串轨 | Task 3（锁存 `commit_track`） |
| 回归与板上证据 | Task 4 |

**2. Step 扫描**：每步只做一件事（写测试 / 跑红 / 实现 / 跑绿 / 提交）。

**3. 类型一致性**：`commit_track[2:0]` 在 Task 3 定义并被 writer 与 clear 共用；`ALL_NOTES_OFF` 事件类型沿用 `4'd5`。

**4. Review Focus 对应**：1→Task 1；2→Task 1 的 STOP 并发用例（现有 abort 已测，需在 e2e 里加一次提交中断）；3→Task 3；4→Task 3；5→Task 1。

**5. 比例**：计划只写接口、测试与断言，不复制实现体。

## 后续（不在本计划内）

阶段 1.5（波表样本源 + LIVE/PLAY 统一）已有自己的计划：`docs/superpowers/plans/2026-11-01-wavetable-voice-bypass.md`。
本计划完成后，多轨播放会第一次让 32 声部引擎同时承担 2–6 个音，正好是 1.5 之前最好的一次压力验证。
