# 交接：从这里继续（MGC3130 synth / mgc3130_clean）

> 每次交接**覆盖**本文件。权威事实在 `docs/progress-<date>.md` 与 `docs/superpowers/plans/`；
> 本文件只写"下一次坐下时最先要知道的东西"。

## 0. 30 秒现状

- 仓库：`C:\weizijian\documents\gowin fpga\mgc3130_clean`，HEAD `aaec218`，工作区**干净**。
- 正在做：路线图 **P1（VCA + 力度 + 失谐）**，任务级计划
  `docs/superpowers/plans/2026-11-01-vca-and-detune.md`，**尚未开工**。
- 板上跑的是生产位流 `impl/v2_board_top_no_test_mode`
  （`sha256 ef8eed8a9eb2c7983ea2ddb87f0a697100ff0ebb55c8612a838bae23d6f3cec5`），
  自检：`0xB0 = 0x5A5A0003`、`read 0xA0 = 0`（测试块已编译掉）、`STATUS` 可读。
- 下一步：按 P1 Task 1 写 `tb/tb_voice_vca.sv`，先红后绿。

## 1. 开工前必须读（按顺序，约 15 分钟）

1. `docs/HANDOFF.md`（本文件）
2. `docs/superpowers/plans/2026-11-01-expression-roadmap.md` —— 范围、赛题映射、P1/P2/P3、非目标、风险
3. `docs/superpowers/plans/2026-11-01-vca-and-detune.md` —— P1 的 3 个任务（文件/接口/命令/期望值）
4. `docs/progress-2026-11-01.md` 的**最后三节** —— 当前证据、已知遗留、下一步
5. 源码：`rtl/v2_voice_engine_banked.sv`
   - 1–130 行：bank 字布局（phase/step/target/envelope/gain/mix/stage/vibrato，256 位用了 250）
   - 200–290 行：`bank_wr_*` 选择（`pending_activate` / calc 写回 / `direct_note_on`）
   - 540–700 行：scan → rd → calc → 累加 → `mixed_sample`

## 2. 第一件事（照计划做，别自由发挥）

1. 写 `tb/tb_voice_vca.sv`（用例在计划 Task 1 Step 1，含：激活首采样必须为 0、稳态幅度 = `(osc_sum × (env×gain>>8)) >> 16`、gain=0 全静音、gain 128:255 峰值比）；
2. `python scripts/sim_unit.py --tb tb_voice_vca` → 红（`calc_env_gain` 不存在）；
3. 实现计划 Task 1 Step 3 的两级乘法；
4. 改三个既有 tb 的绝对电平期望（`tb_voice_wt_source` / `tb_wt_voice_poly` / `tb_top_wt_voice`），**按新物理改，不是放宽**；
5. 四个 tb 绿 → 提交（计划 Task 1 Step 6 的命令）。

## 3. 铁律（都是踩过的）

- 分析一律以**最新版本**为准：先 `git log -1` + 读工作区文件；旧文档只作对照。
- 每轮结束必须提交，`git add` 列**具体文件**，不 `git add -A`。
- 源文件 **LF、无 BOM**（BOM 会让 `vlog` 报 non-printable；PowerShell 5 的 `Set-Content -Encoding UTF8` 会带 BOM，用 `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`）。
- `scripts/synth.py` 的时序摘要解析有 bug（读错文件），时序四个数要手读 `impl/<run>/impl/pnr/v2_board_top.tr`。
- 板级纪律：先读 `0xB0` 确认位流；`cursor_view.py` 独占 COM4；上传/写表**强制 IDLE**；`STOP` 的 data 必须**恰好 1**；`0x2C RESET` 是空操作；PLAY 中 `WT_DATA` 读回 0。
- 验收不许只看"有声部"：`active_voice_count > 0` 不代表有声音，必须有电平证据（GAO 或听感 + 写明"听到什么"）。
- 面积：CLS **10498/11520（91%）**，DSP 6/28，BSRAM 37/56；再加逻辑前先看余量。
- 时序：setup 违约 1163、TNS −916.9 ns、worst −1.841 ns（在 `u_v2_uart`）、Fmax 69.73 MHz（约束 80）。

## 4. 命令速查

| 目的 | 命令 | 通过的样子 |
| --- | --- | --- |
| 静态 + 编译门 | `python scripts/gate.py --compile` | `GATE: PASS`、0 error 0 warning |
| 单 tb | `python scripts/sim_unit.py --tb <tb>` | `UNIT <tb>: PASS` |
| 全回归 | `python scripts/sim.py` | `SIM: PASS`，13 pass / 4 条基线失败，RAM=0/1 一致 |
| 阶段 2 证据集 | `python scripts/test_potts_plane.py` | `POTTS PLANE: PASS` |
| 构建 | `python scripts/synth.py --run-id <id>` | `SYNTH: PASS` + sha256（时序另读 `.tr`） |
| 烧录 | `powershell -File "C:/weizijian/documents/gowin fpga/mgc3130_uart/.worktrees/v2-integration/scripts/board_program.ps1" -FsFile <impl/.../v2_board_top.fs> -Operation 4` | `PROGRAM PASS`，随后 `0xB0=0x5A5A0003` |
| LOOP 板测 | `powershell -File scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 1` | `STAGE2 LOOP RESULT: PASS`（需要手） |
| 阶段 1.5 板测 | `powershell -File scripts/board_wt_voice_play.ps1 -Port COM4` | `WT VOICE PLAY RESULT: PASS`（需要手） |

## 5. 当前基线（改完拿它对比）

| 项 | 值 |
| --- | --- |
| 生产位流 | `ef8eed8a9eb2c7983ea2ddb87f0a697100ff0ebb55c8612a838bae23d6f3cec5` |
| Logic / Register | 16353 / 8751 |
| CLS / DSP / BSRAM | 10498 / 6 / 37 |
| setup 违约 / TNS / worst / Fmax | 1163 / −916.9 ns / −1.841 ns / 69.73 MHz |
| 回归 | 13 pass / 4 fail（R13、R14、0xA8 前提错） |
| 已知未做 | R13/R14 未定案；GAO 频谱对比未做；混响/合唱、64 路、可视化、蓝牙都未做 |

## 6. 未决事项（动到再问用户）

1. **P2 控制面**：滤波器/LFO 参数打算复用契约里从未实现的 `0x40/0x44`（原 `DIAG_AUDIO`/`DIAG_ROUTER`），
   需要同步改契约、GUI 文档、脚本读表。
2. **赛题覆盖缺口**（已和用户确认本轮不补）：R2 的"混响/延迟/合唱"只有现存 delay+comb；R1 按 32 路申报。
3. **patch bank**（763 LUT / 261 寄存器 / 4 BSRAM）仍是"只存不接"的死重，本轮不动；要腾面积时它是第一目标。

## 7. 交接时的工作区状态检查清单

```powershell
cd "C:/weizijian/documents/gowin fpga/mgc3130_clean"
git log --oneline -3
git status --short          # 必须为空
```

板上是否还是当前位流：读 `0xB0`（不等于 `0x5A5A0003` 就重烧）。
