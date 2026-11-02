"""Serial transport for the board: frame construction, CRC and the link itself.

The wire format is frozen in rtl/v2_contract_pkg.sv and in every board_*.ps1
script: an 11-byte command (A5 02 op addr seq d31..d24 d23..d16 d15..d8 d7..d0
crc_hi crc_lo) with CRC16-CCITT-FALSE over the first nine bytes.

One command at a time. The board accepts a new frame only while it is idle
(rtl/v2_uart_link.sv), so the host must pace a burst instead of streaming it,
and a lost reply is retried with the *same* seq: the link replays its cached
response for a byte-identical duplicate, which makes the retry exactly-once.
"""

from __future__ import annotations

import time

from .crc import CRC_SELFTEST, crc16
from .frames import Reply, StreamParser, Telemetry

__all__ = [
    "CRC_SELFTEST",
    "Link",
    "LinkLost",
    "OP_READ",
    "OP_WRITE",
    "SOF",
    "VERSION",
    "build_frame",
    "crc16",
]

SOF = 0xA5
VERSION = 0x02
OP_READ = 0x01
OP_WRITE = 0x02

MAX_ATTEMPTS = 2


class LinkLost(Exception):
    """The link is gone: no matching reply after the retry, or the port failed."""


def build_frame(op: int, addr: int, data: int, seq: int) -> bytes:
    """One 11-byte command frame. The payload is big-endian, as on the wire."""
    frame = bytearray(
        [
            SOF,
            VERSION,
            op & 0xFF,
            addr & 0xFF,
            seq & 0xFF,
            (data >> 24) & 0xFF,
            (data >> 16) & 0xFF,
            (data >> 8) & 0xFF,
            data & 0xFF,
        ]
    )
    value = crc16(bytes(frame))
    frame += bytes([(value >> 8) & 0xFF, value & 0xFF])
    return bytes(frame)


class Link:
    """One command at a time, with a paced burst for bulk transfers.

    Not thread-safe by design: the console runs every serial call on one worker
    thread so that ordering stays obvious and a drag cannot interleave with a
    workflow.
    """

    def __init__(self, port, pacing_s: float = 320e-6, timeout_s: float = 0.4, clock=time.monotonic):
        self._port = port
        self._pacing_s = pacing_s
        self._timeout_s = timeout_s
        self._clock = clock
        self._seq = 0
        self._parser = StreamParser()
        self._telemetry: list[Telemetry] = []
        self._last_round_trip_ms = 0.0

    # -- primitives ---------------------------------------------------------

    def _next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFF
        return self._seq

    def _write(self, frame: bytes) -> None:
        try:
            self._port.write(frame)
        except OSError as exc:
            raise LinkLost("port write failed: %s" % exc) from exc

    def _fill(self, wait_s: float) -> None:
        try:
            chunk = self._port.read(4096, wait_s)
        except OSError as exc:
            raise LinkLost("port read failed: %s" % exc) from exc
        if not chunk:
            return
        self._parser.feed(chunk)
        while True:
            snapshot = self._parser.next_telemetry()
            if snapshot is None:
                return
            self._telemetry.append(snapshot)

    def _drain_replies(self, wanted: int) -> Reply | None:
        """Pop replies until one carries ``wanted``; older ones are stale."""
        while True:
            reply = self._parser.next_reply()
            if reply is None:
                return None
            if reply.seq == wanted:
                return reply

    def _await(self, wanted: int, deadline: float) -> Reply | None:
        while True:
            reply = self._drain_replies(wanted)
            if reply is not None:
                return reply
            now = self._clock()
            if now >= deadline:
                return None
            self._fill(min(0.01, deadline - now))

    def _pace_until(self, when: float) -> None:
        # A real sleep on Windows rounds up to the 15.6 ms timer tick, which is
        # exactly the delay this pacing exists to avoid.
        while self._clock() < when:
            pass

    # -- public -------------------------------------------------------------

    def command(self, op: int, addr: int, data: int = 0) -> Reply:
        """Send one command and wait for its reply. NACKs are returned, not raised."""
        seq = self._next_seq()
        frame = build_frame(op, addr, data, seq)
        for _ in range(MAX_ATTEMPTS):
            started = self._clock()
            self._write(frame)
            reply = self._await(seq, started + self._timeout_s)
            if reply is not None:
                self._last_round_trip_ms = (self._clock() - started) * 1000.0
                return reply
        raise LinkLost("no reply for seq %d after %d attempts" % (seq, MAX_ATTEMPTS))

    def burst(self, cmds: list[tuple[int, int, int]]) -> list[Reply]:
        """Send ``cmds`` at the paced cadence, then collect every reply in order.

        Bulk transfers (a 1024-sample upload) only get faster than one-command-
        at-a-time if this stays under the board's service rate; the caller
        decides when that is allowed.
        """
        if not cmds:
            return []
        frames: list[bytes] = []
        seqs: list[int] = []
        for op, addr, data in cmds:
            seq = self._next_seq()
            seqs.append(seq)
            frames.append(build_frame(op, addr, data, seq))

        pending = list(zip(seqs, frames))
        collected: dict[int, Reply] = {}
        for attempt in range(MAX_ATTEMPTS):
            self._send_paced([frame for _, frame in pending])
            deadline = self._clock() + self._timeout_s + len(pending) * max(self._pacing_s, 0.0005)
            self._collect(seqs, collected, deadline)
            pending = [(seq, frame) for seq, frame in pending if seq not in collected]
            if not pending:
                break
        if pending:
            raise LinkLost(
                "burst lost %d of %d replies (seq %s)"
                % (len(pending), len(seqs), [seq for seq, _ in pending[:8]])
            )
        return [collected[seq] for seq in seqs]

    def _send_paced(self, frames: list[bytes]) -> None:
        next_at = self._clock()
        for frame in frames:
            self._write(frame)
            next_at += self._pacing_s
            self._pace_until(next_at)

    def _collect(self, seqs: list[int], collected: dict[int, Reply], deadline: float) -> None:
        wanted = set(seqs)
        while len(collected) < len(seqs):
            while True:
                reply = self._parser.next_reply()
                if reply is None:
                    break
                if reply.seq in wanted:
                    collected.setdefault(reply.seq, reply)
            now = self._clock()
            if now >= deadline:
                return
            self._fill(min(0.01, deadline - now))

    def pump(self) -> list[Telemetry]:
        """Read whatever is waiting and return the telemetry frames it held."""
        self._fill(0.0)
        out, self._telemetry = self._telemetry, []
        return out

    def last_round_trip_ms(self) -> float:
        return self._last_round_trip_ms
