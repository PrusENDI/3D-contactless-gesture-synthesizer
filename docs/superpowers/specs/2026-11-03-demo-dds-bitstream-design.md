# 独立 DDS 演示位流设计（2026-11-03）

> 范围：只做**第二个位流**，生产位流与 `v2_board_top` 的行为一行不改。
> 上游：赛题「现场验证要求」第 3 条（用户 2026-11-03 提供原文）：
> 「支持测试模式下输出多路不同频率音频，频谱可观测对应数量独立谱峰，
> 同时可通过 RTL 代码佐证纯硬件实时合成通路，验证无预录音频播放行为。」
> 评审记录见 §11（独立评审者 2026-11-03 提了 5 条，全部已处理）。

## 1. 要求 → 三条判据

| 编号 | 判据 | 怎么算过 |
| --- | --- | --- |
| V1 | 多路、不同频率，且路数能当场改变 | N 依次为 1 / 8 / 32，每路频率 `220.000·k Hz`（k=1..N），**无主机参与** |
| V2 | 频谱上数得出 N 个独立谱峰 | **GAO 一路**：2048 点 @48 kHz（42.7 ms、23.4 Hz 分辨率）FFT，峰数 = N、位置落在 `220·k Hz ±1 bin`；模拟录音不进验收（用户 2026-11-03 选 C，见 §10） |
| V3 | RTL 可佐证纯硬件实时合成、无预录 | 位流里 **0 BSRAM、0 DSP、无 UART 实例**；每个样点由「相位累加器 + 单周期 256 点表 + 加法」当场算出；OLED 的字模与柱状图也是**组合算出来**的（§4.3）；并有一个录音做不到的实验：N 自己变，峰数跟着变 |

## 2. 为什么是独立位流，而不是生产位流加一个开关

1. 面积：`v2_test_mode` 实测 2544 LUT / 1153 reg。今天生产构建 CLS 10757–10824/11520（93.4%–94.0%），
   加回来约 11248（97.6%），P&R 余量太小；时序上 P1 那次对比 worst slack 从 −1.841 掉到 −3.148 ns，
   而生产门是 `--min-slack -3.5`（最近三次构建 −4.303 / −4.178 / −3.447，两次已经出红）。
2. 证据：V3 要的是「这个位流里的音频只能算出来」。生产位流里有 32 声部引擎、波表 BSRAM、
   主机上传通路，解释成本高；一个只有 DDS + I2S 的位流，把这件事讲到没有歧义。
3. 用户 2026-11-03 选定方案 C（最小 DDS 位流），放弃方案 A（同一 RTL 两套配置）。

## 3. 目标 / 非目标 / 反目标

**目标**

- 第二个可烧录位流 `v2_demo_top`，上电即输出测试音，不需要 UART、不需要 PC、不需要传感器。
- 32 路不同频率，`220.000·k Hz`（k=1..32，上限 7040.000 Hz）。
- N 自动循环 `1 → 8 → 32`，32 段保持 20 s，GAO 取窗（42.7 ms）有充足余量。
- 可复现的证据链：tb、GAO `.rao`、FFT 脚本、`synth_summary.json`（top + 资源 + sha256）、实测频谱。

**非目标**

- 不做乐器：无 32 声部引擎、无波表、无 MGC3130 读取、无 LIVE/LOOP、无传感器、无滤波器/FX/音量寄存器。
- 不新增 UART 或 CSR 契约；`v2_contract_pkg` 一行不改。
- 不改 `v2_test_mode` 的语义与端口（它是既有 RTL，改了要同时解释生产位流）。
- 不改生产位流的资源、时序与行为（见 §5.1 的口径）。

**反目标（做到这些就算失败）**

- 用「生产位流 + `USE_TEST_MODE=1`」冒充演示位流（面积/时序不允许，且证据最弱）。
- 拿主机上传的波表或 LIVE 录音当「纯硬件合成」证据。
- 只有听感、没有谱；或只有谱、没有 RTL/资源证据。

## 4. 结构

