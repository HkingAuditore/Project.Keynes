"""perf_change_check decides whether a performance change may proceed (AGENTS.md rule 6).

Each gate, parser and classifier is fed inputs it must refuse, not only good ones.
Run: python -m unittest discover -s tools/perf/tests -v
"""
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
IDENTITY = {"scenario": SCENARIO, "method_version": pc.METHOD_VERSION, "machine_label": "Mac",
            "toolchain_label": "godot"}


class ResultLineParsing(unittest.TestCase):
    def test_reads_single_line(self):
        lines = ["noise", "[headless-perf/result] days=50 fatal=false path=/x/perf.csv"]
        self.assertEqual(metrics.parse_kv_line(lines, metrics.RESULT_PREFIX)["path"], "/x/perf.csv")

    def test_preserves_the_unquoted_trailing_path_with_spaces(self):
        lines = ["[headless-perf/result] days=50 fatal=false path=/a b/c=x/perf.csv"]
        self.assertEqual(metrics.parse_kv_line(lines, metrics.RESULT_PREFIX),
                         {"days": "50", "fatal": "false", "path": "/a b/c=x/perf.csv"})

    def test_refuses_missing_duplicate_empty_and_repeated_keys(self):
        for lines in ([], ["[headless-perf/result] days=1", "[headless-perf/result] days=1"],
                      ["[headless-perf/result] nothing here"],
                      ["[headless-perf/result] days=1 days=2"]):
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                metrics.parse_kv_line(lines, metrics.RESULT_PREFIX)


