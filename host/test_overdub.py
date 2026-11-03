"""Host-side overdub: the board records blind, so the host plays the finished takes.

Nothing here talks to the board. The signal path is contours -> one 4 s bar ->
the player backend, which is exactly the part that can be proven without a hand.
"""

import io
import math
import tempfile
import unittest
import wave
from pathlib import Path

from host.v2_console import score as score_mod
from host.v2_console.audio import reference
from host.v2_console.views.shell import ConsoleModel

SCORE = score_mod.load(score_mod.SCORE_DIR / "c-am-vamp-4s.json")
# y level per note: the centre of that note's y interval, the same table the
# Potts solver fits against (host/v2_potts_reference.LEVELS).  64/69/72 are the
# old degrees the score still names; the map no longer commits them, so they
# alias the nearest degree of G natural minor (64->62, 69->65, 72->67).
LEVEL = {55: 30, 57: 135, 58: 286, 60: 421, 62: 557, 63: 707, 65: 858, 67: 978,
         64: 557, 69: 858, 72: 978}
TABLE = [int(8191 * math.sin(2.0 * math.pi * index / 1024)) for index in range(1024)]
ENV = {"attack_step": 4096, "decay_step": 256, "sustain_level": 49152, "release_step": 1024}


def contour_of(track):
    return [LEVEL[note] for note in SCORE.targets(track)]


def samples_of(payload, count=19200):
    with wave.open(io.BytesIO(payload)) as handle:
        raw = handle.readframes(count)
    return [int.from_bytes(raw[index : index + 2], "little", signed=True)
            for index in range(0, len(raw), 2)]


def amplitude(payload):
    return max(abs(value) for value in samples_of(payload, 192000))


def energy_at(values, frequency):
    """Hand-rolled single-bin DFT: enough to say 'this note is in the mix'."""
    step = 2.0 * math.pi * frequency / reference.SAMPLE_RATE
    real = imag = 0.0
    for index, value in enumerate(values):
        real += value * math.cos(step * index)
        imag += value * math.sin(step * index)
    return math.hypot(real, imag) / max(1, len(values))


class FakePlayer:
    def __init__(self):
        self.calls = []

    def play(self, path):
        self.calls.append(("play", path))

    def stop(self):
        self.calls.append(("stop", None))


class MixTest(unittest.TestCase):
    def test_the_mix_holds_every_take_not_just_the_first(self):
        mix = reference.mix_contours({0: contour_of(0), 1: contour_of(1)})
        self.assertEqual({segment.note for segment in mix}, {55, 57, 60})

    def test_the_mix_really_sounds_both_notes(self):
        mix = reference.mix_contours({0: contour_of(0), 1: contour_of(1)})
        payload = reference.render_wav(mix, table=TABLE, voice_shift=2, env=ENV)
        values = samples_of(payload)
        bass = energy_at(values, reference.frequency_of(55))
        pedal = energy_at(values, reference.frequency_of(60))
        absent = energy_at(values, reference.frequency_of(67))
        self.assertGreater(bass, 20 * absent)
        self.assertGreater(pedal, 20 * absent)

    def test_one_bar_of_mix_is_still_exactly_four_seconds(self):
        mix = reference.mix_contours({0: contour_of(0), 1: contour_of(1), 2: contour_of(2)})
        payload = reference.render_wav(mix, table=TABLE, voice_shift=2, env=ENV)
        with wave.open(io.BytesIO(payload)) as handle:
            self.assertEqual(handle.getnframes(), 192000)
            self.assertEqual(handle.getframerate(), 48000)

    def test_an_empty_mix_is_an_empty_list(self):
        self.assertEqual(reference.mix_contours({}), [])


class HeadroomTest(unittest.TestCase):
    def test_headroom_grows_with_the_number_of_takes(self):
        self.assertEqual([reference.headroom(count) for count in (1, 2, 3, 4, 5)], [0, 1, 2, 2, 3])

    def test_two_bits_of_headroom_quarter_the_amplitude(self):
        segments = [reference.Segment(60, 0, 32)]
        loud = amplitude(reference.render_wav(segments, table=TABLE, voice_shift=2, env=ENV))
        quiet = amplitude(
            reference.render_wav(segments, table=TABLE, voice_shift=2, env=ENV, extra_shift=2)
        )
        self.assertGreater(loud, 0)
        self.assertAlmostEqual(quiet / loud, 0.25, places=3)


