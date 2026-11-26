from dataclasses import replace
import json
from pathlib import Path
from subprocess import CompletedProcess, STDOUT
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from tools.perf.analyze_player_handoff import map_read_stats, summarize
from tools.perf.run_rendered_player_handoff import (
    Recording, check_display_pacing, check_held_map_reads, compare_recordings, load_recording, run_sample,
)


def recording(committed):
    return [
        {"committed": day, "consumed": day, "usec": index * 1000,
         "frame_usec": 1000, "reason": "running", "admitted": day + 1,
         "wait_us": index * 100, "retry_us": index * 10,
         "admit_us": index * 100, "consume_us": index * 200,
         "visual_ms": index * 0.5, "ui_us": index * 50}
        for index, day in enumerate(committed)
    ]


def display_frame(**overrides):
    return {"draw_lag_days": [0], "view_updates": 1, "effective_max_fps": 60,
            "overload_us": 0, "received_batches": 1, "receive_us": 120,
            "climate_install_us": 600, "vision_install_us": 100, "cell_refresh_us": 500,
            "cell_encode_us": 230, "staged_publish_us": 1300, "immediate_texture_us": 0} | overrides


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

    def test_map_metrics_use_only_the_matched_draw_window(self):
        frames = recording([4, 5, 6, 7, 8, 9, 10])
        for frame in frames:
            frame.update(display_frame(draw_times=[frame["usec"] - 100]))
        frames[1].update(draw_lag_days=[20], receive_us=12_000, view_updates=3)
        frames[2].update(draw_lag_days=[2], receive_us=210, view_updates=0, overload_us=30_000)
        result = summarize(frames, self.daily, 5, 9, require_rendered=True)

        self.assertEqual(result["display_updates"], 3)
        self.assertEqual(result["display_updates_per_s"], 750)
        self.assertEqual(result["overload_frames"], 1)
        self.assertEqual(result["draw_timing"]["range_ms"], [1, 1])
        self.assertEqual(result["draw_display_lag_days"], {"samples": 4, "median": 0, "range": [0, 2]})
        self.assertEqual(result["step_timings"]["receive_us"],
                         {"samples": 4, "median_ms": 0.12, "p95_ms": 0.21, "range_ms": [0.12, 0.21]})
        self.assertEqual(result["step_timings"]["staged_publish_us"]["median_ms"], 1.3)

    def test_map_metrics_require_age_for_each_draw(self):
        frames = [row | display_frame(draw_times=[row["usec"] - 100]) for row in recording([4, 5, 6, 7, 8, 9])]
        frames[3]["draw_lag_days"] = []
        with self.assertRaisesRegex(ValueError, "each completed draw must have a display age"):
            summarize(frames, self.daily, 5, 9, require_rendered=True)


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

    def write_window(self, prefix, frames):
        config = {"display": "macOS", "driver": "metal", "speed": 50}
        result = {"end": "target", "contiguous": True, "written": True, "consumed_day": 2}
        prefix.with_suffix(".log").write_text(
            f"HANDOFF_CONFIG={json.dumps(config)}\nHANDOFF_RESULT={json.dumps(result)}\n")
        prefix.with_suffix(".jsonl.days").write_text('{"day":1}\n{"day":2}\n')
        prefix.with_suffix(".jsonl").write_text("".join(json.dumps(frame) + "\n" for frame in frames))

    def test_rejects_hidden_window_even_if_callbacks_were_delivered(self):
        with TemporaryDirectory() as directory:
            prefix = Path(directory) / "covered"
            self.write_window(prefix, [
                {"committed": 1, "window_drawable": True, "draw_times": [1000]},
                {"committed": 2, "window_drawable": False, "draw_times": [400000]},
            ])
            with self.assertRaisesRegex(ValueError, "window could not draw.*day 2"):
                load_recording(prefix, 50, 2)

    def test_requires_window_visibility_evidence(self):
        with TemporaryDirectory() as directory:
            prefix = Path(directory) / "unknown"
            self.write_window(prefix, [{"committed": 1, "draw_times": [1000]}])
            with self.assertRaisesRegex(ValueError, "window visibility was not recorded"):
                load_recording(prefix, 50, 2)

    def test_keeps_a_real_draw_gap_when_the_window_stays_visible(self):
        with TemporaryDirectory() as directory:
            prefix = Path(directory) / "drawable"
            frames = [
                {"committed": 1, "window_drawable": True, "draw_times": [1000]},
                {"committed": 1, "window_drawable": True, "draw_times": []},
                {"committed": 2, "window_drawable": True, "draw_times": [401000]},
            ]
            self.write_window(prefix, frames)
            self.assertEqual(load_recording(prefix, 50, 2).frames, frames)

    def test_pair_refuses_different_viewport_sizes(self):
        baseline = self.sample([4, 5, 6, 7, 8, 9, 10])
        resized = replace(baseline, config=self.config | {"viewport_size": "(1280, 800)"})
        with self.assertRaisesRegex(ValueError, "actual player settings differ: viewport_size"):
            compare_recordings(baseline, resized, [(5, 9)])

    def test_pair_refuses_a_trace_running_at_the_wrong_cap(self):
        baseline = self.sample([4, 5, 6, 7, 8, 9, 10])
        baseline.config = self.config | {"fps_mode": "30"}
        for frame in baseline.frames:
            frame.update(display_frame(draw_lag_days=[0] * len(frame.get("draw_times", []))))
            frame.setdefault("draw_times", [])
        with self.assertRaisesRegex(ValueError, "wrong frame limit"):
            compare_recordings(baseline, baseline, [(5, 9)])

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

    def test_map_read_comparison_rejects_a_recording_with_no_samples(self):
        baseline = self.sample([4, 5, 6, 7, 8, 9, 10])
        candidate = self.sample([4, 5, 6, 7, 8, 9, 10])
        for sample in (baseline, candidate):
            for frame in sample.frames:
                frame.update(map_copies=[], map_draw_times=frame.get("draw_times", []),
                             map_draw_lag_days=[0] * len(frame.get("draw_times", [])), panel_feedback=[])
            sample.frames[2]["panel_feedback"] = [{"usec": 900}]
        candidate.frames[2]["map_copies"] = [{"bytes": 4800, "ns": 750}]

        with self.assertRaisesRegex(ValueError, "requires an instrumented baseline"):
            compare_recordings(baseline, candidate, [(5, 9)])

        # The candidate recorded a copy after the held window. Zero in the
        # measured window is now evidence of a hold, not missing instrumentation.
        baseline.frames[2]["map_copies"] = candidate.frames[2]["map_copies"]
        candidate.frames[-1]["map_copies"] = candidate.frames[2]["map_copies"]
        candidate.frames[2]["map_copies"] = []
        window, = compare_recordings(baseline, candidate, [(5, 9)])
        self.assertEqual(window["baseline"]["map_reads"], 1)
        self.assertEqual(window["candidate"]["map_reads"], 0)


