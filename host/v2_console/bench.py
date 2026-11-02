"""Bench for the write-path burst cadence.

A 1024-point upload only gets faster than one-command-at-a-time if the board
keeps up with a paced burst; the read path was measured (280-450 us accepted,
200 us dropped) but the write path was not, so this exists to decide it.
"""

from __future__ import annotations

from dataclasses import dataclass

from .link import Link, LinkLost

WT_DATA = 0x68


@dataclass
class BurstReport:
    count: int
    pacing_us: int
    accepted: int
    elapsed_s: float
    lost: int

    def rate_per_s(self) -> float:
        return self.accepted / self.elapsed_s if self.elapsed_s > 0 else 0.0

    def safe(self) -> bool:
        """A cadence is safe only when nothing was lost and the board kept up."""
        return self.lost == 0 and self.accepted == self.count


def run_burst(link: Link, count: int, pacing_us: int) -> BurstReport:
    """Write ``count`` zero samples to WT_DATA at the given cadence. Never APPLYs."""
    commands = [(0x02, WT_DATA, 0)] * count
    original = link._pacing_s
    link._pacing_s = pacing_us / 1_000_000.0
    started = link._clock()
    try:
        replies = link.burst(commands)
    except LinkLost:
        elapsed = link._clock() - started
        return BurstReport(count, pacing_us, 0, elapsed, count)
    finally:
        link._pacing_s = original
    elapsed = max(link._clock() - started, 1e-9)
    accepted = sum(1 for reply in replies if not reply.nack and reply.err == 0)
    return BurstReport(count, pacing_us, accepted, elapsed, count - accepted)


def recommend(reports: list[BurstReport]) -> int | None:
    """The fastest cadence that lost nothing, or None when none was safe."""
    safe = [report.pacing_us for report in reports if report.safe()]
    return min(safe) if safe else None
