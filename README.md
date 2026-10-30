# mgc3130_clean 鈥?骞插噣鐨?V2 婧愮爜宸ョ▼

FPGA锛欸W5A-LV25MG121NES锛?3,040 LUT 涓婇檺锛夈€傛湰鐩綍鏄?V2 鐨?*鍞竴婧愮爜鍩虹嚎**锛?鐢辨棫浠撳簱 `mgc3130_uart/.worktrees/v2-integration` 鐨?`50acf2e` 鍓旀礂鐢熸垚銆?
鐢熸垚杩囩▼鍙噸鏀撅紝涓嶆槸鎵嬪伐鏁寸悊锛?
```bash
python scripts/bootstrap.py --source "<鏃т粨搴?/.worktrees/v2-integration"
```

## 涓轰粈涔堣鏈夎繖涓洰褰?
鏃х洰褰曠Н绱簡涓嬮潰杩欎簺缁撴瀯鎬х己闄凤紝**姣忎竴鏉￠兘浼氳"鑳界紪杩?鍜?鏄鐨?鍒嗗弶**锛?
| 鏃х洰褰曠姸鎬?| 鍚庢灉 |
|---|---|
| `rtl/` 鏈?71 涓?`.sv`锛屾瀯寤哄彧鐢?30 涓?| 浠讳綍 `rtl/*.sv` 閫氶厤缂栬瘧閮戒細寮曞叆鏃犲叧鏂囦欢 |
| `mgc3130_v2_top` 琚畾涔変袱娆★紙80 MHz 涓?100 MHz+DPB锛?| `vlog-2275` 鍙槸**璀﹀憡**锛屽悗缂栫殑闈欓粯瑕嗙洊鍓嶄竴涓紱瀹炴祴 `CLKS_PER_BIT` 鍙?100銆佹敹鍒扮殑瀛楄妭鍙樻垚 `f3 61 20 鈥 |
| `v2_potts_commit_fsm` 涔熻瀹氫箟涓ゆ | 鍚屼笂 |
| 鍞竴鐨勯《灞傜骇鍥炲綊鏀惧湪 `impl/`锛岃€?`.gitignore` 鎺掗櫎 `impl/` | **娌℃湁琚増鏈鐞?*锛岄殢鏃跺彲鑳戒涪澶?|
| `scripts/` 鏈?78 涓?`synth_*.tcl`锛屽悇鑷唴宓屼竴浠芥枃浠舵竻鍗?| 婧愮爜鍜屾瀯寤烘竻鍗曚細婕傜Щ |
| 鏂囦欢娓呭崟鍙瓨鍦ㄤ簬 Tcl 閲?| 娌℃湁浠讳綍宸ュ叿鑳藉洖绛?杩欐鍒板簳缂栦簡鍝簺鏂囦欢" |

鏈洰褰曠殑姣忎釜涓嶅彉寮忛兘鏈変竴涓剼鏈湪瀹堬細

1. **鍙湁 `filelist.f` 涓€浠芥枃浠舵竻鍗?*锛屼豢鐪熴€侀椄闂ㄣ€佺患鍚堜笁澶勫叡鐢ㄣ€?2. **鍙湁涓€涓《灞?* `v2_board_top`锛堝悎鎴愮敤锛夛紝涓斿畠琚樉寮忓０鏄庡湪 `MANIFEST.json`銆?3. **鐩綍閲屾病鏈夋湭浣跨敤鐨勬枃浠?*锛氶櫎椤跺眰澶栵紝`filelist.f` 閲屾瘡涓ā鍧楅兘蹇呴』琚疄渚嬪寲锛屽惁鍒欓椄闂ㄥけ璐ャ€?4. **缂栬瘧闆惰鍛婃槸纭姹?*锛氫换浣?`vlog` 璀﹀憡锛堝惈 `vlog-2275` 鍚屽悕瑕嗙洊锛夐兘鍒ゅけ璐ャ€?5. **宸茬煡缂洪櫡璁拌繘鍩虹嚎**锛歚sim_baseline.json` 鍒楀嚭褰撳墠宸茬煡澶辫触鐨勬柇瑷€锛屾柊鍑虹幇鐨勫け璐ユ墠鍙洖褰掋€?
## 涓夋潯鍛戒护

