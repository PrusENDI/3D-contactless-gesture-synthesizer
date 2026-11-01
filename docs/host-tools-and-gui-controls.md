# 上位机程序与板级控制面（GUI 设计输入）

> 口径：以工作区当前源码为准（`rtl/v2_contract_pkg.sv`、`rtl/mgc3130_v2_top.sv`、`rtl/v2_board_top.sv`），
> 与最新进度文档 `docs/progress-2026-11-01.md`（HEAD `770ea9a`）一致。历史脚本/旧文档只作对照。
>
> 目的：把所有**能从 PC 控制或观测的东西**列全，作为把这些选项收进单一 GUI 的输入。
> 每一节都标注了"板上验过 / 只有仿真 / 未验证"，GUI 不要给未验证的项做"保证可用"的措辞。

---

## 0. 一句话结论

控制面分三层：

1. **串口 CSR**（唯一真正的控制通道）：`V2_OP_READ/WRITE` + 8 位地址，读写 32 位字，全部落在
   `rtl/v2_contract_pkg.sv` 的地址表里；
2. **多步工作流**（脚本封装）：上传/APPLY、录制/提交/发布、PLAY/STOP、遥测、测试模式——
   这些不是单条 CSR，而是一段有前置条件与轮询判据的序列；
3. **文件与显示**（PC 侧）：波表 .bin/.json、轨迹 .jsonl、GAO CSV、光标窗口。

GUI 要做的本质是把 1 做成"控件"、把 2 做成"按钮 + 状态机"、把 3 做成"文件选择 + 视图"。

---

## 1. 上位机程序清单

### 1.1 构建与验证（Python，不碰硬件）

| 程序 | 行数 | 用途 | 入参 / 输出 |
| --- | --- | --- | --- |
| `scripts/bootstrap.py` | 330 | 从固定 revision 生成干净源码树 | 一次性迁移工具，日常不用 |
| `scripts/gate.py` | 197 | 静态闸门 + `--compile`（ModelSim，警告算失败） | 输出 `GATE: PASS` / 0 error 0 warning |
| `scripts/sim.py` | 168 | 编译 + 跑 `tb_sim_top`，RAM=0/1 双跑，比对 `sim_baseline.json` | 现在基线 **13 pass / 4 fail**，且要求两模式逐条一致 |
| `scripts/sim_unit.py` | 92 | 编译 filelist + 单个 tb，要求行首 PASS | `--tb <name>`；日常改代码用它 |
| `scripts/synth.py` | 183 | 唯一综合入口：由 `filelist.f` 生成 `.gprj`，`--gao` 出探针位流 | 打印资源、`bitstream_sha256`；**时序摘要解析有 bug，数字要手读 `.tr`** |
| `scripts/test_potts_plane.py` | 54 | 一条命令跑阶段 2 的 8 个仿真 + 7 项参考测试 | `POTTS PLANE: PASS` |
| `scripts/gao_capture.py` | 144 | 按 `.rao` 抓 GAO 并解码成 CSV | `--rao` / `--out`；需先烧探针位流，且与烧录共用 JTAG |

### 1.2 板级脚本（PowerShell，串口 COM4 @ 1 Mbaud）

**主线（GUI 会直接复刻这些流程）**

| 脚本 | 工作流 | 关键参数 |
| --- | --- | --- |
| `board_wt_upload.ps1` | 上传一张 1024 点表 + CRC/版本/APPLY | `-Bin -Table -Version -PostSelect -DryRun` |
| `board_wt_morph.ps1` | 三帧一起上传 + 写 `WT_SELECT`（LFO 周期→step） | `-Frame0/1/2 -Period` |
| `board_readback.ps1` | 上传后逐点读回 1024 点比对 | 输出 `1024/1024 match` |
| `board_stage2_loop.ps1` | 录一轨/多轨 → 提交 → 发布 → 播放 → STOP 静音 | `-Tracks N -WaitSeconds` |
| `board_wt_voice_play.ps1` | 阶段 1.5：上传正弦表 → 录一轨 → PLAY 回放 → 查 `WT_DATA=0` | `-Bin -Table -Shift -SkipRecord` |
| `board_cursor.ps1` | 打开遥测帧并打印 x/y/z | `-Period -Seconds` |
| `board_live_mode.ps1` | 切 LIVE 规则（`THRESHOLDS[23]`：0 追踪 / 1 琶音） | `-Mode arp\|track -Note -Live` |
| `board_live_visual.ps1` | LIVE + 上传表 + 开遥测，配合 `cursor_view.py` | — |

