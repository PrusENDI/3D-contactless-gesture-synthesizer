# 演示位流证据（DDS 32 音 + OLED）

> 判据来自赛题「现场验证要求」第 3 条，设计见
> `docs/superpowers/specs/2026-11-03-demo-dds-bitstream-design.md`。
> 本文件只记**实测数字与命令**；没做过的写「未做」。

## 1. 位流身份

同一份 RTL，两种构建（`synth.py --top v2_demo_top`）：

| 用途 | run 目录 | sha256 | BSRAM | CLS | fmax |
| --- | --- | --- | --- | --- | --- |
| **放音**（屏上是李萨如） | `impl/v2_demo_top_scope_play2` | `f2db277a2218b5fdbaa8fc986d93083b4214c0f29593fe4f3173e938294f921e` | 1/56 | 1825/11520 | 98.2 MHz |
| **抓谱**（同一 RTL + GAO 探针） | `impl/v2_demo_top_scope_probe2` | `af2779151e61e3ef4820be9d87acf5d1c930a1fbe3aac5601a9df45450573e45` | 4/56（1 帧缓冲 + 3 探针） | 2154/11520 | 151.6 MHz |

放音位流：Logic 2797、Register 1613、**DSP 0**；**0 个 setup 违约端点**，worst slack **+2.312 ns**
（`u_test/ser_index_4_s1`）。抓谱位流同样 0 违约、worst +0.104 ns。

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

## 4. 屏上显示什么（李萨如示波器）

- 画面是**音频本身**：`x` = 55 个样点之前的采样（220 Hz 的 1/4 周期），`y` = 当前采样。
  单音画圆、2:1 画 8 字、32 音是一片云。
- 1 KB 帧缓冲（**1 块 BSRAM**，`u_fb`）+ 点绘器（每 16 个样点画一点，3 k 点/秒）+
  连续刷屏（1048 字节/帧，1 MHz SPI ≈ 8.4 ms，加帧间隔约 30 fps）。
- 刷屏时把每个字节右移一位写回，旧点自然消退——示波器的余辉。
- 帧缓冲是两个端口：A 给点绘器做读-改-写，B 给刷屏读+衰减写；两个口都遵守
  「读的那一拍自己的写使能为 0」，否则 Gowin 会报 `PA2122`（不支持的 BRAM 写模式）。

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