class MetricClassification(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(metrics.metric_kind("csv.bd_economy_scan_cells.per_day"), "counter")
        self.assertEqual(metrics.metric_kind("csv.t_sus_ms.p95"), "timing")
        self.assertEqual(metrics.metric_kind("rusage.maxrss_mb"), "cost")
        self.assertEqual(metrics.metric_kind("rusage.cpu_s"), "timing")
        self.assertEqual(metrics.metric_kind("result.population"), "gauge")
        self.assertEqual(metrics.direction("auth.authoritative_days_per_second"), "higher")

    def test_improvement_needs_a_clear_gap(self):
        row = metrics.compare_metric("csv.t_sus_ms.mean", [10, 10.5, 11], [7, 7.2, 7.4])
        self.assertEqual(row["status"], "improved")

    def test_refuses_improvement_inside_noise(self):
        row = metrics.compare_metric("csv.t_sus_ms.mean", [10, 10.2, 10.4], [9.0, 9.1, 9.2])
        self.assertEqual(row["status"], "within_noise")

    def test_refuses_improvement_when_ranges_overlap(self):
        row = metrics.compare_metric("csv.t_sus_ms.mean", [6, 10, 14], [5, 7, 13])
        self.assertEqual(row["status"], "within_noise")

    def test_refuses_timing_verdict_from_one_round(self):
        row = metrics.compare_metric("csv.t_sus_ms.mean", [10], [5])
        self.assertEqual(row["status"], "insufficient_rounds")

    def test_higher_is_better_for_throughput(self):
        row = metrics.compare_metric("auth.authoritative_days_per_second", [30, 31, 32], [20, 21, 22])
        self.assertEqual(row["status"], "regressed")

    def test_counters_compare_exactly(self):
        self.assertEqual(metrics.compare_metric("csv.scan_steps_x.per_day", [5, 5], [3, 3])["status"], "less_work")
        self.assertEqual(metrics.compare_metric("csv.scan_steps_x.per_day", [5, 5], [5, 5])["status"], "unchanged")

    def test_refuses_exact_verdict_for_a_counter_that_varies(self):
        row = metrics.compare_metric("csv.scan_steps_x.per_day", [5, 6, 7], [3, 3, 3])
        self.assertNotIn(row["status"], ("less_work", "unchanged"))

    def test_memory_that_repeats_exactly_counts_as_less_or_more_work(self):
        self.assertEqual(metrics.metric_kind("csv.economy_memory_bytes.mean"), "cost")
        self.assertEqual(metrics.compare_metric("csv.economy_memory_bytes.mean", [900, 900], [600, 600])["status"],
                         "less_work")
        self.assertEqual(metrics.compare_metric("csv.economy_memory_bytes.mean", [600, 600], [900, 900])["status"],
                         "more_work")

    def test_refuses_exact_verdict_for_memory_that_varies(self):
        row = metrics.compare_metric("csv.economy_memory_bytes.mean", [900, 905, 910], [890, 895, 899])
        self.assertEqual(row["status"], "within_noise")

    def test_gauges_without_a_direction_are_only_changed(self):
        self.assertEqual(metrics.compare_metric("result.population", [100, 100], [90, 90])["status"], "changed")

    def test_metric_missing_on_one_side(self):
        self.assertEqual(metrics.compare_metric("waterfall.total_ms.p95", [], [1, 2])["status"], "only_in_head")


class CsvSummaries(unittest.TestCase):
    def test_counters_become_per_day_increase_and_timings_get_tail(self):
        rows = [{"bd_economy_scan_a": "0", "t_sus_ms": "1", "label": "x", "unused_ms": ""},
                {"bd_economy_scan_a": "10", "t_sus_ms": "3", "label": "", "unused_ms": ""},
                {"bd_economy_scan_a": "20", "t_sus_ms": "2", "label": "x", "unused_ms": ""}]
        summary = metrics.csv_metrics(rows)
        self.assertEqual(summary["csv.bd_economy_scan_a.per_day"], 10)
        self.assertEqual(summary["csv.t_sus_ms.max"], 3)
        self.assertNotIn("csv.label.mean", summary)
        self.assertNotIn("csv.unused_ms.mean", summary)

    def test_sparse_counters_use_elapsed_days_between_samples(self):
        rows = [{"scan_steps_a": "", "scan_steps_b": ""},
                {"scan_steps_a": "0", "scan_steps_b": ""},
                {"scan_steps_a": "", "scan_steps_b": "3"},
                {"scan_steps_a": "6", "scan_steps_b": ""},
                {"scan_steps_a": "", "scan_steps_b": ""}]
        self.assertEqual(metrics.csv_metrics(rows), {"csv.scan_steps_a.per_day": 3})

    def test_refuses_nonnumeric_populated_cells_in_a_numeric_column(self):
        for bad in ("invalid", "nan"):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "market_ms"):
                metrics.csv_metrics([{"market_ms": "1"}, {"market_ms": ""}, {"market_ms": bad}])

    def test_fewer_research_fallback_scans_satisfy_a_claim(self):
        for name in ("research_full_scan_fallbacks", "bd_country_research_full_scan_fallbacks"):
            with self.subTest(name=name):
                base = metrics.csv_metrics([{name: "7"}, {name: "9"}, {name: "11"}])
                head = metrics.csv_metrics([{name: "7"}, {name: "8"}, {name: "9"}])
                row, = metrics.compare_rounds([base, base], [head, head])
                self.assertEqual(row["metric"], f"csv.{name}.per_day")
                self.assertEqual(row["status"], "less_work")
                self.assertEqual(metrics.judge([], [], [row], [name]), ("pass", []))


class GoldenComparison(unittest.TestCase):
    def test_identical_results_pass(self):
        value = {"days": [{"day": 1, "domain_hashes": {"ECONOMY": "1"}}]}
        self.assertIsNone(metrics.first_difference(value, value))

    def test_refuses_changed_hash_length_type_and_keys(self):
        base = {"days": [{"day": 1, "domain_hashes": {"ECONOMY": "1"}}]}
        for head in ({"days": [{"day": 1, "domain_hashes": {"ECONOMY": "2"}}]},
                     {"days": []}, {"days": {}},
                     {"days": [{"day": 1, "domain_hashes": {"CLIMATE": "1"}}]}):
            with self.subTest(head=head):
                self.assertIsNotNone(metrics.first_difference(base, head))


