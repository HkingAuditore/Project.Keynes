"""Factory tests: the verdict, the ticket gate, plan parsing and the guard list. Stdlib only."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import agent  # noqa: E402
import checks  # noqa: E402
from common import load_config  # noqa: E402
from run import claimable  # noqa: E402
from ticket import criteria, gate, touching  # noqa: E402
from verdict import Facts, classify, judge  # noqa: E402

HEAD = "abc123"


def ready(**kw) -> Facts:
    base = dict(head=HEAD, checks_sha=HEAD, review_status="completed", review_sha=HEAD,
                ci_state="success", findings=[])
    base.update(kw)
    return Facts(**base)


def finding(fid, status="pending", level="action_required"):
    return {"id": fid, "attribution_status": status, "action_level": level, "title": f"t{fid}"}


class VerdictTest(unittest.TestCase):
    def test_native_change_needs_rebuild_and_runtime_evidence(self):
        native = dict(native_changed=True, native_rebuilt=True, native_runtime_ok=True)
        self.assertEqual(judge(ready(**native)).verdict, "READY")
        for fact in ("native_rebuilt", "native_runtime_ok"):
            with self.subTest(fact=fact):
                self.assertEqual(judge(ready(**(native | {fact: False}))).verdict, "NEEDS_HUMAN")

    def test_ready_needs_every_fact(self):
        self.assertEqual(judge(ready()).verdict, "READY")

    def test_review_of_older_commit_is_not_done(self):
        self.assertEqual(judge(ready(review_sha="old")).verdict, "NOT_DONE")

    def test_review_still_running_is_not_done(self):
        self.assertEqual(judge(ready(review_status="started")).verdict, "NOT_DONE")

    def test_checks_on_another_commit_are_not_done(self):
        self.assertEqual(judge(ready(checks_sha="old")).verdict, "NOT_DONE")

    def test_ci_pending_is_not_done(self):
        self.assertEqual(judge(ready(ci_state="pending")).verdict, "NOT_DONE")
        self.assertEqual(judge(ready(ci_state=None)).verdict, "NOT_DONE")

    def test_ci_failure_needs_fix(self):
        self.assertEqual(judge(ready(ci_state="failure")).verdict, "NEEDS_FIX")

    def test_ci_read_error_needs_human_even_with_missing_evidence(self):
        for review_status in ("completed", "started"):
            with self.subTest(review_status=review_status):
                v = judge(ready(ci_state="error", review_status=review_status, findings=[finding("x")]))
                self.assertEqual(v.verdict, "NEEDS_HUMAN")
                self.assertIn("the CI state could not be read", v.reasons)

    def test_each_open_status_blocks(self):
        for s in ("pending", "partial_implementation", "not_implemented", "focus_areas_edited"):
            self.assertEqual(judge(ready(findings=[finding(1, s)])).verdict, "NEEDS_FIX", s)

    def test_closed_findings_do_not_block(self):
        for s in ("implemented", "full_implementation", "dismissed", "detected_after_merge", "outdated"):
            self.assertEqual(judge(ready(findings=[finding(1, s)])).verdict, "READY", s)

    def test_informational_is_listed_not_blocking(self):
        v = judge(ready(findings=[finding(1, level="informational")]))
        self.assertEqual(v.verdict, "READY")
        self.assertEqual(len(v.for_human), 1)

    def test_unknown_status_needs_human(self):
        self.assertEqual(judge(ready(findings=[finding(1, "weird")])).verdict, "NEEDS_HUMAN")

    def test_unknown_or_missing_action_level_needs_human(self):
        for item in (finding(1, level="new_level"), {"id": 1, "attribution_status": "pending"}):
            with self.subTest(item=item):
                self.assertEqual(classify(item), "unknown")
                v = judge(ready(findings=[item]))
                self.assertEqual(v.verdict, "NEEDS_HUMAN")
                self.assertIn("action_level=", v.reasons[0])
                self.assertFalse(v.for_human)

    def test_rejected_check_needs_human_even_with_other_evidence(self):
        command = "tools/ci/check_committed_replay.py --checkpoint --trace --days 10"
        v = judge(ready(rejected_checks=[command]))
        self.assertEqual(v.verdict, "NEEDS_HUMAN")
        self.assertIn(command, v.reasons[0])

    def test_master_failures_alone_do_not_need_a_person(self):
        # A run only reaches a verdict with a pushed head once every check passed,
        # so failures master had before the change are history, not a reason to stop.
        self.assertEqual(judge(ready(base_failures=["regression"])).verdict, "READY")

    def test_new_failures_need_fix(self):
        self.assertEqual(judge(ready(new_failures=["regression"])).verdict, "NEEDS_FIX")

    def test_round_limit_reached_needs_human(self):
        f = ready(findings=[finding(1)], review_rounds=3, review_round_limit=3)
        self.assertEqual(judge(f).verdict, "NEEDS_HUMAN")
        f = ready(findings=[finding(1)], review_rounds=2, review_round_limit=3)
        self.assertEqual(judge(f).verdict, "NEEDS_FIX")

    def test_human_reasons_win(self):
        cases = [dict(stopped_by="x"), dict(plan_questions=["q"]), dict(disagreements=["d"]),
                 dict(human_paths=["tools/ci/size_baseline.json"]),
                 dict(native_changed=True), dict(local_blocking=["L1"]), dict(review_stalled=True)]
        for kw in cases:
            self.assertEqual(judge(ready(**kw)).verdict, "NEEDS_HUMAN", kw)


class TicketTest(unittest.TestCase):
    BODY = "Intro\n\n## Acceptance criteria\n- [ ] one\n2. two\n\n## Notes\n- [ ] not a criterion\n"

    def test_criteria_checkbox_and_numbered(self):
        self.assertEqual(criteria(self.BODY), ["one", "two"])

    def test_chinese_heading(self):
        self.assertEqual(criteria("## 验收标准\n1. 甲\n"), ["甲"])

    def test_gate(self):
        self.assertEqual(gate("t", self.BODY, [], ["blocked"]), [])
        self.assertTrue(gate("t", "no section", [], []))
        self.assertTrue(gate("t", "## Acceptance criteria\njust text\n", [], []))
        self.assertTrue(gate("t", self.BODY, ["blocked"], ["blocked"]))
        self.assertTrue(gate("", self.BODY, [], []))

    def test_touching(self):
        files = ["tools/ci/size_baseline.json", "tools/ci/check_x.py", ".github/w.yml", "a.gd"]
        self.assertEqual(touching(files, ["tools/ci/*baseline*.json"]), ["tools/ci/size_baseline.json"])
        self.assertEqual(touching(files, [".github/"]), [".github/w.yml"])
        self.assertEqual(touching(files, ["a"]), [])


class ClaimTest(unittest.TestCase):
    def test_takes_ready_tickets_oldest_first_and_skips_held_ones(self) -> None:
        cfg = load_config()
        L = cfg["labels"]
        tickets = [
            {"number": 7, "labels": [L["trigger"]]},
            {"number": 3, "labels": [L["trigger"], L["working"]]},
            {"number": 4, "labels": [L["trigger"], L["help"]]},
            {"number": 5, "labels": [L["trigger"], cfg["skipLabels"][0]]},
            {"number": 6, "labels": []},
            {"number": 9, "labels": [L["trigger"], "bug"]},
        ]
        self.assertEqual(claimable(tickets, cfg), [7, 9])


class PlanTest(unittest.TestCase):
    PLAN = ("## Fit\nx\n## Reuse\nx\n## Affected\nx\n## Plan\n1. x\n"
            "## Checks\n- `tools/ci/check_save_contracts.py`\n- rm -rf /\n## Questions\nnone\n")

    def test_sections(self):
        self.assertEqual(agent.plan_complete(self.PLAN), [])
        self.assertEqual(agent.plan_questions(self.PLAN), [])
        self.assertEqual(agent.plan_complete("## Fit\n"), ["reuse", "affected", "plan", "checks", "questions"])

    def test_extra_checks_are_allowlisted(self):
        ok, bad, _ = checks.extra_checks(agent.plan_checks(self.PLAN), r"^tools/ci/[a-z0-9_]+\.py( --?[a-z0-9-]+)*$")
        self.assertEqual(ok, ["tools/ci/check_save_contracts.py"])
        self.assertEqual(bad, ["rm -rf /"])

    def test_extra_checks_accept_python_prefix_and_focused_tests(self):
        pattern = load_config()["checks"]["extraCheckPattern"]
        plan = ("## Checks\n- `python3 tools/ci/run_regression_checks.py tests/economy/trade_test.gd`\n"
                "- tools/ci/check_save_contracts.py --strict\n"
                "- tools/ci/run_regression_checks.py tests/../secret.gd\n"
                "- tools/ci/run_regression_checks.py tests/a.gd; rm -rf /\n"
                "- python3 -c 'print(1)'\n")
        ok, bad, _ = checks.extra_checks(agent.plan_checks(plan), pattern)
        self.assertEqual(ok, ["tools/ci/run_regression_checks.py tests/economy/trade_test.gd",
                              "tools/ci/check_save_contracts.py --strict"])
        self.assertEqual(bad, ["tools/ci/run_regression_checks.py tests/../secret.gd",
                               "tools/ci/run_regression_checks.py tests/a.gd; rm -rf /",
                               "python3 -c 'print(1)'"])

    def test_checks_the_factory_already_runs_are_not_rejected(self):
        # Issues #23-#26: these two lines in a plan stopped the run as rejected checks.
        cfg = load_config()
        plan = ("## Checks\n- tools/ci/run_regression_checks.py --jobs 4\n"
                "- tools/ci/check_macos_runtime_extension.py --library <debug library path>\n"
                "- tools/ci/run_regression_checks.py --jobs 2 tests/economy/a_test.gd\n"
                "- tools/ci/check_save_contracts.py <path>\n")
        ok, bad, dup = checks.extra_checks(agent.plan_checks(plan), cfg["checks"]["extraCheckPattern"],
                                           checks.already_run(cfg))
        self.assertEqual(dup, ["tools/ci/run_regression_checks.py --jobs 4",
                               "tools/ci/check_macos_runtime_extension.py --library <debug library path>"])
        self.assertEqual(ok, ["tools/ci/run_regression_checks.py --jobs 2 tests/economy/a_test.gd"])
        self.assertEqual(bad, ["tools/ci/check_save_contracts.py <path>"])
        self.assertTrue(checks.requests_native(dup, cfg))

    def test_native_check_line_cannot_carry_another_command(self):
        cfg = load_config()
        lines = ["tools/ci/check_macos_runtime_extension.py --library x.dylib; rm -rf /",
                 "tools/ci/check_macos_runtime_extension.py && tools/ci/check_save_contracts.py",
                 "tools/ci/check_macos_runtime_extension.py --library $(whoami)"]
        ok, bad, dup = checks.extra_checks(lines, cfg["checks"]["extraCheckPattern"], checks.already_run(cfg))
        self.assertEqual((ok, dup), ([], []))
        self.assertEqual(bad, lines)
        self.assertFalse(checks.requests_native(bad, cfg))

    def test_requested_native_check_that_did_not_run_needs_a_person(self):
        facts = Facts(native_requested=True)
        self.assertIn("the plan asked for the macOS runtime check, but no native sources changed, so it did not run",
                      judge(facts).reasons)
        facts.native_changed = facts.native_rebuilt = facts.native_runtime_ok = True
        self.assertNotIn("the plan asked for the macOS runtime check, but no native sources changed, so it did not run",
                         judge(facts).reasons)

    def test_questions(self):
        plan = self.PLAN.replace("## Questions\nnone", "## Questions\n- Should taxes round down?")
        self.assertEqual(agent.plan_questions(plan), ["Should taxes round down?"])


class DisputeTest(unittest.TestCase):
    FINDINGS = [{"id": "f"}, {"id": "f-long"}, {"id": "other"}]

    def test_id_is_exact_even_when_evidence_mentions_another_id(self):
        evidence = "see file.gd:42 for finding other"
        for finding_id in ("f-long", "`f-long`"):
            with self.subTest(finding_id=finding_id):
                self.assertEqual(agent.parse_disputes(f"\n- {finding_id}: {evidence}\n\n", self.FINDINGS),
                                 [("f-long", evidence)])

    def test_lists_all_malformed_and_unknown_lines(self):
        bad = ["- f", "  - f: indented", "- f:evidence", "- f:  ", "- unknown: evidence"]
        bad += ["- `f: evidence", "- f`: evidence", "- ``f``: evidence", "- ` f`: evidence",
                "- `unknown`: evidence", "- `f`:evidence"]
        with self.assertRaises(ValueError) as error:
            agent.parse_disputes("\n".join([*bad, "- f: valid evidence"]), self.FINDINGS)
        for line in bad:
            self.assertIn(repr(line), str(error.exception))


class GuardListTest(unittest.TestCase):
    def test_reads_workflow_loop(self):
        with tempfile.TemporaryDirectory() as d:
            wf = Path(d) / "w.yml"
            wf.write_text("run: |\n  for guard in a.py b.py \\\n      c.py; do\n    python \"$guard\"\n")
            self.assertEqual(checks.static_guards(d, "w.yml"), ["a.py", "b.py", "c.py"])

    def test_real_workflow_has_guards(self):
        root = Path(__file__).resolve().parents[3]
        wf = root / ".github" / "workflows" / "runtime-checks.yml"
        if wf.exists():
            self.assertIn("check_size_ratchet.py", checks.static_guards(str(root), ".github/workflows/runtime-checks.yml"))


if __name__ == "__main__":
    unittest.main()
