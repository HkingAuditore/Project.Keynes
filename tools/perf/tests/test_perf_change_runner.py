"""perf_change_check decides whether a performance change may proceed (AGENTS.md rule 6).

Each gate, parser and classifier is fed inputs it must refuse, not only good ones.
Run: python -m unittest discover -s tools/perf/tests -v
"""
import argparse
import contextlib
import io
import json
import runpy
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import perf_change_check as pc  # noqa: E402
import perf_change_metrics as metrics  # noqa: E402
import perf_change_runner as runner  # noqa: E402

SCENARIO = dict(pc.DEFAULT_SCENARIO)
GOOD_RESULT = {"rows": "50", "expected_rows": "50", "fatal": "false", "economy_configured": "true",
               "formal_start": "true", "ledger_failures": "0", "population": "1200",
               "country_count": "4", "path": "/tmp/perf.csv"}
GOOD_CSV = [{"tick_idx": str(i), "speed_multiplier": "50", "t_sus_ms": "1"} for i in range(1, 51)]
IDENTITY = {"commit": "a" * 40, "scenario": SCENARIO, "method_version": pc.METHOD_VERSION,
            "machine": "m1", "machine_label": "Mac", "toolchain": "t1", "toolchain_label": "godot"}


def record(**changes):
    value = {"status": "complete", "tier": "quick", "identity": dict(IDENTITY),
             "rounds": [{"errors": [], "metrics": {}} for _ in range(3)]}
    value.update(changes)
    return value


