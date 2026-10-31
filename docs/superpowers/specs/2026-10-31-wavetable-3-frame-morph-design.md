# 波表三帧 morph 设计（A/B/C 当帧 + LFO 扫 position）

日期：2026-10-31
状态：**待审**（本文只做设计，未改任何 RTL）
范围：`mgc3130_clean`，单声部波表路径（WT_PLAY / LIVE）

## 1 目标

把现有三张单周期表 A/B/C 重新解释为**一张波表的 3 帧**，由一个全局 LFO 驱动
`position ∈ [0, 2]` 在 A→B→C 之间来回扫，相邻两帧逐样本线性交叉淡化。听感是
"手绘音色在持续变形"，音高不变、无跳变、无爆音。

非目标（本轮不做）：

- 8/16 帧的大波表（要改 loader 寻址与上传语义，见 §8）；
- 相位插值（现在 `index = phase[31:22]` 仍是 10 bit 截断，量化杂散保留）；
- 每声部独立 position / LFO（32 声部引擎还没读表）；
- mipmap / 带限、position 跟 Z 或力度。

## 2 现状（代码事实）

| 事实 | 位置 |
| --- | --- |
| 3 张表 × 2 bank × 1024 × 16 bit，共 6 BSRAM | `rtl/v2_wavetable_loader.sv:51` |
| loader 只有一个逻辑读口：`wt_read_table` / `wt_read_index → wt_read_sample`（DPB 输出寄存 1 拍，之后按**当前** table 选择） | `v2_wavetable_loader.sv:190-197, 213-215` |
| 播放：`index = phase[31:22]`，无插值 | `rtl/v2_wt_playback.sv:35` |
| LIVE / WT_PLAY 都走这条单声部路径 | `rtl/mgc3130_v2_top.sv:475, 507, 694-698` |
| 32 声部引擎不读表（`oscillator_value` 用内部锯齿） | `rtl/v2_voice_engine_banked.sv:319` |
| `WT_SELECT` 的 bank/band/octave 字段只写不读 | `mgc3130_v2_top.sv:838-840, 957-958` |
| 8 bit CSR 地址已排满（0x00–0xFF 全部占用，A0–AF 为 test 窗口） | `rtl/v2_contract_pkg.sv:115-137` |
| 当前资源：CLS 11029/11520、LUT 20016/23040、BSRAM 36/56、DSP 8 | `docs/system-design-2026-10-31.md:7, 227-230` |

## 3 备选方案与选择

| 方案 | 存储 | 工作量 | 结论 |
| --- | --- | --- | --- |
| **A：A/B/C 当 3 帧（选定）** | 0 新增 | 1 天 RTL + 0.5 天验证 + 0.5 天 host | 复用已验证的上传/CRC/APPLY/双 bank |
| B：单表 8 帧 × 512 点 | +8 BSRAM | 2–3 天 | 需改 loader 寻址与上传语义 |
| C：仅 A/B 两表淡化 | 0 | 半天 | 不是帧序列，达不到"N 帧变形" |

选 A 的理由：**帧的存储、校验、切换全部复用现成链路**，新代码只有"position 累加 +
第二读口 + 交叉淡化"。A/B/C 各自双 bank 还在，扫表过程中可以继续上传新帧，不打断发声。
代价是只有 3 帧，且中间音色永远是相邻两帧的线性混合。

## 4 设计

### 4.1 帧语义

- 帧 0 = 表 A（`WT_SELECT[1:0]=0`），帧 1 = 表 B，帧 2 = 表 C。
- 上传语义完全不变：host 仍按现有 `WT_SELECT` + `WT_INDEX` + `WT_DATA` + `WT_CRC` +
  `WT_VERSION` + `WT_APPLY` 逐表上传；三张表分别对应三帧。
- 建议三帧按一条演化线画（暗→中→亮），否则扫过去像"穿行于三个音色"而非"一个音色在变形"。

### 4.2 position 与帧索引