**一次性探针（排障用，GUI 里可作为"诊断"页）**

| 脚本 | 回答的问题 |
| --- | --- |
| `board_coord_probe.ps1` | 原始坐标 vs 光标坐标（`0xDC/0xFC` vs `0xF0/0xD8`） |
| `board_input_diag.ps1` | 输入链存活（reports / errors / cursor_valid 增量） |
| `board_cursor_trace.ps1` | 光标逐级计数 |
| `board_live_path.ps1` | LIVE 出音（events / active / gate / note） |
| `board_loop_probe.ps1` | `0xF8` 三页探针（调度器 / 提交写口 / 声部分配） |
| `board_apply_once.ps1` | 上传 + APPLY 一次，给 GAO 触发用 |

### 1.3 数据 / 算法 / 显示（Python）

| 程序 | 作用 | 备注 |
| --- | --- | --- |
| `host/cursor_view.py` | 唯一 GUI（Tk）：读 22 B 遥测帧画光标；`--console-only`；`--flip none\|x\|y\|both`（默认 `y`） | **独占 COM4** |
| `host/wavetable_from_capture.py` | 轨迹 `xy.jsonl` → 1024 点单周期表（弧长相位、y 取幅、去 DC、0.9 FS、限带 32 谐波） | `--phase arc\|time\|x`、`--selftest`；纯标准库 |
| `host/wavetable_frames.py` | N 张单周期表 → 相位对齐多帧 + `frames.json` | morph 用 |
| `host/wavetable_sine.py` | 生成正弦/方波/锯齿测试帧 | 阶段 1.5 验收用的表 |
| `host/v2_potts_reference.py` | Potts 定点参考（y 空间 `LEVELS` + MIDI `NOTES`） | 与硬件同表 |
| `host/test_v2_potts_reference.py` | 上述参考的 7 项回归 | 被 `test_potts_plane.py` 调用 |

### 1.4 仓库外但流程必需

- **烧录**：`mgc3130_uart/.worktrees/v2-integration/scripts/board_program.ps1 -FsFile <impl/.../*.fs> -Operation 4`，
  烧完等 3–5 s 读 `0xB0` 必须为 `0x5A5A0003`。
- 工具链：ModelSim `vlog/vsim`、Gowin `gw_sh`、GAO（JTAG 与烧录互斥）。

---

## 2. 串口协议（GUI 的传输层）

命令帧 11 字节：

```
A5 02 op addr seq d31..d24 d23..d16 d15..d8 d7..d0 crc_hi crc_lo
op: 0x01 READ, 0x02 WRITE        CRC16/CCITT-FALSE, init 0xFFFF, 覆盖前 9 字节
```

应答帧 22 字节（与遥测帧同长同前缀，容易混）：

```
[0]=0x5A  [1]=0x02  [2]=0x80 ACK / 0x81 NACK  [4]=seq 回显
[11]=status  [12]=terminal  [14..17]=data(big endian)  [19]=err  [20..21]=CRC(前 20 字节)
```

错误码（`err` 字节）：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| 0x00 | NONE | 成功 |
| 0x01 | BAD_CRC | 帧 CRC 错 |
| 0x02 | BAD_ADDRESS | 地址非法/不可用 |
| 0x03 | BAD_VERSION | 协议版本不对 |
| 0x04 | BAD_LENGTH | 长度不对 |
| 0x05 | SEQUENCE | seq 重复/不匹配 |
| 0x06 | BAD_OP | 操作码非法 |
| 0x07 | BAD_DATA | 数据越界/写入被拒（如 `WT_DATA` 写不进去） |
| 0x08 | VERSION | 版本不匹配 |
| 0x09 | INCOMPLETE | 表不完整 |
| 0x0A | WT_CRC | 表 CRC 不符 |
| 0x0B | OVERFLOW | 溢出 |
| 0x0C | TIMEOUT | 超时 |

