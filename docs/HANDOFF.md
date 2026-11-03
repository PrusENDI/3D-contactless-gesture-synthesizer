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
过程 `docs/progress-2026-11-02.md`。**236 条 unittest 全绿**（`python -m unittest discover -s host -p "test_*.py"`）。

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

**已修（2026-11-03）**：LIVE 的音频改走 32 声部引擎 + `u_fx_lite`，不再用 `u_wt_playback × wt_env`
（那一整块 LIVE 包络已删，`wt_env_prod` 的 DSP 乘法预计还回 1 片）。`0x94/0x98/0x9C` 与
`0x84/0x88/0x8C` 现在都到 LIVE；`0x40/0x44/0x90` 本来就在 mux 之后、一直生效。
顺带修了 `REVOICE` 只能同音高重调的问题（旧 LIVE 的音高由 `u_wt_playback` 单独走，把引擎里的空操作盖住了）。
arp 仍用 OFF+ON：实测 |Δsample| 726 → 23 → **9**。证据、bench（`tb/tb_live_engine`）与预期面积见
`progress-2026-11-02.md` 的「LIVE 改走 32 声部引擎」。**还没有重新构建/烧板**，板上仍是旧路由。

**界面（第二轮，2026-11-02 晚）**：ttkbootstrap 2.2.6 深色主题 `darkly` + 全中文。新增
`host/v2_console/ui/`（`zh.py` 文案与单位汉化，`theme.py` 字体/间距/DPI）。**多了一个依赖：
`python -m pip install ttkbootstrap`**（`console.py` 启动自检，缺了打印安装命令而不是抛 ImportError；
模型、链路和全部测试都不需要它）。

1. **"丑"的主因是 DPI，不是配色**：这台机 `AppliedDPI=144`（150%），裸 Tk 进程不声明 DPI 感知，
   Windows 把 96 dpi 的位图拉 1.5 倍 → 字全是糊的。`ttkbootstrap.Window` 会调 `SetProcessDpiAwareness(1)`
   但**静默吞掉失败**，所以 `theme.enable_dpi_awareness()` 自己调并回读等级；`console.py` 启动打印
   `window …, 2.00 px per point, dpi awareness 1`。**所有尺寸走 `theme.px()`**（96 dpi 基准 × 屏幕比例），别写死像素。
2. **`ttk.Scale.set()` 会触发 `command`**：建面板时 `set(lo)`、读回时 `_sync_sliders` 的 `set(value)` 都会走
   `_on_param_drag`，"读参数"会变成"把读到的值再写一遍"，建面板时更会把每个字段写成下限（音量 → 0 直接静音）。
   现在有 `self._syncing` 闸门；启动 7 s 的命令日志只剩 `0x80`（开遥测）和 `0x34`（读读数），没有参数写。
3. **一个进程只能有一个 `ttk.Window`**（2.x 会 `_require_single_root` 报错），别为了先选字体建临时 root。
4. 1 bit 字段（`enable/retrig/unipolar`）是 Checkbutton 不是滑杆；数值列显示的是**板子读回值**，clamp 一眼可见。
5. 空画布会画中间提示（"等待手进入感应区"/"还没有波表"/"还没有轨道"），否则看着像坏了。
   截图脚本 `artifacts/tabs_shot.py` → `artifacts/ui/tab-*.png`（`artifacts/` 被忽略）。

**LOOP 卡顿的真因（2026-11-02 深夜）**——不是手感问题，是**整条命令链路停摆 34 秒**：

1. **板子**：`v2_loop_event_store_dpb` 里 `busy = copy_active || commit_pending`、`ctrl_ready = !busy`；
   顶层 `cmd_ready = (!loop_ctrl_pending || cmd_is_abort) && …`。所以**提交之后、发布之前**再去"对准"，
   顶层把控制命令挂进 `loop_ctrl_pending` 等 store 的 `ctrl_ready`，store 却在等一个只在 PLAY 才有的小节边界
   → `cmd_ready` 一直 0 → **连读都不回**，直到 `BOUNDARY_TIMEOUT_CYCLES = 32'd3_400_000_000`
   （100 MHz → **34.0 s**）超时。日志实测 22:07:37→22:08:11 正好 34 秒、28 条 `no usable reply`。
2. **应用**：原来每 0.5 s 在 **Tk 线程**发 7 条命令（14 条/秒，25% 的界面时间在串口上）；
   链路死时每条要 1.2 s（3 次 × 0.4 s），于是窗口整段冻住。
3. **修法（已落地）**：提交后**立刻发布**（swap 的小节边界要靠 PLAY 提供）；对准前读 `0xF8` page 1
   bit6/bit9，还在 pending 就拒绝并提示"先发布"，不再把链路卡死；轮询整体挪到**工作线程**（Tk 线程零 I/O）、
   1 s 一次、单次尝试（死链 0.4 s 而不是 1.2 s）；`wait_for_take` 轮询 20 ms → 100 ms。
