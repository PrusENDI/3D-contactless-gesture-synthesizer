# 阶段 2：LOOP 轮廓 → Potts → 播放（32 tick）设计

日期：2026-11-01
状态：草稿 v2（已按独立评审的 8 条意见修正）

## 1. 目标

一圈 32 tick 的完整闭环，全部在 FPGA 上完成，上位机只做控制：

```
上位机: 0x0C=0 → 0x18 PREPARE+arm → 轮询 full → 0x28 COMMIT → 轮询 done → MODE=PLAY(4)
FPGA:   [采集 32 tick 轮廓] → [Potts 分段] → [事件写进 shadow 的 lead 轨]
        → [COMMIT_REQUEST] → [圈末翻 bank] → [每 tick 扫描 → 声部引擎 → FX → I2S]
上位机（可选）: 用 0x34 读回 32 点轮廓，在 loop 视图里绘制
```

非目标：128 tick 一圈、每声部独立 position、真实 ADSR、多轨录音语义、
撤销/多 take、1.5 的 LIVE 与 PLAY 共用声部引擎收尾（见 §11）。

## 2. 已定决策

| # | 项 | 决定 | 理由 |
| --- | --- | --- | --- |
| D1 | 圈长 | **32 tick**（120 BPM = 4 s = 2 小节） | 只有 `HORIZON<=63` 走 DPB，32 是唯一不需换存储的规模 |
| D2 | 轮廓来源 | 板上 tick 驱动采样，**等 tick 0 起步、顺序 32 点** | 与 LIVE 解耦；下标 == loop_tick，无轮转 |
| D3 | 轮廓值 | `cursor_y[15:6]`（10 bit，0..1023） | 保留手的高度信息；≈60 LSB/半音，λ 落进 16 bit |
| D4 | 音级 | **8 个**，各自 y 区间中点 `>>6`：`{30,135,286,421,557,707,858,978}` | 与 LIVE `map_note` 字母表一致；区间不等宽（1927–4819 counts/半音），故取中点 |
| D5 | λ | **新地址 `0x3C`**，默认 21600 | 不能用 `THRESHOLDS[31:16]`：bit23 是 arp 标志，且契约要求 `data[15:0] < data[31:16]`（pkg:799）。21600 = PC 的 λ=6 × 60²（1 半音≈60 LSB）；换算刻度见 §5.4 |
| D6 | arm | **绑定 `0x18 PREPARE_RECORD`** 写 | 宿主本来就要写这一条；不额外占地址 |
| D7 | 力度 | 固定 100 | 与参考逐位可比 |
| D8 | 提交 | `0x28` 改为“计算并发布”：`commit_run` → DP → 事件写 shadow → `COMMIT_REQUEST` | 现有实现是 op3 与 potts_start 并行，会先把**录音**发布出去 |
| D9 | rest | 每 tick 一个 valid 位；进 DP 前把 `<4` 的 run 并进前一段 | 直接交给 DP 会让短 rest 造成**无解**（见 §5.2） |
| D10 | 末段时值 | DP 不 clamp；`end_tick` 保持 7 bit，32 永不匹配 | 每个提交的最后一个音都是 `tick+duration==32`；由圈末 `ALL_NOTES_OFF` 收掉 |
| D11 | 读口门控 | store 的 `read_enable && !busy` 改成 `&& !copy_active` | `busy=copy_active||commit_pending`（store:48/74）；`commit_pending` 一置就断开读口 → scheduler 冻结 → 边界永不到 |
| D12 | Potts 输出 | 从声部引擎的三元选择里摘掉，直接接 store 写口 | 现在 `voice_event_valid` 在有 Potts 事件时会选中它（top:457-460），声部引擎当场发声，store 拿不到 |

## 3. 数据流与所有权

| 资源 | 所有者 |
| --- | --- |
| `contour_ram[0:31]` + `valid[0:31]` | 新模块 `v2_loop_contour_capture` 写；DP 组合读；`0x34` 读回 |
| `potts_contour[0:127]`（现有） | 删除，由采集 RAM 映射到 `[0:31]`，其余位 0 |
| store 写口 | `commit_run` 时归 Potts 事件流，否则归 recorder |
| store 读口 | scheduler（PLAY） |
| 声部引擎 | 只接 LIVE / PLAY 事件（Potts 事件不再进这里） |

## 4. 新模块：`v2_loop_contour_capture`

```systemverilog
module v2_loop_contour_capture #(parameter integer K = 32) (
  input  logic clk, rst_n,
  input  logic arm,                 // 0x18 写脉冲
  input  logic tick_pulse,
  input  logic [6:0] mtick,
  input  logic [15:0] y,            // cursor_y
  input  logic engaged,             // cursor_engaged
  input  logic [4:0] rd_index,
  output logic [15:0] rd_data,
  output logic full
);
```

