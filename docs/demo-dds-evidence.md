# 演示位流证据（DDS 32 音 + OLED）

> 判据来自赛题「现场验证要求」第 3 条，设计见
> `docs/superpowers/specs/2026-11-03-demo-dds-bitstream-design.md`。
> 本文件只记**实测数字与命令**；没做过的写「未做」。

## 1. 位流身份

同一份 RTL，两种构建（`synth.py --top v2_demo_top`）：

| 用途 | run 目录 | sha256 | BSRAM | CLS | fmax |
| --- | --- | --- | --- | --- | --- |
| **放音**（屏上是 `N=xx` + 32 根阶梯柱） | `impl/v2_demo_top_bars_play2` | `375c197f5c8427f7d7cc033d8c89bc2804f520272fde73677ffe89571c020c21` | **0** | 1345/11520 | 135.0 MHz |
| **抓谱**（同一 RTL + GAO 探针） | `impl/v2_demo_top_bars_probe2` | `d6a5b2d9fe3794e241164bce80c7caf3790f41f79f83276f9421a40f3818fc31` | 3/56（全是探针） | 1745/11520 | 147.7 MHz |

放音位流：Logic 2438、Register 1090、**DSP 0、BSRAM 0**——音频与显示都没有块存储。
时序（不藏）：放音 3 个 setup 违约端点、worst −1.263 ns；抓谱 23 个、worst −1.687 ns。
fmax 都高于 80 MHz，门都过，但这几条路径没抽干净。

## 2. 判据 → 证据

| 判据 | 证据 | 状态 |
| --- | --- | --- |
| V1 多路、不同频率、路数能变 | 序列器按 1(4 s) → 8(4 s) → 32(20 s) 自动走，段间 0.5 s 真静音；`tb_demo_seq` 9 次写的字与顺序全对 | **tb 通过，板上未抓** |
| V2 频谱 N 个独立峰 | `tb_test_mode` 用 Goertzel 在 2048 点上判峰：N=1/8/32 → 峰数 1/8/32，峰/中点功率比 ≈ 10^5；GAO 脚本与 `host/spectrum.py` 就绪 | **仿真级通过，板上未抓** |
| V3 纯硬件合成、无预录 | 音频通路 **DSP 0、BSRAM 0、无 UART 实例**；每样点 = 相位累加器 + 256 点单周期表 + 加法（`rtl/v2_test_mode.sv:361-437`）。屏有 1 块帧缓冲，在 `u_fb` 里、不在音频层级 | **构建级通过 + 板上 32 峰** |

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

## 4. 屏上显示什么（数字 + 条带）

- 第 0–13 行：`N=xx`（5×7 字模放 2 倍，列 32..95，16 px 步距）。
- 第 16–63 行：32 根阶梯柱，3 px 宽 / 4 px 步距，第 k 根高 k 像素，`k ≤ N` 时点亮。
- 画面**全部组合逻辑**，没有 BSRAM：所以放音位流连一块块存储都没有。
- 刷新：`v2_oled_static` 是一次性的，演示 top 通过拉低它的 `rst_n` 重发整帧；每次换 N 屏黑约 110 ms，
  一轮 29.5 s 只发生 3 次。

**试过李萨如，已改回（2026-11-03 晚）**：音频驱动的 XY 示波器（`v2_oled_scope_*`，提交 `2dfb05b`
与 `8b8033a`）在板上能用，但 32 个音都是 220 Hz 的谐波且初相全为 0，同相相加是**每 4.5 ms 一次的
窄脉冲串**——脉冲串的 XY 图必然退化成十字（`artifacts/scope_zero.png` 是硬件同一算法的预览，
和屏上看到的完全一致）。要好看就得给每个音加不同初相（会改变音色）或改画时域波形，
用户选择改回数字 + 条带。示波器代码仍在 git 历史里，随时可取回。

## 5. 板上结果（2026-11-03 晚，已烧已抓）

```powershell
powershell -File ".../board_program.ps1" -FsFile ".../impl/v2_demo_top_scope_probe2/impl/pnr/ao_0.fs" -Operation 4
# PROGRAM PASS
python scripts/gao_capture.py --rao gao/demo_tones.rao --out artifacts/gao/scope32.csv --cable FT2CH
python host/spectrum.py --csv artifacts/gao/scope32_core0.csv --column sample_latched --expect 32
```

实测（两次独立烧录后各抓一次，都是 32 峰）：

```
capture : artifacts/gao/scope32_core0.csv
column  : u_i2s/sample_latched[15:0]
samples : 2048 (42.7 ms at 48000 Hz)
peaks   : 32      220.0→210.9  440→445.3  660→656.2  880→890.6  1100→1101.6 ...
```

- `gao_sh` 会在文件名后加 `_core0`（`demo32.csv` → `demo32_core0.csv`），脚本里要按实际路径。
- 抓取时刻由 `demo_muted==0` 电平触发，`demo_tone_count` 同时被采回来：
  `t=0 initial ... demo_tone_count = 0x20` 就是「这一窗是 32 路」的证据。
- 1 音段的独立抓取还没命中（32 段占 20 s，随机抓到的概率最高；抓到过 8 段与 32 段）。
  `tb_test_mode` 与 `tb_oled_scope` 已覆盖「N=1 → 1 个源」「点绘/衰减正确」，板上 1 音单抓留待下次。

抓谱的三个坑（都是刚踩的，写在 `.rao` 里）：
1. 探针的 `sample_clock` 必须是 `u_i2s/i2s_lrck`（48 kHz），用系统时钟 2048 点只覆盖 1 个音频样点；
2. 触发不能写位选（`demo_tone_count[5]`）→ `PJ0005`；用 `demo_muted == 0` 这个电平触发；
3. `.rao` 里**不能放带 `<...>` 字样的 XML 注释**，否则同样 `PJ0005`（这条注释因此删掉了）。

## 6. 未做清单

- 板上：烧、听、抓谱、屏的实拍（用户明确「先不要烧板」）。
- 生产位流回烧与 `0xB0/0xA0` 复核（要在板上做完上一步才有意义）。
- 生产侧对照构建：按设计 §5.1 不欠；工作区 RTL 干净时再议。
