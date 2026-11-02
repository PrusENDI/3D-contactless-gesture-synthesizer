"""Reference audio: the host plays the bar while the FPGA records blind."""

import io
import unittest
import wave

from host.v2_console.audio import reference

TABLE = [int(32767 * 0.9 * __import__("math").sin(2 * 3.141592653589793 * i / 1024)) for i in range(1024)]
ENV = {"attack_step": 4096, "decay_step": 256, "sustain_level": 49152, "release_step": 1024}


class FormatTest(unittest.TestCase):
    def test_wav_is_four_seconds_at_48k_mono_16bit(self):
        payload = reference.render_wav(
            [reference.Segment(60, 0, 31)], table=TABLE, voice_shift=2, env=ENV
        )
        with wave.open(io.BytesIO(payload)) as handle:
            self.assertEqual(
                (handle.getframerate(), handle.getnchannels(), handle.getsampwidth(), handle.getnframes()),
                (48000, 1, 2, 192000),
            )

    def test_empty_segments_still_render_a_bar_of_silence(self):
        payload = reference.render_wav([], table=TABLE, voice_shift=2, env=ENV)
        with wave.open(io.BytesIO(payload)) as handle:
            self.assertEqual(handle.getnframes(), 192000)


class PitchTest(unittest.TestCase):
    def test_frequency_comes_from_the_rom_increment(self):
        # C4: increment 23409859 / 2**32 * 48000 = 261.63 Hz
        self.assertAlmostEqual(reference.frequency_of(60), 261.63, places=2)

    def test_every_note_in_the_rom_is_playable(self):
        for note in (55, 57, 60, 62, 64, 67, 69, 72):
            self.assertGreater(reference.frequency_of(note), 100.0)


class SegmentTest(unittest.TestCase):
    def test_segments_cover_the_bar_in_order(self):
        segments = reference.segments_from_contour([300] * 32)
        self.assertTrue(segments)
        self.assertGreaterEqual(segments[0].start_tick, 0)
        self.assertLessEqual(segments[-1].end_tick, 32)

    def test_a_gap_is_a_rest_not_a_note(self):
        # Half the bar has no hand in the field; the hardware commits a rest there,
        # so the reference must not invent the lowest pitch.
        segments = reference.segments_from_contour([300] * 16 + [0] * 16)
        for segment in segments:
            self.assertLess(segment.end_tick, 32)
            self.assertLessEqual(segment.start_tick, 16)


class PlayerTest(unittest.TestCase):
    def test_player_forwards_to_its_backend(self):
        class Fake:
            def __init__(self):
                self.calls = []

            def play(self, path):
                self.calls.append(("play", path))

            def stop(self):
                self.calls.append(("stop", None))

        backend = Fake()
        player = reference.Player(backend=backend)
        player.play("bar.wav")
        player.stop()
        self.assertEqual(backend.calls, [("play", "bar.wav"), ("stop", None)])

    def test_default_backend_never_raises_without_audio(self):
        reference.Player().stop()


if __name__ == "__main__":
    unittest.main()
