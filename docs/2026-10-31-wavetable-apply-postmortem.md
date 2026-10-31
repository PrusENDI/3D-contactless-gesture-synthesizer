# 波表 APPLY 调试复盘（2026-10-31）

对象：`scripts/board_wt_upload.ps1` 把任意 `.bin` 表送到板上并 APPLY。
结果：**已修复**（`APPLY err=0`，version 1→2，WT_PLAY 出声）。

## 1. 根因：APPLY 字少了一个提交位

成功脚本（`board_apply_once.ps1`）的写法：

```powershell
$applyWord = [uint32]::Parse('80000000','HexNumber') -bor $ver    # bit31 = 提交
```

我的写法：

```powershell
$applyWord = (($Table) -band 0x3) -shl 16 -bor $Version            # 错：表号放高位
```

**bit31 是“提交”标志，表号走 `WT_SELECT(0x60)`。** 少了它，加载器把命令当普通配置，
回头按 CRC 判失败，于是 `err=7`（`BAD_DATA`，旧映射）或 `err=10`（`WT_CRC`）。

另外两处也必须照抄：上传后写 `WT_LENGTH(0x6C)=1024`；CRC 按 **MSB-first** 采样字节算
（`0xAA59`，不是小端文件字节的 `0xD949`）。版本号取 `WT_STATUS[15:0]` 的当前值，**不自增**。

## 2. 症状时间线（以及每一步排除了什么）

| 观测 | 当时以为 | 实际 |
| --- | --- | --- |
| APPLY `err=7`，`WT_STATUS` 读 0 | shadow 没关闭 | **假信号**：我的 `X()` 返回的是错误字节，不是数据 |
| 上电就有固定音 | 波表通路出声了 | **假阳性**：`PRESERVE_POTTS_PLANE=1` 在上电强跑一次 DP，留下一个永不释放的声部 |
| `ready=1`、`shadow_valid=1`、`valid_q=0` | 加载器没收到请求 | 对；但原因是 APPLY 字缺提交位 |
| `err=7` 但 `reason=0`、`A8/CC` 不变 | 判定没执行 | 对；提交位缺失导致根本没进判定 |
| `0xA4=0`、`0xA8=0xAA59` | CRC 没写进去 | 错，CRC 写进去了；是表内容与期望不符 |

## 3. 我犯的错误（按代价排序）

1. **没有照抄已验证的实现，自己重推协议。** 仓库里 `board_apply_once.ps1` 一直能跑，
   我却按“看起来合理”的方式重写了一遍帧序、CRC、APPLY 字。这是 3 小时的直接来源。
2. **用探针位流做功能测试。** `PRESERVE_POTTS_PLANE=1` 会在上电发一个事件并留下卡音，
   我把它当成“波表出声”，误判了一大轮。**功能验收必须用 `PRESERVE_*=0` 的位流。**
3. **调试脚本自身的读数 bug 当成硬件证据。** `X()` 返回 `[19]`（错误字节），我却打印成
   `WT_STATUS`，得出“shadow 无效”的错误结论。
4. **没有校验应答序号。** 曾怀疑“读到了上一条命令的迟到回包”，花了半轮排查；加序号校验后
   零不匹配，才排除。
5. **一次改多处。** 延迟、重试、版本号、字段序一起改，`err` 一直 7，无法归因。
   正确做法是一次只改一处，并记录对应读数。
6. **先改代码，后看波形。** GAO 抓一次 APPLY 就能看到 `valid_q` 从未拉高；我却在协议层
   试了五六轮才去抓。
7. **PowerShell 陷阱重复踩。** `rd`/`R` 是别名（别名优先于函数）、`0x80000000` 溢出、
   写文件带 BOM 导致 vlog 报错、`Set-Content` 默认加 BOM。

## 4. 可复用的流程（下一个同类问题照这个走）

1. **先找仓库里能跑的那个脚本**，把它的命令序列逐条比对新写的；差异一次只补一处。
2. **功能测试用功能位流**（`PRESERVE_LOOP_PLANE=0 / PRESERVE_POTTS_PLANE=0`）。
3. **每个回包校验四件事**：SOF、序号回显、CRC、错误码；读数据要区分“错误字节”和“数据字”。
4. **一次只改一个变量**，每次记录 `err` 与相关寄存器。
5. **两个回合没有进展就上 GAO**，不要继续在协议层猜。
6. 复现前后各记一次**位流 sha256**。

## 5. 遗留事项

| 项 | 说明 |
| --- | --- |
| 三个上传脚本并存 | `board_apply_once` / `board_readback` / `board_wt_upload` 各写一份上传逻辑，应合并为一个（`-Bin` / `-Pattern` / `-Verify`） |
| `board_readback.ps1` 的常数地址 | 原读 `0x80`（已迁到 `0xB0`），我改过；`board_apply_once.ps1` 里仍是 `0x80` |
| `MODE(0x04)` 读回 | 恒为 0，真实模式在 `STATUS[2:0]` |
| GAO 时间轴 | 用 `pcm5102a_lrck` 作采样时钟时，CSV 标 1 µs/点但实际是 48 kHz，**只能按数据算频率，不看时间戳** |
| 探针位流 `0xB0` 读到 0 | `gao_apply2` 上一次读到 0，功能位流正常；未复现，记录待查 |

## 6. 本次固化的资产

- `scripts/sim_unit.py` —— 单模块单测脚手架（filelist + 一个 tb）
- `tb/tb_wt_playback.sv` —— 播放器 440/46.875/静音三种情形
- `gao/i2s_pitch.rao` —— 用 `wt_play_index` 回卷数测频率（实测 A4 = 440.16 Hz）
- `gao/apply2.rao` —— 以 `wt_apply_valid_q` 为触发，观察 APPLY 握手
- skill `gowin-board-ops` —— 构建四闸门、烧录、协议、调试寄存器、陷阱表
