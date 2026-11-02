"""Playback phase for the LOOP canvas.

Nothing on the board exposes the loop tick, so the console anchors instead: it
forces BPM 120 (which restarts the bar at tick 0 when not in LIVE) and counts
seconds from that moment. Drift is 0.0032 tick per 4 s; the anchor's own
observation error is about 0.14 tick, 45 times larger, and is documented rather
than engineered away.
"""

from __future__ import annotations

import time


class PhaseAnchor:
    """A bar is 4.000 s, which only holds while BPM is forced to 120."""

    BAR_SECONDS = 4.0

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._t0: float | None = None

    def force_bar(self, now: float | None = None) -> None:
        """Call right after writing 0x08=120: that write restarts the bar at tick 0."""
        self._t0 = self._clock() if now is None else now

    @property
    def anchored(self) -> bool:
        """False until a bar has actually been forced: u() is 0 for a reason, not a tick."""
        return self._t0 is not None

    def reanchor(self, now: float | None = None) -> None:
        """Call when the board reports the publish (0xF8 page 1 bit 6 falling)."""
        self.force_bar(now)

    def u(self, now: float | None = None) -> float:
        if self._t0 is None:
            return 0.0
        elapsed = (self._clock() if now is None else now) - self._t0
        return (elapsed / self.BAR_SECONDS) % 1.0
