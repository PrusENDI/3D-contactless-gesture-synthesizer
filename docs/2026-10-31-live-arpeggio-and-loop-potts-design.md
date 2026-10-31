# LIVE 步进琶音 + LOOP 定长轮廓：设计文档（rev3）

状态：**待批准**（批准前不改 RTL）
仓库：`mgc3130_clean`（master @ `45ca44f`）
依据：`docs/live-realtime-mapping-183da4e.md`、`mgc3130_uart@183da4e`
`docs/system-design-summary-2026-10-25.md`、`tools/synthwave_loop.py@5312d84`

rev3 变更：LIVE 改为**方案 C（每 tick 强制发一个音）**；LOOP 改为**固定 128 tick 只录轮廓**、
两个模式由上位机分别选择、互不混用。rev2 里"LIVE 事件入 store""容量 32""第二圈覆盖第一圈"
等条目随之删除。

## 1. 意图

两个模式，两套职责，由上位机（`MODE` CSR `0x04`）选择，互不混用：

| 模式 | 做什么 | 声音 |
| --- | --- | --- |
| **LIVE** | 步进琶音：每 tick 一个音，音高 = 该 tick 的 y | 实时出声，永远合拍 |
| **RECORD** | 只录 128 tick 的 y 轮廓，不录事件 | 静音（见 §6.5） |
| **PLAY** | 循环播放 COMMIT 产出的 Potts 事件表 | loop |

"演奏"和"作曲"因此彻底分开：LIVE 只负责手感与实时性，RECORD+COMMIT 只负责旋律质量。

## 2. 目标

| 编号 | 目标 | 判定 |
| --- | --- | --- |
| G1 | LIVE 严格 1 音/tick（120 BPM → 8 音/秒），起点全在 tick 边界 | GAO 数 128 tick 内的 `NOTE_ON` |
| G2 | LIVE 起音延迟 ≤ 1 tick（120 BPM = 125 ms） | GAO 测 tick_pulse → event_valid |
| G3 | LOOP 音高与边界由 Potts 从**每 tick 的 y** 重算 | 与 PC 参考同输入对照（§15-Q2） |
| G4 | 录满 128 tick 后 COMMIT 可发布，PLAY 能循环 | GAO 抓写存事件流 + 播放 |
| G5 | 判据机器可查（§9） | `scripts/*` 产出物 |

> **G2 的含义变了**：C 是网格化演奏，起音最多滞后 1 tick（125 ms），不是 10 ms。
> 验收口径应写成"网格化、≤1 tick"，不能再说 ≤10 ms。

## 3. 非目标

- 不做接触门控、弓向门控、运动门（用户已排除；C 也不需要）。
- 不做 overdub / 叠录：一圈就是一录。
- 不改 FX、波表、测试模式、声部数（32）。
- 不做 LIVE 多声部。
- 不新增 CSR 地址（λ 借用 `THRESHOLDS`，见 §8.2）。

## 4. 反目标

- LIVE 一个 tick 发两个音，或音起点落在网格外。
- LIVE 与 LOOP 用两套音高坐标。
- 把 Potts 放进实时路径。
- 用 CSR 回读证明实时性（只能 GAO/仿真）。
- RECORD 期间把事件写进 loop store（容量只有 32/轨，见 §5.3）。

## 5. 方案与取舍

### 5.1 LIVE：选 C

| 方案 | 起音 | 换音 | 资源 | 结论 |
| --- | --- | --- | --- | --- |
| A 纯 tick 同步（有变化才发） | ≤1 tick | ≤1 tick | ~150 LUT | 手停住就没有声音活动 |
| B 帧级即时起音 + tick 换音 | ≤7 ms | ≤1 tick | ~200 LUT | 需要帧级路径 |
| **C 步进琶音器（每 tick 发一音）** | ≤1 tick | 1 tick | **~120 LUT** | **采用** |

C 的取舍：手退化成"音高选择器"，节奏完全由机器提供；换来的是**永不冷场**、实现最简、
和 loop 严格同网格。C 不需要帧级起音路径，也不需要滞回时机推理——每 tick 直接按当前 y 定音。

### 5.2 LOOP：只录轮廓（方案 Y）

喂给 Potts 的是每 tick 的 `cursor_y`（16 bit），不是已弹事件。这样音高和边界都从原始轨迹重算。