```
v2_demo_top            端口与 v2_board_top 完全相同（复用同一份 CST 与烧录脚本）
├── 音频路径（80 MHz 域）
│   ├── v2_clock_gen       50 MHz → 80 MHz（PLLA，现成）
│   ├── v2_reset_sync      PLL 锁定后才释放复位（现成）
│   ├── v2_sample_scheduler 80 MHz → 48 kHz sample_ce（现成）
│   ├── v2_demo_sequencer  （新）按帧计数：写 0xA0 的 N 字、拉静音、切段
│   ├── v2_test_mode #(MAX_TONES=32) （现成，零改动）32 路相位累加器 + 256 点单周期正弦表
│   ├── 静音闸门            （新，两个门级逻辑）mute 时输出 0，并按 sample_ce 打一次 valid
│   └── i2s_pcm5102a_tx    CLK_HZ=80_000_000 / SAMPLE_HZ=48_000 / ACC_WIDTH=24（现成）
└── 显示路径（50 MHz 域，与音频无数据通路，只同步 6 位 tone_count）
    ├── v2_oled_tones      （新）组合式画面：大号 "N=xx" + 32 根阶梯柱，0 BSRAM
    ├── v2_oled_static     （现成，零改动）SSD1306 初始化 + 刷整帧
    └── 刷新调度           （新，约 20 行）done 后等 N 变化，用复位脉冲重发整帧
```

### 4.3 OLED 显示（2026-11-03 追加，用户要求）

**显示什么**：第 0–15 行大号 `N=xx`（右对齐，1/8/32 三态）；第 16–63 行 **32 根阶梯柱**，
第 k 根高 k 像素、`k ≤ N` 时点亮。屏上同时给出「几路」和「32 个不同频率」两件事，
和频谱上的 N 个峰一一对应。

**怎么做到 0 BSRAM**：生产那套是「`v2_oled_image`（1 块 BSRAM 存图）+ 写一次」。
演示位流反过来——**画面是组合算出来的**：`img_addr = {page, col}` 与 `tone_count` 直接
产生该字节（大号字模 13 个字符 × 16 字节 = 208 字节放在 LUT 里；柱状图是行/列比较）。
所以整个演示位流 **0 BSRAM**，连显示都没有存储；这条让 V3 的说法更硬（见 gate §7）。

**怎么刷新**：`v2_oled_static` 是一次性的（`ST_DONE` 之后永不再动，`v2_oled_static.sv:240-247`），
而它不能改——它是生产 RTL。演示 top 用**复位脉冲重发**：`done` 之后等 `tone_count` 变化，
把 writer 的 `rst_n` 拉低几拍再放开，它重新走「面板复位 100 µs → 唤醒 100 ms → 初始化 → 刷整帧 8.6 ms」。
代价是每次换 N 屏会黑 ~110 ms（一轮 29.5 s 只发生 3 次），换来 writer 零改动、无复制。
`WAKE_CYCLES` 保持 100 ms：上电那次是屏手册要求，重复初始化时多等无害。

**跨域**：`tone_count` 在 80 MHz 域，writer 与刷新调度在 50 MHz 域（生产就是这么接的，
`v2_board_top` 用 `clk_50m`）。6 位准静态值走两级同步器 + 边沿检测，**不做握手**。

**资源预算**：字模 ~120 LUT、柱状图/地址译码 ~60 LUT、刷新调度 ~25 LUT + 20 寄存器、
writer 现有 ~190 LUT；0 BSRAM、0 DSP。演示位流总面积远低于器件（v2_test_mode 才 2544 LUT）。

**演示位流的音频通路有两个元件，不是一个**（评审第 1 条逼出来的）：

1. `v2_test_mode` 的 `mixed_sample`；
2. 静音闸门：`mute` 时 `i2s_sample_in = 16'sd0`、`i2s_sample_valid = sample_ce`。

为什么必须有它：写「关断」字以后，`v2_test_mode` 只把 `mixed_sample` 清 0，**`sample_valid` 一直是低**
（`rtl/v2_test_mode.sv:412-420`），而 I2S 只在 `sample_valid` 时锁存（`rtl/i2s_pcm5102a_tx.sv:36-37`），
于是 DAC 保持上一个样点——那不是静音，是一个 DC 台阶，正是段间空隙要避免的那种咔哒。
闸门让空隙变成真正的 48 kHz 零样点序列，代价是 2 LUT + 1 个寄存器，文档和 tb 都要把它算进通路。

