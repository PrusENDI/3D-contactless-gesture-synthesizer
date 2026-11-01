# 阶段 2：LOOP 轮廓 → Potts → 播放（32 tick）设计

日期：2026-11-01
状态：草稿，等待作者确认

## 1. 目标

一圈 32 tick 的完整闭环，全部在 FPGA 上完成，上位机只做控制：

```
上位机: 0x18 PREPARE → 写 arm → 写 λ → 0x28 COMMIT → MODE=PLAY
FPGA:   [采集 32 tick 轮廓] → [Potts 分段] → [事件写进 shadow 的 lead 轨]
        → [COMMIT_REQUEST] → [圈末翻 bank] → [每 tick 扫描 → 声部引擎 → FX → I2S]
上位机（可选）: 读回 32 个轮廓样本，在 loop 视图里绘制
```

非目标（本阶段明确不做）：

- 128 tick 一圈（dp 表需换存储，见 §11）。
- 每声部独立 position、真实 ADSR、和弦/强拍项。
- 多轨录音语义（touch/tap 轨不在本阶段）。
- 撤销/多 take 管理（重新 arm 即覆盖）。
- 1.5 的“LIVE 与 PLAY 共用 32 声部引擎”收尾（见 §11）。

## 2. 已定决策

| # | 项 | 决定 | 理由 |
| --- | --- | --- | --- |
| D1 | 圈长 | **32 tick**（120 BPM = 4 s = 2 小节） | 板级 DP 只有 `HORIZON<=63` 走 DPB；32 是唯一不需换存储的规模 |
| D2 | 轮廓来源 | **板上 tick 驱动采样**，不经 LIVE 事件 | 与 LIVE 解耦；索引天然对齐，不再有 `sample_index[7:0]` 回绕问题 |
| D3 | 轮廓值 | `cursor_y[15:6]`（10 bit，0..1023） | 保留手的高度信息；60 LSB/半音量级，λ 落在 16 bit 内 |
| D4 | 音级 | **8 个**，取各自 y 区间中点再 `>>6`：`{30,135,286,421,557,707,858,978}` | 与 LIVE 的 `map_note` 输出字母表一致；区间不等宽（1927–4819 counts/半音），故取中点而非线性 |
| D5 | λ | **新 CSR `0xBC`**（低 16 位），默认 **21600**（= PC 的 λ=6，1 半音²≈3600 LSB²） | 设计文档的 21600 在 `y>>6` 尺度下第一次自洽；**不能用 `THRESHOLDS[31:16]`**：bit23 是 arp 标志，且契约要求 `data[15:0] < data[31:16]`（pkg:799），λ≥0x8000 会和 arp 位冲突 |
| D6 | rest | 每 tick 一个 valid 位（`cursor_engaged`），DP 的 `rest_mask = ~valid` | 零额外成本，手离开就是休止 |
| D7 | 力度 | 固定 100 | 与 `host/v2_potts_reference.py` 逐位可比 |
| D8 | 提交 | `0x28` 语义改为“计算并发布”：置 `commit_run`，DP 完成后事件写 shadow，再发 `COMMIT_REQUEST` | 消除“op3 与 potts_start 并行、先发布录音”的现缺陷 |
| D9 | 读回 | 3 个新 CSR（0xB0/0xB4/0xB8），轮廓读口自增 | 绘制与诊断都需要 |
| D10 | 金标准 | `host/v2_potts_reference.py` 改成 `LEVELS`(y 中点) + `NOTES`(MIDI) 双表，逐事件比对 | 已有 5 项测试，继续用 |

## 3. 数据流与所有权

| 资源 | 所有者 |
| --- | --- |
| `contour_ram[0:31]` + `valid[0:31]` | 新模块 `v2_loop_contour_capture` 写；DP 组合读；CSR 读回 |
| `potts_contour[0:127]`（现有） | 删除；由上面的 RAM 直接接 DP 的 `contour` 端口 |
| store 写口 | `commit_run` 时归 Potts 事件流，否则归 recorder（现有行为） |
| store 读口 | scheduler（PLAY） |
| 声部引擎 | LIVE/PLAY（现状），本阶段不改 |

## 4. 新模块：`v2_loop_contour_capture`

```systemverilog
module v2_loop_contour_capture #(parameter integer K = 32) (
  input  logic clk, rst_n,
  input  logic arm,                 // 上位机写 0xB0 bit0；上升沿清空并开始
  input  logic tick_pulse,          // v2_tick_gen
  input  logic [6:0] mtick,         // v2_tick_gen
  input  logic [15:0] y,            // cursor_y
  input  logic engaged,             // cursor_engaged
  input  logic [4:0] rd_index,      // 读回端口
  output logic [15:0] rd_data,
  output logic full                 // 圈末（mtick[4:0]==K-1）置位，re-arm 清零
);
```

语义：