### 5.3 为什么"只录轮廓 + 定长"是关键简化

| 原来的阻塞 | 现在 |
| --- | --- |
| store 每轨只有 32 个事件槽，128 tick 连续琶音放不下 | **不存事件**，只存轮廓；store 只装 Potts 结果（12–17 个，硬上限 32） |
| append-only、后圈覆盖前圈、overdub 语义 | **一圈就是一录**，无叠录，无覆盖语义 |
| COMMIT 要不要保留现场演奏 | 不需要：RECORD 期不产生可存事件 |
| loop 长度不定 | **固定 128 tick = 8 小节**（120 BPM 下 16 s） |

## 6. 详细设计

### 6.1 tick 发生器 `v2_tick_gen`（新）

```
samples_per_tick = 720_000 / BPM        // 48 kHz × 60 / (BPM × 4)
```

| 项 | 值 |
| --- | --- |
| BPM | 契约：60..240，默认 **120**，值在 `[31:16]`；越界由 `v2_uart_link` 拒收（BAD_DATA），板内不钳位 |
| 120 BPM | 6000 采样 = **125 ms/tick**；128 tick = **16 s** |
| 100 BPM | 7200 采样 = 150 ms/tick；128 tick = 19.2 s |
| 除法 | 只在 BPM 写入时做一次（24 ÷ 16 bit，24 拍），余数丢弃（≤0.014%） |
| 面积 | ~100 LUT |

BPM 写入时**重置 tick 计数**。现状用 `sample_index[6:0]` 当 tick（128 采样 = 2.7 ms），必须先换掉。

### 6.2 LIVE 步进琶音（改写 `v2_live_rule_engine`）

```
on tick_pulse:
    cand = map_note(y_now)
    if (active) → NOTE_OFF(active_note)
    → NOTE_ON(cand, velocity)
    active_note <= cand
```

- 每 tick 恰好一对 OFF/ON；音高相同也照发（这就是步进琶音的"重复敲"）。
- `y_now` = tick 边界时的 `cursor_y`。
- `gate = cursor_engaged`（Z 距离门）：gate 落时不发新音，并发一次 `NOTE_OFF`。
- **删除**：左边界 arming、`edge_cross`、死的 `note_change_ok`、每帧 `EV_CONTROL`、
  `MIN_EVENT_TICKS`（网格本身就是时间限）。
- NOTE_OFF **不受 `bad_frame` 阻塞**：现状 `.frame_valid(cursor_frame_done && cursor_engaged)`
  让 `active && !gate` 不可达 → 音会永远挂着。修正为"只看 gate 电平"，并加 2 s 卡音超时兜底。

### 6.3 事件语义

LIVE 不再用 `EV_REVOICE`。现状它打包新音高，而声部引擎按"找已经在弹这个新音高的声部"匹配，
恒不匹配、静默丢弃 → 音高永远不更新。

C 每 tick 都发 `NOTE_OFF` + `NOTE_ON`，天然绕过该缺陷，且**不需要改 32 声部引擎**。
调度器 pass 顺序（pass0=OFF，pass1=ON）保证同 tick 内 OFF 先于 ON。

### 6.4 音高坐标与量化

**Y 全量程，1 半音 = 3855 counts（65535/17）**，量化用**最近邻**（与 PC `_nearest_scale` 一致）。
下表是**音级中心**，`map_note` 的门槛是相邻中心的中点：

| 音 | 中心 c_k | 门槛 |
| --- | --- | --- |
| 55 G3 | 0 | — |
| 57 A3 | 7710 | 3855 |
| 60 C4 | 19275 | 13493 |
| 62 D4 | 26985 | 23130 |
| 64 E4 | 34695 | 30840 |
| 67 G4 | 46260 | 40478 |
| 69 A4 | 53970 | 50115 |
| 72 C5 | 65535 | 59753 |

C 模式没有换音滞回（每 tick 直接按最近邻定音），所以 §6.4 的 250 counts 滞回**只用于 Potts 的分段约束**，不用于 LIVE。
（这一条消除了 rev2 里"同一张表当两个用"的矛盾。）

PC 参考须同步改成 `CURSOR_Y_RANGE=(0,65535)`（见 §15-Q2）。

