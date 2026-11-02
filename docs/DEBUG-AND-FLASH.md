# 调试与烧录手册（2026-10-31）

本文件把这一阶段用到的**构建、烧录、板上调试、GAO 抓波形**方法固化下来，
目标是下次任何人（包括未来的我）不用重新踩坑。

工程根：`C:\weizijian\documents\gowin fpga\mgc3130_clean`
板卡：Tang Primer 25K（GW5A-LV25MG121NES），串口 **COM4 @ 1 Mbaud**。

---

## 1. 构建链（四道闸门，前一道不过不进下一道）

| 层 | 命令 | 判据 |
| --- | --- | --- |
| L0 静态 | `python scripts/gate.py` | 无重复模块、单一顶层、filelist 内每模块都被实例化 |
| L1 编译 | `python scripts/gate.py --compile` | **0 error / 0 warning**（CRLF 警告也会被点名） |
| L2 仿真 | `python scripts/sim.py` | 失败集合 ⊆ `sim_baseline.json` |
| L3 综合 | `python scripts/synth.py --run-id <名字>` | `SYNTH: PASS`，输出 `synth_summary.json` |
| L4 网表 | Gowin GAO 版位流必须 `check_synth_netlist` 类检查 | 无输出被接 GND、无未驱动控制网 |

仪器化构建（带 GAO 探针）：

```powershell
python scripts/synth.py --run-id gao_x --gao gao/apply.rao
```

产物在 `impl/v2_board_top_<run-id>/impl/pnr/`：
- 普通构建 → `v2_board_top.fs`
- GAO 构建 → **`ao_0.fs`**（名字不同，别找错）

### 1.1 构建产物必须记录身份

```powershell
$fs = (Resolve-Path 'impl\v2_board_top_<run>\impl\pnr\ao_0.fs').Path
"sha256: " + (Get-FileHash $fs -Algorithm SHA256).Hash
(Get-Item $fs).LastWriteTime
```

写进 `artifacts/board/bitstream_identity.log`。**没有 sha256 的板测结论一律不认。**

---

## 2. 烧录

```powershell
$prog='C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-integration\scripts\board_program.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File $prog -FsFile $fs -Operation 4
```

- 必须传**绝对路径**（脚本在另一个工作树里，相对路径会找不到）；
- 成功标志：`PROGRAM PASS: device answers after programming.`
- 烧完**等 3–5 秒**再发命令（传感器复位序列 + 上电稳定）。

### 2.1 烧后自检（每次必做）

```powershell
python host\cursor_view.py --console-only --seconds 3
```

或读常数寄存器 `0xB0`，必须等于 **`0x5A5A0003`**。
不等于 → 位流不对或串口没连上，**不要继续往下测**。

---

## 3. 串口命令协议（主机侧）

- 1 Mbaud、8N1、无流控
- 命令帧 11 字节：`A5 02 op addr seq data[4] crc16[2]`（CRC16-CCITT，覆盖前 9 字节）
- 应答帧 22 字节：`5A 02 type 00 seq … [11]=status [12]=terminal [14..17]=rsp_data [19]=error [20..21]=CRC`
- `op`: `0x01`=读，`0x02`=写
- 地址必须落在合法区段，否则回 `err=2 (BAD_ADDRESS)`：
  `0x00–0x44` legacy/loop、`0x60–0x7C` wavetable、
  `0x80–0x9C` telemetry、`0xA0–0xAF` test、`0xB0–0xFC` diag
  （`0x48–0x5C` 的 patch 窗口已随 `v2_patch_bank` 删除；写/读实测回 `0x02`）

### 3.1 现用调试寄存器表（`V2_DEBUG_CSR=1` 时有效）

| 地址 | 内容 |
| --- | --- |
| 0xB0 | 常数 `0x5A5A0003`（位流自检） |
| 0xB4 / 0xB8 / 0xBC / 0xC0 / 0xC4 / 0xC8 | wavetable loader：state / accepted / covered / covered_count / wr_ptr / rejected |
| 0xCC | `crc_final_captured` |
| 0xA4 / 0xA8 / 0xAC | APPLY 拒绝原因 / 期望 CRC / APPLY 版本 |
| **0xD0** | `report_valid` 计数（传感器是否在报） |
| **0xD4** | LIVE 事件计数 |
| **0xD8** | `cursor_y`（0..65535） |
| **0xDC** | `raw_x`（原始，0..65535） |
| **0xE0** | 最近一帧 `frame_cal_z`（32 位） |
| **0xE4** | 光标 FSM 状态（简化后已固定） |
| **0xE8** | `{pos[25:8], live_active, live_gate, live_note}`（低 10 bit 不变；高 18 bit 是帧 morph 的 position） |
| **0xEC** | `valid_frame` 计数 |
| **0xF0** | `cursor_x` |
| **0xF4** | reader 状态机状态 |
| **0xF8** | `cursor_point_valid` 计数 |
| **0xFC** | `raw_y` |

