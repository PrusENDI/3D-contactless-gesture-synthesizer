"""The window: one model behind four tabs, and the Tk code that draws it.

The model is pure -- it holds the session, the telemetry buffer, the table and the
contours, and answers "what does this tab draw" and "what does this button do".
Only :class:`ConsoleWindow` and ``canvas/render_tk.py`` import tkinter, and every
action that talks to the board runs on a worker thread, because one command costs
17 ms and a failed one can cost 800 ms.
"""

from __future__ import annotations

import datetime as _dt
import queue
import threading
import time

from .. import phase as phase_mod
from ..audio import reference
from ..canvas import primitives
from ..session import core
from ..telemetry import TelemetryBuffer
from ..views import live_painter, loop_painter, wave_painter

TABS = ("live", "tone", "loop", "wave")


class ConsoleModel:
    """Everything the window shows, with no Tk in it."""

    def __init__(self, session=None, buffer: TelemetryBuffer | None = None):
        self.session = session
        self.buffer = buffer or TelemetryBuffer()
        self.phase = phase_mod.PhaseAnchor()
        self.table = []
        self.table_diff = None
        self.frames: dict = {}
        self.uploaded_frames: dict = {}
        self.trajectory: list = []
        self.contours: dict = {}
        self.live_contour = None
        self.preset_name = ""
        self.message = ""
        self._status = None
        self._status_at = 0.0
        self.player = reference.Player()
        self.overdubbing = False
        self.overdub_path = None
        self.flow = None
        self.flow_factory = None
        self.track = 0
        self.commit_count = 0
        self.score = None
        self.hit = None
        self._io = 0
        # What the LOOP page says while a take runs. The window paints this, not the
        # worker: a worker blocked in a capture cannot report its own progress.
        self.record_state = "idle"        # idle | waiting | countdown | armed | captured | failed
        self.record_track = 0
        self.record_started = 0.0
        # The capture does not start at the arm: v2_loop_contour_capture waits for
        # the next tick-0 of a 32-tick wrap, and 0x08=120 has just put the tick at 1,
        # so it waits a whole bar. Measured: FULL lands 7.9 s after the arm on every
        # take (spread 0.07 s) = 4 s of waiting + a 4 s window.
        self.record_offset = 4.0
        self.record_seconds = 4.0
        self.take_coverage = 0           # ticks the hand was in the field for
        self.take_failed_at = 0.0
        self._readouts = None
        self._readouts_at = 0.0
        self.params: dict = {}
        from ..session import record_flow as _record_flow

        self.flow_factory = _record_flow.RecordFlow

    # -- state --------------------------------------------------------------

    def status(self):
        return self.session.status() if self.session is not None else None

    def cached_status(self, max_age_s: float = 1.0):
        """The window redraws at 30 Hz; a STATUS command per frame would be 17 ms each."""
        now = time.monotonic()
        if self._status is None or (now - self._status_at) > max_age_s:
            self._status = self.status()
            self._status_at = now
        return self._status

    # -- who may touch the link ---------------------------------------------
    #
    # One command costs 17.6 ms and a lost one costs 1.2 s (three timeouts), so the
    # window must not poll while a worker owns the link: the Tk thread would block
    # behind it and every repaint would wait.

    def begin_io(self) -> None:
        self._io += 1

    def end_io(self) -> None:
        self._io = max(0, self._io - 1)

    def io_busy(self) -> bool:
        return self._io > 0

    def can_edit_params(self) -> bool:
        """The nine parameters are writable in PLAY too: tuning while it plays is supported."""
        return self.session is not None

    def can_write_table(self) -> bool:
        """Upload and read-back need IDLE; in any other mode the board refuses them."""
        status = self.cached_status()
        return status is None or status.mode == 0

    def status_line(self) -> str:
        status = self.cached_status()
        if status is None:
            return "not connected"
        name = core.MODE_NAMES.get(status.mode, str(status.mode))
        parts = ["mode %s" % name]
        if status.loop_active:
            parts.append("loop active")
        if status.fault:
            parts.append("fault 0x%04X" % status.fault)
        if self.buffer.waiting():
            parts.append("waiting for a hand over the sensor")
        else:
            parts.append("%d frames" % len(self.buffer.trail(10 ** 6)))
        if self._readouts:
            parts.append("voices %d" % self._readouts.get("voices", 0))
            parts.append("steals %d" % self._readouts.get("steals", 0))
            parts.append("note %d" % self._readouts.get("note", 0))
            parts.append("z %d" % self._readouts.get("z", 0))
        if self.message:
            parts.append(self.message)
        return "  ".join(parts)

    # -- actions (the buttons call these; they own no Tk) --------------------

    def stop(self) -> str:
        self.session.stop()
        self.message = "stopped"
        return self.message

    def apply_preset(self, preset) -> str:
        result = self.session.apply_preset(preset)
        self.preset_name = preset.name
        if result.ok:
            self.message = "preset %s applied" % preset.name
        else:
            addr = "0x%02X" % result.failed_addr if result.failed_addr else "?"
            self.message = "preset %s failed at %s" % (preset.name, addr)
        return self.message

    def capture_preset(self, name: str) -> str:
        preset = self.session.capture_preset(name)
        self.message = "captured preset %s" % preset.name
        return self.message

    def upload(self, samples, table: int = 0, voice_shift: int = 2) -> str:
        if not self.can_write_table():
            raise RuntimeError("uploading needs IDLE; stop the loop first")
        result = self.session.upload_table(samples, table=table, voice_shift=voice_shift)
        self.table = list(samples)
        self.table_diff = None
        self.message = "uploaded %d samples (v%d, %.1f s)" % (
            len(samples),
            result.active_version,
            result.elapsed_s,
        )
        return self.message

    def readback(self) -> str:
        if not self.can_write_table():
            raise RuntimeError("reading the table back needs IDLE")
        samples = self.session.read_table()
        self.table_diff = [
            0 if (index < len(self.table) and self.table[index] == sample) else 1
            for index, sample in enumerate(samples)
        ]
        mismatches = sum(self.table_diff)
        self.message = "read back %d samples, %d differ from the file" % (len(samples), mismatches)
        return self.message

    @staticmethod
    def _audio_path(name: str) -> str:
        """Rendered audio lives under artifacts/, never in the repo root."""
        from pathlib import Path

        folder = Path("artifacts") / "console"
        folder.mkdir(parents=True, exist_ok=True)
        return str(folder / name)

    def play_reference(self, segments, table, voice_shift, env, path=None) -> str:
        if not table:
            raise RuntimeError("no wavetable loaded: upload one before playing a reference")
        path = path or self._audio_path("reference.wav")
        payload = reference.render_wav(segments, table=table, voice_shift=voice_shift, env=env)
        with open(path, "wb") as handle:
            handle.write(payload)
        self.player.play(path)
        self.message = "reference playing (%d segments)" % len(segments)
        return self.message

    def stop_reference(self) -> str:
        self.player.stop()
        self.message = "reference stopped"
        return self.message

    # -- overdub monitor: the host plays what the board cannot ---------------

    def default_env(self) -> dict:
        """The envelope the board plays a loop with, for the host's monitor."""
        from ..params import PARAMS

        return {
            "attack_step": PARAMS[0x94].default & 0xFFFF,
            "decay_step": (PARAMS[0x94].default >> 16) & 0xFFFF,
            "sustain_level": PARAMS[0x98].default & 0xFFFF,
            "release_step": (PARAMS[0x98].default >> 16) & 0xFFFF,
        }

    def overdub_segments(self) -> list:
        """The finished takes as one part; empty before the first one lands."""
        return reference.mix_contours(self.contours)

    def _audio_log(self, event: str, detail: str = "") -> None:
        """Audio state is invisible in the command log; write it there anyway.

        'I had to press 试听参考 every time' cannot be answered from a UART log:
        whether the monitor started, and whether it was stopped a moment later,
        only exists on this side.
        """
        log = getattr(self.session, "log", None)
        if log is None:
            return
        try:
            log.append(
                {
                    "t": _dt.datetime.now().isoformat(timespec="milliseconds"),
                    "op": "AUDIO",
                    "event": event,
                    "detail": detail,
                }
            )
        except Exception:
            pass

    def start_overdub(self, env=None, path: str | None = None) -> str:
        """Render the finished takes into one looping bar, ready to play.

        The board cannot monitor an overdub: ``voice_rst_n`` is held in reset
        outside LIVE/PLAY, so RECORD is silent by construction. The host has the
        takes as contours, and a contour is enough to re-synthesize the take, so
        the mix is rendered here and looped by the backend.

        Rendering a bar of Python takes a few hundred ms, so this runs *before*
        ``0x08=120`` forces the bar; :meth:`play_overdub` then only starts it.
        """
        segments = self.overdub_segments()
        if not segments:
            raise RuntimeError("no recorded take yet: the first one plays along with nothing")
        table = self.table or reference.sine_table()
        payload = reference.render_wav(
            segments,
            table=table,
            voice_shift=2,
            env=env or self.default_env(),
            normalize=True,          # same loudness for one take and for four
        )
        path = path or self._audio_path("overdub.wav")
        with open(path, "wb") as handle:
            handle.write(payload)
        self.overdub_path = path
        self.message = "monitor ready: %d take(s)" % len(self.contours)
        return self.message

    def play_overdub(self) -> str:
        """Start the bar prepared by :meth:`start_overdub`; nothing prepared, nothing plays."""
        if not getattr(self, "overdub_path", None):
            return self.message
        self.player.play(self.overdub_path)
        self.overdubbing = True
        self._audio_log("monitor_play", self.overdub_path)
        self.message = "monitor looping %d take(s) ON THE PC (not the board)" % len(self.contours)
        return self.message

    def stop_overdub(self) -> str:
        if not getattr(self, "overdubbing", False):
            return self.message
        self.player.stop()
        self.overdubbing = False
        self._audio_log("monitor_stop")
        self.message = "monitor stopped"
        return self.message

    def prepare_overdub(self) -> str:
        """Render the monitor early -- during the countdown, not on the downbeat.

        Rendering a bar takes a few hundred milliseconds and the bar starts when
        ``0x08=120`` lands, so rendering after the countdown would put the monitor
        that far behind and make the "go" beep a lie.
        """
        if not self.contours:
            return self.message
        return self.start_overdub()

    def armed_take(self, track: int, overdub: bool = True) -> str:
        """Arm, monitor, capture, stop the monitor -- in that order, for a reason.

        The mix has to be rendered before ``arm_take`` writes ``0x08=120`` (which
        restarts the bar), or the monitor starts a fraction of a beat late. What
        is left is the playback start latency, tens of milliseconds; the bar
        lengths are both exactly 4.000 s, so there is no drift, only that offset.
        """
        if overdub and self.contours and not self.overdub_path:
            self.start_overdub()
        self.arm_take(track)
        # The board does not capture yet: it waits a bar for the next tick-0. Start
        # the monitor when the window actually opens, or the backing plays against a
        # capture that has not begun.
        if self.overdub_path and self.record_offset > 0:
            time.sleep(self.record_offset)
        if self.record_state == "waiting":
            self.record_state = "armed"
        if self.overdub_path:
            self.play_overdub()
        try:
            self.wait_for_take()
            return self.capture_contour()
        finally:
            self.stop_overdub()
            self.overdub_path = None

    # -- three-frame morph ------------------------------------------------

    def capture_frame(self, points, index: int | None = None) -> str:
        """Turn the last seconds of the hand trajectory into one morph frame."""
        from ..wavetable import table_from_trajectory

        target = index if index is not None else self._next_frame_slot()
        if target is None:
            raise RuntimeError("all three frames are recorded; clear one or re-record it")
        table = table_from_trajectory(points)
        self.frames[target] = table
        self.table = table
        self.trajectory = list(points)
        self.message = "frame %s recorded from %d trajectory points" % ("ABC"[target], len(points))
        return self.message

    def _next_frame_slot(self) -> int | None:
        for index in range(3):
            if index not in self.frames:
                return index
        return None

    def upload_frames(self, shift: int, morph: bool, period_s: float, on_progress=None) -> str:
        """Upload only the frames that changed, then switch the morph on."""
        if not self.frames:
            raise RuntimeError("record at least one frame before uploading")
        if not self.can_write_table():
            raise RuntimeError("uploading needs IDLE; stop the loop first")
        result = self.session.upload_frames(
            self.frames,
            shift=shift,
            morph=morph,
            period_s=period_s,
            uploaded=self.uploaded_frames,
            on_progress=on_progress,
        )
        self.uploaded_frames = {table: list(frame) for table, frame in self.frames.items()}
        which = ", ".join("ABC"[table] for table in result.uploaded) or "none"
        self.message = "uploaded frames %s (shift %d, %.1f s), morph %s" % (
            which,
            shift,
            result.elapsed_s,
            "on" if morph else "off",
        )
        return self.message

    # -- LOOP recording (the state machine proven on the board) -------------

    def arm_take(self, track: int) -> str:
        """Force the bar, select the track and arm; the capture window opens at tick 0."""
        from ..session import record_flow

        self.flow = self.flow_factory(self.session, track)
        self.track = track
        self.flow.arm()
        self.phase.force_bar()
        self.record_track = track
        self.record_started = time.monotonic() + self.record_offset
        self.record_state = "waiting"
        self.message = "armed track %d: the window opens one bar from now" % track
        return self.message

    def wait_for_take(self, timeout_s: float = 12.0) -> str:
        """Block until the contour is full. Call from a worker thread, not the Tk loop.

        12 s, not 8: the board reports FULL about 7.9 s after the arm (measured on
        four takes in one session, spread 0.07 s), so an 8 s deadline raced the
        board and threw away good takes.
        """
        if getattr(self, "flow", None) is None:
            raise RuntimeError("nothing is armed")
        from ..session import record_flow

        deadline = time.monotonic() + timeout_s
        while self.flow.state == record_flow.ARMED:
            self.flow.poll()
            if self.flow.state == record_flow.ARMED:
                if time.monotonic() >= deadline:
                    raise RuntimeError("the capture never filled; is a hand over the sensor?")
                # 100 ms is ten looks per four-second bar: a 20 ms poll spends the
                # whole link on the question and starves the window.
                time.sleep(0.1)
        return "captured"

    def capture_contour(self) -> str:
        """Read the 32 contour points and gate them on coverage before anything is committed."""
        contour = self.flow.contour()
        verdict = self.flow.accept_take(contour)
        self.take_coverage = sum(1 for value in contour if value)
        if verdict != "ok":
            # A refused take used to be one small grey line, and the next take then
            # had no monitor because the contour was never stored.
            self.record_state = "failed"
            self.take_failed_at = time.monotonic()
            self.message = "take refused (%s): nothing was stored or committed" % verdict
            return self.message
        self.contours[self.track] = list(contour)
        self.live_contour = None
        self.record_state = "captured"
        self.hit = self.judge_take(contour)
        self.message = "track %d captured: %d/32 non-zero" % (
            self.track,
            sum(1 for value in contour if value),
        )
        if self.hit is not None:
            self.message += ", %s on the score" % self.hit.fraction()
        return self.message

    def commit_take(self) -> str:
        """Commit, then publish at once: the bank swap needs a bar boundary.

        The store only swaps on a loop boundary, and the scheduler only runs in
        PLAY -- so a commit left unpublushed parks every later loop command behind
        the RTL's 34 s boundary timeout. Publishing here closes that window.
        """
        if getattr(self, "flow", None) is None:
            raise RuntimeError("nothing is armed")
        count = self.flow.commit()
        self.commit_count = count
        self.flow.publish()
        self.phase.reanchor()
        self.message = "committed %d event(s) and published: it plays now" % count
        return self.message

    def publish_take(self) -> str:
        from ..session import record_flow

        if getattr(self, "flow", None) is None:
            return self.message
        if self.flow.state == record_flow.PUBLISHING:
            self.flow.publish()
        elif hasattr(self.session, "set_mode"):
            self.session.set_mode(4)          # committed and swapped already: just play
        self.phase.reanchor()
        self.message = "playing track %d" % self.track
        return self.message

    # -- score guide --------------------------------------------------------

    def load_score(self, path) -> str:
        """Read a score from disk; the LOOP page then draws it under the take."""
        from .. import score as score_mod

        self.score = score_mod.load(path)
        self.hit = None
        self.message = "score %s: %d track(s), %d ticks" % (
            self.score.name,
            len(self.score.tracks),
            self.score.ticks,
        )
        return self.message

    def score_targets(self):
        """The armed track's note per tick, or None when this track has no part."""
        if self.score is None:
            return None
        try:
            return self.score.targets(self.track)
        except KeyError:
            return None

    def judge_take(self, contour):
        """How many ticks landed in the note the score asked for; None without a score."""
        from .. import score as score_mod

        targets = self.score_targets()
        if targets is None:
            return None
        return score_mod.judge(contour, targets)

    def guide_tick(self):
        """The tick the bar is on, or None before a bar has been forced."""
        from .. import score as score_mod

        if not self.phase.anchored:
            return None
        return int(self.phase.u() * score_mod.TICKS) % score_mod.TICKS

    def record_progress(self) -> float:
        """How much of the capture window has gone by, 0..1."""
        if self.record_state != "armed":
            return 0.0
        elapsed = time.monotonic() - self.record_started
        return max(0.0, min(1.0, elapsed / self.record_seconds))

    def record_ticks(self) -> int:
        return int(round(self.record_progress() * 32))

    # -- parameters, modes and readouts ------------------------------------

    def set_param(self, addr: int, word: int) -> str:
        """Write one register and read it back; report a clamp instead of hiding it."""
        from ..params import PARAMS

        param = PARAMS.get(addr)
        if param is None:
            raise ValueError("0x%02X is not a parameter register" % addr)
        outside = word & ~param.mask
        if outside:
            raise ValueError(
                "0x%02X has bits outside its mask (0x%08X): the board would NACK it"
                % (addr, outside)
            )
        reply = self.session.write(addr, word)
        if reply.nack or reply.err:
            raise RuntimeError("0x%02X refused (err=0x%02X)" % (addr, reply.err))
        back = self.session.read(addr)
        if back == word:
            return "0x%02X = 0x%08X" % (addr, word)
        return "0x%02X wrote 0x%08X, board clamped to 0x%08X" % (addr, word, back)

    def read_params(self) -> dict:
        from ..params import PARAM_ADDRS

        words = {addr: self.session.read(addr) for addr in PARAM_ADDRS}
        self.params = dict(words)
        return words

    def write_field(self, addr: int, name: str, value: int) -> str:
        """Move one slider: keep every other field of that register as it is on the board."""
        from ..params import PARAMS, set_field

        # Read the register fresh: a stale copy rewrites the other fields, which is
        # how a cutoff slider ends up writing enable=0 and changing nothing audible.
        current = self.session.read(addr)
        word = set_field(addr, current, name, value)
        message = self.set_param(addr, word)
        self.params[addr] = self.session.read(addr)
        self.message = message
        return message

    def set_mode(self, mode: int) -> str:
        self.session.set_mode(mode)
        self._status = None
        self.message = "mode %s" % core.MODE_NAMES.get(mode, mode)
        return self.message

    def set_arp(self, on: bool) -> str:
        """THRESHOLDS[23]: 1 = step arpeggio, 0 = per-frame tracking."""
        word = self.session.read(0x30)
        word = (word | (1 << 23)) if on else (word & ~(1 << 23))
        low, high = word & 0xFFFF, (word >> 16) & 0xFFFF
        if low >= high:                       # the board refuses low >= high
            high = low + 1
            word = (high << 16) | low
        self.session.write(0x30, word)
        self.message = "rule: %s" % ("step pulse (one note per tick, pitch from Y)" if on else "per-frame tracking")
        return self.message

    def arp_on(self) -> bool:
        return bool((self.session.read(0x30) >> 23) & 1)

    def bpm(self) -> int:
        return self.session.read(0x08) & 0xFFFF

    def readouts(self) -> dict:
        """The numbers the storyboard puts on screen: note, gate, z, voices, steals."""
        snapshot = self.session.readouts()
        self._readouts = snapshot
        return snapshot

    def poll_board(self, slow: bool = False) -> dict:
        """Everything the window shows, gathered off the Tk thread.

        One attempt per command: a poll nobody waits on should cost 0.4 s on a dead
        link, not 1.2 s. The status is cached here too, so the paint loop never has
        to read it.
        """
        snapshot = {"readouts": None, "status": None, "bpm": None, "identity": None}
        try:
            self._readouts = self.session.readouts(attempts=1)
            self._readouts_at = time.monotonic()
            snapshot["readouts"] = self._readouts
        except Exception:
            self._readouts = None
            raise
        snapshot["status"] = self.session.status(attempts=1)
        self._status = snapshot["status"]
        self._status_at = time.monotonic()
        if slow:
            snapshot["bpm"] = self.bpm()
            snapshot["identity"] = self.identity_numbers()
        return snapshot

    def refresh_readouts(self) -> None:
        """Cache the readout block; the window redraws too often to poll it per frame.

        One attempt, not three: this is a poll nobody is waiting on, and a dead link
        should cost 0.4 s here and not 1.2 s.
        """
        try:
            self._readouts = self.session.readouts(attempts=1)
            self._readouts_at = time.monotonic()
        except Exception:
            self._readouts = None

    def last_readouts(self) -> dict | None:
        """The cached readout block, for a view that redraws faster than it may poll."""
        return self._readouts

    def identity_numbers(self) -> tuple:
        """(board id, table version) -- the view formats it, the model stays English."""
        board = getattr(self.session, "identity", None)
        board_id = board.board_id if board is not None else self.session.read(0xB0)
        return board_id, self.session.read(0x7C) & 0xFFFF

    def identity_text(self) -> str:
        board_id, version = self.identity_numbers()
        return "board 0x%08X  table v%d" % (board_id, version)

    # -- what to draw -------------------------------------------------------

    def drawing(self, tab: str):
        if tab == "live":
            return live_painter.paint_live(self.buffer)
        if tab == "wave":
            return wave_painter.paint_wave(self.table, diff=self.table_diff)
        if tab == "loop":
            return loop_painter.paint_loop(
                self.contours,
                live=self.live_contour,
                playhead_u=self.phase.u(),
                score=self.score,
                guide_track=self.track,
                tick=self.guide_tick(),
            )
        drawing = primitives.Drawing()
        drawing.add(primitives.Grid(4, 4, layer=primitives.STATIC))
        drawing.add(
            primitives.Text(0.5, 0.55, "preset: %s" % (self.preset_name or "none"), layer=primitives.STATIC)
        )
        drawing.add(
            primitives.Text(0.5, 0.45, "parameters are editable in every mode", layer=primitives.STATIC)
        )
        return drawing



