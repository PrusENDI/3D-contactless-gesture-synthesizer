# 杈撳叆娑堣垂鐨勪笁鏉¤矾寰勶細缂哄彛涓庤€﹀悎鍒嗘瀽锛?026-10-31锛?
## 1. 涓夋潯璺緞鐨勭幇鐘?
| 璺緞 | 杈撳叆鏉ユ簮 | 娑堣垂鑰?| 杈撳嚭鍘诲悜 |
| --- | --- | --- | --- |
| **LIVE** | 鍏夋爣婊ゆ尝鍣紙`audio_cursor_*` 绛夋暎淇″彿锛?| `v2_live_rule_engine` | `voice_event_*`锛坄mode_live`锛?|
| **LOOP** | 鍚屼笂锛?*鍚屼竴涓?* rule engine锛?| 褰曞埗锛歚v2_loop_event_store_dpb`锛涙挱鏀撅細`loop_event_*` | 褰曞埗瀛?DPB锛涙挱鏀捐繘 `voice_event_*`锛坄mode_play`锛?|
| **娉㈣〃** | **涓嶆秷璐硅緭鍏?* | `v2_wt_playback` | I2S锛坄mode_wt_play`锛?|

鍏抽敭鎺ョ嚎锛坄mgc3130_v2_top.sv`锛夛細

```verilog
// 319: LIVE 涓?RECORD 鍏辩敤鍚屼竴涓?rule engine锛宺eady 鐢辨ā寮忓喅瀹?assign live_event_ready = mode_live ? voice_event_ready : mode_record ? record_event_ready : 1'b0;
// 310-311: 褰曞埗鐩存帴鍚?rule engine 鐨勪簨浠舵祦
.record_event_valid(live_event_valid), .record_event_ready(record_event_ready) ...
// 422-425: 涓変釜浜嬩欢婧愬湪澹伴煶寮曟搸鍏ュ彛鍋氭ā寮忎笁閫変竴
assign voice_event_valid = mode_live ? live_event_valid : mode_play ? loop_event_valid : potts_event_valid;
assign loop_event_ready  = mode_play ? voice_event_ready : 1'b0;
assign potts_event_ready = (!mode_live && !mode_play) ? voice_event_ready : 1'b0;
```

## 2. 姣忔潯璺緞鐨勭己鍙?
### 2.1 LIVE

| 缂哄彛 | 璇存槑 |
| --- | --- |
| 瀛楁閿欎綅 | `x/y/z/velocity/depth` 鍦?`sample_ce && stable_valid` 鏇存柊锛岃€屾秷璐硅妭鎷嶆槸 `cursor_frame_done` |
| 闈欓粯涓㈠抚 | `eval_*` 鏃犳潯浠惰杞姐€佽鍒欐洿鏂拌鑳屽帇鎸′綇 鈫?甯ц瑕嗙洊涓旀棤璁℃暟 |
| 闂ㄦ帶涓庡潗鏍囦笉鍚屾簮 | `touch/bow` 鏉ヨ嚜杈撳叆娴佹按锛屾瘮鍏夋爣杈撳嚭鏃╄嫢骞叉媿 |

### 2.2 LOOP

| 缂哄彛 | 璇存槑 |
| --- | --- |
| **涓?LIVE 鍏辩敤瑙勫垯寮曟搸** | 鍙湁涓€浠?`v2_live_rule_engine`锛氬綍鍒舵椂鐨勬槧灏?*蹇呯劧绛変簬** Live 鏄犲皠锛屾棤娉?褰曚竴濂椼€佹挱鍙︿竴濂? |
| 褰曞埗鑳屽帇鍐荤粨 Live 璇勪及 | RECORD 妯″紡涓?`live_event_ready = record_event_ready`锛屽綍鍒跺啓涓嶈繘鏃惰鍒欑姸鎬佺洿鎺ュ仠鎽?|
| 鎾斁渚ф棤杈撳叆 | 鎾斁闃舵 `loop_event_*` 鍙洖鏀惧巻鍙蹭簨浠讹紝涓庡綋鍓嶅厜鏍?*鏃犲叧**锛堟病鏈?杈瑰綍杈硅窡鎵?鐨勯€氳矾锛?|
| 杈圭晫璇箟鏈畾 | `loop_boundary` 涓庡厜鏍囧抚娌℃湁鏃堕棿鎴冲叧鑱旓紝璺ㄨ竟鐣岀殑浜嬩欢瀵归綈闈?`tick` 闅愬紡绾﹀畾 |

### 2.3 娉㈣〃

| 缂哄彛 | 璇存槑 |
| --- | --- |
| **瀹屽叏涓嶆秷璐硅緭鍏?* | `v2_wt_playback` 鍙湁 `sample_ce` + 鍥哄畾鐩镐綅锛屾棤 pitch/gate/浣嶇疆杈撳叆 |
| 璇诲彛鍐茬獊 | 娉㈣〃鎾斁鍗犵敤 loader 鐨勫敮涓€璇诲彛锛屼笌涓绘満 1024 鐐瑰洖璇讳簰鏂ワ紙宸插湪 搂19/搂22 璁板綍锛?|
| 鏃犺皟鍒跺绾?| "鐢ㄥ厜鏍?y 鎺у埗闊抽珮銆乪ngaged 鎺у埗 gate"杩欑被璇箟杩樻病鏈夊畾涔?|

## 3. 鑰﹀悎闂锛堢粨鏋勬€э紝涓嶆槸鎺ョ嚎闂锛?
1. **鍗曡鍒欏紩鎿?*锛歀IVE 涓?LOOP 褰曞埗鍏辩敤涓€浠斤紝浜岃€呭湪璇箟涓婅缁戞锛?2. **鍗曚簨浠剁鍙?+ 妯″紡涓夐€変竴**锛氬０闊冲紩鎿庡悓涓€鏃跺埢鍙帴鍙椾竴涓簮锛屼换浣曟柊娑堣垂鑰呴兘瑕佹敼杩欎釜 mux锛?   ready 淇″彿鍙堣妯″紡闂ㄦ帶涓?0锛屽鑷?娌″湪鐢ㄧ殑璺緞"浼氭妸涓婃父鎷栨锛?3. **鏃犳墖鍑?*锛氬厜鏍囧彧鏈変竴涓?1 鎷?`frame_output_valid`锛屼笁鏉¤矾寰勫悇鑷寜淇″彿鍚嶆帴绾匡紝
   浜庢槸閿欎綅琚鍒朵笁浠斤紱
4. **璇诲彛鍏变韩**锛氭尝琛ㄦ挱鏀句笌涓绘満鍥炶浜掓枼锛?5. **妯″紡鍗充徊瑁?*锛歚mode_reg` 鍚屾椂鍐冲畾"璋佸彂澹?"璋佸綍鍒?"璋佹斁琛?锛屼笁绉嶈€﹀悎鍙犲湪涓€涓瘎瀛樺櫒涓娿€?
## 4. 鍒ゆ柇