- 未用端口：`uart_tx = 1'b1`（空闲高），`mgc_sda/scl/ts/mclr = 1'bz`，`uart_rx` 不接。
  端口名与 `v2_board_top` 逐字相同，因此 `constr/mgc3130_v2.cst` 不用改；
  烧录脚本是 `C:/weizijian/documents/gowin fpga/mgc3130_uart/.worktrees/v2-integration/scripts/board_program.ps1`
  （见 `docs/DEBUG-AND-FLASH.md:46`，它只吃 `-FsFile`，也不用改）。

### 4.1 序列（`v2_demo_sequencer`）

| 段 | N | 时长（默认参数） | 作用 |
| --- | --- | --- | --- |
| A | 1 | 4 s | 单峰基准，看电平与频点 |
| 空隙 | 静音（闸门） | 0.5 s | 真零输出；下一段的 N 字在这段里写 |
| B | 8 | 4 s | 峰数变成 8 |
| 空隙 | 静音 | 0.5 s | |
| C | 32 | 20 s | 主测量窗：32 峰 |
| 空隙 | 静音 | 0.5 s | |
| 循环 | | 共 29.5 s | |

- 参数：`TONE_FRAMES`、`HOLD32_FRAMES`、`GAP_FRAMES`；tb 用短值覆盖。
- **CSR 字（评审第 4 条，以 RTL 为准）**：
  - 开/换 N：`csr_wdata = 32'h0000_0000 | (N << 8) | 8'h01`（selector=1 在 `[7:0]`，count 在 `[13:8]`）；
  - 关断字：`32'h0000_0001`（selector=1、count=0；`rtl/v2_test_mode.sv:388-399` 的唯一合法关断方式）；
  - **绝不能写 `32'h0000_0000`**：selector≠1 会置 `fault`（粘滞、永不清零），且 `tone_count` 不变，
    于是「关断」根本不发生。
- 序列器只写 N 字，不写关断字：关断由静音闸门做，少一条只用一半的路径。
- 输出 `demo_tone_count[5:0]` 供 GAO 当触发/标注，`demo_muted` 供排查。
- 为什么不让序列器直接改 `v2_test_mode` 内部计数：那要动既有 RTL；走 CSR 写口还顺带证明
  「换 N 只是一个寄存器写」，这一点对 V1 的「当场改变」有用。

### 4.2 频率与电平（都从 RTL 常量推得）

- `tone_phase_increment(k) = k × 19 685 267`，`f = inc × 48 000 / 2^32 = **220.000** × k Hz`
  （k=1 → 220.000 Hz，k=8 → 1760.000 Hz，k=32 → 7040.000 Hz）。
- 每路先 `>>> 5`（1/32），单路峰值 1024 = **−30.10 dBFS**；32 路求和 32768，正好顶到 16 bit 饱和（削掉 1 LSB）。
- 于是「1 路很轻、32 路接近满幅」是设计如此，不是 bug；证据文档要写明，避免被当成电平缺陷。

## 5. 相对现有代码的改动面