position 用 Q2.24 定点，`1.0 = 2^24`，范围 `0 .. 2^25`（=2.0）：

```
pos[25:0], step[22:0]  (Q2.24)
每个 sample_ce（48 kHz）：
  up:   pos >= 2^25 - step ? (pos <= 2^25, dir <= down) : pos <= pos + step
  down: pos <= step        ? (pos <= 0,    dir <= up)   : pos <= pos - step
frame_a = pos[25:24]                       // 0,1,2
frame_b = (frame_a == 2) ? 2 : frame_a + 1
frac    = pos[23:16]                       // 8 bit
```

端点处两帧相同、`frac=0`，输出连续；`morph_en` 0→1 时 `pos`、方向复位，保证可复现。

### 4.3 读取：给 loader 加第二读口

现有单口按**当前** table 做输出 mux（DPB 输出比地址晚 1 拍），表号变化时会取到旧字，
所以不能靠"每拍换表号"实现双读。改为：

```
新增输入： wt_read_table0/1 [1:0], wt_read_index0/1 [9:0]
新增输出： wt_read_sample0/1 [15:0]
读使能：   mem_rd_en[ct][bank] = (ct == table0) || (ct == table1)
读地址：   mem_rd_addr[ct][bank] = (ct == table1) ? index1 : index0
输出：     用寄存后的 table0_q / table1_q 选择 mem_rd_data（保持 1 拍延迟）
```

- 两张表是各自独立的 DPB，**同时读不同表不冲突**；
- `table0 == table1` 时该表只置一次读使能，两个输出相同；
- 原 `wt_read_table/wt_read_sample` 端口保留，IDLE 的 host 读回路径一字不改。

top 在 morph 模式下把两个读口都指向 `wt_play_index`，输出：

```
sample = sample0 + ((sample1 - sample0) * frac) >>> 8     // 1 DSP
```

`morph_en=0` 时 `table0 = table1 = wt_select_table`，`sample0` 即旧路径，行为逐字节不变。

### 4.4 寄存器：复用 `WT_SELECT`（0x60）

8 bit 地址空间已满，且 `bank/band/octave` 只写不读，因此重定义高位：

| 位 | 旧语义 | 新语义 |
| --- | --- | --- |
| `[1:0]` | 表号（上传目标） | 不变 |
| `[8]` | bank（未使用） | `morph_en` |
| `[15:9]` | band/octave（未使用） | `lfo_step[6:0]` |
| `[31:16]` | 未使用 | `lfo_step[22:7]` |

即 `WT_SELECT = {lfo_step[22:0], 7'd0, morph_en, 7'd0, table[1:0]}`。

- `V2_CSR_WT_SELECT_WRITE_MASK`：`0x0000FF07` → `0xFFFFFF07`；
- `v2_csr_data_valid(WT_SELECT)` 仍只校验 `data[2:0] <= 2`；
- 读回返回写入值（`{lfo_step, 7'd0, morph_en, 7'd0, table}`）；
- `wt_select_bank/band/octave` 三个寄存器删除。

host 计算 `step = round(2^25 / (period_seconds × 48000))`。例：20 s → 34.9 → 35；
1 s → 699；0.1 s → 6991。LFO 周期 = `2^25 / step / 48000` 秒。

注意：上传脚本现在会写 `WT_SELECT = table`，会把 `morph_en/step` 清零。上传流程必须
改成"上传三张表 → 最后写一次 `WT_SELECT`（table + morph_en + step）"。

### 4.5 模式行为

| 模式 | 读口 | 输出 |
| --- | --- | --- |
| IDLE | 旧端口（`wt_select_table` + `wt_select_index`） | 不发声；host `WT_DATA` 读回不变 |
| WT_PLAY | 双口，index = `wt_play_index`，table 由 position 定 | 交叉淡化结果 |
| LIVE | 同上（音高仍来自 `live_active_note`） | 交叉淡化结果，再乘 LIVE 包络 |
| PLAY | 不变（32 声部引擎不读表） | 引擎输出 |

