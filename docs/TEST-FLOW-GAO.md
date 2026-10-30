# 鏂版祴璇曟祦绋嬶細浠?GAO 涓轰富瑕佽娴嬫墜娈碉紙2026-10-30锛?
## 1. 涓轰粈涔堢幇鍦ㄧ殑鍋氭硶鍦ㄦ灦鏋勪笂涓嶅

鍏堟壙璁ょ幇鐘剁殑闂锛屽畠浠笉鏄?鍐嶆敼鍑犺灏辫兘缁曡繃"鐨勶細

| 鐜扮姸 | 缁撴瀯鎬у悗鏋?|
| --- | --- |
| 鐢?**CSR 浜嬪姟** 瑙傛祴鍐呴儴鐘舵€?| 瑙傛祴璺緞灏辨槸琚祴璺緞銆侾1 鐨?bug 鎭版伆鍑哄湪 CSR 浜嬪姟瀵归綈涓娾€斺€?*鐢ㄥ潖灏哄瓙閲忓潖涓滆タ**锛岃鍒扮殑"鏁版嵁"鏃犳硶鑷瘉 |
| 鎶婁竴涓噺鎵撳寘杩涗竴涓?word锛屽啀鎸変綅鍩熻В鏋?| 浣嶅煙閿欎竴浣嶅叏閿欙紱涓よ疆閲屽凡鍥犲湴鍧€鍐茬獊锛坄0xA0` 鎾?`TEST_SELECT`锛夈€佸瓧娈靛亸绉汇€乣0xA8` 琚?`V2_DEBUG_CSR` 闂搁棬鍏虫帀鑰岃鍒?|
| 鍙湁**蹇収**锛屾病鏈夋椂搴?| "T 鎷嶅啓銆乀+1 鎷嶉噰鏍?杩欑被闂鍙兘闈犳帹鏂紱`crc_error=10` 鑺变簡涓夎疆鎵嶆媶鎴?reason 1/2/3 |
| 姣忔崲涓€涓棶棰樺氨瑕佹敼 RTL銆侀噸缁煎悎銆佸啓鏂拌剼鏈?| 鍙嶉鍛ㄦ湡 鈮?15 鍒嗛挓锛屼笖姣忔閮藉彲鑳藉紩鍏ユ柊鐨勮娴?bug |
| 鏉夸笂涓庝豢鐪熺敤涓ゅ涓嶅悓鐨勮娴嬫満鍒?| 浠跨湡閲?PASS銆佹澘涓?FAIL 鏃讹紝鏃犳硶鍒ゆ柇鏄璁″樊寮傝繕鏄娴嬪樊寮?|

**GAO锛圙owin Analyzer Oscilloscope锛夎В鍐崇殑姝ｆ槸杩欏洓鐐?*锛氬畠鏄?*鐙珛浠櫒**锛?涓嶅湪琚祴璺緞涓婏紝缁欑殑鏄?*鏃堕棿杞存尝褰?*鑰屼笉鏄揩鐓с€?
## 2. GAO 鍙鎬э細宸叉牳瀹烇紝鍏ㄦ祦绋嬪彲鑴氭湰鍖?
涓婁竴杞垜鏇惧垽鏂?GAO 蹇呴』 IDE 鎵嬪伐鍋?鈥斺€?*杩欎釜鍒ゆ柇鎾ゅ洖**銆傚疄娴嬭瘉鎹細

