# 交接：从这里继续（MGC3130 synth / mgc3130_clean）

> 每次交接**覆盖**本文件。权威事实在 `docs/progress-<date>.md` 与 `docs/superpowers/plans/`；
> 本文件只写"下一次坐下时最先要知道的东西"。

## 0. 30 秒现状

- 仓库：`C:\weizijian\documents\gowin fpga\mgc3130_clean`，工作区**干净**（HEAD 见 `git log -1`）。
- **P1 已完成并板上验收**（VCA + 力度 + 失谐 + 激活走邮箱），板上位流
  `impl/v2_board_top_vca_detune_mbox`（sha256 `6ab982d6…`），听感已由用户确认。
- **P2a 已完成并板上验收**：滤波器 + LFO + 效果器接线 + 主音量。
  位流 `impl/v2_board_top_p2a_timing3b`（sha256 `915e87cd…`，`0xB0=0x5A5A0003`），
  **CLS 10894/11520、DSP 28/28、BSRAM 38/56、Fmax 60.58 MHz、worst −4.007 ns**。
  用户听感确认：`0x40` 变暗、`0x44` 起伏、`0x90` 变响（"现在没问题了"）。
  回归：`tb_top_wt_filter`（WT_PLAY + 滤波 + 音量 + LFO，仿真 1249 → 99 → 2498 → 摆幅 867）
  等 7 个单元 tb 全绿，`sim.py` 13/4，`POTTS PLANE` 绿。
- 音频链延迟 **3 个采样（62.4 µs）**，开滤波器 4 个；所有寄存器由 `sample_ce` 使能。
- **下一次的第一件事：选 P2b（语音参数 `0x94/0x98/0x9C`）还是先还时序欠账**（见 §6 第 1、2 条）。

## 1. 开工前必须读（按顺序，约 15 分钟）

1. 本文件；
2. `docs/progress-2026-11-01.md` 的**最后一节**（P2a：三次构建、三个根因、还差一步）；
3. `docs/superpowers/specs/2026-11-01-filter-lfo-design.md` 的 **§13 实施回写**
   （真实面积/时序 + 三条硬规则：乘法片宽、DSP 稀缺、跨模块组合链）；
4. 任务级计划 `docs/superpowers/plans/2026-11-01-p2a-filter-lfo.md`（Task 0–6 已完成，Task 7 未做完）；
5. 源码：`rtl/v2_ladder_lp.sv`（13 级流水、27 位 Q4、27 位钳位）、`rtl/v2_lfo_triangle.sv`
   （正弦三次式每拍一级流水、输出寄存）、`rtl/mgc3130_v2_top.sv` 里的音频链
   （`i2s_sample_raw` → LFO/`ci_total` → `u_filter` → 音量 → `i2s_sample`）。

## 2. 第一件事：修顶层音频链（决策已提给用户，未答复）

最差 −9.20 ns 全在顶层，**与滤波器/LFO 无关**（它们已经退出最差 25 条）：

```
u_wt_playback → wt_quiet 移位加 → mult_3201（LIVE 包络乘法，仍是 LUT 阵列）
             → 音频 mux → 音量乘法（2 片 MULT27X36）→ 饱和 → I2S
```

根因：DSP 28/28 满 → LIVE 的包络乘法掉进 LUT → 单个 LUT 乘法器 ~17 ns > 12.5 ns 周期，
**所以只加流水寄存收不回来**。必须两条一起做：

- **A**：撤掉本轮的效果器接线（`0x84–0x8C` 的四个乘法），腾 4 片 DSP 给 LIVE 包络与音量；
  `0x84–0x8C` 改回未实现（写入 NACK），GUI 文档同步。
- **B**：在音频 mux 之后加一级 `sample_ce` 寄存（总延迟 1 → 2 个采样 = 41.6 µs）。

**待用户拍板的第二件事**：验收线用严格 `worst ≥ −3.5`，还是务实"新增路径不得进入最差 25 条
且 Fmax ≥ 60 MHz（基线 63.6）、允许 worst 落在 −6 以内并作为既有欠账记账"。

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

## 5. 当前基线（两套，别混）

| | P1 生产位流 `6ab982d6…`（**在板上**） | P2a 待验收 `p2a_timing3b` |
| --- | --- | --- |
| Logic / Register | 15793 / 8733 | 待抄（CLS 10894） |
| CLS / DSP / BSRAM | 10510 / 8 / 37 | **10894 / 28 / 38** |
| setup 违约 / TNS | 1401 / −1691.8 ns | 1693 / −2127 ns |
| worst / Fmax | −3.214 ns / 63.639 MHz | **−4.007 ns / 60.580 MHz** |
| 最差路径 | `u_v2_uart` 家族 | `fx_a → u_fx/delay_mem`（**本轮新引入的 0.8 ns**，其余 −4.0 附近是既有欠账） |
| 回归 | 13 pass / 4 fail | 同样 13/4 |
| 音频链延迟 | 1 个采样 | **3 个采样（62.4 µs）**，开滤波器 4 个 |

## 6. 未决事项

1. **时序欠账**：worst −4.007 ns（Fmax 60.58），其中 0.8 ns 是本轮新引入的
   `fx_a → u_fx/delay_mem`；地板在 −4.0（fx/potts/voice/uart 四条既有锥）。
   要再挤需动 `v2_fx_lite`（增益乘法后加寄存）等**本轮冻结的文件**。
2. **效果器接线**若本轮撤掉，等设备有余量时接回（`v2_fx_lite` 参数已就绪，只差 CSR 六行）。
3. **P2b**（`0x94/0x98/0x9C` 语音参数）未开始：设计在 spec §11.3/§11.6，计划未写。
4. **P2c**（预设接线，patch bank ↔ 9 个 CSR）只有映射（spec §12），未实现。
5. **整机 −3.2 ns 的历史欠账**仍在（UART 那一族），与 P2a 无关。

## 7. 交接检查清单

```powershell
cd "C:/weizijian/documents/gowin fpga/mgc3130_clean"
git log --oneline -3
git status --short          # 必须为空
```

板上是否还是 P1 位流：读 `0xB0`（不等于 `0x5A5A0003` 就重烧）。