- **鍔?FIFO 鍙兘瑙ｅ喅 LIVE 鐨勪涪甯?*锛岃В鍐充笉浜?涓夎矾鍏辩敤涓€涓敓浜ц€?涓€涓紩鎿?涓€涓鍙?鐨勮€﹀悎锛?- 鐪熸闇€瑕佺殑鏄?*涓€娆℃墦鍖?+ 骞挎挱**锛氬厜鏍囧抚骞挎挱缁欎笁涓秷璐硅€咃紝鍚勮嚜鏈夌嫭绔嬬殑灏忕紦鍐诧紙娣卞害 2 鍗冲彲锛?  鍥犱负娑堣垂绔兘鍦?80 MHz銆佸抚鐜?鈮?38 Hz锛夛紝鐢熶骇鑰呮案涓嶅洜鏌愪釜娑堣垂鑰呭仠椤胯€屽仠鎽嗭紱
- LOOP 蹇呴』鍏堝畾璇箟锛?*褰?Live 鐨勪簨浠?*锛坱ap 鐜版湁寮曟搸锛夎繕鏄?*鐙珛鏄犲皠**锛堥渶瑕佺浜屼唤瑙勫垯寮曟搸锛夈€?  杩欏喅瀹氶潰绉笌鎺ョ嚎锛屼笉鑳界敤瀹炵幇缁嗚妭鎺╃洊銆?
## 5. 寤鸿鐨勬帴鍙ｅ舰鎬?
```
cursor filter 鈹€鈹€[packed frame + valid]鈹€鈹€鈹攢鈹€> LIVE 瑙勫垯寮曟搸锛堝惈 pop 闂ㄦ帶 + drop 璁℃暟锛?                                        鈹溾攢鈹€> LOOP 褰曞埗缂撳啿锛堝彲閫夛細tap 寮曟搸杈撳嚭 鎴?鐙珛寮曟搸锛?                                        鈹斺攢鈹€> 娉㈣〃璋冨埗锛坹鈫抪itch, engaged鈫抔ate锛塠寰呭畾涔夊绾
```

