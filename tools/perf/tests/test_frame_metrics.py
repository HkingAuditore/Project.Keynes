"""Contract tests for tools/perf/frame_metrics.py.

The point of these tests is that the numbers in a performance report are defined
by code, not by whoever reads the CSV last. Each test pins one definition from
the module docstring, plus the cross-check that `percentile` agrees with the
`pct()` already shipped in analyze_android_perf.py (two files quoting one
percentile must not drift apart).
"""
import sys
import unittest
from pathlib import Path

PERF = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERF))

import frame_metrics as fm  # noqa: E402
import analyze_android_perf as aap  # noqa: E402

BUDGET = 1000.0 / 60.0


class PercentileTest(unittest.TestCase):
    def test_matches_existing_pct_helper(self):
        series = [16.7, 33.4, 8.1, 41.2, 16.8, 16.6, 25.0, 50.5, 12.0]
        for q in (0.0, 0.05, 0.5, 0.95, 0.99, 1.0):
            self.assertAlmostEqual(fm.percentile(series, q),
                                   aap.pct(series, q), places=9)

    def test_p99_of_one_to_hundred(self):
        self.assertAlmostEqual(fm.percentile(list(range(1, 101)), 0.99), 99.01)

    def test_empty_and_single(self):
        self.assertIsNone(fm.percentile([], 0.5))
        self.assertEqual(fm.percentile([7.5], 0.99), 7.5)

    def test_q_outside_range_is_clamped(self):
        self.assertEqual(fm.percentile([1.0, 2.0, 3.0], -1.0), 1.0)
        self.assertEqual(fm.percentile([1.0, 2.0, 3.0], 2.0), 3.0)


class DroppedFrameTest(unittest.TestCase):
    def test_frame_at_budget_is_not_a_drop(self):
        self.assertEqual(fm.dropped_frames([BUDGET], BUDGET), 0)
        self.assertEqual(fm.dropped_frames([BUDGET - 0.001], BUDGET), 0)

    def test_tolerance_absorbs_nanosecond_quantization(self):
        # A perfect 60 Hz frame measured from ns timestamps is 16.666667 ms,
        # which is 3e-7 ms over the float budget. Without tolerance that marks a
        # smooth run as 100% dropped -- the bug this test exists for.
        smooth = [16666667 / 1e6] * 300
        self.assertEqual(fm.dropped_frames(smooth, BUDGET), 0)
        self.assertEqual(fm.dropped_frames(smooth, BUDGET, 0.0), 300)

    def test_tolerance_is_optional(self):
        late = [BUDGET + 0.2]
        self.assertEqual(fm.dropped_frames(late, BUDGET), 0)
        self.assertEqual(fm.dropped_frames(late, BUDGET, 0.0), 1)
        self.assertEqual(fm.dropped_frames([BUDGET + 0.6], BUDGET), 1)

    def test_counts_and_percentage_in_stats(self):
        frames = [16.0, 16.0, 40.0, 16.0, 100.0]
        stats = fm.frame_stats(frames, BUDGET)
        self.assertEqual(stats["dropped"]["frames"], 2)
        self.assertAlmostEqual(stats["dropped"]["pct"], 40.0, places=2)

    def test_missed_vsyncs_accounts_for_long_frames(self):
        # 40 ms on a 60 Hz budget misses one slot; 100 ms misses five.
        self.assertEqual(fm.missed_vsyncs([40.0], BUDGET), 1)
        self.assertEqual(fm.missed_vsyncs([100.0], BUDGET), 5)
        self.assertEqual(fm.missed_vsyncs([16.0, 16.0], BUDGET), 0)

    def test_bad_budget_rejected(self):
        with self.assertRaises(ValueError):
            fm.missed_vsyncs([16.0], 0)


