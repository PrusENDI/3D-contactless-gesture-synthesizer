# LIVE 琶音 + LOOP 变分：设计文档（2026-10-31）

状态：**待批准**（批准前不改 RTL）
仓库：`mgc3130_clean`（master @ `45ca44f`）
依据：`docs/live-realtime-mapping-183da4e.md`、`mgc3130_uart@183da4e` 的
`docs/system-design-summary-2026-10-25.md`、`tools/synthwave_loop.py@5312d84`

## 1. 意图

一次演奏分成两层，各自承担它擅长的东西：

- **LIVE = 连续琶音**。手一动就出声，音高随 y 变化，每个音的起点落在 16 分音符网格上。
  它要的是**即时反馈和可听性**，不是旋律质量。
- **LOOP = 变分分段**。录下每 tick 的 y，COMMIT 时用 Potts 从原始轨迹重算整圈旋律。
  它要的是**旋律质量**，可以离线、可以慢。

这样 10 ms 级的延迟要求和全局最优的旋律质量不再互相拉扯：一个在实时路径，一个在提交路径。

## 2. 目标

| 编号 | 目标 | 判定方式 |
| --- | --- | --- |
| G1 | LIVE 在 BPM=100 下最多 6.67 音/秒，音起点都在 tick 边界 | GAO / 仿真统计换音间隔 |
| G2 | LIVE 起音延迟 ≤ 1 帧（7.2 ms） | GAO 测 `cursor_frame_done → live_event_valid` |
| G3 | LOOP 的音高与边界由 Potts 从**每 tick 的 y** 重算 | 与 PC 参考同一输入的事件表对照 |
| G4 | 事件 tick 字段是 7 bit 音乐 tick，loop 能循环播放 | UART 读回 + 播放 |
| G5 | 全部判据机器可查（§9） | `scripts/*` 产出物 |

## 3. 非目标

- 不做接触门控（`touch`），不做弓向门控（`bow`）——用户明确排除"接触发声"。
- 不做运动门（"停手即静音"）——LIVE 要连续演奏。
- 不改 FX、波表链路、测试模式、声部数（32）。
- 不做 LIVE 多声部：LIVE 只有一条 lead。
- 不改 PC UI 逻辑，只改参考实现的 y 映射常量（§6.4）。

## 4. 反目标（技术上做成了也算失败）

- LIVE 每秒超过 6.67 个音——那就退回"机器枪"。
- LIVE 与 LOOP 用两套音高坐标——那 PC 对照失去意义。
- 把 Potts 放进实时路径——延迟必然破坏 G2。
- 用 CSR 回读证明实时性——只能 GAO 或仿真。

## 5. 方案与取舍

### 5.1 LIVE 的三条路

| 方案 | 起音延迟 | 换音延迟 | 资源 | 结论 |
| --- | --- | --- | --- | --- |
| A 纯 tick 同步（每 tick 采样 y） | ≤150 ms | ≤150 ms | ~150 LUT | 合拍，但第一次出声"慢半拍" |
| **B 帧级即时起音 + tick 边界换音** | **≤7 ms** | ≤150 ms | ~200 LUT | **采用** |
| C 步进琶音器（每 tick 强制发一个音） | 1 tick | 1 tick | ~150 LUT | 手速不影响节奏，演奏感最弱 |

选 B：它保住了"手一动就响"的反馈，同时把换音压在网格上，因此既像乐器又像琶音。
持续移动时 A 与 B 几乎等价，差别只在每个乐句的第一个音。

### 5.2 LOOP 的两条路

| 方案 | 喂给 Potts 的 | 新增 | 结论 |
| --- | --- | --- | --- |
| X 录已弹事件（音符号） | `live_event_data[71:64]` | 无 | 只能挪边界，**改不了音高** |
| **Y 录每 tick 的 y（轮廓）** | 16 bit 原始 y | **1 BSRAM** | **采用**：音高与边界都从轨迹重算 |

选 Y：X 的输入已经是 8 个离散值，Potts 再多聪明也只能合并，做不出"loop 比 live 更好听"。

## 6. 详细设计

### 6.1 tick 发生器 `v2_tick_gen`（新模块）

```
samples_per_tick = 720_000 / BPM          // 48 kHz × 60 s / (BPM × 4)
```

- `BPM` 来自 CSR `0x08`（契约里已定义、top 里还没有实现），默认 100。
- 除法**只在 BPM 写入时做一次**：顺序除法器（24 bit ÷ 16 bit，24 拍），结果存 `samples_per_tick[23:0]`。
  余数丢弃，最大误差 1 采样（0.014%），可以接受。
