# mgc3130_clean — 非接触手势合成器（GW5A / Tang Primer 25K）

FPGA：**GW5A-LV25MG121NES**（23,040 LUT 上限，实际约 17,400 LUT）。
一块 MGC3130 电场传感器测手的位置，FPGA 把高度变成音高、把前后／高低变成亮度与音量，
再用波表合成器出声；上位机负责调音色、录循环、看遥测。

本目录是 V2 的**唯一源码基线**，由旧仓库 `mgc3130_uart/.worktrees/v2-integration`
的 `50acf2e` 剔洗生成，生成过程可重放（`python scripts/bootstrap.py --source <旧仓库>`）。

## 现在能做什么

| 功能 | 状态 | 入口 |
| --- | --- | --- |
| LIVE：手势直接演奏，单声部 | 可用，板上验收 | 模式 `1` |
| 音阶：**G 自然小调** `55 57 58 60 62 63 65 67`，y 分七档 | 可用 | `rtl/v2_live_rule_engine.sv` |
| 步进琶音：固定 **125 ms** 一步，四种走位（跟随／上行／上下／随机） | 可用，板上有声 | `THRESHOLDS[26:25]` |
| 波表：3 × 1024 点，A/B/C 可 morph | 可用 | `0x60`（表/增益/morph）、`0x64` / `0x68`（索引/数据） |
| PLAY：32 声部复音，事件来自 LOOP | 可用 | 模式 `4` |
| LOOP：录制 32 tick 轮廓 → Potts 分段 → 事件表 → 回放 | 可用 | `LOOP_CTRL` 一组，见 `docs/DEBUG-AND-FLASH.md` |
| 音色：锯齿梯滤波器 + LFO + FX + ADSR + 失谐／力度／滑音 | 可用 | `0x40 / 0x44 / 0x84…0x9C` |
| 上位机控制台（tkinter，全中文） | 可用，板上验收 | `python host/console.py` |
| 波表乐器：9 个预设 + 6 个 AKWF（CC0） | 可用 | `host/presets/` |
| 静态 OLED（SSD1306 128×64，7 针 SPI） | **源码已写，未跑 P&R** | `rtl/v2_oled_static.sv` |
| demo 位流：32 音 DDS + OLED 音高面板 | 另一条分支 | `rtl/v2_demo_top.sv` |

## 三条命令

```bash
python scripts/gate.py --compile   # 静态检查 + ModelSim 编译；警告即失败（应 0 error / 0 warning）
python scripts/sim.py              # RAM=0 与 RAM=1 两套回归，逐条比对 sim_baseline.json
python scripts/synth.py --run-id r1  # 生成 .gprj 并跑 syn + pnr（约 9 分钟），输出 synth_summary.json
```

`sim.py` 的退出码即结论：观察到的失败必须是 `sim_baseline.json` 的子集
（当前 **13 条通过 / 4 条已知失败**）。修掉某个已知缺陷后跑 `--update-baseline` 把它摘掉。

位流在 `impl/<run-id>/impl/pnr/v2_board_top.fs`，`impl/` **不入库**。
烧录：`scripts/board_program.ps1 -FsFile <fs> -Operation 4`，烧完读 `0xB0` 应为 `0x5A5A0003`。

## 上位机

```bash
python -m pip install ttkbootstrap
python host/console.py --port COM4     # COM4 是板载 FTDI，同一个口也用于烧录
```

- 每命令约 17 ms（FTDI 16 ms 定时器），1024 点波表上传约 **18 s**，不能突发；
- 波表帧：`python host/instrument_tables.py`（谐波配方五件）或 `python host/akwf_tables.py --all`
  （AKWF，CC0，首次运行联网下载）；
- 测试：`python -m unittest host.test_*`——**317 条**，全绿。

## 目录

