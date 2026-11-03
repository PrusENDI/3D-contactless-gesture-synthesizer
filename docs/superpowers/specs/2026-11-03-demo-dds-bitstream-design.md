# 独立 DDS 演示位流设计（2026-11-03）

> 范围：只做**第二个位流**，生产位流与 `v2_board_top` 的行为一行不改。
> 上游：赛题「现场验证要求」第 3 条（用户 2026-11-03 提供原文）：
> 「支持测试模式下输出多路不同频率音频，频谱可观测对应数量独立谱峰，
> 同时可通过 RTL 代码佐证纯硬件实时合成通路，验证无预录音频播放行为。」

## 1. 要求 → 三条判据

| 编号 | 判据 | 怎么算过 |
| --- | --- | --- |
| V1 | 多路、不同频率，且路数能当场改变 | N 依次为 1 / 8 / 32，每路频率 `220·k Hz`（k=1..N），**无主机参与** |
| V2 | 频谱上数得出 N 个独立谱峰 | 数字（GAO 2048 点）与模拟（PCM5102A 线路输出录音）两条路各自 FFT，峰数 = N、位置落在 `220·k Hz ±1 bin` |
| V3 | RTL 可佐证纯硬件实时合成、无预录 | 位流里 **0 BSRAM、0 DSP、无 UART 实例**；每个样点由「相位累加器 + 单周期 256 点表 + 加法」当场算出；并有一个录音做不到的实验：N 自己变，峰数跟着变 |

## 2. 为什么是独立位流，而不是生产位流加一个开关

1. 面积：`v2_test_mode` 实测 2544 LUT / 1153 reg。今天生产构建 CLS 10757/11520（93.4%），
   加回来约 11248（97.6%），P&R 余量太小；时序上 P1 那次对比 worst slack 从 −1.841 掉到 −3.148 ns，
   而 `synth.py` 的门是 `--min-slack -3.5`（最近两次构建已经 −4.18 / −4.30）。
2. 证据：V3 要的是「这个位流里的音频只能算出来」。生产位流里有 32 声部引擎、波表 BSRAM、
   主机上传通路，解释成本高；一个只有 DDS + I2S 的位流，把这件事讲到没有歧义。
3. 用户 2026-11-03 选定方案 C（最小 DDS 位流），放弃方案 A（同一 RTL 两套配置）。

## 3. 目标 / 非目标 / 反目标

**目标**

- 第二个可烧录位流 `v2_demo_top`，上电即输出测试音，不需要 UART、不需要 PC、不需要传感器。
- 32 路不同频率，`220·k Hz`（k=1..32，上限 7040 Hz）。
- N 自动循环 `1 → 8 → 32`，32 段保持 20 s，供频谱仪/手机录音取窗。
- 可复现的证据链：tb、GAO `.rao`、FFT 脚本、`synth_summary.json`（top + 资源 + sha256）、实测频谱。

**非目标**

- 不做乐器：无 32 声部引擎、无波表、无 MGC3130 读取、无 LIVE/LOOP、无传感器、无滤波器/FX/音量寄存器。
- 不新增 UART 或 CSR 契约；`v2_contract_pkg` 一行不改。
- 不改 `v2_test_mode` 的语义与端口（它是既有 RTL，改了要同时解释生产位流）。
- 不改生产位流的资源、时序与行为。

**反目标（做到这些就算失败）**

- 用「生产位流 + `USE_TEST_MODE=1`」冒充演示位流（面积/时序不允许，且证据最弱）。
- 拿主机上传的波表或 LIVE 录音当「纯硬件合成」证据。
- 只有听感、没有谱；或只有谱、没有 RTL/资源证据。

## 4. 结构

```
v2_demo_top                    端口与 v2_board_top 完全相同（复用同一份 CST 与烧录脚本）
├── v2_clock_gen               50 MHz → 80 MHz（PLLA，现成）
├── v2_reset_sync              PLL 锁定后才释放复位（现成）
├── v2_sample_scheduler        80 MHz → 48 kHz sample_ce（现成）
├── v2_demo_sequencer          （新）按帧计数，向测试块写 0xA0：1、8、32、0 循环
├── v2_test_mode #(MAX_TONES=32)  （现成，零改动）32 路相位累加器 + 256 点单周期正弦表
└── i2s_pcm5102a_tx            CLK_HZ=80_000_000 / SAMPLE_HZ=48_000 / ACC_WIDTH=24（现成）
```

