"""Tests for the heartbeat timeline in analyze_android_perf.py.

`[heartbeat]` is the only wall-clock anchored signal in a run directory: the
`adb logcat -v time` prefix gives each line a `MM-DD HH:MM:SS.mmm` stamp. Before
this change the parser kept only `fps`, so "when did it stutter" was unanswerable.
These tests pin the timeline, the gap detection built on it, and the day-filter
the charts rely on.
"""
import datetime
import json
import sys
import tempfile
import unittest
from pathlib import Path

PERF = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERF))

import analyze_android_perf as aap  # noqa: E402

LINE = "{stamp}  1234  5678 I Godot   : [heartbeat] day={day} speed=1.00 fps={fps} " \
       "stalls={stalls} scale=1.000 eco_day={day} graph=true window=2400x1080"


def write_logcat(directory, rows):
    path = Path(directory) / "logcat.txt"
    path.write_text("\n".join(
        LINE.format(stamp=stamp, day=day, fps=fps, stalls=stalls)
        for stamp, day, fps, stalls in rows) + "\n", encoding="utf-8")
    return path


class LogcatSecondsTest(unittest.TestCase):
    def test_reads_v_time_prefix(self):
        self.assertAlmostEqual(
            aap.logcat_seconds("11-25 10:44:27.123  1234  1234 I Godot : x"),
            10 * 3600 + 44 * 60 + 27.123, places=3)

    def test_returns_none_without_prefix(self):
        self.assertIsNone(aap.logcat_seconds("I Godot : [heartbeat] day=1"))