```
filelist.f            唯一文件清单（顺序即依赖顺序；仿真、闸门、综合三处共用）
ip/filelist_ip.f      厂商 IP 清单，只给综合用
MANIFEST.json         每个文件的 sha256 + 来源 commit
rtl/                  45 个 RTL，v2_board_top 是唯一合成顶层
ip/gowin_i2c_master/  Gowin I2C 核（加密 .vp + 顶层包装 + 两个 .vh 宏）
tb/                   41 个 testbench
constr/               mgc3130_v2.cst（引脚）、mgc3130_v2_top_observable.sdc（时钟）
scripts/              gate / sim / sim_unit / synth / gao_capture / board_*.ps1 / board_table.py
host/                 上位机：控制台、波表生成、评分、频谱、OLED 图
docs/                 HANDOFF.md（最新现状）、progress-*.md、specs/、plans/
gao/                  GAO 探针定义
```

## 本目录守的六条不变式

1. **只有 `filelist.f` 一份文件清单**，仿真、闸门、综合三处共用。
2. **只有一个合成顶层** `v2_board_top`，且声明在 `MANIFEST.json`。
3. **`filelist.f` 里每个模块都必须被实例化**，否则闸门失败（没有死代码）。
4. **编译零警告是硬要求**：任何 `vlog` 警告（含 `vlog-2275` 同名覆盖）都判失败。
5. **已知缺陷记进基线**：`sim_baseline.json` 列出当前已知失败，新出现的失败才叫回归。
6. **每轮改动都提交**，工作区不留跨轮未提交的改动。

## 四条容易踩的硬约束

**1. `rtl/` 里不许出现第二个 `module v2_board_top`。**
ModelSim 对同名模块只报 `vlog-2275` 警告然后覆盖，后果是"编过了，但跑的不是这份代码"。
`gate.py` 会拦；手工操作时要知道。

**2. 仿真必须带 `+define+V2_SIM`。**
`rtl/v2_clock_gen.sv` 在 `V2_SIM` 下把 `clk_sys_100m` 直接连到 `clk_in`、`pll_locked` 直接连到
`rst_n`；不带这个宏，器件 PLL 原语在仿真里不出锁，整个设计表现为"完全不应答"。
`scripts/sim.py` 与 `sim_unit.py` 已经默认带上。

**3. `clk_sys_100m` 实际是 80 MHz**（PLLA：50 MHz × 16 / 10）。
这个错误命名已经造成过一次"波特率偏 25%"的误判。重命名会触及 30 个文件，收益不抵风险，保留并在此声明。

**4. 厂商 IP 不能进 `filelist.f`。**
`mgc3130_reader` 实例化的是 `Gowin_I2C_Master`，实现体是加密的 `I2C_MASTER.vp`，
喂给 ModelSim 会编译失败。所以 `synth.py` 单独把 `ip/filelist_ip.f` 排在 `filelist.f` 之前写进 `.gprj`。

## 已知限制

- **DSP 28/28 满**、CLS 约 10 745/11 520、最差建立时间约 −2.1 ns：器件是**布局受限**，
  任何新增逻辑都要先看时序预算，不能只看 LUT 余量；
- **LIVE 是单声部**（32 声部只在 PLAY）；上传波表会强制回 IDLE；
- 上传一张表 18 s，三帧 morph 约一分钟；
- **拔掉 MGC3130 会让读取器停在等 I2C 应答**（没有超时），表现为整机"死机"，需重烧；
- OLED 静态图只到"源码 + 仿真台 + 编译门"，**没有跑过 P&R**。

## 文档从哪读

| 想知道 | 看 |
| --- | --- |
| 今天的真实状态、下一个任务 | `docs/HANDOFF.md` |
| 每个功能怎么来的、当时测了什么 | `docs/progress-<日期>.md` |
| 某个功能的验收标准 | `docs/superpowers/specs/` |
| 任务拆解与执行顺序 | `docs/superpowers/plans/` |
| 板级操作、寄存器表、烧录坑 | `docs/DEBUG-AND-FLASH.md`、`docs/host-tools-and-gui-controls.md` |
| 波表从哪来 | `docs/wavetable-sources.md` |

## 许可

AKWF 波形为 **CC0 1.0**（Adventure Kid），原文见 `artifacts/akwf/LICENSE-CC0.txt`。
其余代码与文档为本项目所有。
