"""The window: one model behind four tabs, and the Tk code that draws it.

The model is pure -- it holds the session, the telemetry buffer, the table and the
contours, and answers "what does this tab draw". Only :class:`ConsoleWindow` and
``canvas/render_tk.py`` import tkinter, which is what keeps the painters testable.
"""

from __future__ import annotations

from .. import phase as phase_mod
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
        self.contours: dict = {}
        self.live_contour = None
        self.preset_name = ""
        self.message = ""

    # -- state --------------------------------------------------------------

    def status(self):
        return self.session.status() if self.session is not None else None

    def editable(self) -> bool:
        """Config changes need IDLE; in LIVE/PLAY the controls grey out instead of failing."""
        status = self.status()
        return status is None or status.mode == 0

    def status_line(self) -> str:
        status = self.status()
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
        return "  ".join(parts)

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
        return live_painter.paint_live(self.buffer)


class ConsoleWindow:
    """Tk shell. Wiring only: every decision lives in ConsoleModel or the painters."""

    def __init__(self, model: ConsoleModel, port_name: str = "COM4", pump=None):
        import tkinter as tk
        from tkinter import ttk

        from ..canvas import render_tk

        self.model = model
        self.pump = pump
        self.tk = tk
        self.render = render_tk
        self.root = tk.Tk()
        self.root.title("MGC3130 console - %s" % port_name)
        self.root.configure(bg="#101014")

        self.status = tk.Label(self.root, anchor="w", fg="#cccccc", bg="#101014", text="not connected")
        self.status.pack(fill="x")

        self.notebook = ttk.Notebook(self.root)
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

    def _on_tab(self, _event=None) -> None:
        index = self.notebook.index(self.notebook.select())
        self._current = TABS[index]

    def refresh(self) -> None:
        if self.pump is not None:
            try:
                self.pump()
            except Exception as exc:  # a dead link must not kill the window
                self.status.config(text="link: %s" % exc)
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