class RenderedHandoffLaunchTest(unittest.TestCase):
    def test_macos_launch_failure_preserves_system_error(self):
        def denied(command, *, stdout=None, stderr=None):
            if stdout is not None and stderr == STDOUT:
                stdout.write("LaunchServices -10827: kLSNoExecutableErr\n")
            return CompletedProcess(command, 1)

        with TemporaryDirectory() as directory:
            root = Path(directory)
            prefix = root / "baseline"
            with patch("tools.perf.run_rendered_player_handoff.subprocess.run", side_effect=denied):
                with self.assertRaisesRegex(ValueError, r"exited with 1.*baseline\.launch\.log"):
                    run_sample("godot", root, prefix, 50, 180, "30", True, Path("/Applications/Godot.app"))

            self.assertIn("LaunchServices -10827", prefix.with_suffix(".launch.log").read_text())
            self.assertEqual(json.loads(prefix.with_suffix(".run.json").read_text())["exit_code"], 1)
            self.assertFalse(prefix.with_suffix(".jsonl").exists())


class DisplayPacingTraceTest(unittest.TestCase):
    def setUp(self):
        self.frames = [
            display_frame(consumed=39, presented=39),
            display_frame(consumed=42, presented=39, view_updates=0, cell_refresh_us=0,
                          staged_publish_us=0, overload_us=17_000),
            display_frame(consumed=46, presented=46, overload_us=17_000),
            display_frame(consumed=57, presented=57),
        ]

    def test_receives_during_overload_merges_and_recovers(self):
        check_display_pacing(self.frames)

    def test_held_frame_rejects_a_copy_even_when_no_map_update_was_drawn(self):
        self.frames[1]["map_copies"] = [{"bytes": 4800, "ns": 900}]
        self.assertEqual(check_held_map_reads(self.frames, baseline=True),
                         {"frames": 1, "reads": 1, "bytes": 4800})
        with self.assertRaisesRegex(ValueError, "candidate copied"):
            check_held_map_reads(self.frames, baseline=False)
        self.frames[1]["map_copies"] = []
        self.assertEqual(check_held_map_reads(self.frames, baseline=False),
                         {"frames": 1, "reads": 0, "bytes": 0})
        with self.assertRaisesRegex(ValueError, "baseline did not copy"):
            check_held_map_reads(self.frames, baseline=True)

    def test_receiving_less_often_is_not_display_pacing(self):
        self.frames[1]["consumed"] = 39
        self.frames[1]["received_batches"] = 0
        with self.assertRaisesRegex(ValueError, "no overloaded frame received days"):
            check_display_pacing(self.frames)

    def test_busy_frame_that_flushes_a_staged_upload_does_not_count_as_held(self):
        self.frames[1].update(staged_publish_us=500, map_copies=[])
        with self.assertRaisesRegex(ValueError, "need a busy frame"):
            check_held_map_reads(self.frames, baseline=False)

    def test_applying_the_held_batch_separately_is_not_coalescing(self):
        self.frames[2]["presented"] = 42
        with self.assertRaisesRegex(ValueError, "never merged"):
            check_display_pacing(self.frames)

    def test_publishing_a_map_behind_the_receipts_is_not_recovery(self):
        self.frames[-1]["presented"] = 46
        with self.assertRaisesRegex(ValueError, "did not catch up"):
            check_display_pacing(self.frames)