```bash
python scripts/gate.py              # 闈欐€佹鏌ワ細閲嶅妯″潡 / 椤跺眰鍞竴 / 姝讳唬鐮?/ 鍖呴『搴?python scripts/gate.py --compile    #   + ModelSim 缂栬瘧锛岃鍛婂嵆澶辫触
python scripts/sim.py               # 缂栬瘧骞惰窇 RAM=0 涓?RAM=1 涓ゅ鍥炲綊锛岄€愭潯姣斿鍩虹嚎
python scripts/sim.py --trace       #   + 鎵撳嵃鍛戒护/APPLY/搴旂瓟娴侊紙CSR_TRACE锛?python scripts/synth.py --run-id r1  # 鐢熸垚 .gprj 骞惰窇 syn + pnr锛岃緭鍑?synth_summary.json
```

`sim.py` 閫€鍑虹爜鍗崇粨璁猴細瑙傚療鍒扮殑澶辫触蹇呴』鏄?`sim_baseline.json` 鐨勫瓙闆嗐€?淇帀鏌愪釜宸茬煡缂洪櫡鍚庤窇 `python scripts/sim.py --update-baseline` 鎶婂畠浠庡熀绾块噷鎽樻帀銆?
## 鐩綍

```
filelist.f            鍞竴鏂囦欢娓呭崟锛堥『搴忓嵆渚濊禆椤哄簭锛?ip/filelist_ip.f      鍘傚晢 IP 娓呭崟锛屽彧缁欑患鍚堢敤
MANIFEST.json         姣忎釜鏂囦欢鐨?sha256 + 鏉ユ簮 commit + 鐩稿鏃т粨搴撶殑琛ヤ竵璇存槑
rtl/                  29 涓?RTL + v2_board_top.sv锛堝敮涓€鍚堟垚椤跺眰锛?ip/gowin_i2c_master/  Gowin I2C 鏍革紙鍔犲瘑 .vp + 椤跺眰鍖呰 + 涓や釜 .vh 瀹忓畾涔夛級
tb/                   tb_top_csr_gate.sv锛堥《灞傜骇鍥炲綊锛夈€乼b_sim_top.sv锛圙SR 缁戝畾锛夈€乵on_csr_trace.sv
constr/               mgc3130_v2.cst銆乵gc3130_v2_top_observable.sdc
scripts/              bootstrap.py / gate.py / sim.py / synth.py
docs/BASELINE.md      褰撳墠鏁板€间笌宸茬煡缂洪櫡娓呭崟
sim_logs/, .sim/      浠跨湡杈撳嚭锛堜笉鍏ュ簱锛?impl/                 缁煎悎杈撳嚭锛堜笉鍏ュ簱锛?```

## 鍘傚晢 IP 涓轰粈涔堝崟鐙竴涓竻鍗?
`mgc3130_reader` 瀹炰緥鍖栫殑鏄?**`Gowin_I2C_Master`**鈥斺€旀ā鍧楀悕鐢?`ip/gowin_i2c_master/top_define.vh`
閲岀殑 `` `define module_name `` 鍐冲畾锛屽疄鐜颁綋鏄姞瀵嗙殑 `I2C_MASTER.vp`銆傛紡鎺夊畠锛岀患鍚堜細鍋滃湪
`ERROR (EX3937) : Instantiating unknown module 'Gowin_I2C_Master'`銆?
瀹冧笉鑳借繘 `filelist.f`锛氬姞瀵嗙殑 `.vp` 鍠傜粰 ModelSim 浼氱洿鎺ョ紪璇戝け璐ワ紝鑰屼豢鐪熻矾寰勬牴鏈敤涓嶅埌瀹?锛坱estbench 璧?UART锛屼笉纰?I2C锛夈€傛墍浠?`scripts/synth.py` 浼氭妸 `ip/filelist_ip.f` 鎺掑湪
`filelist.f` 涔嬪墠涓€璧峰啓杩?`.gprj`锛宍scripts/gate.py` 鍙垎鏋愯璁℃湰浣撱€?
## 涓ゆ潯瀹规槗韪╃殑纭害鏉?
**1. `rtl/` 閲屼笉璁稿嚭鐜扮浜屼釜 `module v2_board_top`锛屼篃涓嶈鍔犲洖 `mgc3130_v2_top_dpb.sv`銆?*
ModelSim 瀵瑰悓鍚嶆ā鍧楀彧鎶?`vlog-2275` 璀﹀憡鐒跺悗瑕嗙洊銆俙gate.py` 浼氭嫤锛屼絾鎵嬪伐鎿嶄綔鏃惰鐭ラ亾銆?
**2. 浠跨湡蹇呴』甯?`+define+V2_SIM`銆?*
`rtl/v2_clock_gen.sv` 鍦?`V2_SIM` 涓嬫妸 `clk_sys_100m` 鐩存帴杩炲埌 `clk_in`銆佹妸 `pll_locked`
鐩存帴杩炲埌 `rst_n`锛涗笉甯﹁繖涓畯锛屽櫒浠?PLL 鍘熻鍦ㄤ豢鐪熼噷涓嶅嚭閿侊紝`por_n` 姘歌繙涓嶈В澶嶄綅锛?鏁翠釜璁捐琛ㄧ幇涓?瀹屽叏涓嶅簲绛?銆俙scripts/sim.py` 宸茬粡榛樿甯︿笂銆?
## 淇″彿鍛藉悕鐨勫巻鍙插寘琚憋紙涓嶆敼锛屼絾瑕佺煡閬擄級