语义：

- `arm`：清空样本与 valid，`full<=0`，`armed<=1`，`wr<=0`，`waiting_zero<=1`。
- `waiting_zero && tick_pulse && mtick[4:0]==0`：`waiting_zero<=0`（从 tick 0 起步）。
- `armed && !waiting_zero && tick_pulse`：`mem[wr] <= y[15:6]`、`valid[wr] <= engaged`、
  `wr<=wr+1`；`wr==K-1` 时 `full<=1`、`armed<=0`。
- 输出：`contour[t] = {6'd0, mem[t]}`、`rest_mask[t] = ~valid[t]`。

为什么必须等 tick 0（评审 #4）：若按 `mtick[4:0]` 当写地址，arm 落在 tick p 时只能采到 p..31，
`full` 在 31 就起，0..p-1 是 rest —— 平均半圈没音。顺序计数器 + 等 tick 0 才让 32 点完整，
且轮廓下标天然等于 loop_tick。

已知限制（刻意接受）：

- 一圈 32 点 = **8 Hz** 采样；轮廓是 32 点折线（PC 侧每圈 128 点，同类粒度）。
- arm 后最多要等 1 个 tick（250 ms @60 BPM 的 4 倍，见 §7 的 tick 定义）才开始采。
- 半途 COMMIT 不会出脏数据：未采到的 tick valid=0，是 rest。

## 5. Potts 改动

### 5.1 表与接线

1. 音级拆两张表：`level(k)`（y>>6 中点，只用于误差）与 `note(k)`（MIDI，只用于事件输出）。
   现在 `note(k)` 身兼两用，换单位后事件音高会变成 30..978。`d` 0..7，收尾判据 `d==7`。

   | k | note | y 区间 | midpoint | level |
   | --- | --- | --- | --- | --- |
   | 0 | 55 | 0–3855 | 1927 | 30 |
   | 1 | 57 | 3855–13493 | 8674 | 135 |
   | 2 | 60 | 13493–23130 | 18311 | 286 |
   | 3 | 62 | 23130–30840 | 26985 | 421 |
   | 4 | 64 | 30840–40478 | 35659 | 557 |
   | 5 | 67 | 40478–50115 | 45296 | 707 |
   | 6 | 69 | 50115–59753 | 54934 | 858 |
   | 7 | 72 | 59753–65535 | 62644 | 978 |

2. 轮廓：接采集 RAM；`rest_mask[0:31] = ~valid`，`[32:127]` 恒 1。
3. λ：新寄存器 `potts_lambda`（`0x3C`，复位 21600）。
4. `HORIZON=32`、`EV_CAP=9`（最多 8 段）不变。
5. DP 本体（枚举顺序、平局规则、饱和、回溯）不动。

### 5.2 rest 净化（评审 #5，必须做）

DP 的规则是“连续全覆盖 + 除 `s==0` 外每段 ≥ `MIN_LENGTH` + 一段不混 rest/data”。
手离开 1–3 拍会产生一个 <4 的 rest run → 没有任何合法分段能覆盖到 `dp[32]` →
`dp[32]` 保持 INF → 回溯从 `bp_s[32]`（GSR 后为 0）直接结束 → 对外表现为
`backtrace_valid=1、overflow=0、done=1`，发布出去是一条满长假音或空轨，**无法与正常结果区分**。

净化规则（进 DP 前，对 32 bit valid 做一次）：

```
从左到右扫描 run（连续相同的 valid）；
除第一个 run 外，任何长度 < 4 的 run 并入前一个 run；
第一个 run 允许短（DP 本身允许 s==0 的短首段）。
```

净化后所有段 ≥4（首段除外），DP 必定有解，`dp[32]` 不再可能是 INF。
实现：32 拍的预扫描（最多 32 个周期，在 COMMIT 后、DP 的 INIT 之前跑），或组合逻辑三趟。
Python 参考里同样实现，保证逐位一致。

### 5.3 末段与比对顺序（评审 #6）
- 回溯永远从 `e=HORIZON=32` 开始，所以**每次提交的最后一个音都是 `tick+duration==32`**。
- 不改 DP：`end_tick` 保持 7 bit，`32` 永远不会等于 `loop_tick`(0..31)，因此该音没有配对的 OFF；
  由圈末的 `ALL_NOTES_OFF`（scheduler 在 boundary 前发）收掉。这一条写进验收并加 tb。
- RTL 按**回溯顺序**发事件（先最后一段），参考 `solve()` 按时间顺序返回。
  逐位比对必须先按 tick 排序，规定：**比对前两边都按 `tick` 升序排列**。