class HeartbeatTimelineTest(unittest.TestCase):
    def test_timeline_keeps_time_day_and_fps(self):
        rows = [("11-25 10:00:00.000", 0, 5.0, 0),
                ("11-25 10:00:05.000", 1, 58.0, 0),
                ("11-25 10:00:10.000", 2, 41.5, 3)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            timeline = aap.heartbeat_timeline(tmp)
        self.assertEqual([e["t_s"] for e in timeline], [0.0, 5.0, 10.0])
        self.assertEqual([e["day"] for e in timeline], [0.0, 1.0, 2.0])
        self.assertEqual([e["fps"] for e in timeline], [5.0, 58.0, 41.5])
        self.assertEqual(timeline[2]["stalls"], 3.0)

    def test_missing_logcat_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(aap.heartbeat_timeline(tmp), [])

    def test_midnight_rollover_is_not_a_negative_gap(self):
        rows = [("12-01 23:59:58.000", 3, 60.0, 0),
                ("12-02 00:00:03.000", 3, 60.0, 0)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            timeline = aap.heartbeat_timeline(tmp)
        self.assertAlmostEqual(timeline[1]["t_s"], 5.0, places=3)

    def test_without_time_prefix_t_s_is_none(self):
        path_tmp = tempfile.mkdtemp()
        Path(path_tmp, "logcat.txt").write_text(
            "I Godot : [heartbeat] day=4 speed=1.00 fps=55.0 stalls=0\n",
            encoding="utf-8")
        timeline = aap.heartbeat_timeline(path_tmp)
        self.assertIsNone(timeline[0]["t_s"])
        self.assertEqual(timeline[0]["fps"], 55.0)

    def test_series_keeps_the_day_zero_filter_for_charts(self):
        rows = [("11-25 10:00:00.000", 0, 5.0, 0),
                ("11-25 10:00:05.000", 1, 58.0, 0)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            series = aap.heartbeat_series_of(tmp)
        # day 0 is the 5 fps loading/map-build stage and must stay out (see chart_run).
        self.assertEqual(series, [58.0])


class HeartbeatGapTest(unittest.TestCase):
    def test_long_gap_is_detected_and_located(self):
        rows = [("11-25 10:00:00.000", 2, 60.0, 0),
                ("11-25 10:00:05.000", 2, 60.0, 0),
                ("11-25 10:00:10.000", 2, 60.0, 0),
                ("11-25 10:00:30.000", 2, 18.0, 2),   # main thread blocked ~20 s
                ("11-25 10:00:35.000", 2, 59.0, 2)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            gaps = aap.heartbeat_gaps(aap.heartbeat_timeline(tmp))
        self.assertEqual(gaps["max_gap_s"], 20.0)
        self.assertEqual(gaps["max_gap_at_s"], 10.0)
        self.assertEqual(gaps["threshold_s"], 10.0)
        self.assertEqual(len(gaps["long_gaps"]), 1)
        self.assertEqual(gaps["long_gaps"][0]["gap_s"], 20.0)
        self.assertEqual(gaps["long_gaps"][0]["day"], 2.0)

    def test_normal_cadence_has_no_long_gaps(self):
        rows = [("11-25 10:00:{0:02d}.000".format(i * 5), 1, 60.0, 0) for i in range(5)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            gaps = aap.heartbeat_gaps(aap.heartbeat_timeline(tmp))
        self.assertEqual(gaps["max_gap_s"], 5.0)
        self.assertEqual(gaps["long_gaps"], [])

    def test_single_heartbeat_reports_unknown(self):
        rows = [("11-25 10:00:00.000", 1, 60.0, 0)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            gaps = aap.heartbeat_gaps(aap.heartbeat_timeline(tmp))
        self.assertIsNone(gaps["max_gap_s"])
        self.assertEqual(gaps["windows"], 1)


class SlowestWindowTest(unittest.TestCase):
    def test_worst_windows_come_back_with_time(self):
        rows = [("11-25 10:00:00.000", 0, 5.0, 0),
                ("11-25 10:00:05.000", 1, 59.0, 0),
                ("11-25 10:00:10.000", 1, 21.0, 4),
                ("11-25 10:00:15.000", 1, 45.0, 1)]
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, rows)
            slow = aap.slowest_windows(aap.heartbeat_timeline(tmp), top=2)
        self.assertEqual([s["fps"] for s in slow], [21.0, 45.0])
        self.assertEqual(slow[0]["t_s"], 10.0)
        self.assertEqual(slow[0]["stalls"], 4.0)
        # day 0 (loading) never counts as a slow gameplay window.
        self.assertNotIn(5.0, [s["fps"] for s in slow])


SAMPLE_LOG = """# samples for unit
[10:00:00] screen: mWakefulness=Awake
[10:00:10] thermal 
Temperature{mName=Cpu;mValue=41.5} 
Temperature{mName=Skin;mValue=38.0}
mStatus=0
[10:00:30] thermal 
Temperature{mName=Cpu;mValue=52.5}
mStatus=1
[10:00:32] battery temp before run: 38.5 C
"""


class SampleTimelineTest(unittest.TestCase):
    def test_multiline_block_inherits_the_block_stamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "samples.log").write_text(SAMPLE_LOG, encoding="utf-8")
            events = aap.parse_sample_timeline(Path(tmp) / "samples.log")
        self.assertEqual([e["t_s"] for e in events], [0.0, 10.0, 30.0, 32.0])
        thermal = [e for e in events if e["kind"] == "thermal"]
        # Temperature lines live BELOW the stamped `thermal ` header line.
        self.assertEqual(thermal[0]["max_c"], 41.5)
        self.assertEqual(thermal[0]["status"], 0)
        self.assertEqual(thermal[1]["max_c"], 52.5)
        self.assertEqual(thermal[1]["status"], 1)

    def test_battery_temperature_from_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "samples.log").write_text(SAMPLE_LOG, encoding="utf-8")
            events = aap.parse_sample_timeline(Path(tmp) / "samples.log")
        battery = [e for e in events if e["battery_c"] is not None]
        self.assertEqual(battery[-1]["battery_c"], 38.5)

    def test_missing_samples_log_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(aap.parse_sample_timeline(Path(tmp) / "samples.log"), [])


class ThermalStepsTest(unittest.TestCase):
    def steps(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "samples.log").write_text(SAMPLE_LOG, encoding="utf-8")
            return aap.thermal_steps(aap.parse_sample_timeline(Path(tmp) / "samples.log"))

    def test_transitions_and_onset(self):
        steps = self.steps()
        self.assertEqual(steps["points"], 2)
        self.assertEqual(steps["coverage_s"], 20.0)
        self.assertEqual(steps["max_status"], 1)
        self.assertTrue(steps["throttled"])
        self.assertEqual(steps["onset"]["t_s"], 30.0)
        self.assertEqual(steps["onset"]["status"], 1)

    def test_coverage_is_reported_so_a_short_timeline_cannot_overclaim(self):
        # Only two readings 20 s apart: the report must be able to say "coverage 20s".
        self.assertEqual(self.steps()["first_t_s"], 10.0)
        self.assertEqual(self.steps()["last_t_s"], 30.0)

    def test_single_reading_is_not_a_timeline(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "samples.log").write_text(
                "[10:00:10] thermal \nmStatus=0\n", encoding="utf-8")
            steps = aap.thermal_steps(aap.parse_sample_timeline(Path(tmp) / "samples.log"))
        self.assertEqual(steps["points"], 1)
        self.assertEqual(steps["coverage_s"], 0.0)
        self.assertFalse(steps["throttled"])


class ClockTimelineTest(unittest.TestCase):
    def test_clock_rate_lines_get_timestamps(self):
        rows = [("11-25 10:00:00.000", 1.20, 380),
                ("11-25 10:00:02.000", 0.95, 470)]
        with tempfile.TemporaryDirectory() as tmp:
            text = "\n".join(
                "{0}  1234  5678 I Godot   : [clock/rate] dps={1:.2f} speed=1x "
                "cap=3.00d/f cost={2}ms fps=58.0 blocked=0 budget_break=0".format(*r)
                for r in rows) + "\n"
            Path(tmp, "logcat.txt").write_text(text, encoding="utf-8")
            clock = aap.clock_timeline(tmp)
        self.assertEqual([c["t_s"] for c in clock], [0.0, 2.0])
        self.assertEqual([c["cost_ms"] for c in clock], [380.0, 470.0])
        self.assertEqual(clock[0]["cap"], 3.0)
        self.assertEqual([c["dps"] for c in clock], [1.2, 0.95])


class ThermalCoverageTest(unittest.TestCase):
    def test_gap_between_thermal_end_and_run_end_is_computed(self):
        steps = {"coverage_s": 40.0, "last_t_s": 45.0}
        heartbeat = [{"t_s": float(t), "day": 1.0, "fps": 60.0, "stalls": 0.0}
                     for t in (0, 5, 300, 595)]
        out = aap.thermal_coverage(steps, heartbeat)
        self.assertEqual(out["run_span_s"], 595.0)
        self.assertEqual(out["uncovered_s"], 550.0)

    def test_no_heartbeat_means_unknown_not_zero(self):
        out = aap.thermal_coverage({"last_t_s": 45.0}, [])
        self.assertIsNone(out["run_span_s"])
        self.assertIsNone(out["uncovered_s"])


class ThrottleCorrelationTest(unittest.TestCase):
    def test_fps_and_cost_before_vs_after_one_step(self):
        heartbeat = [{"t_s": float(t), "day": 5.0,
                      "fps": 60.0 if t < 30 else 40.0, "stalls": 0.0}
                     for t in range(0, 60, 5)]
        clock = [{"t_s": float(t), "cost_ms": 380.0 if t < 30 else 470.0,
                  "dps": 1.2 if t < 30 else 0.9} for t in range(0, 60, 2)]
        steps = {"transitions": [{"t_s": 30.0, "from": 0, "status": 1,
                                  "max_c": 52.5, "battery_c": 40.0}]}
        rows = aap.correlate_throttle(steps, heartbeat, clock, window_s=20.0)
        self.assertEqual(len(rows), 1)
        self.assertAlmostEqual(rows[0]["fps_before"], 60.0)
        self.assertAlmostEqual(rows[0]["fps_after"], 40.0)
        self.assertAlmostEqual(rows[0]["cost_before_ms"], 380.0)
        self.assertAlmostEqual(rows[0]["cost_after_ms"], 470.0)

    def test_window_without_data_reports_none_not_zero(self):
        rows = aap.correlate_throttle(
            {"transitions": [{"t_s": 10.0, "from": None, "status": 0,
                              "max_c": None, "battery_c": None}]},
            [{"t_s": 0.0, "day": 1.0, "fps": 60.0, "stalls": 0.0}], [], 20.0)
        self.assertIsNone(rows[0]["fps_after"])


class AlignSourcesTest(unittest.TestCase):
    def test_sources_share_one_wall_axis(self):
        hb = [{"wall": 100.0, "t_s": 0.0}, {"wall": 105.0, "t_s": 5.0}]
        thermal = [{"wall": 90.0, "t_s": 0.0}]
        base = aap.align_sources([hb, thermal])
        self.assertEqual(base, 90.0)
        self.assertEqual([e["t_run_s"] for e in hb], [10.0, 15.0])
        self.assertEqual(thermal[0]["t_run_s"], 0.0)

    def test_no_wall_clock_yields_none(self):
        hb = [{"wall": None, "t_s": 0.0}]
        self.assertIsNone(aap.align_sources([hb]))
        self.assertIsNone(hb[0]["t_run_s"])


class CoverageTest(unittest.TestCase):
    def test_tail_gap_marks_incomplete_with_the_missing_range(self):
        cov = aap.source_coverage("thermal", [5.0, 25.0, 45.0], 595.0)
        self.assertEqual(cov["status"], "INCOMPLETE")
        self.assertEqual(cov["missing_s"][-1]["reason"], "tail")
        self.assertEqual(cov["missing_s"][-1]["to_s"], 595.0)

    def test_full_coverage_is_ok(self):
        cov = aap.source_coverage("heartbeat", list(range(0, 600, 5)), 595.0, 5.0)
        self.assertEqual(cov["status"], "OK")
        self.assertEqual(cov["missing_s"], [])

    def test_internal_hole_is_reported(self):
        cov = aap.source_coverage("clock", [0.0, 2.0, 4.0, 300.0, 302.0], 302.0, 2.0)
        self.assertEqual(cov["status"], "INCOMPLETE")
        self.assertEqual(cov["missing_s"][0]["reason"], "hole")
        self.assertEqual(cov["missing_s"][0]["from_s"], 4.0)

    def test_missing_source(self):
        cov = aap.source_coverage("frames", [], 595.0)
        self.assertEqual(cov["status"], "MISSING")

    def test_report_aggregates_warnings(self):
        report = aap.completeness_report([
            aap.source_coverage("heartbeat", list(range(0, 600, 5)), 595.0, 5.0),
            aap.source_coverage("thermal", [5.0, 25.0, 45.0], 595.0)], 595.0)
        self.assertEqual(report["status"], "INCOMPLETE")
        self.assertTrue(any("thermal" in w for w in report["warnings"]))


class PerfCsvLookupTest(unittest.TestCase):
    def test_frame_dump_is_not_mistaken_for_the_perf_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "frames_raw.csv").write_text("0.016,16.7\n0.033,16.8\n", encoding="utf-8")
            Path(tmp, "perf_run.csv").write_text(
                "timestamp_ms,fps,fast_ms\n0,60,4\n", encoding="utf-8")
            found = aap.find_csv(tmp, {})
        self.assertEqual(Path(found).name, "perf_run.csv")

    def test_only_a_frame_dump_means_no_perf_csv(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "frames_raw.csv").write_text("0.016,16.7\n", encoding="utf-8")
            self.assertIsNone(aap.find_csv(tmp, {}))

    def test_header_sniff(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp, "a.csv")
            good.write_text("timestamp_ms,fps,fast_ms\n", encoding="utf-8")
            bad = Path(tmp, "b.csv")
            bad.write_text("t,frame_ms\n0,16.7\n", encoding="utf-8")
            self.assertTrue(aap.looks_like_perf_csv(good))
            self.assertFalse(aap.looks_like_perf_csv(bad))


class FrameDumpLookupTest(unittest.TestCase):
    def test_priority_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("sf_latency_raw.txt", "frames_raw.csv"):
                Path(tmp, name).write_text("16.7\n", encoding="utf-8")
            found = aap.find_frame_dump(tmp)
        self.assertEqual(Path(found).name, "frames_raw.csv")

    def test_none_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(aap.find_frame_dump(tmp))


class ThermalCsvTest(unittest.TestCase):
    """The perfetto path: ts_ms is CLOCK_REALTIME, so it must land on the run."""

    def epoch_ms(self, hour, minute, second):
        # Same machine, same timezone, so this is exactly the frame the parser assumes.
        return datetime.datetime(2026, 11, 25, hour, minute, second).timestamp() * 1000.0

    def test_parses_ms_and_khz(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "thermal_timeline.csv")
            path.write_text("ts_ms,cpu_freq_khz,thermal_status\n"
                            "1000,2000000,0\n2000,1900000,0\n", encoding="utf-8")
            rows, meta = aap.parse_thermal_csv(path)
        self.assertEqual([r["freq_khz"] for r in rows], [2000000.0, 1900000.0])
        self.assertEqual([r["status"] for r in rows], [0, 0])
        self.assertEqual(meta["points"], 2)

    def test_per_core_rows_collapse_to_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "thermal_timeline.csv")
            path.write_text("ts_ms,cpu,cpu_freq_khz,thermal_status\n"
                            "1000,0,1800000,0\n1000,7,2400000,0\n2000,0,1700000,1\n",
                            encoding="utf-8")
            rows, meta = aap.parse_thermal_csv(path)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["freq_khz"], 2400000.0)
        self.assertTrue(meta["multi_core_max"])

    def test_ns_and_ghz_columns_are_scaled(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "thermal_timeline.csv")
            path.write_text("ts_ns,cpu_freq_ghz,thermal_status\n"
                            "1000000000,2.0,0\n2000000000,1.9,0\n", encoding="utf-8")
            rows, _ = aap.parse_thermal_csv(path)
        self.assertEqual(rows[0]["t_ms"], 1000.0)
        self.assertEqual(rows[0]["freq_khz"], 2000000.0)

    def test_wall_alignment_accepts_a_run_that_starts_together(self):
        rows = [{"t_ms": self.epoch_ms(10, 0, 0) + i * 1000, "freq_khz": 2e6, "status": 0}
                for i in range(10)]
        walls, meta = aap.thermal_csv_wall(rows, [36000.0])   # 10:00:00 as seconds-of-day
        self.assertTrue(meta["aligned"])
        self.assertAlmostEqual(walls[0], 36000.0, places=3)

    def test_wall_alignment_rejects_a_shifted_series(self):
        # A timezone-sized error must be caught, not silently used.
        rows = [{"t_ms": self.epoch_ms(18, 0, 0), "freq_khz": 2e6, "status": 0}]
        _, meta = aap.thermal_csv_wall(rows, [36000.0])
        self.assertFalse(meta["aligned"])
        self.assertGreater(abs(meta["tried"][0]["start_skew_s"]), 300)

    def test_steps_report_baseline_and_frequency_drop(self):
        rows = [{"t_ms": 0, "freq_khz": 2400000.0, "status": 0} for _ in range(10)]
        rows += [{"t_ms": 0, "freq_khz": 1500000.0, "status": 0} for _ in range(10)]
        times = [float(i) for i in range(len(rows))]
        steps = aap.thermal_csv_steps(rows, times)
        self.assertEqual(steps["baseline_freq_khz"], 2400000.0)
        self.assertEqual(steps["drop_threshold_khz"], 1920000.0)
        self.assertEqual(steps["min_freq_khz"], 1500000.0)
        self.assertTrue(steps["throttled"])
        self.assertEqual(steps["onset"]["reason"], "freq_drop")
        self.assertEqual(steps["onset"]["t_s"], 10.0)

    def test_status_change_also_counts_as_onset(self):
        rows = [{"t_ms": 0, "freq_khz": 2400000.0, "status": 0},
                {"t_ms": 1000, "freq_khz": 2400000.0, "status": 2}]
        steps = aap.thermal_csv_steps(rows, [0.0, 1.0])
        self.assertEqual(steps["onset"]["reason"], "status")
        self.assertEqual(steps["onset"]["status"], 2)

    def test_missing_file_is_not_an_exception(self):
        rows, meta = aap.parse_thermal_csv("does-not-exist.csv")
        self.assertEqual(rows, [])
        self.assertIn("error", meta)