- 运行期：`sample_ce` 计数到 `samples_per_tick` → `tick_pulse`，同时 `tick[6:0] += 1`（模 128）。
- BPM 范围限制 40..240，写入时钳位。

| 项 | 值 |
| --- | --- |
| 100 BPM | 7200 采样 = 150 ms |
| 90 / 120 / 128 BPM | 8000 / 6000 / 5625 采样 |
| Loop | 8 小节 × 16 tick = 128 tick = 19.2 s @100 BPM |
| 估计面积 | ~100 LUT，0 DSP，0 BSRAM |

**这是前置条件**：没有它，后面所有"tick"都不成立。当前 top 用 `sample_index[6:0]` 当 tick，
128 个采样就是一"圈"，只有 2.7 ms。

### 6.2 LIVE 琶音规则（改写 `v2_live_rule_engine`）

**删除**：左边界 arming（`left_edge` 现在被硬接 `1'b1`）、`edge_cross` 重击、
死的 `note_change_ok` 判据、每帧的 `EV_CONTROL`（z 变化）事件、`MIN_EVENT_TICKS` 采样计数。

**保留**：`map_note`（表要修正，见 §6.4）、`active/active_note`、事件握手。

**新增两条规则**：

```
// 1) 即时起音（帧级）
if (!active && gate)  → NOTE_ON(map_note(y))        // ≤1 帧

// 2) 网格换音（tick 级，每 tick 至多一次）
on tick_pulse:
    cand = map_note(y_sampled)
    if (active && cand != active_note && hysteresis_ok(y_sampled, active_note, cand))
        → NOTE_OFF(active_note) 然后 NOTE_ON(cand)   // 同一 tick，顺序固定 OFF→ON
```

- `gate = cursor_engaged`（Z 距离门），沿用现状；不做接触、不做运动门。
- `y_sampled` = tick 边界时锁存的 `cursor_y`。
- 同音高保持不重发（不产生 `note_off/on` 对）。
- 力度沿用现有 `cursor_velocity[7:0]`（光标模块已经给出 proximity + speed 的合成）。
- 事件 `tick` 字段 = 7 bit 音乐 tick。

**行为后果**：手在感应区内扫动 → 每 tick 至多一个音，音高随 y 阶梯上升/下降 = 琶音；
手停住 → 一个长音；手离开 → gate 落，NOTE_OFF。没有休止，因为不需要。

### 6.3 事件语义：LIVE 路径去掉 `REVOICE`

现状的 bug：规则引擎在 `EV_REVOICE` 里打包**新音高**，而声部引擎按
"找已经在弹这个新音高的声部"去匹配（`note[i] == event_data[71:64]`），
正在响的声部持的是旧音高，所以恒不匹配、静默丢弃。结果音高只能靠下一次
NOTE_ON 更新。

**决定**：LIVE 不再发 `REVOICE`，改发 `NOTE_OFF(old)` + `NOTE_ON(new)`。

理由：
- 不动 32 声部引擎，风险最小；
- 每个音重新起音，正是琶音想要的；
- `v2_loop_scheduler` 已经支持显式 `NOTE_OFF`（pass 0），存储/回放不用改；
- 事件率翻倍也无所谓：最多 13.3 事件/秒。

**同一 tick 内 OFF 先于 ON** 由调度器保证，不靠写入顺序：
`v2_loop_scheduler` 按 pass 处理（pass0 = NOTE_OFF，pass1 = NOTE_ON，pass2 = CONTROL）。
规则引擎只需保证两个事件带同一个 7 bit tick。

### 6.4 音高坐标与量化表

**决定：板上用 Y 全量程，1 半音 = 3855 counts。**

现状三个问题：
1. RTL 的 `map_axis()` 只做 `+32768`，**没有 PC 的 0.648 压缩**，全量程 0..65535；
2. `map_note` 的 7 个边界与"线性音高 + 五声量化"不一致（实际宽度 2/1/2/1/3/2/1/5 半音，
   应为 2/3/2/2/3/2/3）；
3. 两者叠加导致中音区偏低 1–3 个半音、C5 独占最上面 5 个半音。

新表（截断式，音级从自己的中心开始；PC 参考同步改成 `CURSOR_Y_RANGE=(0,65535)`）：