class ConsoleWindow:
    """Tk shell. Wiring only: every decision lives in ConsoleModel or the painters.

    Layout rules learned the hard way:
    * the window has a fixed geometry and every panel that can grow (the tone
      sliders, the tab canvases) sits in a scrollable or expanding container --
      rows stacked with ``pack`` below an expanding notebook are simply invisible
      on a small screen, which is how the LOOP buttons and the wavetable controls
      went missing in the first hands-on run;
    * nothing is written in raw pixels. The display runs at 150 % and Tk is only
      DPI aware because ``ttkbootstrap.Window`` says so, so every size goes
      through :meth:`px`.
    """

    def __init__(self, model: ConsoleModel, port_name: str = "COM4", pump=None, presets=None):
        import tkinter as tk

        import ttkbootstrap as ttk

        from ..canvas import render_tk
        from ..ui import theme as theme_mod
        from ..ui import zh

        self.model = model
        self.pump = pump
        self.presets = presets or []
        self.tk = tk
        self.ttk = ttk
        self.zh = zh
        self.render = render_tk
        self._results: queue.Queue = queue.Queue()
        self._param_after = None
        self._pending_param = None
        self._syncing = False           # a ttk.Scale fires its command on set(), too
        self._pending_label = None
        self._capture_mark = None
        self._capture_until = 0.0
        self._current = TABS[0]

        self.dpi_awareness = theme_mod.enable_dpi_awareness()
        self.root = ttk.Window(title=zh.t("app.title", port_name), themename=theme_mod.THEME)
        self.px = lambda value: theme_mod.px(self.root, value)
        self.font_family = theme_mod.pick_family(self.root)
        self.palette = theme_mod.apply(self.root)
        theme_mod.apply_canvas(self.palette)

        width = self.px(1180)
        height = self.px(860)
        width = min(width, self.root.winfo_screenwidth() - self.px(60))
        height = min(height, self.root.winfo_screenheight() - self.px(110))
        self.root.geometry("%dx%d" % (width, height))
        self.root.minsize(self.px(900), self.px(600))

        self.status = self.ttk.Label(
            self.root, text=zh.t("status.none"), anchor="w", bootstyle="inverse-dark",
            padding=(self.px(12), self.px(4)),
        )
        self.status.pack(fill="x", side="bottom")

        self._build_mode_row()
        body = self.ttk.Frame(self.root, padding=(self.px(6), self.px(4)))
        body.pack(fill="both", expand=True)
        self._build_sidebar(body)
        self._build_notebook(body)

    # -- building blocks ----------------------------------------------------

    def _button(self, parent, text, command, side="top", bootstyle="secondary"):
        button = self.ttk.Button(parent, text=text, command=command, bootstyle=bootstyle)
        button.pack(
            side=side,
            fill="x" if side == "top" else "none",
            padx=self.px(3),
            pady=self.px(2),
        )
        return button

    def _hint(self, parent, key: str) -> None:
        self.ttk.Label(
            parent, text=self.zh.t(key), bootstyle="secondary",
            wraplength=self.px(820), justify="left",
        ).pack(anchor="w", pady=(self.px(2), self.px(4)))

    def _canvas(self, parent):
        canvas = self.tk.Canvas(
            parent,
            bg=self.palette.canvas,
            highlightthickness=self.px(1),
            highlightbackground=self.palette.panel,
            bd=0,
        )
        canvas.pack(fill="both", expand=True, pady=(self.px(4), 0))
        return canvas

    def _build_sidebar(self, body) -> None:
        zh = self.zh
        sidebar = self.ttk.Frame(body, padding=(self.px(4), self.px(4)))
        sidebar.pack(side="left", fill="y")
        self.ttk.Label(sidebar, text=zh.t("side.presets"), bootstyle="warning").pack(
            anchor="w", pady=(0, self.px(4))
        )
        self.preset_list = self.tk.Listbox(
            sidebar,
            height=10,
            width=20,
            exportselection=False,
            activestyle="none",
            bg=self.palette.panel,
            fg=self.palette.fg,
            selectbackground=self.palette.accent,
            selectforeground="#1a1c1f",
            highlightthickness=0,
            borderwidth=0,
            font=(self.font_family, 10),
        )
        for preset in self.presets:
            self.preset_list.insert("end", preset.name)
        if self.presets:
            self.preset_list.selection_set(0)
        else:
            self.preset_list.insert("end", zh.t("side.empty"))
            self.preset_list.itemconfigure(0, foreground=self.palette.dim)
        self.preset_list.pack(fill="x", pady=(0, self.px(8)))
        self._button(sidebar, zh.t("side.apply"), self._on_apply, bootstyle="warning")
        self._button(sidebar, zh.t("side.capture"), self._on_capture)
        self._button(sidebar, zh.t("side.readback"), self._on_readback, bootstyle="secondary-outline")
        self.preset_label = self.ttk.Label(
            sidebar, text="", bootstyle="secondary", wraplength=self.px(180), justify="left"
        )
        self.preset_label.pack(fill="x", pady=self.px(8))

    def _build_notebook(self, body) -> None:
        main = self.ttk.Frame(body)
        main.pack(side="left", fill="both", expand=True, padx=(self.px(8), 0))
        self.notebook = self.ttk.Notebook(main)
        self.notebook.pack(fill="both", expand=True)
        self.canvases = {}
        for name in TABS:
            frame = self.ttk.Frame(self.notebook, padding=self.px(6))
            if name == "tone":
                self._build_tone_panel(frame)
                self.canvases[name] = None
            elif name == "loop":
                self._build_loop_controls(frame)
                self.canvases[name] = self._canvas(frame)
            elif name == "wave":
                self._build_wave_controls(frame)
                self.canvases[name] = self._canvas(frame)
            else:
                self._hint(frame, "hint.live")
                self.canvases[name] = self._canvas(frame)
            self.notebook.add(frame, text=self.zh.t("tab." + name))
        self.notebook.bind("<<NotebookTabChanged>>", self._on_tab)

    def _build_mode_row(self) -> None:
        zh = self.zh
        row = self.ttk.Frame(self.root, padding=(self.px(4), self.px(3)))
        row.pack(fill="x", side="bottom")
        self._button(row, zh.t("mode.stop"), self._on_stop, side="left", bootstyle="danger-outline")
        self._button(row, zh.t("mode.live"), lambda: self._on_mode(1), side="left", bootstyle="warning")
        self._button(row, zh.t("mode.play"), lambda: self._on_mode(4), side="left", bootstyle="primary")
        self._button(row, zh.t("mode.wt"), lambda: self._on_mode(6), side="left", bootstyle="primary-outline")
        self.arp_var = self.tk.BooleanVar(value=False)
        self.arp = self.ttk.Checkbutton(
            row, text=zh.t("mode.arp"), variable=self.arp_var, command=self._on_arp, bootstyle="warning"
        )
        self.arp.pack(side="left", padx=self.px(10))
        self.bpm_label = self.ttk.Label(row, text="", bootstyle="secondary")
        self.bpm_label.pack(side="left", padx=self.px(6))
        self._button(
            row, zh.t("mode.read_params"), self._on_read_params, side="left", bootstyle="secondary-outline"
        )
        self.identity_label = self.ttk.Label(row, text="", bootstyle="secondary")
        self.identity_label.pack(side="left", padx=self.px(8))
        self._button(row, zh.t("mode.ref_play"), self._on_reference, side="left")
        self._button(
            row, zh.t("mode.ref_stop"), self._on_reference_stop, side="left", bootstyle="secondary-outline"
        )

    def _build_tone_panel(self, parent) -> None:
        """One control per field, grouped per register, inside a scrollable canvas.

        Flags are checkbuttons: a slider from 0 to 1 is a knob with two positions.
        Everything else is a ttk.Scale; the number beside it is refreshed from the
        board's own read-back, so a clamp is visible instead of guessed.
        """
        from ..params import PARAMS

        zh = self.zh
        outer = self.ttk.Frame(parent)
        outer.pack(fill="both", expand=True)
        canvas = self.tk.Canvas(outer, bg=self.palette.bg, highlightthickness=0, bd=0)
        bar = self.ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=bar.set)
        bar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        inner = self.ttk.Frame(canvas, padding=self.px(10))
        window = canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda _e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda event: canvas.itemconfigure(window, width=event.width))

        def wheel(event):
            canvas.yview_scroll(int(-event.delta / 120), "units")

        canvas.bind("<Enter>", lambda _e: canvas.bind_all("<MouseWheel>", wheel))
        canvas.bind("<Leave>", lambda _e: canvas.unbind_all("<MouseWheel>"))

        self.param_controls = {}
        self._syncing = True
        for addr in sorted(PARAMS):
            param = PARAMS[addr]
            group = self.ttk.Labelframe(
                inner,
                text="0x%02X   %s   %s" % (addr, zh.param_name(addr), zh.scope_name(param.scope)),
                bootstyle="secondary",
                padding=self.px(8),
            )
            group.pack(fill="x", pady=self.px(6))
            for field in param.fields:
                row = self.ttk.Frame(group)
                row.pack(fill="x", pady=self.px(3))
                self.ttk.Label(
                    row, text=zh.field_name(addr, field.name), width=8, anchor="w", bootstyle="secondary"
                ).pack(side="left")
                if field.width == 1:
                    var = self.tk.BooleanVar(value=False)
                    toggle = self.ttk.Checkbutton(
                        row,
                        variable=var,
                        bootstyle="warning",
                        command=lambda a=addr, n=field.name, v=var: self._on_toggle(a, n, v),
                    )
                    toggle.pack(side="left", padx=self.px(8))
                    self.param_controls[(addr, field.name)] = ("flag", var, toggle, None)
                else:
                    scale = self.ttk.Scale(
                        row, from_=field.lo, to=field.hi, orient="horizontal",
                        length=self.px(300), bootstyle="warning",
                    )
                    scale.set(field.lo)
                    scale.configure(
                        command=lambda value, a=addr, n=field.name: self._on_param_drag(a, n, value)
                    )
                    scale.pack(side="left", padx=self.px(8))
                    value_label = self.ttk.Label(row, text="—", width=26, anchor="w", bootstyle="secondary")
                    value_label.pack(side="left")
                    self.param_controls[(addr, field.name)] = ("scale", scale, None, value_label)
            if param.danger:
                self.ttk.Label(group, text="⚠ " + zh.danger_name(addr), bootstyle="danger").pack(anchor="w")
        self._syncing = False

    def _build_loop_controls(self, parent) -> None:
        zh = self.zh
        self._hint(parent, "hint.loop")
        strip = self.ttk.Frame(parent)
        strip.pack(fill="x", pady=(0, self.px(4)))
        self.ttk.Label(strip, text=zh.t("loop.track"), bootstyle="secondary").pack(side="left")
        self.track_box = self.ttk.Spinbox(strip, from_=0, to=5, width=3, bootstyle="secondary")
        self.track_box.set(0)
        self.track_box.pack(side="left", padx=self.px(6))
        self._button(strip, zh.t("loop.arm"), self._on_arm, side="left", bootstyle="warning")
        self._button(strip, zh.t("loop.commit"), self._on_commit, side="left", bootstyle="warning")
        # 发布 used to be a second commit-shaped button. Committing now publishes, so
        # all that is left for this one is "go back to PLAY" -- say so.
        self._button(strip, zh.t("loop.publish"), self._on_publish, side="left", bootstyle="primary-outline")
        self.overdub_var = self.tk.BooleanVar(value=True)
        self.overdub_box = self.ttk.Checkbutton(
            strip, text=zh.t("loop.overdub"), variable=self.overdub_var, bootstyle="warning"
        )
        self.overdub_box.pack(side="left", padx=self.px(8))
        self.loop_label = self.tk.Label(
            strip, text=zh.t("loop.hint"), bg=self.palette.bg, fg=self.palette.dim,
            font=(self.font_family, 11),
        )
        self.loop_label.pack(side="left", padx=self.px(10))

        guide = self.ttk.Frame(parent)
        guide.pack(fill="x", pady=(0, self.px(4)))
        from .. import score as score_mod

        self.ttk.Label(guide, text=zh.t("score.label"), bootstyle="warning").pack(side="left")
        self.score_box = self.ttk.Combobox(
            guide,
            values=[path.stem for path in score_mod.available()],
            state="readonly",
            width=20,
            bootstyle="secondary",
        )
        self.score_box.pack(side="left", padx=self.px(6))
        self.score_box.bind("<<ComboboxSelected>>", self._on_score)
        self.hit_label = self.ttk.Label(guide, text="", bootstyle="warning")
        self.hit_label.pack(side="left", padx=self.px(10))

    def _build_wave_controls(self, parent) -> None:
        zh = self.zh
        self._hint(parent, "hint.wave")
        strip = self.ttk.Frame(parent)
        strip.pack(fill="x", pady=(0, self.px(4)))
        self._button(strip, zh.t("wave.capture"), self._on_capture_frame, side="left", bootstyle="warning")
        self.ttk.Label(strip, text=zh.t("wave.gain"), bootstyle="secondary").pack(
            side="left", padx=(self.px(12), self.px(4))
        )
        self.gain = self.ttk.Scale(
            strip, from_=0, to=15, orient="horizontal", length=self.px(150), bootstyle="warning"
        )
        self.gain.set(2)
        self.gain.pack(side="left")
        self.gain_label = self.ttk.Label(strip, text="2", width=3, bootstyle="secondary")
        self.gain_label.pack(side="left", padx=(self.px(4), 0))
        self.gain.configure(
            command=lambda value: self.gain_label.config(text="%d" % int(float(value)))
        )
        self.ttk.Label(strip, text=zh.t("wave.period"), bootstyle="secondary").pack(
            side="left", padx=(self.px(12), self.px(4))
        )
        self.period = self.ttk.Entry(strip, width=6, bootstyle="secondary")
        self.period.insert(0, "20")
        self.period.pack(side="left")
        self._button(strip, zh.t("wave.upload"), self._on_upload_frames, side="left", bootstyle="primary")
        self._button(strip, zh.t("wave.bin"), self._on_upload, side="left", bootstyle="secondary-outline")
        self.progress = self.ttk.Progressbar(
            strip, maximum=1024, length=self.px(170), bootstyle="warning"
        )
        self.progress.pack(side="left", padx=self.px(8))
        self.progress_label = self.ttk.Label(strip, text="", bootstyle="secondary")
        self.progress_label.pack(side="left")

    # -- actions ------------------------------------------------------------

    def _run(self, label, fn) -> None:
        """Every board call runs off the Tk thread; one failed command can cost 800 ms."""

        def worker():
            self.model.begin_io()
            try:
                self._results.put((label, fn(), None))
            except Exception as exc:  # surfaced in the status bar, never swallowed
                self._results.put((label, None, exc))
            finally:
                self.model.end_io()

        threading.Thread(target=worker, daemon=True).start()

    def _selected_preset(self):
        if not self.presets:
            return None
        selection = self.preset_list.curselection()
        return self.presets[selection[0]] if selection else None

    def _on_apply(self):
        preset = self._selected_preset()
        if preset is not None:
            self.preset_label.config(text="%s: %s" % (self.zh.t("side.apply"), preset.name))
            self._run("apply", lambda: self.model.apply_preset(preset))

    def _on_capture(self):
        self._run("capture", lambda: self.model.capture_preset("captured-%d" % int(time.time())))

    def _on_stop(self):
        self.model.record_state = "idle"
        self._run("stop", self.model.stop)

    def _on_readback(self):
        self._run("readback", self.model.readback)

    def _on_upload(self):
        from tkinter import filedialog

        path = filedialog.askopenfilename(filetypes=[("wavetable", "*.bin")])
        if not path:
            return

        def action():
            with open(path, "rb") as handle:
                raw = handle.read()
            samples = [
                int.from_bytes(raw[index : index + 2], "little", signed=True)
                for index in range(0, len(raw) - 1, 2)
            ]
            return self.model.upload(samples)

        self._run("upload", action)

    def _on_capture_frame(self):
        self._capture_mark = self.model.buffer.mark()
        self._capture_until = time.monotonic() + 4.0
        self.model.message = "capturing 4 s: move your hand over the sensor"
        self.root.after(4000, self._finish_capture)

    def _finish_capture(self):
        frames = self.model.buffer.since(self._capture_mark)
        self._capture_mark = None
        points = [(frame.x, frame.y) for frame in frames]
        if len(points) < 32:
            self.model.message = (
                "capture got %d samples in 4 s; the board only streams telemetry while "
                "a hand is in the field" % len(points)
            )
            self.loop_label.config(text=self.model.message, fg=self.palette.danger)
            return
        self._run("capture-frame", lambda: self.model.capture_frame(points))

    def _on_upload_frames(self):
        shift = int(float(self.gain.get()))
        try:
            period = float(self.period.get() or 20.0)
        except ValueError:
            self.model.message = "LFO period must be a number of seconds"
            return

        def action():
            return self.model.upload_frames(
                shift, True, period,
                on_progress=lambda table, done, total: self._results.put(
                    ("progress", (table, done, total), None)
                ),
            )

        self._run("upload-frames", action)

    def _on_toggle(self, addr: int, name: str, var) -> None:
        self._run("param", lambda: self.model.write_field(addr, name, 1 if var.get() else 0))

    def _on_param_drag(self, addr: int, name: str, value: str) -> None:
        if self._syncing:
            return                      # ttk.Scale.set() also calls the command
        self._pending_param = (addr, name, int(float(value)))
        if self._param_after is not None:
            self.root.after_cancel(self._param_after)
        self._param_after = self.root.after(250, self._flush_param)

    def _flush_param(self) -> None:
        self._param_after = None
        if self._pending_param is None:
            return
        addr, name, value = self._pending_param
        self._pending_param = None
        self._run("param", lambda: self.model.write_field(addr, name, value))

    def _on_read_params(self):
        def action():
            words = self.model.read_params()
            self._results.put(("params", (words, self.model.arp_on()), None))
            return "read %d registers" % len(words)

        self._run("read-params", action)

    def _sync_sliders(self, words: dict) -> None:
        from ..params import get_field

        self._syncing = True
        try:
            for (addr, name), (kind, widget, _toggle, _label) in getattr(self, "param_controls", {}).items():
                word = words.get(addr)
                if word is None:
                    continue
                value = get_field(addr, name, word)
                if kind == "flag":
                    if bool(widget.get()) != bool(value):
                        widget.set(bool(value))
                elif int(float(widget.get())) != value:
                    widget.set(value)
        finally:
            self._syncing = False

    def _refresh_value_labels(self) -> None:
        """The numbers beside the sliders, from the board's own last read-back."""
        from ..params import display, get_field

        words = self.model.params
        if not words:
            return
        for (addr, name), (kind, _widget, _toggle, label) in getattr(self, "param_controls", {}).items():
            if label is None:
                continue
            word = words.get(addr)
            if word is None:
                continue
            value = get_field(addr, name, word)
            shown = self.zh.localize(display(addr, name, word))
            # The raw number only helps when the display converted it (kHz, ms, dB).
            text = shown if str(value) in shown else "%d   %s" % (value, shown)
            if label.cget("text") != text:
                label.config(text=text)

    def _on_mode(self, mode: int):
        self._run("mode", lambda: self.model.set_mode(mode))

    def _on_arp(self):
        wanted = bool(self.arp_var.get())
        self._run("rule", lambda: self.model.set_arp(wanted))

    def _on_score(self, _event=None) -> None:
        from .. import score as score_mod

        name = self.score_box.get()
        if not name:
            return
        path = score_mod.SCORE_DIR / (name + ".json")
        self._run("score", lambda: self.model.load_score(path))

    def _on_arm(self):
        track = int(float(self.track_box.get()))
        self._countdown(3, track)

    @staticmethod
    def _beep(frequency: int, milliseconds: int = 70) -> None:
        """A short tone off the UI thread: Beep blocks for its duration."""
        def tone():
            try:
                import winsound

                winsound.Beep(frequency, milliseconds)
            except Exception:
                pass

        threading.Thread(target=tone, daemon=True).start()

    def _countdown(self, remaining: int, track: int) -> None:
        if remaining > 0:
            self.model.record_state = "countdown"
            self.model.record_track = track
            self._beep(660, 60)
            self.loop_label.config(
                text=self.zh.t("loop.countdown", track, remaining), fg=self.palette.accent
            )
            if remaining == 3 and self.overdub_var.get() and self.model.contours:
                # Render the mix now: on the downbeat there is only time to play it.
                self._run("prepare", self.model.prepare_overdub)
            self.root.after(1000, lambda: self._countdown(remaining - 1, track))
            return

        monitor = bool(self.overdub_var.get())

        def action():
            return self.model.armed_take(track, overdub=monitor)

        self._beep(990, 120)
        self.loop_label.config(text=self.zh.t("loop.armed", track), fg=self.palette.danger)
        self._run("arm", action)

    def _on_commit(self):
        self.model.record_state = "idle"
        self._set_pending(self.zh.t("loop.committing"))
        self._run("commit", self.model.commit_take)

    def _on_publish(self):
        self.model.record_state = "idle"
        self._set_pending(self.zh.t("loop.publishing"))
        self._run("publish", self.model.publish_take)

    def _on_reference(self):
        if not self.model.contours:
            self.model.message = "record a take before playing a reference"
            return
        segments = reference.mix_contours(self.model.contours)
        table = self.model.table or reference.sine_table()
        env = self.model.default_env()
        self._run("reference", lambda: self.model.play_reference(segments, table, 2, env))

    def _on_reference_stop(self):
        self._run("reference-stop", self.model.stop_reference)

    # -- loop ---------------------------------------------------------------

    def _on_tab(self, _event=None) -> None:
        index = self.notebook.index(self.notebook.select())
        self._current = TABS[index]

    def _drain_results(self) -> None:
        while True:
            try:
                label, value, error = self._results.get_nowait()
            except queue.Empty:
                return
            self._pending_label = None
            if label == "progress":
                table, done, total = value
                self.progress.configure(maximum=total, value=done)
                self.progress_label.config(text=self.zh.t("wave.progress", "ABC"[table], done, total))
                continue
            if label == "params":
                words, arp = value
                self._sync_sliders(words)
                if bool(self.arp_var.get()) != bool(arp):
                    self.arp_var.set(bool(arp))
                continue
            if label == "arm" and error is not None:
                self.model.record_state = "failed"
                self.model.take_failed_at = time.monotonic()
                self._beep(330, 300)
            if label == "arm" and error is None:
                self._beep(1320, 140) if self.model.record_state == "captured" else self._beep(330, 300)
            if label == "poll":
                if error is not None:
                    self.identity_label.config(text="link: %s" % error)
                else:
                    self._apply_poll(value)
                continue
            if error is not None:
                self.model.message = "%s: %s" % (label, error)
            elif value:
                self.model.message = str(value)
            self.preset_label.config(text=self.model.message)

    def _status_text(self) -> str:
        zh = self.zh
        # While a worker owns the link this must not block: a stale line beats a freeze.
        status = self.model.cached_status(10.0 if self.model.io_busy() else 2.0)
        if self.model.record_state in ("waiting", "armed"):
            # The poll is paused during a take, and the board is in RECORD now, so
            # the cached mode is stale by design. Say what is actually happening.
            parts = [zh.t("status.mode_recording")]
            parts.append(zh.t("status.monitor_playing") if self.model.overdubbing
                         else zh.t("status.monitor_off"))
            if status is not None and status.fault:
                parts.append(zh.t("status.fault"))
            if self.model.buffer.waiting():
                parts.append(zh.t("status.waiting"))
            else:
                parts.append(zh.t("status.frames", len(self.model.buffer.trail(10 ** 6))))
            readouts = self.model.last_readouts()
            if readouts:
                parts.append(zh.t("status.note", readouts.get("note", 0)))
                parts.append(zh.t("status.z", readouts.get("z", 0)))
            if self.model.message:
                parts.append(self.model.message)
            return "    ".join(parts)
        if status is None:
            return zh.t("status.none")
        parts = [zh.t("status.mode", zh.mode_name(status.mode))]
        if status.loop_active:
            parts.append(zh.t("status.loop"))
        if status.fault:
            parts.append(zh.t("status.fault"))
        if self.model.buffer.waiting():
            parts.append(zh.t("status.waiting"))
        else:
            parts.append(zh.t("status.frames", len(self.model.buffer.trail(10 ** 6))))
        readouts = self.model.last_readouts()
        if readouts:
            parts.append(zh.t("status.voices", readouts.get("voices", 0)))
            parts.append(zh.t("status.steals", readouts.get("steals", 0)))
            parts.append(zh.t("status.note", readouts.get("note", 0)))
            parts.append(zh.t("status.z", readouts.get("z", 0)))
        if self.model.message:
            parts.append(self.model.message)
        return "    ".join(parts)

    def _apply_poll(self, snapshot: dict) -> None:
        status = snapshot.get("status")
        if status is not None:
            if status.mode == 1:
                # LIVE derives tempo from cursor X (bpm_auto_q) and no register
                # exposes it, so bpm_reg here would be a lie.
                self.bpm_label.config(text=self.zh.t("mode.bpm_live"))
            elif snapshot.get("bpm") is not None:
                self.bpm_label.config(text=self.zh.t("mode.bpm", snapshot["bpm"]))
        if snapshot.get("identity"):
            self.identity_label.config(text=self.zh.t("mode.identity", *snapshot["identity"]))

    def _paint_record(self, canvas) -> None:
        """A red bar and a big caption: a take must be visible, not inferred."""
        state = self.model.record_state
        width = canvas.winfo_width()
        if state == "failed" and time.monotonic() - self.model.take_failed_at < 3.0:
            canvas.create_text(
                width / 2, self.px(30),
                text=self.zh.t("loop.rec_failed", self.model.take_coverage),
                fill=self.palette.danger, font=(self.font_family, 13, "bold"),
            )
            return
        if state not in ("countdown", "waiting", "armed"):
            return
        if state == "countdown":
            colour = self.palette.accent
            text = self.zh.t("loop.rec_countdown", self.model.record_track)
        elif state == "waiting":
            colour = self.palette.accent
            text = self.zh.t("loop.rec_waiting", self.model.record_track)
        else:
            colour = self.palette.danger
            progress = self.model.record_progress()
            left = max(0.0, self.model.record_seconds * (1.0 - progress))
            text = self.zh.t(
                "loop.recording", self.model.record_track, self.model.record_ticks(), left
            )
            canvas.create_rectangle(0, 0, width * progress, self.px(8), fill=colour, outline="")
        canvas.create_text(
            width / 2, self.px(30), text=text, fill=colour,
            font=(self.font_family, 13, "bold"),
        )

    def _update_record_label(self) -> None:
        state = self.model.record_state
        if getattr(self, "_pending_label", None):
            # A worker is running: say so, and stop saying it when it answers.
            if self.loop_label.cget("text") != self._pending_label:
                self.loop_label.config(text=self._pending_label, fg=self.palette.dim)
            return
        if state == "waiting":
            self.loop_label.config(
                text=self.zh.t("loop.label_waiting", self.model.record_track),
                fg=self.palette.accent,
            )
        elif state == "armed":
            self.loop_label.config(
                text=self.zh.t("loop.label_recording", self.model.record_track, self.model.record_ticks()),
                fg=self.palette.danger,
            )
        elif state == "captured":
            self.loop_label.config(
                text=self.zh.t("loop.label_done", self.model.record_track), fg=self.palette.accent
            )
        elif state == "failed":
            self.loop_label.config(text=self.zh.t("loop.label_failed"), fg=self.palette.danger)
        else:
            text = self.model.message or self.zh.t("loop.hint")
            if self.loop_label.cget("text") != text:
                self.loop_label.config(text=text, fg=self.palette.dim)

    def _set_pending(self, text: str) -> None:
        """Show a verb until the worker answers; a stuck label is worse than none."""
        self._pending_label = text
        self.loop_label.config(text=text, fg=self.palette.dim)

    def _paint_capture(self, canvas) -> None:
        """Frame count while a wavetable capture runs: zero means no stream, now."""
        if self._capture_mark is None:
            return
        frames = self.model.buffer.since(self._capture_mark)
        left = max(0.0, self._capture_until - time.monotonic())
        canvas.create_text(
            canvas.winfo_width() / 2, self.px(30),
            text=self.zh.t("wave.capturing", len(frames), left),
            fill=self.palette.accent, font=(self.font_family, 13, "bold"),
        )

    def _empty_hint(self, tab: str):
        """A blank canvas looks broken; say what would fill it instead."""
        if tab == "live":
            return self.zh.t("empty.live") if self.model.buffer.waiting() else None
        if tab == "loop":
            return None if self.model.contours else self.zh.t("empty.loop")
        if tab == "wave":
            return None if self.model.table else self.zh.t("empty.wave")
        return None

    def refresh(self) -> None:
        if self.pump is not None:
            try:
                self.pump()
            except Exception as exc:  # a dead link must not kill the window
                self.model.message = "link: %s" % exc
        self._drain_results()
        now = time.monotonic()
        if not self.model.io_busy() and self.pump is not None and now - getattr(self, "_readout_at", 0.0) > 1.0:
            self._readout_at = now
            slow = now - getattr(self, "_slow_at", 0.0) > 3.0
            if slow:
                self._slow_at = now
            self._run("poll", lambda wanted=slow: self.model.poll_board(wanted))
        self._refresh_value_labels()
        hit = self.model.hit
        if hit is None:
            if self.hit_label.cget("text"):
                self.hit_label.config(text="")
        else:
            text = self.zh.t("score.hit", hit.fraction())
            if hit.wrong:
                text += "    " + self.zh.t("score.wrong", " ".join(str(tick) for tick in hit.wrong[:10]))
            if self.hit_label.cget("text") != text:
                self.hit_label.config(text=text)
        canvas = self.canvases.get(self._current)
        try:
            if canvas is not None:
                self.render.draw(canvas, self.model.drawing(self._current))
                hint = self._empty_hint(self._current)
                if hint:
                    canvas.create_text(
                        canvas.winfo_width() / 2,
                        canvas.winfo_height() / 2,
                        text=hint,
                        fill=self.palette.dim,
                        font=(self.font_family, 12),
                        justify="center",
                    )
                self._paint_record(canvas)
                self._paint_capture(canvas)
            self._update_record_label()
            self.status.config(text=self._status_text())
        except Exception as exc:  # a render error must not kill the loop
            self.status.config(text="draw error: %s" % exc)
        self.root.after(33, self.refresh)

    def run(self) -> int:
        self.refresh()
        self.root.after(200, self._on_read_params)
        self.root.mainloop()
        return 0
