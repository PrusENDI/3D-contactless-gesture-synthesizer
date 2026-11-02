"""The window: one model behind four tabs, and the Tk code that draws it.

The model is pure -- it holds the session, the telemetry buffer, the table and the
contours, and answers "what does this tab draw" and "what does this button do".
Only :class:`ConsoleWindow` and ``canvas/render_tk.py`` import tkinter, and every
action that talks to the board runs on a worker thread, because one command costs
17 ms and a failed one can cost 800 ms.
"""

from __future__ import annotations

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
        self.flow = None
        self.flow_factory = None
        self.track = 0
        self.commit_count = 0
        self._readouts = None
        self._readouts_at = 0.0
        self.params: dict = {}
        from ..session import record_flow as _record_flow

        self.flow_factory = _record_flow.RecordFlow

    # -- state --------------------------------------------------------------

    def status(self):
        return self.session.status() if self.session is not None else None

    def cached_status(self, max_age_s: float = 0.5):
        """The window redraws at 30 Hz; a STATUS command per frame would be 17 ms each."""
        now = time.monotonic()
        if self._status is None or (now - self._status_at) > max_age_s:
            self._status = self.status()
            self._status_at = now
        return self._status

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

    def play_reference(self, segments, table, voice_shift, env, path="reference.wav") -> str:
        if not table:
            raise RuntimeError("no wavetable loaded: upload one before playing a reference")
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
        self.message = "armed track %d: the window opens at the next bar" % track
        return self.message

    def wait_for_take(self, timeout_s: float = 8.0) -> str:
        """Block until the contour is full. Call from a worker thread, not the Tk loop."""
        if getattr(self, "flow", None) is None:
            raise RuntimeError("nothing is armed")
        from ..session import record_flow

        deadline = time.monotonic() + timeout_s
        while self.flow.state == record_flow.ARMED:
            self.flow.poll()
            if self.flow.state == record_flow.ARMED:
                if time.monotonic() >= deadline:
                    raise RuntimeError("the capture never filled; is a hand over the sensor?")
                time.sleep(0.02)
        return "captured"

    def capture_contour(self) -> str:
        """Read the 32 contour points and gate them on coverage before anything is committed."""
        contour = self.flow.contour()
        verdict = self.flow.accept_take(contour)
        if verdict != "ok":
            self.message = "take refused (%s): nothing was stored or committed" % verdict
            return self.message
        self.contours[self.track] = list(contour)
        self.live_contour = None
        self.message = "track %d captured: %d/32 non-zero" % (
            self.track,
            sum(1 for value in contour if value),
        )
        return self.message

    def commit_take(self) -> str:
        if getattr(self, "flow", None) is None:
            raise RuntimeError("nothing is armed")
        count = self.flow.commit()
        self.commit_count = count
        self.message = "committed %d event(s); press Publish to hear it" % count
        return self.message

    def publish_take(self) -> str:
        if getattr(self, "flow", None) is None:
            raise RuntimeError("nothing is armed")
        self.flow.publish()
        self.phase.reanchor()
        self.message = "published track %d: mode is PLAY now" % self.track
        return self.message

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

    def refresh_readouts(self) -> None:
        """Cache the readout block; the window redraws too often to poll it per frame."""
        try:
            self._readouts = self.session.readouts()
            self._readouts_at = time.monotonic()
        except Exception:
            self._readouts = None

    def identity_text(self) -> str:
        board = getattr(self.session, "identity", None)
        board_id = board.board_id if board is not None else self.session.read(0xB0)
        version = self.session.read(0x7C) & 0xFFFF
        return "board 0x%08X  table v%d" % (board_id, version)

    # -- what to draw -------------------------------------------------------

    def drawing(self, tab: str):
        if tab == "live":
            return live_painter.paint_live(self.buffer)
        if tab == "wave":
            return wave_painter.paint_wave(self.table, diff=self.table_diff)
        if tab == "loop":
            return loop_painter.paint_loop(
                self.contours, live=self.live_contour, playhead_u=self.phase.u()
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



def ttk_like_progress(tk, parent):
    from tkinter import ttk

    bar = ttk.Progressbar(parent, length=160, maximum=1024)
    bar.pack(side="left", padx=8)
    return bar



class ConsoleWindow:
    """Tk shell. Wiring only: every decision lives in ConsoleModel or the painters.

    Layout rule learned the hard way: the window has a fixed geometry and every
    panel that can grow (the tone sliders, the tab canvases) sits in a scrollable
    or expanding container. Rows stacked with ``pack`` below an expanding notebook
    are simply invisible on a small screen, which is how the LOOP buttons and the
    wavetable controls went missing in the first hands-on run.
    """

    def __init__(self, model: ConsoleModel, port_name: str = "COM4", pump=None, presets=None):
        import tkinter as tk
        from tkinter import ttk

        from ..canvas import render_tk

        self.model = model
        self.pump = pump
        self.presets = presets or []
        self.tk = tk
        self.render = render_tk
        self.root = tk.Tk()
        self.root.title("MGC3130 console - %s" % port_name)
        self.root.configure(bg="#101014")
        self.root.geometry("1180x880")
        self.root.minsize(900, 640)
        self._results: queue.Queue = queue.Queue()
        self._param_after = None
        self._pending_param = None

        self.status = tk.Label(self.root, anchor="w", fg="#cccccc", bg="#101014", text="not connected")
        self.status.pack(fill="x")

        body = tk.Frame(self.root, bg="#101014")
        body.pack(fill="both", expand=True)

        sidebar = tk.Frame(body, bg="#101014", width=190)
        sidebar.pack(side="left", fill="y")
        tk.Label(sidebar, text="presets", fg="#888888", bg="#101014").pack(anchor="w")
        self.preset_list = tk.Listbox(sidebar, height=10, exportselection=False)
        for preset in self.presets:
            self.preset_list.insert("end", preset.name)
        if self.presets:
            self.preset_list.selection_set(0)
        self.preset_list.pack(fill="x")
        self._button(sidebar, "Apply preset", self._on_apply)
        self._button(sidebar, "Capture preset", self._on_capture)
        self._button(sidebar, "Read back table", self._on_readback)
        self.preset_label = tk.Label(sidebar, text="", fg="#888888", bg="#101014", wraplength=180, justify="left")
        self.preset_label.pack(fill="x", pady=4)

        main = tk.Frame(body, bg="#101014")
        main.pack(side="left", fill="both", expand=True)
        self.notebook = ttk.Notebook(main)
        self.notebook.pack(fill="both", expand=True)
        self.canvases = {}
        for name in TABS:
            frame = tk.Frame(self.notebook, bg="#101014")
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
                self.canvases[name] = self._canvas(frame)
            self.notebook.add(frame, text=name)
        self._current = TABS[0]
        self.notebook.bind("<<NotebookTabChanged>>", self._on_tab)

        mode_row = tk.Frame(self.root, bg="#101014")
        mode_row.pack(fill="x", side="bottom")
        self._button(mode_row, "STOP", self._on_stop, side="left")
        self._button(mode_row, "LIVE", lambda: self._on_mode(1), side="left")
        self._button(mode_row, "PLAY", lambda: self._on_mode(4), side="left")
        self._button(mode_row, "WT_PLAY", lambda: self._on_mode(6), side="left")
        self.arp = tk.Checkbutton(
            mode_row, text="step pulse (Y per tick)", command=self._on_arp,
            bg="#101014", fg="#cccccc", selectcolor="#202024", activebackground="#101014",
        )
        self.arp.pack(side="left", padx=8)
        self.bpm_label = tk.Label(mode_row, text="BPM -", fg="#888888", bg="#101014")
        self.bpm_label.pack(side="left", padx=8)
        self._button(mode_row, "Read params", self._on_read_params, side="left")
        self.identity_label = tk.Label(mode_row, text="", fg="#888888", bg="#101014")
        self.identity_label.pack(side="left", padx=8)
        self._button(mode_row, "Reference play", self._on_reference, side="left")
        self._button(mode_row, "Reference stop", self._on_reference_stop, side="left")

    # -- building blocks ----------------------------------------------------

    def _button(self, parent, label, command, side="top"):
        button = self.tk.Button(parent, text=label, command=command)
        button.pack(side=side, fill="x" if side == "top" else "none", padx=2, pady=1)
        return button

    def _canvas(self, parent):
        canvas = self.tk.Canvas(parent, bg="#101014", highlightthickness=0)
        canvas.pack(fill="both", expand=True)
        return canvas

    def _build_tone_panel(self, parent) -> None:
        """One slider per field, inside a scrollable canvas so nothing hides below the fold."""
        tk = self.tk
        outer = tk.Frame(parent, bg="#101014")
        outer.pack(fill="both", expand=True)
        scroll = tk.Scrollbar(outer, orient="vertical")
        scroll.pack(side="right", fill="y")
        canvas = tk.Canvas(outer, bg="#101014", highlightthickness=0, yscrollcommand=scroll.set)
        canvas.pack(side="left", fill="both", expand=True)
        scroll.config(command=canvas.yview)
        inner = tk.Frame(canvas, bg="#101014")
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda _e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(int(-e.delta / 120), "units"))

        from ..params import PARAMS, display, get_field

        self.param_scales = {}
        row = 0
        for addr in sorted(PARAMS):
            param = PARAMS[addr]
            tk.Label(
                inner, text="0x%02X %s   (affects: %s)" % (addr, param.key, param.scope),
                fg="#aaaaaa", bg="#101014", anchor="w",
            ).grid(row=row, column=0, columnspan=3, sticky="w", pady=(8, 0))
            row += 1
            for field in param.fields:
                tk.Label(inner, text=field.name, fg="#cccccc", bg="#101014", width=15, anchor="w").grid(
                    row=row, column=0, sticky="w"
                )
                scale = tk.Scale(
                    inner, from_=field.lo, to=field.hi, orient="horizontal", length=260,
                    bg="#101014", fg="#cccccc", highlightthickness=0, showvalue=0,
                    command=lambda value, a=addr, f=field.name: self._on_param_drag(a, f, value),
                )
                scale.set(field.lo)
                scale.grid(row=row, column=1, sticky="w")
                value_label = tk.Label(inner, text="", fg="#888888", bg="#101014", width=24, anchor="w")
                value_label.grid(row=row, column=2, sticky="w")
                self.param_scales[(addr, field.name)] = (scale, value_label)
                row += 1

    def _build_loop_controls(self, parent) -> None:
        tk = self.tk
        strip = tk.Frame(parent, bg="#101014")
        strip.pack(fill="x")
        tk.Label(strip, text="track", fg="#cccccc", bg="#101014").pack(side="left")
        self.track_box = tk.Spinbox(strip, from_=0, to=5, width=3)
        self.track_box.pack(side="left", padx=4)
        self._button(strip, "Arm (bar)", self._on_arm, side="left")
        self._button(strip, "Commit", self._on_commit, side="left")
        self._button(strip, "Publish", self._on_publish, side="left")
        self._button(strip, "STOP", self._on_stop, side="left")
        self.loop_label = tk.Label(strip, text="blind recording: you cannot hear the other tracks", fg="#888888", bg="#101014")
        self.loop_label.pack(side="left", padx=8)

    def _build_wave_controls(self, parent) -> None:
        tk = self.tk
        strip = tk.Frame(parent, bg="#101014")
        strip.pack(fill="x")
        self._button(strip, "Capture frame (4 s)", self._on_capture_frame, side="left")
        tk.Label(strip, text="gain shift", fg="#cccccc", bg="#101014").pack(side="left", padx=(8, 2))
        self.gain = tk.Scale(strip, from_=0, to=15, orient="horizontal", length=140,
                             bg="#101014", fg="#cccccc", highlightthickness=0)
        self.gain.set(2)
        self.gain.pack(side="left")
        tk.Label(strip, text="LFO period s", fg="#cccccc", bg="#101014").pack(side="left", padx=(8, 2))
        self.period = tk.Entry(strip, width=6)
        self.period.insert(0, "20")
        self.period.pack(side="left")
        self._button(strip, "Upload frames", self._on_upload_frames, side="left")
        self._button(strip, "Upload .bin...", self._on_upload, side="left")
        self.progress = ttk_like_progress(tk, strip)
        self.progress_label = tk.Label(strip, text="", fg="#888888", bg="#101014")
        self.progress_label.pack(side="left")

    # -- actions ------------------------------------------------------------

    def _run(self, label, fn) -> None:
        """Every board call runs off the Tk thread; one failed command can cost 800 ms."""

        def worker():
            try:
                self._results.put((label, fn(), None))
            except Exception as exc:  # surfaced in the status bar, never swallowed
                self._results.put((label, None, exc))

        threading.Thread(target=worker, daemon=True).start()

    def _selected_preset(self):
        if not self.presets:
            return None
        selection = self.preset_list.curselection()
        return self.presets[selection[0]] if selection else None

    def _on_apply(self):
        preset = self._selected_preset()
        if preset is not None:
            self.preset_label.config(text="applying %s" % preset.name)
            self._run("apply", lambda: self.model.apply_preset(preset))

    def _on_capture(self):
        self._run("capture", lambda: self.model.capture_preset("captured-%d" % int(time.time())))

    def _on_stop(self):
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
        started = len(self.model.buffer.trail(10 ** 6))
        self.model.message = "capturing 4 s: move your hand over the sensor"
        self.root.after(4000, lambda: self._finish_capture(started))

    def _finish_capture(self, started: int):
        points = self.model.buffer.trail(10 ** 6)[started:]
        if len(points) < 32:
            self.model.message = "capture got %d samples; is the telemetry stream on?" % len(points)
            return
        self._run("capture-frame", lambda: self.model.capture_frame(points))

    def _on_upload_frames(self):
        shift = int(self.gain.get())
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

    def _on_param_drag(self, addr: int, name: str, value: str) -> None:
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
            self._results.put(("params", words, None))
            return "read %d registers" % len(words)

        self._run("read-params", action)

    def _sync_sliders(self, words: dict) -> None:
        from ..params import display, get_field

        for (addr, name), (scale, label) in getattr(self, "param_scales", {}).items():
            word = words.get(addr)
            if word is None:
                continue
            value = get_field(addr, name, word)
            if int(float(scale.get())) != value:
                scale.set(value)
            label.config(text=display(addr, name, word))

    def _on_mode(self, mode: int):
        self._run("mode", lambda: self.model.set_mode(mode))

    def _on_arp(self):
        wanted = bool(self.arp.get())
        self._run("rule", lambda: self.model.set_arp(wanted))

    def _on_arm(self):
        track = int(self.track_box.get())
        self._countdown(3, track)

    def _countdown(self, remaining: int, track: int) -> None:
        if remaining > 0:
            self.loop_label.config(text="track %d starts in %d" % (track, remaining))
            self.root.after(1000, lambda: self._countdown(remaining - 1, track))
            return

        def action():
            self.model.arm_take(track)
            self.model.wait_for_take()
            return self.model.capture_contour()

        self.loop_label.config(text="armed on track %d" % track)
        self._run("arm", action)

    def _on_commit(self):
        self.loop_label.config(text="committing")
        self._run("commit", self.model.commit_take)

    def _on_publish(self):
        self.loop_label.config(text="publishing")
        self._run("publish", self.model.publish_take)

    def _on_reference(self):
        from ..params import PARAMS

        env = {
            "attack_step": PARAMS[0x94].default & 0xFFFF,
            "decay_step": (PARAMS[0x94].default >> 16) & 0xFFFF,
            "sustain_level": PARAMS[0x98].default & 0xFFFF,
            "release_step": (PARAMS[0x98].default >> 16) & 0xFFFF,
        }
        contours = [c for c in self.model.contours.values()]
        if not contours:
            self.model.message = "record a take before playing a reference"
            return
        segments = reference.segments_from_contour(contours[0])
        table = self.model.table
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
            if label == "progress":
                table, done, total = value
                self.progress.configure(maximum=total, value=done)
                self.progress_label.config(text="frame %s  %d/%d" % ("ABC"[table], done, total))
                continue
            if label == "params":
                self._sync_sliders(value)
                continue
            if error is not None:
                self.model.message = "%s: %s" % (label, error)
            elif value:
                self.model.message = str(value)
            self.preset_label.config(text=self.model.message)

    def refresh(self) -> None:
        if self.pump is not None:
            try:
                self.pump()
            except Exception as exc:  # a dead link must not kill the window
                self.model.message = "link: %s" % exc
        self._drain_results()
        now = time.monotonic()
        if now - getattr(self, "_readout_at", 0.0) > 0.5:
            self._readout_at = now
            try:
                self.model.refresh_readouts()
                status = self.model.cached_status()
                if status is not None and status.mode == 1:
                    # LIVE derives tempo from cursor X (bpm_auto_q) and no register
                    # exposes it, so showing bpm_reg here would be a lie.
                    self.bpm_label.config(text="BPM: from X axis (not readable)")
                else:
                    self.bpm_label.config(text="BPM %d" % self.model.bpm())
                self.identity_label.config(text=self.model.identity_text())
            except Exception as exc:
                self.identity_label.config(text="link: %s" % exc)
        canvas = self.canvases.get(self._current)
        try:
            if canvas is not None:
                self.render.draw(canvas, self.model.drawing(self._current))
            self.status.config(text=self.model.status_line())
        except Exception as exc:  # a render error must not kill the loop
            self.status.config(text="draw error: %s" % exc)
        self.root.after(33, self.refresh)

    def run(self) -> int:
        self.refresh()
        self.root.after(200, self._on_read_params)
        self.root.mainloop()
        return 0
