# mgc3130_clean — 干净的 V2 源码工程

FPGA：GW5A-LV25MG121NES（23,040 LUT 上限）。本目录是 V2 的**唯一源码基线**，
由旧仓库 `mgc3130_uart/.worktrees/v2-integration` 的 `50acf2e` 剔洗生成。

生成过程可重放，不是手工整理：

```bash
python scripts/bootstrap.py --source "<旧仓库>/.worktrees/v2-integration"
```

## 为什么要有这个目录

旧目录积累了下面这些结构性缺陷，**每一条都会让"能编过"和"是对的"分叉**：

| 旧目录状态 | 后果 |
|---|---|
| `rtl/` 有 71 个 `.sv`，构建只用 30 个 | 任何 `rtl/*.sv` 通配编译都会引入无关文件 |
| `mgc3130_v2_top` 被定义两次（80 MHz 与 100 MHz+DPB） | `vlog-2275` 只是**警告**，后编的静默覆盖前一个；实测 `CLKS_PER_BIT` 变 100、收到的字节变成 `f3 61 20 …` |
| `v2_potts_commit_fsm` 也被定义两次 | 同上 |
| 唯一的顶层级回归放在 `impl/`，而 `.gitignore` 排除 `impl/` | **没有被版本管理**，随时可能丢失 |
| `scripts/` 有 78 个 `synth_*.tcl`，各自内嵌一份文件清单 | 源码和构建清单会漂移 |
| 文件清单只存在于 Tcl 里 | 没有任何工具能回答"这次到底编了哪些文件" |

本目录的每个不变式都有一个脚本在守：

1. **只有 `filelist.f` 一份文件清单**，仿真、闸门、综合三处共用。
2. **只有一个顶层** `v2_board_top`（合成用），且它被显式声明在 `MANIFEST.json`。
3. **目录里没有未使用的文件**：除顶层外，`filelist.f` 里每个模块都必须被实例化，否则闸门失败。
4. **编译零警告是硬要求**：任何 `vlog` 警告（含 `vlog-2275` 同名覆盖）都判失败。
5. **已知缺陷记进基线**：`sim_baseline.json` 列出当前已知失败的断言，新出现的失败才叫回归。

## 三条命令

```bash
python scripts/gate.py              # 静态检查：重复模块 / 顶层唯一 / 死代码 / 包顺序
python scripts/gate.py --compile    #   + ModelSim 编译，警告即失败
python scripts/sim.py               # 编译并跑 RAM=0 与 RAM=1 两套回归，逐条比对基线
python scripts/sim.py --trace       #   + 打印命令/APPLY/应答流（CSR_TRACE）
python scripts/synth.py --run-id r1  # 生成 .gprj 并跑 syn + pnr，输出 synth_summary.json
```

`sim.py` 退出码即结论：观察到的失败必须是 `sim_baseline.json` 的子集。
修掉某个已知缺陷后跑 `python scripts/sim.py --update-baseline` 把它从基线里摘掉。

## 目录

```
filelist.f            唯一文件清单（顺序即依赖顺序）
ip/filelist_ip.f      厂商 IP 清单，只给综合用
MANIFEST.json         每个文件的 sha256 + 来源 commit + 相对旧仓库的补丁说明
rtl/                  29 个 RTL + v2_board_top.sv（唯一合成顶层）
ip/gowin_i2c_master/  Gowin I2C 核（加密 .vp + 顶层包装 + 两个 .vh 宏定义）
tb/                   tb_top_csr_gate.sv（顶层级回归）、tb_sim_top.sv（GSR 绑定）、mon_csr_trace.sv
constr/               mgc3130_v2.cst、mgc3130_v2_top_observable.sdc
scripts/              bootstrap.py / gate.py / sim.py / synth.py
docs/BASELINE.md      当前数值与已知缺陷清单
sim_logs/, .sim/      仿真输出（不入库）
impl/                 综合输出（不入库）
```

## 厂商 IP 为什么单独一个清单

`mgc3130_reader` 实例化的是 **`Gowin_I2C_Master`**——模块名由 `ip/gowin_i2c_master/top_define.vh`
里的 `` `define module_name `` 决定，实现体是加密的 `I2C_MASTER.vp`。漏掉它，综合会停在
`ERROR (EX3937) : Instantiating unknown module 'Gowin_I2C_Master'`。

它不能进 `filelist.f`：加密的 `.vp` 喂给 ModelSim 会直接编译失败，而仿真路径根本用不到它
（testbench 走 UART，不碰 I2C）。所以 `scripts/synth.py` 会把 `ip/filelist_ip.f` 排在
`filelist.f` 之前一起写进 `.gprj`，`scripts/gate.py` 只分析设计本体。

## 两条容易踩的硬约束

**1. `rtl/` 里不许出现第二个 `module v2_board_top`，也不许加回 `mgc3130_v2_top_dpb.sv`。**
ModelSim 对同名模块只报 `vlog-2275` 警告然后覆盖。`gate.py` 会拦，但手工操作时要知道。

**2. 仿真必须带 `+define+V2_SIM`。**
`rtl/v2_clock_gen.sv` 在 `V2_SIM` 下把 `clk_sys_100m` 直接连到 `clk_in`、把 `pll_locked`
直接连到 `rst_n`；不带这个宏，器件 PLL 原语在仿真里不出锁，`por_n` 永远不解复位，
整个设计表现为"完全不应答"。`scripts/sim.py` 已经默认带上。

## 信号命名的历史包袱（不改，但要知道）

`clk_sys_100m` 实际是 **80 MHz**（PLLA：50 MHz × 16 / 10）。这个错误命名已经造成过一次
"波特率偏 25%"的误判，`constr/*.sdc` 里原先写着 "100 MHz" 的注释也已一并更正。
重命名会触及 30 个文件，收益不抵风险，因此保留并在此声明。

## 不在本目录的内容

`pc_receiver/`（上位机模型）、`artifacts/`（历史板测日志）、`docs/`（契约与审计）仍在旧仓库。
本目录只负责"源码 + 可复现的构建与验证"。
