# 波表三帧 morph 设计（A/B/C 当帧 + LFO 扫 position）

日期：2026-10-31
状态：**待审**（本文只做设计，未改任何 RTL）
范围：`mgc3130_clean`。§1–§8 是单声部 morph（WT_PLAY / LIVE）；§9 是下一阶段
"旁路表引擎"（32 声部读表），单独实施；§10 是与 LIVE/LOOP 的并行关系。

## 1 目标

把现有三张单周期表 A/B/C 重新解释为**一张波表的 3 帧**，由一个全局 LFO 驱动
`position ∈ [0, 2]` 在 A→B→C 之间来回扫，相邻两帧逐样本线性交叉淡化。听感是
"手绘音色在持续变形"，音高不变、无跳变、无爆音。

非目标（本轮不做）：

- 8/16 帧的大波表（要改 loader 寻址与上传语义，见 §8）；
- 相位插值（现在 `index = phase[31:22]` 仍是 10 bit 截断，量化杂散保留）；
- 每声部独立 position / LFO（32 声部读表见 §9，但 position 仍全局）；
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

**调试读回**：`0xE8`（仅 `V2_DEBUG_CSR=1`）低 10 bit 保持现状（`[7:0]` note、`[8]` gate、
`[9]` active），高 18 bit `[27:10]` 改放 `pos[25:8]`，其余补 0。宿主按 60 Hz 轮询即可
测出 LFO 周期——这是唯一能观测秒级行为的仪器（GAO 窗口只有 µs 级）。
现有脚本只解低 10 bit，不受影响；但按 skill 要求，此变更必须同步
`docs/DEBUG-AND-FLASH.md` 的调试表与 `host/cursor_view.py`。

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

## 6 验收（按 gowin-board-ops / gowin-fpga-debug 的证据纪律）

### 6.1 闸门与产物

| 层 | 命令 | 判据 | 产物 |
| --- | --- | --- | --- |
| L0 静态 | `python scripts/gate.py` | 无重名模块、单一顶层、filelist 内模块都被实例化 | 终端输出 |
| L1 编译 | `python scripts/gate.py --compile` | **0 error / 0 warning** | 编译日志 |
| L2 仿真 | `python scripts/sim.py` | 失败集 ⊆ `sim_baseline.json`，baseline 只缩不扩 | 回归日志 |
| L3 综合 | `python scripts/synth.py --run-id morph1` | `SYNTH: PASS`、**违约端点 0**、`synth_summary.json` 含 `bitstream_sha256` | `.fs` + summary |
| L4 协议 | 三帧上传 + 读回脚本 | 每个回包校验 SOF/seq/CRC/err，N 轮 + 负例 | 原始日志 |
| L5 波形 | `python scripts/gao_capture.py` | 抓到真实跳变，深度/时钟换算与报告一致 | `.csv` + `.rao` |

- **"P&R 过了" = 违约端点 0**，不是"生成了位流"。非 0 时所有功能观测只能标"暂定"，
  并把最差路径的起终点归属写进报告。
- 功能验证只用 `PRESERVE_LOOP_PLANE=0 / PRESERVE_POTTS_PLANE=0` 的位流；探针位流会在
  上电强跑一次 DP，留下卡音，制造"功能好了"的假象。

### 6.2 仿真用例（L2）

1. `tb/tb_wt_morph.sv`：强制 `pos = 0 / 2^23 / 2^24 / 3·2^23 / 2^25`，输出分别等于
   A、`(A+B)/2`、B、`(B+C)/2`、C，误差 ≤1 LSB；
2. `step=35`：方向翻转周期 `2^25/35` 样本 ±1；端点不越界；`dir` 每次只翻转一次；
3. `morph_en=0`：输出与改前**逐样本一致**（同表同相位）；
4. `frame_b` 的 `wt_active_valid=0` 时退回只用 `frame_a`；
5. `table0==table1`：两个读口输出相等，且该表只置一次 `mem_rd_en`（层次引用检查）；
6. 观测机制与板上一致：tb 直接看 `wt_read_sample0/1` 与混合结果，不经过 CSR。

### 6.3 上板前置（L4）

1. `.fs` 用绝对路径、`-Operation 4`，成功标志 `PROGRAM PASS`；烧完等 3–5 s；
2. **先读 `0xB0`**，必须 `0x5A5A0003`，否则停止——先排除位流/串口；
3. 打印基线寄存器并确认干净，再开始测试（脏基线曾直接造出"状态机卡死"的假结论）；
4. 记录位流 sha256、时间戳、源码 commit；未跑项列在报告末尾；
5. 脚本纪律：每个回包校验 `SOF=0x5A`、序号回显、CRC、`err`；失败非零退出；结束回 IDLE。

### 6.4 GAO（L5）

