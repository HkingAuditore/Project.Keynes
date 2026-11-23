import unittest

from tools.perf.analyze_player_handoff import summarize


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


if __name__ == "__main__":
    unittest.main()