- 音频通路只有一处选择：`v2_test_mode` 的 `mixed_sample` → I2S（`sample_valid` 打拍）。
  没有滤波器、没有音量、没有 FX。
- 未用端口：`uart_tx = 1'b1`（空闲高），`mgc_sda/scl/ts/mclr = 1'bz`，`uart_rx` 不接。
  端口名与 `v2_board_top` 逐字相同，因此 `constr/mgc3130_v2.cst` 与
  `scripts/board_program.ps1` 都不用改。

### 4.1 序列（`v2_demo_sequencer`）

| 段 | N | 时长（默认参数） | 作用 |
| --- | --- | --- | --- |
| A | 1 | 4 s | 单峰基准，看电平与频点 |
| — | 0（静音） | 0.5 s | 切换缓冲，避免满幅咔哒 |
| B | 8 | 4 s | 峰数变成 8 |
| — | 0 | 0.5 s | |
| C | 32 | 20 s | 主测量窗：32 峰 |
| — | 0 | 0.5 s | |
| 循环 | | 共 29.5 s | |

- 参数：`TONE_FRAMES`（每段帧数）、`HOLD32_FRAMES`、`GAP_FRAMES`，tb 用短值覆盖。
- 写口就是测试块真正的 CSR 写口：`csr_valid=1, csr_write=1, csr_addr=8'hA0,
  csr_wdata={24'd0, N[5:0], 8'd1}`；写 0 关断。
- 输出 `demo_tone_count[5:0]` 供 GAO 当触发/标注。
- 为什么不让序列器直接改 `v2_test_mode` 内部计数：那要动既有 RTL；走 CSR 写口还顺带证明
  「换 N 只是一个寄存器写」，这一点对 V1 的「当场改变」有用。

### 4.2 频率与电平（都从 RTL 常量推得，不另立数据）

- `tone_phase_increment(k) = k × 19 685 267`，`f = inc × 48 000 / 2^32 = 220.0 × k Hz`。
- 每路先 `>>> 5`（1/32），单路峰值 ≈ 1024（−30.1 dBFS）；32 路求和在最后饱和到 16 bit。
- 于是「1 路很轻、32 路接近满幅」是设计如此，不是 bug；文档要写明，避免被当成电平缺陷。

## 5. 相对现有代码的改动面

| 文件 | 改动 | 理由 |
| --- | --- | --- |
| `rtl/v2_demo_sequencer.sv` | 新增 | 自走 N 序列 |
| `rtl/v2_demo_top.sv` | 新增 | 第二 top |
| `filelist.f` | 加两行（序列器在前、top 在后） | 编译顺序 |
| `MANIFEST.json` | `expected_top` → `expected_tops: ["v2_board_top", "v2_demo_top"]` | gate 只允许一个 root，否则第二 top 直接 FAIL |
| `scripts/gate.py` | 按 `expected_tops` 校验多个 root；其余 root 仍 FAIL | 同上 |
| `scripts/synth.py` | `--top`（默认 `v2_board_top`）；run 目录与报告名按 top；summary 记 top | 现在写死 `TOP = v2_board_top` |
| `scripts/synth_report.py` | `--top`（默认不变） | 现在写死 `top = "v2_board_top"` |
| `tb/tb_test_mode.sv` | 新增 | 测试块至今没有 tb；V2 的第一道证据 |
| `tb/tb_demo_top.sv` | 新增 | 证明序列与音频 mux |
| `host/spectrum.py` + `host/test_spectrum.py` | 新增 | FFT 数峰，标准库实现（不引入 numpy） |
| `gao/demo_tones.rao` | 新增 | 探针：`mixed_sample[15:0]`、`demo_tone_count[5:0]`、`sample_valid` |
| `docs/demo-dds-evidence.md` | 新增 | 给评委看的 RTL 佐证 + 实测频谱 |
| `docs/DEBUG-AND-FLASH.md` | 补一节「演示位流」 | 构建/烧录/验收命令 |

生产侧不动的部分：`mgc3130_v2_top.sv`、`v2_board_top.sv`、`v2_contract_pkg.sv`、
`v2_test_mode.sv`、所有约束文件。

## 6. 证据包（V1/V2/V3 → 具体动作）

