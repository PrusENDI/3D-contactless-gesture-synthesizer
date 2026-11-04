"""Real-time intent inference from the cursor stream.

The board already streams (x, y, z) at whatever rate ``0x80`` asks for; this
module turns that stream into three continuously updated guesses:

* **register**  -- low / mid / high, from where the hand has been sitting;
* **rhythm**    -- even / dotted / accelerating / slowing / free, from the gaps
  between note changes;
* **melody**    -- ascending / descending / arch / valley / wave, plus stepwise
  vs arpeggio, from the sequence of scale degrees the hand walked through.

Everything is causal: an estimate only uses samples already received, so the
"latency" is the length of the analysis window, not a lookahead.  A new note is
seen as soon as its band is confirmed (3 samples, ~15 ms at 200 Hz); the rhythm
and melody labels need a few notes and settle in roughly 300--600 ms.

Deliberately not here: no model file, no numpy, no allocation per sample.  The
whole state is a ring of recent (t, y) pairs and the last few notes, which is
what makes it cheap enough to run on every telemetry frame at 200--500 Hz.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

# The live map's seven y edges (rtl/v2_live_rule_engine.sv), 0..65535.
BAND_EDGES = (3855, 13493, 23130, 30840, 40478, 50115, 59753)
BANDS = len(BAND_EDGES) + 1                      # 8 degrees of G natural minor

# Thirds of the travel: where "low", "mid" and "high" live.
REGISTER_EDGES = (21845, 43690)

DEFAULTS = {
    "rate_hz": 200.0,
    "window_s": 1.6,          # how much history the labels look at
    "register_s": 0.6,        # the register settles faster than the melody
    "min_note_s": 0.06,       # two note changes closer than this are one
    "confirm": 3,             # samples a new band must hold before it counts
    "settle_s": 0.05,
}


def band_of(y: int, edges: Iterable[int] = BAND_EDGES) -> int:
    """Which scale degree the board would play for this y (0..7)."""
    index = 0
    for edge in edges:
        if y >= edge:
            index += 1
        else:
            break
    return index


def register_of(median_y: float) -> str:
    low, high = REGISTER_EDGES
    if median_y < low:
        return "low"
    if median_y > high:
        return "high"
    return "mid"


def _median(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return 0.5 * (ordered[middle - 1] + ordered[middle])


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


@dataclass(frozen=True)
class Estimate:
    """One snapshot of the guess. ``confidence`` is what a caller should gate on."""

    register: str = "mid"
    rhythm: str = "free"
    melody: str = "flat"
    figures: str = "mixed"
    tempo_ms: float = 0.0
    confidence: float = 0.0
    y: int = 0
    notes: tuple[int, ...] = ()
    onsets: int = 0
    window_s: float = 0.0

    def line(self) -> str:
        return ("reg=%-4s rhythm=%-12s melody=%-10s %-8s %5.0f ms  conf=%.2f  notes=%s"
                % (self.register, self.rhythm, self.melody, self.figures,
                   self.tempo_ms, self.confidence,
                   "".join(str(n) for n in self.notes[-6:])))


class IntentEngine:
    """Feed it cursor samples, ask it for an :class:`Estimate` whenever you like."""

    def __init__(self, **options):
        self.options = dict(DEFAULTS)
        self.options.update(options)
        self._t: list[float] = []
        self._y: list[int] = []
        self._notes: list[tuple[float, int]] = []   # (time, band) in order
        self._pending_band: int | None = None
        self._candidate: int | None = None
        self._candidate_count = 0
        self._held = 0
        self._started = False
        self._last_onset = -1e9

    # ------------------------------------------------------------------ input

    def push(self, y: int, t: float) -> None:
        """One visible cursor sample: ``y`` in 0..65535, ``t`` in seconds."""
        self._t.append(t)
        self._y.append(y)
        self._trim()

        confirm = self.options["confirm"]
        band = band_of(y)

        if self._pending_band is None:
            self._pending_band = band
            self._held = 1
            return

        if band == self._pending_band:
            self._candidate = None
            self._candidate_count = 0
            self._held += 1
            if not self._started and self._held >= confirm:
                # The phrase opened on this pitch: it is a note too, not silence.
                self._started = True
                self._record(t, band)
            return

        # A different band is on screen; it becomes the note once it holds.
        if self._candidate == band:
            self._candidate_count += 1
        else:
            self._candidate = band
            self._candidate_count = 1
        if self._candidate_count < confirm:
            return

        self._pending_band = band
        self._candidate = None
        self._candidate_count = 0
        self._held = 1
        self._started = True
        self._record(t, band)

    def _record(self, t: float, band: int) -> None:
        if self._notes and t - self._last_onset < self.options["min_note_s"]:
            # Too close to the previous note: same gesture, keep the later pitch.
            self._notes[-1] = (t, band)
            self._last_onset = t
            return
        self._last_onset = t
        self._notes.append((t, band))
        horizon = t - self.options["window_s"] * 2
        while self._notes and self._notes[0][0] < horizon:
            self._notes.pop(0)

    def _trim(self) -> None:
        if not self._t:
            return
        horizon = self._t[-1] - self.options["window_s"]
        drop = 0
        while drop < len(self._t) and self._t[drop] < horizon:
            drop += 1
        if drop > 64:                                # trim in blocks, not per sample
            del self._t[:drop]
            del self._y[:drop]

    # ---------------------------------------------------------------- estimate

    def estimate(self) -> Estimate:
        if not self._y:
            return Estimate()
        t_now = self._t[-1]

        recent = [yt for ts, yt in zip(self._t, self._y)
                  if ts >= t_now - self.options["register_s"]]
        median_y = _median(recent or self._y[-8:])
        register = register_of(median_y)

        notes = [band for ts, band in self._notes if ts >= t_now - self.options["window_s"]]
        onsets = len(notes)
        iois = [b[0] - a[0] for a, b in zip(self._notes, self._notes[1:])
                if b[0] >= t_now - self.options["window_s"]]
        tempo_ms = 1000.0 * _median(iois) if iois else 0.0
        rhythm = self._classify_rhythm(iois)
        melody, figures = self._classify_melody(notes)

        spread = (max(recent) - min(recent)) if len(recent) > 1 else 0
        confidence = 0.0
        confidence += 0.35 if onsets >= 4 else 0.08 * onsets
        confidence += 0.25 if len(iois) >= 3 else 0.05 * len(iois)
        confidence += 0.25 if spread > 3000 else 0.05
        confidence += 0.15 if len(iois) >= 2 and _cv(iois) < 0.30 else 0.05
        confidence = min(1.0, confidence)

        return Estimate(register=register, rhythm=rhythm, melody=melody,
                        figures=figures, tempo_ms=tempo_ms, confidence=confidence,
                        y=int(median_y), notes=tuple(notes), onsets=onsets,
                        window_s=self.options["window_s"])

    # ------------------------------------------------------------- classifiers

    @staticmethod
    def _classify_rhythm(iois: list[float]) -> str:
        if len(iois) < 3:
            return "free"
        median = _median(iois)
        if median <= 0:
            return "free"
        if _cv(iois) < 0.20:
            return "even"
        # 2:1 figures: two gap sizes an octave apart and *nothing in between*.
        # The empty middle is what separates a dotted rhythm from a gradual
        # accelerando, whose end points can be 2:1 apart by accident.
        smallest = min(iois)
        largest = max(iois)
        if smallest > 0 and 1.6 <= largest / smallest <= 2.6:
            low_edge = smallest + 0.25 * (largest - smallest)
            high_edge = largest - 0.25 * (largest - smallest)
            if not any(low_edge < value < high_edge for value in iois):
                return "dotted"
        slope, fit = _trend(iois)
        normalised = slope * len(iois) / median
        if fit > 0.5 and normalised < -0.15:
            return "accelerating"
        if fit > 0.5 and normalised > 0.15:
            return "slowing"
        return "free"

    @staticmethod
    def _classify_melody(notes: list[int]) -> tuple[str, str]:
        if len(notes) < 2:
            return "flat", "mixed"
        steps = [b - a for a, b in zip(notes, notes[1:])]
        turns = sum(1 for a, b in zip(steps, steps[1:]) if a * b < 0)

        if all(step >= 0 for step in steps) and any(step > 0 for step in steps):
            shape = "ascending"
        elif all(step <= 0 for step in steps) and any(step < 0 for step in steps):
            shape = "descending"
        elif turns <= 1 and len(notes) >= 3:
            # One turning point: up-then-down is an arch, down-then-up a valley.
            # Anything that keeps turning is a wave, not an arch with a wiggle.
            peak = max(range(len(notes)), key=lambda i: notes[i])
            trough = min(range(len(notes)), key=lambda i: notes[i])
            if 0 < peak < len(notes) - 1 and notes[peak] - notes[0] >= 2:
                shape = "arch"
            elif 0 < trough < len(notes) - 1 and notes[0] - notes[trough] >= 2:
                shape = "valley"
            else:
                shape = "wave"
        else:
            shape = "wave"

        average = _mean([abs(step) for step in steps])
        if average <= 1.2:
            figures = "stepwise"
        elif average >= 2.0:
            figures = "arpeggio"
        else:
            figures = "mixed"
        return shape, figures


def _cv(values: list[float]) -> float:
    """Coefficient of variation: how uneven the gaps are, scale-free."""
    if len(values) < 2:
        return 1.0
    mean = _mean(values)
    if mean <= 0:
        return 1.0
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return (variance ** 0.5) / mean


def _trend(values: list[float]) -> tuple[float, float]:
    """Least-squares slope of ``values`` and its R^2, for accel/ritardando."""
    n = len(values)
    if n < 3:
        return 0.0, 0.0
    xs = list(range(n))
    mean_x = _mean([float(x) for x in xs])
    mean_y = _mean(values)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    if sxx <= 0:
        return 0.0, 0.0
    sxy = sum((x - mean_x) * (value - mean_y) for x, value in zip(xs, values))
    sst = sum((value - mean_y) ** 2 for value in values)
    slope = sxy / sxx
    if sst <= 1e-12:
        return slope, 0.0
    predicted = [mean_y + slope * (x - mean_x) for x in xs]
    residual = sum((value - fit) ** 2 for value, fit in zip(values, predicted))
    return slope, max(0.0, 1.0 - residual / sst)