class JankRunTest(unittest.TestCase):
    def test_finds_all_runs_in_order(self):
        frames = [16.0, 30.0, 30.0, 16.0, 50.0]
        runs = fm.jank_runs(frames, BUDGET)
        self.assertEqual([(r["start_index"], r["frames"]) for r in runs],
                         [(1, 2), (4, 1)])

    def test_longest_ignores_single_frame_spikes(self):
        frames = [200.0, 16.0, 30.0, 30.0, 30.0, 16.0]
        # The 200 ms spike is longer in ms; as a stutter segment the 3-run wins.
        self.assertEqual(fm.longest_jank_run(frames, BUDGET, 1)["frames"], 1)
        self.assertEqual(fm.longest_jank_run(frames, BUDGET, 2)["frames"], 3)

    def test_run_carries_index_and_seconds(self):
        frames = [16.0] * 4 + [40.0, 40.0] + [16.0] * 2
        stamps = [i * BUDGET / 1000.0 for i in range(len(frames))]
        stats = fm.frame_stats(frames, BUDGET, stamps)
        run = stats["jank_run_longest"]
        self.assertEqual(run["start_index"], 4)
        self.assertEqual(run["end_index"], 5)
        self.assertEqual(run["frames"], 2)
        self.assertAlmostEqual(run["ms"], 80.0, places=2)
        # 4 frames earlier, one budget each.
        self.assertAlmostEqual(run["start_s"], 4 * BUDGET / 1000.0, places=3)

    def test_no_runs_on_smooth_series(self):
        self.assertIsNone(fm.longest_jank_run([16.0] * 50, BUDGET))
        self.assertEqual(fm.jank_runs([16.0] * 50, BUDGET), [])


class FrameStatsTest(unittest.TestCase):
    def test_full_report_shape(self):
        frames = [16.0] * 90 + [40.0, 40.0] + [16.0] * 8
        stamps = [i / 60.0 for i in range(len(frames))]
        stats = fm.frame_stats(frames, BUDGET, stamps)
        self.assertEqual(stats["frames"], 100)
        self.assertAlmostEqual(stats["coverage_s"], (99 / 60.0), places=3)
        for key in ("p50", "p95", "p99", "max", "min", "mean"):
            self.assertIn(key, stats["frame_ms"])
        self.assertEqual(stats["jank_runs_total"], 1)
        self.assertEqual(stats["jank_runs_stutter"], 1)
        self.assertEqual(stats["worst"][0]["index"], 90)
        self.assertIn("at_s", stats["worst"][0])

    def test_p99_separates_hitch_from_p95(self):
        # 95 smooth frames and 5 hitches: p95 hides them, p99 does not.
        frames = [16.0] * 95 + [55.0] * 5
        stats = fm.frame_stats(frames, BUDGET)
        self.assertLess(stats["frame_ms"]["p95"], 30.0)
        self.assertGreater(stats["frame_ms"]["p99"], 40.0)

    def test_empty_series(self):
        stats = fm.frame_stats([], BUDGET)
        self.assertEqual(stats["frames"], 0)
        self.assertIsNone(stats["coverage_s"])

    def test_timestamp_length_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            fm.frame_stats([16.0, 16.0], BUDGET, [0.0])

    def test_without_timestamps_still_reports_numbers(self):
        stats = fm.frame_stats([16.0, 40.0, 40.0], BUDGET)
        self.assertEqual(stats["frames"], 3)
        self.assertNotIn("start_s", stats["jank_run_longest"])


class BucketTest(unittest.TestCase):
    def test_frames_land_in_the_right_second(self):
        # Buckets are relative to the first timestamp, so these fall in 0s and 2s;
        # the empty second between them is not emitted (nothing happened there).
        frames = [16.0, 16.0, 40.0, 16.0]
        stamps = [0.1, 0.9, 2.4, 2.6]
        buckets = fm.bucket_report(frames, stamps, 1.0, BUDGET)
        self.assertEqual([b["frames"] for b in buckets], [2, 2])
        self.assertEqual([b["dropped"] for b in buckets], [0, 1])
        self.assertAlmostEqual(buckets[0]["from_s"], 0.0)
        self.assertAlmostEqual(buckets[1]["from_s"], 2.0)

    def test_rejects_mismatched_input(self):
        with self.assertRaises(ValueError):
            fm.bucket_report([16.0], [0.0, 1.0], 1.0, BUDGET)