### 5.4 λ 的刻度与默认值

`21600 = 6 × 60²`：6 是 PC `synthwave_loop.py` 的默认 λ（半音²·tick），60 是 `y>>6` 尺度下
每半音的平均 LSB 数（1024 级 / 17 半音 = 60.2）。

“一次 1 半音的偏差要持续几拍才值得换音”是 `t = λ / 3600`：

| λ | 持续时长 | 32 拍一圈的音符数 |
| --- | --- | --- |
| 14400 | 4 拍（被 `MIN_LENGTH=4` 卡住） | 8（上限） |
| **21600（默认）** | 6 拍（0.75 s @120 BPM） | 约 5 |
| 36000 | 10 拍 | 约 3 |
| 57600 | 16 拍 | 2 |
| 65535（16 bit 上限） | 18 拍 | 2 |

已知偏差（刻意接受）：`map_note` 的每半音宽度是 1927–4819 counts（`y>>6` 后 30–75 LSB），
60 只是平均值，所以 λ 的“半音”含义会随手的高度漂移最多 2.5 倍。若听感上出现
“低音区太密、高音区太疏”，解法是加一块 1024×8 的 `y>>6 → 半音` 查表（1 块 BSRAM）
把尺度线性化，本阶段不做。

## 6. 提交与写 shadow

```
写 0x18 → PREPARE_RECORD（复制 active→shadow、清 lead count）+ 上升沿 arm 采集
写 0x28 → commit_run<=1
commit_run && !potts_busy && !done_seen → potts_start 一拍
commit_run → potts_event_valid/ready ⇄ store 写口（track=0，slot=slot_cnt）
potts_done → 全部事件已写入 → 发 COMMIT_REQUEST（loop_ctrl op3）→ commit_run<=0
```

要点（含评审 #1/#7/#8）：

1. **写口 owner**：`commit_run ? potts_event_* : recorder_*`；`write_track` 固定 0，
   `write_slot = slot_cnt`（每写成功 +1）。
2. **必须先选 lead 轨**：`0x18` 用的是 `selected_track`（top:1050）。若之前选过别的轨，
   Potts 写 track 0 时 `write_slot` 与 `counts[shadow][0]` 不一致 → `write_ready` 不置起 →
   卡在 EMIT、`done` 永不到（连 commit 超时都不触发）。协议第一步固定写 `0x0C=0`。
3. **把 Potts 从声部引擎的三元选择里摘掉**（top:457-460），`potts_event_ready` 改由
   store 的 `write_ready` 驱动。否则 COMMIT 期间事件被声部引擎当场吃掉。
4. **读口门控**：store 的 `read_enable && !busy` 改为 `read_enable && !copy_active`
   （store:74）。否则 `commit_pending` 一起就断读口，scheduler 停摆、边界永不到、
   42.5 s 后超时丢弃（`3.4e9` @ 80 MHz；时钟由 PLL 16/10 从 50 MHz 得到，
   `SYSTEM_RATE_HZ=80e6`）。
5. **发布只发生在 PLAY 里**（scheduler 只在 `mode_play` 运行），COMMIT 后必须进 PLAY。
6. `commit_timeout` 会丢弃这次提交；`0x38` 能读到。

## 7. 播放

1. `LOOP_TICKS = 32` 参数化；`loop_tick` 改接 `tick_now[4:0]`（现在接 `sample_index[6:0]`）。
   事件字段仍是 7 bit `[87:80]`：`loop_tick` 零扩展到 7 bit 再比，`end_tick` 保持 7 bit，
   这样 `32` 永不匹配（配合 §5.3）。
2. scheduler 改为**每 tick 扫一遍**：`tick_pulse` 置 `scan_active`，扫完 6 轨 × 32 槽 × 3 遍清零；
   不再自由跑，否则同一事件在一个 tick 内被重复命中。
3. `loop_boundary` 在 `loop_tick==5'd31` 且该 tick 扫描结束时发一次。
4. 圈末顺序：`ALL_NOTES_OFF` → `BOUNDARY`（现有 boundary_stage 逻辑不变）。
5. 音频路径不变：声部引擎 → `v2_fx_lite` → `>>>2` → I2S。

## 8. CSR

**地址空间已满**（`0x00–0xFC` 的 4 对齐地址被 legacy/patch/wt/tlm/test/diag 全部占满），
且 `0xB0` 是位流身份寄存器（读 `0x5A5A0003`，板测脚本与 DEBUG-AND-FLASH 都依赖它）。
所以不复用 `0xB*`，改用三个**在 V2 里从未实现**（读恒 0）的 legacy 地址：

