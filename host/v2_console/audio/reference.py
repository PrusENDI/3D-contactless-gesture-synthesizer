"""Host-side reference track: the v1 substitute for overdub monitoring.

During RECORD the FPGA is silent (voice_rst_n is held low outside PLAY), so the
PC sound card can own the room without fighting the DAC. Pitch comes from the
same note-increment ROM the hardware plays, and the envelope reuses the 0x94/0x98
step semantics, so the reference matches in pitch and timing -- not in timbre.
Filter and FX are deliberately left out (LOOP spec 7.5).
"""

from __future__ import annotations

import io
import wave
from dataclasses import dataclass

from host.v2_potts_reference import solve

SAMPLE_RATE = 48000
BAR_SECONDS = 4.0
BAR_TICKS = 32
TICKS_PER_SECOND = BAR_TICKS / BAR_SECONDS

# rtl/v2_note_increment_rom.sv, the only eight notes that are not silent.
ROM_INCREMENT = {
    55: 17537476,
    57: 19685267,
    60: 23409859,
    62: 26276679,
    64: 29494575,
    67: 35075158,
    69: 39370534,
    72: 46819719,
}


@dataclass(frozen=True)
class Segment:
    note: int
    start_tick: int
    end_tick: int


def frequency_of(note: int) -> float:
    """f = increment / 2**32 * 48000, the same arithmetic the phase accumulator runs."""
    return ROM_INCREMENT[note] / 2.0 ** 32 * SAMPLE_RATE


def segments_from_contour(contour) -> list[Segment]:
    """Ask the deterministic Potts reference which note each run fits to."""
    return [
        Segment(event.note, event.tick, min(BAR_TICKS, event.tick + event.duration))
        for event in solve(contour)
        if event.note in ROM_INCREMENT
    ]


def _envelope(env: dict, samples_in: int, total: int) -> float:
    """0x94/0x98 semantics: per-sample steps, bigger is faster."""
    attack = max(1, int(env.get("attack_step", 4096)))
    decay = max(0, int(env.get("decay_step", 256)))
    sustain = int(env.get("sustain_level", 49152)) / 65535.0
    release = max(1, int(env.get("release_step", 1024)))

    level = 0.0
    level = min(1.0, samples_in * attack / 65535.0) if samples_in * attack < 65535 else 1.0
    if level >= 1.0:
        fall = (samples_in - 65535 // attack) * decay
        level = max(sustain, 1.0 - fall / 65535.0)
    remaining = max(0, total - samples_in)
    if remaining * release < 65535:
        level = min(level, remaining * release / 65535.0)
    return max(0.0, level)


def render_wav(segments, table, voice_shift: int, env: dict) -> bytes:
    """One bar of int16 mono audio, ready for winsound's SND_LOOP."""
    total = int(SAMPLE_RATE * BAR_SECONDS)
    scale = 1.0 / (1 << max(0, min(15, voice_shift)))
    out = [0] * total

    for segment in segments:
        start = int(segment.start_tick * SAMPLE_RATE / TICKS_PER_SECOND)
        end = int(segment.end_tick * SAMPLE_RATE / TICKS_PER_SECOND)
        length = max(0, end - start)
        if length == 0:
            continue
        step = frequency_of(segment.note) * len(table) / SAMPLE_RATE
        phase = 0.0
        for index in range(length):
            position = start + index
            if position >= total:
                break
            sample = table[int(phase) % len(table)]
            gain = _envelope(env, index, length) * scale
            out[position] += int(sample * gain)
            phase += step

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(
            b"".join(max(-32768, min(32767, value)).to_bytes(2, "little", signed=True) for value in out)
        )
    return buffer.getvalue()


class _SilentBackend:
    def play(self, path: str) -> None:  # pragma: no cover - no audio device
        return None

    def stop(self) -> None:  # pragma: no cover - no audio device
        return None


class _WinsoundBackend:
    def __init__(self) -> None:
        import winsound  # noqa: F401  (import here so the module loads on any OS)

        self._winsound = winsound

    def play(self, path: str) -> None:
        flags = self._winsound.SND_FILENAME | self._winsound.SND_ASYNC | self._winsound.SND_LOOP
        self._winsound.PlaySound(path, flags)

    def stop(self) -> None:
        self._winsound.PlaySound(None, self._winsound.SND_PURGE)


def default_backend():
    try:
        return _WinsoundBackend()
    except Exception:  # no audio device, or not Windows
        return _SilentBackend()


class Player:
    """Loops one bar of WAV. Restart it every time the bar is forced."""

    def __init__(self, backend=None):
        self._backend = backend if backend is not None else default_backend()

    def play(self, path: str) -> None:
        self._backend.play(path)

    def stop(self) -> None:
        self._backend.stop()
