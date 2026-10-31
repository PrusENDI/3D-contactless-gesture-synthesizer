# Cursor 鈫?Live 鐨勬椂搴忛敊浣嶅垎鏋愪笌"鎵撳寘鎴愬抚浜嬩欢"璇勪及锛?026-10-31锛?
## 1. 鐜扮姸锛氫笁灞傞敊浣嶏紝涓嶆槸涓€灞?
`v2_live_rule_engine` 鐨勫疄渚嬪寲锛坄mgc3130_v2_top.sv`锛夋槸杩欐牱鎺ョ殑锛?
```verilog
v2_live_rule_engine #(.PIPELINE_NOTE(1)) u_live (
  .frame_in_valid(cursor_frame_done),
  .x(audio_cursor_x[15:0]), .y(audio_cursor_y[15:0]), .z(audio_cursor_z[15:0]),
  .touch(calibrated_touch), .bow(calibrated_presence),
  .velocity_in(audio_velocity[7:0]), .brightness_in(audio_depth),
  ...
```

娑堣垂绔湪 `cursor_frame_done` 閭ｄ竴鎷嶉噰鏍锋墍鏈夎緭鍏ャ€傞棶棰樻槸杩欎簺杈撳叆鐨?*鏇存柊鏃跺埢鏍规湰涓嶅悓**锛?
| 杈撳叆 | 鏇存柊鏉′欢 | 鎵€鍦ㄦ祦姘寸骇 |
| --- | --- | --- |
| `frame_in_valid` (`cursor_frame_done`) | 姣忓鐞嗗畬涓€甯ц剦鍐蹭竴娆★紙~138 Hz锛?| 鍏夋爣婊ゆ尝杈撳嚭 |
| `x/y/z`锛坄audio_cursor_*`锛?| **`sample_ce && stable_valid`**锛?8 kHz锛?| 鍏夋爣婊ゆ尝鐨?stable 鍒嗘敮 |
| `velocity_in`/`brightness_in` | 鍚屼笂 | 鍚屼笂 |
| `touch`/`bow` | 姣忎釜杈撳叆甯э紙`calibrated_*`锛?| 鏍″噯/杈撳叆娴佹按 |

鐢辨鏈変笁灞傞敊浣嶏細