- `arm` 上升沿：清空 K 个样本与 valid 位，`full<=0`，`armed<=1`。
- `armed && tick_pulse`：`mem[mtick[4:0]] <= y[15:6]`，`valid[mtick[4:0]] <= engaged`；
  当 `mtick[4:0]==K-1` 时 `full<=1`、`armed<=0`。
- 索引直接取板上 tick，**不需要计数器，也不需要与录音起点对齐**：无论何时 arm，
  下一次 tick 0 起的 32 拍会被完整覆盖。
- 输出：`contour[t] = {6'd0, mem[t]}`（16 bit 有符号、非负）、`rest_mask[t] = ~valid[t]`。

已知限制（刻意接受）：

- 一圈 32 个采样点 = **8 Hz**，比传感器 138 Hz 粗一个量级；轮廓是 32 点折线。
  PC 侧 `synthwave_loop.py` 也是每圈 128 点，同一种粗粒度。
- arm 后未采到的 tick 都是 rest（arm 时 valid 全清），所以**半途 COMMIT 不会出脏数据**，
  只是后半圈没音；不需要为“未 full”加拒绝逻辑。
- arm 发生在任意 tick 都不影响对齐：索引就是 `mtick[4:0]`，播放也从 tick 0 开始。

## 5. Potts 改动

1. 音级：拆成两张表——`level(k)`（y>>6 单位的中点常量，只用于误差）与 `note(k)`
   （MIDI 音高，{55,57,60,62,64,67,69,72}，只用于输出事件）。现在的 `note(k)` 一张表身兼两用，
   换成 y 单位后必须拆开，否则事件里的音高会变成 30..978。`d` 计数 0..7；收尾判据 `d==7`。

   `level(k) = floor(midpoint(k) / 64)`，midpoint 取自 `note_boundary()` 的 8 个区间：

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
2. 轮廓：直接接采集 RAM（`contour[t] = mem[t]`），`rest_mask = ~valid`。
3. λ：`lambda_q16` 接新寄存器 `potts_lambda`（CSR `0xBC`，复位值 21600）。
4. `HORIZON=32` 保持（`DP_RAM` 走 DPB）；`EV_CAP = 32/4+1 = 9`，够 8 段。
5. DP 本体（枚举顺序、平局规则、饱和、回溯）**不动**；只换常量与数据源。
6. 端口仍是 `contour[0:127]`、`rest_mask[127:0]`：top 里把采集 RAM 的 32 项映射到 `[0:31]`，
   `[32:127]` 恒 0；`rest_mask[0:31] = ~valid`，其余位 1（避免 DP 读到假数据）。
7. 参考解算器 `solve()` 增加 `horizon` 参数（默认 128，本阶段用 32），并改用
   `LEVELS` 算误差、`NOTES` 输出；5 个既有测试按新常量重写输入。

## 6. 提交与写 shadow

`0x28 COMMIT` 现在的行为（同时发 store op3 + `potts_start`）改为：

```
写 0x28 → commit_run <= 1（不再直接发 op3，也不再直接 potts_start）
commit_run && !potts_busy && !potts_done_seen → potts_start 一拍
potts_event_valid/ready ⇄ store 写口（track=0，slot=slot_cnt，slot_cnt 每写成功 +1）
potts_done → 若要写的事件已全部写进 store → 发 COMMIT_REQUEST（loop_ctrl op3）→ commit_run<=0
```

要点：

- 写口 owner：`commit_run ? potts_event_* : recorder_*`；`write_slot` 用 `slot_cnt`，
  与 recorder 的 `recorder_write_slot` 二选一。
- `PREPARE_RECORD`（0x18）已经把 lead 轨的 count 清零（`counts[shadow][track]=0`），
  所以写之前**不需要**额外 `CLEAR_TRACK`；旧数据因 count 归零不可见。
- `COMMIT_REQUEST` 之后 `commit_pending` 一直挂着，直到 scheduler 在圈末发 `BOUNDARY`；
  超时 3.4e9 周期（80 MHz 下 **42.5 s**）会丢弃并置 `commit_timeout`。
- **发布只发生在 PLAY 里**（scheduler 只在 `mode_play` 运行），所以上位机必须在 COMMIT 后进 PLAY。

## 7. 播放

1. `LOOP_TICKS = 32` 参数化；`loop_tick` 改接 `tick_now[4:0]`（现在是 `sample_index[6:0]`）。
   所有 tick 比较都收窄到 `LOOP_TICKS` 的位数（5 bit）：`end_tick[4:0]==loop_tick`、
   `loop_tick==5'd31`。事件字段本身仍是 7 bit `[87:80]`，本阶段只用到低 5 位。
2. scheduler 改为**每 tick 扫一遍**：`tick_pulse` 置 `scan_active`，扫完 6 轨 × 32 槽 × 3 遍后清零；
   不再自由跑，否则同一个事件会在一个 tick 内被重复命中。
