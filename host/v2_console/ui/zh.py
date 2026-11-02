"""Every user-facing string, in one place.

The model keeps its own English messages -- the tests read them, and a session
log is easier to diff in ASCII -- so only the view asks this module what to put
on a label.  Keys are dotted names; a missing key falls back to the key itself,
which is ugly on screen but never raises inside the paint loop.
"""

from __future__ import annotations

ZH = {
    # window and tabs
    "app.title": "MGC3130 音色控制台 — %s",
    "tab.live": "实时演奏",
    "tab.tone": "音色",
    "tab.loop": "循环录制",
    "tab.wave": "波表",
    # per-tab hints
    "hint.live": "手在感应区移动：左右 → 速度，前后 → 音高，靠近 → 起音。没有手时不出数据，这是正常的。",
    "hint.tone": "拖动即写入。板子是 clamp 不是拒绝，写进去的值被截断时右侧显示的是板子读回的值。",
    "hint.loop": "盲录：听不到别的轨。选一张谱，画布会把这一轨每个 tick 的目标档填亮；录完给出命中率。",
    "hint.wave": "捕获 4 秒轨迹成一帧表，三帧即 A/B/C；上传后由 LFO 在三个表之间做 morph。",
    # sidebar
    "side.presets": "预设",
    "side.apply": "应用预设",
    "side.capture": "抓取预设",
    "side.readback": "读回波表",
    "side.empty": "artifacts/console/presets 里没有预设文件",
    # modes
    "mode.stop": "停止",
    "mode.live": "实时",
    "mode.play": "循环播放",
    "mode.wt": "波表试听",
    "mode.arp": "步进脉冲（每拍一个音，音高取自 Y）",
    "mode.read_params": "读取参数",
    "mode.ref_play": "试听参考",
    "mode.ref_stop": "停止参考",
    "mode.now": "当前模式：%s",
    "mode.bpm_live": "速度：由 X 轴决定（无读回）",
    "mode.bpm": "速度 %d BPM",
    "mode.identity": "板 0x%08X · 表 v%d",
    # loop strip
    "loop.track": "轨",
    "loop.arm": "对准一小节",
    "loop.commit": "提交",
    "loop.publish": "▶ 播放",
    "loop.stop": "停止",
    "loop.hint": "盲录：其他轨听不到",
    "loop.overdub": "边听边录（放已录轨）",
    "loop.countdown": "第 %d 轨 %d 秒后开窗",
    "loop.armed": "第 %d 轨已就绪",
    "loop.rec_countdown": "准备第 %d 轨…",
    "loop.rec_waiting": "第 %d 轨已武装，等板子开窗（约 4 秒）…",
    "loop.label_waiting": "⏳ 轨 %d 已武装，等开窗…",
    "loop.recording": "● 正在录第 %d 轨     tick %d/32     剩 %.1f s",
    "loop.label_recording": "● 录音中  轨 %d   %d/32 tick",
    "loop.label_done": "✔ 轨 %d 已采下　→ 下一步：点【提交】",
    "loop.label_failed": "✘ 这一条没收下",
    "loop.committing": "提交中…",
    "loop.publishing": "切换播放…",
    # score guide
    "score.label": "指引",
    "score.hit": "命中 %s",
    "score.wrong": "错 tick %s",
    # wave strip
    "wave.capture": "捕获一帧（4 秒）",
    "wave.gain": "增益移位",
    "wave.period": "LFO 周期（秒）",
    "wave.upload": "上传三帧",
    "wave.bin": "上传 .bin…",
    "wave.progress": "帧 %s  %d/%d",
    # empty states, drawn in the middle of a canvas that has nothing to show
    "empty.live": "等待手进入感应区",
    "empty.loop": "还没有轨道\n选轨 → 对准一小节 → 手在感应区画一遍",
    "empty.wave": "还没有波表\n点「捕获一帧」或「上传 .bin…」",
    # tone groups
    "danger": "危险",
    # status bar
    "status.none": "未连接",
    "status.mode": "模式 %s",
    "status.mode_recording": "模式 录制（板子）",
    "status.monitor_playing": "监听 PC 播放中",
    "status.monitor_off": "监听 关",
    "status.loop": "循环已激活",
    "status.fault": "历史错误（复位才清）",
    "status.waiting": "等待手进入感应区",
    "status.frames": "%d 帧",
    "status.voices": "声部 %d",
    "status.steals": "抢占 %d",
    "status.note": "音高 %d",
    "status.z": "高度 %d",
}