GUI 必须：**每条命令递增 seq 并校验回显**、校验帧 CRC、超时（≥400 ms）报错、失败即中止当前工作流。

---

## 3. CSR 总表

### 3.1 状态与模式

| 地址 | 名称 | 访问 | 写掩码 | 值域/校验 | 写入效果 | 读回 |
| --- | --- | --- | --- | --- | --- | --- |
| 0x00 | STATUS | RO | 0 | — | — | `{…, fault(9), loop_active_valid(8), mode[2:0]}` |
| 0x04 | MODE | RW | 0x7 | `≤6` | 写 RECORD(2) 拉 `record_start`；写非 RECORD 拉 `record_stop` | **恒 0（读不到模式，读 STATUS[2:0]）** |
| 0x08 | BPM | RW | 0xFFFF | 60..240 | 重装分频器；LIVE 下被 X→BPM 覆盖 | `{16'd0, bpm}` |
| 0x0C | TRACK | RW | 0x7 | `≤5` | 设 `selected_track`（录制/提交/探针选中轨） | 无（读 0） |
| 0x14 | STOP | WO | 0x1 | `data==1` | `mode←IDLE`、`record_abort`、store ABORT、`record_stop` | — |

模式枚举：`0 IDLE, 1 LIVE, 2 RECORD, 3 COMMIT, 4 PLAY, 5 ERROR, 6 WT_PLAY`。

### 3.2 LOOP / Potts

| 地址 | 名称 | 访问 | 写掩码 | 值域/校验 | 写入效果 / 读回 |
| --- | --- | --- | --- | --- | --- |
| 0x18 | RECORD | WO | 0x1 | `data==1` | `PREPARE_RECORD(选中轨)` + 轮廓采集 arm + `record_stop` |
| 0x1C | OVERDUB | WO | 0x1 | `data==1` | `PREPARE_OVERDUB`（复制 active→shadow 且**不清**该轨） |
| 0x20 | CLEAR_TRACK | WO | 0x107 | 低 3 位=轨号（写入即触发；掩码含 bit8，但顶层不检查，也不要求 `data==1`） | 清 shadow 该轨计数 |
| 0x24 | CLEAR_ALL | WO | 0x1 | `data==1` | 清 shadow 全部轨计数 |
| 0x28 | COMMIT | WO | 0x1 | `data==1` | 锁存 `commit_track` → PREPARE → Potts DP → 写入 shadow → `COMMIT_REQUEST`（等下一个 loop 边界发布） |
| 0x30 | THRESHOLDS | RW | 0xFFFFFFFF | 要求 `data[15:0] < data[31:16]` | `[7:0]`=WT_PLAY 测试音符（0=46.875 Hz 旧行为）、`[23]`=LIVE arp 模式；`[31:16]` **未使用**（λ 已挪到 0x3C） |
| 0x34 | CONTOUR_DATA | RW | 0x1F | — | 写=设轮廓读指针（**同时是 0xF8 探针页选择器**）；读=该点轮廓值并把指针 +1 |
| 0x38 | POTTS_STATUS | RO | 0 | — | `[0]commit_done [1]busy [2]overflow [3]commit_timeout [4]capture_full` |
| 0x3C | POTTS_LAMBDA | RW | 0xFFFF | — | Potts λ，默认 21600 |

### 3.3 音色：波表（可用）与 patch bank（只存储）