若 `frame_b` 对应的表未通过 CRC/APPLY（`wt_active_valid` 为 0），**退回只用 `frame_a`**，
避免淡到半张空表。

### 4.6 host：三帧 + 相位对齐

1. 三次抓取，各自跑 `host/wavetable_from_capture.py` 得到 1024 点表；
2. **新增相位对齐**：对每帧做 DFT，取基波（k=1）相位 θ，把整帧旋转 −θ（等价于把基波
   相位归零、保留各次谐波相对相位），再限带 32 谐波、峰值归一；
3. 按现有协议上传 A/B/C（可复用 `scripts/board_wt_upload.ps1` 三次）；
4. 写 `WT_SELECT` 开启 morph。

相位对齐是必须的：三帧来自不同手势，基波相位任意；直接线性混合时若相差接近 180°，
中间位置会抵消（变薄、掉音量）。这一步约 30 行 Python，不占 FPGA 资源。

## 5 资源预算

| 项 | 估计 | 依据 |
| --- | --- | --- |
| loader 第二读口 | +40…60 LUT | 3 表 × 2 bank 的读使能/mux 复制 |
| LFO + 交叉淡化 | +120…160 LUT、1 DSP | 26 bit 加减、16×8 乘加 |
| 寄存器/CLS | +80…120 CLS | 余量 491 |
| BSRAM | 0 | 复用 |

DSP 从 8 增到 9（器件上限按综合报告为准，当前 8/… 未满）。

## 6 验收

**仿真（L0/L1）**

1. `gate.py --compile` 0 error / 0 warning；
2. 新增 `tb/tb_wt_morph.sv`：强制 `pos = 0 / 2^23 / 2^24 / 3×2^23 / 2^25`，输出应分别等于
   A、`(A+B)/2`、B、`(B+C)/2`、C，误差 ≤1 LSB；
3. `step=35` 时，方向翻转周期 = `2^25/35` 样本 ±1；端点不越界；
4. `morph_en=0` 时输出与改前**逐样本一致**（同表同相位）。

**上板（L4/L5）**

5. 上传正弦/锯齿/方波到 A/B/C，morph 开，LFO 20 s：GAO 抓 I2S，position 每过 0.5 应看到
   波形逐点向下一帧靠拢；听感无咔嗒、无音量塌陷；
6. 上传期间扫表不中断（双 bank）；
7. 回归：`WT_PLAY` 46.875 Hz 用例、`THRESHOLDS[7:0]=69` 的 440 Hz 用例、CRC/APPLY 读回
   全部照旧。

## 7 风险

| 风险 | 对策 |
| --- | --- |
| 相位不对齐导致中点抵消 | host 相位对齐（§4.6）；残留的凹陷属正常听感，不做补偿 |
| 帧 B/C 未上传完整 | `wt_active_valid` 检查后退回 `frame_a` |
| 上传脚本清掉 morph 配置 | 脚本末尾统一写一次 `WT_SELECT` |
| `WT_SELECT` 语义变更 | 只影响 host 与文档；RTL 内无其他消费方（`bank/band/octave` 未使用） |
| 双读使 table 读带宽翻倍 | 单声部 2 读/样本；将来 32 声部为 64 读/样本，占 1667 周期预算 3.8% |

## 8 升级路径

3 帧太粗时，把 loader 的 3 表 × 1024 换成单表 8 帧 × 512（8 BSRAM），position 数学不变
（`frame = pos[24:22]`，`frac` 取 8 bit），只改帧数与寻址。再往上（16 帧 / mipmap）需要
外挂 PSRAM，另立项目。

## 9 我的默认决定（可推翻）

- LFO 是**全局自由运行**的，不随音符重触发：当前只有一条发声路径，per-voice 无意义；
  接 32 声部时再讨论 retrigger。
- LFO 波形用三角（来回扫），不做正弦/方波选择。
- `morph_en` 0→1 时 position 与方向复位，便于验收复现。