4. **待办（要动板子，未做）**：`BOUNDARY_TIMEOUT_CYCLES` 从 3.4e9 降到 5e8（5 s），或让 IDLE/RECORD 下的
   swap 立即完成。否则任何一次误操作都要等 34 秒。
5. **录音时的提示**（用户反馈"不知道有没有开始录"）：倒计时 3-2-1 每声 660 Hz、开窗 990 Hz、
   完成 1320 Hz（都在线程里响，不卡界面）；画布顶部红色进度条 + 居中"● 正在录第 N 轨 tick x/32
   剩 x.x s"；控件行同步显示"● 录音中 轨 N x/32 tick"。
6. **板子的采集窗口比 arm 晚一小节**：`v2_loop_contour_capture` 要等下一次 `mtick[4:0]==0`，
   而 `0x08=120` 刚把 tick 清到 1，所以**arm 之后整 4 秒才开始录**，再 4 秒才 FULL（四次实测 7.90–7.94 s）。
   主机端因此把监听和进度条都**推迟 4 秒**（`ConsoleModel.record_offset`），采集超时也放到 12 s。
   不知道这条就会以为"录了 4 秒"，实际手上要有 8 秒。
7. **波表采集曾经永远拿到 0 帧**：`buffer.trail(10**6)[started:]` 用**长度**当下标，而 `trail` 是环形缓冲
   （容量 1200 = 6 秒），手在感应区待够 6 秒后长度就停在 1200，切片永远为空。现在用 `mark()`/`since()`
   的绝对计数；捕获过程中画布实时显示"捕获中 N 帧"，一眼能看出遥测有没有来。
8. **"上传卡在 1023" 是进度少一**：`on_sample(index, total)` 传的是 0..1023，进度条永远停在 1023/1024，
   而真正的 CRC/APPLY 还在后面几十毫秒，看起来像挂了。现在传 `index+1`，最后一格是 1024/1024。
9. **"波表试听没反应" 多半是只传了一帧却开了 morph**：LFO 在 A→B→C 三张表之间扫，只填了 A 时
   三分之二的扫描落在空表上（听感就是没声）。`upload_frames` 现在**只有三帧齐全才开 morph**，
   否则只放 A，消息里写明 "morph off: it sweeps A/B/C, and there are only N frame(s)"。
10. **A/B/C 录满曾是死路**：`_next_frame_slot()` 满了就抛错，而界面没有"重录某一帧"的入口。
   现在波表页有 **写入 A/B/C/自动** 选择器 + **清空帧**；指定槽位就覆盖该帧（上传时按内容差异重发）。
   画布同时画三帧（当前帧更粗、标 A/B/C），并有 **导出 .bin** 把帧写成
   `artifacts/console/A.bin`（16 位小端），"上传 .bin…" 才有文件可选。
11. **重启控制台后【提交】曾经一个字节都不发**：`commit_take()` 要求 `self.flow` 非空，而 flow 只在
   【录制】里创建 —— 板子明明还存着完整轮廓（`0x38` bit4 = 1）、上一轮也提交成功过，界面却抛
   "nothing is armed"。现在 `RecordFlow.adopt()` + `ConsoleModel.adopt_board_take()`：flow 为空时先读
   `0x38`，满了就接管 `0x34` 的 32 点轮廓（同一 30/32 门禁），再走正常提交/发布。
12. **`USE_POTTS` 在板级是开着的**：模块默认 0，但 `rtl/v2_board_top.sv:22` 传 `.USE_POTTS(1)`，
   `.POTTS_HORIZON(32)` —— 出厂位流里 DP **是**在跑的。我曾只看模块默认值和构建脚本，误判成 stub，
   并在文档里写过"提交只会写 0 事件"；**那是错的**，已更正。板级实测：page1 `0x0082006B` 解出
   `commit_count = 4`、`record_count = 4`（事件确实写进去了），只是在 swap 刚发生那一刻读到的
   `0x6B` 还是 0，容易被误读成"没写"。
13. **PLAY/WT_PLAY 没声的常见原因是 morph**：两者都走 `WT_SELECT` 的 `morph` 位与 `shift` 位。
   只填了 A 却开 morph，三分之二的插值落在空表上；`shift`（WT_SELECT[7:4]，界面"增益移位"）
   是 `sample >>> shift`，**数值越小越响**（0 最响、可能削顶）。
14. **"上传 .bin…" 曾经没有进度**：`ConsoleModel.upload()` 没把 `on_sample` 传给
   `session.upload_table`，18 秒里进度条一动不动，看着像卡死。现在它接受 `on_progress(done,total)`
   并转给上传循环（和"上传三帧"共用同一条进度条），另外非 1024 点的文件会在发命令**之前**被拒。

