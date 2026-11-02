# 交接：从这里继续（MGC3130 synth / mgc3130_clean）

> 每次交接**覆盖**本文件。权威事实在 `docs/progress-<date>.md` 与 `docs/superpowers/plans/`；
> 本文件只写"下一次坐下时最先要知道的东西"。

## 0. 30 秒现状

- 仓库：`C:\weizijian\documents\gowin fpga\mgc3130_clean`，HEAD 见 `git log -1`，工作区干净。
- **板上是 P2a，已验收**：`impl/v2_board_top_p2a_timing3b`（sha256 `915e87cd…`，`0xB0=0x5A5A0003`），
  CLS 10894/11520、DSP 28/28、BSRAM 38/56、Fmax 60.58 MHz、worst −4.007 ns；用户听感已确认。
- **P2b 代码完成，但构建门未过、未做板上验收**：`0x94/0x98/0x9C` + `voice_cfg` 已实现，
  `tb_contract_clamp`(40) / `tb_voice_cfg` / `tb_top_p2_csr` 全绿，`sim.py` 13/4；
  上一次构建 `p2b_voice_params` 是 **Fmax 57.989 MHz、worst −4.745 ns、CLS 10946/11520（96%）**。
  `fx_a` 那条已被增益寄存消掉；整体变慢是布局/面积，不是 P2b 新路径。详见 `docs/progress-2026-11-01.md` 的 P2b 节。
- **面积决定已做、已落地（2026-11-02 晚）**：`u_patch_bank` 整块删除（原先 763 LUT / 261 寄存器 / 4 BSRAM），
  `0x48–0x5C` 现在读写都回 `BAD_ADDRESS (0x02)`；预设改为主机连接时上传九个参数词（约 2 ms）。
  **本轮没有跑综合**，所以省下的面积还没有新的位流数字。
- **下一次的第一件事：用 `synth.py --run-id p2b_voice_params_no_patch` 重跑构建门**（§2）。

## 1. 开工前必须读（按顺序，约 15 分钟）

1. 本文件；
2. `docs/progress-2026-11-01.md` 的**最后一节**（P2b：代码完成、构建门未过、未上板、未验证清单）；
3. `docs/superpowers/specs/2026-11-01-filter-lfo-design.md` 的 **§13 实施回写**
   （真实面积/时序 + 三条硬规则：乘法片宽、DSP 稀缺、跨模块组合链）；
4. 任务级计划 `docs/superpowers/plans/2026-11-01-p2a-filter-lfo.md`（Task 0–6 已完成，Task 7 未做完）；
5. 源码：`rtl/v2_ladder_lp.sv`（13 级流水、27 位 Q4、27 位钳位）、`rtl/v2_lfo_triangle.sv`
   （正弦三次式每拍一级流水、输出寄存）、`rtl/mgc3130_v2_top.sv` 里的音频链
   （`i2s_sample_raw` → LFO/`ci_total` → `u_filter` → 音量 → `i2s_sample`）。

## 2. 第一件事：把删掉 patch bank 后的构建重跑一遍

面积决定已经做了：`u_patch_bank`（763 LUT / 261 寄存器 / 4 BSRAM）整块删除，`v2_patch_bank.sv`
已从 `filelist.f` 移除，`0x48–0x5C` 现在读写都 NACK `0x02`。**但本轮只做代码/测试/文档，
没有跑综合**，所以 P2b 的 96% CLS 有没有降下来、Fmax 有没有回到 60 以上，都还没有数字。

1. 用 `python scripts/synth.py --run-id p2b_voice_params_no_patch` 重跑构建门
   （`--max-cls 11300`、`--min-slack −3.5`）并读 `impl/<run>/impl/pnr/v2_board_top.tr`；
2. 过门才烧板复测 P2b（`0x94/0x98/0x9C` 写读回 + 听感 + 一次 LOOP 回放）；
3. 若仍不过门，再考虑 P2c 之类的功能重排，或接受 code-complete（不烧板、不声称听感）；
4. 不要为了时序偷偷砍功能——P2a 的教训是 Fmax 20 → 46 靠流水/移位，不是删功能。

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

## 5. 当前基线（三套，别混）

| | P1 生产位流 `6ab982d6…`（已被 P2a 取代） | P2a 生产位流 `p2a_timing3b`（**在板上，已验收**） | P2b 待验收 `p2b_voice_params`（**未做板上验收，门未过**） |
| --- | --- | --- | --- |
| Logic / Register | 15793 / 8733 | 18373 / 9615 | 18757 / 9699 |
| CLS / DSP / BSRAM | 10510 / 8 / 37 | **10894 / 28 / 38** | 10946 / 28 / 38 |
| setup 违约 / TNS | 1401 / −1691.8 ns | 1693 / −2127 ns | 1531 / −3084.01 ns |
| worst / Fmax | −3.214 ns / 63.639 MHz | **−4.007 ns / 60.580 MHz** | **−4.745 ns / 57.989 MHz** |
| 最差路径 | `u_v2_uart` 家族 | `fx_a → u_fx/delay_mem` | `u_filter/u_full_0_s → nx1_25_s0`（fx_a 那条已消失） |
| 回归 | 13 pass / 4 fail | 13 / 4 | 13 / 4 |
| 音频链延迟 | 1 个采样 | 3 个采样（62.4 µs），开滤波器 4 个 | 同 P2a；PLAY 开效果器时 fx 内部再多 1 拍 |

P2b 位流 sha256：`5156485899f46c050143f3f358eb300ad685ea137906247acda6210ea4116c8b`。
P2a 位流 sha256：`915e87cd6367b23ba953e3ba6dd37640ab3b00eb8132a1e865a1dc3b59ff908f`。

## 6. 未决事项

1. **P2b 构建门未过（第一优先）**：上一次实测 Fmax 57.989 < 60、worst −4.745 < −4.2，
   CLS 10946/11520（96%）。根因是 `+52 CLS` 引起的布局退化（uart −3.92 → −4.67、potts −4.01 → −4.69），
   **P2b 没有新关键路径**。现在 `u_patch_bank` 已删（763 LUT / 261 寄存器 / 4 BSRAM），
   **但删完还没重跑构建**——下一步就是 `synth.py --run-id p2b_voice_params_no_patch`。
   在过门之前 P2b 保持 code-complete，不烧板、不复测听感。
2. **P2b 的板级/听感验证全部未做**：`0x94/0x98/0x9C` 写读回只在仿真 `tb_top_p2_csr` 里证明；
   包络/力度/失谐的听感需要手 + 一次 LOOP 回放。
3. **预设只在主机侧**：spec §12 的 `F0_I0..I8` 映射已随 patch bank 作废，`0x48–0x5C` 回 `0x02`；
   将来做预设，就是连接时把九个参数词（`0x40/0x44/0x84/0x88/0x8C/0x90/0x94/0x98/0x9C`）
   逐条写一遍（约 2 ms，失去原子生效，换来 763 LUT）。
4. **效果器接线**已在 P2a 接回，保持；`0x84–0x8C` 不要撤。
5. **整机 −4.0 ns 的历史欠账**（uart/potts/voice/fx 几条锥）在 P2a 时是 −4.0 附近；
   P2b 的布局把这几条整体放大到 −4.6 左右，等删掉 patch bank 后的构建数字出来再看。

## 7. 交接检查清单

```powershell
cd "C:/weizijian/documents/gowin fpga/mgc3130_clean"
git log --oneline -3
git status --short          # 必须为空
```

板上是否还是 P2a 位流：读 `0xB0`（等于 `0x5A5A0003`；不等于就按 §4 重烧 `p2a_timing3b`）。
