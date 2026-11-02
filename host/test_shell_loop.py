"""The LOOP page's three buttons drive the state machine that was proven on the board."""

import time
import unittest
from types import SimpleNamespace

from host.v2_console import frames
from host.v2_console.session import record_flow
from host.v2_console.views.shell import ConsoleModel


class FakeFlow:
    def __init__(self, session, track=0):
        self.session = session
        self.track = track
        self.state = record_flow.IDLE
        self.calls = []
        self.contour_result = [100] * 32
        self.committed = 4
        self.verdict = "ok"

    def arm(self):
        self.calls.append("arm")
        self.state = record_flow.ARMED

    def poll(self):
        self.calls.append("poll")
        if self.state == record_flow.ARMED:
            self.state = record_flow.CAPTURED
        return self.state

    def contour(self):
        self.calls.append("contour")
        return list(self.contour_result)

    def accept_take(self, contour):
        self.calls.append("accept")
        if self.verdict == "ok":
            self.state = record_flow.REVIEWED
        return self.verdict

    def commit(self, timeout_s=15.0):
        self.calls.append("commit")
        self.state = record_flow.PUBLISHING
        return self.committed

    def publish(self, timeout_s=15.0):
        self.calls.append("publish")
        self.state = record_flow.ROLLED


class FakeSession:
    identity = SimpleNamespace(mode=0)

    def __init__(self):
        self.writes = []

    def status(self):
        return SimpleNamespace(mode=0, loop_active=False, fault=0)

    def write(self, addr, data):
        self.writes.append((addr, data))
        return SimpleNamespace(nack=False, err=0)


def model_with_flow(flow_cls=FakeFlow):
    session = FakeSession()
    model = ConsoleModel(session)
    model.flow_factory = flow_cls
    return model, session


class ArmTest(unittest.TestCase):
    def test_arm_builds_a_flow_for_the_selected_track_and_anchors_the_bar(self):
        model, _ = model_with_flow()
        message = model.arm_take(track=2)
        self.assertEqual(model.flow.track, 2)
        self.assertIn("arm", model.flow.calls)
        self.assertIn("armed", message.lower())
        self.assertIsNotNone(model.phase._t0)

    def test_a_take_is_captured_and_stored_in_its_own_slot(self):
        model, _ = model_with_flow()
        model.arm_take(track=1)
        model.wait_for_take(timeout_s=0.5)
        message = model.capture_contour()
        self.assertEqual(len(model.contours[1]), 32)
        self.assertIn("32", message)

    def test_a_take_that_fails_the_coverage_gate_is_not_stored(self):
        model, _ = model_with_flow()
        model.flow_factory = lambda session, track: FakeFlow(session, track)
        model.arm_take(track=0)
        model.flow.verdict = "retry"
        model.wait_for_take(timeout_s=0.5)
        message = model.capture_contour()
        self.assertEqual(model.contours, {})
        self.assertIn("retry", message.lower())


class RecordFeedbackTest(unittest.TestCase):
    """A take has to be visible while it runs: the worker cannot report its own progress."""

    def test_arming_marks_the_take_as_running(self):
        model, _ = model_with_flow()
        model.arm_take(track=1)
        self.assertEqual(model.record_state, "armed")
        self.assertEqual(model.record_track, 1)

    def test_progress_runs_from_zero_to_one_across_the_bar(self):
        model, _ = model_with_flow()
        model.arm_take(track=0)
        model.record_started = time.monotonic()
        self.assertLess(model.record_progress(), 0.05)
        model.record_started = time.monotonic() - model.record_seconds
        self.assertAlmostEqual(model.record_progress(), 1.0, places=2)
        self.assertEqual(model.record_ticks(), 32)

    def test_a_captured_take_says_so(self):
        model, _ = model_with_flow()
        model.arm_take(track=0)
        model.wait_for_take(timeout_s=0.5)
        model.capture_contour()
        self.assertEqual(model.record_state, "captured")

    def test_a_refused_take_says_so(self):
        model, _ = model_with_flow()
        model.arm_take(track=0)
        model.flow.verdict = "retry"
        model.wait_for_take(timeout_s=0.5)
        model.capture_contour()
        self.assertEqual(model.record_state, "failed")


    def test_the_take_timeout_covers_the_board_really_taking_eight_seconds(self):
        # Measured: FULL lands 7.9 s after the arm (four takes, spread 0.07 s). An
        # 8 s deadline raced the board and threw away every fourth take.
        import inspect

        model, _ = model_with_flow()
        default = inspect.signature(model.wait_for_take).parameters["timeout_s"].default
        self.assertGreater(default, 8.5)


class CommitTest(unittest.TestCase):
    def test_commit_then_publish_reports_the_event_count_and_reanchors(self):
        model, _ = model_with_flow()
        model.arm_take(track=0)
        model.wait_for_take(timeout_s=0.5)
        model.capture_contour()
        message = model.commit_take()
        self.assertIn("4", message)
        model.publish_take()
        self.assertIsNotNone(model.phase._t0)

    def test_commit_without_a_take_is_refused(self):
        model, _ = model_with_flow()
        with self.assertRaises(RuntimeError):
            model.commit_take()


if __name__ == "__main__":
    unittest.main()
