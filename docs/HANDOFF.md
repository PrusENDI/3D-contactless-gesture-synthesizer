# 交接：从这里继续（MGC3130 synth / mgc3130_clean）

> 每次交接**覆盖**本文件。权威事实在 `docs/progress-<date>.md` 与 `docs/superpowers/plans/`；
> 本文件只写"下一次坐下时最先要知道的东西"。

## 0. 30 秒现状

- 仓库：`C:\weizijian\documents\gowin fpga\mgc3130_clean`，工作区**干净**（HEAD 见 `git log -1`）。
- **P1 已完成**（VCA + 力度 + 失谐 + 激活改走邮箱）：`5337ac0`、`97da308`、`0218fa6`。
  细节与偏差见 `docs/progress-2026-11-01.md` 最后一节「P1 落地」与
  `docs/superpowers/plans/2026-11-01-vca-and-detune.md` 的「实施记录」。
- 板上跑的是 `impl/v2_board_top_vca_detune_mbox/impl/pnr/v2_board_top.fs`
  （sha256 `6ab982d6a8d7d0f857a2dd8b1f9ee8a9a267caa174d07ae61b677038ecffc27b`），
  自检：`0xB0 = 0x5A5A0003`；1024 点上传 PASS；
  `board_wt_voice_play.ps1` 全流程 PASS（32 tick 轮廓 29/32 非零、8 音符、published、
  PLAY voices peak 2、WT_DATA 0、STOP 后静音）。
- 唯一还缺的证据是 GAO 抓 `i2s_sample` 的斜坡（仿真已断言，板上没量）；**听感已由用户确认**
  （2026-11-01，"声音没问题"）。
- **下一步：P2 —— 整机一个低通 + 三角 LFO 扫截止**（路线图 §3 P2）。
  拓扑还没定（12 dB 状态变量 vs 24 dB 梯形），定了再写任务级计划。

## 1. 开工前必须读（按顺序，约 15 分钟）

1. `docs/HANDOFF.md`（本文件）
2. `docs/superpowers/plans/2026-11-01-expression-roadmap.md` —— P1 已标完成，P2/P3 的范围与面积估算
3. `docs/progress-2026-11-01.md` 的**最后一节**（P1 落地：实测值、三个位流对比、已知限制）
4. 源码：
   - `rtl/v2_voice_engine_banked.sv`：`envelope_gain()` / `calc_osc_vca`（VCA）、
     `detuned_step()` + `pending_activate`（激活字）、`bounded_step`（滑音目标）
   - `rtl/v2_board_top.sv`：`PRESERVE_*_PLANE(0)`、`USE_TEST_MODE(0)`、`FX_ENABLE(1)`
   - 滤波器要插在 I2S 混音之前，先看 `rtl/mgc3130_v2_top.sv` 里 `i2s_sample` 的来源与
     `u_fx` 的位置
5. `docs/host-tools-and-gui-controls.md`（改控制面时要同步的 CSR 表与 GUI 文档）

## 2. 第一件事（P2，照流程来，别自由发挥）

1. 先定 **P2 控制面**：复用契约里从未实现的 `0x40`（截止/共振/旁路）与 `0x44`（LFO 速率/深度/使能），
   要同步改 `v2_contract_pkg.sv`、顶层译码、`docs/host-tools-and-gui-controls.md`、脚本读表；
2. 写 `tb/tb_filter_lfo.sv`：DC 通过、-3 dB 点、共振峰、LFO 扫一圈截止频率的包络可测；
3. 实现（`v2_lowpass_2pole.sv` + LFO），再跑门禁与回归；
4. 构建 → 烧录 → `board_stage2_loop.ps1 -Tracks 1` 听感。

**先算面积**：CLS 10510/11520，只剩 **1010 CLS**；P2 估算 +400~700 LUT + 2~3 DSP（DSP 8/28）。
不够就先砍 `u_patch_bank`（763 LUT / 261 reg / 4 BSRAM，只存不接）。

## 3. 铁律（都是踩过的）

- 分析一律以**最新版本**为准：先 `git log -1` + 读工作区文件；旧文档只作对照。
- 每轮结束必须提交，`git add` 列**具体文件**，不 `git add -A`。
- 源文件 **LF、无 BOM**（BOM 会让 `vlog` 报 non-printable；PowerShell 5 的 `Set-Content -Encoding UTF8`
  会带 BOM，用 `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`）。
  `gate.py` 会就 CRLF 报 `!!`，新改的文件保持 LF 即可。
- **Verilog 乘法按目标宽度定尺寸**：`x <= (a * b) >>> 8` 会被截断，必须走内部宽变量/函数
  （`envelope_gain()` 就是为此而写）。
- **ModelSim 不吃 `"..." . "..."` 字符串拼接**，也不接受 `before` 之类关键字做参数名。
- `scripts/synth.py` 的时序摘要解析有 bug（读错文件），四个数要手读 `impl/<run>/impl/pnr/v2_board_top.tr`：
  `Setup Violated Endpoints`、`default_gen_clk   setup` 那行的 TNS/端点数、`Actual Fmax` 行、`timing_paths` 里的起点。
