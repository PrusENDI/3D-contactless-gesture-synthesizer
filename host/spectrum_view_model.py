"""Model behind the spectrum viewer: no Tk, so it can be tested headless.

One capture is judged against the N the demo is supposed to be playing:

  * the CSV is a GAO capture at the I2S frame clock (48 kHz),
  * the demo puts tone k on 220.000*k Hz,
  * the capture also carries `demo_tone_count`, which says which segment this
    window really is -- a capture taken during the 8-tone segment must not be
    judged as if it were 32.

The viewer draws `spectrum.power_spectrum` and lists `find_peaks`; this module
only turns a file into numbers.
"""

from __future__ import annotations

import math
import os
import subprocess
import sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import spectrum  # noqa: E402  (host/spectrum.py, standard library only)

TONE_STEP_HZ = spectrum.TONE_STEP_HZ
DEFAULT_FS = spectrum.SAMPLE_RATE
TONE_COUNT_COLUMN = "demo_tone_count"


@dataclass
class Peak:
    k: int            # which expected tone this is (1-based)
    expected: float   # 220.000 * k
    found: float      # measured peak frequency
    level: float      # relative to the tallest peak
    error_bins: float # (found - expected) / bin width


@dataclass
class Analysis:
    path: str
    column: str
    fs: float
    samples: int
    usable: int
    bin_hz: float
    expected: int
    peaks: list[Peak] = field(default_factory=list)
    missing: list[int] = field(default_factory=list)
    stray: int = 0
    tone_count: int | None = None
    note: str = ""

    @property
    def peaks_found(self) -> int:
        return len(self.peaks)

    @property
    def count_ok(self) -> bool:
        return self.peaks_found == self.expected and not self.missing

    @property
    def segment_ok(self) -> bool:
        # A capture from the wrong segment is not a spectrum failure; say so.
        return self.tone_count is None or self.tone_count == self.expected

    @property
    def ok(self) -> bool:
        return self.count_ok and self.segment_ok

    @property
    def verdict(self) -> str:
        if not self.segment_ok:
            return "抓错段：这一窗是 %d 路，不是 %d 路" % (self.tone_count, self.expected)
        if self.missing:
            return "缺 %d 个峰（%s）" % (
                len(self.missing), ", ".join(str(k) for k in self.missing[:8]))
        if self.peaks_found != self.expected:
            return "峰数 %d，期望 %d" % (self.peaks_found, self.expected)
        return "%d/%d 峰全部落在 220*k Hz" % (self.peaks_found, self.expected)


def _pick_peak(peaks: list[tuple[float, float]], expected_hz: float,
               tolerance_hz: float) -> tuple[float, float] | None:
    best = None
    for freq, level in peaks:
        if abs(freq - expected_hz) <= tolerance_hz:
            if best is None or level > best[1]:
                best = (freq, level)
    return best


def analyze(path: str, expected: int, column: str | None = "sample_latched",
            fs: float = DEFAULT_FS, floor: float = 0.05) -> Analysis:
    """Read one capture and judge it against `expected` tones."""
    path = resolve_capture(path)
    samples, name = spectrum.read_capture(path, column)

    usable = 1 << (len(samples).bit_length() - 1)
    bin_hz = fs / usable
    peaks = spectrum.find_peaks(samples, fs, floor)

    tone_count = None
    try:
        counts, _ = spectrum.read_capture(path, TONE_COUNT_COLUMN)
        tone_count = int(counts[0])
    except ValueError:
        tone_count = None

    tolerance = 2.0 * bin_hz
    found: list[Peak] = []
    missing: list[int] = []
    for k in range(1, expected + 1):
        expected_hz = TONE_STEP_HZ * k
        hit = _pick_peak(peaks, expected_hz, tolerance)
        if hit is None:
            missing.append(k)
            continue
        found.append(Peak(k=k, expected=expected_hz, found=hit[0], level=hit[1],
                          error_bins=(hit[0] - expected_hz) / bin_hz))

    stray = max(0, len(peaks) - len(found))
    return Analysis(path=path, column=name, fs=fs, samples=len(samples),
                    usable=usable, bin_hz=bin_hz, expected=expected,
                    peaks=found, missing=missing, stray=stray,
                    tone_count=tone_count)


def resolve_capture(path: str) -> str:
    """gao_sh writes `<stem>_core0.csv`; accept either spelling."""
    if os.path.isfile(path):
        return path
    stem, ext = os.path.splitext(path)
    for candidate in (stem + "_core0" + ext, stem + "_core0.csv"):
        if os.path.isfile(candidate):
            return candidate
    raise ValueError("找不到抓取文件：%s" % path)


def curve(path: str, column: str | None = "sample_latched",
          fs: float = DEFAULT_FS, points: int = 900) -> tuple[list[float], float, float]:
    """Magnitude spectrum in dB, decimated to at most `points` dots.

    Returns (values_db, bin_hz, peak_db).  The first value is always 0 dB.
    """
    samples, _ = spectrum.read_capture(resolve_capture(path), column)
    size = 1 << (len(samples).bit_length() - 1)
    samples = samples[:size]
    power = spectrum.power_spectrum(samples)
    floor = max(max(power) * 1e-9, 1e-30)
    values = [10.0 * math.log10(max(p, floor) / max(power)) for p in power]
    step = max(1, len(values) // points)
    return values[::step], fs / size, 0.0


def waveform(path: str, column: str | None = "sample_latched",
             fs: float = DEFAULT_FS) -> tuple[list[float], float]:
    """The capture exactly as GAO recorded it: samples and milliseconds per point."""
    samples, _ = spectrum.read_capture(resolve_capture(path), column)
    return samples, 1000.0 / fs


def capture(cable: str, out_base: str, rao: str, timeout: int = 180) -> str:
    """Run one GAO capture; return the CSV path it produced.

    The gao_sh child writes to our stdio and appends `_core0`, so the file is
    located after the run instead of being assumed.
    """
    project = os.path.dirname(HERE)
    command = [sys.executable, os.path.join(project, "scripts", "gao_capture.py"),
               "--rao", rao, "--out", out_base, "--cable", cable]
    proc = subprocess.run(command, cwd=project, capture_output=True, text=True,
                          errors="replace", timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError((proc.stdout + proc.stderr).strip()[-800:] or "gao_capture 失败")
    return resolve_capture(out_base)