| 地址 | 名称 | 访问 | 写掩码 | 值域/校验 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 0x60 | WT_SELECT | RW | 0xFFFFFFF7 | `data[2:0] ≤ 2` | `[1:0]`表(0..2) `[7:4]`声部 shift 0..15（默认 **2**） `[8]`morph_en `[31:9]`LFO step；`step = round(2^25/(周期s×48000))` |
| 0x64 | WT_INDEX | RW | 0xFFFF | `<1024` | 同时装上传指针 `wr_ptr` |
| 0x68 | WT_DATA | RW | 0xFFFF | — | 写=样本（索引自增）；读=当前索引样本（**PLAY 中返回 0**；WT_PLAY 中返回正在播放的样本） |
| 0x6C | WT_LENGTH | RW | 0xFFFF | `==1024` | 只支持 1024 |
| 0x70 | WT_CRC | RW | 0xFFFF | — | 期望 CRC（MSB-first 两字节/样本） |
| 0x74 | WT_VERSION | RW | 0xFFFF | — | 三方匹配用的 WT_VERSION 寄存器 |
| 0x78 | WT_APPLY | WO | 0x8000FFFF | `data[31]==1` | 提交位 + 版本；成功条件：版本三方一致、表完整、CRC 匹配；**只在 idle 或 loop 边界翻 bank** |
| 0x7C | WT_STATUS | RO | 0 | — | `[31:24]`err、`[17]`apply_busy、`[16]`shadow_valid、`[15:0]`active_version |
| 0x48 | PATCH_SELECT | RW | 0x0000FF1F | family/track/index 组合校验 | `family[1:0]` `track[4:2]` `index[15:8]` |
| 0x4C | PATCH_SHADOW_DATA | RW | 0xFFFFFFFF | `v2_patch_value_valid`（每个参数各自 MIN/MAX） | 写 shadow 参数 |
| 0x50 | PATCH_ACTIVE_DATA | RO | 0 | — | 读当前生效参数 |
| 0x54 | PATCH_STATUS | RO | 0 | — | `{last_error[31:24], apply_busy, crc_ok, shadow_dirty, active_version[15:0]}` |
| 0x58 | PATCH_CRC | RW | 0xFFFF | — | 期望 CRC |
| 0x5C | PATCH_APPLY | WO | 0x8000FFFF | `data[31]==1` | 版本[15:0] + 提交位 |

> **注意**：patch bank（0x48–0x5C）目前只做"存储 + CRC + APPLY + 回读"，`u_patch_bank` 的输出
> **没有接进音频路径**。GUI 里如果要给 patch 编辑做界面，要明确标注"硬件未接线"。

### 3.4 遥测

| 地址 | 名称 | 访问 | 写掩码 | 说明 |
| --- | --- | --- | --- | --- |
| 0x80 | TLM_CONTROL | RW | 0xFFFF0001 | bit0 开流；`[31:16]` 周期（音频采样数，0→2400，约 20 Hz）；读回原值 |

遥测帧固定 22 字节：`5A 02 01 seq[2] x[2] y[2] z[2] … CRC`（x/y/z 大端）。与 ACK 帧同长，
靠 `[2]==0x01` 区分。

### 3.5 测试模式（生产位流里**已编译掉**）

| 地址 | 名称 | 访问 | 写掩码 | 说明 |
| --- | --- | --- | --- | --- |
| 0xA0 | TEST_SELECT | RW | 0xFFFFFFFF | selector=`wdata[7:0]`：**1 = N-tone**，N=`wdata[13:8]`（1..32，0=关闭）；读回 `{tone_count, 18'd0, selector}` |

> **生产位流不含这个块**：`v2_board_top` 传 `USE_TEST_MODE(0)`（约 2500 LUT / 1150 寄存器，
> 比整条单声部 LIVE 出口还贵）。因此生产板上写 0xA0 会被 ACK 但**没有效果**，读回 0。
> 需要 1/8/32 音测试时单独出一个位流（把 `v2_board_top.sv` 里 `USE_TEST_MODE` 改成 1），
> 或直接用 `tb_voice_engine_banked` / `tb_wt_voice_poly` 的仿真证据。

> `test_active` 时音频输出被测试音**取代**（`i2s_sample = test_active ? test_sample : fx_quiet`），
> GUI 必须把它做成"互锁"开关。实现只占 0xA0，其余 `0xA4..0xAF` 写入会被 ACK 但无效果。

### 3.6 只读调试寄存器（`V2_DEBUG_CSR=1`，生产位流默认就是 1）