| 信号 | 位宽 | 用途 |
| --- | --- | --- |
| `clk_sys_100m`（`sample_clock`） | — | 真实 80 MHz（名字是历史遗留） |
| `pos[25:8]` | 18 | position 走向 |
| `frame_a` / `frame_b` | 2 + 2 | 帧选择 |
| `frac[7:0]` | 8 | 淡化系数 |
| `wt_read_sample0/1` | 16 + 16 | 两帧样本 |
| `morph_sample` | 16 | 混合结果 |

合计 78 bit，取 80 bit：`2048 × 80 = 163,840 bit ≈ 9 BSRAM`（36/56 → 45/56）；
降深到 1024 约 5 块，窗口 12.8 µs。

要点：

- `.rao` 必须含 `<Expressions type="Static"><Expression>M0</Expression></Expressions>`；
  构建后检查 `RTL_GAO/ao_0/gw_ao_expression.v` 首行是 `match[0]`，否则触发恒真、抓到静态窗口；
- `-out` 必须带 `.csv`，产物是 `<stem>_core0.csv`，可能晚几秒出现，要轮询；
- 窗口 = 深度 / 80 MHz，报告里写明；80 MHz 下 1 点 = 12.5 ns，不要用 CSV 的 `t` 推频率；
- 窗口内必须真的有一次 position 跨越 1.0（或一次 APPLY），否则 `change points = 0`；
- 按 CSV 表头解码列，不假设列序；
- GAO 与烧录共用 JTAG：先烧后抓。

**GAO 只回答µs 级的先后**；LFO 周期是秒级，用 §6.5 的 CSR 轮询，不要试图用 GAO 量。

### 6.5 板上功能判据

1. 上传正弦/锯齿/方波到 A/B/C，`morph_en=1`、`step=35`（20 s 扫一趟）：
   - 宿主 60 Hz 轮询 `0xE8[27:10]`，10 s 内 position 单调变化，方向翻转周期 20.6 s ±2%；
   - 扫表期间上传新帧（双 bank），无静音、无爆音；
2. 听感：无咔嗒；`frac≈128` 处不明显塌陷（相位对齐后）；
3. 回归：`WT_PLAY` 46.875 Hz、`THRESHOLDS[7:0]=69` → 440 Hz、CRC/APPLY 读回、
   IDLE 下 `WT_DATA` 逐点读回，全部照旧。

### 6.6 证据清单

- 位流 sha256 + 时间戳 + commit；
- `synth_summary.json`（违约端点 0）；
- L2 回归日志（失败集 ⊆ baseline）；
- 上传/读回脚本原始日志（含 `err` 字段，不只打印数据）；
- GAO `.rao` + `.csv` + 窗口/触发说明；
- 未跑项列表。

### 6.7 调试表与脚本同步

`WT_SELECT` 新语义与 `0xE8` 高位的新含义，必须同时更新 `docs/DEBUG-AND-FLASH.md`
的调试表和 `host/cursor_view.py`；`scripts/board_wt_upload.ps1` 末尾统一写一次
`WT_SELECT`。不同步 = 下一次板测按旧含义解读，等于没有证据。

## 7 风险

| 风险 | 对策 |
| --- | --- |
| 相位不对齐导致中点抵消 | host 相位对齐（§4.6）；残留的凹陷属正常听感，不做补偿 |
| 帧 B/C 未上传完整 | `wt_active_valid` 检查后退回 `frame_a` |
| 上传脚本清掉 morph 配置 | 脚本末尾统一写一次 `WT_SELECT` |
| `WT_SELECT` 语义变更 | 只影响 host 与文档；RTL 内无其他消费方（`bank/band/octave` 未使用） |
| 双读使 table 读带宽翻倍 | 单声部 2 读/样本；将来 32 声部为 64 读/样本，占 1667 周期预算 3.8% |
| `0xE8` / `WT_SELECT` 语义变更未同步脚本 | §6.7：同改调试表与 `cursor_view.py`，报告里标注新字段 |
| GAO 探针超 BSRAM | 先按 `2048×80 ≈ 9` 块算；装不下降到 1024 深（≈5 块，窗口 12.8 µs） |
| 用 GAO 量秒级 LFO 周期 | 不可能（窗口只有 25.6 µs）；周期一律用 `0xE8` 轮询测 |

## 8 升级路径

3 帧太粗时，把 loader 的 3 表 × 1024 换成单表 8 帧 × 512（8 BSRAM），position 数学不变
（`frame = pos[24:22]`，`frac` 取 8 bit），只改帧数与寻址。再往上（16 帧 / mipmap）需要
外挂 PSRAM，另立项目。

## 9 阶段 1.5：旁路表引擎（32 声部读表）

本节是 morph 的下一阶段，单独实施、单独验收；morph 本身不依赖它。

**为什么必须有它**：PLAY 走 32 声部引擎，引擎的振荡器是内部锯齿
（`oscillator_value` 用 `phase[31:16] − 32768`）。不接表，录好的 loop 一回放就变回锯齿，
手绘音色、帧序列、position 全部只存在于 LIVE。

**结构：不改扫描管线，旁路一个表引擎**