class ParseSourceTest(unittest.TestCase):
    def test_surfaceflinger_latency_triplets(self):
        refresh = 16666667
        base = 1000000000
        present = [base, base + refresh, base + 2 * refresh, base + 5 * refresh]
        lines = [str(refresh)]
        for stamp in present:
            lines.append(f"{stamp} {stamp} {stamp - 1000000}")
        frames, stamps, meta = fm.parse_frame_source("\n".join(lines))
        self.assertEqual(meta["shape"], "surfaceflinger")
        self.assertEqual(len(frames), 3)          # n presents -> n-1 deltas
        self.assertAlmostEqual(frames[0], refresh / 1e6, places=3)
        self.assertAlmostEqual(frames[2], 3 * refresh / 1e6, places=3)
        self.assertIsNotNone(stamps)
        self.assertAlmostEqual(stamps[0], 0.0, places=6)

    def test_surfaceflinger_skips_pending_rows(self):
        refresh = 16666667
        lines = [str(refresh),
                 f"{0} {2**63 - 1} {0}",
                 f"{1000000000} {1000000000} {999000000}",
                 f"{1016666667} {1016666667} {1015666667}"]
        frames, _, _ = fm.parse_frame_source("\n".join(lines))
        self.assertEqual(len(frames), 1)
        self.assertAlmostEqual(frames[0], refresh / 1e6, places=3)

    def test_timestamped_pairs(self):
        text = "0.000,16.7\n0.017,40.0\n0.057,16.7"
        frames, stamps, meta = fm.parse_frame_source(text)
        self.assertEqual(meta["shape"], "timestamped")
        self.assertEqual(frames, [16.7, 40.0, 16.7])
        self.assertEqual([round(s, 3) for s in stamps], [0.0, 0.017, 0.057])

    def test_bare_ms_per_line(self):
        frames, stamps, meta = fm.parse_frame_source("16.7\n16.6\n50.0\n")
        self.assertEqual(frames, [16.7, 16.6, 50.0])
        self.assertIsNone(stamps)
        self.assertEqual(meta["shape"], "bare_ms")

    def test_surfaceflinger_stamps_are_seconds_not_ms(self):
        refresh = 16666667
        base = 5000000000
        lines = [str(refresh)]
        for index in range(60):
            stamp = base + index * refresh
            lines.append(f"{stamp} {stamp} {stamp - 3000000}")
        frames, stamps, meta = fm.parse_frame_source("\n".join(lines))
        self.assertEqual(meta["refresh_ms"], 16.6667)
        # 58 deltas of one refresh period = 0.967 s, not 967 s.
        self.assertAlmostEqual(stamps[-1], 58 * refresh / 1e9, places=3)
        self.assertLess(stamps[-1], 2.0)

    def test_repeated_samples_are_stitched_without_fake_freeze(self):
        # `--latency` only covers the last ~128 frames, so a run is sampled again
        # and again. The jump between blocks must NOT become one giant frame.
        refresh = 16666667
        lines = []
        for block in range(3):
            lines.append(str(refresh))
            base = 100000000000 + block * 1000000000   # 1 s between samples
            for index in range(20):
                stamp = base + index * refresh
                lines.append(f"{stamp} {stamp} {stamp - 3000000}")
        frames, stamps, meta = fm.parse_frame_source("\n".join(lines))
        self.assertEqual(meta["blocks"], 3)
        self.assertEqual(len(frames), 3 * 19)
        self.assertTrue(all(f < refresh * 1.5 / 1e6 for f in frames),
                        f"a block boundary leaked into frame times: {max(frames)}")
        self.assertEqual(sorted(stamps), stamps, "timestamps must stay monotonic")

    def test_ignores_logcat_noise(self):
        text = ("11-25 10:44:27.123  1234  1234 I Godot : [heartbeat] day=3 fps=57.2\n"
                "16.7\n11-25 10:44:32.001  1234  1234 I Godot : [heartbeat] day=3 fps=58.0\n"
                "16.8\n")
        frames, _, _ = fm.parse_frame_source(text)
        self.assertEqual(frames, [16.7, 16.8])

    def test_empty_input(self):
        self.assertEqual(fm.parse_frame_source("")[0], [])


