from dataclasses import replace
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tools.perf.analyze_player_handoff import summarize
from tools.perf.run_rendered_player_handoff import Recording, compare_recordings, load_recording


def recording(committed):
    return [
        {"committed": day, "consumed": day, "usec": index * 1000,
         "frame_usec": 1000, "reason": "running", "admitted": day + 1,
         "wait_us": index * 100, "retry_us": index * 10,
         "admit_us": index * 100, "consume_us": index * 200,
         "visual_ms": index * 0.5, "ui_us": index * 50}
        for index, day in enumerate(committed)
    ]


class HandoffWindowTest(unittest.TestCase):
    daily = {day: {"produced_at_us": day * 2000} for day in range(4, 11)}

    def test_rejects_skipped_first_day_even_with_daily_record(self):
        with self.assertRaisesRegex(ValueError, r"day 5.*skipped.*4.*6"):
            summarize(recording([4, 6, 7, 8, 9, 10]), self.daily, 5, 9)

    def test_rejects_skipped_last_day_even_with_daily_record(self):
        with self.assertRaisesRegex(ValueError, r"day 9.*skipped.*8.*10"):
            summarize(recording([4, 5, 6, 7, 8, 10]), self.daily, 5, 9)

    def test_exact_endpoints_allow_days_to_share_an_interior_frame(self):
        frames = recording([4, 5, 5, 7, 9, 9, 10])
        frames[1]["frame_usec"] = 80_000
        frames[5]["frame_usec"] = 90_000
        frames[2]["reason"] = "calendar_wait"
        result = summarize(frames, self.daily, 5, 9)

        self.assertEqual(result["days_per_s"], 500.0)
        self.assertEqual(result["frames"], 3)
        self.assertEqual(result["frame_p95_ms"], 1.0)
        self.assertEqual(result["calendar_wait_total_ms"], 0.3)
        self.assertEqual(result["input_retry_total_ms"], 0.03)
        self.assertEqual(result["observed_waits"]["calendar_wait"], {"count": 1, "max_ms": 1.0})
        self.assertEqual(result["admit_median_ms"], 0.3)
        self.assertEqual(result["consume_median_ms"], 0.7)
        self.assertEqual(result["visual_apply_median_ms"], 1.5)
        self.assertEqual(result["ui_median_ms"], 0.15)

    def test_draw_intervals_use_only_draws_within_the_exact_window(self):
        frames = recording([4, 5, 5, 7, 9, 9, 10])
        frames[1]["draw_times"] = [50]
        frames[2]["draw_times"] = [1900]
        frames[4]["draw_times"] = [3900]
        frames[5]["draw_times"] = [4990]
        result = summarize(frames, self.daily, 5, 9, require_rendered=True)

        self.assertEqual(result["frames"], 3)
        self.assertEqual(result["frame_p95_ms"], 1.0)
        self.assertEqual(result["draw_intervals"], 1)
        self.assertEqual(result["draw_p95_ms"], 2.0)

    def test_rendered_window_rejects_a_headless_recording(self):
        with self.assertRaisesRegex(ValueError, "fewer than two completed draws"):
            summarize(recording([4, 5, 6, 7, 8, 9, 10]), self.daily, 5, 9, require_rendered=True)


class RenderedHandoffComparisonTest(unittest.TestCase):
    config = {"display": "macOS", "driver": "metal", "viewport_size": "(1600, 960)", "speed": 50}
    daily = HandoffWindowTest.daily

    def sample(self, committed):
        frames = recording(committed)
        for frame in frames[1:]:
            frame["draw_times"] = [frame["usec"] - 100]
        return Recording(self.config, frames, self.daily)

    def test_pair_requires_completed_draws_on_both_sides(self):
        baseline = self.sample([4, 5, 6, 7, 8, 9, 10])
        undrawn = replace(baseline, frames=recording([4, 5, 6, 7, 8, 9, 10]))
        with self.assertRaisesRegex(ValueError, "fewer than two completed draws"):
            compare_recordings(baseline, undrawn, [(5, 9)])

    def test_rejects_headless_even_with_a_graphics_driver_name(self):
        # Godot can report "metal" even when DisplayServer is headless.
        with TemporaryDirectory() as directory:
            prefix = Path(directory) / "headless"
            prefix.with_suffix(".log").write_text(
                'HANDOFF_CONFIG={"display":"headless","driver":"metal","speed":50}\n')
            with self.assertRaisesRegex(ValueError, "used no window renderer"):
                load_recording(prefix, 50, 180)

    def test_pair_refuses_different_viewport_sizes(self):
        baseline = self.sample([4, 5, 6, 7, 8, 9, 10])
        resized = replace(baseline, config=self.config | {"viewport_size": "(1280, 800)"})
        with self.assertRaisesRegex(ValueError, "actual player settings differ: viewport_size"):
            compare_recordings(baseline, resized, [(5, 9)])

    def test_pair_reports_draw_and_wait_timing_at_shared_boundaries(self):
        baseline = self.sample([4, 5, 6, 6, 7, 8, 9, 10])
        candidate = self.sample([4, 6, 6, 7, 8, 10])
        baseline.frames[3]["reason"] = "calendar_wait"
        window, = compare_recordings(baseline, candidate, [(5, 9)])

        self.assertEqual(window["requested_days"], [5, 9])
        for side in ("baseline", "candidate"):
            self.assertEqual(window[side]["first_day"], 6)
            self.assertEqual(window[side]["last_day"], 8)
            self.assertEqual(window[side]["draw_p95_ms"], 1.0)
        self.assertEqual(window["baseline"]["observed_waits"]["calendar_wait"], {"count": 1, "max_ms": 1.0})
        self.assertEqual(window["candidate"]["observed_waits"]["calendar_wait"], {"count": 0, "max_ms": 0.0})


if __name__ == "__main__":
    unittest.main()