MODE_NAMES = {
    0: "空闲",
    1: "实时",
    2: "录制",
    3: "提交",
    4: "循环播放",
    5: "错误",
    6: "波表试听",
}

PARAM_NAMES = {
    0x40: "滤波器",
    0x44: "低频振荡",
    0x84: "效果 A",
    0x88: "效果 B",
    0x8C: "效果 C",
    0x90: "总音量",
    0x94: "包络 AD",
    0x98: "包络 SR",
    0x9C: "声部混合",
}

FIELD_NAMES = {
    (0x40, "ci"): "截止",
    (0x40, "res"): "共振",
    (0x40, "enable"): "启用",
    (0x44, "rate_mhz"): "速率",
    (0x44, "depth"): "深度",
    (0x44, "enable"): "启用",
    (0x44, "retrig"): "重触发",
    (0x44, "unipolar"): "单极",
    (0x44, "wave"): "波形",
    (0x84, "gain_q16"): "增益",
    (0x84, "level"): "插入点",
    (0x84, "enable"): "启用",
    (0x88, "delay"): "延迟",
    (0x88, "cutoff_q16"): "截止",
    (0x8C, "feedback_q15"): "反馈",
    (0x8C, "reverb_mix_q15"): "混响",
    (0x90, "volume_q16"): "音量",
    (0x94, "attack_step"): "起音",
    (0x94, "decay_step"): "衰减",
    (0x98, "sustain_level"): "延音电平",
    (0x98, "release_step"): "释放",
    (0x9C, "velocity_shift"): "力度移位",
    (0x9C, "detune_shift"): "失谐移位",
    (0x9C, "glide_rate"): "滑音速率",
}

SCOPE_NAMES = {"all": "全部模式", "play": "仅循环播放"}

DANGER_NAMES = {
    0x84: "增益 0 会让循环播放静音",
    0x8C: "反馈 ≥ 1.0 会自激",
    0x94: "起音 0 永远升不上去",
    0x98: "释放 0 会卡死事件流",
    0x9C: "滑音 0 会把偏音卡住",
}


def t(key: str, *args) -> str:
    text = ZH.get(key, key)
    return text % args if args else text


# ``params.display`` is the single source of truth for unit conversion and is
# asserted in English by its tests, so the view translates the few words it
# emits instead of duplicating the maths. Units (kHz, ms, dB, %) stay as they are.
_DISPLAY_WORDS = (
    ("sample&hold", "采样保持"),
    ("triangle", "三角波"),
    ("square", "方波"),
    ("sine", "正弦波"),
    ("saw", "锯齿波"),
    ("+lowpass", "+低通"),
    ("+delay", "+延迟"),
    ("+comb", "+梳状"),
    ("dry", "干声"),
    ("octaves", "倍频程"),
    ("samples", "采样"),
    ("inf", "∞"),
    ("res", "Q"),
    ("shift", "移位"),
    ("rate", "速率"),
    ("wave", "波形"),
    ("level", "插入"),
)


def localize(text: str) -> str:
    for english, chinese in _DISPLAY_WORDS:
        text = text.replace(english, chinese)
    return text


def mode_name(mode: int) -> str:
    return MODE_NAMES.get(mode, str(mode))


def param_name(addr: int) -> str:
    return PARAM_NAMES.get(addr, "0x%02X" % addr)


def field_name(addr: int, name: str) -> str:
    return FIELD_NAMES.get((addr, name), name)


def scope_name(scope: str) -> str:
    return SCOPE_NAMES.get(scope, scope)


def danger_name(addr: int) -> str:
    return DANGER_NAMES.get(addr, "")
