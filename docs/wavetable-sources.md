# 波表从哪来：AKWF（CC0）

> 2026-11-03。上一版波表是用谐波配方加出来的（`host/instrument_tables.py` 的 `RECIPES`），
> 五件乐器听起来像**同一件乐器在远近变化**——配方就是一条频谱，而频谱没有"身体"。
> 现在改用真实单周期波形。

## 来源与许可

| 项 | 值 |
| --- | --- |
| 集合 | **AKWF（Adventure Kid Waveforms）**，约 600 条单周期波形 |
| 许可 | **CC0 1.0**（公有领域奉献），可自由商用、可再分发；原文见 `artifacts/akwf/LICENSE-CC0.txt` |
| 镜像 | `DatanoiseTV/AKWF_WaveForms_1024`：每条重采样成 **1024+1 点 int16** 的 C 头文件 |
| 下载 | `python host/akwf_tables.py --family <名字>`（首次自动下载到 `artifacts/akwf/`） |

镜像里的每个头文件是一族（如 `AKWF_cello.h` 19 条），命名 `AKWF_cello_0015`。

## 已生成的六件

| 预设 | 波 | 12 次以上谐波能量（body） | 特点 |
| --- | --- | --- | --- |
| `akwf-eorgan` | `AKWF_eorgan_0037` | −12.9 dB | 加法合成的管风琴，厚 |
| `akwf-epiano` | `AKWF_epiano_0038` | −19.4 dB | 电钢琴，圆 |
| `akwf-violin` | `AKWF_violin_0007` | −17.6 dB | 弓弦，有共振峰 |
| `akwf-cello` | `AKWF_cello_0013` | −16.9 dB | 大提琴，低而暖 |
| `akwf-flute` | `AKWF_flute_0003` | −37.3 dB | 笛，接近正弦（本来是） |
| `akwf-oboe` | `AKWF_oboe_0003` | −36.6 dB | 双簧管，薄 |

每个乐器写三个**相位对齐**的帧：bright（截止以上提升，封顶 4×）/ body（22–26 次谐波以上按
`(cutoff/k)²` 衰减）/ dark（10–14 次谐波）。三帧共用**一个**归一化系数，所以 morph 是换音色不是换音量。

预设里 `wavetable.table = 1`：morph 关着时引擎只播一张表，**body** 才是该听的那张
（bright 是起音，dark 是另一个极端）。

## 怎么听

```powershell
# 一条命令：把 body 帧上传到预设指定的表槽，再写九个寄存器，最后进 LIVE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_instrument.ps1 -Instrument akwf-cello -Live
```

`-SkipUpload` 只写九个词（表已经在板上时用）。上传一张表约 **18 s**（逐点 ACK），换一件乐器就是一次上传。

## 换同一族里的另一条波

```powershell
python host/akwf_tables.py --family cello --top 5      # 该族打分前五
python host/akwf_tables.py --family cello --index 3    # 用第四名重建（覆盖同名前缀的目录）
```

排名考虑了：32 次以上谐波的能量（G4 会折返成毛刺）、显著谐波条数（太少=正弦，太多=嗡嗡）、
峰均比、占空比是否接近 50 %（否则会挑到窄脉冲，squ 族一开始就挑错了）。

## 已知限制

1. **预设文件不含帧数据**：只有 `wavetable`（表槽/增益/morph）与九个寄存器词，帧在
   `artifacts/wt/instruments/<name>/frame{0,1,2}.bin`（未入库，`artifacts/` 被忽略）。
   一键"应用预设 = 连波表一起上"还没做，现在是"预设 + 上传"两步。
2. `board_wt_upload.ps1` 逐点写、每点等 ACK，一帧 18 s；三帧 morph 约一分钟。
3. 这些表是**单周期**波形，板子按相位增量读，音高由音符号决定；表本身的谐波在第 32 次以上
   已经在 G4 折返，所以生成时就做了频段限制，不要再换更亮的版本。