class ClockSnapshotTest(unittest.TestCase):
    """Offset is computed here, not by the capture side (group decision)."""

    def test_narrow_one_row_per_clock(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "clock_snapshot.csv")
            # BOOTTIME is 2 h 51 min behind REALTIME in this fabricated snapshot.
            path.write_text(
                "clock_id,clock_name,clock_value\n"
                "1,CLOCK_REALTIME,1795000000000000\n"
                "6,CLOCK_BOOTTIME,1784742000000000\n", encoding="utf-8")
            offset, meta = aap.parse_clock_snapshot_csv(path)
        self.assertAlmostEqual(offset, 10258.0, places=3)
        self.assertEqual(meta["method"], "clock_snapshot_narrow")

    def test_wide_two_column_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "clock_snapshot.csv")
            path.write_text("boottime_ns,realtime_ns\n1000000000,45000000000\n",
                            encoding="utf-8")
            offset, meta = aap.parse_clock_snapshot_csv(path)
        self.assertAlmostEqual(offset, 44.0, places=3)
        self.assertEqual(meta["method"], "clock_snapshot_wide")

    def test_unreadable_dump_yields_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "clock_snapshot.csv")
            path.write_text("foo,bar\n1,2\n", encoding="utf-8")
            offset, meta = aap.parse_clock_snapshot_csv(path)
        self.assertIsNone(offset)
        self.assertIn("error", meta)

    def test_snapshot_offset_is_used_and_labelled(self):
        rows = [{"t_ms": self.epoch_ms(10, 0, 0), "freq_khz": 2e6, "status": 0}]
        _, meta = aap.thermal_csv_wall(rows, [36000.0], clock_offset_s=28800.0)
        self.assertTrue(meta["aligned"])
        self.assertEqual(meta["offset_source"], "clock_snapshot.csv")
        self.assertEqual(meta["method"], "boottime+snapshot")

    def test_a_wrong_snapshot_offset_cannot_poison_the_result(self):
        # A bogus snapshot offset fails the landing check; the realtime model still
        # fits, so the run is used and the bad candidate is kept as evidence.
        rows = [{"t_ms": self.epoch_ms(10, 0, 0), "freq_khz": 2e6, "status": 0}]
        _, meta = aap.thermal_csv_wall(rows, [36000.0], clock_offset_s=3600.0)
        self.assertTrue(meta["aligned"])
        self.assertEqual(meta["method"], "realtime+pc_tz")
        self.assertFalse(meta["tried"][0]["aligned"])

    def test_nothing_lands_means_rejected_with_evidence(self):
        rows = [{"t_ms": self.epoch_ms(10, 0, 0) + 5 * 3600 * 1000,
                 "freq_khz": 2e6, "status": 0}]
        _, meta = aap.thermal_csv_wall(rows, [36000.0])
        self.assertFalse(meta["aligned"])
        self.assertTrue(meta["tried"])
        self.assertTrue(all(not item["aligned"] for item in meta["tried"]))

    def epoch_ms(self, hour, minute, second):
        return datetime.datetime(2026, 11, 25, hour, minute, second).timestamp() * 1000.0