`clk_sys_100m` 瀹為檯鏄?**80 MHz**锛圥LLA锛?0 MHz 脳 16 / 10锛夈€傝繖涓敊璇懡鍚嶅凡缁忛€犳垚杩囦竴娆?"娉㈢壒鐜囧亸 25%"鐨勮鍒わ紝`constr/*.sdc` 閲屽師鍏堝啓鐫€ "100 MHz" 鐨勬敞閲婁篃宸蹭竴骞舵洿姝ｃ€?閲嶅懡鍚嶄細瑙﹀強 30 涓枃浠讹紝鏀剁泭涓嶆姷椋庨櫓锛屽洜姝や繚鐣欏苟鍦ㄦ澹版槑銆?
## 涓嶅湪鏈洰褰曠殑鍐呭

`pc_receiver/`锛堜笂浣嶆満妯″瀷锛夈€乣artifacts/`锛堝巻鍙叉澘娴嬫棩蹇楋級銆乣docs/`锛堝绾︿笌瀹¤锛変粛鍦ㄦ棫浠撳簱銆?鏈洰褰曞彧璐熻矗"婧愮爜 + 鍙鐜扮殑鏋勫缓涓庨獙璇?銆?
## 版本控制与调试方法

本目录自 2026-10-30 起是一个独立 git 仓库（此前只有 `MANIFEST.json` 的 sha256，没有 VCS 兜底）：

- 忽略项：`impl/`、`sim_logs/`、`.sim/`、`.gate/`、`artifacts/`、`work/`、`*.wlf`、`.synth_run*.txt`、`.sim_run*.txt`
- 两个提交：初始干净树、忽略每次运行的临时日志
- 首次在别的机器/账号克隆时需要 `git config --global --add safe.directory <本目录>`（本机目录属主是 Administrators）

调试方法论已固化为用户级 skill `gowin-fpga-debug`
（`~/.dsh/skills/gowin-fpga-debug/SKILL.md`），要点：

1. **不要用被测机制观测被测对象**（CSR 回读证明不了 CSR 时序）；
2. 按症状选仪器：周期级 → GAO，帧级 → 主机 UART 闭环，长时计数 → 契约寄存器，可复现逻辑 → 双 RAM 仿真；
3. GAO 全流程可脚本化：明文 `.rao` → `.gprj` 里 `type="file.gao"` → `gw_sh run all` 生成 `RTL_GAO/` 与 `ao_0.fs` → `gao_sh -gao ... -out ...` 抓取；
4. 预算：1 块 BSRAM = 18,432 位，`深度 × 位宽` 必须装得下；2048×112 已验证占 13 块；
5. 证据纪律：干净基线、ACK 全字段、原始日志、位流 sha256 + 内容 hash、未跑的项要写明。

测试流程细节见 `docs/TEST-FLOW-GAO.md`。