1. **瀛楁婊炲悗**锛歚audio_cursor_*` 鍦?`sample_ce && stable_valid` 鏃舵墠鏇存柊锛岃€?`cursor_frame_done` 涓庡畠涓嶅悓鎷嶏紱鏈€鍧忔儏鍐典笅锛坄stable_valid` 鎺夛級锛屽瓧娈典細**涓€鐩村喕缁?*锛屼笅娓稿嵈浠嶅湪鎷?`frame_in_valid` 褰?鏂板抚"銆?2. **鍩熶笉鍚?*锛歚touch`/`bow` 鏉ヨ嚜杈撳叆娴佹按锛屾瘮鍏夋爣杈撳嚭鏃╄嫢骞叉媿锛堜腑鍊兼护娉?+ 闄ゆ硶鍣級锛屽悓涓€鎷嶉噰鍒扮殑"瑙︽懜"鍜?鍧愭爣"鍙兘灞炰簬涓嶅悓甯с€?3. **鎻℃墜璇箟缂哄け**锛歚frame_in_valid` 鏄?1 鎷嶈剦鍐诧紝濂戠害涓婃病鏈夊畾涔?杩欎竴鎷嶅繀椤诲悓鏃剁湅鍒板摢浜涘瓧娈?锛屼簬鏄瘡娆℃敼鎺ョ嚎閮藉彲鑳芥倓鎮勭牬鍧忎竴鑷存€с€?
杩欐鏄綘璇寸殑"Cursor 杈撳嚭鍜?Live 杈撳叆鏃跺簭閿欎綅"鈥斺€?*鏍瑰洜鏄帴鍙ｆ寜淇″彿鎺ョ嚎锛岃€屼笉鏄寜甯ф墦鍖?*銆?
## 2. 褰卞搷

- 浜嬩欢锛坣ote on/off锛夋惡甯︾殑 `x/y/z/velocity` 鍙兘鏄?*涓婁竴甯?*鐢氳嚦**鍐荤粨鍊?*锛?- 闂ㄦ帶锛坓ate锛変笌鍧愭爣涓嶅悓婧愭椂锛屼細鍑虹幇"宸茬粡鎶墜浣嗕粛鍦ㄥ彂澹?鎴?鏈姮鎵嬪嵈瑙﹀彂"锛?- 涓€鏃︿笅娓稿啀鍔犱竴涓秷璐硅€咃紙Loop/Potts锛夛紝姣忎釜娑堣垂鑰呴兘瑕佽嚜宸辩寽鏃跺簭鈥斺€旈敊浣嶄細琚鍒躲€?
## 3. 鏂规瀵规瘮

### 鏂规 A锛堟帹鑽愶級锛氬厜鏍囧抚瀵勫瓨鍣?+ 鍗曚竴 valid

鍦?`cursor_frame_done` 閭ｄ竴鎷?*鍘熷瓙閿佸瓨**涓€涓厓缁勶細

```verilog
typedef struct packed {
    logic [15:0] x, y, z;         // 鍏夋爣鍧愭爣锛堟护娉㈠悗锛?    logic [15:0] pitch;           // normalized_pitch
    logic [15:0] velocity, depth; // 鎺у埗閲?    logic [1:0]  state;           // DISENGAGED/ENGAGED/REBASED
    logic        engaged;         // 绛変环浜?gate 鐨勬护娉㈠悗鐗堟湰
    logic        touch, bow;      // 璇箟闂ㄦ帶锛堟湰甯э級
    logic        point_valid, rebased, stable_valid;
    logic [7:0]  reason;          // calibration_reason
    logic [15:0] sequence;        // 甯у簭鍙?    logic [31:0] tick;            // sample_index / timestamp
} v2_cursor_frame_t;
```

- `v2_cursor_frame_t frame;` + `logic frame_valid;`
- 鍦?`always_ff` 閲?`if (cursor_frame_done) frame <= {鈥; frame_valid <= cursor_frame_done;`
- Live/Loop/Potts 鍙湪 `frame_valid` 閭ｆ媿閲囨牱锛屼笖**鍙?*浠?`frame` 鍙栧瓧娈点€?
鎴愭湰锛氱害 150 涓?FF锛堝綋鍓?10,476 / 23,280锛屽崰姣斿彲蹇界暐锛夈€?
浼樼偣锛氫竴涓?valid銆佷竴涓厓缁勶紝璇箟鑷唇锛涙柊澧炴秷璐硅€呮棤闇€鍐嶇寽鏃跺簭锛涘彲澶嶇敤涓?Loop 褰曞埗鐨勪簨浠惰浇鑽枫€?
### 鏂规 B锛堟渶灏忔敼鍔級锛氱粺涓€鏇存柊鍩?
璁?`audio_cursor_*` 鏀规垚**姣?`sample_ce` 鏃犳潯浠?*鏇存柊锛堝幓鎺?`stable_valid` 闂ㄦ帶锛夛紝
骞舵妸 `touch/bow` 涔熷瘎瀛樺埌鍚屼竴鍩熴€傛敼鍔?3鈥? 琛屻€?
缂虹偣锛氫粛鐒跺瓨鍦?甯ц剦鍐蹭笌瀛楁鏇存柊涓嶅悓鎷?鐨勭獥鍙ｏ紙鈮?0 碌s锛夛紝鍙槸鎶婂喕缁撻棶棰樺幓鎺変簡锛?濂戠害涓婁緷鏃ф病鏈?鍚屽抚"淇濊瘉銆?
### 鏂规 C锛堜笉鎺ㄨ崘锛夛細涓嬫父鍚勮嚜鍔犲欢杩熷榻?
姣忎釜娑堣垂鑰呭悇鑷墦鎷嶅欢杩熴€傞敊浣嶈澶嶅埗鍒版瘡涓秷璐硅€咃紝涓斿欢杩熷€奸殢鍐呴儴瀹炵幇鍙樺寲锛屼笉鍙淮鎶ゃ€?
## 4. 缁撹

**搴旇鎵撳寘銆?* 浣嗚鏄庣‘鎵撳寘鐨勬槸"**鍏夋爣甯?*"锛屼笉鏄?鎶婄幇鏈変俊鍙锋尓鍒颁竴璧?锛?
- 閿佸瓨鐐瑰繀椤婚€夊湪 `cursor_frame_done`锛堝厜鏍囨护娉㈠敮涓€鐨勪竴甯х粨鏉熺偣锛夛紱
- 鍏冪粍蹇呴』**鍖呭惈 gate 璇箟**锛坄engaged` 涓?`touch/bow`锛夛紝鍚﹀垯"鍧愭爣涓庨棬鎺т笉鍚屾簮"鐨勯棶棰樹粛鍦紱
- 涓嬫父鍙 `frame_valid` + 鍏冪粍锛岀姝㈠啀鍗曠嫭鎺?`audio_cursor_*`锛?- `sequence`/`tick` 涓€璧锋墦鍖咃紝渚夸簬瀵归綈閬ユ祴涓?Loop 褰曞埗銆?
## 5. 瀹炴柦椤哄簭锛堝緟鎵瑰噯锛?
1. 鍦?`v2_contract_pkg` 閲屽畾涔?`v2_cursor_frame_t`锛?2. `v2_cursor_filter_timed` 澧炲姞 `frame`/`frame_valid` 杈撳嚭锛堝湪 `frame_output_valid` 鍚屾媿閿佸瓨锛夛紱
3. 椤跺眰鎶?Live/Loop/Potts 鏀规垚浠?`frame` 鍙栧瓧娈碉紱
4. 鍥炲綊锛歚sim.py` 鍙?RAM + 鏉夸笂鍏夋爣鏄剧ず锛坄host/cursor_view.py`锛夌‘璁ゅ潗鏍囦笌闂ㄦ帶鍚屾锛?5. 鏂囨。锛氭妸璇ユ帴鍙ｅ啓杩涘绾︼紝绂佹鍐嶇洿鎺ユ帴 `audio_cursor_*`銆?
---

## 6. 下游到底怎么消费输入（决定要不要 FIFO）

### 6.1 今天的消费路径

```
cursor_frame_done (1 拍)
   -> v2_live_rule_engine  eval 寄存器 (无条件装载, line 237-239)
   -> 规则状态机 (line 260: 仅当 !(event_valid && !event_ready) 才更新)
   -> event_valid/event_data -> live_event_ready
```

`live_event_ready` 的来源（`mgc3130_v2_top.sv:319`）：

```verilog
assign live_event_ready = mode_live ? voice_event_ready : mode_record ? record_event_ready : 1'b0;
```

而 `voice_event_ready = rst_n && !scan_busy && !revoice_pending && ...`（32 音扫描期间为低）。

### 6.2 因此存在两个丢帧点

1. **被背压时不更新、但 eval 寄存器照样被下一帧覆盖**：
   `eval_valid <= frame_in_valid` 无条件执行，规则状态更新却被
   `!(event_valid && !event_ready)` 挡住 → 那一帧的数据被**静默丢弃**（无计数器）。
2. **模式门控让 ready 长期为 0**：非 LIVE/RECORD 模式下 `live_event_ready = 0`，
   如果在这种状态下持续喂帧，任何 FIFO 都会**灌满并积压旧帧**；一旦切进 LIVE，
   前几帧还是旧的——这比丢帧更糟。

### 6.3 所以：要 FIFO，但不能只加 FIFO

| 结论 | 理由 |
| --- | --- |
| **要加** | 背压确实存在（32 音扫描、录制路径），1 拍脉冲 + 无握手 = 静默丢帧 |
| **深度 4–8 足够** | 帧率 ≤138 Hz（≈7 ms 一帧），消费停顿是"音扫描/事件握手"级（µs 级）；与滤波器输入侧 `FIFO_DEPTH=8` 对称 |
| **必须同时改消费端** | `eval_*` 改成只在"能动作"时装载（否则 FIFO 出来了照样丢） |
| **必须处理模式门控** | 非 LIVE 时要么停止生产，要么在进入 LIVE 时**清空/合并**队列，避免旧帧回放 |
| **必须有丢帧计数** | 与项目证据纪律一致：静默丢弃不可接受 |

### 6.4 推荐的边界设计

```verilog
// 生产者: 光标帧（已打包的 tuple + valid）
// 队列: 深度 4，满时 producer_stall 回压到光标滤波器
// 消费者: live 引擎仅在 (frame_pop && 能动作) 时弹出
```

语义上区分两类内容：

- **状态量**（x/y/z/pitch/velocity/depth/state）：可被更新帧**覆盖**（latest-wins），
  队列满时应丢弃旧的状态帧而不是回压整个滤波链；
- **边沿量**（engaged 上升/下降 → note on/off）：**不可丢**，应保证在队列里
  至少各有一个事件位，或由消费端比较连续两帧自行推导。

最简实现：FIFO 深度 4，存打包帧；生产者满即回压；消费者只在可动作时弹出；
进入 LIVE 时清空；另加 `drop_count` 与 `overflow` 状态位供上位机读取。