- **`synth.py` 拒绝复用已有 run 目录**，重建要换 `--run-id`。
- 板级纪律：先读 `0xB0` 确认位流；`cursor_view.py` 独占 COM4；上传/写表**强制 IDLE**；
  `STOP` 的 data 必须**恰好 1**；`0x2C RESET` 是空操作；PLAY 中 `WT_DATA` 读回 0。
- **`board_cursor.ps1` 不会关遥测流**：它把 `TLM_CONTROL(0x80)` bit0 打开就退出，
  之后别的脚本会 `SEQ MISMATCH sent=1 got=0` + 错误码 254（遥测帧插在应答里）。先写 `0x80 = 0`。
- 验收不许只看"有声部"：`active_voice_count > 0` 不代表有声音，必须有电平证据。
- 音符 ROM 只有 8 个音高（55/57/60/62/64/67/69/72），其余 `rom_step = 0`。

## 4. 命令速查

| 目的 | 命令 | 通过的样子 |
| --- | --- | --- |
| 静态 + 编译门 | `python scripts/gate.py --compile` | `GATE: PASS`、0 error 0 warning |
| 单 tb | `python scripts/sim_unit.py --tb <tb>` | `UNIT <tb>: PASS` |
| 全回归 | `python scripts/sim.py` | `SIM: PASS`，13 pass / 4 条基线失败，RAM=0/1 一致 |
| 阶段 2 证据集 | `python scripts/test_potts_plane.py` | `POTTS PLANE: PASS` |
| 构建 | `python scripts/synth.py --run-id <新名字>` | `SYNTH: PASS` + sha256（时序另读 `.tr`） |
| 烧录 | `powershell -File ".../board_program.ps1" -FsFile <impl/.../v2_board_top.fs> -Operation 4` | `PROGRAM PASS`，随后 `0xB0=0x5A5A0003` |
| 上传波表（练链路） | `powershell -File scripts/board_wt_upload.ps1 -Port COM4 -Bin artifacts/wt/voice_sine.bin -PostSelect 0x00000040` | `RESULT: PASS` |
| 遥测 | `powershell -File scripts/board_cursor.ps1 -Port COM4 -Seconds 4` | `RESULT: n frames`（**跑完记得关 0x80**） |
| LOOP 板测（要手） | `powershell -File scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 1` | `STAGE2 LOOP RESULT: PASS` |
| 阶段 1.5 板测（要手） | `powershell -File scripts/board_wt_voice_play.ps1 -Port COM4` | `WT VOICE PLAY RESULT: PASS` |

## 5. 当前基线（改完拿它对比）

| 项 | 值 |
| --- | --- |
| 生产位流 | `6ab982d6a8d7d0f857a2dd8b1f9ee8a9a267caa174d07ae61b677038ecffc27b` |
| Logic / Register | 15793 / 8733 |
| CLS / DSP / BSRAM | 10510 / 8 / 37 |
| setup 违约 / TNS / worst / Fmax | 1401 / −1691.8 ns / −3.214 ns / 63.639 MHz |
| 最差路径 | `u_v2_uart/frame[3]_7_s0 → last_frame/CE`（不是声部；92% 占用下的布局结果） |
| 回归 | 13 pass / 4 fail（R13、R14、0xA8 前提错） |
| 上一版（P1 前） | `ef8eed8a…`：CLS 10498、DSP 6、1163 违约、TNS −916.9、worst −1.841、69.73 MHz |

## 6. 未决事项（动到再问用户）

1. **P2 控制面**：滤波器/LFO 参数打算复用契约里从未实现的 `0x40`/`0x44`（原 `DIAG_AUDIO`/`DIAG_ROUTER`），
   需要同步改契约、GUI 文档、脚本读表。
2. **时序欠账**：最差路径已是 UART（−3.214 ns，1 Mbaud 实测不丢帧，但结构上仍违约）。
   要收就先查 `frame → last_frame/CE` 这条锥（加一级寄存或收紧使能条件）；本轮不动。
3. **REVOICE 抹平失谐**：要把失谐挪到 calc 级（`calc_step_b` 由 `bounded_step` 结果派生）才能修，
   代价是热路径多一个 32 位移位 + 减法；本轮不动，已写在 progress 的"已知限制"。
4. **力度下限**：`velocity = depth_now`，手远即静音。要"轻触也有声"就改
   `v2_cursor_filter_timed.sv` 的映射（加下限或改 `Z_LOW`），不是改 VCA。

## 7. 交接时的工作区状态检查清单

```powershell
cd "C:/weizijian/documents/gowin fpga/mgc3130_clean"
git log --oneline -3
git status --short          # 必须为空
```

板上是否还是当前位流：读 `0xB0`（不等于 `0x5A5A0003` 就重烧）。
