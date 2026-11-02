"""Assisted recording state machine (LOOP spec 7.1).

Recording is blind -- the voice engine is held in reset outside PLAY -- so every
gate here exists to keep a take that cannot be heard from being committed: the
bar is forced first, the contour is read before the commit, and a take with holes
is retried before it is ever written to the store.
"""

from __future__ import annotations

import time

IDLE, READY, COUNTDOWN, ARMED, CAPTURING, CAPTURED, ANALYSING, REVIEWED, COMMITTING, PUBLISHING, ROLLED = (
    "idle",
    "ready",
    "countdown",
    "armed",
    "capturing",
    "captured",
    "analysing",
    "reviewed",
    "committing",
    "publishing",
    "rolled",
)
STATES = (
    IDLE,
    READY,
    COUNTDOWN,
    ARMED,
    CAPTURING,
    CAPTURED,
    ANALYSING,
    REVIEWED,
    COMMITTING,
    PUBLISHING,
    ROLLED,
)

BPM = 0x08
TRACK = 0x0C
RECORD = 0x18
COMMIT = 0x28
CONTOUR = 0x34
POTTS_STATUS = 0x38
PROBE = 0xF8

CONTOUR_POINTS = 32
MIN_COVERAGE = 30
MAX_RETRIES = 2
MAX_TRACK = 5
FULL_BIT = 0x10
DONE_BIT = 0x01


class FlowError(RuntimeError):
    """The flow was asked to do something out of order. Nothing was sent."""


def coverage(contour) -> int:
    return sum(1 for value in contour if value)


class RecordFlow:
    """One take on one track. Every step that writes checks the state first."""

    def __init__(self, session, track: int = 0, clock=time.monotonic):
        self.session = session
        self.track = track
        self.state = IDLE
        self.retries = 0
        self.diagnostic: dict = {}
        self._clock = clock

    # -- arming -------------------------------------------------------------

    def arm(self) -> None:
        """Force BPM 120, check it reads back, select the track, then PREPARE_RECORD.

        0x08=120 restarts the bar at tick 0 *when the board is not in LIVE*, which
        is the only deterministic phase reference the hardware offers; in LIVE the
        cursor drives the tempo and the four-second bar does not exist. The RTL
        switches to RECORD by itself once 0x18 arms, so MODE is never written.
        """
        if self.state not in (IDLE, READY, COUNTDOWN, ROLLED):
            raise FlowError("cannot arm from %s" % self.state)
        if not 0 <= self.track <= MAX_TRACK:
            raise FlowError("track must be 0..%d, not %d" % (MAX_TRACK, self.track))
        identity = getattr(self.session, "identity", None)
        if identity is not None and identity.mode == 1:
            raise FlowError("the board is in LIVE: its tempo comes from the cursor, so the bar is not 4 s")

        self.state = COUNTDOWN
        self.session.write(BPM, 120)
        back = self.session.read(BPM) & 0xFFFF
        if back != 120:
            raise FlowError("BPM read back as %d, not 120: the bar has no known length" % back)
        self.session.write(TRACK, self.track & 0x7)
        self.session.write(RECORD, 1)
        self.state = ARMED

    def poll(self) -> str:
        """Advance one step from what the board reports. No writes."""
        if self.state == ARMED:
            status = self.session.read(POTTS_STATUS)
            if status & FULL_BIT:
                self.state = CAPTURED
        return self.state

    # -- the take -----------------------------------------------------------

    def contour(self) -> list[int]:
        """Read the 32 contour samples; the pointer must be zeroed or the take rotates."""
        if self.state not in (CAPTURED, ANALYSING, REVIEWED):
            raise FlowError("no capture to read (state %s)" % self.state)
        self.session.write(CONTOUR, 0)
        samples = [self.session.read(CONTOUR) & 0xFFFF for _ in range(CONTOUR_POINTS)]
        self.state = REVIEWED if self.state == REVIEWED else ANALYSING
        return samples

    def accept_take(self, contour) -> str:
        """Gate a take on coverage. Returns "ok", "retry" or "diagnose"."""
        non_zero = coverage(contour)
        if non_zero >= MIN_COVERAGE:
            self.state = REVIEWED
            return "ok"
        if self.state not in (CAPTURED, ANALYSING, ARMED, COUNTDOWN):
            raise FlowError("no take to judge (state %s)" % self.state)
        self.retries += 1
        if self.retries <= MAX_RETRIES:
            self.state = COUNTDOWN
            return "retry"
        self.diagnose()
        self.state = IDLE
        return "diagnose"

    def diagnose(self) -> dict:
        """Tell "hand not there" apart from "state machine stuck", in that order."""
        frames_before = self.session.read(0xEC)
        time.sleep(0.01)
        frames_after = self.session.read(0xEC)
        raw_x = self.session.read(0xDC)
        raw_z = self.session.read(0xE0)
        self.diagnostic = {
            "frames": frames_after,
            "sensor_alive": frames_after != frames_before,
            "raw_x": raw_x,
            "raw_z": raw_z,
            "engaged": raw_z < 30000,
        }
        return self.diagnostic

    def commit(self, timeout_s: float = 15.0) -> int:
        """Commit the reviewed take, wait for the DP, and return the event count.

        The count is only meaningful after 0x38 bit0 says done; board_stage2_loop
        polls up to 15 s for exactly that, because reading the write-port probe
        while the DP is still running returns whatever it happened to hold.
        """
        if self.state != REVIEWED:
            raise FlowError("nothing reviewed to commit (state %s)" % self.state)
        self.state = COMMITTING
        self.session.write(COMMIT, 1)
        deadline = self._clock() + timeout_s
        while True:
            status = self.session.read(POTTS_STATUS)
            if status & DONE_BIT:
                break
            if self._clock() >= deadline:
                raise FlowError("the solver never reported done within %.1f s" % timeout_s)
            time.sleep(0.01)
        self.session.write(CONTOUR, 1)               # probe page 1 = commit write port
        word = self.session.read(PROBE)
        self.state = PUBLISHING
        return (word >> 21) & 0x3F

    def publish(self, timeout_s: float = 15.0) -> None:
        """Enter PLAY and wait for the boundary to swap the banks (0xF8 page 1 bit 6)."""
        if self.state != PUBLISHING:
            raise FlowError("nothing to publish (state %s)" % self.state)
        self.session.set_mode(4)
        deadline = self._clock() + timeout_s
        while True:
            self.session.write(CONTOUR, 1)           # page 1, without rotating the contour
            pending = (self.session.read(PROBE) >> 6) & 1
            if not pending:
                break
            if self._clock() >= deadline:
                raise FlowError("the store never published within %.1f s" % timeout_s)
            time.sleep(0.01)
        self.state = ROLLED