```
sample_ce
  ├─ 声部扫描（32 拍，原逻辑不动）
  │    读 bank → 计算 → 写回；计算时振荡器来源换成"样本缓冲[slot]"
  │    顺手把新相位 (phase_a, phase_b) 写进相位缓冲[slot]
  └─ 表引擎（扫描结束后 64 拍）
       相位缓冲[slot] → 两帧表读 → 交叉淡化 → 样本缓冲[slot]（下一个样本用）
```

- **相位缓冲**：32 × 64 bit（phase_a/phase_b），分布式 RAM，约 2 Kb；
- **样本缓冲**：32 × 32 bit（osc_a/osc_b 各 16 bit），一个 DPB lane，约 1 Kb；
- **表引擎**每声部 2 拍：第 1 拍两个读口分别读 `(frame_a, idx_a)` 与 `(frame_b, idx_a)`，
  第 2 拍读 `(frame_a, idx_b)` 与 `(frame_b, idx_b)`；`idx = phase[31:22]`；
- 淡化用的 position 与 `frac` **复用单声部那一个模块**，不写第二份。

声部引擎只改一处：

```verilog
calc_osc_sum <= attenuate(sample_buf[rd_slot].a, stage, gain, mix_a)
              + attenuate(sample_buf[rd_slot].b, stage, gain, mix_b);
```

`attenuate` 就是现有 `oscillator_value` 里那段 stage/velocity/mix 移位衰减，原样保留。

**读口所有权**

| 模式 | loader 读口 |
| --- | --- |
| IDLE | 旧端口给宿主读回（不变） |
| WT_PLAY / LIVE | 单声部路径（§4.3） |
| PLAY | 表引擎（两个新端口） |

模式互斥，按 `mode_reg` 选择；PLAY 下宿主读 `WT_DATA` 返回 0，文档写明。

**时序**：32（扫描）+ 64（表引擎）+ 2 拍流水 ≈ **100 拍/样本 = 6.0%**（1667 拍预算）。

**电平**：表是 0.9 FS，32 个声部直接求和必削顶。表引擎加固定缩放 `WT_VOICE_SHIFT`
（默认 4），板测按遥测 peak/RMS 校准到与现有引擎路径 **±3 dB** 以内。

**首样本**：缓冲初值 0，进入 PLAY 后第一个样本静音（20.8 µs），可接受。

**非目标**：每声部独立 position、每声部相位插值、真实 ADSR。
（备注：引擎算了 16 bit `envelope` 但从未参与振幅，衰减只按 stage 分档。要不要让它
真正生效是独立议题，会改变现有听感，不在本阶段。）

**验收**

1. 仿真：同一 position 下，32 声部逐声部输出与单声部参考一致（层次引用比对）；
2. 1/8/32 音 test mode 全部通过；
3. PLAY 中读 `WT_DATA` 返回 0（所有权规则）；
4. 板测：同一帧、同一 position 下，loop 回放与 LIVE 的频谱一致（±3 dB），
   切换模式无音量跳变；
5. 回归：单声部 morph、WT_PLAY、CRC/APPLY 全部照旧。

**工作量**：1.5–2 天（含验证）。主要风险是相位/样本缓冲的读写纪律，仿真容易抓。

## 10 与 LIVE / LOOP 并行

**逻辑上独立，物理上在同一个 `mgc3130_v2_top.sv` 汇合**：

| 汇合点 | morph | LIVE（进行中） | LOOP |
| --- | --- | --- | --- |
| `i2s_sample` / `i2s_sample_valid` 选择（[top:475](mgc3130_clean/rtl/mgc3130_v2_top.sv#L475)、[507](mgc3130_clean/rtl/mgc3130_v2_top.sv#L507)） | 加第三音源 | 加包络/模式条件 | PLAY 走引擎 |
| 读表口驱动（[top:706](mgc3130_clean/rtl/mgc3130_v2_top.sv#L706)） | 双口 + position | 不动 | 表引擎接管 |
| `WT_SELECT`（[top:838](mgc3130_clean/rtl/mgc3130_v2_top.sv#L838)、[957](mgc3130_clean/rtl/mgc3130_v2_top.sv#L957)） | 改高位 | 不动 | 不动 |
| CLS 余量 491 | +80…120 | +50 | +250 |

推荐顺序：**morph → LIVE 合并 → 阶段 1.5 表引擎 → LOOP**。
理由：morph 只碰读路径，面积可预测；表引擎把 PLAY 的音色补上之后，LOOP 才有意义；
CLS 三者相加约 400，必须等 morph 实测面积出来再排。

板测资源也排队：三帧上传、GAO 探针位流（9 块 BSRAM）、LIVE 调试共用同一个 COM4 和 JTAG。

## 11 我的默认决定（可推翻）

- LFO 是**全局自由运行**的，不随音符重触发：当前只有一条发声路径，per-voice 无意义；
  接 32 声部时再讨论 retrigger。
- LFO 波形用三角（来回扫），不做正弦/方波选择。
- `morph_en` 0→1 时 position 与方向复位，便于验收复现。