| 判据 | 证据 | 产出 |
| --- | --- | --- |
| V1 | 序列器上电即按 1→8→32 走；GAO 抓 `demo_tone_count` 三段 | `artifacts/gao/demo_seq.csv` |
| V2（数字） | GAO 2048 点 @48 kHz（42.7 ms，23.4 Hz 分辨率）→ `host/spectrum.py --expect 32` | CSV + 峰表 |
| V2（模拟） | PCM5102A 线路输出录音（人做，44.1/48 kHz 均可，脚本按实际 fs 算） | WAV + 峰表 |
| V3 | 构建报告 **0 BSRAM / 0 DSP**；`v2_demo_top` 里没有 UART、没有音频存储；相位增量是常量 | `synth_summary.json` + §RTL 说明 |
| V3（反证） | 现场看 N 从 32 跳到 1 再跳到 8，峰数跟着变——录音无法做到 | 视频/截图 |
| 身份 | `synth_summary.json` 的 `top` + `bitstream_sha256`；行为上「上电即响」本身就是标志 | 记录 |

## 7. 门（缺一不算完成）

1. 先红后绿：`tb_test_mode` 在没有 DDS 输出时红，接上后绿；`tb_demo_top` 同理。
2. `python scripts/gate.py --compile` → `0 error(s), 0 warning(s)`。
3. `python scripts/sim.py` → PASS，失败集不超出基线（4 条已知）。
4. `python scripts/sim_unit.py --tb tb_test_mode`、`--tb tb_demo_top` → PASS。
5. `python scripts/synth.py --top v2_demo_top --run-id <id>` → SYNTH PASS；**BSRAM 必须是 0**，
   否则先查清楚是不是被推断成存储（那会推翻 V3 的说法）。
6. 演示位流不吃生产位的 `--min-slack -3.5`：它逻辑很小，应当 Fmax ≥ 80 MHz 通过；
   如果不过，那是真问题，不是门的问题。
7. 板上：烧 → 上电即响 → GAO 32 峰 → 模拟录音 32 峰 → 回烧生产位流并确认
   `0xB0=0x5A5A0003`、`0xA0` 读 0。

## 8. 风险

| 风险 | 对策 |
| --- | --- |
| 两个 top 让 gate 的「根」检查失效（真正的死模块被第二个 top 掩护） | gate 仍只允许 `expected_tops` 里的名字当根，其他 root 继续 FAIL |
| 端口表与 CST 不一致 → 综合报「port not found」 | 端口逐字照抄 `v2_board_top`，先跑 `gate.py --compile` 再综合 |
| 每段切换相位清零，32 路同相起振 → 满幅咔哒 | 段间插 0.5 s 静音；不追求无缝，演示位流不要求连续 |
| 2048 点 FFT 相邻峰只隔 9.4 bin，窗旁瓣可能把 1 个峰数成 3 个 | Hann 窗 + 局部极大值 + 相对门限，tb 与脚本用同一套判据 |
| 声卡采样率与板子 48 kHz 不同源 → 峰位偏移 | 脚本按 WAV 头里的 fs 换算，容差按 bin；记录实际 fs |
| GAO 2048 点只覆盖 42.7 ms，若触发点落在段间就抓到静音 | 触发用 `demo_tone_count==32` 的电平，`.rao` 里写明 |
| `v2_test_mode` 历史上没有 tb，第一次写 tb 可能暴露既有 bug | 这正是先红后绿的意义；发现 bug 单独记，不在本设计里顺手改 |

## 9. 留给构建者的（我的决定，不再问）

- 序列器用 Moore 状态机 + 帧计数器实现，状态数 ≤ 8，不引入第二个时钟域。
- `tb_test_mode` 用实数 DFT（ModelSim 支持 `$cos`/`real`）在 4096 点上判峰，不做 FFT。
- `host/spectrum.py` 用标准库 radix-2 FFT（2048/4096/8192 点），不引入 numpy。
- 文档《demo-dds-evidence.md》按「判据 → 证据 → 命令 → 数字」写，附 RTL 行号。

## 10. 开放项（需要用户回答的）

- 现场演示时是否允许用手机/声卡录音？若不允许，V2 只有 GAO 数字证据一条腿。
- 是否需要在演示位流里保留「静音 0」段以外的交互（例如按一下板上的键切换 N）？
  本设计按「完全自动、零交互」做。