> 新增调试量时**必须同步更新本表与所有脚本**。曾经出现过"改了 0xE4 含义、脚本仍按旧含义显示"的误导。

### 3.2 `WT_SELECT(0x60)` 的 morph 布局（2026-10-31）

`{step[22:0], morph_en, 6'd0, table[1:0]}`，写掩码 `0xFFFFFF07`。

- `table[1:0]`：上传目标 / 静态播放表（不变）；
- `morph_en=1`：position LFO 驱动帧选择，`frame_a=pos[25:24]`、`frame_b=min(+1,2)`、`frac=pos[23:16]`；
- `step`：Q2.24 position 增量/样本；`step = round(2^25 / (周期秒 × 48000))`，20 s → 35；
- 例：`0x0024_6901` = step 0x1234、morph 开、table 1；
- 上传脚本必须最后统一写一次本寄存器，否则会把 morph 配置清掉。

---

## 4. 板上调试脚本（按用途）

| 脚本 | 用途 | 关键输出 |
| --- | --- | --- |
| `board_coord_probe.ps1` | 坐标链：raw vs cursor | `raw_x/raw_y` 与 `cursor_x/cursor_y` 逐行对比 |
| `board_input_diag.ps1` | 输入链路存活 | `reports / errors / cursor_valid` 增量 |
| `board_cursor_trace.ps1` | 光标逐级计数 | `reports/frame/fsm/z/point/cx/cy/reason` |
| `board_live_path.ps1` | LIVE 出音 | `events / active / gate / note`，结束自动回 IDLE |
| `board_readback.ps1` | 波表 1024 点读回 | `1024/1024 match`、`RESULT: PASS` |
| `board_apply_once.ps1` | 上传 + WT_VERSION + APPLY | APPLY ACK + 版本递增 |
| `board_cursor.ps1` | 遥测帧显示 | 20 Hz 快照帧的 x/y/z |

**脚本纪律**：
- 每个脚本结束要么回 IDLE、要么明确说明会留下什么状态（否则会遗留持续音）；
- 失败必须非零退出；
- 执行策略：`powershell -NoProfile -ExecutionPolicy Bypass -File <脚本>`（否则 `RemoteSigned` 会拒绝）。

---

## 5. 遥测与上位机显示

- 使能：写 `TLM_CONTROL(0x80) = (period<<16) | 1`，`period=2400` → 约 **20 Hz**；
- 帧格式 22 字节：`5A 02 01 seq[2] x[2] y[2] z[2] … CRC`（x/y/z 大端）；
- 默认关闭，避免 48 kHz 捕获把 1 Mbaud 打满。

显示：

```powershell
python host\cursor_view.py --port COM4                 # Tk 窗口 + 四角基准 + 像素坐标
python host\cursor_view.py --console-only              # 纯文本
```

方向修正：`--flip none|x|y|both`（板上实测只有 Y 镜像，默认 `y`）。

---

## 6. GAO 抓波形（本项目最关键、也最容易踩坑的一环）

### 6.1 抓取流程

1. 写探针文件 `gao/xxx.rao`（明文 XML）；
2. 构建：`python scripts/synth.py --run-id gao_x --gao gao/xxx.rao` → `ao_0.fs`；
3. 烧录；
4. **触发事件必须真的发生**（例如抓 APPLY 就要有人在窗口内发 APPLY；抓光标就要有人动）；
5. 抓取：

```powershell
python scripts/gao_capture.py --rao gao/xxx.rao --out artifacts/gao/run1 --force-trigger-timeout 90 --stop-timeout 120
```

### 6.2 `.rao` 的三段结构（缺一不可）

```xml
<AoCore sample_clock="u_v2/clk_sys_100m" storage_depth="2048" trig_type="0" ...>
  <SignalList> … 探针（层次名，总线要逐位展开）… </SignalList>
  <Triggers>
    <Trigger index="0"><SignalList><Signal>u_v2/xxx</Signal></SignalList></Trigger>
    … index 1..15 空占位 …
  </Triggers>
  <MatchUnits>
    <MatchUnit index="0" enabled="1" match_type="0" value0="1" value1="0" trigger="0"/>
  </MatchUnits>
  <Expressions type="Static"><Expression>M0</Expression></Expressions>   <!-- 关键 -->
</AoCore>
```

### 6.3 七个必须知道的坑

