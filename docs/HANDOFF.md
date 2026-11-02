# 交接：从这里继续（MGC3130 synth / mgc3130_clean）

> 每次交接**覆盖**本文件。权威事实在 `docs/progress-<date>.md` 与 `docs/superpowers/plans/`；
> 本文件只写"下一次坐下时最先要知道的东西"。

## 0. 30 秒现状

- 仓库：`C:\weizijian\documents\gowin fpga\mgc3130_clean`，HEAD 见 `git log -1`，工作区干净。
- **板上是 P2b，构建门已过**：`impl/v2_board_top_p2b_no_patch`（sha256 `471fa9ba…`，`0xB0=0x5A5A0003`），
  CLS **10750/11520**、DSP 28/28、BSRAM **34/56**、Fmax **62.925 MHz**、worst **−3.392 ns**
  （`gate: OK`），比 P2a（10894 / 38 / 60.58 MHz / −4.007）全面更好。
- **删 patch bank 的实测收益**：CLS −196（10946 → 10750）、LUT −934（18757 → 17823）、
  寄存器 −334（9699 → 9365）、BSRAM −4（38 → 34）。对照 P2a 的 LUT 18373，则是 −550。
- **P2b 寄存器已在硅上验收**：`0x94=0x01001000`、`0x98=0x0400C000`、`0x9C=0x02000000`；
  写 `0x94=0x01000080` 读回同值，再写回 `0x01001000`；`0x48` 写/读都回 NACK `BAD_ADDRESS (0x02)`。
- **P2b 听感仍未验证**（唯一剩下的验收缺口）：包络 / 力度深度 / 失谐宽度 / 滑音需要
  **手**在传感器上做手势 + 一次 **LOOP 回放**。不要引用任何“听起来如何”的结论——本轮没有听。
- **P2b 已完成并板上验收**：位流 `impl/v2_board_top_p2b_no_patch`（sha `471fa9ba…`，
  CLS 10750、Fmax 62.93 MHz、worst −3.392 ns、`gate: OK`）。用户听感确认：attack 改慢 → 音头渐入、
  `velocity_shift=3` → 轻重差别变小、`detune_shift=3` → 音色变薄。
  **`glide_rate` 未在板上验证**（只影响 LIVE 的 REVOICE，LOOP 播放不经过它）。
- **下一次的第一件事**：定 OLED（薄版 ~400 LUT，位置够）还是补 P2c（预设已改由上位机上传，无硬件改动）；见 §6。

## 0.5 上位机控制台（2026-11-02 建成，`host/v2_console/`）

入口 `python host/console.py --port COM4`；设计 `docs/superpowers/specs/2026-11-02-console-design.md`
与 `2026-11-02-loop-canvas-assisted-recording-design.md`，计划 `docs/superpowers/plans/2026-11-02-console-v2.md`，
过程 `docs/progress-2026-11-02.md`。**183 条 unittest 全绿**（`python -m unittest discover -s host -p "test_*.py"`）。

板上验过的：身份/模式、`warm` 九条读回全等、正弦表上传+读回 1024/1024、手绘一帧（797 点轨迹 → 1024 点表、
只传该帧 17.8 s）、morph 20 s 扫描、LOOP 的 Arm/Commit/Publish（32/32 覆盖、2 事件、`voices=1`）、
LIVE 光标 214 帧/2.5 s。滑杆的写-读回路只在模拟端口上测过，**还没在板上逐个拧过**。

必须知道的五个坑：

1. **串口 16 ms 定时器**：COM4 是 FTDI FT2232（就是高云烧录线），`LatencyTimer` 注册表改 1 ms 无效，
   实测仍是 16.00 ms。所以**每条命令 17.6 ms，1024 点上传 18.1 s，逐点读回 35.3 s**；突发不可用（丢一半）。
2. **传感器没有目标就不拉 TS**：手离开后 `0xEC`/`0xD0` 冻结、`0xF4=3`（`ST_WAIT_TS`）、坐标全 0，遥测也停帧。
   这不是故障；手一靠近立刻恢复（~165 fps）。
3. **`WT_DATA` 读不自增索引**，逐点读回必须每点先写 `0x64`。
4. **seq 撞车**：新进程第一条命令若与板子缓存帧同 seq（内容不同）会收 `err=5`；`Link` 现在换新 seq 重试。
5. **一个 Link 只能有一个线程用**：已加可重入锁；窗口的读数轮询在 Tk 线程、按钮动作在工作线程。

