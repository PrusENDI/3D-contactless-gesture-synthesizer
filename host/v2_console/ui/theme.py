"""Fonts, spacing and colours in one place, so a restyle never touches a handler.

The window is 150 % scaled on this machine (``AppliedDPI=144``). A plain Tk process
does not declare DPI awareness, so Windows renders it at 96 dpi and then stretches
the bitmap 1.5x -- every glyph is resampled, which is what "the GUI looks bad"
mostly is. ``ttkbootstrap.Window`` sets the awareness; this module then sizes
everything from the real DPI instead of hard-coded pixels.
"""

from __future__ import annotations

from dataclasses import dataclass

THEME = "darkly"
FAMILY = "Microsoft YaHei UI"
FAMILY_FALLBACK = "Microsoft YaHei"
MONO = "Consolas"
BASE_SIZE = 10
SMALL_SIZE = 9

NAMED_FONTS = (
    "TkDefaultFont",
    "TkTextFont",
    "TkMenuFont",
    "TkHeadingFont",
    "TkCaptionFont",
    "TkSmallCaptionFont",
    "TkTooltipFont",
    "TkIconFont",
)


@dataclass(frozen=True)
class Palette:
    bg: str
    panel: str
    fg: str
    dim: str
    accent: str
    danger: str
    canvas: str
    grid: str
    canvas_text: str


def dpi_scale(root) -> float:
    """1.0 at 96 dpi, 1.5 at 144 dpi. Pure maths, so it is testable off a screen."""
    return root.winfo_fpixels("1i") / 96.0


def enable_dpi_awareness() -> int:
    """Ask Windows to stop stretching our bitmaps, and report what we actually got.

    0 is unaware (the compositor scales the window 1.5x and every glyph is
    resampled), 1 is system DPI aware, 2 is per-monitor. ``ttkbootstrap.Window``
    calls the same API, but it swallows a refusal silently, and a silent refusal
    is exactly the case that produced a 96 dpi window on a 144 dpi screen.
    """
    try:
        from ctypes import byref, c_int, windll
    except Exception:                      # not Windows
        return -1

    def level() -> int:
        value = c_int(0)
        try:
            windll.shcore.GetProcessDpiAwareness(None, byref(value))
        except Exception:
            return -1
        return value.value

    if level() > 0:
        return level()
    for call in (lambda: windll.shcore.SetProcessDpiAwareness(1),
                 lambda: windll.user32.SetProcessDPIAware()):
        try:
            call()
        except Exception:
            continue
        if level() > 0:
            return level()
    return level()


def px(root, value: float) -> int:
    """A size written for 96 dpi, expressed in this screen's pixels."""
    return max(1, int(round(value * dpi_scale(root))))


def pick_family(root) -> str:
    from tkinter import font as tkfont

    families = set(tkfont.families(root))
    for name in (FAMILY, FAMILY_FALLBACK):
        if name in families:
            return name
    return "TkDefaultFont"


def apply(root) -> Palette:
    """Apply the theme's typography and spacing, and hand back the colours."""
    import ttkbootstrap as ttk

    family = pick_family(root)
    try:
        ttk.set_global_family(family, mono_family=MONO)
    except Exception:
        pass                      # a future ttkbootstrap may drop the helper

    from tkinter import font as tkfont

    for name in NAMED_FONTS:
        try:
            tkfont.nametofont(name).configure(family=family, size=BASE_SIZE)
        except Exception:
            pass

    style = root.style
    style.configure("TButton", padding=(px(root, 10), px(root, 4)))
    style.configure("TNotebook.Tab", padding=(px(root, 14), px(root, 5)))
    style.configure("TLabelframe.Label", font=(family, BASE_SIZE))
    style.configure("Small.TLabel", font=(family, SMALL_SIZE))

    colors = style.colors
    return Palette(
        bg=colors.bg,
        panel=colors.dark,
        fg=colors.fg,
        dim=getattr(colors, "light", "#ADB5BD"),
        accent=getattr(colors, "warning", "#f39c12"),
        danger=getattr(colors, "danger", "#e74c3c"),
        canvas="#1a1c1f",
        grid="#2a2d31",
        canvas_text="#9aa4ad",
    )


def apply_canvas(palette: Palette) -> None:
    """Tell the one Tk renderer which font and colours the drawings should use."""
    from ..canvas import render_tk

    render_tk.configure(
        font=(FAMILY, SMALL_SIZE),
        colors={"grid": palette.grid, "text": palette.canvas_text, "live": palette.accent},
    )