class Judgement(unittest.TestCase):
    ROWS = [{"metric": "csv.t_sus_ms.mean", "status": "improved", "change": -0.3},
            {"metric": "result.run_ms", "status": "within_noise", "change": -0.05}]

    def test_pass_when_claim_improves(self):
        self.assertEqual(metrics.judge([], [], self.ROWS, [r"t_sus_ms"]), ("pass", []))

    def test_refuses_pass_when_results_changed_or_runs_invalid(self):
        self.assertEqual(metrics.judge(["hash differs"], [], self.ROWS, [])[0], "fail")
        self.assertEqual(metrics.judge([], ["round 1: fatal"], self.ROWS, [])[0], "fail")

    def test_refuses_pass_when_claim_missing_or_not_improved(self):
        self.assertEqual(metrics.judge([], [], self.ROWS, [])[0], "needs_human")
        self.assertEqual(metrics.judge([], [], self.ROWS, [r"no_such_metric"])[0], "needs_human")
        self.assertEqual(metrics.judge([], [], self.ROWS, [r"run_ms"])[0], "needs_human")

    def test_refuses_pass_when_the_claim_is_unmeasured(self):
        """Found by the first fresh-session run: a claim needing an open overlay has no headless metric."""
        status, reasons = metrics.judge([], [], self.ROWS, [], "needs an open overlay")
        self.assertEqual(status, "needs_human")
        self.assertEqual(reasons, ["claim not measured headlessly: needs an open overlay"])
        self.assertEqual(metrics.judge(["hash differs"], [], self.ROWS, [], "overlay")[0], "fail")
        self.assertEqual(metrics.judge([], ["round 1: fatal"], self.ROWS, [], "overlay")[0], "fail")
        # Found by Qodo on b05f8fc: a measurable claim given next to --unmeasured is still judged.
        status, reasons = metrics.judge([], [], self.ROWS, [r"t_sus_ms"], "overlay")
        self.assertEqual((status, reasons), ("needs_human", ["claim not measured headlessly: overlay"]))
        args = pc.parse_args(["compare", "a", "b", "--claim", "t_sus_ms", "--unmeasured", "overlay"])
        self.assertEqual((args.claim, args.unmeasured), (["t_sus_ms"], "overlay"))
        for pattern in (r"no_such_metric", r"run_ms"):
            with self.subTest(pattern=pattern):
                status, reasons = metrics.judge([], [], self.ROWS, [pattern], "overlay")
                self.assertEqual(status, "needs_human")
                self.assertTrue(any(pattern in reason for reason in reasons))
        regressed = [self.ROWS[0], metrics.compare_metric("result.run_ms", [10, 10], [14, 14])]
        status, reasons = metrics.judge([], [], regressed, [], "overlay")
        self.assertEqual(status, "needs_human")
        self.assertTrue(any("result.run_ms" in reason for reason in reasons))

    def test_refuses_pass_when_headline_regressed(self):
        for metric, base, head in (("result.run_ms", [10, 10], [14, 14]),
                                   ("rusage.maxrss_mb", [600, 600], [601, 601])):
            with self.subTest(metric=metric):
                rows = [self.ROWS[0], metrics.compare_metric(metric, base, head)]
                status, reasons = metrics.judge([], [], rows, ["t_sus_ms"])
                self.assertEqual(status, "needs_human")
                self.assertTrue(any(metric in reason for reason in reasons))

    def test_refuses_pass_when_any_metric_in_a_claim_regresses(self):
        for metric, base, head in (("csv.household_market_ms.p95", [10, 10], [14, 14]),
                                   ("csv.household_market_memory_bytes.mean", [500, 500], [501, 501])):
            with self.subTest(metric=metric):
                rows = [
                    metrics.compare_metric("csv.household_market_ms.mean", [10, 10], [6, 6]),
                    metrics.compare_metric(metric, base, head),
                ]
                status, reasons = metrics.judge([], [], rows, ["household_market"])
                self.assertEqual(status, "needs_human")
                self.assertTrue(any(metric in reason for reason in reasons))

    def test_refuses_pass_if_an_unclaimed_measurement_is_missing(self):
        base = {"result.run_ms": 100, "csv.optional_ms.max": 10}
        head = {"result.run_ms": 65, "csv.optional_ms.max": 10}
        base_missing, head_missing = {"result.run_ms": 100}, {"result.run_ms": 65}
        for base_rounds, head_rounds in (([base] * 3, [head_missing] * 3),
                                         ([base] * 3, [head, head_missing, head]),
                                         ([base_missing] * 3, [head] * 3)):
            with self.subTest(base_rounds=base_rounds, head_rounds=head_rounds):
                rows = metrics.compare_rounds(base_rounds, head_rounds)
                status, reasons = metrics.judge([], [], rows, ["result.run_ms"])
                self.assertEqual(status, "fail")
                self.assertTrue(any("csv.optional_ms.max" in reason for reason in reasons))


