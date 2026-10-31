# 输入消费的三条路径：缺口与耦合分析（2026-10-31）

## 1. 三条路径的现状

| 路径 | 输入来源 | 消费者 | 输出去向 |
| --- | --- | --- | --- |
| **LIVE** | 光标滤波器（`audio_cursor_*` 等散信号） | `v2_live_rule_engine` | `voice_event_*`（`mode_live`） |
| **LOOP** | 同上（**同一个** rule engine） | 录制：`v2_loop_event_store_dpb`；播放：`loop_event_*` | 录制存 DPB；播放进 `voice_event_*`（`mode_play`） |
| **波表** | **不消费输入** | `v2_wt_playback` | I2S（`mode_wt_play`） |

关键接线（`mgc3130_v2_top.sv`）：

```verilog
// 319: LIVE 与 RECORD 共用同一个 rule engine，ready 由模式决定
assign live_event_ready = mode_live ? voice_event_ready : mode_record ? record_event_ready : 1'b0;
// 310-311: 录制直接吃 rule engine 的事件流
.record_event_valid(live_event_valid), .record_event_ready(record_event_ready) ...
// 422-425: 三个事件源在声音引擎入口做模式三选一
assign voice_event_valid = mode_live ? live_event_valid : mode_play ? loop_event_valid : potts_event_valid;
assign loop_event_ready  = mode_play ? voice_event_ready : 1'b0;
assign potts_event_ready = (!mode_live && !mode_play) ? voice_event_ready : 1'b0;
```

## 2. 每条路径的缺口

### 2.1 LIVE

| 缺口 | 说明 |
| --- | --- |
| 字段错位 | `x/y/z/velocity/depth` 在 `sample_ce && stable_valid` 更新，而消费节拍是 `cursor_frame_done` |
| 静默丢帧 | `eval_*` 无条件装载、规则更新被背压挡住 → 帧被覆盖且无计数 |
| 门控与坐标不同源 | `touch/bow` 来自输入流水，比光标输出早若干拍 |

### 2.2 LOOP

| 缺口 | 说明 |
| --- | --- |
| **与 LIVE 共用规则引擎** | 只有一份 `v2_live_rule_engine`：录制时的映射**必然等于** Live 映射，无法"录一套、播另一套" |
| 录制背压冻结 Live 评估 | RECORD 模式下 `live_event_ready = record_event_ready`，录制写不进时规则状态直接停摆 |
| 播放侧无输入 | 播放阶段 `loop_event_*` 只回放历史事件，与当前光标**无关**（没有"边录边跟手"的通路） |
| 边界语义未定 | `loop_boundary` 与光标帧没有时间戳关联，跨边界的事件对齐靠 `tick` 隐式约定 |

### 2.3 波表

| 缺口 | 说明 |
| --- | --- |
| **完全不消费输入** | `v2_wt_playback` 只有 `sample_ce` + 固定相位，无 pitch/gate/位置输入 |
| 读口冲突 | 波表播放占用 loader 的唯一读口，与主机 1024 点回读互斥（已在 §19/§22 记录） |
| 无调制契约 | "用光标 y 控制音高、engaged 控制 gate"这类语义还没有定义 |

## 3. 耦合问题（结构性，不是接线问题）

1. **单规则引擎**：LIVE 与 LOOP 录制共用一份，二者在语义上被绑死；
2. **单事件端口 + 模式三选一**：声音引擎同一时刻只接受一个源，任何新消费者都要改这个 mux；
   ready 信号又被模式门控为 0，导致"没在用的路径"会把上游拖死；
3. **无扇出**：光标只有一个 1 拍 `frame_output_valid`，三条路径各自按信号名接线，
   于是错位被复制三份；
4. **读口共享**：波表播放与主机回读互斥；
5. **模式即仲裁**：`mode_reg` 同时决定"谁发声""谁录制""谁放表"，三种耦合叠在一个寄存器上。

## 4. 判断

- **加 FIFO 只能解决 LIVE 的丢帧**，解决不了"三路共用一个生产者/一个引擎/一个端口"的耦合；
- 真正需要的是**一次打包 + 广播**：光标帧广播给三个消费者，各自有独立的小缓冲（深度 2 即可，
  因为消费端都在 80 MHz、帧率 ≤138 Hz），生产者永不因某个消费者停顿而停摆；
- LOOP 必须先定语义：**录 Live 的事件**（tap 现有引擎）还是**独立映射**（需要第二份规则引擎）。
  这决定面积与接线，不能用实现细节掩盖。

## 5. 建议的接口形态

```
cursor filter ──[packed frame + valid]──┬──> LIVE 规则引擎（含 pop 门控 + drop 计数）
                                        ├──> LOOP 录制缓冲（可选：tap 引擎输出 或 独立引擎）
                                        └──> 波表调制（y→pitch, engaged→gate）[待定义契约]
```

每个消费者一个 2 深 skid 缓冲 + 自己的 `overflow` 计数；生产者侧只做广播，不等 ready。
这样"某一路忙"不会影响另外两路，也不需要把三个模式揉进一个 mux。

## 6. 需要先定的三件事

1. **LOOP 语义**：录 Live 事件，还是独立映射？
2. **波表消费什么**：y→音高、engaged→gate 是否就是目标语义？还是只用位置做音色调制？
3. **模式是否还要独占**：三路是否可以并存（例如波表垫底 + Live 主奏），还是继续三选一？