| 文件 | 改动 | 理由 |
| --- | --- | --- |
| `rtl/v2_demo_sequencer.sv` | 新增 | 自走 N 序列 + 静音控制 |
| `rtl/v2_demo_top.sv` | 新增 | 第二 top（含静音闸门与刷新调度） |
| `rtl/v2_oled_tones.sv` | 新增 | 组合式画面：大号 `N=xx` + 32 根阶梯柱，0 BSRAM（§4.3） |
| `filelist.f` | 加两行（序列器在前、top 在后） | 编译顺序 |
| `MANIFEST.json` | 加 `expected_tops: ["v2_board_top", "v2_demo_top"]`，保留 `expected_top` | gate 读列表；保留旧键让 `bootstrap.py` 重跑时至少能起一个明确的失败 |
| `scripts/gate.py` | 按 `expected_tops` 校验多个 root；其他 root 仍 FAIL | 现在只允许一个 root（`gate.py:174-177`） |
| `scripts/synth.py` | `--top`（默认 `v2_board_top`）；gprj/run 目录/报告名按 top；summary 记 top；新增 `--min-fmax`（默认关） | 现在写死 `TOP`/`PROJECT_NAME`；`gate_fail` 只查 CLS 与 slack（`synth_report.py:79-92`），没有 fmax 门 |
| `scripts/synth_report.py` | 从 run 目录里的 `*.rpt.txt` 自动发现 top，不再写死 | 现在写死 `top = "v2_board_top"` |
| `tb/tb_test_mode.sv` | 新增 | 测试块至今没有 tb；V2 的第一道证据 |
| `tb/tb_demo_top.sv` | 新增 | 证明序列、CSR 字与静音闸门 |
| `host/spectrum.py` + `host/test_spectrum.py` | 新增 | 读 GAO CSV、FFT 数峰；标准库实现（不引入 numpy），不读 WAV |
| `gao/demo_tones.rao` | 新增 | 探针：`u_i2s/sample_latched[15:0]`（真正串行出去的 16 位字）、`demo_tone_count[5:0]`、`demo_muted` |
| `docs/demo-dds-evidence.md` | 新增 | 给评委看的 RTL 佐证 + 实测频谱 |
| `docs/DEBUG-AND-FLASH.md` | 补一节「演示位流」 | 构建/烧录/验收命令 |

生产侧不动的部分：`mgc3130_v2_top.sv`、`v2_board_top.sv`、`v2_contract_pkg.sv`、
`v2_test_mode.sv`、`v2_oled_static.sv`、`v2_oled_image.sv`、所有约束文件。

### 5.1 「生产位流不变」怎么算数（评审第 2 条）

`synth.py` 用整份 `filelist.f` 生成项目，所以加了两个源文件以后**生产项目也包含它们**。口径如下：

- 生产层级里没有任何实例化点指向 `v2_demo_*`，综合会把这些未达模块删掉，网表不变；
- 因此本特性**不欠一次生产重构建**，也不把生产门（`--min-slack -3.5`，现在余量 0.05 ns）绑到本特性上；
- 证明方式：`v2_board_top.sv` / `mgc3130_v2_top.sv` 的 diff 为空（本轮不碰），加一个 gate 断言
  「`v2_demo_*` 不出现在生产 top 的实例化里」；
- 如果用户要求一次对照构建，那是**另一个任务**（且必须在工作区 RTL 干净时做——
  现在 `rtl/mgc3130_v2_top.sv` 有未提交的 `mode_rw_q` 实验，拿它当基线会得出错的结论）。

## 6. 证据包（V1/V2/V3 → 具体动作）

| 判据 | 证据 | 产出 |
| --- | --- | --- |
| V1 | 序列器上电即按 1→8→32 走；GAO 抓 `demo_tone_count` 三段 | `artifacts/gao/demo_seq.csv` |
| V2 | GAO 2048 点 @48 kHz（42.7 ms，23.4 Hz 分辨率），探针是 `u_i2s/sample_latched`（I2S 真正串出去的字）→ `host/spectrum.py --expect 32` | CSV + 峰表 |
| V3 | 构建报告 **0 BSRAM / 0 DSP**；`v2_demo_top` 里没有 UART、没有音频存储；相位增量是常量 | `synth_summary.json` + evidence 文档 |
| V3（反证） | **同一次上电、不重烧**，在 N=1 与 N=32 两段各抓一次，两次的峰数是 1 和 32；录音做不到「同一个位流、同一秒的窗口里换 N」 | 两个 CSV + 两份峰表 |
| 身份 | `synth_summary.json` 的 `top` + `bitstream_sha256`；行为上「上电即响」本身就是标志 | 记录 |