class ThermalSourceColumnTest(unittest.TestCase):
    """4th column `thermal_source`; held rows are interpolated and never decide onset."""

    def write(self, directory, name, text):
        path = Path(directory, name)
        path.write_text(text, encoding="utf-8")
        return path

    def test_fourth_column_is_parsed_and_counted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, "thermal_timeline.csv",
                              "ts_ms,cpu_freq_khz,thermal_status,thermal_source\n"
                              "1000,2400000,0,measured\n2000,2400000,0,held\n"
                              "3000,2400000,1,measured\n")
            rows, meta = aap.parse_thermal_csv(path)
        self.assertEqual([r["source"] for r in rows], ["measured", "held", "measured"])
        self.assertEqual(meta["measured_points"], 2)
        self.assertEqual(meta["held_points"], 1)

    def test_held_rows_cannot_create_a_false_onset(self):
        # The held row says status 1 five seconds early; only the measured rows may
        # decide, so the onset window starts at the last measured point.
        rows = [
            {"t_ms": 0, "freq_khz": 2400000.0, "status": 0, "source": "measured"},
            {"t_ms": 1000, "freq_khz": 2400000.0, "status": 1, "source": "held"},
            {"t_ms": 5000, "freq_khz": 2400000.0, "status": 1, "source": "measured"},
        ]
        steps = aap.thermal_csv_steps(rows, [0.0, 1.0, 5.0])
        self.assertEqual(steps["held_points_excluded"], 1)
        self.assertEqual(steps["onset"]["reason"], "status")
        self.assertEqual(steps["onset"]["window"]["from_t_s"], 0.0)
        self.assertEqual(steps["onset"]["window"]["to_t_s"], 5.0)
        self.assertEqual(steps["onset"]["window"]["width_s"], 5.0)

    def test_onset_is_an_interval_not_a_point(self):
        rows = [{"t_ms": index * 1000, "freq_khz": 2400000.0, "status": 0,
                 "source": "measured"} for index in range(10)]
        rows += [{"t_ms": 10000, "freq_khz": 2400000.0, "status": 2, "source": "measured"}]
        steps = aap.thermal_csv_steps(rows, [float(i) for i in range(11)])
        window = steps["onset"]["window"]
        self.assertEqual(window["width_s"], 1.0)
        self.assertLess(window["from_t_s"], window["to_t_s"])

    def test_frequency_drop_window_points_back_to_last_measured(self):
        rows = [{"t_ms": index * 1000, "freq_khz": 2400000.0, "status": 0,
                 "source": "measured"} for index in range(10)]
        rows += [{"t_ms": 10000, "freq_khz": 1500000.0, "status": 0,
                  "source": "measured"}]
        steps = aap.thermal_csv_steps(rows, [float(i) for i in range(11)])
        self.assertEqual(steps["onset"]["reason"], "freq_drop")
        self.assertEqual(steps["onset"]["window"]["from_t_s"], 9.0)
        self.assertEqual(steps["onset"]["window"]["to_t_s"], 10.0)

    def test_missing_source_column_is_flagged_not_assumed_silently(self):
        rows = [{"t_ms": 0, "freq_khz": 2400000.0, "status": 0}]
        steps = aap.thermal_csv_steps(rows, [0.0])
        self.assertTrue(steps["source_unknown"])


