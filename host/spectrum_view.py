#!/usr/bin/env python3
"""GAO 频谱校验台：抓一次、数峰、给结论。

    python host/spectrum_view.py --csv artifacts/gao/bars32_core0.csv --expect 32
    python host/spectrum_view.py            # 空窗口，用「抓取」按钮现场抓

左上是频谱（0..8 kHz，虚线是 220*k Hz 的期望位置），右上是判定，下面是峰表。
「抓取」直接调 scripts/gao_capture.py；抓完自动分析。抓错的段（例如这一窗是
8 路）不会被判成频谱失败，而是明确说「抓错段」。

只用标准库 + tkinter；没有 ttkbootstrap 也能跑，只是没有主题。
"""

from __future__ import annotations

import argparse
import datetime
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
if REPO not in sys.path:
    sys.path.insert(0, REPO)

import tkinter as tk
from tkinter import filedialog, ttk

from host import spectrum_view_model as model

BG = "#15171c"
PANEL = "#1d2027"
FG = "#e6e6e6"
DIM = "#9aa0aa"
ACCENT = "#4ea1ff"
GOOD = "#3ddc84"
BAD = "#ff5c5c"
GRID = "#2a2e37"
CURVE = "#7fb2ff"

DEFAULT_RAO = os.path.join(REPO, "gao", "demo_tones.rao")
DEFAULT_OUT = os.path.join(REPO, "artifacts", "gao", "viewer")