3. `loop_boundary` 在 `loop_tick==LOOP_TICKS-1` 且该 tick 的扫描结束时发一次。
4. ON 事件的时值仍由 `duration` 生成 OFF（`end_tick = tick + duration`），所以 Potts 的
   `duration` 必须 ≥1 且 `tick+duration <= 31`。
5. PLAY 的音频路径不变：声部引擎 → `v2_fx_lite` → `>>>2` → I2S。

## 8. CSR 新增

| 地址 | 名称 | 读 | 写 |
| --- | --- | --- | --- |
| 0xB0 | `CONTOUR_CTRL` | `{30'd0, full, armed}` | bit0 = arm（写 1 触发一次） |
| 0xB4 | `CONTOUR_DATA` | `{22'd0, contour[rd_ptr]}`，**读一次 rd_ptr+1** | 只读 |
| 0xB8 | `POTTS_STATUS` | `{28'd0, overflow, busy, done, event_count[5:0]}` | 只读 |
| 0xBC | `POTTS_LAMBDA` | `{16'd0, potts_lambda}` | λ（低 16 位），复位 21600 |

- 写掩码：`0xB0` = `0x1`、`0xBC` = `0xFFFF`；`0xB4`/`0xB8` 只读。
- 四个地址都在 DIAG 段头部，当前未被占用（实现的是 `0xC0..0xFC`）。
- `THRESHOLDS(0x30)` 保持原语义不动（`[7:0]` 测试音、`[23]` arp、`[15:0] < [31:16]` 校验）。

## 9. 上位机协议

```
1. 0x18 = 1            PREPARE_RECORD（复制 active→shadow，清 lead 轨）
2. 0xB0 = 1            arm：清空并开始采集 32 tick
3. 0xBC = λ             写 λ（默认 21600；不写就用复位值）
4. 轮询 0xB0 直到 full=1（32 tick @120 BPM = 4 s；@45 BPM = 10.7 s）
5. 0x28 = 1            COMMIT：算 → 写 shadow → 请求发布
6. 轮询 0xB8 直到 done=1（H32 约 0.57 ms）
7. 0x04 = 5            MODE=PLAY：进入后第一个圈末翻 bank，再下一圈开始响
8. （可选）读 0xB4 × 32 拿轮廓，绘制
```

## 10. 验收

| 层 | 判据 |
| --- | --- |
| 单元：采集块 | arm → 32 个 tick 后 `full=1`；valid 位随 `engaged`；re-arm 清零；索引来自 `mtick[4:0]` |
| 单元：Potts | `HORIZON=32`、8 音级、λ=0 时的精确事件流（`tb_v2_potts_commit_fsm` 更新期望） |
| 单元：提交写口 | `0x28` → DP → n 个事件按 slot 0..n-1 写入 shadow → 发 `COMMIT_REQUEST`；边界到达后 bank 交换；不写 active |
| 单元：调度 | 每 tick 只扫一遍、同一事件不重复发、圈末 boundary 只发一次（`LOOP_TICKS=32`） |
| 回归 | `python scripts/sim.py` PASS 且失败集不超出 `sim_baseline.json` |
| 参考 | `python -m unittest host.test_v2_potts_reference`：`LEVELS`（y 中点）用于误差、`NOTES`（MIDI）用于输出，5 项测试改成同一套常量后仍通过 |
| 板上 | PLAY 有声音；连续两圈事件集合一致；`bitstream_sha256` 记录 |
| 可选 | `0xE8`/`0xD4` 读数 + GAO 频谱 |

## 11. 风险与依赖

1. **时序**：旧报告里 Potts 的 segment 累加是全设计最差路径（15.6 ns/23 级）。
   本阶段第一个构建就要看 slack，必要时拆流水（SEGMENT 内先累加两半）。
2. **发布依赖 PLAY**：不写 `MODE=PLAY` 就没有边界，42.5 s 后提交被丢弃（`commit_timeout`）。
3. **1.5 未收尾**：LIVE 目前走单声部波表、PLAY 走 32 声部引擎，“同一音色”仍是两条路径；
   若要在本阶段一起收，需改 `i2s_sample` 的 LIVE 分支（已知，不在本设计范围）。
4. **BPM 影响时长**：同样 32 tick，宿主 60–240 BPM 下是 8–2 s；LIVE 自动 tempo 30–59 下是 16–8.1 s。
5. **`gate.py` 现在是红的**（1.5 两个模块未实例化），本阶段以 tb + `sim.py` 为判据。

## 12. 实施顺序（给计划用）

1. 采集块 + tb（不动其它逻辑）
2. Potts 8 音级 + 接采集 RAM + λ 接线 + tb 更新
3. CSR 三连（0xB0/0xB4/0xB8）+ 契约包
4. 提交写口 owner + 槽计数 + `0x28` 语义 + tb
5. scheduler 每 tick 扫描 + `LOOP_TICKS=32` + `loop_tick` + tb
6. 端到端仿真（top tb：arm→commit→play→bank 交换）
7. 构建 + 上板 + 记录 sha256