class PerfRunValidation(unittest.TestCase):
    def test_accepts_a_complete_run(self):
        self.assertEqual(metrics.validate_perf_run(0, GOOD_RESULT, GOOD_CSV, SCENARIO), [])

    def test_refuses_each_broken_fact(self):
        cases = {
            "exit": (1, GOOD_RESULT, GOOD_CSV),
            "no result": (0, None, GOOD_CSV),
            "short csv": (0, GOOD_RESULT, GOOD_CSV[:-1]),
            "missing csv": (0, GOOD_RESULT, None),
            "rows": (0, GOOD_RESULT | {"rows": "49"}, GOOD_CSV),
            "expected rows": (0, GOOD_RESULT | {"expected_rows": "10"}, GOOD_CSV),
            "fatal": (0, GOOD_RESULT | {"fatal": "true"}, GOOD_CSV),
            "fatal missing": (0, {k: v for k, v in GOOD_RESULT.items() if k != "fatal"}, GOOD_CSV),
            "ledger": (0, GOOD_RESULT | {"ledger_failures": "2"}, GOOD_CSV),
            "ledger not a number": (0, GOOD_RESULT | {"ledger_failures": "nan"}, GOOD_CSV),
            "economy": (0, GOOD_RESULT | {"economy_configured": "false"}, GOOD_CSV),
            "synthetic start": (0, GOOD_RESULT | {"formal_start": "false"}, GOOD_CSV),
            "no population": (0, GOOD_RESULT | {"population": "0"}, GOOD_CSV),
            "too few countries": (0, GOOD_RESULT | {"country_count": "2"}, GOOD_CSV),
        }
        for name, (code, result, rows) in cases.items():
            with self.subTest(name):
                self.assertTrue(metrics.validate_perf_run(code, result, rows, SCENARIO))

    def test_refuses_required_columns_missing_with_the_correct_row_count(self):
        for column in ("tick_idx", "speed_multiplier", "t_sus_ms"):
            rows = [{key: value for key, value in row.items() if key != column} for row in GOOD_CSV]
            with self.subTest(column=column):
                self.assertTrue(any(column in error for error in
                                    metrics.validate_perf_run(0, GOOD_RESULT, rows, SCENARIO)))

    def test_refuses_required_column_with_no_numeric_values(self):
        rows = [row | {"speed_multiplier": ""} for row in GOOD_CSV]
        self.assertTrue(any("speed_multiplier" in error for error in
                            metrics.validate_perf_run(0, GOOD_RESULT, rows, SCENARIO)))

    def run_csv_round(self, tmp, headers, values, result_fields=None, source="legacy recorder"):
        worktree = Path(tmp)
        script = worktree / runner.PROJECT / runner.PERF_SCRIPT.removeprefix("res://")
        script.parent.mkdir(parents=True)
        script.write_text(source)
        recorder = worktree / runner.PROJECT / "scripts/ui/perf_recorder.gd"
        recorder.parent.mkdir(parents=True)
        recorder.write_text("shared CSV recorder")
        path = worktree / "perf.csv"
        path.write_text("\n".join([headers, *values]) + "\n")
        days = len(values)
        result = (GOOD_RESULT | {"rows": str(days), "expected_rows": str(days)} | (result_fields or {}))
        result.pop("path")
        result["path"] = str(path)
        usage = argparse.Namespace(ru_utime=0.1, ru_stime=0.1, ru_maxrss=1000)

        def godot(*_, stdout, **__):
            stdout.write(metrics.RESULT_PREFIX + " " + " ".join(f"{k}={v}" for k, v in result.items()) + "\n")
            stdout.write(metrics.AUTH_PREFIX + " authoritative_days_per_second=50\n")
            stdout.write(metrics.HARNESS_PREFIX + " adjusted_days_per_second=50\n")
            return argparse.Namespace(pid=42)

        with mock.patch.object(runner.subprocess, "Popen", side_effect=godot), \
             mock.patch.object(runner.os, "wait4", return_value=(42, 0, usage), create=True):
            return runner.perf_round(worktree, worktree / "round", SCENARIO | {"days": days},
                                 "quick", "godot", "r1")

    def test_perf_round_uses_observed_samples_for_optional_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = self.run_csv_round(tmp, "tick_idx,speed_multiplier,t_sus_ms,market_ms",
                                     ["1,50,0,", "2,50,0,7", "3,50,0,", "4,50,0,3"])
        self.assertEqual(run["errors"], [])
        self.assertEqual(run["metrics"]["csv.market_ms.mean"], 5)
        self.assertEqual(run["metrics"]["csv.market_ms.p95"], 7)
        self.assertEqual(run["metrics"]["csv.market_ms.max"], 7)

    def test_perf_round_rejects_missing_required_column_and_corrupt_optional_cells(self):
        for headers, values, reason in (
            ("tick_idx,t_sus_ms", ["1,0", "2,0"], "speed_multiplier"),
            ("tick_idx,speed_multiplier,t_sus_ms", ["1,50,0", "2,,0"], "speed_multiplier"),
            ("tick_idx,speed_multiplier,t_sus_ms,market_ms", ["1,50,0,7", "2,50,0,invalid"], "market_ms"),
            ("tick_idx,speed_multiplier,t_sus_ms,market_ms", ["1,50,0,7", "2,50,0"], "header width"),
            ("tick_idx,speed_multiplier,t_sus_ms,t_sus_ms", ["1,50,0,0", "2,50,0,0"], "duplicate"),
        ):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp:
                run = self.run_csv_round(tmp, headers, values)
                self.assertTrue(any(reason in error for error in run["errors"]), run["errors"])


    def test_new_recorder_uses_only_measured_daily_intervals(self):
        columns = ("row_idx,tick_idx,speed_multiplier,t_sus_ms,runtime_graph_simulation_committed_day,"
                   "runtime_graph_simulation_generation,commit_produced_at_us,commit_interval_ms")
        method = "day_records_worker_v1"
        with tempfile.TemporaryDirectory() as tmp:
            run = self.run_csv_round(tmp, columns, ["0,6,50,,6,106,2000,1", "1,7,50,,7,107,5000,3"],
                                     {"warmup_days": "5", "recorder_method": method})
        self.assertEqual(run["errors"], [])
        self.assertEqual(run["recorder_method"], method)
        self.assertEqual(run["metrics"]["csv.commit_interval_ms.mean"], 2.0)
        self.assertEqual(run["metrics"]["csv.commit_interval_ms.p95"], 3.0)
        self.assertEqual(run["metrics"]["csv.commit_interval_ms.max"], 3.0)
        self.assertNotIn("csv.t_sus_ms.mean", run["metrics"])
        self.assertNotIn("csv.commit_produced_at_us.mean", run["metrics"])

    def test_day_format_refuses_fake_timings_and_a_gap_even_at_the_expected_count(self):
        first = {"row_idx": "0", "tick_idx": "6", "speed_multiplier": "50", "t_sus_ms": "",
                 "runtime_graph_simulation_committed_day": "6", "runtime_graph_simulation_generation": "106",
                 "commit_produced_at_us": "2000", "commit_interval_ms": "1"}
        second = first | {"row_idx": "1", "tick_idx": "7", "runtime_graph_simulation_committed_day": "7",
                          "runtime_graph_simulation_generation": "107", "commit_produced_at_us": "5000",
                          "commit_interval_ms": "3"}
        result = GOOD_RESULT | {"rows": "2", "expected_rows": "2", "warmup_days": "5",
                                "recorder_method": "day_records_worker_v1"}
        scenario = SCENARIO | {"days": 2}
        self.assertEqual(metrics.validate_perf_run(0, result, [first, second], scenario), [])
        for column, value, reason in (
            ("t_sus_ms", "0", "t_sus_ms"),
            ("fast_ms", "1", "columns"),
            ("tick_idx", "8", "ordered day 7"),
            ("runtime_graph_simulation_committed_day", "8", "ordered day 7"),
            ("commit_produced_at_us", "", "commit_produced_at_us"),
            ("commit_produced_at_us", "1000", "commit_produced_at_us"),
            ("commit_interval_ms", "", "commit_interval_ms"),
            ("commit_interval_ms", "0", "commit_interval_ms"),
        ):
            with self.subTest(column=column, value=value):
                errors = metrics.validate_perf_run(0, result, [first, second | {column: value}], scenario)
                self.assertTrue(any(reason in error for error in errors), errors)
        for method in ("", "unknown", "day_records_main_v1"):
            with self.subTest(method=method):
                errors = metrics.validate_perf_run(0, result | {"recorder_method": method}, [first, second], scenario)
                self.assertTrue(any("recorder method" in error for error in errors), errors)

    def test_zero_warmup_allows_only_the_first_interval_to_be_absent(self):
        rows = [{"row_idx": "0", "tick_idx": "1", "speed_multiplier": "50", "t_sus_ms": "",
                 "runtime_graph_simulation_committed_day": "1", "runtime_graph_simulation_generation": "101",
                 "commit_produced_at_us": "2000", "commit_interval_ms": ""}]
        result = GOOD_RESULT | {"rows": "1", "expected_rows": "1", "warmup_days": "0",
                                "recorder_method": "day_records_main_v1"}
        scenario = SCENARIO | {"days": 1}
        self.assertEqual(metrics.validate_perf_run(0, result, rows, scenario), [])
        errors = metrics.validate_perf_run(0, result, [rows[0] | {"commit_interval_ms": "0"}], scenario)
        self.assertTrue(any("no preceding commit" in error for error in errors), errors)

    def test_unversioned_recorders_use_their_own_source_identity(self):
        methods = []
        for source in ("foreground clock", "worker clock"):
            with tempfile.TemporaryDirectory() as tmp:
                run = self.run_csv_round(tmp, "tick_idx,speed_multiplier,t_sus_ms", ["1,50,0"],
                                         source=source)
                self.assertEqual(run["errors"], [])
                methods.append(run["recorder_method"])
        self.assertNotEqual(*methods)
        self.assertTrue(all(method.startswith("unversioned:") for method in methods))

    def test_unversioned_recorder_identity_includes_shared_columns(self):
        with tempfile.TemporaryDirectory() as tmp:
            worktree = Path(tmp)
            run = self.run_csv_round(tmp, "tick_idx,speed_multiplier,t_sus_ms", ["1,50,0"])
            columns = worktree / runner.PROJECT / "scripts/ui/perf_record_columns.gd"
            columns.write_text("first column definition")
            new_method = runner.recorder_method(worktree)
            self.assertNotEqual(run["recorder_method"], new_method)
            columns.write_text("updated column definition")
            self.assertNotEqual(new_method, runner.recorder_method(worktree))


