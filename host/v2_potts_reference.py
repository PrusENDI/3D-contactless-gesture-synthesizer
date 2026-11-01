"""Deterministic fixed-point reference for the V2 128-tick Potts commit.

Ported verbatim from mgc3130_uart/tools/v2_potts_reference.py.  This is the
integer-note contract the RTL `v2_potts_commit_fsm` is compared against: the
contour holds MIDI note numbers, the level set is five degrees, and lambda is
paid once per non-initial segment.
"""
from dataclasses import dataclass

NOTES = (57, 60, 62, 64, 67)
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


def solve(contour, rest_mask=0, lambda_q16=65536, min_length=4):
    x = [int(contour[i]) if i < len(contour) else 0 for i in range(N)]
    # The hardware pipeline purifies the valid mask before the DP, so the
    # reference does the same and both see the same feasible problem.
    valid = purify_valid(~rest_mask & ((1 << N) - 1), N)
    rest_mask = ~valid & ((1 << N) - 1)
    lam = max(0, int(lambda_q16))
    L = max(1, int(min_length))
    inf = 1 << 62
    dp = [inf] * (N + 1)
    prev = [None] * (N + 1)
    dp[0] = 0
    for end in range(1, N + 1):
        for start in range(0, end):
            length = end - start
            if length < L and start != 0:
                continue
            vals = [x[t] for t in range(start, end) if not (rest_mask >> t) & 1]
            if vals and len(vals) != length:
                continue
            for k, note in enumerate(NOTES):
                err = sum((v - note) * (v - note) for v in vals)
                cost = dp[start] + (0 if start == 0 else lam) + err
                if cost < dp[end]:
                    dp[end] = cost
                    prev[end] = (start, k)
    if prev[N] is None:
        return []
    seg = []
    end = N
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


__all__ = ["NOTES", "PottsEvent", "solve"]