### 6.5 轮廓录制 `v2_contour_recorder`（新）

```
MODE=RECORD → 等下一个 tick==0 → 连续 128 个 tick 写 y[i] 与 valid[i] → contour_full
```

- 128 × 16 bit RAM + 128 bit valid 掩码，1 BSRAM。
- 无手/无效帧写 valid=0，COMMIT 时当 `rest_mask`。
- **不记录事件**，也不发声：RECORD 期静音（要监听只能靠上位机，见 §15-Q3）。
- 未录满就退出 RECORD（host 改 MODE）→ 丢弃本次，`contour_full=0`。

### 6.6 COMMIT：Potts（形态待定，§15-Q1）

| 形态 | 做法 | 代价 |
| --- | --- | --- |
| A 分块 | 128 tick 分 5 块，`BASE` 每次前进 **28**（左重叠 4），丢弃跨界的首段 | 序列器 ~80 LUT，接缝需验收 |
| B 一次跑完 | `HORIZON=128`，DP 表搬到 DPB（7 bit 地址） | ~+1 DPB lane，COMMIT 数十毫秒 |

（rev2 写的 4 块是错的：每块只能提交 28 个新 tick，128 需要 5 块，否则留下 4 tick 空洞。）

两种形态都要改：
1. `contour[seg_t]` → `contour[BASE + seg_t]`（B 形态 BASE=0）；
2. 音级表 5 → 8（`note(k)` 补 55/69/72，收尾判据 `d==4` → `d==7`）；
3. 误差项改成 `(y − c_k)` 平方，定点见 §7；
4. 事件打包写绝对 tick。

### 6.7 COMMIT → store 时序

```
0x28 COMMIT
  → PREPARE（复制 active → shadow，等 write_ready）
  → CLEAR_TRACK(lead)
  → Potts（A: 5 次 / B: 1 次）→ 事件写 shadow 的 lead 轨（≤32）
  → COMMIT_REQUEST（切 bank，在 loop 边界生效）
  → host 写 MODE=PLAY
```

现状一次 `0x28` 同时触发 `loop_ctrl_op=3` 和 `potts_start`；非 PLAY 模式下要等 16–19 s 的 loop
边界，等不到就丢影子 bank。序列器必须显式等待并暴露 fault。

## 7. 定点约定

```
delta = (y - c_k) >> 6      // 11 bit 有符号
err   = delta * delta        // ≤1,046,529
λ     = lambda_q16           // 同单位
```

1 半音 = 3855 counts → `3855>>6 = 60` → 1 半音² = 3600 LSB。PC 的 λ=6 → `lambda_q16 = 21600`。

## 8. 寄存器与接口

### 8.1 BPM

`0x08`，值 `[31:16]`，60..240，默认 120，越界拒收，写入后重置 tick 计数。

### 8.2 λ

不新增地址（`0xA4` 已被只读 `dbg_apply_reject_reason` 占用）。放
`V2_CSR_THRESHOLDS(0x30)` 的 `[31:16]`，默认 21600。

### 8.3 velocity

现状 `velocity_in = cursor_velocity[7:0]` 是 Q16 值的低字节，会回绕、非单调。
改为 **256×8 bit ROM**：输入 `cursor_velocity[15:8]`，输出单调映射到 MIDI 32..122。

### 8.4 可观测性

`potts_done` / commit 状态无 CSR 可读（见 §15-Q3）。

## 9. 验收判据

1. **tick 周期**：120 BPM，128 个 `tick_pulse` 跨 768 000 采样 ±1（16 s）。
2. **严格 1 音/tick**：128 tick 内 `NOTE_ON` 计数 = 128，任意两个相隔 = 1 tick。
3. **音高跟随**：y 从 0 线性升到 65535 的 128 tick，音高序列单调，且恰好经过 8 个音级。
4. **同音重复**：y 固定 32 tick → 32 个同音高事件（不是 1 个长音）。
5. **不卡音**：发过 NOTE_ON 后把手移出感应区，下一次 tick 收到 NOTE_OFF。
6. **RECORD 定长**：录满 128 tick 后 `contour_full=1`；中途退出则丢弃。
7. **COMMIT 发布**：COMMIT 后 PLAY 的事件集 = Potts 输出（4–32 个/圈），每圈相同。
8. **可听性**：1 Hz 正弦手势录 8 小节，Potts 输出 ≥8 个音且音高单调跟随。