class MapReadStatsTest(unittest.TestCase):
    def test_held_window_without_map_draws_still_reports_copies_and_feedback(self):
        held = {"map_copies": [], "panel_feedback": [{"usec": 900}],
                "map_draw_times": [], "map_draw_lag_days": []}
        recovery = {"map_copies": [{"bytes": 4800, "ns": 750}],
                    "panel_feedback": [], "map_draw_times": [3000], "map_draw_lag_days": [4]}
        result = map_read_stats([held], recording_frames=[held, recovery])
        self.assertEqual(result["map_reads"], 0)
        self.assertEqual(result["map_draw"]["samples"], 0)
        self.assertIsNone(result["map_draw_lag"])
        self.assertEqual(result["panel_feedback"]["median_ms"], 0.9)

        result = map_read_stats([recovery])
        self.assertEqual(result["map_draw"]["samples"], 0)
        self.assertEqual(result["map_draw_lag"],
                         {"samples": 1, "median": 4, "p95": 4, "range": [4, 4]})
        recovery["map_draw_lag_days"] = []
        with self.assertRaisesRegex(ValueError, "each actual map draw"):
            map_read_stats([recovery])

    def test_reports_copies_feedback_and_actual_map_draws_independently(self):
        frames = [
            {"map_copies": [{"bytes": 4800, "ns": 750}], "panel_feedback": [],
             "map_draw_times": [1000], "map_draw_lag_days": [0]},
            {"map_copies": [], "panel_feedback": [{"usec": 900}],
             "map_draw_times": [3000], "map_draw_lag_days": [4]},
        ]
        result = map_read_stats(frames)
        self.assertEqual(result["map_reads"], 1)
        self.assertEqual(result["map_copied_bytes"], 4800)
        self.assertEqual(result["map_copy"]["median_ms"], 0.00075)
        self.assertEqual(result["panel_feedback"]["median_ms"], 0.9)
        self.assertEqual(result["map_draw"]["median_ms"], 2.0)
        self.assertEqual(result["map_draw_lag"], {"samples": 2, "median": 2, "p95": 4, "range": [0, 4]})
        frames[0]["map_copies"][0]["ns"] = -1
        with self.assertRaisesRegex(ValueError, "requires an instrumented baseline"):
            map_read_stats(frames)
        frames[0]["map_copies"] = []
        with self.assertRaisesRegex(ValueError, "requires an instrumented baseline"):
            map_read_stats(frames)


if __name__ == "__main__":
    unittest.main()