**已知缺陷（用户已提，待改）**：`THRESHOLDS[23]` 的 "step pulse" 每 tick 发 `NOTE_OFF+NOTE_ON`，
而 LIVE 路径的包络在每个 `NOTE_ON` 被 `hit_sticky` 清零（`top:739/749`，`ENV_ATT=96`≈14 ms、`ENV_DEC=8`≈41 ms），
所以听感是**节拍敲击**而不是重复触发当前音。用户要求改成"重复触发当前音"——这是 RTL 改动
（只在音高变化时清零包络，tick 之间保持电平）。**不改 RTL 时的替代做法**：用 LOOP 录 4 个不同 Y 的音再 PLAY，
PLAY 的包络可用 `0x94/0x98` 调节，能做出连奏琶音。

## 1. 开工前必须读（按顺序，约 15 分钟）

1. 本文件；
2. `docs/progress-2026-11-01.md` 的**最后一节**（P2b 板上验收：构建门已过、寄存器已实测、听感未验）；
3. `docs/superpowers/specs/2026-11-01-filter-lfo-design.md` 的 **§13 实施回写**
   （真实面积/时序 + 三条硬规则：乘法片宽、DSP 稀缺、跨模块组合链）；
4. 任务级计划 `docs/superpowers/plans/2026-11-01-p2a-filter-lfo.md`（Task 0–6 已完成，Task 7 未做完）；
5. 源码：`rtl/v2_ladder_lp.sv`（13 级流水、27 位 Q4、27 位钳位）、`rtl/v2_lfo_triangle.sv`
   （正弦三次式每拍一级流水、输出寄存）、`rtl/mgc3130_v2_top.sv` 里的音频链
   （`i2s_sample_raw` → LFO/`ci_total` → `u_filter` → 音量 → `i2s_sample`）。

## 2. 第一件事：带手做 P2b 听感验收（唯一剩下的缺口）

构建门与寄存器面都过了：`p2b_no_patch` 是 CLS 10750、Fmax 62.925 MHz、worst −3.392 ns，
`gate: OK`，已烧在板上（`0xB0=0x5A5A0003`）。`0x94/0x98/0x9C` 的板上写读回、
`0x94=0x01000080` 往返、`0x48` 的 `BAD_ADDRESS` 都实测过。**只剩听感没有验证。**

1. 先读 `0xB0` 确认板上是 `471fa9ba…` 这一版；不等就按 §4 重烧 `p2b_no_patch`。
2. 按连接流程上传波表（`scripts/board_wt_upload.ps1`），再让**手**在传感器上做手势：
   对比默认包络与 `0x94/0x98` 拉长/缩短的起音与释放、`0x9C[1:0]` 改力度深度后的轻重差、
   `0x9C[3:2]` 改失谐宽度后的拍频、`0x9C[31:16]` 改滑音速率后的换音速度。
3. 再做一次 **LOOP 回放**（`scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 1`），听同一段循环。
4. 听感结论必须带位流 sha256 与具体寄存器值；没有听到就写“未验证”，不要写“应该”。
5. 不要为了时序偷偷砍功能——P2a 的教训是 Fmax 20 → 46 靠流水/移位，不是删功能。

## 3. 铁律（都是踩过的）

- 分析一律以**最新版本**为准：先 `git log -1` + 读工作区文件。
- 每轮结束必须提交，`git add` 列**具体文件**，不 `git add -A`。
- 源文件 **LF、无 BOM**；`gate.py` 对 CRLF 只警告，对 BOM 报错。
- **`filelist.f` 是显式清单**（禁止通配）：新建 `.sv` 必须加进去，否则 `sim_unit` 编译不到它。
- **`gate.py` 不许有未例化模块**（除声明顶层）；存在静态失败时**会跳过编译步骤**。
- **乘法操作数必须落在 27×18 片内**；常数乘法写移位加；不要把 16×16 零扩展成 32×32。
- **`synth.py` 现在会跑构建门**（`--max-cls` 11300、`--min-slack` −3.5），不过会打印
  `GATE: FAIL` 并 `exit 2`——位流仍留在磁盘上可查，但**不许上板**。四个数读
  `impl/<run>/impl/pnr/v2_board_top.tr` 与 `.timing_paths`（`scripts/synth_report.py` 已能解析）。