| 音 | 中心/起始 y | 滞回 |
| --- | --- | --- |
| 55 G3 | 0 | 250 |
| 57 A3 | 7710 | 250 |
| 60 C4 | 19275 | 250 |
| 62 D4 | 26985 | 250 |
| 64 E4 | 34695 | 250 |
| 67 G4 | 46260 | 250 |
| 69 A4 | 53970 | 250 |
| 72 C5 | 65535 | — |

`map_note(y)` = 落到包含 y 的区间；换音需离开当前音中心 250 counts（约 0.065 半音）。

选全量程而不压缩的理由：画布是 PC 的概念，板上只关心 y→音高；全量程免掉一个乘法器，
而且分辨率从 2498 提到 3855 counts/半音。

### 6.5 轮廓录制 `v2_contour_recorder`（新模块）

- 128 × 16 bit RAM 存 `cursor_y`，配 `valid[127:0]` 掩码（无手/无效帧为 0）。
- 写：RECORD 期间每个 `tick_pulse` 写一个点，索引 = `tick[6:0]`。
- 1 BSRAM（128×16 装得进 1024×18），~30 LUT 胶合。
- 与事件录制并行（事件仍录，供 LIVE 回放/诊断）。

### 6.6 COMMIT：分块 Potts（改 `v2_potts_commit_fsm` + 顶层）

板上 `HORIZON=32`，128 tick 要分 4 块：

```
chunk k = 0..3:  BASE = 32k (k=0) / 32k-4 (k>0)        // 4 tick 重叠
                 窗口 = [BASE, BASE+32)
                 只提交 start ≥ 32k 的段               // 首段属于上一块
                 事件 tick = BASE + trace_start
```

改动点：
1. `contour[seg_t]` → `contour[BASE + seg_t]`；`rest_mask` 同样加 BASE。
2. 音级表从 5 个扩到 8 个（`note(k)` 加 55/69/72，`d==4` 的收尾判据改成 `d==7`）。
3. 误差项从"音符号差平方"改成"y 与音级中心差平方"，定点见 §7。
4. 新增 `BASE` 输入与事件打包时的绝对 tick。
5. 顶层新增提交序列器：4 次 start/done，把事件写进 loop store。

### 6.7 路由：Potts → loop store

现状：Potts 的事件直接送声部（`mode` 非 live 非 play 时）。
目标：COMMIT 后写进 loop store 的 lead 轨，再由 `v2_loop_scheduler` 循环播放。

改动：store 的写口加一级 mux（平时接 `u_recorder`，COMMIT 时接 Potts），
以及一个"COMMIT 期间占用写口"的仲裁信号。事件 track 位由 FSM 置 0（lead）。

## 7. 定点约定（Potts 误差项）

轮廓值 = `y`（0..65535），音级中心 `c_k` 见 §6.4 表。

```
delta = (y - c_k) >> 6          // 11 bit 有符号，量程 ±1023
err   = delta * delta            // ≤ 1,046,529，20 bit
λ     = lambda_q16               // 与 err 同单位
```

单位换算：1 半音 = 3855 counts → `3855>>6 = 60` → 1 半音² = 3600 LSB。
PC 的 λ=6 → 板上 `lambda_q16 = 21600`（0x5460）。

`dp` 累加仍是 32 bit，饱和在 `0x3FFFFFFF`（现有 `sat()` 不变）。

## 8. 寄存器与接口变更

| CSR | 变更 |
| --- | --- |
| `0x08 BPM` | **新实现**：16 bit，钳位 40..240，写入时重算 `samples_per_tick` |
| `0x28 COMMIT` | 语义扩展：触发 4 块序列，完成后 `potts_done` |
| 新增 `0x2C` 之后任一空位（建议 `0x5C` 已被 patch 占用，用 `0xA4`） | `lambda_q16`（16 bit），默认 21600 |
| `0x34 POSITION` / 遥测 | 增加 `tick[6:0]` 与 `live_active_note`（可选） |

事件契约（96 bit）**不变**，只是 LIVE 不再用 `REVOICE`，并把 `[87:80]` 写成音乐 tick。

## 9. 验收判据（全部可机器检查）

1. **tick 周期**：BPM=100，连续 128 个 `tick_pulse` 跨 921 600 采样 ±1。
2. **琶音速率**：一段从 y=0 线性升到 65535、持续 128 tick 的激励，产出恰好 7 次换音
   （8 个音级），间隔都 ≥1 tick。
