"""Rolling telemetry. The board only streams while the cursor is valid, so a quiet
stream is the normal state of a hand not being over the sensor -- not a dead link.
"""

from __future__ import annotations

import time

from .frames import Telemetry


class TelemetryBuffer:
    """Newest frames plus a bounded trail, and an honest "waiting" flag."""

    def __init__(self, capacity: int = 1200, timeout_s: float = 0.5, clock=time.monotonic):
        # 1200 frames is six seconds at the sensor's 200 Hz: enough for the four
        # second wavetable capture plus the hand still being there before it.
        self._capacity = capacity
        self._timeout_s = timeout_s
        self._clock = clock
        self._frames: list[Telemetry] = []
        self._last_at: float | None = None
        self._pushed = 0

    def push(self, snapshot: Telemetry) -> None:
        self._frames.append(snapshot)
        self._pushed += 1
        if len(self._frames) > self._capacity:
            del self._frames[: len(self._frames) - self._capacity]
        self._last_at = self._clock()

    def last(self) -> Telemetry | None:
        return self._frames[-1] if self._frames else None

    def trail(self, n: int) -> list[tuple[int, int]]:
        return [(frame.x, frame.y) for frame in self._frames[-n:]]

    def mark(self) -> int:
        """Absolute count of frames seen so far.

        A wavetable capture must not index this ring by length: once it is full
        (1200 frames = 6 s of hand) the length stops growing, so "frames after the
        one I had" was always empty and every capture returned zero samples.
        """
        return self._pushed

    def since(self, mark: int) -> list[Telemetry]:
        """Every frame pushed after ``mark``, as far as the ring still holds them."""
        first = self._pushed - len(self._frames)
        return self._frames[max(0, mark - first):]

    def waiting(self) -> bool:
        """True when nothing arrived recently: no hand in the field, or no stream."""
        if self._last_at is None:
            return True
        return (self._clock() - self._last_at) > self._timeout_s