class Assessment(unittest.TestCase):
    """Found on the first real run: an invalid round used to skip the base/head result comparison."""

    def side(self, tmp, name, hashes, errors):
        candidate = Path(tmp) / f"{name}.json"
        candidate.write_text(json.dumps({"days": [{"day": 1, "domain_hashes": hashes}]}))
        rounds = [{"metrics": {"result.run_ms": 100.0 + i}, "errors": list(e),
                   "recorder_method": "day_records_worker_v1"} for i, e in enumerate(errors)]
        return {"identity": {"commit": name * 12}, "golden": {"passed": True, "candidate": str(candidate)},
                "rounds": rounds}

    def test_refuses_throughput_comparison_between_different_recorder_methods(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [[], [], []])
            head = self.side(tmp, "b", {"ECONOMY": "1"}, [[], [], []])
            for run in base["rounds"]:
                run["recorder_method"] = "unversioned:foreground"
                run["metrics"]["auth.authoritative_days_per_second"] = 50
                run["metrics"]["harness.adjusted_days_per_second"] = 50
            for run in head["rounds"]:
                run["metrics"]["auth.authoritative_days_per_second"] = 100
                run["metrics"]["harness.adjusted_days_per_second"] = 100
            verdict = pc.assess(base, head, ["days_per_second"], metrics.NOISE)
        self.assertEqual(verdict["status"], "needs_human")
        self.assertEqual(verdict["rows"], [])
        self.assertIn("incompatible recorder methods", verdict["reasons"][0])

    def test_refuses_a_record_with_mixed_or_missing_methods(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [[], [], []])
            head = self.side(tmp, "b", {"ECONOMY": "1"}, [[], [], []])
            for method in ("day_records_main_v1", None):
                with self.subTest(method=method):
                    head["rounds"][0]["recorder_method"] = method
                    verdict = pc.assess(base, head, ["result.run_ms"], metrics.NOISE)
                    self.assertEqual(verdict["status"], "fail")
                    self.assertEqual(verdict["rows"], [])
                    self.assertIn("inconsistent recorder methods", verdict["reasons"][0])

    def test_result_difference_is_reported_even_when_a_round_is_invalid(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [["exit=6"], [], []])
            head = self.side(tmp, "b", {"ECONOMY": "2"}, [[], [], []])
            verdict = pc.assess(base, head, [], metrics.NOISE)
        self.assertEqual(verdict["status"], "fail")
        self.assertTrue(any("differ" in reason for reason in verdict["reasons"]))
        self.assertTrue(any("exit=6" in reason for reason in verdict["reasons"]))

    def test_invalid_rounds_are_left_out_of_the_statistics(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [["exit=6"], [], []])
            head = self.side(tmp, "b", {"ECONOMY": "1"}, [[], [], []])
            verdict = pc.assess(base, head, [], metrics.NOISE)
        row, = [r for r in verdict["rows"] if r["metric"] == "result.run_ms"]
        self.assertEqual(row["base"], [101.0, 102.0])
        self.assertEqual(verdict["excluded_rounds"], ["base round 1: exit=6"])

    def test_quick_comparison_can_reuse_a_full_tier_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [[], []])
            head = self.side(tmp, "b", {"ECONOMY": "1"}, [[], []])
            base["tier"] = "full"
            base["load_consistency"] = {"passed": True}
            head["tier"] = "quick"
            for run in base["rounds"]:
                run["metrics"]["waterfall.total_ms.mean"] = 100
            for run in head["rounds"]:
                run["metrics"]["result.run_ms"] = 60
            verdict = pc.assess(base, head, ["result.run_ms"], metrics.NOISE)
        self.assertEqual(verdict["status"], "pass")
        self.assertEqual([row["metric"] for row in verdict["rows"]], ["result.run_ms"])

    def test_report_uses_the_round_counts_from_the_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [[], [], [], []])
            head = self.side(tmp, "b", {"ECONOMY": "1"}, [[], [], []])
            for saved in (base, head):
                saved["identity"] = IDENTITY | saved["identity"]
            base["reused"] = True
            base["created"] = "2026-11-24T12:00:00Z"
            for run in head["rounds"]:
                run["metrics"]["result.run_ms"] = 60
            args = pc.parse_args(["compare", "a", "b", "--claim", "result.run_ms", "--out", tmp])
            args.started = runner.time.monotonic()
            with mock.patch.object(pc, "ensure_records", return_value=[base, head]), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pc.command_compare(args, repo, runner.Archive(repo)), pc.EXIT_PASS)
            report = json.loads((repo / "report.json").read_text())
            self.assertEqual(report["requested_rounds"], 3)
            self.assertEqual(report["base"]["rounds"], 4)
            self.assertEqual(report["head"]["rounds"], 3)
            self.assertIn("base 4 rounds, head 3 rounds", (repo / "report.md").read_text())

    def test_unmeasured_claim_still_checks_results_and_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            base = self.side(tmp, "a", {"ECONOMY": "1"}, [[], [], []])
            head = self.side(tmp, "b", {"ECONOMY": "1"}, [[], [], []])
            for saved in (base, head):
                saved["identity"] = IDENTITY | saved["identity"]
            args = pc.parse_args(["compare", "a", "b", "--unmeasured", "needs an open overlay", "--out", tmp])
            args.started = runner.time.monotonic()
            with mock.patch.object(pc, "ensure_records", return_value=[base, head]), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pc.command_compare(args, repo, runner.Archive(repo)), pc.EXIT_HUMAN)
            report = json.loads((repo / "report.json").read_text())
            self.assertEqual(report["claims"], [])
            self.assertEqual(report["unmeasured"], "needs an open overlay")
            markdown = (repo / "report.md").read_text()
            self.assertIn("daily per-domain hashes of base and head are identical", markdown)
            self.assertIn("Claim not measured headlessly: needs an open overlay", markdown)
            head["golden"]["candidate"] = self.side(tmp, "c", {"ECONOMY": "2"}, [])["golden"]["candidate"]
            with mock.patch.object(pc, "ensure_records", return_value=[base, head]), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pc.command_compare(args, repo, runner.Archive(repo)), pc.EXIT_FAIL)


