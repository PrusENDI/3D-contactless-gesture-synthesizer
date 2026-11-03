"""Deterministic fixed-point reference for the V2 stage-2 Potts commit.

The contour is what the capture block stores: ``cursor_y >> 6``.  The fit runs
against ``LEVELS`` (the midpoint of each note's y interval) while the event
carries ``NOTES`` (the MIDI degree), exactly like the hardware's two tables.
"""
from dataclasses import dataclass

# y>>6 midpoints of the eight G-natural-minor degrees, from
# v2_live_rule_engine's note map: 55, 57, 58, 60, 62, 63, 65, 67.
LEVELS = (30, 135, 286, 421, 557, 707, 858, 978)
NOTES = (55, 57, 58, 60, 62, 63, 65, 67)
N = 128
MIN_RUN = 4


def purify_valid(mask, k=32, min_run=MIN_RUN):
    """Rewrite every valid run shorter than ``min_run`` into the previous run.

    The DP forbids a segment that mixes rest and data, so a short run leaves no
    valid segmentation at all.  Runs are rewritten in place (a chain of short
    runs keeps collapsing) and the first run is allowed to stay short, matching
    the first-segment exception in ``solve``.
    """
    pur = [(mask >> i) & 1 for i in range(k)]
    run_start = 0
    i = 1
    while i < k:
        if pur[i] != pur[i - 1]:
            if (i - run_start) < min_run and run_start != 0:
                value = pur[run_start - 1]
                for j in range(run_start, i):
                    pur[j] = value
            run_start = i
        i += 1
    if (k - run_start) < min_run and run_start != 0:
        value = pur[run_start - 1]
        for j in range(run_start, k):
            pur[j] = value
    return sum(bit << index for index, bit in enumerate(pur))


@dataclass(frozen=True)
class PottsEvent:
    tick: int
    duration: int
    note: int
    velocity: int = 100
    track: int = 0
    event_type: int = 1


def solve(contour, rest_mask=0, lambda_q16=21600, min_length=4, horizon=32):
    n = int(horizon)
    x = [int(contour[i]) if i < len(contour) else 0 for i in range(n)]
    # The hardware pipeline purifies the valid mask before the DP, so the
    # reference does the same and both see the same feasible problem.
    valid = purify_valid(~rest_mask & ((1 << n) - 1), n)
    rest_mask = ~valid & ((1 << n) - 1)
    lam = max(0, int(lambda_q16))
    L = max(1, int(min_length))
    inf = 1 << 62
    dp = [inf] * (n + 1)
    prev = [None] * (n + 1)
    dp[0] = 0
    for end in range(1, n + 1):
        for start in range(0, end):
            length = end - start
            if length < L and start != 0:
                continue
            vals = [x[t] for t in range(start, end) if not (rest_mask >> t) & 1]
            if vals and len(vals) != length:
                continue
            for k, level in enumerate(LEVELS):
                err = sum((v - level) * (v - level) for v in vals)
                cost = dp[start] + (0 if start == 0 else lam) + err
                if cost < dp[end]:
                    dp[end] = cost
                    prev[end] = (start, k)
    if prev[n] is None:
        return []
    seg = []
    end = n
    while end:
        start, k = prev[end]
        seg.append((start, end, k))
        end = start
    seg.reverse()
    out = []
    for start, end, k in seg:
        if any(not (rest_mask >> t) & 1 for t in range(start, end)):
            out.append(PottsEvent(start, end - start, NOTES[k]))
    return out


__all__ = ["LEVELS", "NOTES", "PottsEvent", "purify_valid", "solve"]