**采样时钟口径（评审第 5 条）**：GAO 必须 `sample_clock="pcm5102a_lrck"`（48 kHz），
照抄 `gao/i2s_pitch.rao` / `gao/tick_period.rao`；**不要**照抄 `gao/apply.rao` / `gao/play.rao`
（它们用 80 MHz，2048 点只覆盖 25.6 µs，约 1 个音频样点）。
tb 的时钟是 **80 MHz（12.5 ns）**，不是既有 top tb 常用的 `#5`：`v2_sample_scheduler` 按
`SYSTEM_RATE_HZ=80_000_000` 分频，若 tb 跑 100 MHz，`sample_ce` 变成 60 kHz，所有音高会偏到 `275·k`，
DFT 断言必红。`v2_test_mode.sv:353-355` 里「2083 clocks at 100 MHz」是**过期注释**，
按「零改动」原则不修，但 evidence 文档要标一句。

## 7. 门（缺一不算完成）

1. 先红后绿：`tb_test_mode` 在没有 DDS 输出时红，接上后绿；`tb_demo_top` 同理。
2. `python scripts/gate.py --compile` → `0 error(s), 0 warning(s)`。
3. `python scripts/sim.py` → PASS，失败集不超出基线（4 条已知）。
4. `python scripts/sim_unit.py --tb tb_test_mode`、`--tb tb_demo_top`、`--tb tb_oled_tones` → PASS。
5. `python scripts/synth.py --top v2_demo_top --run-id <id> --min-fmax 80` → SYNTH PASS；
   **BSRAM 必须是 0**，包括显示：字模必须在 LUT 里（推断成 BSRAM 就说明画面被存起来了，
   既推翻 V3 也说明 composer 写成了 ROM）；DSP 也必须是 0；
   fmax ≥ 80 MHz 由新加的 `--min-fmax` 真正判定，不再是一条没人执行的评审意见。
6. 板上：烧 → 上电即响 → 同一次上电里抓 N=32（32 峰）与 N=1（1 峰）两次 →
   回烧生产位流并确认 `0xB0=0x5A5A0003`、`0xA0` 读 0。
   模拟录音**不进验收**：本机 3.5mm 是耳麦麦克风口、没有线路输入（§10），
   evidence 文档第一页就要写明「V2 的证据是数字域，不是模拟域」。

## 8. 风险

| 风险 | 对策 |
| --- | --- |
| 两个 top 让 gate 的「根」检查失效（真正的死模块被第二个 top 掩护） | gate 仍只允许 `expected_tops` 里的名字当根，其他 root 继续 FAIL |
| 端口表与 CST 不一致 → 综合报「port not found」 | 端口逐字照抄 `v2_board_top`，先跑 `gate.py --compile` 再综合 |
| 每段切换相位清零，32 路同相起振 → 满幅台阶 | 段间真静音 0.5 s（闸门），且 N 字在静音段里写，起振瞬间不可闻 |
| 2048 点 FFT 相邻峰只隔 9.4 bin，窗旁瓣可能把 1 个峰数成 3 个 | Hann 窗 + 局部极大值 + 相对门限，tb 与脚本用同一套判据 |
| 只有数字域一条腿（用户选 C） | 证据文档开篇写明「V2 是 GAO 抓 I2S 发送寄存器」，并给两次不同 N 的 CSV；不申报 SNR/THD/底噪 |
| GAO 2048 点只覆盖 42.7 ms，触发点落错就抓到静音 | 触发用 `demo_tone_count==32` 且 `demo_muted==0` 的电平，`.rao` 里写明 |
| 写 `N=32` 时 `ser_term` 会在发布那一拍读 `phase[32]`（数组是 `[0:31]`） | 无害（发布拍不用 `ser_term`），但新 tb 会刷越界告警；tb 里注明，不顺手改既有 RTL |
| `v2_test_mode` 历史上没有 tb，第一次写 tb 可能暴露既有 bug | 这正是先红后绿的意义；发现 bug 单独记，不在本设计里改 |
| 工作区现在有未提交的 `rtl/mgc3130_v2_top.sv`（`mode_rw_q` 实验） | 本特性不碰它；任何生产基线都按「工作区当前状态」记，不能用 HEAD 冒充 |
| 每次换 N 屏黑 ~110 ms（复位脉冲重发整帧） | 一轮只发生 3 次；若现场观感差，再改成可重发 writer（复制 `v2_oled_static` 改状态机），那是另一个任务 |
| 字模若被推断成 BSRAM，`0 BSRAM` 的说法就破了 | 字模写成 `case` 函数（组合），构建门硬查 BSRAM=0；变成 1 就查是不是写了 `mem[]` |
| 50 MHz 与 80 MHz 两个域，`tone_count` 跨域 | 两级同步器 + 边沿检测；该值 4 s 才变一次，不做握手 |
| 屏初始化序列与实物不符（SH1106 / 列偏移） | 沿用生产已验过的 `v2_oled_static` 初始化表，不改；只在板上确认"能显示" |

