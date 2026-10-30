# BASELINE — 干净工程当前状态

生成源：旧仓库 `50acf2e`（`mgc3130_uart/.worktrees/v2-integration`）。
本文件只记录**实际跑出来的**结果，未跑的一律标注"未验证"。

## 已验证

| 项 | 命令 | 结果 |
|---|---|---|
| 结构闸门 | `python scripts/gate.py` | PASS：31 个模块 / 2 个包 / 30 个文件；除顶层外每个模块都被实例化；无重名模块 |
| 编译 | `python scripts/gate.py --compile` | **0 error / 0 warning**（旧树在这里有 `EX1998` 无驱动和 `vlog-2388` 使用先于声明） |
| 仿真 RAM=0 | `python scripts/sim.py --ram 0` | 14 条断言：**10 pass / 4 fail**，wall 138 s |
| 仿真 RAM=1（DPB） | `python scripts/sim.py --ram 1` | 同样 **10 pass / 4 fail**，与 RAM=0 **逐条一致**，wall 311 s |
| 综合 RAM=1 配置 | `python scripts/synth.py --run-id clean3` | 综合完成：`Register 10,450 / 23,280`、`BSRAM 36 / 56`，网表与 synth 报告已生成 |

`10 pass / 4 fail` 与旧树在 `50acf2e` 上的结果**完全相同**（旧树为 9 pass / 4 fail，多出的 1 条是
`0xA8` 那条断言在旧树里因名字被截断而未被记入）。这是等价性证据，不是新引入的回归。

`10 pass` 覆盖：常数 CSR、常数读错误码、`WT_INDEX → wr_ptr`、覆盖计数 32、覆盖位图 `0xFFFFFFFF`、
T1 APPLY 提交、T1 应答错误码、T2/T3 版本不变、T4 应答错误码。也就是说
**"1024 点上传 → CRC → APPLY 换表 → 版本递增"这条主链在干净工程里仍然成立**。

## 未验证

- **P&R 未跑完**（按要求中止）。因此没有 Fmax、没有 setup 违例计数、没有位流。
  旧树最近一次数据是 Fmax 67.168 MHz / 1,537 setup 违例，**不能**直接记到本工程账上。
- 板测：无。
- `pc_receiver/` 上位机模型未纳入本工程，未联调。

## 4 条已知失败

见 `sim_baseline.json`，每条都写了原因。归纳成两个 R 项：

**R13（一行代码）** `mgc3130_v2_top.sv` 的 APPLY 应答只把 `reason==3` 映射成 `V2_ERR_WT_CRC`，
`reason 1`（版本不匹配）与 `reason 2`（表不完整）落到 `V2_ERR_NONE`，于是被正确拒绝了却回 `err=0x00`。
影响断言：`T2 reply error is BAD_DATA`、`T3 reply error is BAD_DATA`。

**R14（需要决策，不是 bug）** APPLY 成功后 `active_bank` 翻转、shadow 覆盖被清空，同一张表重放
必被判 `reason=2`。要么允许幂等重放，要么给独立错误码。影响断言：`T4 retry committed`。

另有一条是**测试台前提错误**：`0xA8` 属于 `V2_DEBUG_CSR` 门控的调试寄存器，默认配置下被裁掉，
读到 0。应改读 `WT_STATUS(0x7C)`，或编译时加 `-DV2_DEBUG_CSR`。影响断言：
`expected CRC reached the uploader`。

## 与旧树的差异（全部在 MANIFEST.json 的 patches 里）

1. `rtl/mgc3130_v2_top.sv` — 补 `patch_crc_payload_q` 声明，并把 P1 声明块移到 `v2_patch_bank`
   实例之前。**不改逻辑**，只改声明位置（旧树这份文件根本编译不过）。
2. `rtl/v2_board_top.sv` — 由 `sim/v2_top_fullpath_probe.sv` 改名而来，模块体未改。
3. `tb/tb_top_csr_gate.sv` — `rxbuf` 读索引与 mod-256 写索引对齐；`%0s` → `%s`；断言名参数
   256 → 512 位（原宽度 32 字符，"expected CRC reached the uploader" 有 33 字符，右对齐截断吃掉首字符）。
4. `constr/*.sdc` — 更正 "100 MHz" 注释（PLL 实际输出 80 MHz）。

除以上四类，30 个文件的字节内容与 `50acf2e` 一致，sha256 记录在 `MANIFEST.json`。