class App:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.analysis: model.Analysis | None = None
        self.auto_job = None

        root.title("GAO 抓取校验台 — 32 路 DDS")
        root.configure(bg=BG)
        # No DPI call on this build: with awareness on, Tk lays the window out in
        # pixels but the window manager sizes it in DIPs, so a 2100x1170 layout
        # landed in a 1415x817 window and the side panel was cut off.  Without
        # it, Tk and the window manager agree on one coordinate space.
        root.geometry("1100x700+20+20")
        root.minsize(900, 560)

        self._build_controls()
        self._build_body()
        self._build_table()

    # ------------------------------------------------------------- widgets --
    def _build_controls(self) -> None:
        bar = tk.Frame(self.root, bg=PANEL)
        bar.pack(fill="x", padx=8, pady=(8, 2))
        row2 = tk.Frame(self.root, bg=PANEL)
        row2.pack(fill="x", padx=8, pady=(0, 4))

        tk.Label(bar, text="抓取文件", bg=PANEL, fg=DIM).pack(side="left", padx=(8, 4))
        self.path_var = tk.StringVar()
        entry = tk.Entry(bar, textvariable=self.path_var, width=34, bg="#0f1116",
                         fg=FG, insertbackground=FG, relief="flat")
        entry.pack(side="left", padx=4, ipady=3)

        tk.Button(bar, text="浏览…", command=self.browse, bg="#2a2f39", fg=FG,
                  relief="flat").pack(side="left", padx=3)
        tk.Button(bar, text="分析", command=self.analyze, bg=ACCENT, fg="#06121f",
                  relief="flat", width=5).pack(side="left", padx=3)
        tk.Button(bar, text="抓取一次", command=self.capture_once, bg="#2f4a6a", fg=FG,
                  relief="flat", width=8).pack(side="left", padx=(8, 4))

        tk.Label(row2, text="期望路数", bg=PANEL, fg=DIM).pack(side="left", padx=(8, 4))
        self.expect_var = tk.StringVar(value="32")
        ttk.Spinbox(row2, from_=1, to=32, width=4, textvariable=self.expect_var).pack(side="left")

        tk.Label(row2, text="电缆", bg=PANEL, fg=DIM).pack(side="left", padx=(12, 4))
        self.cable_var = tk.StringVar(value="FT2CH")
        tk.Entry(row2, textvariable=self.cable_var, width=7, bg="#0f1116", fg=FG,
                 insertbackground=FG, relief="flat").pack(side="left", ipady=3)

        self.auto_var = tk.BooleanVar(value=False)
        tk.Checkbutton(row2, text="自动重抓(5 s)", variable=self.auto_var,
                       command=self.toggle_auto, bg=PANEL, fg=DIM,
                       selectcolor=PANEL, activebackground=PANEL).pack(side="left", padx=(12, 4))

        tk.Label(row2, text="视图", bg=PANEL, fg=DIM).pack(side="left", padx=(12, 2))
        self.mode_var = tk.StringVar(value="wave")
        for value, label in (("wave", "波形"), ("spectrum", "频谱")):
            tk.Radiobutton(row2, text=label, value=value, variable=self.mode_var,
                           command=self.redraw, bg=PANEL, fg=DIM, selectcolor=PANEL,
                           activebackground=PANEL).pack(side="left", padx=2)

    def _build_body(self) -> None:
        body = tk.Frame(self.root, bg=BG)
        body.pack(fill="both", expand=True, padx=8, pady=4)

        self.canvas = tk.Canvas(body, bg="#0d0f13", highlightthickness=0, height=240)
        self.canvas.pack(side="left", fill="both", expand=True)
        self.canvas.bind("<Configure>", lambda _event: self.redraw())

        side = tk.Frame(body, bg=PANEL, width=300)
        side.pack(side="right", fill="y", padx=(6, 0))
        side.pack_propagate(False)

        self.verdict_label = tk.Label(side, text="等待抓取", bg=PANEL, fg=DIM,
                                      font=("Microsoft YaHei UI", 13, "bold"),
                                      wraplength=270, justify="left")
        self.verdict_label.pack(anchor="w", padx=10, pady=(10, 4))

        self.stats = tk.Text(side, height=15, width=44, bg=PANEL, fg=DIM, bd=0,
                             font=("Consolas", 9), wrap="word")
        self.stats.pack(anchor="w", padx=14)
        self.stats.configure(state="disabled")

    def _build_table(self) -> None:
        frame = tk.Frame(self.root, bg=BG)
        frame.pack(fill="both", expand=False, padx=8, pady=(4, 8))
        columns = ("k", "expect", "found", "bins", "level")
        self.table = ttk.Treeview(frame, columns=columns, show="headings", height=8)
        for column, title, width in (("k", "k", 40), ("expect", "期望 Hz", 110),
                                     ("found", "实测 Hz", 110), ("bins", "偏差 bin", 90),
                                     ("level", "相对电平", 100)):
            self.table.heading(column, text=title)
            self.table.column(column, width=width, anchor="center")
        self.table.pack(side="left", fill="both", expand=True)
        scroll = ttk.Scrollbar(frame, orient="vertical", command=self.table.yview)
        scroll.pack(side="right", fill="y")
        self.table.configure(yscrollcommand=scroll.set)

        self.status = tk.Label(self.root, text="就绪", bg=BG, fg=DIM, anchor="w")
        self.status.pack(fill="x", padx=10, pady=(0, 6))

    # -------------------------------------------------------------- actions --
    def browse(self) -> None:
        path = filedialog.askopenfilename(
            title="选择 GAO 抓取",
            initialdir=os.path.join(REPO, "artifacts", "gao"),
            filetypes=[("CSV", "*.csv"), ("所有文件", "*.*")])
        if path:
            self.path_var.set(path)
            self.analyze()

    def analyze(self) -> None:
        path = self.path_var.get().strip()
        if not path:
            self.set_status("先选一个抓取文件，或点「抓取一次」", BAD)
            return
        try:
            expected = int(self.expect_var.get())
        except ValueError:
            self.set_status("期望路数不是整数", BAD)
            return
        try:
            self.analysis = model.analyze(path, expected)
        except Exception as exc:  # noqa: BLE001 - the window reports, never crashes
            self.analysis = None
            self.set_status("分析失败：%s" % exc, BAD)
            self.redraw()
            self.fill_table()
            return
        self.path_var.set(self.analysis.path)
        self.redraw()
        self.fill_table()
        self.update_side()
        self.set_status(self.analysis.verdict, GOOD if self.analysis.ok else BAD)

    def capture_once(self) -> None:
        stamp = datetime.datetime.now().strftime("%H%M%S")
        out_base = "%s_%s" % (DEFAULT_OUT, stamp)
        self.set_status("抓取中（约 5–10 秒）…", ACCENT)
        self.root.update_idletasks()
        try:
            path = model.capture(self.cable_var.get().strip() or "FT2CH", out_base,
                                 DEFAULT_RAO)
        except Exception as exc:  # noqa: BLE001
            self.set_status("抓取失败：%s" % exc, BAD)
            return
        self.path_var.set(path)
        self.analyze()

    def toggle_auto(self) -> None:
        if self.auto_job is not None:
            self.root.after_cancel(self.auto_job)
            self.auto_job = None
        if self.auto_var.get():
            self._auto_tick()

    def _auto_tick(self) -> None:
        self.capture_once()
        self.auto_job = self.root.after(5000, self._auto_tick)

    # --------------------------------------------------------------- render --
    def redraw(self) -> None:
        self.canvas.delete("all")
        if self.analysis is None:
            self.canvas.create_text(max(self.canvas.winfo_width(), 400) // 2,
                                    max(self.canvas.winfo_height(), 240) // 2,
                                    text="点「抓取一次」或选一个 CSV", fill=DIM,
                                    font=("Microsoft YaHei UI", 12))
            return
        if self.mode_var.get() == "wave":
            self.draw_wave()
        else:
            self.draw_spectrum()

    def draw_wave(self) -> None:
        """The GAO capture as it was recorded: 2048 points over 42.7 ms."""
        width = max(self.canvas.winfo_width(), 400)
        height = max(self.canvas.winfo_height(), 240)
        left, right, top, bottom = 56, 16, 16, 34
        try:
            samples, ms_per = model.waveform(self.analysis.path, self.analysis.column)
        except Exception as exc:  # noqa: BLE001
            self.canvas.create_text(width // 2, height // 2,
                                    text="读不到抓取：%s" % exc, fill=BAD)
            return

        total_ms = len(samples) * ms_per
        plot_w = width - right - left
        plot_h = height - bottom - top

        for tick in range(0, int(total_ms) + 1, 5):
            x = left + plot_w * tick / total_ms
            self.canvas.create_line(x, top, x, height - bottom, fill=GRID)
            self.canvas.create_text(x, height - bottom + 12, text="%dms" % tick,
                                    fill=DIM, font=("Consolas", 8))
        for level, label in ((32767, "+FS"), (0, "0"), (-32768, "-FS")):
            y = top + plot_h * (0.5 - level / 65536.0)
            self.canvas.create_line(left, y, width - right, y, fill=GRID)
            self.canvas.create_text(left - 26, y, text=label, fill=DIM,
                                    font=("Consolas", 8))

        # One point per sample: this is the raw trace, not a decimated sketch.
        points = []
        for index, value in enumerate(samples):
            x = left + plot_w * index / max(1, len(samples) - 1)
            y = top + plot_h * (0.5 - value / 65536.0)
            points.extend([x, y])
        if len(points) >= 4:
            self.canvas.create_line(*points, fill=CURVE, width=1)

        self.canvas.create_text(
            width - right - 6, top + 6, anchor="ne",
            text="%d 点 / %.1f ms / %s 路" % (len(samples), total_ms,
                                              self.analysis.tone_count
                                              if self.analysis.tone_count is not None else "?"),
            fill=DIM, font=("Consolas", 9))

    def draw_spectrum(self) -> None:
        width = max(self.canvas.winfo_width(), 400)
        height = max(self.canvas.winfo_height(), 240)
        left, right, top, bottom = 56, 16, 16, 34
        self._plot_left, self._plot_right = left, width - right
        self._plot_top, self._plot_bottom = top, height - bottom

        # Full scale: 0..8 kHz covers tones 1..32 with a margin; never beyond fs/2.
        f_max = min(8000.0, (self.analysis.fs if self.analysis else 48000.0) / 2.0)
        self.f_max = f_max

        for step_khz in range(0, int(f_max / 1000) + 1):
            x = self.fx(step_khz * 1000.0)
            self.canvas.create_line(x, top, x, height - bottom, fill=GRID)
            self.canvas.create_text(x, height - bottom + 12, text="%dk" % step_khz,
                                    fill=DIM, font=("Consolas", 8))
        for db in range(0, -81, -20):
            y = self.fy(db)
            self.canvas.create_line(left, y, width - right, y, fill=GRID)
            self.canvas.create_text(left - 30, y, text="%d" % db, fill=DIM,
                                    font=("Consolas", 8))

        if self.analysis is None:
            return

        # Expected tone positions.
        for k in range(1, self.analysis.expected + 1):
            x = self.fx(model.TONE_STEP_HZ * k)
            if x is None:
                continue
            self.canvas.create_line(x, top, x, height - bottom, fill="#333a46", dash=(2, 4))
            if k % 8 == 0 or k == 1:
                self.canvas.create_text(x, top + 8, text="%d" % k, fill="#556070",
                                        font=("Consolas", 7))

        # Spectrum curve.
        try:
            values, _bin_hz, _peak = model.curve(self.analysis.path, self.analysis.column)
        except Exception:  # noqa: BLE001
            values = []
        if values:
            step_hz = f_max / max(1, len(values) - 1)
            points = []
            for index, value in enumerate(values):
                freq = index * step_hz
                if freq > f_max:
                    break
                points.extend([self.fx(freq), self.fy(max(-90.0, value))])
            if len(points) >= 4:
                self.canvas.create_line(*points, fill="#2b3444", width=1)

        # Found peaks.
        for peak in self.analysis.peaks:
            x = self.fx(peak.found)
            if x is None:
                continue
            y = self.fy(max(-90.0, 20.0 * (1.0 - peak.level)))
            self.canvas.create_line(x, self._plot_bottom, x, y, fill=GOOD, width=2)
            self.canvas.create_oval(x - 3, y - 3, x + 3, y + 3, fill=GOOD, outline="")

        # Missing tones.
        for k in self.analysis.missing:
            x = self.fx(model.TONE_STEP_HZ * k)
            if x is None:
                continue
            self.canvas.create_line(x, self._plot_bottom - 6, x, self._plot_bottom,
                                    fill=BAD, width=3)

        self.canvas.create_text(
            width - right - 6, top + 6, anchor="ne",
            text="%d 峰 / 期望 %d" % (self.analysis.peaks_found, self.analysis.expected),
            fill=GOOD if self.analysis.count_ok else BAD,
            font=("Microsoft YaHei UI", 11, "bold"))

    def fill_table(self) -> None:
        for item in self.table.get_children():
            self.table.delete(item)
        if self.analysis is None:
            return
        for peak in self.analysis.peaks:
            self.table.insert("", "end", values=(
                peak.k, "%.1f" % peak.expected, "%.1f" % peak.found,
                "%+.2f" % peak.error_bins, "%.3f" % peak.level))

    def update_side(self) -> None:
        analysis = self.analysis
        assert analysis is not None
        self.verdict_label.configure(
            text=("PASS\n" if analysis.ok else "FAIL\n") + analysis.verdict,
            fg=GOOD if analysis.ok else BAD)
        lines = [
            "文件    %s" % os.path.basename(analysis.path),
            "列      %s" % analysis.column,
            "采样    %d 点（用 %d，%.1f ms）" % (analysis.samples, analysis.usable,
                                                1000.0 * analysis.usable / analysis.fs),
            "分辨率  %.1f Hz/bin" % analysis.bin_hz,
            "峰数    %d / %d" % (analysis.peaks_found, analysis.expected),
            "多余峰  %d" % analysis.stray,
            "计数列  %s" % ("%d 路" % analysis.tone_count if analysis.tone_count is not None
                            else "（这次抓取没采）"),
            "",
            "频率 = 220.000*k Hz",
            "容差 ±2 bin = ±%.0f Hz" % (2 * analysis.bin_hz),
        ]
        self.stats.configure(state="normal")
        self.stats.delete("1.0", "end")
        self.stats.insert("1.0", "\n".join(lines))
        self.stats.configure(state="disabled")

    def set_status(self, text: str, colour: str) -> None:
        self.status.configure(text=text, fg=colour)

    # ------------------------------------------------------------ geometry --
    def fx(self, hz: float) -> float | None:
        if hz < 0 or hz > self.f_max:
            return None
        span = self._plot_right - self._plot_left
        return self._plot_left + span * (hz / self.f_max)

    def fy(self, db: float) -> float:
        span = self._plot_bottom - self._plot_top
        return self._plot_top + span * (-db / 90.0)


def enable_dpi_awareness() -> None:
    """Without this, Windows renders the window at 96 dpi and stretches it, so a
    760-px-tall window becomes 1140 px and the table falls off the screen."""
    try:
        import ctypes
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:  # noqa: BLE001 - older Windows
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:  # noqa: BLE001 - not Windows
        pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", default="", help="打开时直接分析这个抓取")
    parser.add_argument("--expect", type=int, default=32)
    parser.add_argument("--view", default="wave", choices=("wave", "spectrum"))
    args = parser.parse_args(argv)

    # DPI awareness stays off; App explains why (the layout gets clipped here).
    root = tk.Tk()
    app = App(root)
    app.mode_var.set(args.view)
    app.expect_var.set(str(args.expect))
    if args.csv:
        app.path_var.set(args.csv)
        root.after(150, app.analyze)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