| 浜嬪疄 | 璇佹嵁 |
| --- | --- |
| 鎶撳彇宸ュ叿鍙敤 | `IDE/bin/gao_sh.exe`锛岀敤娉?`gao_sh -gao <file> -cable <type> [-out <file>]` |
| 鎺㈤拡瀹氫箟鏂囦欢鏄?*鏄庢枃 XML** | vendor 渚嬬▼ `UART/simple_uart/src/uart.rao`锛歚sample_clock`銆乣storage_depth`銆乣SignalList`锛堝眰娆″寲淇″彿鍚嶏級銆乣Triggers` |
| 宸ョ▼閲屾寜 GAO 鏂囦欢寮曠敤鍗冲彲 | `uart.gprj` 涓?`<File path="src/uart.rao" type="file.gao" enable="1"/>` |
| 缁煎悎浼氳嚜鍔ㄧ敓鎴?GAO RTL | 璇ュ伐绋?`impl/gwsynthesis/RTL_GAO/` 涓嬫湁 `gw_gao_top.v`銆乣ao_0/gw_ao_parameter.v` 绛夛紝浣嶆祦鍚嶄负 `ao_0.fs` |
| 鎺㈤拡鍙傛暟鐢?.rao 鍐冲畾 | `gw_ao_parameter.v` 閲?`SIG_PORT_WIDTH`銆乣STORAGE_DEPTH`銆乣TRIG_PORT_WIDTH_n` 涓?.rao 鐨?SignalList/Triggers 涓€涓€瀵瑰簲 |

**缁撹锛歚gw_sh run all` + `.rao` 灏辫兘浜у嚭 GAO 浠櫒鍖栦綅娴侊紝`gao_sh` 鎶撳彇锛?涓嶉渶瑕佸湪 IDE 閲屾墜鐢绘尝褰€?*

### 2.1 纭害鏉燂紙蹇呴』閬靛畧锛?
| 绾︽潫 | 璇存槑 |
| --- | --- |
| 璁捐閲岃鏈?`sample_clk` 淇″彿 | `.rao` 鐨?`sample_clock` 鎸夊悕瀛楄繛鎺ワ紱vendor 鐢?`OSCA` 浜х敓 4.2 MHz銆傛湰椤圭洰鐢?*绯荤粺鏃堕挓 80 MHz**锛堝悓姝ラ噰鏍凤紝鏈€鐪熷疄锛?|
| 鎺㈤拡鍚嶅繀椤诲湪缁煎悎鍚庡瓨鍦?| 鐢ㄥ眰娆¤矾寰勶紙濡?`u_v2/wt_apply_done`锛夛紱琚紭鍖栨帀鐨勪俊鍙锋姄涓嶅埌鈥斺€旈渶瑕?`syn_keep` 鎴栭€夋嫨鐪熷疄瀛樺湪鐨勮妭鐐?|
| 绐楀彛 = 娣卞害 梅 閲囨牱鐜?| 2048 @ 80 MHz = **25.6 碌s**銆傚 APPLY + CRC 鎵弿锛?024 鎷?鈮?12.8 碌s锛夛紝**涓嶅涓€鏁存潯 UART 甯?*锛?1 B 脳 10 bit 脳 1 碌s 鈮?110 碌s锛?|
| BSRAM 棰勭畻 | 2048脳32 鈮?4 鍧楋紱褰撳墠 36/56锛屽姞 GAO 鍚?40/56 浠嶆湁浣欓噺 |
| JTAG 鐙崰 | 鎶撳彇鏃朵笉鑳藉悓鏃剁儳鍐欙紱`gao_sh` 涓?`programmer_cli` 涓茶浣跨敤 |
| 姣忔鏀规帰閽堣閲嶆柊缁煎悎 | 鎺㈤拡闆嗕竴鏃﹀喕缁擄紝璺戜竴娆＄患鍚堝彲鍙嶅鎶撳彇锛涙崲淇″彿闇€閲嶇紪 |

**鍥犳鍒嗗伐鏄槑纭殑**锛?- **UART 甯х骇/闀挎椂搴?*锛堜竴甯?110 碌s銆佷笂浼?1024 鐐癸級鈫?涓绘満渚ч棴鐜剼鏈紙L4锛夛紱
- **鍛ㄦ湡绾?鎻℃墜绾?CRC 鎵弿**锛埪祍 閲忕骇锛夆啋 GAO锛圠5锛夈€?
## 3. 鏂版祦绋嬶細浜斿眰锛屾瘡灞傛湁鏈哄櫒鍒ゆ嵁