class ArchiveReuse(unittest.TestCase):
    def test_reuses_identical_identity(self):
        self.assertTrue(metrics.record_reusable(record(), dict(IDENTITY), "quick", 3)[0])
        self.assertTrue(metrics.record_reusable(record(tier="full"), dict(IDENTITY), "quick", 2)[0])

    def test_refuses_any_identity_difference(self):
        for key, value in (("commit", "b" * 40), ("scenario", SCENARIO | {"days": 60}),
                           ("machine", "m2"), ("toolchain", "t2"),
                           ("method_version", pc.METHOD_VERSION + 1)):
            with self.subTest(key):
                self.assertFalse(metrics.record_reusable(record(), IDENTITY | {key: value}, "quick", 3)[0])

    def test_does_not_reuse_version_two_measurements(self):
        stored = record(identity=IDENTITY | {"method_version": 2})
        self.assertFalse(metrics.record_reusable(stored, IDENTITY, "quick", 3)[0])

    def test_refuses_incomplete_invalid_missing_or_lower_tier(self):
        self.assertFalse(metrics.record_reusable(None, IDENTITY, "quick", 3)[0])
        self.assertFalse(metrics.record_reusable(record(status="invalid"), IDENTITY, "quick", 3)[0])
        self.assertFalse(metrics.record_reusable(record(status="measuring"), IDENTITY, "quick", 3)[0])
        self.assertFalse(metrics.record_reusable(record(), IDENTITY, "full", 3)[0])
        stored = record()
        stored["identity"] = IDENTITY | {"extra": 1}
        self.assertFalse(metrics.record_reusable(stored, IDENTITY, "quick", 3)[0])

    def test_archive_refuses_fewer_rounds_than_requested(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = runner.Archive(Path(tmp))
            entry = archive.new_record_dir(IDENTITY) / "record.json"
            runner.save(entry, record())
            found, reason = archive.find(IDENTITY, "quick", 4)
            self.assertIsNone(found)
            self.assertIn("3 rounds", reason)
            self.assertEqual(len(archive.find(IDENTITY, "quick", 2)[0]["rounds"]), 3)


class MachineLoadGate(unittest.TestCase):
    def test_quiet_machine_goes(self):
        self.assertEqual(runner.load_gate(0.7, [], 0.5), [])

    def test_refuses_busy_cpu_unknown_or_impossible_idle_and_competitors(self):
        for idle in (0.3, None, -0.1, 1.5):
            with self.subTest(idle=idle):
                self.assertTrue(runner.load_gate(idle, [], 0.5))
        self.assertTrue(runner.load_gate(0.9, ["123 godot 90% cpu"], 0.5))

    def test_top_idle_uses_the_last_sample_not_the_since_boot_one(self):
        text = ("CPU usage: 5.0% user, 2.0% sys, 93.0% idle\n"
                "CPU usage: 67.43% user, 9.2% sys, 23.54% idle\n")
        self.assertAlmostEqual(runner.parse_top_idle(text), 0.2354)

    def test_refuses_top_output_without_two_samples(self):
        for text in ("", "CPU usage: 5.0% user, 2.0% sys, 93.0% idle\n", "garbage"):
            with self.subTest(text=text):
                self.assertIsNone(runner.parse_top_idle(text))

    def test_proc_stat_idle_between_two_readings(self):
        before = "cpu  100 0 100 700 100 0 0 0\ncpu0 1 2 3 4 5\n"
        after = "cpu  150 0 150 850 150 0 0 0\n"
        self.assertAlmostEqual(runner.parse_proc_stat_idle(before, after), 200 / 300)

    def test_refuses_unreadable_or_non_advancing_proc_stat(self):
        same = "cpu  100 0 100 700 100 0 0 0\n"
        for before, after in (("", same), (same, same), ("cpu x y z w v", same)):
            with self.subTest(before=before):
                self.assertIsNone(runner.parse_proc_stat_idle(before, after))

    def test_busy_godot_and_compilers_count_but_idle_editor_and_children_do_not(self):
        table = "\n".join([
            "  10     1  95.0 godot",
            "  11     1   0.3 /Applications/Godot.app/Contents/MacOS/Godot",
            "  12     1  80.0 /usr/bin/clang++",
            "  13   500  99.0 /opt/homebrew/bin/godot",
            "  14     1  99.0 /usr/bin/python3",
            "garbage line",
        ])
        found = runner.competing_processes(table, mine=500)
        self.assertEqual([entry.split()[0] for entry in found], ["10", "12"])

    def test_competing_build_is_found_when_its_path_has_a_space(self):
        table = "\n".join([
            "  15     1  90.0 /Users/me/My Tools/scons",
            "  16     1  85.0 /Applications/Godot Engine.app/Contents/MacOS/Godot",
            "  17     1  99.0 /Users/me/godot Tools/python3",
        ])
        self.assertEqual(runner.competing_processes(table, mine=500), ["15 scons 90% cpu", "16 Godot 85% cpu"])

    def test_quiet_sample_uses_one_process_listing_with_executable_names(self):
        args = argparse.Namespace(wait_left=0, budget=0, min_idle=0.5)
        listing = runner.subprocess.CompletedProcess("ps", 0, stdout="  15     1  90.0 /usr/bin/python3\n",
                                                 stderr="")
        failed = runner.subprocess.CompletedProcess("ps", 1, stdout="", stderr="ps: permission denied\n")
        with mock.patch.object(runner, "cpu_idle", return_value=0.9), \
             mock.patch.object(runner.subprocess, "run", side_effect=[listing, failed]) as ps:
            self.assertEqual(runner.wait_for_quiet_machine(args, [])["busy"], [])
        ps.assert_called_once()
        self.assertEqual(ps.call_args.args[0],
                         ["ps", "-Aww", "-o", "pid=", "-o", "ppid=", "-o", "%cpu=", "-o", "comm="])

    def test_refuses_quiet_sample_when_process_listing_fails(self):
        args = argparse.Namespace(wait_left=0, budget=0, min_idle=0.5)
        failed = runner.subprocess.CompletedProcess("ps", 1, stdout="", stderr="ps: permission denied\n")
        with mock.patch.object(runner, "cpu_idle", return_value=0.9), \
             mock.patch.object(runner.subprocess, "run", return_value=failed) as ps, \
             self.assertRaisesRegex(runner.StepFailed, r"ps .*%cpu= .*comm= exited 1\nps: permission denied"):
            runner.wait_for_quiet_machine(args, [])
        ps.assert_called_once()

    def test_busiest_names_any_busy_process_busiest_first_but_not_ours(self):
        table = "\n".join([
            "  20     1  40.0 /usr/bin/python3",
            "  21     1  95.0 /Applications/Xcode.app/Contents/MacOS/Xcode",
            "  22   500  99.0 /opt/homebrew/bin/godot",
            "  500    1  99.0 /usr/bin/python3",
            "  23     1   5.0 /usr/sbin/idle_daemon",
            "  24     1  60.0 /usr/bin/swift-frontend",
            "  25     x  90.0 /bin/broken",
            "garbage line",
        ])
        self.assertEqual(runner.busiest_processes(table, mine=500, limit=2),
                         ["21 Xcode 95% cpu", "24 swift-frontend 60% cpu"])
        self.assertEqual(runner.busiest_processes("", mine=500), [])

    def test_busiest_names_load_spread_over_small_processes(self):
        table = "\n".join(f"  {pid}     1  12.0 /usr/libexec/mdworker_shared" for pid in (30, 31, 32))
        self.assertEqual(runner.competing_processes(table, mine=500), [])
        self.assertEqual(len(runner.busiest_processes(table, mine=500)), 3)
        self.assertEqual(runner.busiest_processes("  33     1   0.5 /usr/sbin/quiet", mine=500), [])

    def test_busiest_names_macos_apps_by_bundle_not_by_first_word(self):
        table = "  40     1  70.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        self.assertEqual(runner.busiest_processes(table, mine=500), ["40 Google Chrome 70% cpu"])
        self.assertEqual(runner.process_name("/usr/bin/swift-frontend"), "swift-frontend")
        self.assertEqual(runner.process_name("kernel_task"), "kernel_task")
        self.assertEqual(runner.process_name("/Applications/Xcode.app/Contents/Resources/helper"), "helper")

    def test_busy_sample_reports_executable_names(self):
        args = argparse.Namespace(wait_left=0, budget=0, min_idle=0.5, poll_seconds=15)
        table = ("  40     1  70.0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n"
                 "  41     1  80.0 /usr/bin/find\n")
        listing = runner.subprocess.CompletedProcess("ps", 0, stdout=table, stderr="")
        log = []
        with mock.patch.object(runner, "cpu_idle", return_value=0.1), \
             mock.patch.object(runner.os, "getpid", return_value=500), \
             mock.patch.object(runner.subprocess, "run", return_value=listing) as ps, \
             self.assertRaisesRegex(runner.Deferred, "busiest processes: 41 find 80% cpu, 40 Google Chrome 70% cpu"):
            runner.wait_for_quiet_machine(args, log)
        ps.assert_called_once()
        self.assertEqual(log[0]["busy"], ["cpu 10% idle, below 50%",
                                         "busiest processes: 41 find 80% cpu, 40 Google Chrome 70% cpu"])

    def test_busiest_explains_low_idle_only_when_no_competitor_does(self):
        busiest = ["21 Xcode 95% cpu"]
        self.assertEqual(runner.load_gate(0.0, [], 0.5, busiest),
                         ["cpu 0% idle, below 50%", "busiest processes: 21 Xcode 95% cpu"])
        with_competitor = runner.load_gate(0.0, ["10 godot 95% cpu"], 0.5, busiest)
        self.assertNotIn("busiest processes: 21 Xcode 95% cpu", with_competitor)

    def test_busiest_never_makes_a_quiet_machine_busy(self):
        self.assertEqual(runner.load_gate(0.7, [], 0.5, ["21 Xcode 95% cpu"]), [])
        self.assertEqual(runner.load_gate(None, [], 0.5, ["21 Xcode 95% cpu"]), ["cpu idle unknown"])


class TimeBudget(unittest.TestCase):
    def args(self, **overrides):
        values = dict(started=0.0, wait_left=0.0, poll_seconds=15, budget=10, min_idle=0.5)
        return argparse.Namespace(**(values | overrides))

    def test_estimate_counts_builds_only_for_unbuilt_worktrees(self):
        built = runner.work_estimate([True], "quick", 3)
        self.assertEqual(runner.work_estimate([False], "quick", 3), built + runner.ESTIMATE_S["build"])
        self.assertGreater(runner.work_estimate([True], "full", 3), built)
        self.assertEqual(runner.work_estimate([], "quick", 3), 0)

    def test_allowance_is_what_the_work_leaves_and_never_negative(self):
        self.assertEqual(runner.wait_allowance(600, 0, 200), 400)
        self.assertEqual(runner.wait_allowance(600, 500, 200), 0)

    def test_refuses_to_wait_once_the_allowance_is_spent(self):
        args = self.args()
        with mock.patch.object(runner, "load_gate", return_value=["cpu busy"]), \
             mock.patch.object(runner, "cpu_idle", return_value=0.1), \
             mock.patch.object(runner, "process_table", return_value=""), \
             mock.patch.object(runner.time, "monotonic", return_value=30), \
             mock.patch.object(runner.time, "sleep") as sleep, self.assertRaises(runner.Deferred):
            runner.wait_for_quiet_machine(args, [])
        sleep.assert_not_called()

    def test_quiet_machine_runs_without_wait_allowance_if_budget_remains(self):
        with mock.patch.object(runner, "cpu_idle", return_value=0.9), \
             mock.patch.object(runner, "process_table", return_value=""), \
             mock.patch.object(runner.time, "monotonic", return_value=30):
            self.assertEqual(runner.wait_for_quiet_machine(self.args(), [])["busy"], [])

    def test_wont_sleep_past_the_run_budget_with_waiting_allowance_left(self):
        with mock.patch.object(runner, "cpu_idle", return_value=0.1), \
             mock.patch.object(runner, "process_table", return_value=""), \
             mock.patch.object(runner.time, "monotonic", return_value=590), \
             mock.patch.object(runner.time, "sleep") as sleep, self.assertRaisesRegex(runner.Deferred, "busy"):
            runner.wait_for_quiet_machine(self.args(wait_left=120), [])
        sleep.assert_not_called()

    def test_refuses_to_sample_after_the_run_budget_expires(self):
        with mock.patch.object(runner, "cpu_idle", return_value=0.9) as sample, \
             mock.patch.object(runner, "process_table", return_value=""), \
             mock.patch.object(runner.time, "monotonic", return_value=600), \
             self.assertRaisesRegex(runner.Deferred, "budget.*expired"):
            runner.wait_for_quiet_machine(self.args(), [])
        sample.assert_not_called()

    def test_refuses_a_quiet_sample_that_finishes_after_the_budget(self):
        elapsed = 599

        def cpu_idle():
            nonlocal elapsed
            elapsed = 600
            return 0.9

        with mock.patch.object(runner, "cpu_idle", side_effect=cpu_idle), \
             mock.patch.object(runner, "process_table", return_value=""), \
             mock.patch.object(runner.time, "monotonic", side_effect=lambda: elapsed), \
             self.assertRaisesRegex(runner.Deferred, "budget.*expired"):
            runner.wait_for_quiet_machine(self.args(), [])

    def test_last_round_over_budget_defers_but_saves_a_complete_record(self):
        elapsed = 0

        def perf_round(*_):
            nonlocal elapsed
            elapsed += 30
            return {"errors": [], "metrics": {}}

        args = self.args(rev="a", godot="godot", scons=None, scenario=SCENARIO, tier="quick", rounds=2, budget=1)
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            archive = runner.Archive(repo)
            with mock.patch.object(pc, "machine_identity", return_value={"machine": "m", "machine_label": "test"}), \
                 mock.patch.object(pc, "toolchain_identity", return_value={"toolchain": "build-1"}), \
                 mock.patch.object(pc, "resolve", return_value=("a" * 40, "test")), \
                 mock.patch.object(pc, "prepare_worktree", return_value=repo), \
                 mock.patch.object(pc, "golden_check", return_value={"passed": True}), \
                 mock.patch.object(runner, "cpu_idle", return_value=0.9), \
                 mock.patch.object(runner, "process_table", return_value=""), \
                 mock.patch.object(pc, "perf_round", side_effect=perf_round) as measure, \
                 mock.patch.object(runner.time, "monotonic", side_effect=lambda: elapsed), \
                 self.assertRaisesRegex(runner.Deferred, "budget.*expired"):
                pc.command_measure(args, repo, archive)
            self.assertEqual(measure.call_count, 2)
            entry = json.loads((repo / "index.jsonl").read_text())
            saved = json.loads((Path(entry["path"]) / "record.json").read_text())
            self.assertEqual(saved["status"], "complete")
            self.assertEqual(len(saved["rounds"]), 2)

    def test_zero_budget_is_unlimited(self):
        with mock.patch.object(runner, "cpu_idle", return_value=0.9), \
             mock.patch.object(runner, "process_table", return_value=""), \
             mock.patch.object(runner.time, "monotonic", return_value=1000):
            self.assertEqual(runner.wait_for_quiet_machine(self.args(budget=0), [])["busy"], [])

    def test_refuses_negative_budget_and_impossible_idle_floor(self):
        command = ["compare", "a", "b", "--claim", "run_ms"]
        for value in ("-1", "nan", "inf"):
            with self.subTest(budget=value), contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(pc.main([*command, "--budget", value]), pc.EXIT_USAGE)
                self.assertIn("--budget", stderr.getvalue())
        for value in ("0", "1.5"):
            with self.subTest(min_idle=value):
                self.assertEqual(pc.main([*command, "--min-idle", value]), pc.EXIT_USAGE)


class BuildRecipe(unittest.TestCase):
    def test_refuses_cached_measurement_tree_from_a_different_toolchain(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            repo.mkdir()
            runner.git(repo, "init", "-q")
            runner.git(repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                       "commit", "--allow-empty", "-qm", "baseline")
            commit = runner.git(repo, "rev-parse", "HEAD")
            archive = runner.Archive(Path(tmp) / "archive")
            cached = archive.worktrees / commit[:12]
            runner.add_worktree(repo, cached, commit)
            (cached / ".perf-built").write_text(f"{commit}\nold-toolchain\n")
            args = argparse.Namespace(toolchain="old-toolchain")
            self.assertEqual(runner.prepare_worktree(repo, archive, commit, args, repo, []), cached)
            args.toolchain = "new-toolchain"
            with mock.patch.object(runner, "wait_for_quiet_machine"), \
                 mock.patch.object(runner, "compile_commit", side_effect=runner.StepFailed("rebuilding")), \
                 self.assertRaisesRegex(runner.StepFailed, "rebuilding"):
                runner.prepare_worktree(repo, archive, commit, args, repo, [])
            self.assertFalse(cached.exists())

    def test_refuses_to_overwrite_an_existing_unmanaged_archive_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = runner.Archive(Path(tmp))
            archive.build.mkdir()
            receipt = archive.build / "personal-file"
            receipt.write_text("keep this")
            with self.assertRaisesRegex(runner.StepFailed, "not a managed worktree"):
                runner.compile_commit(Path(tmp), archive, "a" * 40, None, Path(tmp))
            self.assertEqual(receipt.read_text(), "keep this")

    def test_builds_only_the_debug_target_the_headless_editor_loads(self):
        command = runner.scons_command("Darwin", "arm64", 8)
        self.assertIn("target=template_debug", command)
        self.assertNotIn("target=template_release", command)
        self.assertIn("arch=arm64", command)

    def test_checked_in_libraries_of_other_platforms_do_not_count_as_built(self):
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / runner.PROJECT / runner.LIBRARY_DIR
            (bin_dir / "android").mkdir(parents=True)
            (bin_dir / "android" / "libdots_ext.android.template_debug.arm64.so").write_text("x")
            (bin_dir / "macos").mkdir()
            (bin_dir / "macos" / "libdots_ext.macos.template_release.arm64.dylib").write_text("x")
            self.assertEqual(runner.debug_libraries(Path(tmp), "Darwin", "arm64"), [])
            built = bin_dir / "macos" / "libdots_ext.macos.template_debug.arm64.dylib"
            built.write_text("x")
            self.assertEqual(runner.debug_libraries(Path(tmp), "Darwin", "arm64"), [built])

    def test_refuses_unknown_platform_or_architecture(self):
        for system, machine in (("SunOS", "x86_64"), ("Darwin", "riscv64")):
            with self.subTest(system=system, machine=machine), self.assertRaises(runner.StepFailed):
                runner.scons_command(system, machine, 8)

    def test_refuses_to_start_build_while_machine_is_busy(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            archive = runner.Archive(repo)
            args = argparse.Namespace(started=runner.time.monotonic(), wait_left=0,
                                      budget=10, min_idle=0.5, poll_seconds=15, toolchain="build-1")
            with mock.patch.object(runner, "cpu_idle", return_value=0.1), \
                 mock.patch.object(runner, "process_table", return_value=""), \
                 mock.patch.object(runner, "compile_commit") as compile_commit, \
                 mock.patch.object(runner, "git") as git, self.assertRaisesRegex(runner.Deferred, "busy"):
                runner.prepare_worktree(repo, archive, "a" * 40, args, repo, [])
            compile_commit.assert_not_called()
            git.assert_not_called()

    def test_refuses_to_import_if_the_machine_became_busy_during_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            archive = runner.Archive(repo)
            args = argparse.Namespace(started=runner.time.monotonic(), wait_left=0,
                                      budget=10, min_idle=0.5, poll_seconds=15, toolchain="build-1")
            with mock.patch.object(runner, "cpu_idle", side_effect=[0.9, 0.1]), \
                 mock.patch.object(runner, "process_table", return_value=""), \
                 mock.patch.object(runner, "compile_commit", return_value=[]) as compile_commit, \
                 mock.patch.object(runner, "add_worktree"), mock.patch.object(runner, "run") as run, \
                 self.assertRaisesRegex(runner.Deferred, "busy"):
                runner.prepare_worktree(repo, archive, "a" * 40, args, repo, [])
            compile_commit.assert_called_once()
            run.assert_not_called()