class BaselineAssessmentTest(unittest.TestCase):
    """S1's caveat, expressed as a machine check instead of a hand-written note."""

    def clean_digest(self):
        return {"frames": {"pacing_changes": 0, "regimes": []},
                "speed_profile": {"changes": [], "dominant": 1.0, "share_dominant": 100.0},
                "swap_pss_kb": 1200,
                "perf": {"rows": 40}}

    def test_clean_run_is_usable(self):
        out = aap.baseline_assessment(self.clean_digest())
        self.assertTrue(out["usable_for_absolute"])
        self.assertEqual(out["reasons"], [])

    def test_pacing_change_blocks_absolute_numbers(self):
        digest = self.clean_digest()
        digest["frames"] = {"pacing_changes": 1,
                            "regimes": [{"from_s": 0.0, "to_s": 219.0},
                                        {"from_s": 219.0, "to_s": 484.0}]}
        out = aap.baseline_assessment(digest)
        self.assertFalse(out["usable_for_absolute"])
        self.assertTrue(any("pacing_stable" in reason for reason in out["reasons"]))

    def test_speed_change_is_reported_with_its_time_and_share(self):
        digest = self.clean_digest()
        digest["speed_profile"] = {"changes": [{"at_s": 40.4, "from": 1.0, "to": 10.0}],
                                   "dominant": 10.0, "share_dominant": 91.3}
        out = aap.baseline_assessment(digest)
        detail = next(c["detail"] for c in out["checks"]
                      if c["check"] == "constant_sim_speed")
        self.assertIn("1 -> 10", detail)
        self.assertIn("40.4", detail)
        self.assertIn("91.3", detail)

    def test_paging_blocks_absolute_numbers(self):
        digest = self.clean_digest()
        digest["swap_pss_kb"] = 131026
        out = aap.baseline_assessment(digest)
        self.assertFalse(out["usable_for_absolute"])
        self.assertTrue(any("no_paging" in reason for reason in out["reasons"]))

    def test_missing_subsystem_csv_is_an_attribution_gap_not_a_blocker(self):
        digest = self.clean_digest()
        digest["perf"] = {"rows": 0}
        out = aap.baseline_assessment(digest)
        self.assertTrue(out["usable_for_absolute"])
        self.assertTrue(any("subsystem_csv" in reason for reason in out["reasons"]))

    def test_swap_pss_parsed_from_meminfo(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "meminfo_end.txt").write_text(
                "TOTAL PSS:  2547976    TOTAL RSS: 2562556    TOTAL SWAP PSS:   131026\n",
                encoding="utf-8")
            self.assertEqual(aap.swap_pss_kb(tmp), 131026)

    def test_swap_pss_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(aap.swap_pss_kb(tmp))


