# 独立 DDS 演示位流：任务级计划（2026-11-03）

> 分支：`feat/demo-dds-oled`，独立 worktree `mgc3130_demo`（从 `feat/demo-dds-bitstream` @ `c878314` 拉出，
> 那份已含 OLED 的既有实现与设计 `2b394d5`；master 不受影响）。
> 设计：`docs/superpowers/specs/2026-11-03-demo-dds-bitstream-design.md`。
> 每个任务：先红后绿、跑指定命令、**单独提交**。构建只跑一次（见 T9），不要每步构建。

## 0. 开工前置（不占任务号）

- 工作全部在 worktree `C:/weizijian/documents/gowin fpga/mgc3130_demo` 里做，
  主工作区 `mgc3130_clean` 里那 16 个别人的改动不碰、也不在上面跑门。
- 本特性只碰：`filelist.f`、`MANIFEST.json`、`scripts/gate.py`、`scripts/synth.py`、
  `scripts/synth_report.py`、`host/test_synth_report.py`、新增 `rtl/v2_demo_*`、新增 `rtl/v2_oled_tones.sv`、
  新增 `tb/tb_demo_*`、新增 `tb/tb_oled_tones.sv`、新增 `tb/tb_test_mode.sv`、
  新增 `host/spectrum.py` + `host/test_spectrum.py`、新增 `gao/demo_tones.rao`、
  新增 `docs/demo-dds-evidence.md`、`docs/DEBUG-AND-FLASH.md`、进度文档。
- 不碰：`rtl/mgc3130_v2_top.sv`、`rtl/v2_board_top.sv`、`rtl/v2_test_mode.sv`、`rtl/v2_oled_static.sv`、
  `rtl/v2_oled_image.sv`、`v2_contract_pkg.sv`、`constr/`。

## T1 gate 认识第二个 top

**目的**：`gate.py` 现在只允许一个 root（`gate.py:174-177`），加第二个 top 必 FAIL。

1. 新建 `rtl/v2_demo_top.sv`，只放端口表与空 body（`assign pcm5102a_* = 0;` 之类）。
   `filelist.f` 追加 `rtl/v2_demo_top.sv`。
2. **红**：`python scripts/gate.py` → 应打印 `additional uninstantiated module(s) ... (second top candidate)`。
3. `MANIFEST.json` 加 `"expected_tops": ["v2_board_top", "v2_demo_top"]`（保留 `expected_top`），
   `gate.py` 改成读列表：列表里每个名字都必须是 root 且已定义，其他 root 仍 FAIL。
4. **绿**：`python scripts/gate.py` → `GATE: PASS`。
5. 追加断言：`v2_board_top.sv` 与 `mgc3130_v2_top.sv` 的文本里不得出现 `v2_demo_`
   （生产层级不含演示模块；这是「生产网表不变」的静态证据）。
6. 提交：`git add MANIFEST.json scripts/gate.py filelist.f rtl/v2_demo_top.sv`
   → `feat(demo): teach the gate about a second top`.

**过**：红/绿两次输出都贴进进度文档。

## T2 构建入口按 top 走，并给 fmax 一个真正的门

`synth.py` 写死 `TOP`/`PROJECT_NAME`；`synth_report.read_run` 写死 `v2_board_top`；
`gate_fail` 只查 CLS 与 slack，`--min-fmax` 不存在（设计 §7.5）。

1. **红**（Python 单测，先写）：`host/test_synth_report.py` 加
   - `gate_fail(summary, max_cls, min_slack, min_fmax=80)`：fmax 62.9 → 1 条问题；fmax 100 → 0 条；
     `min_fmax=None` → 0 条（生产行为不变）；
   - `read_run(tmpdir)`：目录里只有 `v2_demo_top.*` 三个文件时也能读出来（自动发现 top）。
   跑 `python -m unittest host.test_synth_report` → 失败（参数不存在 / 找不到文件）。
2. 实现：`read_run(run_dir, top=None)` 从 `impl/pnr/*.rpt.txt` 自动发现；
   `gate_fail(..., min_fmax=None)`；`synth.py` 新增 `--top`（默认 `v2_board_top`，校验在 `expected_tops` 里）、
   `--min-fmax`（默认 `None`），run 目录/`gprj`/报告名/`summary["top"]` 全部按 top。
3. **绿**：单测全过；`python scripts/synth_report.py --run-dir impl/v2_board_top_p2b_no_patch` 仍打印四个数。
4. 提交。

