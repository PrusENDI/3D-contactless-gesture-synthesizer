"""A score: what every track should play, tick by tick, and how close a take was.

The eight notes and their eight y intervals are the hardware's, not a choice:
``rtl/v2_note_increment_rom.sv`` holds exactly these eight phase increments, and
``rtl/v2_live_rule_engine.sv:96-103`` picks the note from ``cursor_y`` with the
edges below.  A contour sample is ``y[15:6]`` (``v2_loop_contour_capture.sv:57``),
so the same edges divided by 64 are the contour intervals used here -- that is
what makes a hit/miss check mean the same thing the board means.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

TICKS = 32
BAR_BPM = 120                 # record_flow.arm forces it; the bar has no other length
NOTES = (55, 57, 58, 60, 62, 63, 65, 67)
NAME_OF = {55: "G3", 57: "A3", 58: "Bb3", 60: "C4", 62: "D4", 63: "Eb4", 65: "F4", 67: "G4"}
SCHEMA = 1

# (edge, note selected below that edge): y < 3855 -> G3, ... y >= 59753 -> G4.
_EDGES = ((60, 55), (211, 57), (361, 58), (482, 60), (632, 62), (783, 63), (934, 65))
TOP_NOTE = 67
CONTOUR_MAX = 1023


class ScoreError(ValueError):
    """The file cannot be played, and the message says which line is wrong."""


SCORE_DIR = Path(__file__).resolve().parent.parent / "scores"


def available() -> list:
    """Every score on disk, in name order."""
    return sorted(SCORE_DIR.glob("*.json"))


def note_of(value: int) -> int | None:
    """Which note the board would hear for this contour sample; None for a rest."""
    if not value:
        return None
    for edge, note in _EDGES:
        if value < edge:
            return note
    return TOP_NOTE


def band_of(note: int) -> tuple[int, int]:
    """The contour interval that selects ``note``. The band a hand has to be in."""
    if note not in NOTES:
        raise KeyError("%d is not one of the eight notes" % note)
    lower = 0
    for edge, candidate in _EDGES:
        if candidate == note:
            return lower, edge
        lower = edge
    return lower, CONTOUR_MAX


def edges() -> list[tuple[int, int]]:
    """(low, high) contour bounds of every band, bottom to top -- for drawing."""
    return [band_of(note) for note in NOTES]


@dataclass(frozen=True)
class Segment:
    note: int
    start: int
    end: int

    @property
    def name(self) -> str:
        return NAME_OF[self.note]


@dataclass(frozen=True)
class Track:
    index: int
    role: str
    segments: tuple = ()

    def target(self) -> list[int]:
        """One note per tick, 0 where the track is silent."""
        row = [0] * TICKS
        for segment in self.segments:
            for tick in range(segment.start, min(TICKS, segment.end)):
                row[tick] = segment.note
        return row


@dataclass(frozen=True)
class Score:
    name: str
    bpm: int
    ticks: int
    tracks: tuple
    path: Path | None = None

    def track(self, index: int) -> Track:
        for track in self.tracks:
            if track.index == index:
                return track
        raise KeyError("the score has no track %d" % index)

    def targets(self, index: int) -> list[int]:
        return self.track(index).target()


@dataclass(frozen=True)
class HitReport:
    ok: int
    engaged: int
    ticks: int
    wrong: tuple = ()

    def fraction(self) -> str:
        return "%d/%d" % (self.ok, self.ticks)


def judge(contour, target) -> HitReport:
    """Count the ticks whose recorded height lands in the note the score asked for.

    A tick where the hand was not in the field (contour 0) is a miss, not a skip:
    the commit writes a rest there, and the arrangement would lose a note.
    """
    wrong = []
    ok = 0
    for tick, wanted in enumerate(target):
        want = note_of(contour[tick]) if tick < len(contour) else None
        if want == wanted:
            ok += 1
        else:
            wrong.append(tick)
    engaged = sum(1 for value in contour if value)
    return HitReport(ok=ok, engaged=engaged, ticks=len(target), wrong=tuple(wrong))


def _segments(entries, where: str) -> tuple:
    """[tick, note] pairs -> segments, merging repeated notes into one hold."""
    if not entries:
        raise ScoreError("%s has no notes" % where)
    points = []
    for entry in entries:
        if not isinstance(entry, (list, tuple)) or len(entry) != 2:
            raise ScoreError("%s: every note is [tick, note], got %r" % (where, entry))
        tick, note = int(entry[0]), int(entry[1])
        if not 0 <= tick < TICKS:
            raise ScoreError("%s: tick %d is outside 0..%d" % (where, tick, TICKS - 1))
        if note not in NOTES:
            raise ScoreError(
                "%s: note %d is not playable; the ROM has %s" % (where, note, ", ".join(map(str, NOTES)))
            )
        if points and tick <= points[-1][0]:
            raise ScoreError("%s: ticks must start once each, ascending (%d after %d)"
                             % (where, tick, points[-1][0]))
        points.append((tick, note))

    merged: list[Segment] = []
    for index, (tick, note) in enumerate(points):
        end = points[index + 1][0] if index + 1 < len(points) else TICKS
        if merged and merged[-1].note == note and merged[-1].end == tick:
            merged[-1] = Segment(note, merged[-1].start, end)
        else:
            merged.append(Segment(note, tick, end))
    return tuple(merged)


def parse(document: dict, path: Path | None = None) -> Score:
    if not isinstance(document, dict):
        raise ScoreError("a score is a JSON object")
    schema = document.get("schema")
    if schema != SCHEMA:
        raise ScoreError("schema %r is not %d" % (schema, SCHEMA))
    ticks = int(document.get("ticks", 0))
    if ticks != TICKS:
        raise ScoreError("ticks is %d; the loop is %d ticks (4 s at %d BPM)" % (ticks, TICKS, BAR_BPM))
    bpm = int(document.get("bpm", 0))
    if bpm != BAR_BPM:
        # arm() writes 0x08=120 and refuses to continue unless it reads back, so a
        # score at any other tempo would disagree with the bar it is drawn on.
        raise ScoreError("bpm is %d; recording forces %d" % (bpm, BAR_BPM))

    tracks = []
    seen = set()
    for entry in document.get("tracks", ()):
        index = int(entry.get("track", -1))
        if not 0 <= index <= 5:
            raise ScoreError("track %r is outside 0..5" % entry.get("track"))
        if index in seen:
            raise ScoreError("track %d appears twice" % index)
        seen.add(index)
        role = str(entry.get("role", ""))
        tracks.append(Track(index, role, _segments(entry.get("notes"), "track %d" % index)))
    if not tracks:
        raise ScoreError("the score has no tracks")
    return Score(str(document.get("name", path.stem if path else "score")), bpm, ticks, tuple(tracks), path)


def load(path) -> Score:
    path = Path(path)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ScoreError("cannot read %s: %s" % (path, exc)) from exc
    except json.JSONDecodeError as exc:
        raise ScoreError("%s is not valid JSON: %s" % (path.name, exc)) from exc
    return parse(document, path)