| 地址 | 内容 |
| --- | --- |
| 0xA4 | `apply_reject_reason[1:0]` |
| 0xA8 | `expected_crc_captured[15:0]` |
| 0xAC | `apply_version_seen[15:0]` |
| 0xB0 | 身份常量 `0x5A5A_0003` |
| 0xB4 | 表状态机 `[1:0]` |
| 0xB8 / 0xBC / 0xC0 / 0xC4 | 上传 accepted / covered 位图 / covered_count / wr_ptr |
| 0xC8 / 0xCC | rejected 计数 / CRC 计算终值 |
| 0xD0 | 传感器 report 计数 |
| 0xD4 | LIVE 事件计数 `[15:0]` |
| 0xD8 / 0xF0 | `cursor_y` / `cursor_x` |
| 0xDC / 0xFC | 原始 `raw_x` / `raw_y`（有符号） |
| 0xE0 | `cursor_last_z` |
| 0xE4 | 光标状态机 `[4:0]` |
| 0xE8 | `{4'd0, wt_pos[25:8], live_active, live_gate, live_active_note[7:0]}` |
| 0xEC | 传感器帧计数 |
| 0xF4 | reader 状态 `[5:0]` |
| 0xF8 | **分页探针**，页码由写 `0x34` 选择（0/1/2），见下 |

`0xF8` 三页：

| 页 | 位域 |
| --- | --- |
| 0 | `[9:2]`调度器状态 `[1:0]`声部 busy |
| 1 | `[0]`capture_full `[1]`purify_done `[2]`dp_run `[3]`dp_done `[4]`dp_busy `[5]`store_busy `[6]`commit_pending `[7]`write_ready `[8]`write_valid `[9]`ctrl_pending `[14:10]`write_slot `[20:15]`轨0 shadow 计数 `[26:21]`本次提交事件数 |
| 2 | `[15:0]`steal 计数 `[16]`voice_overflow `[22:17]`active_voice_count `[24:23]`声部 busy |

### 3.7 音频链：滤波 / LFO / 效果器 / 主音量（P2a）

| 地址 | 名称 | 访问 | 写掩码 | 值域/校验（clamp） | 说明 |
| --- | --- | --- | --- | --- | --- |
| 0x40 | FILTER | RW | `0x010FFFFF` | ci ≤ 423、res ≤ 255 | `[11:0]` 截止索引 ci（1/48 八度，一极点 `fc = 40·2^(ci/48)`，4 极点 −3 dB ≈ 0.43·fc）、`[19:12]` 共振 res（`K = res·3.75/256`，相对 DC 峰值 0…28 dB）、`[24]` 使能。**默认 0 = 旁路** |
| 0x44 | LFO | RW | `0x3FFFFFFF` | rate ≤ 20000、depth ≤ 255 | `[15:0]` 速率 mHz（50…20000，即 0.05…20 Hz）、`[23:16]` 深度（ci 单位，最大 255 = ±5.3 八度）、`[24]` 使能、`[25]` 重触发（进 PLAY 时相位归零）、`[26]` 单极（只在设定截止之上调制）、`[29:27]` 波形（0 三角 1 正弦 2 锯齿 3 方波 4 随机 S&H）。默认全 0 |
| 0x84 | FX_A | RW | `0x001FFFFF` | gain ≤ `0x10000` | `[17:0]` 增益 Q16、`[19:18]` 档位、`[20]` 使能。复位 = 编译配置（板上 `0x0015_0000`，tb 里 `0x0001_0000`） |
| 0x88 | FX_B | RW | `0xFFFF03FF` | cutoff 任意 | `[9:0]` 延迟采样数（**实际延迟 = 该值 + 1 拍**，读口寄存了一级）、`[31:16]` 内部一极点系数 Q16。默认 `0xFFFF_0000` |
| 0x8C | FX_C | RW | `0xFFFFFFFF` | feedback ≤ `0x7333`、mix ≤ `0x7FFF` | `[15:0]` 延迟反馈 Q15、`[31:16]` 梳状混合 Q15。默认 0 |
| 0x90 | VOLUME | RW | `0x0003FFFF` | ≤ `0x20000` | 主音量 Q1.16，`0x10000` = 1.0（默认，**逐位透明**），上限 2.0；之后接饱和器 |

四条必须写清的：

- **只有 PLAY 经过效果器**：`v2_fx_lite` 挂在 `fx_quiet` 那一支，LIVE 与 WT_PLAY 不走它。
- `FX_A` 的增益与 `FX_B` 的 cutoff **不受 `[20]` 使能管**：使能为 0 时档位强制为 0（干声），但增益与内部低通照样生效——所以增益的复位值必须是 1.0，写 0 会让 PLAY 变哑。
- `fx_level`（档位）**不是混合量**：0 干、1 加内部低通、2 再叠延迟、3 再叠梳状（混响感）。
- **掩码外的位由链路判 `BAD_DATA(0x07)`**，不进入 clamp；clamp 只处理掩码**内**的越界值（例如 ci 12 位写 0xFFF → 夹到 423）。