- **`synth.py` 拒绝复用 run 目录**，重建要换 `--run-id`。
- 板级纪律：先读 `0xB0` 确认位流；`cursor_view.py` 独占 COM4；上传/写表强制 IDLE；
  `STOP` 的 data 必须恰好 1；`0x2C RESET` 是空操作。
- **`board_cursor.ps1` 不会关遥测流**：它退出后别的脚本会 `SEQ MISMATCH` + 错误码 254，
  先写 `0x80 = 0`。
- 验收不许只看"有声部"：必须有电平证据或听感。

## 4. 命令速查

| 目的 | 命令 | 通过的样子 |
| --- | --- | --- |
| 静态 + 编译门 | `python scripts/gate.py --compile` | `GATE: PASS`、0 error 0 warning |
| 单 tb | `python scripts/sim_unit.py --tb <tb>` | `UNIT <tb>: PASS` |
| 全回归 | `python scripts/sim.py` | `SIM: PASS`，13 pass / 4 基线失败，RAM=0/1 一致 |
| 阶段 2 证据集 | `python scripts/test_potts_plane.py` | `POTTS PLANE: PASS` |
| Python 单测 | `python -m unittest host.test_synth_report host.test_filter_coeff` | `OK`（25 tests） |
| 构建（带门） | `python scripts/synth.py --run-id <新名字>` | `SYNTH: PASS` **且** `gate: OK` |
| 已有构建查门 | `python scripts/synth_report.py --run-dir impl/<run>` | 打四个数 + `gate: OK/FAIL` |
| 烧录 | `powershell -File ".../board_program.ps1" -FsFile <impl/.../v2_board_top.fs> -Operation 4` | `PROGRAM PASS`，随后 `0xB0=0x5A5A0003` |
| LOOP 板测（要手） | `powershell -File scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 1` | `STAGE2 LOOP RESULT: PASS` |
| 阶段 1.5 板测（要手） | `powershell -File scripts/board_wt_voice_play.ps1 -Port COM4` | `WT VOICE PLAY RESULT: PASS` |
| 上位机控制台 | `python host/console.py --port COM4` | **2026-11-02 已板上验收**：`warm` 九条读回全等、正弦表上传+读回 1024/1024、录一轨 32/32 覆盖→4 事件→发布、STOP 后 `voices=0`、LIVE 214 帧/2.5 s。**突发不可用**，上传 18.1 s、逐点读回 35.3 s |

> 控制台的事看 `docs/progress-2026-11-02.md`，计划在 `docs/superpowers/plans/2026-11-02-console-v2.md`。
> 上传仍是逐条等 ACK（≈18.3 s）；突发要等 `scripts/gui_burst_bench.py` 在板上量过。

## 5. 当前基线（三套，别混）

| | P1 生产位流 `6ab982d6…`（已被 P2a 取代） | P2a 生产位流 `p2a_timing3b`（已被 P2b 取代） | P2b 生产位流 `p2b_no_patch`（**在板上，寄存器已验收，听感未验**） |
| --- | --- | --- | --- |
| Logic / Register | 15793 / 8733 | 18373 / 9615 | **17823 / 9365** |
| CLS / DSP / BSRAM | 10510 / 8 / 37 | 10894 / 28 / 38 | **10750 / 28 / 34** |
| setup 违约 / TNS | 1401 / −1691.8 ns | 1693 / −2127 ns | **1335 / −1516.005 ns** |
| worst / Fmax | −3.214 ns / 63.639 MHz | −4.007 ns / 60.580 MHz | **−3.392 ns / 62.925 MHz** |
| 最差路径 | `u_v2_uart` 家族 | `fx_a → u_fx/delay_mem` | `u_v2/g_potts.u_potts/d_15_s0 → err_acc_31_s0` |
| 回归 | 13 pass / 4 fail | 13 / 4 | 13 / 4（最近一次 `sim.py`，本次构建轮未重跑） |
| 音频链延迟 | 1 个采样 | 3 个采样（62.4 µs），开滤波器 4 个 | 同 P2a；PLAY 开效果器时 fx 内部再多 1 拍 |

P2b 位流 sha256：`471fa9ba4b2878c0d83b0867447012fcfc70714d9d234276823a554537a0e48a`
（旧的 `51564858…` 是 `p2b_voice_params`，已作废）。
P2a 位流 sha256：`915e87cd6367b23ba953e3ba6dd37640ab3b00eb8132a1e865a1dc3b59ff908f`。

## 6. 未决事项