**PC 侧 overdub（2026-11-02 晚）**：LOOP 页勾上"边听边录（放已录轨）"，对准一小节时主机把**已录的每条轨**
混成一个 4 s WAV 循环播，板子照旧盲录。板内做不到不是懒：`voice_rst_n` 只在 LIVE/PLAY 放开，
`loop_probe_run = mode_play`，RECORD 时音频 mux 落到被 reset 的引擎（`fx_quiet`），是结构性的静音。

1. **顺序是全部**：`start_overdub()`（渲染，Python 走 192k 采样要几百 ms）必须在 `arm_take()` 写 `0x08=120`
   之**前**完成，`play_overdub()` 只负责起播。反过来做，监听会晚四分之一拍。
2. **误差是常数不是漂移**：两边小节都正好 4.000 s（`SAMPLE_RATE * BAR_SECONDS`），差的只是起播延迟，
   约 **±20–50 ms**（命令往返 17.6 ms + PlaySound 起播）。当伴奏听不出来，当节拍器会有 flam。
3. **混音要留头**：`headroom(轨数)` 给 1→0、2→1、3/4→2 档右移，否则四条轨叠起来就削顶。
4. **没上传波表也能听**：回落到 `reference.sine_table()`（板子复位表就是正弦）。
5. "试听参考"按钮也改成放**全部**轨的混音（原来只放 `contours[0]`）。

**指引页（LOOP 页的谱表，2026-11-02 晚）**：`host/scores/*.json` 是谱，`host/v2_console/score.py` 是模型
（无 Tk），LOOP 页顶部下拉选谱，画布把**正在录的那一轨**每个 tick 的目标档填亮，录完按 32 点算命中率。
格式与加谱方法见 `host/scores/README.md`。

1. **谱只能在硬件给的 8 个音里写**：`rtl/v2_note_increment_rom.sv` 只有 55/57/60/62/64/67/69/72；写别的音
   `score.parse` 直接报错并列出这 8 个。
2. **档位是硬件的 y 区间，不是八等分**：`v2_live_rule_engine.sv:96-103` 的阈值（3855/13493/…/59753）除以 64
   就是轮廓域（`v2_loop_contour_capture.sv:57` 存的是 `y[15:6]`，0..1023）的边界。G3 只有 60 宽、A3 有 151 宽，
   画成等分会让你对着一个"看着对、听着错"的位置练。
3. **命中率里，没手 = 错**：轮廓 0 表示那一 tick 没有手，提交后是休止，所以算 miss 不算跳过。
4. **bpm 只接受 120**：`record_flow.arm` 强写 `0x08=120` 并读回校验，谱写别的速度就和画出来的小节错位。
5. 谱的 `notes` 是 `[起始 tick, MIDI 音号]`，长度由下一个起点或 32 决定；连续同音会并成一个 hold。

## 1. 开工前必须读（按顺序，约 15 分钟）

1. 本文件；
2. `docs/progress-2026-11-01.md` 的**最后一节**（P2b 板上验收：构建门已过、寄存器已实测、听感未验）；
3. `docs/superpowers/specs/2026-11-01-filter-lfo-design.md` 的 **§13 实施回写**
   （真实面积/时序 + 三条硬规则：乘法片宽、DSP 稀缺、跨模块组合链）；
4. 任务级计划 `docs/superpowers/plans/2026-11-01-p2a-filter-lfo.md`（Task 0–6 已完成，Task 7 未做完）；
5. 源码：`rtl/v2_ladder_lp.sv`（13 级流水、27 位 Q4、27 位钳位）、`rtl/v2_lfo_triangle.sv`
   （正弦三次式每拍一级流水、输出寄存）、`rtl/mgc3130_v2_top.sv` 里的音频链
   （`i2s_sample_raw` → LFO/`ci_total` → `u_filter` → 音量 → `i2s_sample`）。

## 2. 第一件事：构建 + 带手做 P2b 听感验收（唯一剩下的缺口）

**LIVE 路由在 2026-11-03 改了**（引擎 + FX，见 §0.5），所以听感验收必须先**重新构建、烧板**；
板上现在那块 P2b 位流还是旧路由，直接听听到的不是这份 RTL。

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
6. **LIVE 路由已改（2026-11-03，见 §0.5）**：LIVE = 引擎 `voice_sample` → `u_fx_lite` → `>>>2` → I2S，
   `wt_env` 已删（预期 −1 DSP、−150~250 LUT/CLS，未构建）；arp 仍用 OFF+ON，实测 |Δsample| 726→23→9；
   REVOICE 现在能跨音高重调（`last_active_slot` + `note[]` 回写）。下一步：构建 → 烧板 → 带手听感。
7. **上位机还差的**（按分镜优先级）：滑杆的板上逐项验证、每轨预设绑定、A/B 对比、
   N-tone 测试按钮与频谱（频谱要 GAO 或新加音频通路，属 RTL）。指引页与 PC 侧 overdub 已做（§0.5），
   **overdub 还没在板上真录一遍**（要先在台架上听：听得出起播晚了就加一个固定的渲染偏移来补）。
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