### 3.8 契约里有、顶层**未实现**（GUI 不要暴露，或标灰并注明）

| 地址 | 名称 | 现状 |
| --- | --- | --- |
| 0x10 | PLAY | 无任何处理；进 PLAY 只能用 `MODE=4` |
| 0x2C | RESET | 只进 `cmd_is_abort`，**没有动作**（"复位"请用 `STOP` + `CLEAR_ALL`） |
| 0x94 / 0x98 / 0x9C | ENV_AD / ENV_SR / VOICE_MIX | P2b 才实现，现在写入判 `BAD_ADDRESS(0x02)` |

> **名字变动（P2a）**：`TLM_STATUS / LATENCY / PEAK / RMS` 这四个人类可读的名字**已经不存在**，
> 原地址被 `FX_A / FX_B / FX_C / VOLUME` 占用。PEAK/RMS 想补"电平证据"只能另找地址——
> 这个缺口仍在（见 §7.1）。

---

## 4. 工作流（GUI 的"按钮"）

每个工作流都注明：前置状态、命令序列、成功判据、已知陷阱、现有实现。

### W1 连接与身份
- 前置：串口空闲（**`cursor_view.py` 开着就抢不到 COM4**）。
- 步骤：打开 COM4/1 Mbaud → 读 `0xB0` → 读 `STATUS`。
- 判据：`0xB0 == 0x5A5A0003`；`STATUS[2:0]` 是当前模式。
- 陷阱：`0x04` 读回恒 0；隔夜掉电位流会丢，`0xB0` 不对就要重烧。

### W2 上传一张波表
- 前置：**MODE 必须是 IDLE**（播放中写表会被拒）。
- 步骤：`WT_SELECT = 表号`（先把 shift/morph 清掉）→ `WT_LENGTH=1024` → `WT_INDEX=0` →
  1024×`WT_DATA` → `WT_CRC` → `WT_VERSION` → `WT_APPLY = 0x80000000|version`；
  再写一次带 shift 的 `WT_SELECT`。
- 判据：`WT_APPLY` 的 err=0；`WT_STATUS[15:0]` 版本 +1；`WT_STATUS[17]`（busy）落回 0。
- 陷阱：APPLY 的 ACK 是**延迟**回复（等 CRC 扫描完），期间链接只允许一个 outstanding；
  缺 commit 位（bit31）→ 无动作；同一张表重复 APPLY 必被判不完整（见 R14）。

### W3 读回校验
- 步骤：`WT_INDEX=0` → 1024× 读 `WT_DATA`（指针自增）。
- 判据：逐点与源文件一致（CRC 过不代表排列对）。
- 陷阱：PLAY 中 `WT_DATA` 恒 0，读回只能在 IDLE。

### W4 LIVE 试听（含 arp 切换）
- 步骤：上传表 → `WT_SELECT` 带 morph/LFO → `MODE=1`（LIVE）→ 手在感应区。
- 观测：`0xD4` 事件计数、`0xE8` 的 active/gate/note、`0xF0/0xD8` 坐标。
- 切规则：写 `THRESHOLDS[23]`（1=步进琶音，0=逐帧追踪），**立即生效**，无需重烧。
- 陷阱：LIVE 的 BPM 由 X 轴决定（30..59），主机写 `BPM` 不生效；LIVE 音频走**单声部**
  波表路径（与 PLAY 的 32 声部引擎不同）。

### W5 录一轨 → 提交 → 发布
- 步骤：`TRACK=n` → `RECORD=1`（+`POTTS_LAMBDA`）→ 等 `POTTS_STATUS[4]`(capture_full) →
  读 32 点轮廓（`0x34` 读 32 次）→ `COMMIT=1` → 轮询 `POTTS_STATUS[0]`(done) →
  `MODE=4`(PLAY) → 等 loop 边界把 shadow 翻成 active。