## 10. 验证计划

| 层 | 命令 | 判据 |
| --- | --- | --- |
| L0 | `python scripts/gate.py` | 无重名模块、单一顶层 |
| L1 | `gate.py --compile` | 0 error / 0 warning |
| L2 | `sim.py` + 新增 `tb_live_arp`、`tb_potts_commit` | 基线子集；新增全过 |
| L3 | `synth.py --run-id arp1` | syn + P&R，**违约端点 0**，位流 sha256 |
| L4 | `host/board_*.ps1` | BPM 写/读回、RECORD 定长、COMMIT、PLAY |
| L5 | `gao_capture.py` | 16 个连续 tick 的 `live_event_*`，证明 1 音/tick 与边界对齐 |

L3/L4/L5 使用 `PRESERVE_LOOP_PLANE=0 / PRESERVE_POTTS_PLANE=0` 的功能位流
（现在这两个开关把触发源换成 `sample_index` 探针，CSR COMMIT 不会启动 Potts），
面积必须在同一配置下重测。

## 11. 资源预算（估算，须实测）

| 变更 | LUT | DSP | BSRAM |
| --- | --- | --- | --- |
| `v2_tick_gen` + BPM | +100 | – | – |
| LIVE 改 C（删 arm/edge/arc 逻辑） | −80 | – | – |
| 轮廓 RAM | +30 | – | +1 |
| Potts 8 音级 + 平方器 | +100 | +1 | – |
| COMMIT 序列器（A 形态） | +80 | – | – |
| velocity ROM | +20 | – | – |
| **合计** | **≈ +250** | **+1** | **+1** |

余量：CLS 491（11029/11520）、LUT 3024、BSRAM 20。CLS 会到 97% 附近。

## 12. 风险

1. DSP：平方器可能不止 +1，L3 实测；不够用移位加法。
2. 分块接缝（A 形态）：与全局 DP 的差异未知；验收要求"可解释"，不要求逐事件相等。
3. 旧文档的"41 µs"不可信：FSM 是 O(H³·K)，H=128 数十毫秒，H=32 约 1 ms/块。
4. PC 与板上坐标分叉：改全量程会破 `mgc3130_uart` 的现有测试与旧采集。
5. CLS 97%：P&R 可能变慢或违例。
6. C 模式没有力度起伏的第二种来源：velocity 只用 Z/speed（§8.3），节奏完全均匀。

## 13. 留给实现者

- tick 除法器复用光标 `u_div` 还是独立。
- 轮廓 RAM 用 BSRAM 还是 DPB。
- COMMIT 序列器状态机划分。
- velocity ROM 用 LUT RAM 还是 BSRAM。
- RECORD 期是否需要 tick 计数复位到 0（与 loop 相位对齐）。

## 14. 我替你定下的

1. LIVE = C，每 tick 强制一音，音高相同也重发。
2. 同 tick 内 `NOTE_OFF` + `NOTE_ON`，不用 `REVOICE`。
3. LOOP 固定 **8 小节 = 128 tick**，只录轮廓，一圈一录，无叠录。
4. 音高用 Y 全量程、最近邻、1 半音 = 3855 counts；滞回只用于 Potts。
5. RECORD 期静音；不把事件写进 store。
6. 文档放 `docs/` 平铺目录。

## 15. 待你定的三件事

**Q1 — Potts 形态**：A 5 块分块（+80 LUT，接缝要验收）还是 B `HORIZON=128` 一次跑完
（+1 DPB lane，COMMIT 数十毫秒）？我倾向 B。

**Q2 — PC 金标准与老仓库**：`v2_potts_reference.py`（5 音级、音符号域）还是
`synthwave_loop.py`（8 音级、半音域）？把轮廓换成 y 需要连误差项一起改，且改全量程会破
`mgc3130_uart` 的测试——允许改老仓库吗？

**Q3 — 事件表要不要 CSR 可读**：现在没有读口（store 端口 A 被调度器占用、端口 B 只写），
STATUS 也没有 commit 完成位。加读回窗口（未计入预算），还是接受 GAO + 仿真作为证据？