class ArgumentChecks(unittest.TestCase):
    def test_refuses_single_round_and_nonpositive_scenario(self):
        self.assertEqual(pc.main(["compare", "a", "b", "--claim", "run_ms", "--rounds", "1"]), pc.EXIT_USAGE)
        self.assertEqual(pc.main(["measure", "a", "--days", "0"]), pc.EXIT_USAGE)

    def test_compare_requires_an_explicit_nonempty_claim(self):
        for flags in ([], ["--claim", ""], ["--claim", "["]):
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(pc.main(["compare", "a", "b", *flags]), pc.EXIT_USAGE)
                self.assertIn("--claim", stderr.getvalue())

    def test_unmeasured_needs_a_reason(self):
        for flags in (["--unmeasured", ""], ["--unmeasured", "  "]):
            with self.subTest(flags=flags), contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(pc.main(["compare", "a", "b", *flags]), pc.EXIT_USAGE)
                self.assertIn("--unmeasured", stderr.getvalue())

    def test_history_starts_without_unix_fcntl(self):
        with mock.patch.dict(sys.modules, {"fcntl": None}), \
             mock.patch.object(runner.platform, "system", return_value="Windows"), \
             tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()) as stdout:
            main = runpy.run_path(pc.__file__)["main"]
            self.assertEqual(main(["--home", tmp, "history"]), pc.EXIT_PASS)
            self.assertIn("archive is empty", stdout.getvalue())
            self.assertEqual(main(["--home", tmp, "measure", "a"]), pc.EXIT_FAIL)
            self.assertIn("macOS or Linux", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