## 9. 留给构建者的（我的决定，不再问）

- 序列器用 Moore 状态机 + 帧计数器，状态数 ≤ 8，单时钟域。
- `tb_test_mode` 用实数 DFT（ModelSim 支持 `$cos`/`real`）在 4096 点上判峰，不做 FFT。
- `host/spectrum.py` 用标准库 radix-2 FFT（2048/4096/8192 点），只读 GAO CSV，不引入 numpy。
- 证据文档按「判据 → 证据 → 命令 → 数字」写，附 RTL 行号。

## 10. 开放项（已定）

- **模拟录音：不做**（用户 2026-11-03 选 C）。这台 ASUS Vivobook Pro 15 `N6506MV` 的 3.5mm 是
  `1x 3.5mm Combo Audio Jack`（[ASUS 规格](https://www.asus.com/bn/laptops/for-home/vivobook/asus-vivobook-pro-15-oled-n6506/techspec/)），
  Windows 里只有三个**采集**端点（Intel 麦克风阵列、Realtek「麦克风」、NICEHCK USB 的「麦克风」），
  **没有线路输入**；直接接线路输出要 −37 dB 衰减 + 耳麦分线器 + 关降噪，且单声道、电平不可信。
  所以 V2 只报数字域，模拟录音不进验收、不申报 SNR/THD。
- 交互按「完全自动、零交互」做：现场看 N 变化最多等 25 s（1→8→32 一轮 29.5 s 里的前 8.5 s）。

## 11. 评审记录（2026-11-03，独立评审者）

| # | 评审发现 | 处理 |
| --- | --- | --- |
| 1 | 写关断字后 `sample_valid` 一直低，I2S 保持上个样点 → 空隙是 DC 台阶，不是静音 | 加静音闸门（§4），通路从「一个 mux」改成「测试块 + 闸门两个元件」，tb 与文档同步 |
| 2 | `filelist.f` 变更会进生产项目；生产门余量只有 0.05 ns | 明确不欠生产重构建（§5.1），并写清怎么证明生产网表不变 |
| 3 | §10 的录音许可未答，直接决定 V2 的证据组 | 用户 2026-11-03 选 C：不做模拟录音（见第 6 行） |
| 4 | CSR 字写错：`{24'd0,N,8'd1}` 是 38 位；`0x0` 不是关断（会置粘滞 fault） | 改成 `(N<<8)|1`、关断字 `0x0000_0001`、禁止写 `0x0`（§4.1） |
| 5 | `v2_test_mode` 注释写 100 MHz，实际 80 MHz；tb 跑 100 MHz 会让音高变 275·k；`.rao` 采样时钟选错只覆盖 1 个样点 | tb 固定 80 MHz、`.rao` 固定 `pcm5102a_lrck`，过期注释标注不改（§6） |
| 附 | `--min-fmax` 今天没有任何执行点 | `synth.py` 新增 `--min-fmax`，演示位流按 80 MHz 判（§7.5） |
| 6 | 这台电脑能不能录线路输出：`N6506MV` 3.5mm 是 combo 耳麦口，Windows 只有麦克风采集端点、无线路输入 | 用户选 C：模拟录音不进验收；V2 只报 GAO 数字域，开篇写明（§10） |
| 7 | 用户追加：测试模式要加 OLED 显示（2026-11-03） | §4.3：复用生产 writer（零改动）+ 组合式画面（0 BSRAM）+ 复位脉冲刷新；新增 `v2_oled_tones` 与 `tb_oled_tones` |
| 附 | `board_program.ps1` 不在本仓库 | 文档给出真实路径（§4） |