0. **上位机脚本问题清单在 `docs/host-tools-and-gui-controls.md` §9**（十条，含清场前提、`0x84 level≥2` 相加削顶成直流、
   COM4 独占、PowerShell 三个解析坑、加轨的 CSR 序列）。**改 `board_stage2_loop.ps1` 主流程前必须先测**——
   本轮加 `-SkipClear` 把控制流弄坏，已回退。
0b. **叠加已验证可用**：`PREPARE_RECORD` 会 `copy_active`，在已发布 take 上只重录一轨不会清掉其它轨。
   **overdub 监听（边放边录）没有实现**：`voice_rst_n`/`loop_event_ready` 只在 PLAY 使能（P3 级改动，余量约 770 CLS）。
0. **已知限制**：`board_stage2_loop.ps1` 的清场只在「板上没有已发布轨道」时才通过（见 progress 的「坑一」）；
   局部失败的一轮要恢复，目前只能**重烧位流**清状态。多轨录制要用 `-PrepareSeconds 8`，否则轨间窗口来不及摆手。

1. **P2b 听感未验证（第一优先）**：包络四段（`0x94/0x98`）、力度深度（`0x9C[1:0]`）、
   失谐宽度（`0x9C[3:2]`）、滑音速率（`0x9C[31:16]`）的听感都需要手在传感器上做手势，
   外加一次 LOOP 回放。寄存器与构建都已验收，**唯一缺口是耳朵**（§2）。
2. **OLED / 屏幕后置决定未做**：首版明确不承诺屏幕（`HARDWARE_DESIGN_CONTEXT.md:262`）；
   若以后要加，屏幕不能夹在 Rx 与 Tx 之间，且 LCD/OLED 的 ITO/背板/刷新噪声会改变
   `CRxTx/CRxGND`，必须重做 Aurea 参数化（同文件 §电极设计、`:261`）。本仓库目前没有任何
   OLED 驱动/UI 代码，这一项是产品决定，不是待写的模块。
3. **P2c 预设已在主机侧完成**：`0x48–0x5C` 退役后不再需要片上预设表。做预设就是连接时把
   九个参数词（`0x40/0x44/0x84/0x88/0x8C/0x90/0x94/0x98/0x9C`）逐条写一遍（约 2 ms，
   失去原子生效，换来 763 LUT / 4 BSRAM）。**P2c 若还要做，只剩功能重排**（例如 32 声部
   gain/limiter），不是预设。
4. **效果器接线**已在 P2a 接回，保持；`0x84–0x8C` 不要撤。
5. **80 MHz 时序欠账**：worst −3.392 ns、1335 个 setup 违约端点、Fmax 62.9 MHz；
   板子仍按 80 MHz 跑。这是 P1 起就有的历史欠账，本轮比 P2a 好 0.6 ns，但**没有真正 closure**。
   要 closure 只能继续流水化/换结构，不要删功能。
6. **LIVE 的 "step pulse" 要改成重复触发当前音（用户 2026-11-02 明确要求）**：见 §0.5 的已知缺陷。
   最小改法：`hit_sticky` 只在 `live_note_hit` 且新音高 ≠ 旧音高时置位（多一个比较器），
   或者 tick 之间不清零、只在 gate 下降时走释放。CLS 10750/11520（93%），塞得下。
7. **上位机还差的**（按分镜优先级）：滑杆的板上逐项验证、每轨预设绑定、A/B 对比、
   N-tone 测试按钮与频谱（频谱要 GAO 或新加音频通路，属 RTL）。
6. **worst 25 里的 `u_voice` 是诊断偏差，不是 P2b 回归**：25 条里 20 条终点在 `u_v2/u_voice`
   （11 条 VCA/混音 `n9320_s0 → mixed_sample_*`、9 条 `mode_reg → revoice_target_a_pending_*`），
   起点都不是 `voice_cfg` 的七个字段，且这两条锥早于 P2a（`5337ac0` / `cafb93d`）。
   P2a 时它们被更差的 uart/potts/fx 路径盖住；本轮整体变快后浮进前 25。别再当新问题查。

## 7. 交接检查清单

```powershell
cd "C:/weizijian/documents/gowin fpga/mgc3130_clean"
git log --oneline -3
git status --short          # 必须为空
```

板上是否还是 P2b 位流：读 `0xB0`（等于 `0x5A5A0003`；不等于就按 §4 重烧 `p2b_no_patch`，
sha256 `471fa9ba…`）。