- 判据：提交事件数 = 0x38 done 时的 0xF8 页 1 `[26:21]`；发布后 `STATUS[8]`=1。
- 陷阱：轮廓必须是"手在场"采的（全 0 会被脚本拒绝）；提交计数只能在**提交后、PLAY 前**读
  （翻 bank 会清退役 bank 的计数）。

### W6 多轨
- 必须**逐轨提交 + 逐轨发布**：提交 → PLAY 跑到边界 → 下一轨。不能先把两轨都提交再 PLAY
  （`COMMIT_REQUEST` 后 store busy，第二次 `PREPARE` 会被拒，`loop_ctrl_pending` 会挡死命令）。
- 前置：每轨开始前 `TRACK` 重新选择；`0x18` 的 PREPARE 会把 active 内容复制进 shadow。

### W7 PLAY 回放 / 停止
- 步骤：`MODE=4`；观测 `0xF8` 页 2 的 active_voice_count / steal；`STOP=1` 收尾。
- 判据：PLAY 中 `WT_DATA` 读 0（读口属于表引擎）；STOP 后 `voices=0`。
- 陷阱：**`STOP` 的 data 必须是 1**；PLAY 的事件只来自 loop 调度器，主机发不出 NOTE_ON；
  PLAY 里 morph 的 position 是**冻结**的（LFO 只在 LIVE/WT_PLAY 跑）。

### W8 遥测显示
- 步骤：`TLM_CONTROL = (period<<16)|1`（period=2400 → ~20 Hz）→ 收 22 B 帧 → CRC 校验。
- 判据：帧率 ≈ 48000/period；`seq` 递增、CRC 正确。
- 陷阱：与 ACK 帧同长，靠 `[2]==0x01` 区分；显示期间串口被独占。

### W9 测试模式（N-tone）
- 步骤：写 `0xA0 = (N<<8)|1`；关闭写 `0xA0 = 1`（N=0）。
- 判据：`test_active` 后音频被测试音取代；读回 `{tone_count, …, 1}`。
- 陷阱：它**顶替**正常音频输出，必须在 GUI 里互锁。

### W10 清空 / 复位
- 清 loop：`STOP=1` → `CLEAR_ALL=1` → `MODE=4` 跑一圈把空 bank 发布 → `STOP=1`，
  用 `STATUS[8]==0` 确认。
- `0x2C RESET` 无效，别依赖它。

---

## 5. 不变量与陷阱（GUI 必须写进代码）

1. **一个串口只能有一个拥有者**：`cursor_view.py`、任何 `board_*.ps1`、未来的 GUI 互斥。
2. 上传/写表**强制 IDLE**；顺序永远是 上传 → 设模式 → 开显示。
3. 每条命令 seq 递增并校验回显；CRC 全程校验；超时 ≥400 ms。
4. APPLY 是延迟回复，且**一次只能有一个 outstanding 命令**。
5. `PLAY/STOP/RECORD/OVERDUB/CLEAR_ALL/COMMIT/RESET` 的 data 必须**恰好等于 1**（写 0 会被 NACK）；
   `CLEAR_TRACK` 不要求（只查掩码，写入即触发）；`0x2C RESET` 即使被接受也无效。
6. PLAY 中 `WT_DATA` 返回 0；读回只能在 IDLE。
7. 多轨必须"逐轨提交、逐轨发布"。
8. per-track 计数只在提交后、PLAY 前可读。
9. `0x34` 双用途：写=轮廓读指针 **也是** 0xF8 探针页选择器，连续读 32 点后页号会飞。
10. `MODE(0x04)` 读回恒 0，真实模式看 `STATUS[2:0]`。
11. `BPM` 只对 PLAY 有效（LIVE 用 X 轴自动 tempo）。
12. `THRESHOLDS` 写入要求 `[15:0] < [31:16]`；`λ` 在 `0x3C`，不在 `[31:16]`。
13. `WT_INDEX` 值必须 <1024，`WT_LENGTH` 必须 ==1024，`WT_SELECT[2:0] ≤ 2`。
14. `WT_APPLY`/`PATCH_APPLY` 需要 **bit31 提交位** + 版本三方一致。
15. `test_active` 会顶替音频输出。
16. 同一张波表重复 APPLY 会被判"不完整"（R14 未定案）。
17. 被拒绝时 `err` 可能是 0（R13 未修：reason 1/2 未映射）。
18. 板级结论属"暂定"：setup 违约 1646、Fmax 63.9/80、CLS 95%。