3. **同音不重发**：y 固定 32 tick，LIVE 事件数 = 0（除首次 NOTE_ON）。
4. **起音延迟**：`cursor_frame_done` 到 `live_event_valid` ≤ 1 帧（7.2 ms）。
5. **REVOICE 消失**：LIVE 路径不再出现 `EV_REVOICE`（grep 事件流）。
6. **COMMIT 一致性**：仿真里用 `HORIZON=128` 跑一遍作金标准，与 4×32 分块结果逐事件比较；
   差异必须为 0，否则把差异写进文档并给出理由。
7. **循环落位**：录 2 圈，读回事件 tick 集合应为 `{0..127}` 的子集，且第二圈覆盖第一圈。
8. **可听性**：一段正弦手势（1 Hz）产出 ≥8 个音且音高单调跟随（不能只在波峰出音）。

## 10. 验证计划

| 层 | 命令 | 判据 |
| --- | --- | --- |
| L0 静态 | `python scripts/gate.py` | 无重名模块、单一顶层、filelist 一致 |
| L1 编译 | `python scripts/gate.py --compile` | 0 error / 0 warning |
| L2 仿真 | `python scripts/sim.py` + 新增 `tb_live_arpeggio`、`tb_potts_chunk` | 失败是基线子集；新增用例全过 |
| L3 构建 | `python scripts/synth.py --run-id arp1` | syn + P&R 通过，**记录违约端点数为 0**，位流 sha256 |
| L4 板级协议 | `host/board_*.ps1` | BPM 写入/读回、COMMIT、事件表读回，N 轮 + 负例 |
| L5 波形 | `python scripts/gao_capture.py` | 抓 16 个连续 tick 的 `live_event_*`，验证换音只在边界 |

L4/L5 必须记录：基线寄存器、位流 sha256、源 commit、未跑项清单。

## 11. 资源预算（估算，须由 `synth.py` 实测）

| 变更 | LUT | DSP | BSRAM |
| --- | --- | --- | --- |
| `v2_tick_gen` + BPM 寄存器 + 除法器 | +100 | – | – |
| LIVE 规则改写（删 arm/edge，加 tick 采样） | −40 | – | – |
| 轮廓 RAM + 胶合 | +30 | – | **+1** |
| Potts 扩到 8 音级 + 平方器 + BASE | +100 | **+1** | – |
| COMMIT 序列器 | +80 | – | – |
| **合计** | **≈ +270** | **+1** | **+1** |

余量：CLS 549 空闲、LUT 3263 空闲、BSRAM 20 空闲。可行，但没有第二次机会——
任何额外功能都要先砍别的东西。

## 12. 风险

1. **DSP**：平方器可能不止 +1，需在 L3 实测；不够就用移位加法（多 ~100 LUT）。
2. **分块接缝**：4 块拼接与全局 DP 的差异目前未知；§9.6 就是为量化它而设。
3. **旧文档的"41 µs"不可信**：FSM 的 SEGMENT 状态对每个 cell 重扫段内所有点，复杂度 O(H³·K)，
   估算 H=128 约 3×10⁷ 拍（80 MHz 下数十毫秒），H=32 约 1×10⁶ 拍（约 1 ms/块）。以实测为准。
4. **PC 与板上的坐标分叉**：本次把 PC 改成全量程，会破它现有的测试与历史采集的可比性；
   旧采集需要重算。
5. **CLS 紧**：95.2% 已用，新增 270 LUT 后约 96–97%，P&R 可能开始变慢或违例。

## 13. 留给实现者的决定

- tick 发生器的除法器复用光标里的 `u_div` 还是独立一个（耦合 vs 面积）。
- 轮廓 RAM 用 BSRAM 还是 DPB（DPB 已被 Potts 占 3 块）。
- COMMIT 序列器的状态机形态（4 块串行，还是允许 32 tick 一步跑完）。
- 是否保留 `EV_CONTROL` 在其它路径（遥测仍需要 z，但不必走事件流）。

## 14. 我替你定下的（请复核）

1. **16 分音符为一格**（1 tick = 150 ms @100 BPM），与 PC 参考一致。
2. **LIVE 用 NOTE_OFF+NOTE_ON 代替 REVOICE**（不动声部引擎）。
3. **板上音高用 Y 全量程**（1 半音 = 3855 counts），PC 参考同步。
4. **同音高不重发**（保持长音），不做每 tick 重击。
5. 文档放 `docs/` 平铺目录，跟随本仓库现有习惯（而非 `docs/superpowers/specs/`）。