| 坑 | 现象 | 解法 |
| --- | --- | --- |
| **缺 `<Expressions>`** | 生成的 `gw_ao_expression.v` 全是常量 1 → 触发恒真，抓到的是一段空闲快照 | 必须写 `<Expression>M0</Expression>`；构建后检查 `impl/.../RTL_GAO/ao_0/gw_ao_expression.v` 第一行应为 `match[0]` |
| `-out` 无扩展名 | `gao_sh` 退出码 1 | `-out x.csv`（支持 `.csv/.vcd/.prn/.gwd`） |
| 输出文件名 | 找不到 `x.csv` | 实际是 **`x_core0.csv`**，脚本用通配符查找 |
| 文件延迟落盘 | 进程返回时文件还没出现 | 轮询等待（脚本已带重试） |
| 触发信号没活动 | 抓到静态窗口、`change points = 0` | 抓取窗口内必须让人/主机真的触发事件 |
| 捕获超限 | 波形被截断 | 深度 × 位宽受 BSRAM 限制：1 块 = 18,432 位；2048×112 位 ≈ 13 块 |
| 采样时钟名 | 构建报找不到 net | `sample_clock` 必须是设计里真实存在的信号名 |

### 6.4 CSV 解码格式

```
Groups:            ← 只有总线定义
<name> =, bit, bit, ...
Data:
time unit: us, <sig>, <sig>, ...      ← 真正的列头
0, v0, v1, ...
```

解码要点：以 `Data:` 后的**列头行**为准，不要按 `.rao` 顺序猜。

---

## 7. 通用陷阱清单（都是实际踩过的）

| 类别 | 坑 | 后果 / 解法 |
| --- | --- | --- |
| PowerShell | `rd` 是 `Remove-Item` 的别名 | 函数名用 `Read-Csr`，不要用 `Rd` |
| PowerShell | `[uint32]0x80000000` 抛异常 | 用 `[uint32]::Parse('80000000', 'HexNumber')` |
| PowerShell | `$sp.ReadExisting().ToCharArray()` 类型转换 | 用 `$sp.BytesToRead` + `$sp.Read($arr,0,$n)` |
| PowerShell | 执行策略 RemoteSigned | `-ExecutionPolicy Bypass`（脚本不是本地新建的） |
| 工具 | `vlog` 输出接管道会挂起 | 直接重定向到文件，不接 `Select-String` |
| 工具 | `vsim -do "run -all; quit -f"` 在 `$fatal` 后仍返回 0 | 以日志文本判定 PASS，别只看退出码 |
| 构建 | 顶层文件 CRLF | 被 gate 点名，写文件时统一 LF |
| 地址 | 调试块占用 `0x80–0x9C` | 与 telemetry 区冲突，已迁移到 `0xB0–0xFC` |
| 契约 | `MODE` 只接受 ≤6 | 新枚举要同步 `v2_csr_write_valid` |
| 坐标 | 把 0..65535 当 signed 再减 32768 | 偏移半屏、翻转到另一端 |
| 坐标 | 重复加 32768 | 范围翻倍，16 位回绕后"右边界跳左边界" |
| Verilog | `logic x = expr;` 是**初始化**不是连续赋值 | 探测量必须用时序锁存或 `wire` |
| 板子 | 上一次脚本把模式留在 LIVE | 下次上电仍有持续音；脚本结束必须回 IDLE |
| 板子 | 烧录后立刻发命令 | 传感器复位序列约 2.25 s，先等再发 |
| GAO | JTAG 与烧录互斥 | 先烧后抓，不要同时 |

---

## 8. 最小排障顺序（出问题时按此走）

1. **常数寄存器** `0xB0 == 0x5A5A0003`？（位流 + 串口）
2. **`report_valid` 0xD0 在涨吗**？（传感器是否在报）
3. **`raw_x/raw_y` 0xDC/0xFC 在变吗**？（坐标是否真的有输入）
4. **`cursor_x/cursor_y` == `raw + 偏移` 吗**？（映射是否 1:1）
5. **`valid_frame` 0xEC 在涨吗**？（位置有效性是否通过）
6. **`point` 0xF8 在涨吗**？（光标是否接合）
7. **`events` 0xD4 / `note` 0xE8 在变吗**？（出音规则是否工作）
8. 以上都对还不对 → **上 GAO**，抓对应阶段的波形，不要再猜。

---

## 9. 脚本索引

```
scripts/gate.py            静态 + 编译闸门
scripts/sim.py             双 RAM 仿真回归
scripts/synth.py           综合/P&R（--gao 生成仪器化位流）
scripts/gao_capture.py     GAO 抓取 + CSV 解码
scripts/board_*.ps1        板上各类探针（见 §4）
host/cursor_view.py        遥测显示（Tk / 控制台）
host/wavetable_from_capture.py  采集曲线 → 波表
```

控制面全集（CSR 表、工作流、GUI 约束）见 `docs/host-tools-and-gui-controls.md`。