姣忎釜娑堣垂鑰呬竴涓?2 娣?skid 缂撳啿 + 鑷繁鐨?`overflow` 璁℃暟锛涚敓浜ц€呬晶鍙仛骞挎挱锛屼笉绛?ready銆?杩欐牱"鏌愪竴璺繖"涓嶄細褰卞搷鍙﹀涓よ矾锛屼篃涓嶉渶瑕佹妸涓変釜妯″紡鎻夎繘涓€涓?mux銆?
## 6. 闇€瑕佸厛瀹氱殑涓変欢浜?
1. **LOOP 璇箟**锛氬綍 Live 浜嬩欢锛岃繕鏄嫭绔嬫槧灏勶紵
2. **娉㈣〃娑堣垂浠€涔?*锛歽鈫掗煶楂樸€乪ngaged鈫抔ate 鏄惁灏辨槸鐩爣璇箟锛熻繕鏄彧鐢ㄤ綅缃仛闊宠壊璋冨埗锛?3. **妯″紡鏄惁杩樿鐙崰**锛氫笁璺槸鍚﹀彲浠ュ苟瀛橈紙渚嬪娉㈣〃鍨簳 + Live 涓诲锛夛紝杩樻槸缁х画涓夐€変竴锛?
---

## 7. LIVE 到发声的通路修复（2026-10-31）

### 7.1 问题

`v2_live_rule_engine` 的实例化取的是 `audio_cursor_*`（只在 `sample_ce && stable_valid`
时更新），而消费节拍是 `cursor_frame_done`。实测：`cursor_x=0x8000` 时
`audio_cursor_x` 仍为 0 → 规则引擎看到的是**全 0 坐标**，无法产生有意义的音符。

### 7.2 修复

| 端口 | 原接线 | 现接线 |
| --- | --- | --- |
| `x/y/z` | `audio_cursor_*` | **`cursor_x/y/z`**（滤波器同拍输出） |
| `touch/bow`（gate） | `calibrated_touch/presence` | **`cursor_point_valid`**（光标已 engage） |
| `velocity_in` | `audio_velocity` | **`cursor_velocity[7:0]`** |
| `brightness_in` | `audio_depth` | **`cursor_depth`** |

并新增观测：`0xD4` = `live_event_count`，`0xE8` = `{active, gate, note[7:0]}`。

### 7.3 板上结果（位流 `36B65FDA…E138`，`MODE=1`）

```
const=0x5A5A0003   MODE=1 -> err=0
time  events  active gate note  points
  0s       1       1    1   60    170
  ...      1       1    1   60    170
```

**LIVE 通路已从"坐标全 0、不发声"变成"进入 LIVE 即触发 note-on，音高 60"**。

### 7.4 仍需验证

- 声音是否真的从耳机输出（需实听）；
- 手指纵向移动时 `note` 是否随 `y` 改变、抬手是否发 note-off；
- 事件背压时仍会静默丢帧（未加 pop 门控与计数）。