| 灞?| 鍛戒护 | 鍒ゆ嵁 | 浜х墿 |
| --- | --- | --- | --- |
| **L0 闈欐€侀椄闂?* | `python scripts/gate.py` | 閲嶅妯″潡 0銆侀《灞傚敮涓€銆乫ilelist 鍐呮瘡妯″潡閮借瀹炰緥鍖?| 鎺у埗鍙?PASS |
| **L1 缂栬瘧闂搁棬** | `python scripts/gate.py --compile` | **vlog 0 error / 0 warning**锛坄vlog-2275` 鍚屽悕瑕嗙洊涓€绁ㄥ惁鍐筹級 | `.sim/vlog.log` |
| **L2 浠跨湡鍥炲綊** | `python scripts/sim.py` | RAM=0 涓?RAM=1 鍚勮窇涓€閬嶏紝澶辫触闆嗗悎 鈯?`sim_baseline.json`锛?*鍩虹嚎鍙鍙樼煭** | `sim_logs/*.log` |
| **L3 缁煎悎/P&R** | `python scripts/synth.py --run-id <id>`锛堟櫘閫氾級+ `--gao gao/apply.rao`锛堜华鍣ㄥ寲锛?| syn+pnr PASS銆乣synth_summary.json`銆佺綉琛ㄦ鏌ワ紙鏃犻┍鍔ㄧ綉/甯搁噺杈撳嚭锛夈€佷綅娴?sha256 + manifest 鍐呭绾?hash | `impl/<run>/`銆乣synth_summary.json` |
| **L4 鏉夸笂 UART 闂幆** | `python scripts/board_loop.py` | 甯告暟璇?鈫?涓婁紶 鈫?APPLY 鈫?**1024 鐐归€愮偣璇诲洖**锛涜繛缁?3 杞紱璐熶緥锛堥敊 payload / 閿欑増鏈?/ 婕忓潡锛夛紱姣忔潯 ACK 鍏ㄥ瓧娈垫牎楠?| `artifacts/board/*.log` |
| **L5 鏉夸笂 GAO 鎶撳彇** | `python scripts/gao_capture.py --rao gao/apply.rao --out artifacts/gao/apply_run1` | 瑙﹀彂鍛戒腑銆丆SV 琛屾暟 = 娣卞害銆佽В鐮佸嚭鐨勬椂闂寸嚎涓?L2 鏈熸湜搴忓垪涓€鑷达紙apply 鑴夊啿 鈫?done 鈫?reason 鈫?鐗堟湰鍙樺寲锛?| `artifacts/gao/*.csv` + 瑙ｇ爜鏂囨湰 |

**L3 鏅€氱増涓庝华鍣ㄥ寲鐗堝繀椤诲垎寮€鏋勫缓**锛氬嚭璐т綅娴佷笉甯?GAO锛堢渷 BSRAM/CLB锛夛紝
浠櫒鍖栫増鍙敤浜?L5锛屼綅娴佸搱甯屽垎鍒褰曘€?
## 4. GAO 鎺㈤拡璁″垝锛坄gao/apply.rao`锛?
`module_name="v2_board_top"`锛宍sample_clock="u_v2/clk_sys_100m"`锛?0 MHz锛夛紝
`storage_depth=2048`锛宍trig_type=0`锛堜笂鍗囨部瑙﹀彂锛夛紝瑙﹀彂淇″彿 `u_v2/wt_apply_valid_q`銆?
| 淇″彿锛堢浉瀵?`v2_board_top`锛?| 瀹藉害 | 鎶撳畠鐨勭悊鐢?|
| --- | --- | --- |
| `u_v2/u_uart_rx/data[7:0]` | 8 | 鏀跺埌鐨勫瓧鑺?|
| `u_v2/u_uart_rx/valid` | 1 | 瀛楄妭鏈夋晥鑴夊啿 |
| `u_v2/u_v2_uart/cmd_valid`銆乣cmd_ready` | 2 | 鍛戒护鎻℃墜 |
| `u_v2/cmd_op[7:0]`銆乣cmd_address[7:0]`銆乣cmd_data[31:0]` | 48 | 鍛戒护鍐呭 |
| `u_v2/wt_index_load_q`銆乣wt_crc_valid_q`銆乣wt_apply_valid_q` | 3 | **P1 鐨勪笁涓欢杩熻剦鍐?*锛堟湰娆′簤璁腑蹇冿級 |
| `u_v2/wt_expected_crc[15:0]` | 16 | 鏈熸湜 CRC 鍦ㄨ剦鍐插埌杈炬椂鏄惁宸叉槸鏂板€?|
| `u_v2/u_wavetable_loader/state[1:0]` | 2 | loader 鐘舵€佹満 |
| `u_v2/u_wavetable_loader/crc_final_captured[15:0]` | 16 | 姣旇緝鍣ㄥ疄闄呯湅鍒扮殑鍊?|
| `u_v2/wt_apply_done`銆乣wt_apply_ok`銆乣wt_apply_reason[1:0]` | 4 | R12 鐨勭粨鏋滄彙鎵?|
| `u_v2/wt_apply_busy`銆乣wt_crc_error` | 2 | 鐘舵€佷綅 |
| `u_v2/wt_active_version[15:0]` | 16 | 鐗堟湰閫掑鏃跺埢 |
| `u_v2/rsp_valid`銆乣rsp_error[7:0]` | 9 | 搴旂瓟涓庢湰娆＄粨鏋?|

鍚堣绾?**137 浣?*锛堝惈鎬荤嚎鎸変綅灞曞紑锛夛紝2048 娣卞害 鈮?4 鍧?BSRAM銆?
**瑙﹀彂**锛歚wt_apply_valid_q` 涓婂崌娌?鈫?鎶?apply 杩涘叆 loader 涔嬪悗 25.6 碌s锛?姝ｅソ瑕嗙洊 1024 鎷?CRC 鎵弿 + 缁撴灉鎻℃墜 + 搴旂瓟銆?
## 5. 涓庣幇鏈夋墜娈电殑鍒嗗伐锛堣皝淇濈暀銆佽皝鍒犻櫎锛?
| 鎵嬫 | 澶勭疆 |
| --- | --- |
| 鎵撳寘寮?`V2_DEBUG_CSR`锛?x80/0x84/0x88鈥︼級 | **鍒犻櫎**銆傚畠鑷韩寮曞叆浣嶅煙/鍦板潃鍐茬獊 bug锛屼笖瑙傛祴璧拌娴嬭矾寰?|
| 甯告暟瀵勫瓨鍣紙`0x5A5A0003`锛?| **淇濈暀涓€涓?*锛岀敤浜?L4 鐨?鍥炶閫氳矾鑷"锛堜綆鎴愭湰銆佹棤姝т箟锛?|
| `WT_STATUS`锛?x7C锛?| **淇濈暀**锛屽畠鏄绾﹀瘎瀛樺櫒锛屼笉鏄皟璇曡鏂?|
| `apply_reject_reason` | 浣滀负**鐘舵€佷綅**淇濈暀锛圠4 鏂█鐢級锛屼絾涓嶅啀浣滀负娴嬮噺涓婚€氶亾锛汫AO 閲屽悓鏃跺彲瑙?|
| 涓绘満 UART 鑴氭湰 | **淇濈暀骞朵弗鏍煎寲**锛圓CK 鍏ㄥ瓧娈点€佽秴鏃堕潪闆堕€€鍑恒€佸師濮嬪抚鍏ュ簱锛?|
| 浠跨湡鍥炲綊 | **淇濈暀**锛圠2锛夛紝瀹冩槸鍞竴鑳借窇 1024 鐐瑰叏娴佺▼涓斿彲閲嶅鐨勬墜娈?|

## 6. 楠屾敹娓呭崟锛堟湰杞祦绋嬭惤鍦扮殑瀹氫箟锛?
1. `gao/apply.rao` 鑳借 `gw_sh` 鎺ュ彈骞剁敓鎴?`RTL_GAO/`锛堜竴娆＄患鍚堝嵆鍙獙璇侊級锛?2. `synth.py --gao` 浜х墿 `ao_0.fs` 瀛樺湪锛屼笖 sha256 璁板綍杩?manifest锛?3. `gao_sh` 鑳芥姄鍒?CSV锛岃鏁?= `storage_depth`锛?4. `gao_capture.py` 鑳芥妸 CSV 瑙ｇ爜鎴愭椂闂寸嚎锛堜俊鍙峰悕鏉ヨ嚜 .rao锛屼笉鍐欐椤哄簭锛夛紱
5. L4 闂幆 3 杞?+ 璐熶緥鍏?PASS锛?6. L2 鐨勫凡鐭ュけ璐ユ竻鍗曪紙褰撳墠 4 鏉★級鍙噺涓嶅銆?
## 7. 椋庨櫓涓庢湭鍐?
| 椋庨櫓 | 缂撹В |
| --- | --- |
| 鎺㈤拡淇″彿琚患鍚堜紭鍖栨帀 | 鍏抽敭鎺у埗缃戝姞 `syn_keep`锛涙垨鎶撶湡瀹炲瓨鍦ㄧ殑涓€绾у瘎瀛樺櫒 |
| 2048 娣卞害涓嶅鐪嬪畬鏁?apply 閾?| 瑙﹀彂鐐逛笂绉?涓嬬Щ锛屾垨鎶?`trig_pos` 璋冨埌 50% 鐪嬪墠鍚庡悇鍗?|
| `gao_sh` 涓庣儳鍐欎覆琛屽啿绐?| 娴佺▼閲屽己鍒?鍏堢儳鍚庢姄"锛屾姄瀹屾牎楠?IDCODE |
| GAO 鐗堜笌鏅€氱増浣嶆祦娣锋穯 | 鏂囦欢鍚嶅墠缂€ `ao_`锛宮anifest 鍒嗕袱鏉¤褰曪紝鐑у啓鑴氭湰鎸夎緭鍏ユ牎楠?|

## 8. 涓嬩竴姝ワ紙鎸夐『搴忥紝涓嶈烦姝ワ級

1. 钀?`gao/apply.rao`锛岃窇涓€娆?*浠呯患鍚?*楠岃瘉 `RTL_GAO` 鐢熸垚锛堚増2 鍒嗛挓锛夛紱
2. 瀹炵幇 `synth.py --gao` 涓?`gao_capture.py`锛?3. L4 鑴氭湰涓ユ牸鍖栵紙ACK 鍏ㄥ瓧娈?闈為浂閫€鍑?1024 鐐硅鍥烇級锛?4. 鐢ㄤ华鍣ㄥ寲浣嶆祦鎶撲竴娆?APPLY锛岀‘璁ゆ尝褰笌 L2 搴忓垪涓€鑷达紱
5. 涔嬪悗鍐嶈皥鍔熻兘闂幆涓?1,537 鏉℃椂搴忚繚渚嬶紙鍒嗗埆鍏抽棴锛夈€?
---

## 9. 可行性验证结果（已实测，2026-10-30）

用本工程自己的设计跑了一次**仅综合**（`python scripts/synth.py --run-id gao_probe --syn-only --gao gao/apply.rao`）：

| 检查 | 结果 |
| --- | --- |
| `gw_sh` 接受 `.rao` | **是**，`SYNTH: PASS`，148 s |
| 自动生成 GAO RTL | `impl/v2_board_top_gao_probe/impl/gwsynthesis/RTL_GAO/gw_gao_top.v` 存在 |
| 探针解析正确 | `gw_ao_parameter.v`：`SIG_PORT_WIDTH = 112`、`STORAGE_DEPTH = 2048`、`TRIG_PORT_WIDTH_0 = 1`、`TRIG_TYPE = 0` |
| 探针名解析正确 | `gw_gao_top.v` 端口即 `.rao` 里的层次名（`\u_v2/u_uart_rx/data[7]` 等） |
| 资源 | Logic **20,500**（17,795 LUT + 2,705 ALU）、Register **11,149**、**BSRAM 49/56** |

**结论：GAO 路线在本工程上成立，且完全可脚本化。**

### 9.1 由实测得到的两条约束（比设计时的估算更硬）

1. **BSRAM 只剩 7 块余量**：2048 深度 × 112 位探针 = 229,376 位 ≈ 13 块 BSRAM。
   若要扩探针，必须**把深度降到 1024**（约 7 块）或裁信号；这是硬上限，不是偏好。
2. **窗口与探针位宽互相挤占**：深度 × 位宽 固定受 56 块 BSRAM 限制。
   当前配置（2048×112）覆盖 APPLY + CRC 扫描（12.8 µs）刚好够，**不要再加信号而不降深度**。

### 9.2 下一步（可执行）

1. 跑一次完整 `--gao` 构建（syn + pnr），确认 `ao_0.fs` 生成并记录 sha256；
2. 烧 `ao_0.fs`，用 `python scripts/gao_capture.py` 抓一次 APPLY；
3. 解码出的时间线必须与 L2 仿真序列一致（apply 脉冲 → done → reason → 版本递增）；
4. 之后 L4 的 UART 闭环与 L5 的 GAO 成为固定两件套，新问题先看波形再看寄存器。