| 地址 | 名称 | 读 | 写 |
| --- | --- | --- | --- |
| 0x34 | `CONTOUR_DATA` | `{22'd0, contour[rd_ptr]}`，读一次 `rd_ptr+1` | `rd_ptr`（低 5 位） |
| 0x38 | `POTTS_STATUS` | `{27'd0, full, commit_timeout, overflow, busy, done}` | 只读 |
| 0x3C | `POTTS_LAMBDA` | `{16'd0, potts_lambda}` | λ（低 16 位），复位 21600 |

- 0x34/0x38/0x3C 在 top 的读解码里没有分支（落到 `default: 0`），也没有板级脚本读它们。
- `THRESHOLDS(0x30)` 语义不动（`[7:0]` 测试音、`[23]` arp、`[15:0] < [31:16]` 校验）。

## 9. 上位机协议

```
1. 0x0C = 0             选 lead 轨（0x18 清的是 selected_track）
2. 0x18 = 1            PREPARE_RECORD + arm 轮廓采集（等下一个 tick 0 起采 32 拍）
3. 0x3C = λ            可选，默认 21600
4. 轮询 0x38 的 full=1（最多 33 tick：@60 BPM 8.25 s，@240 BPM 2.06 s）
5. 0x28 = 1            COMMIT：净化 rest → DP → 写 shadow → COMMIT_REQUEST
6. 轮询 0x38 的 done=1（H32 约 0.57 ms）
7. 0x04 = 4            MODE=PLAY（**4 是 PLAY**，5 是 ERROR）
8. （可选）0x34 写 0 之后连读 32 次拿轮廓，绘制
```

## 10. 验收

| 层 | 判据 |
| --- | --- |
| 采集块 | arm 后等 tick 0 才起采；32 拍后 `full=1`；valid 随 `engaged`；re-arm 清零；半途 COMMIT 的后半圈是 rest |
| rest 净化 | **含 2 拍 rest** 的轮廓能正常出音（净化前无解、净化后有解，测试要能区分） |
| Potts | `HORIZON=32`、8 音级、λ=0 的精确事件流；事件按 tick 排序后与参考比对 |
| 末段 | 最后一个音 `tick+duration==32`，由圈末 `ALL_NOTES_OFF` 收掉，不出现卡音 |
| 提交写口 | `0x28` → DP → n 个事件写进 shadow lead（slot 0..n-1）→ `COMMIT_REQUEST`；不写 active |
| 发布 | **边界必须由真实 scheduler 产生，tb 禁止 `force loop_boundary`**（现 tb 就是靠 force 才绿的） |
| 调度 | 每 tick 只扫一遍；同一事件不重复发；boundary 每圈一次 |
| 回归 | `python scripts/sim.py` PASS，失败集不超出 `sim_baseline.json` |
| 参考 | `host.test_v2_potts_reference` 改 `LEVELS/NOTES/horizon` + rest 净化后仍通过（含新增 rest 用例） |
| 板上 | PLAY 有声音；连续两圈事件集合一致；记录 `bitstream_sha256` |

## 11. 风险与依赖

1. **时序**：第一个构建看报告再定。候选是 SEGMENT 的 `(contour-note)²` 乘加与
   CELL_COMMIT 的 cost/sat/compare → `wr_cost_q`；旧报告里 Potts 曾是全设计最差路径，
   但那是 DPB 改动之前的形态，不要预设拆哪条。
2. **发布依赖 PLAY**，且 42.5 s 超时会丢弃提交。
3. **1.5 未收尾**：LIVE 走单声部波表、PLAY 走 32 声部引擎；本设计不做统一。
4. **BPM 影响时长**：同样 32 tick，宿主 60–240 BPM 下是 8.25–2.06 s（`tick = 15/BPM` 秒）；
   LIVE 自动 tempo 30–59 下是 16–8.1 s。
5. **`gate.py` 现在是红的**（1.5 两个模块未实例化），本阶段以 tb + `sim.py` 为判据。

## 12. 实施顺序（给计划用）

1. store 读口门控 + 发布 tb（先修 #1，否则后面所有端到端测试都是假的）
2. 采集块（等 tick 0、顺序 32 点）+ tb
3. rest 净化（RTL + 参考）+ tb（含 2 拍 rest 用例）
4. Potts：8 音级双表、接采集 RAM、λ=0x3C + tb 更新
5. 提交写口 owner、slot 计数、`0x28` 语义、摘掉声部引擎那条 Potts 支路 + tb
6. scheduler 每 tick 扫描 + `LOOP_TICKS=32` + `loop_tick` + tb
7. 端到端 top tb（arm→commit→play→真实边界翻 bank→出声路径）
8. 构建 + 上板 + 记录 sha256
