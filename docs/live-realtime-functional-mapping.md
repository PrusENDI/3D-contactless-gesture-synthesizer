# LIVE 实时化：PC 测试版功能 → FPGA 功能对应设计（2026-10-31）

目标：把最新 PC 测试版（`tools/synthwave_loop.py` + `pc_receiver/synthwave_ui.py`）的
**操作与演奏体验**，搬成 FPGA 上的**实时** LIVE 模式。本文只做功能对应与取舍，不写实现。

## 1. PC 参考实现的处理链

```
JSONL 逐帧采集
  → project_sample（校准：中性点/增益/工作区）
  → 每 tick 特征 {pitch, bow, height, speed, direction, valid, engaged}
  → bow_attacks(deadzone=0.03)        方向翻转才算"攻击"，带死区去抖
  → segments (note, start_tick, end_tick)   段长 = 音符时长
  → merge_leaps(degrees=3, dwell=8)    把"短瞥"合成一次跳进
  → 段间 rest                          没段落 = 不出音
  → 量化到 A 小调五声 G3..C5
  → 事件 note_on / note_off（带 tick）
```

关键：**出音由"段"决定，音高由段起点的 y 决定**。两段之间是静音，不是持续音。

## 2. FPGA 现状与缺口

| PC 阶段 | FPGA 现有 | 缺口 |
| --- | --- | --- |
| 采集 | 光标帧 `cursor_frame_done`（~138 Hz） | 无 |
| 校准 | `v2_input_calibration` | 无 |
| 特征 | 部分（pitch/engaged） | 缺 `speed` / `direction` / `bow` |
| **tick 网格** | **`loop_tick = sample_index[6:0]`** —— 这是 48 kHz 计数的低 7 位，128 个采样约 2.7 ms，**不是音乐 tick** | **必须新建 BPM→16 分音符的 tick 发生器**（`V2_CSR_BPM=0x08` 目前也没实现） |
| bow_attacks | 无（现在是"音高一变就 revoice"） | 缺方向翻转 + 死区检测 |
| segments | 无 | 缺段化 |
| merge_leaps | 无 | 缺短扫合并 |
| rests | 无（一直保持音） | 缺段间静音 |
| 量化 | `map_note` 已按文档改成五声 ✅ | 无 |
| 事件 | `v2_live_rule_engine`（连续跟踪器） | 语义需改成"段驱动" |

**结论：音高映射已经对齐，缺的是"音乐时间轴 + 段化"。**

## 3. 实时的取舍（必须先定）

### 3.1 tick 定义

- 建议：**16 分音符为一 tick**，`ticks_per_bar = 16`，与参考一致；
- tick 周期 = `60 / BPM / 4` 秒。120 BPM → 125 ms/tick。
- 以 48 kHz 计：`samples_per_tick = 12_000_000 / BPM`（120 BPM → 100 000 采样）。

### 3.2 延迟预算（这是实时化最硬的一条）

| 环节 | 离线代价 | 实时代价 |
| --- | --- | --- |
| 帧率 | 任意 | 138 Hz → **7.2 ms/帧** |
| 段化 | 可回看全曲 | 只能看已到达的帧 |
| `merge_leaps(dwell=8)` | 8 tick | 120 BPM 下 **1 秒延迟**，不可接受 |
| `bow_attacks(deadzone)` | 全序列 | 因果可做，延迟 0 |

**因此 `merge_leaps` 必须改**，三选一：

1. `dwell` 降到 1–2 tick（125–250 ms 延迟）——最简单；
2. 不做合并，接受"经过音"也发一次音——体验更"跟手"，但会有碎音；
3. 用"单段前瞻"：只延迟一个段就决定是否合并——折中（约 1 段延迟）。

建议先取 (1)：`dwell=2`，参数做成寄存器，后续按听感调。

### 3.3 参数表（建议初值，全部做成寄存器）

| 参数 | 参考值 | 实时建议 | 说明 |
| --- | --- | --- | --- |
| BPM | UI 可调 | 120 | 驱动 tick 发生器 |
| ticks/bar | 16 | 16 | 固定 |
| `deadzone` | 0.03（归一化） | 2000 counts（≈0.03×65535） | 弓向翻转去抖 |
| `dwell` | 8 tick | **2 tick** | 短扫合并的等待 |
| `degrees` | 3 半音 | 3 | 合并阈值 |
| 音域 | G3..C5 | 55..72 | 已实现 |
| 最小音符时长 | — | 1 tick | 防碎音 |

## 4. 功能对应表（实现时的模块划分）

| 功能 | 新模块 | 输入 | 输出 | 频率 |
| --- | --- | --- | --- | --- |
| 音乐时间轴 | `v2_tick_gen` | BPM、48 kHz | `tick_pulse`、`tick_index[6:0]` | 每 tick |
| 轨迹特征 | `v2_lead_features` | 光标帧 x/y/z | pitch（连续）、bow、speed、direction | 每帧 |
| 弓向攻击 | `v2_bow_attack` | bow 序列 | `attack` 脉冲 | 每帧 |
| 段化 | `v2_segmenter` | attack、tick、pitch | `note_on/note_off` + note + 时长 | 每 tick |
| 短扫合并 | `v2_leap_merge` | 段流（dwell 延迟） | 合并后的段流 | 每段 |
| 事件 | 现有 `v2_live_rule_engine` 改造 | 段流 | 96 位事件 | 每段 |

## 5. 需要你确认的四件事

1. **tick 定义**：16 分音符/tick、16 tick/bar，对吗？（还是 8 分或 32 分？）
2. **`dwell` 取舍**：接受 250 ms 合并延迟（dwell=2），还是完全不做合并？
3. **velocity 来源**：用手的移动速度（speed），还是固定 80，还是 z（距离）？
4. **段间静音**：参考实现是"段间不出音"。实时下你希望两段之间**完全静音**，还是**保持上一个音直到下一段**？

这四点定了，我就按 §4 的模块划分实现，并先用 Python 参考对同一段轨迹生成期望事件序列，作为 RTL 的逐事件回归。