class SpeedProfileTest(unittest.TestCase):
    def test_detects_the_speed_step(self):
        timeline = ([{"t_s": float(i), "speed": 1.0} for i in range(8)] +
                    [{"t_s": float(20 + i), "speed": 10.0} for i in range(24)])
        profile = aap.speed_profile(timeline)
        self.assertEqual(profile["changes"], [{"at_s": 20.0, "from": 1.0, "to": 10.0}])
        self.assertEqual(profile["dominant"], 10.0)
        self.assertEqual(profile["share_dominant"], 75.0)

    def test_constant_speed_has_no_changes(self):
        timeline = [{"t_s": float(i), "speed": 1.0} for i in range(5)]
        self.assertEqual(aap.speed_profile(timeline)["changes"], [])


class RunDirectoryIntegrationTest(unittest.TestCase):
    """analyze() + digest assembly on a minimal run dir, no device required."""

    def test_digest_carries_timeline_gaps_and_slowest(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_logcat(tmp, [("11-25 10:00:00.000", 1, 60.0, 0),
                               ("11-25 10:00:25.000", 1, 20.0, 2)])
            (Path(tmp) / "run_meta.json").write_text(
                json.dumps({"label": "unit", "query": "fixture"}), encoding="utf-8")
            digest = aap.analyze(tmp)
            timeline = aap.heartbeat_timeline(tmp)
            digest["heartbeat_gaps"] = aap.heartbeat_gaps(timeline)
            digest["heartbeat_slowest"] = aap.slowest_windows(timeline)
            digest["heartbeat_series"] = [e["fps"] for e in timeline]

        self.assertEqual(digest["meta"]["label"], "unit")
        self.assertEqual(digest["heartbeat_gaps"]["max_gap_s"], 25.0)
        self.assertEqual(digest["heartbeat_slowest"][0]["fps"], 20.0)
        self.assertEqual(digest["heartbeat_series"], [60.0, 20.0])
        # A run dir with no CSV still parses; it just has no per-day rows.
        self.assertEqual(digest["perf"].get("rows", 0), 0)


if __name__ == "__main__":
    unittest.main()
