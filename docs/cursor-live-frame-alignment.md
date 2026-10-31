# Cursor → Live 的时序错位分析与"打包成帧事件"评估（2026-10-31）

## 1. 现状：三层错位，不是一层

`v2_live_rule_engine` 的实例化（`mgc3130_v2_top.sv`）是这样接的：

```verilog
v2_live_rule_engine #(.PIPELINE_NOTE(1)) u_live (
  .frame_in_valid(cursor_frame_done),
  .x(audio_cursor_x[15:0]), .y(audio_cursor_y[15:0]), .z(audio_cursor_z[15:0]),
  .touch(calibrated_touch), .bow(calibrated_presence),
  .velocity_in(audio_velocity[7:0]), .brightness_in(audio_depth),
  ...
```

消费端在 `cursor_frame_done` 那一拍采样所有输入。问题是这些输入的**更新时刻根本不同**：

| 输入 | 更新条件 | 所在流水级 |
| --- | --- | --- |
| `frame_in_valid` (`cursor_frame_done`) | 每处理完一帧脉冲一次（~138 Hz） | 光标滤波输出 |
| `x/y/z`（`audio_cursor_*`） | **`sample_ce && stable_valid`**（48 kHz） | 光标滤波的 stable 分支 |
| `velocity_in`/`brightness_in` | 同上 | 同上 |
| `touch`/`bow` | 每个输入帧（`calibrated_*`） | 校准/输入流水 |

由此有三层错位：

1. **字段滞后**：`audio_cursor_*` 在 `sample_ce && stable_valid` 时才更新，而 `cursor_frame_done` 与它不同拍；最坏情况下（`stable_valid` 掉），字段会**一直冻结**，下游却仍在拿 `frame_in_valid` 当"新帧"。
2. **域不同**：`touch`/`bow` 来自输入流水，比光标输出早若干拍（中值滤波 + 除法器），同一拍采到的"触摸"和"坐标"可能属于不同帧。
3. **握手语义缺失**：`frame_in_valid` 是 1 拍脉冲，契约上没有定义"这一拍必须同时看到哪些字段"，于是每次改接线都可能悄悄破坏一致性。

这正是你说的"Cursor 输出和 Live 输入时序错位"——**根因是接口按信号接线，而不是按帧打包**。

## 2. 影响

- 事件（note on/off）携带的 `x/y/z/velocity` 可能是**上一帧**甚至**冻结值**；
- 门控（gate）与坐标不同源时，会出现"已经抬手但仍在发声"或"未抬手却触发"；
- 一旦下游再加一个消费者（Loop/Potts），每个消费者都要自己猜时序——错位会被复制。

## 3. 方案对比

### 方案 A（推荐）：光标帧寄存器 + 单一 valid

在 `cursor_frame_done` 那一拍**原子锁存**一个元组：

```verilog
typedef struct packed {
    logic [15:0] x, y, z;         // 光标坐标（滤波后）
    logic [15:0] pitch;           // normalized_pitch
    logic [15:0] velocity, depth; // 控制量
    logic [1:0]  state;           // DISENGAGED/ENGAGED/REBASED
    logic        engaged;         // 等价于 gate 的滤波后版本
    logic        touch, bow;      // 语义门控（本帧）
    logic        point_valid, rebased, stable_valid;
    logic [7:0]  reason;          // calibration_reason
    logic [15:0] sequence;        // 帧序号
    logic [31:0] tick;            // sample_index / timestamp
} v2_cursor_frame_t;
```

- `v2_cursor_frame_t frame;` + `logic frame_valid;`
- 在 `always_ff` 里 `if (cursor_frame_done) frame <= {…}; frame_valid <= cursor_frame_done;`
- Live/Loop/Potts 只在 `frame_valid` 那拍采样，且**只**从 `frame` 取字段。

成本：约 150 个 FF（当前 10,476 / 23,280，占比可忽略）。

优点：一个 valid、一个元组，语义自洽；新增消费者无需再猜时序；可复用为 Loop 录制的事件载荷。

### 方案 B（最小改动）：统一更新域

让 `audio_cursor_*` 改成**每 `sample_ce` 无条件**更新（去掉 `stable_valid` 门控），
并把 `touch/bow` 也寄存到同一域。改动 3–4 行。

缺点：仍然存在"帧脉冲与字段更新不同拍"的窗口（≤20 µs），只是把冻结问题去掉了；
契约上依旧没有"同帧"保证。

### 方案 C（不推荐）：下游各自加延迟对齐

每个消费者各自打拍延迟。错位被复制到每个消费者，且延迟值随内部实现变化，不可维护。

## 4. 结论

**应该打包。** 但要明确打包的是"**光标帧**"，不是"把现有信号挪到一起"：

- 锁存点必须选在 `cursor_frame_done`（光标滤波唯一的一帧结束点）；
- 元组必须**包含 gate 语义**（`engaged` 与 `touch/bow`），否则"坐标与门控不同源"的问题仍在；
- 下游只认 `frame_valid` + 元组，禁止再单独接 `audio_cursor_*`；
- `sequence`/`tick` 一起打包，便于对齐遥测与 Loop 录制。

## 5. 实施顺序（待批准）

1. 在 `v2_contract_pkg` 里定义 `v2_cursor_frame_t`；
2. `v2_cursor_filter_timed` 增加 `frame`/`frame_valid` 输出（在 `frame_output_valid` 同拍锁存）；
3. 顶层把 Live/Loop/Potts 改成从 `frame` 取字段；
4. 回归：`sim.py` 双 RAM + 板上光标显示（`host/cursor_view.py`）确认坐标与门控同步；
5. 文档：把该接口写进契约，禁止再直接接 `audio_cursor_*`。