class LoudnessTest(unittest.TestCase):
    """What was audible on track 1 must still be audible on track 4."""

    def test_normalising_keeps_a_one_take_and_a_four_take_mix_equally_loud(self):
        one = [reference.Segment(60, 0, 32)]
        four = [reference.Segment(55, 0, 32), reference.Segment(60, 0, 32),
                reference.Segment(64, 8, 32), reference.Segment(67, 16, 32)]
        quiet = amplitude(reference.render_wav(one, table=TABLE, voice_shift=2, env=ENV,
                                               normalize=True))
        loud = amplitude(reference.render_wav(four, table=TABLE, voice_shift=2, env=ENV,
                                              normalize=True))
        self.assertAlmostEqual(loud / quiet, 1.0, places=2)

    def test_without_normalising_the_mix_does_get_quieter(self):
        one = reference.render_wav([reference.Segment(60, 0, 32)], table=TABLE,
                                   voice_shift=2, env=ENV, extra_shift=0)
        four = reference.render_wav([reference.Segment(60, 0, 32)], table=TABLE,
                                    voice_shift=2, env=ENV, extra_shift=2)
        self.assertAlmostEqual(amplitude(four) / amplitude(one), 0.25, places=2)

    def test_normalising_never_clips(self):
        four = [reference.Segment(note, 0, 32) for note in (55, 60, 64, 67)]
        payload = reference.render_wav(four, table=TABLE, voice_shift=0, env=ENV, normalize=True)
        self.assertLessEqual(amplitude(payload), int(0.5 * 32767) + 1)


class DefaultTableTest(unittest.TestCase):
    def test_the_fallback_table_is_the_shape_the_board_starts_with(self):
        table = reference.sine_table()
        self.assertEqual(len(table), 1024)
        self.assertEqual(max(table), 32767)
        self.assertLess(min(table), 0)

    def test_a_monitor_without_an_upload_still_renders(self):
        payload = reference.render_wav(
            [reference.Segment(60, 0, 32)], table=reference.sine_table(), voice_shift=2, env=ENV
        )
        self.assertGreater(amplitude(payload), 100)


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.model = ConsoleModel(None)
        self.player = FakePlayer()
        self.model.player = self.player
        self.model.contours = {0: contour_of(0), 1: contour_of(1)}

    def test_the_first_take_has_nothing_to_play_along(self):
        model = ConsoleModel(None)
        model.player = FakePlayer()
        with self.assertRaises(RuntimeError):
            model.start_overdub()
        model.play_overdub()
        self.assertEqual(model.player.calls, [])

    def test_preparing_renders_but_does_not_play_yet(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / "overdub.wav")
            self.model.start_overdub(path=path)
            self.assertEqual(self.player.calls, [])
            with wave.open(path) as handle:
                self.assertEqual(handle.getnframes(), 192000)

    def test_playing_then_stopping_reaches_the_backend(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / "overdub.wav")
            self.model.start_overdub(path=path)
            self.model.play_overdub()
            self.assertTrue(self.model.overdubbing)
            self.model.stop_overdub()
            self.assertFalse(self.model.overdubbing)
        self.assertEqual(self.player.calls, [("play", path), ("stop", None)])

    def test_stopping_twice_does_not_reach_the_backend_twice(self):
        with tempfile.TemporaryDirectory() as folder:
            self.model.start_overdub(path=str(Path(folder) / "overdub.wav"))
            self.model.play_overdub()
            self.model.stop_overdub()
            self.model.stop_overdub()
        self.assertEqual(self.player.calls, [("play", self.model.overdub_path), ("stop", None)])


class OrderTest(unittest.TestCase):
    """The whole timing argument is in the order of these six calls."""

    def setUp(self):
        self.model = ConsoleModel(None)
        self.model.record_offset = 0.0        # the window wait is not what this tests
        self.model.contours = {0: contour_of(0)}
        self.order = []
        model = self.model

        def render(**_kwargs):
            self.order.append("render")
            model.overdub_path = "stub.wav"      # what start_overdub would leave behind

        model.start_overdub = render
        model.arm_take = lambda track: self.order.append("arm")
        model.play_overdub = lambda: self.order.append("play")
        model.wait_for_take = lambda: self.order.append("wait")
        model.capture_contour = lambda: self.order.append("capture") or "captured"
        model.stop_overdub = lambda: self.order.append("stop")

    def test_render_happens_before_the_bar_is_forced(self):
        self.model.armed_take(2)
        self.assertEqual(self.order, ["render", "arm", "play", "wait", "capture", "stop"])

    def test_a_refused_take_still_stops_the_monitor(self):
        def explode():
            self.order.append("capture")
            raise RuntimeError("take refused")

        self.model.capture_contour = explode
        with self.assertRaises(RuntimeError):
            self.model.armed_take(2)
        self.assertEqual(self.order[-1], "stop")

    def test_the_monitor_can_be_switched_off_per_take(self):
        self.model.armed_take(2, overdub=False)
        self.assertEqual(self.order, ["arm", "wait", "capture", "stop"])


if __name__ == "__main__":
    unittest.main()