---

## 6. 建议的 GUI 信息架构

| 面板 | 控件 | 绑定 |
| --- | --- | --- |
| 连接条 | 端口/波特率、连接/断开、身份灯、模式灯 | W1：`0xB0`、`STATUS` |
| 状态面板 | 模式、fault、loop_active、active_voice_count、steal 计数、每轨计数 | `STATUS`、`0xF8` 页 1/2 |
| 音色页 | 表选择、shift、morph 开关、LFO 周期、上传/APPLY/读回、帧文件列表 | `WT_SELECT/INDEX/DATA/LENGTH/CRC/VERSION/APPLY/STATUS`，W2/W3 |
| LOOP 页 | 轨选择、录音（波形/轮廓曲线）、λ、提交、发布、多轨矩阵、事件/计数 | `0x0C/0x18/0x28/0x34/0x38/0x3C`，W5/W6 |
| PLAY 页 | 播放/停止、播放中的声部/静音状态 | `MODE=4`、`STOP`、`0xF8` 页 2，W7 |
| LIVE 页 | 追踪/琶音开关、BPM（只读，说明由 X 决定）、gate/note/事件计数 | `THRESHOLDS[23]`、`0xD4/0xE8`，W4 |
| 遥测页 | 开关、周期、实时 x/y/z 画布（复用 `cursor_view.py` 的绘制） | `TLM_CONTROL`，W8 |
| 诊断页 | 只读寄存器表（0xA4–0xFC）、探针分页、原始坐标/光标坐标 | §3.6，W1 |
| 测试页 | N-tone 开关 + N（互锁，**仅测试位流**） | `0xA0`，W9 |

---

## 7. 建 GUI 之前必须先定的 5 件事

1. **电平证据**：现在没有任何寄存器能回答"到底有没有声音"——只能看 `active_voice_count`。
   建议加一个只读 peak/RMS 寄存器（或固定走 GAO）。上一轮"有声部但 −66 dBFS 听不见"就是
   这个缺口造成的。
2. **R13/R14 定案**：`reason 1/2` 映射到 `err=0`，GUI 的"为什么被拒绝"永远显示成功；
   同一张表能否幂等重放也没定。
3. **未实现 CSR 的呈现**：`0x10/0x2C/0x40/0x44/0x84–0x9C` 要么隐藏、要么显示为 N/A，
   否则用户会以为写了有用。
4. **patch bank 是否需要接音频**：现在只存储/回读。
5. **串口所有权模型**：GUI 要成为唯一拥有者（内部一个会话状态机），并禁止同时开
   `cursor_view.py`；同时把"上传强制 IDLE / 一次一个 outstanding / APPLY 延迟回复"内建。
   还要把**遥测流当开关**管好：`board_cursor.ps1` 打开 `TLM_CONTROL(0x80)` bit0 后**不会关**，
   之后任何命令的应答都会被 22 字节遥测帧插队（表现为 `SEQ MISMATCH sent=n got=0`、
   错误码 254）。离开遥测页必须写 `0x80 = 0`。

---

## 8. 附录：脚本 ↔ 工作流映射

| 工作流 | 现有实现 |
| --- | --- |
| W1 连接与身份 | 每个 `board_*.ps1` 的入口检查 |
| W2 上传 | `board_wt_upload.ps1` |
| W2b 三帧 morph | `board_wt_morph.ps1` |
| W3 读回 | `board_readback.ps1` |
| W4 LIVE | `board_live_mode.ps1`、`board_live_path.ps1`、`board_live_visual.ps1` |
| W5/W6/W7 LOOP | `board_stage2_loop.ps1`（`-Tracks N`） |
| W7+音色 | `board_wt_voice_play.ps1` |
| W8 遥测 | `board_cursor.ps1`、`host/cursor_view.py` |
| W9 测试模式 | 无脚本（只有 RTL） |
| 诊断页 | `board_coord_probe.ps1`、`board_input_diag.ps1`、`board_cursor_trace.ps1`、`board_loop_probe.ps1` |
| 波形证据 | `scripts/gao_capture.py` + `gao/*.rao` |
