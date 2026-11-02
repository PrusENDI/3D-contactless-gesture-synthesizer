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


class ConsoleWindow:
    """Tk shell. Wiring only: every decision lives in ConsoleModel or the painters."""

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
        self._results: queue.Queue = queue.Queue()

        self.status = tk.Label(self.root, anchor="w", fg="#cccccc", bg="#101014", text="not connected")
        self.status.pack(fill="x")

        body = tk.Frame(self.root, bg="#101014")
        body.pack(fill="both", expand=True)

        sidebar = tk.Frame(body, bg="#101014", width=180)
        sidebar.pack(side="left", fill="y")
        tk.Label(sidebar, text="presets", fg="#888888", bg="#101014").pack(anchor="w")
        self.preset_list = tk.Listbox(sidebar, height=12, exportselection=False)
        for preset in self.presets:
            self.preset_list.insert("end", preset.name)
        if self.presets:
            self.preset_list.selection_set(0)
        self.preset_list.pack(fill="x")
        self._button(sidebar, "Apply", self._on_apply)
        self._button(sidebar, "Capture", self._on_capture)
        self._button(sidebar, "Upload table...", self._on_upload)
        self._button(sidebar, "Read back", self._on_readback)

        main = tk.Frame(body, bg="#101014")
        main.pack(side="left", fill="both", expand=True)
        self.notebook = ttk.Notebook(main)
        self.notebook.pack(fill="both", expand=True)
        self.canvases = {}
        for name in TABS:
            frame = tk.Frame(self.notebook, bg="#101014")
            canvas = tk.Canvas(frame, bg="#101014", highlightthickness=0)
            canvas.pack(fill="both", expand=True)
            self.notebook.add(frame, text=name)
            self.canvases[name] = canvas
        self._current = TABS[0]
        self.notebook.bind("<<NotebookTabChanged>>", self._on_tab)

        controls = tk.Frame(self.root, bg="#101014")
        controls.pack(fill="x")
        self._button(controls, "Stop", self._on_stop, side="left")
        self._button(controls, "Reference play", self._on_reference, side="left")
        self._button(controls, "Reference stop", self._on_reference_stop, side="left")

        morph = tk.Frame(self.root, bg="#101014")
        morph.pack(fill="x")
        self._button(morph, "Capture frame (4 s)", self._on_capture, side="left")
        tk.Label(morph, text="gain shift", fg="#cccccc", bg="#101014").pack(side="left", padx=(8, 2))
        self.gain = tk.Scale(
            morph, from_=0, to=15, orient="horizontal", length=140,
            bg="#101014", fg="#cccccc", highlightthickness=0,
        )
        self.gain.set(2)
        self.gain.pack(side="left")
        tk.Label(morph, text="LFO period s", fg="#cccccc", bg="#101014").pack(side="left", padx=(8, 2))
        self.period = tk.Entry(morph, width=6)
        self.period.insert(0, "20")
        self.period.pack(side="left")
        self._button(morph, "Upload frames", self._on_upload_frames, side="left")
        self.progress = ttk.Progressbar(morph, length=160, maximum=1024)
        self.progress.pack(side="left", padx=8)
        self.progress_label = tk.Label(morph, text="", fg="#888888", bg="#101014")
        self.progress_label.pack(side="left")

    # -- helpers ------------------------------------------------------------

    def _button(self, parent, label, command, side="top"):
        button = self.tk.Button(parent, text=label, command=command)
        button.pack(side=side, fill="x" if side == "top" else "none", padx=2, pady=1)
        return button

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

    # -- button handlers ----------------------------------------------------

    def _on_apply(self):
        preset = self._selected_preset()
        if preset is not None:
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

    def _on_capture(self):
        """Collect four seconds of trajectory first; one frame is one pass of the hand."""
        started = len(self.model.buffer.trail(10 ** 6))
        self.model.message = "capturing 4 s: move your hand over the sensor"
        self.root.after(4000, lambda: self._finish_capture(started))

    def _finish_capture(self, started: int):
        points = self.model.buffer.trail(10 ** 6)[started:]
        if len(points) < 32:
            self.model.message = "capture got %d samples; is the telemetry stream on?" % len(points)
            return
        self._run("capture", lambda: self.model.capture_frame(points))

    def _on_upload_frames(self):
        shift = int(self.gain.get())
        try:
            period = float(self.period.get() or 20.0)
        except ValueError:
            self.model.message = "LFO period must be a number of seconds"
            return

        def action():
            return self.model.upload_frames(
                shift,
                True,
                period,
                on_progress=lambda table, done, total: self._results.put(
                    ("progress", (table, done, total), None)
                ),
            )

        self._run("upload-frames", action)

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
            if error is not None:
                self.model.message = "%s: %s" % (label, error)
            elif value:
                self.model.message = str(value)

    def refresh(self) -> None:
        if self.pump is not None:
            try:
                self.pump()
            except Exception as exc:  # a dead link must not kill the window
                self.model.message = "link: %s" % exc
        self._drain_results()
        canvas = self.canvases[self._current]
        try:
            self.render.draw(canvas, self.model.drawing(self._current))
            self.status.config(text=self.model.status_line())
        except Exception as exc:  # a render error must not kill the loop
            self.status.config(text="draw error: %s" % exc)
        self.root.after(33, self.refresh)

    def run(self) -> int:
        self.refresh()
        self.root.mainloop()
        return 0