## T3 序列器 + 它的 tb

新 `rtl/v2_demo_sequencer.sv`：帧计数器状态机，`sample_ce` 驱动，参数
`TONE_FRAMES`/`HOLD32_FRAMES`/`GAP_FRAMES`；输出 `csr_valid/csr_write/csr_addr/csr_wdata`、
`demo_tone_count[5:0]`、`demo_muted`、`demo_segment[1:0]`。

1. **红**：`tb/tb_demo_seq.sv`（tb 用短参数：`TONE_FRAMES=8`、`GAP_FRAMES=2`）断言：
   - 上电后依次出现 `csr_wdata == 0x0000_0101`（N=1）、`0x0000_0801`（N=8）、`0x0000_2001`（N=32）；
   - 每个字只出现一拍（`csr_valid` 单脉冲），地址恒 `0xA0`；
   - **任何时刻都不出现 `0x0000_0000`**（会置粘滞 fault）；
   - 段间 `demo_muted=1` 持续 `GAP_FRAMES` 个 `sample_ce`。
   跑 → 编译失败（模块不存在）= 红。
2. 实现；**绿**：`python scripts/sim_unit.py --tb tb_demo_seq` → `UNIT tb_demo_seq: PASS`。
3. 提交。

## T3b OLED 画面（组合式，0 BSRAM）

新 `rtl/v2_oled_tones.sv`：`img_addr[9:0]`（`{page[2:0], col[6:0]}`）+ `tone_count[5:0]` →
`img_data[7:0]`，**纯组合**。

1. 画面：第 0–15 行大号 `N=xx`（13 个 8×16 字模：0-9、`N`、`=`、空格，放 `case` 函数即 LUT）；
   第 16–63 行 32 根阶梯柱，第 k 根高 k 像素、`k ≤ tone_count` 时点亮（列 `col[6:2]` 是槽号，
   `col[1:0] < 3` 才是柱宽）。
2. **红**：`tb/tb_oled_tones.sv` 断言
   ①`tone_count=32` 时点亮的柱数 = 32、`tone_count=8` 时 = 8；
   ②第 k 根柱的像素高度 = k（逐列扫 `col=4k..4k+2` 统计亮位）；
   ③`N=32` 时 "3" 与 "2" 的字模字节与 `host` 侧参考（手写的 13×16 表）逐字节相同；
   ④`tone_count=0` 时屏幕只剩 `N= 0`，柱全灭。
   跑 → 编译失败 = 红。
3. 实现；**绿**：`sim_unit --tb tb_oled_tones` PASS。提交。

## T4 演示 top：静音闸门 + 显示路径 + 它的 tb

`rtl/v2_demo_top.sv` 填实：照抄 `mgc3130_v2_top.sv:62-77` 的时钟/复位/调度器，
接 `v2_demo_sequencer` + `v2_test_mode` + 静音闸门 + `i2s_pcm5102a_tx`；
再按设计 §4.3 接显示路径：`v2_oled_tones`（组合画面）→ `v2_oled_static`（现成 writer，`clk_50m`），
`tone_count` 两级同步器进 50 MHz 域，`done` 后等 N 变化 → 拉低 writer 的 `rst_n` 几拍 → 放开重发整帧；
未用端口 `uart_tx=1`、`mgc_*=1'bz`。

1. **红**：`tb/tb_demo_top.sv`（80 MHz，`#6.25`；短参数）断言：
   - 静音段 `u_i2s/sample_latched` 保持**连续 0**（不是保持上一个样点）；
   - 有声段 `sample_latched` 非 0，且 `demo_tone_count` 与段对应；
   - `pcm5102a_lrck` 频率 ≈ 48 kHz（分频参数对不对）；
   - 端口表与 `v2_board_top` 逐字相同（对比两文件的 port 声明即可，脚本 grep）；
   - 换 N 之后 writer 的 `rst_n` 被拉低过（重发整帧），并且 SPI 上出现完整的 8×131 字节序列。
2. 实现；**绿**：`sim_unit --tb tb_demo_top` PASS。
3. 提交。

## T5 `v2_test_mode` 的第一支 tb（频点基准）

`tb/tb_test_mode.sv`：直接打 CSR 字，用实数 DFT 在 4096 点上判峰。
断言 N=1/8/32 时，`220·k Hz` bin 的功率 ≥ 邻居 bin 的 100 倍，且高于门限的峰数 = N；
N=32 时顺便确认发布拍那次 `phase[32]` 越界不会污染 `mixed_sample`（注释里写明）。

