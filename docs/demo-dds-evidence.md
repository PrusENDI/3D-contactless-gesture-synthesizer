# 演示位流证据（DDS 32 音 + OLED）

> 判据来自赛题「现场验证要求」第 3 条，设计见
> `docs/superpowers/specs/2026-11-03-demo-dds-bitstream-design.md`。
> 本文件只记**实测数字与命令**；没做过的写「未做」。

## 1. 位流身份

同一份 RTL，两种构建（`synth.py --top v2_demo_top`）：

| 用途 | run 目录 | sha256 | BSRAM | CLS | fmax |
| --- | --- | --- | --- | --- | --- |
| **放音**（烧这块听/演示） | `impl/v2_demo_top_demo_play` | `d21f7915676f23deb2088a10e3d31e908a4a2f99bfdb88d9c3c1d76d11344286` | **0** | 1345/11520 | 135.0 MHz |
| **抓谱**（带 GAO 探针） | `impl/v2_demo_top_demo_final` | `5f499d87be570e230371971f40d0a2d9fe6db0ce1d7f5b2453903949fb35482e` | 3/56（探针的采样存储） | 1745/11520 | 147.7 MHz |

放音位流：Logic 2438、Register 1090、**DSP 0、BSRAM 0**。
抓谱位流多出的 3 块 BSRAM 全在 GAO 采样器里，不在音频通路。

**时序说明（不藏）**：放音位流 3 个 setup 违约端点、worst −1.263 ns（`u_seq/csr_wdata_8_s0`）；
抓谱位流 23 个、worst −1.687 ns。两者的 fmax 都远高于 80 MHz 约束，门的 `--min-fmax 80`
与 `--min-slack -3.5` 都过，但这几条路径还没有收干净。

## 2. 判据 → 证据

| 判据 | 证据 | 状态 |
| --- | --- | --- |
| V1 多路、不同频率、路数能变 | 序列器按 1(4 s) → 8(4 s) → 32(20 s) 自动走，段间 0.5 s 真静音；`tb_demo_seq` 9 次写的字与顺序全对 | **tb 通过，板上未抓** |
| V2 频谱 N 个独立峰 | `tb_test_mode` 用 Goertzel 在 2048 点上判峰：N=1/8/32 → 峰数 1/8/32，峰/中点功率比 ≈ 10^5；GAO 脚本与 `host/spectrum.py` 就绪 | **仿真级通过，板上未抓** |
| V3 纯硬件合成、无预录 | 放音位流 **DSP 0、BSRAM 0、无 UART 实例**；每样点 = 相位累加器 + 256 点单周期表 + 加法（`rtl/v2_test_mode.sv:361-437`） | **构建级通过** |

频率是常量推出来的：`tone_phase_increment(k) = k × 19 685 267`，`f = inc × 48 000 / 2^32 = 220.000 × k Hz`
（k=1 → 220.000，k=32 → 7040.000）。每路先 `>>> 5`，单路 −30.10 dBFS；32 路求和 32768，正好顶到饱和。

## 3. 测试证据（全部可重跑）

| 命令 | 结果 |
| --- | --- |
| `python scripts/gate.py --compile` | `GATE: PASS`，compiler 0 error / 0 warning |
| `python scripts/sim_unit.py --tb tb_test_mode` | PASS：N=1/8/32 → 1/8/32 个峰，峰/中点功率比 142526 / 111284 / 128565 |
| `python scripts/sim_unit.py --tb tb_demo_seq` | PASS：9 次写、0 错误、末态 count 32 |
| `python scripts/sim_unit.py --tb tb_oled_tones` | PASS：第 k 根柱高 k 像素；`N=1/8/32/0` 各自正确；字模字节与 5×7 表逐字节相同 |
| `python scripts/sim_unit.py --tb tb_demo_top` | PASS：96 帧、静音段 24 帧全 0、有声段 48 帧非 0、屏被写 5 次 |
| `python -m unittest host.test_spectrum` | 10 条 OK（32 音→32 峰、1 音→1 峰、补码、命令行退出码） |
| `python scripts/synth.py --top v2_demo_top --run-id demo_play --min-fmax 80` | `SYNTH: PASS`，数字见 §1 |

## 4. 屏上显示什么

- 第 0–13 行：`N=xx`（5×7 字模放 2 倍，列 32..95，16 px 步距）。
- 第 16–63 行：32 根阶梯柱，3 px 宽 / 4 px 步距，第 k 根高 k 像素，`k ≤ N` 时点亮。
- 画面**全部组合逻辑**，没有 BSRAM：所以放音位流连一块块存储都没有。
- 刷新：`v2_oled_static` 是一次性的，演示 top 通过拉低它的 `rst_n` 重发整帧；每次换 N 屏黑约 110 ms，
  一轮 29.5 s 只发生 3 次。

## 5. 板上步骤（**未做**，用户要求先不烧）

```powershell
# 1) 烧抓谱位流（它同时也放音）
powershell -File "C:/weizijian/documents/gowin fpga/mgc3130_uart/.worktrees/v2-integration/scripts/board_program.ps1" `
  -FsFile "C:/weizijian/documents/gowin fpga/mgc3130_demo/impl/v2_demo_top_demo_final/impl/pnr/ao_0.fs" -Operation 4

# 2) 等它走到 32 段（上电 1 s 内是 0.5 s 静音 + 4 s 单音 + 0.5 s 静音 + 4 s 八音），再抓
python scripts/gao_capture.py --rao gao/demo_tones.rao --out artifacts/gao/demo32.csv
python host/spectrum.py --csv artifacts/gao/demo32.csv --column sample_latched --expect 32

# 3) 回到 1 段再抓一次
python scripts/gao_capture.py --rao gao/demo_tones.rao --out artifacts/gao/demo1.csv
python host/spectrum.py --csv artifacts/gao/demo1.csv --column sample_latched --expect 1

# 4) 回烧生产位流并确认
#    0xB0 = 0x5A5A0003、0xA0 读 0
```

抓谱的三个坑（都是刚踩的，写在 `.rao` 里）：
1. 探针的 `sample_clock` 必须是 `u_i2s/i2s_lrck`（48 kHz），用系统时钟 2048 点只覆盖 1 个音频样点；
2. 触发不能写位选（`demo_tone_count[5]`）→ `PJ0005`；用 `demo_muted == 0` 这个电平触发；
3. `.rao` 里**不能放带 `<...>` 字样的 XML 注释**，否则同样 `PJ0005`（这条注释因此删掉了）。

## 6. 未做清单

- 板上：烧、听、抓谱、屏的实拍（用户明确「先不要烧板」）。
- 生产位流回烧与 `0xB0/0xA0` 复核（要在板上做完上一步才有意义）。
- 生产侧对照构建：按设计 §5.1 不欠；工作区 RTL 干净时再议。