class HeaderCsvTest(unittest.TestCase):
    """The capture side owns the frames_raw.csv schema; a header must not blank it."""

    def test_index_time_frame_columns(self):
        text = ("frame_idx,t_ms,frame_ms\n"
                "0,0.000,16.70\n1,16.700,16.60\n2,33.300,40.00\n")
        frames, stamps, meta = fm.parse_frame_source(text)
        self.assertEqual(meta["shape"], "csv_header")
        self.assertEqual(frames, [16.7, 16.6, 40.0])
        self.assertEqual([round(s, 4) for s in stamps], [0.0, 0.0167, 0.0333])

    def test_time_only_column_derives_frame_times(self):
        text = "t_ms\n0\n16.7\n33.3\n73.3\n"
        frames, stamps, _ = fm.parse_frame_source(text)
        self.assertEqual(len(frames), 3)
        self.assertAlmostEqual(frames[0], 16.7, places=3)
        self.assertAlmostEqual(frames[2], 40.0, places=3)
        self.assertEqual(len(stamps), 3)

    def test_frame_ms_only_column(self):
        frames, stamps, _ = fm.parse_frame_source("frame_ms\n16.7\n16.8\n50.0\n")
        self.assertEqual(frames, [16.7, 16.8, 50.0])
        self.assertIsNone(stamps)

    def test_seconds_column_is_scaled(self):
        text = "t_s,frame_ms\n0.000,16.7\n0.017,16.7\n"
        _, stamps, _ = fm.parse_frame_source(text)
        self.assertAlmostEqual(stamps[-1], 0.017, places=3)

    def test_headerless_two_column_still_works(self):
        frames, _, meta = fm.parse_frame_source("0.016,16.7\n0.033,16.8\n")
        self.assertEqual(meta["shape"], "timestamped")
        self.assertEqual(frames, [16.7, 16.8])

    def test_header_does_not_break_the_latency_path(self):
        text = "16666667\n1000000000 1000000000 999000000\n"
        text += "1016666667 1016666667 1015666667\n"
        frames, _, meta = fm.parse_frame_source(text)
        self.assertEqual(meta["shape"], "surfaceflinger")
        self.assertEqual(len(frames), 1)


class PacingChangeTest(unittest.TestCase):
    """The mechanical check for "did the fps limit get rewritten during the run"."""

    def test_stable_60fps_has_no_pacing_change(self):
        frames = [16.5] * 600
        stamps = [index * 0.0165 for index in range(600)]
        stats = fm.frame_stats(frames, None, stamps)
        self.assertEqual(stats["pacing_changes"], 0)
        self.assertGreaterEqual(stats["per_second"]["p50"], 55)

    def test_lock_to_30_is_detected_as_a_pacing_change(self):
        frames = [16.5] * 600 + [33.0] * 600
        stamps = []
        when = 0.0
        for frame in frames:
            when += frame / 1000.0
            stamps.append(when)
        stats = fm.frame_stats(frames, None, stamps)
        self.assertEqual(stats["pacing_changes"], 1)
        self.assertEqual(len(stats["regimes"]), 2)
        self.assertGreater(stats["per_second"]["seconds_below_45fps"], 0)

    def test_per_second_counts_shape(self):
        stamps = [index / 60.0 for index in range(120)]
        out = fm.per_second_counts(stamps)
        self.assertEqual(out["seconds"], 2)
        self.assertEqual(out["p50"], 60.0)
        self.assertEqual(out["seconds_below_45fps"], 0)


class EndToEndLatencyTest(unittest.TestCase):
    """One latency dump in, one verdict out -- the shape the report consumes."""

    def test_verdict_from_latency_dump(self):
        refresh = 16666667
        base = 1000000000
        present = [base + i * refresh for i in range(30)]
        present.append(present[-1] + 5 * refresh)   # one 5-vsync stall
        for _ in range(15):
            present.append(present[-1] + refresh)
        lines = [str(refresh)]
        for stamp in present:
            lines.append(f"{stamp} {stamp} {stamp - 1000000}")
        frames, stamps, _ = fm.parse_frame_source("\n".join(lines))
        stats = fm.frame_stats(frames, refresh / 1e6, stamps)
        self.assertEqual(stats["frames"], len(present) - 1)
        self.assertEqual(stats["dropped"]["frames"], 1)
        self.assertEqual(stats["dropped"]["missed_vsyncs"], 4)
        # A single long frame is a spike, not a stutter segment (min_frames=2).
        self.assertIsNone(stats["jank_run_longest"])
        self.assertEqual(stats["spike_longest"]["frames"], 1)
        self.assertAlmostEqual(stats["spike_longest"]["ms"], 5 * refresh / 1e6, places=2)


if __name__ == "__main__":
    unittest.main()