- 这是**回归守卫**，不是新功能：写它之前 RTL 已经正确，先跑一次记录基线；若红了就是真 bug，单独记。
- `sim_unit --tb tb_test_mode` PASS；提交。

## T6 FFT 数峰脚本

`host/spectrum.py`：读 `gao_capture.py` 的 CSV（`sample_latched` 列），按 48 kHz 做 radix-2 FFT
（Hann 窗、局部极大值、相对门限），打印峰表并断言峰数 = `--expect`。
只用标准库，不引入 numpy。

1. **红**：`host/test_spectrum.py` 合成信号（1/8/32 个正弦 + 白噪）→ 模块不存在。
2. 实现；**绿**：`python -m unittest host.test_spectrum`；再拿 `artifacts/gao/` 里既有 CSV 试跑不崩。
3. 提交。

## T7 GAO 探针

`gao/demo_tones.rao`：`sample_clock="pcm5102a_lrck"`（48 kHz，**不是** 80 MHz），
探针 `u_i2s/sample_latched[15:0]`、`demo_tone_count[5:0]`、`demo_muted`；
触发 `demo_tone_count==32 && !demo_muted` 电平，`storage_depth=2048`。

- 只能靠 T9 的构建 + 板上抓一次来验证；先在文件里写清理由（照抄 `gao/i2s_pitch.rao` 的注释格式）。

## T8 全套门（一次跑完）

```powershell
python scripts/gate.py --compile      # 0 error(s), 0 warning(s)
python scripts/sim.py                 # PASS，失败集不超基线
python scripts/sim_unit.py --tb tb_demo_seq
python scripts/sim_unit.py --tb tb_demo_top
python scripts/sim_unit.py --tb tb_test_mode
$mods = @(Get-ChildItem host/test_*.py | % { 'host.' + $_.BaseName }); python -m unittest @mods
```

全绿才进 T9；任何一条红先修，不带着红去构建。

## T9 一次构建（唯一一次 P&R）

```powershell
python scripts/synth.py --top v2_demo_top --run-id demo1 --gao gao/demo_tones.rao --min-fmax 80
```

记录进 `impl/v2_demo_top_demo1/synth_summary.json` 与进度文档：

- `top = v2_demo_top`、`bitstream_sha256`；
- **BSRAM 必须 0**（音频与显示都算：>0 说明某处被推断成存储，推翻 V3；字模进 LUT 才是对的）；
- DSP 0、Logic/Reg/CLS 实际数、fmax、worst slack；
- 若 `--min-fmax` 红：那是真问题（这么小的设计不该跑不到 80 MHz），先查，不调低门。

## T10 板上（要手，一次做完）

1. 烧 `impl/v2_demo_top_demo1/impl/pnr/ao_0.fs`（GAO 构建）→ 上电即响，不接 USB。
1b. 屏：上电后显示 `N= 1` 与 1 根柱；走到 N=32 段时 32 根柱全亮（每次换 N 黑 ~110 ms 再画）。
2. `gao_capture.py --rao gao/demo_tones.rao --out artifacts/gao/demo32.csv` →
   `python host/spectrum.py --csv artifacts/gao/demo32.csv --expect 32`。
3. 等序列走回 N=1 段，再抓一次 `demo1.csv` → `--expect 1`。
4. 两次 CSV + 两份峰表存 `artifacts/gao/`，数字写进证据文档。
5. 回烧生产位流，读 `0xB0=0x5A5A0003`、`0xA0=0`（生产位流没有测试块）。

## T11 文档 + 收尾

- `docs/demo-dds-evidence.md`：判据 → 证据 → 命令 → 数字；开篇写明「V2 是数字域（GAO）」；
  附 RTL 行号（相位累加器、256 点表、加法、0 BSRAM）、两次抓取的峰表、sha256。
- `docs/DEBUG-AND-FLASH.md` 加一节「演示位流：构建/烧录/抓谱」。
- `docs/progress-2026-11-03.md`（或当日进度文档）记本轮证据。
- 提交；分支保留，合并与否由用户决定（生产位流不因此改变，见设计 §5.1）。

## 不做什么（与设计一致）

- 不做模拟录音、不做 UART、不做交互、不改 `v2_test_mode`、不改生产 RTL、
  不欠生产重构建（设计 §5.1）。
