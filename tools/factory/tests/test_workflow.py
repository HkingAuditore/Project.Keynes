"""Offline tests of factory stages with external commands replaced."""

import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, call, patch

FACTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FACTORY))

import agent
import checks
import qodo
import run as issue_runner
import sync_rules
import work
from common import Events, Result, load_config
from github import GitHub
from run import Run
from verdict import CIFacts, CIRun, Verdict
from watch_prs import PrState, Watcher


ISSUE = {"title": "Example", "body": "## Acceptance criteria\n1. Pass\n", "labels": ["ready-for-agent"]}
HEAD = "a" * 40
FINDING = {"id": "f", "attribution_status": "pending", "action_level": "action_required"}
PR = {"number": 7, "headRefOid": HEAD, "headRefName": "issue", "title": "Example",
      "url": "https://example.invalid/pr/7"}


def review(*findings):
    return {"review_session": {"status": "completed", "commit_sha": HEAD}, "findings": list(findings)}


class TempFactory(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.cfg = load_config()
        self.cfg["home"] = str(self.root)
        self.enterContext(redirect_stdout(io.StringIO()))

    def write_file(self, root, path, text=""):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def write_guard_list(self, root, *guards):
        self.write_file(root, self.cfg["checks"]["staticWorkflow"], f"for guard in {' '.join(guards)}; do\n")


class IssueWorkflowTest(TempFactory):
    def make_run(self, dry=False):
        run = Run(self.cfg, 7, dry)
        run.base = HEAD
        run.gh = Mock(errors=[])
        return run

    def test_failed_gate_removes_trigger_and_adds_help(self):
        run = self.make_run()
        run.go({**ISSUE, "body": ""})
        self.assertEqual(run.finish(), 0)
        run.gh.relabel.assert_called_once_with(7, ["agent-needs-help"], ["agent-working", "ready-for-agent"])
        run.gh.comment.assert_called_once()

    def test_failed_dry_gate_leaves_labels_alone(self):
        run = self.make_run(dry=True)
        run.go({**ISSUE, "body": ""})
        run.finish()
        run.gh.relabel.assert_not_called()

    def test_failed_final_lookup_still_comments_relabels_and_records(self):
        run = self.make_run()
        run.pr = {"number": 9, "url": "https://example.invalid/pr/9"}
        run.gh.open_pr.side_effect = RuntimeError("service unavailable")
        self.assertEqual(run.finish(), 1)
        run.gh.comment.assert_called_once()
        self.assertEqual(run.gh.relabel.call_args_list,
                         [call(7, ["agent-needs-help"], ["agent-working"]), call(9, ["agent-needs-help"], [])])
        record = json.loads((self.root / "runs" / f"7-{run.stamp}.json").read_text())
        self.assertIn("service unavailable", record["githubErrors"][0])

    def test_master_failures_still_block_a_push(self):
        # AGENTS.md: found failures are fixed before a push, even ones master already had.
        run = self.make_run()
        run.candidate = Mock()
        run.candidate.run.return_value = ([{"name": "regression", "ok": False, "code": 1, "log": "x"},
                                           {"name": "static:a.py", "ok": True, "code": 0, "log": "y"}], [])
        run.candidate.scope.return_value = ([], [], [])
        with patch("work.changed", return_value=["a.gd"]):
            _, blocking = run.run_checks("t", [], ["regression"])
        self.assertEqual(blocking, ["regression"])

    def test_issue_pr_is_labelled_until_the_verdict(self):
        run = self.make_run()
        run.gh.relabel.return_value = None
        run.gh.open_pr.return_value = None
        run.gh.create_pr.return_value = {"number": 9, "url": "https://example.invalid/pr/9"}
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch.object(run, "plan", return_value=""),
              patch.object(run, "implement", return_value=True), patch.object(run, "local_review", return_value=True),
              patch.object(run, "commit_checked", return_value=True), patch("work.push"),
              patch.object(run, "pr_loop")):
            run.go(ISSUE)
        for ready, expected in ((False, call(9, ["agent-needs-help"], [])), (True, call(9, ["factory-handoff"], []))):
            with self.subTest(ready=ready):
                run.gh.relabel.reset_mock()
                run.gh.open_pr.return_value = None
                verdict = Verdict("READY" if ready else "NEEDS_HUMAN", [], [])
                with patch.object(issue_runner, "judge", return_value=verdict):
                    run.finish()
                self.assertEqual(run.gh.relabel.call_args_list[-1], expected)

    def test_failed_hand_off_leaves_a_way_to_retry(self):
        run = self.make_run()
        run.pr = {"number": 9, "url": "https://example.invalid/pr/9"}
        run.gh.open_pr.return_value = None
        run.gh.relabel.side_effect = lambda n, add, remove: "relabel #9: 502" if add == ["factory-handoff"] else None
        with patch.object(issue_runner, "judge", return_value=Verdict("READY", [], [])):
            run.finish()
        self.assertIn(call(9, ["agent-needs-help"], []), run.gh.relabel.call_args_list)
        pr_comments = [c for c in run.gh.comment.call_args_list if c.args[0] == 9]
        self.assertEqual(len(pr_comments), 1)
        self.assertIn("Add `factory-handoff`", pr_comments[0].args[1])

    def test_finish_finds_a_pr_that_create_pr_lost(self):
        # gh created the PR but the lookup after it failed, so run.pr was never set.
        run = self.make_run()
        run.facts.head = HEAD
        run.gh.open_pr.return_value = {"number": 9, "url": "https://example.invalid/pr/9", "headRefOid": HEAD}
        run.gh.relabel.return_value = None
        with patch.object(issue_runner, "judge", wraps=issue_runner.judge) as judge:
            run.finish()
        self.assertEqual(judge.call_args.args[0].stopped_by, "the PR was opened but the run lost track of it")
        self.assertEqual(run.gh.relabel.call_args_list[-1], call(9, ["agent-needs-help"], []))

    def test_rejected_plan_check_stops_before_implementation(self):
        run = self.make_run()
        run.gh.relabel.return_value = None
        run.gh.open_pr.return_value = None
        command = "tools/ci/check_committed_replay.py --checkpoint --out /tmp/replay"
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]),
              patch.object(run, "plan", return_value=f"## Checks\n- {command}"),
              patch.object(run, "implement") as implement):
            run.go(ISSUE)
        self.assertEqual(run.facts.rejected_checks, [command])
        implement.assert_not_called()

    def test_incomplete_local_review_is_recorded_and_in_pr_body(self):
        for required in (False, True):
            with self.subTest(required=required):
                self.cfg["limits"]["localReviewRequired"] = required
                run = self.make_run()
                review = {"ok": True, "complete": False, "blocking": []}
                with patch("qodo.local_review", return_value=review):
                    self.assertEqual(run.local_review(ISSUE, "", [], []), not required)
                self.assertFalse(run.record["localReviews"][0]["complete"])
                self.assertTrue(run.facts.local_review_incomplete)
                self.assertIn("coverage was incomplete", run.pr_body(ISSUE, ""))

    def test_scope_before_commit_catches_protected_paths_from_checks(self):
        for path in ("tools/ci/check_extra.py", "tools/ci/module_api/test.json", "gdext/godot-cpp"):
            with self.subTest(path=path):
                run = self.make_run()
                with patch("work.changed", return_value=["edit.gd", path]), patch("work.commit") as commit:
                    self.assertFalse(run.commit_checked("test"))
                commit.assert_not_called()
                self.assertIsNone(run.facts.checks_sha)
                if path == "gdext/godot-cpp":
                    self.assertFalse(run.facts.native_changed)
                    self.assertIn(path, run.facts.human_paths)
                else:
                    self.assertIn(path, run.facts.stopped_by)

    def test_pr_fix_uses_same_commit_scope_gate(self):
        run = self.make_run()
        run.pr = {"url": "https://example.invalid/pr/7"}
        run.facts.head = HEAD
        review = {"review_session": {"status": "completed", "commit_sha": HEAD}, "findings": [FINDING]}
        with (patch("qodo.wait_pr_review", return_value=review), patch.object(run, "wait_ci", return_value="success"),
              patch.object(run, "fix", return_value=True), patch("work.dirty", return_value=True),
              patch("work.changed", return_value=["edit.gd", ".github/new.yml"]),
              patch("work.commit") as commit):
            run.pr_loop(ISSUE, [], [])
        commit.assert_not_called()
        self.assertIn(".github/new.yml", run.facts.stopped_by)

    def test_initial_commit_also_rechecks_scope_after_checks(self):
        run = self.make_run()
        run.gh.relabel.return_value = None
        run.gh.open_pr.return_value = None
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch.object(run, "plan", return_value=""),
              patch.object(run, "implement", return_value=True),
              patch.object(run, "local_review", return_value=True),
              patch("work.changed", return_value=["tools/ci/baseline.json"]), patch("work.commit") as commit):
            run.go(ISSUE)
        commit.assert_not_called()
        self.assertIn("tools/ci/baseline.json", run.facts.stopped_by)

    def test_failed_implementation_stops_before_checks_review_or_publish(self):
        run = self.make_run()
        patch_path = run.logs / "fix.patch"
        run.gh.relabel.return_value = None
        run.gh.open_pr.return_value = None
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch.object(run, "plan", return_value=""),
              patch("agent.codex", return_value={"ok": False, "code": 1, "report": "partial"}) as codex,
              patch("work.save_patch", return_value=[patch_path]) as save,
              patch.object(run, "run_checks") as candidate_checks,
              patch.object(run, "local_review") as local_review,
              patch("work.commit") as commit, patch("work.push") as push):
            run.go(ISSUE)
        codex.assert_called_once()
        save.assert_called_once_with(run.workdir, HEAD, patch_path)
        for step in (candidate_checks, local_review, commit, push, run.gh.create_pr):
            step.assert_not_called()
        self.assertIn("Codex failed (exit 1) during implementation", run.facts.stopped_by)
        self.assertIn(str(patch_path), run.facts.stopped_by)

    def test_failed_issue_review_fix_stops_before_checks_or_publish(self):
        run = self.make_run()
        paths = [run.logs / "fix.patch", run.logs / "fix.gdext__godot-cpp.patch"]
        run.pr = PR
        run.facts.head = HEAD
        with (patch("qodo.wait_pr_review", return_value=review(FINDING)),
              patch.object(run, "wait_ci", return_value="success"),
              patch("agent.codex", return_value={"ok": False, "code": 124, "report": "partial"}),
              patch("work.save_patch", return_value=paths) as save, patch.object(run, "run_checks") as candidate_checks,
              patch("work.commit") as commit, patch("work.push") as push):
            run.pr_loop(ISSUE, [], [])
        save.assert_called_once_with(run.workdir, HEAD, paths[0])
        for step in (candidate_checks, commit, push):
            step.assert_not_called()
        self.assertIn("Codex timed out", run.facts.stopped_by)
        for path in paths:
            self.assertIn(str(path), run.facts.stopped_by)

    def test_issue_review_fix_stops_on_invalid_dispute_file(self):
        run = self.make_run()
        paths = [run.logs / "fix.patch", run.logs / "fix.gdext__godot-cpp.patch"]
        disagree = Path(run.workdir) / ".factory-disagree.md"
        disagree.parent.mkdir()
        disagree.write_text("  - f: malformed\n- unknown: file.gd:42\n", encoding="utf-8")
        with (patch("agent.codex", return_value={"ok": True, "report": ""}),
              patch("work.save_patch", return_value=paths) as save,
              patch.object(run, "run_checks") as candidate_checks):
            self.assertFalse(run.fix(ISSUE, [FINDING], "local review", False, [], []))
        save.assert_called_once_with(run.workdir, HEAD, paths[0])
        candidate_checks.assert_not_called()
        self.assertIn(repr("  - f: malformed"), run.facts.stopped_by)
        self.assertIn(repr("- unknown: file.gd:42"), run.facts.stopped_by)
        self.assertEqual(run.facts.disagreements, [])
        self.assertEqual(run.finish(), 0)
        for path in paths:
            self.assertIn(str(path), run.facts.stopped_by)
            self.assertIn(str(path), run.gh.comment.call_args.args[1])

    def test_ci_query_error_stops_polling_and_pr_fix(self):
        run = self.make_run()
        run.pr = PR
        run.facts.head = HEAD
        run.gh.ci_state.return_value = "error"
        with (patch("qodo.wait_pr_review", return_value=review(FINDING)),
              patch("run.time.sleep") as sleep, patch.object(run, "fix") as fix):
            run.pr_loop(ISSUE, [], [])
        run.gh.ci_state.assert_called_once_with(HEAD)
        self.assertEqual(run.facts.ci_state, "error")
        sleep.assert_not_called()
        fix.assert_not_called()

    def test_missing_check_stops_issue_and_records_needs_human(self):
        path = "tools/ci/base_guard.py"
        self.write_guard_list(self.root / "work", "base_guard.py")
        gh = Mock(errors=[])
        gh.issue.return_value = {**ISSUE, "number": 7}
        gh.relabel.return_value = gh.open_pr.return_value = None
        with (patch("sys.argv", ["run.py", "--issue", "7"]), patch("run.load_config", return_value=self.cfg),
              patch("run.GitHub", return_value=gh), patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.sh", return_value=Result(1, "", "")) as execute,
              patch("agent.codex", return_value={"ok": False, "code": 1, "report": ""}) as codex,
              patch("work.commit") as commit, patch("work.push") as push):
            self.assertEqual(issue_runner.main(), 0)
        for step in (execute, codex, commit, push, gh.create_pr):
            step.assert_not_called()
        gh.relabel.assert_called_with(7, ["agent-needs-help"], ["agent-working"])
        record_file, = (self.root / "runs").glob("7-*.json")
        record = json.loads(record_file.read_text())
        self.assertEqual(record["verdict"], "NEEDS_HUMAN")
        self.assertIn(path, record["facts"]["stopped_by"])
        self.assertEqual(record["facts"]["base_failures"], [])
        self.assertIn(path, gh.comment.call_args.args[1])


class WatchWorkflowTest(TempFactory):
    def make_watcher(self):
        watcher = Watcher(self.cfg, dry=False)
        watcher.gh = Mock(errors=[])
        return watcher

    def read_record(self, watcher):
        return json.loads((self.root / "runs" / f"pr-7-{watcher.stamp}.json").read_text())

    def run_check_fix(self, results, codex_ok=True):
        watcher = self.make_watcher()
        log = self.write_file(self.root, "native.log", "src/a.cpp:197:49: error: no viable conversion\n"
                              + "warning: noise\n" * 200)
        failing = [{"name": "native-rebuild", "ok": False, "code": 1, "log": str(log)}]
        runs = [(failing if r == "fail" else [], ["edit.gd"]) for r in results]
        reports = [{"ok": True, "report": "fixed", "session": "thread-1"}] + [
            {"ok": codex_ok, "code": 0 if codex_ok else 1, "report": "x", "session": "thread-1"}] * 3
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch("work.head", return_value=HEAD),
              patch("agent.codex", side_effect=reports) as codex,
              patch("work.changed", return_value=["edit.gd"]), patch("checks.Candidate.run", side_effect=runs),
              patch.object(watcher, "scope_blocked", return_value=False),
              patch("work.save_patch", return_value=[]),
              patch.object(watcher, "stop") as stop, patch("work.commit", return_value="b" * 40) as commit,
              patch("checks.Candidate.committed"), patch("watch_prs.must")):
            record = {}
            outcome = watcher._fix(PR, PrState(), [FINDING], self.root, Events(), record)
        return outcome, codex, stop, commit, record

    def test_codex_resume_continues_the_same_thread(self):
        report = str(self.root / "fix.md")
        events = '{"type":"thread.started","thread_id":"0199-abc"}\n{"type":"turn.completed"}\n'

        def fake_sh(args, **kw):
            Path(kw["log"]).write_text(events if "resume" not in args else "", encoding="utf-8")
            return Result(0, "", "")

        with patch("agent.sh", side_effect=fake_sh) as sh:
            first = agent.codex(self.cfg, "/w", "fix", report, writable=True)
            again = agent.codex(self.cfg, "/w", "checks", report, writable=True, session=first["session"])
        self.assertEqual(first["session"], "0199-abc")
        self.assertEqual(again["session"], "0199-abc")
        new_args, resume_args = sh.call_args_list[0].args[0], sh.call_args_list[1].args[0]
        self.assertIn("--json", new_args)
        self.assertEqual(resume_args[1:4], ["exec", "resume", "0199-abc"])
        self.assertNotIn("-C", resume_args)
        self.assertIn('sandbox_mode="workspace-write"', resume_args)
        self.assertEqual(sh.call_args_list[1].kwargs["cwd"], "/w")

    def test_codex_without_thread_event_has_no_session(self):
        report = str(self.root / "fix.md")
        with patch("agent.sh", side_effect=lambda args, **kw: (Path(kw["log"]).write_text("not json\n"), Result(1, "", ""))[1]):
            self.assertIsNone(agent.codex(self.cfg, "/w", "fix", report, writable=True)["session"])

    def test_failing_checks_go_back_to_codex_before_stopping(self):
        outcome, codex, stop, commit, record = self.run_check_fix(["fail", "pass"])
        self.assertEqual(outcome, "pushed")
        self.assertEqual(codex.call_count, 2)
        prompt = codex.call_args_list[1].args[2]
        self.assertIn("no viable conversion", prompt)
        self.assertIsNone(codex.call_args_list[0].kwargs.get("session"))
        self.assertEqual(codex.call_args_list[1].kwargs["session"], "thread-1")
        self.assertEqual(record["codexSession"], "thread-1")
        stop.assert_not_called()
        commit.assert_called_once()
        self.assertEqual(record["checks"]["checkFixRounds"], 1)

    def test_checks_that_keep_failing_stop_after_the_round_limit(self):
        rounds = self.cfg["limits"]["checkFixRounds"]
        outcome, codex, stop, commit, _ = self.run_check_fix(["fail"] * (rounds + 1))
        self.assertEqual(outcome, "stopped")
        self.assertEqual(codex.call_count, rounds + 1)
        commit.assert_not_called()
        self.assertIn(f"after {rounds} check-fix rounds: native-rebuild", stop.call_args.args[2])

    def test_failed_check_fix_agent_stops_with_patch(self):
        outcome, codex, stop, commit, _ = self.run_check_fix(["fail", "pass"], codex_ok=False)
        self.assertEqual(outcome, "stopped")
        self.assertEqual(codex.call_count, 2)
        commit.assert_not_called()
        self.assertIn("while fixing failing checks", stop.call_args.args[2])

    def test_scope_rechecked_after_passing_checks(self):
        watcher = Watcher(self.cfg, dry=False)
        pr = {"number": 7, "headRefOid": HEAD, "headRefName": "issue", "title": "Example"}
        paths = [self.root / "fix.patch", self.root / "fix.gdext__godot-cpp.patch"]
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch("work.head", return_value=HEAD),
              patch("agent.codex", return_value={"ok": True, "report": ""}),
              patch("work.changed", side_effect=[["edit.gd"], ["edit.gd", "tools/ci/generated.py"]]),
              patch("checks.Runner.run", return_value=[]), patch("work.save_patch", return_value=paths) as save,
              patch.object(watcher, "stop") as stop, patch("work.commit") as commit):
            self.assertEqual(watcher._fix(pr, PrState(), [FINDING], self.root, Events(), {}), "stopped")
        commit.assert_not_called()
        save.assert_called_once_with(watcher.workdir, HEAD, paths[0])
        self.assertIn("tools/ci/generated.py", stop.call_args.args[2])
        for path in paths:
            self.assertIn(str(path), stop.call_args.args[3])

    def test_failed_codex_saves_partial_patch_without_checks_or_publish(self):
        for code, reason in ((1, "Codex failed"), (124, "Codex timed out")):
            with self.subTest(code=code):
                watcher = self.make_watcher()
                logs = self.root / "logs" / f"pr-7-{watcher.stamp}"
                paths = [logs / "fix.patch", logs / "fix.gdext__godot-cpp.patch"]
                with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
                      patch("checks.base_results", return_value=[]),
                      patch("agent.codex", return_value={"ok": False, "report": "partial", "code": code}),
                      patch("work.save_patch", return_value=paths) as save,
                      patch("checks.Runner.run") as candidate_checks,
                      patch("work.commit") as commit, patch("watch_prs.must") as push):
                    watcher.fix(PR, PrState(), [FINDING])
                save.assert_called_once_with(watcher.workdir, HEAD, paths[0])
                for step in (candidate_checks, commit, push):
                    step.assert_not_called()
                record = self.read_record(watcher)
                self.assertEqual(record["outcome"], "stopped")
                self.assertIn(reason, record["agentFailure"])
                self.assertEqual(watcher.load(7).gave_up_at, HEAD)
                self.assertIn(reason, watcher.gh.comment.call_args.args[1])
                for path in paths:
                    self.assertIn(str(path), watcher.gh.comment.call_args.args[1])
                watcher.gh.relabel.assert_called_with(7, [], ["agent-working"])

    def test_disputed_head_runs_codex_once_across_two_ticks(self):
        watcher = self.make_watcher()
        later = {**FINDING, "id": "later"}
        with (patch.object(watcher, "prs", return_value=[PR]),
              patch("qodo.pr_review", side_effect=[review(FINDING), review(FINDING, later)]),
              patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("work.head", return_value=HEAD), patch("work.changed", return_value=[]),
              patch("checks.base_results", return_value=[]),
              patch("work.scratch", return_value="- `f`: file.gd:42"),
              patch("agent.codex", return_value={"ok": True, "report": ""}) as codex):
            self.assertEqual(watcher.tick(None), 0)
            self.assertEqual(watcher.tick(None), 0)
        codex.assert_called_once()
        state = watcher.load(7)
        self.assertEqual(state.gave_up_at, HEAD)
        self.assertIn("disputed every finding", state.reason)
        self.assertEqual(self.read_record(watcher)["outcome"], "disputed")
        watcher.gh.comment.assert_called_once()

    def test_partial_dispute_stops_and_names_undisputed_ids(self):
        findings = [FINDING, {**FINDING, "id": "f-long"}, {**FINDING, "id": "other"}]
        for edits in ([], ["edit.gd"]):
            with self.subTest(edits=edits):
                watcher = self.make_watcher()
                with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
                      patch("work.head", return_value=HEAD), patch("work.changed", side_effect=[edits, []]),
                      patch("checks.base_results", return_value=[]),
                      patch("checks.Runner.run", return_value=[]) as candidate_checks,
                      patch("work.scratch", return_value="- f-long: file.gd:42 mentions other"),
                      patch("agent.codex", return_value={"ok": True, "report": ""})):
                    watcher.fix(PR, PrState(), findings)
                self.assertEqual(candidate_checks.call_count, int(bool(edits)))
                state = watcher.load(7)
                self.assertEqual(state.gave_up_at, HEAD)
                self.assertEqual(state.disputed, ["f-long"])
                self.assertIn("f, other", state.reason)
                record = self.read_record(watcher)
                self.assertEqual(record["outcome"], "stopped")
                self.assertEqual(record["undisputed"], ["f", "other"])
                watcher.gh.relabel.assert_any_call(7, ["agent-needs-help"], ["agent-working"])

    def test_invalid_dispute_stops_pr_fix_before_checks(self):
        watcher = self.make_watcher()
        logs = self.root / "logs" / f"pr-7-{watcher.stamp}"
        paths = [logs / "fix.patch", logs / "fix.gdext__godot-cpp.patch"]
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch("checks.Runner.run") as candidate_checks,
              patch("work.scratch", return_value="- unknown: file.gd:42"),
              patch("agent.codex", return_value={"ok": True, "report": ""}),
              patch("work.save_patch", return_value=paths) as save,
              patch("work.commit") as commit, patch("watch_prs.must") as push):
            watcher.fix(PR, PrState(), [FINDING])
        save.assert_called_once_with(watcher.workdir, HEAD, paths[0])
        for step in (candidate_checks, commit, push):
            step.assert_not_called()
        self.assertEqual(watcher.load(7).gave_up_at, HEAD)
        self.assertIn("- unknown: file.gd:42", self.read_record(watcher)["disputeError"])
        self.assertIn("- unknown: file.gd:42", watcher.gh.comment.call_args.args[1])
        for path in paths:
            self.assertIn(str(path), watcher.gh.comment.call_args.args[1])

    def test_moved_head_clears_working_label_and_records_without_comment(self):
        watcher = self.make_watcher()
        moved = "b" * 40
        with (patch("work.ensure"), patch("work.prepare", return_value=moved),
              patch("checks.base_results") as base_checks, patch("agent.codex") as codex):
            watcher.fix(PR, PrState(), [FINDING])
        base_checks.assert_not_called()
        codex.assert_not_called()
        watcher.gh.comment.assert_not_called()
        self.assertEqual(watcher.gh.relabel.call_args_list, [
            call(7, ["agent-working"], ["agent-needs-help"]), call(7, [], ["agent-working"]),
        ])
        record = self.read_record(watcher)
        self.assertEqual(record["outcome"], "head moved")
        self.assertEqual([(e["step"], e["expected"], e["got"]) for e in record["events"]],
                         [("moved", HEAD, moved)])

    def test_missing_candidate_check_stops_pr_and_records_error_without_push(self):
        watcher = self.make_watcher()
        path = "tools/ci/candidate_guard.py"
        self.write_guard_list(Path(watcher.workdir), "candidate_guard.py")
        with (patch("work.ensure"), patch("work.prepare", return_value=HEAD),
              patch("checks.base_results", return_value=[]), patch("work.head", return_value=HEAD),
              patch("work.changed", return_value=["edit.gd"]),
              patch("agent.codex", return_value={"ok": True, "report": ""}) as codex,
              patch("checks.sh", return_value=Result(1, "", "")) as execute,
              patch("work.commit") as commit, patch("watch_prs.must") as push):
            watcher.fix(PR, PrState(), [FINDING])
        codex.assert_called_once()
        for step in (execute, commit, push):
            step.assert_not_called()
        self.assertEqual(watcher.load(7).gave_up_at, HEAD)
        watcher.gh.relabel.assert_any_call(7, ["agent-needs-help"], ["agent-working"])
        watcher.gh.relabel.assert_called_with(7, [], ["agent-working"])
        self.assertIn(path, watcher.gh.comment.call_args.args[1])
        record = self.read_record(watcher)
        self.assertEqual(record["outcome"], "error")
        self.assertIn(path, record["error"])
        self.assertEqual(record["events"][-1]["step"], "error")
        self.assertNotIn("checks", record)


class ConflictUpdateTest(TempFactory):
    def setUp(self):
        super().setUp()
        self.source = self.root / "source"
        self.source.mkdir()
        self.remote = self.root / "fork.git"
        self.watcher = Watcher(self.cfg, dry=False)
        self.watcher.gh = Mock(errors=[])
        self.watcher.gh.relabel.return_value = None
        self.watcher.gh.pr_merge_state.side_effect = lambda number: {
            **self.pr, "baseRefOid": self.base, "state": "OPEN",
            "isDraft": False, "isCrossRepository": False,
            "labels": [*self.pr["labels"], self.cfg["labels"]["working"]], **self.fresh_fields,
        }
        self.fresh_fields = {}
        self.checkout = Path(self.watcher.workdir)
        self.libraries = self.cfg["paths"]["nativeLibraries"]
        work.git(str(self.source), "init", "-qb", "master")
        self.configure(self.source)
        self.enterContext(patch.dict(os.environ, {"GIT_ALLOW_PROTOCOL": "file"}))
        # These fixtures have no Godot checkout. Git still handles the real merge and push.
        self.enterContext(patch("work.update_godot_cpp"))
        self.codex = self.enterContext(patch("agent.codex"))
        self.qodo = self.enterContext(patch("qodo.pr_review"))
        self.baseline = self.enterContext(patch("checks.base_results", side_effect=self.check_baseline))
        self.runner = self.enterContext(patch("checks.Runner.run", side_effect=self.check_candidate))
        self.build = False
        self.parent_results = {
            "head": [{"name": "known", "ok": False}, {"name": "regression", "ok": True}],
            "base": [{"name": "known", "ok": True}, {"name": "regression", "ok": True}],
        }
        self.after = [{"name": "known", "ok": False}, {"name": "regression", "ok": True}]

    def configure(self, repo):
        work.git(str(repo), "config", "user.name", "Factory Test")
        work.git(str(repo), "config", "user.email", "factory@example.invalid")
        work.git(str(repo), "config", "commit.gpgsign", "false")

    def write_versions(self, paths):
        for path, data in paths.items():
            target = self.source / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

    def commit(self, repo):
        work.git(str(repo), "add", "-A")
        work.git(str(repo), "commit", "-qm", "test checkout")
        return work.head(str(repo))

    def prepare_conflict(self, paths):
        self.write_versions({path: versions[0] for path, versions in paths.items()})
        self.write_file(self.source, ".github/master.yml", "old check")
        self.write_file(self.source, "unrelated.txt", "unchanged")
        self.write_file(self.source, "script.sh", "#!/bin/sh\n")
        common = self.commit(self.source)
        self.write_versions({path: versions[1] for path, versions in paths.items()})
        # This protected file arrives cleanly from master and is outside the resolution scope.
        self.write_file(self.source, ".github/master.yml", "upstream check")
        self.base = self.commit(self.source)
        work.git(str(self.source), "checkout", "-qb", "issue", common)
        self.write_versions({path: versions[2] for path, versions in paths.items()})
        self.commit(self.source)
        self.open_fixture()

    def open_fixture(self):
        head = work.head(str(self.source))
        work.git(str(self.source), "clone", "--bare", "-q", ".", str(self.remote))
        work.git(str(self.source), "clone", "-qo", "fork", str(self.remote), str(self.checkout))
        self.configure(self.checkout)
        self.pr = {**PR, "headRefOid": head, "baseRefName": "master", "mergeable": "CONFLICTING", "labels": []}

    def check_baseline(self, cfg, workdir, head, cache, logs):
        self.assertEqual(work.head(workdir), head)
        self.assertIsNone(work.merge_head(workdir))
        self.assertEqual(Path(cache), self.root / "base-checks")
        if head == self.base:
            return self.parent_results["base"]
        self.assertEqual(head, self.pr["headRefOid"])
        return self.parent_results["head"]

    def check_candidate(self, native, extra):
        self.assertEqual(native, self.build)
        self.assertEqual(work.merge_head(str(self.checkout)), self.base)
        self.assertFalse(work.unmerged(str(self.checkout)))
        native_results = []
        if native:
            for lib, data in zip(self.libraries, self.rebuilt):
                (self.checkout / lib).write_bytes(data)
            native_results = [{"name": checks.NATIVE_REBUILD, "ok": True, "libraries": {
                lib: checks.file_digest(self.checkout / lib) for lib in self.libraries
            }}, {"name": checks.NATIVE_IMPORT, "ok": True}]
            native_results.extend({"name": checks.runtime_name(lib), "ok": True} for lib in self.libraries)
        return [*native_results, *self.after]

    def tick(self):
        with patch.object(self.watcher, "prs", return_value=[self.pr]):
            self.assertEqual(self.watcher.tick(None), 0)
        self.qodo.assert_not_called()
        record = self.root / "runs" / f"pr-7-{self.watcher.stamp}.json"
        return json.loads(record.read_text())

    def remote_head(self):
        return work.git(str(self.remote), "rev-parse", "refs/heads/issue")

    def assert_merge(self, used_codex):
        sha = self.remote_head()
        self.assertNotEqual(sha, self.pr["headRefOid"])
        self.assertEqual(work.git(str(self.remote), "show", "-s", "--format=%P", sha).split(),
                         [self.pr["headRefOid"], self.base])
        body = work.git(str(self.remote), "show", "-s", "--format=%B", sha)
        self.assertTrue(body.startswith("Merge master into issue\n"))
        self.assertIn("Fixed-By: keynes-factory", body)
        self.assertEqual("Implemented-By: Codex (" in body, used_codex)
        self.assertEqual(self.watcher.load(7).rounds, 1)
        return sha

    def assert_stopped(self, reason):
        self.assertIsNone(work.merge_head(str(self.checkout)))
        self.assertEqual(self.remote_head(), self.pr["headRefOid"])
        self.assertEqual(self.watcher.load(7).gave_up_at, self.pr["headRefOid"])
        self.watcher.gh.relabel.assert_any_call(7, ["agent-needs-help"], ["agent-working"])
        self.assertIn(reason, self.watcher.gh.comment.call_args.args[1])

    def resolve_text(self, cfg, workdir, prompt, report, writable, *, text="PR and master\n", stage=True):
        self.assertIn("edit.gd", prompt)
        self.assertTrue(writable)
        self.write_file(Path(workdir), "edit.gd", text)
        if stage:
            work.git(workdir, "add", "edit.gd")
        return {"ok": True, "code": 0, "report": "edit.gd combines the changes from both branches."}

    def text_conflict(self):
        self.prepare_conflict({"edit.gd": (b"common\n", b"master\n", b"PR\n")})
        self.codex.side_effect = self.resolve_text

    def test_library_conflicts_force_native_flow_even_without_source_edits(self):
        self.prepare_conflict({lib: (b"\0old", b"\0master", b"\0pr") for lib in self.libraries})
        self.build = True
        # Identical to master for one target, different from both parents for the other.
        self.rebuilt = [b"\0master", b"\0rebuilt"]
        record = self.tick()
        sha = self.assert_merge(used_codex=False)
        self.codex.assert_not_called()
        self.assertEqual(record["conflicts"], sorted(self.libraries))
        self.assertEqual(record["files"], [self.libraries[1]])
        self.assertTrue(all(record["facts"].values()))
        self.assertEqual(record["outcome"], "pushed")
        for lib, data in zip(self.libraries, self.rebuilt):
            self.assertEqual(subprocess.check_output(["git", "-C", str(self.remote), "show", f"{sha}:{lib}"]), data)
            self.assertIn(checks.runtime_name(lib), self.watcher.gh.comment.call_args.args[1])

    def test_required_native_check_failure_blocks_without_a_baseline(self):
        self.prepare_conflict({lib: (b"\0old", b"\0master", b"\0pr") for lib in self.libraries})
        self.build = True
        self.rebuilt = [b"\0master", b"\0rebuilt"]
        name = checks.runtime_name(self.libraries[0])

        def fail_probe(native, extra):
            results = self.check_candidate(native, extra)
            next(row for row in results if row["name"] == name).update(
                ok=False, code=1, log=str(self.root / "native.log"))
            return results

        self.runner.side_effect = fail_probe
        record = self.tick()
        self.assert_stopped(name)
        self.assertEqual(record["checks"]["new"], [])
        self.assertEqual(record["checks"]["nativeFailed"], [name])

    def test_text_conflict_preserves_clean_upstream_changes_and_existing_failures(self):
        self.text_conflict()
        record = self.tick()
        sha = self.assert_merge(used_codex=True)
        self.codex.assert_called_once()
        self.assertEqual(record["files"], ["edit.gd"])
        self.assertEqual(record["checks"]["before"], ["known"])
        self.assertEqual(record["checks"]["new"], [])
        self.assertEqual(work.git(str(self.remote), "show", f"{sha}:edit.gd"), "PR and master")
        self.assertEqual(work.git(str(self.remote), "show", f"{sha}:.github/master.yml"), "upstream check")
        self.assertIn("combines the changes", self.watcher.gh.comment.call_args.args[1])

    def test_check_already_failing_on_base_does_not_block_the_update(self):
        self.text_conflict()
        self.parent_results["head"][0]["ok"] = True
        self.parent_results["base"][0]["ok"] = False
        record = self.tick()
        self.assert_merge(used_codex=True)
        self.assertEqual([c.args[2] for c in self.baseline.call_args_list], [self.pr["headRefOid"], self.base])
        self.assertEqual(record["checks"]["new"], [])
        self.assertEqual(record["checks"]["beforeByParent"], {"head": [], "base": ["known"]})

    def test_check_that_passed_on_both_parents_blocks_the_update(self):
        self.text_conflict()
        self.after[1].update(ok=False, code=1, log=str(self.root / "regression.log"))
        record = self.tick()
        self.assert_stopped("the update has failing checks: regression")
        self.assertEqual(record["checks"]["new"], ["regression"])
        self.assertEqual([c.args[2] for c in self.baseline.call_args_list], [self.pr["headRefOid"], self.base])

    def test_check_missing_on_one_parent_is_not_a_regression_from_both(self):
        self.text_conflict()
        self.parent_results["base"].pop()
        self.after[1]["ok"] = False
        self.assertEqual(self.tick()["checks"]["new"], [])
        self.assert_merge(used_codex=True)

    def test_codex_cannot_restore_a_cleanly_merged_file_to_the_pr_head(self):
        self.text_conflict()
        path = ".github/master.yml"

        def undo_upstream_change(cfg, workdir, *args, **kwargs):
            report = self.resolve_text(cfg, workdir, *args, **kwargs)
            work.git(workdir, "restore", "--source=HEAD", "--staged", "--worktree", "--", path)
            return report

        self.codex.side_effect = undo_upstream_change
        self.assertEqual(self.tick()["outcome"], "stopped")
        self.assert_stopped(path)
        self.runner.assert_not_called()

    def test_codex_cannot_delete_add_or_change_modes_outside_conflicts(self):
        self.text_conflict()

        def edit_unrelated_paths(cfg, workdir, *args, **kwargs):
            report = self.resolve_text(cfg, workdir, *args, **kwargs)
            (self.checkout / "unrelated.txt").unlink()
            work.git(workdir, "update-index", "--chmod=+x", "--", "script.sh")
            self.write_file(self.checkout, "new.txt", "untracked")
            self.write_file(self.checkout, "staged.txt", "staged")
            work.git(workdir, "add", "--", "staged.txt")
            return report

        self.codex.side_effect = edit_unrelated_paths
        record = self.tick()
        self.assertEqual(record["outcome"], "stopped", record.get("error"))
        self.assertEqual(record["unrelatedFiles"], ["new.txt", "script.sh", "staged.txt", "unrelated.txt"])
        for path in ("unrelated.txt", "script.sh", "new.txt", "staged.txt"):
            self.assert_stopped(path)
        self.runner.assert_not_called()

    def test_label_added_before_push_abandons_the_update(self):
        self.text_conflict()
        self.fresh_fields["labels"] = ["agent-working", "agent-needs-help"]
        record = self.tick()
        self.assertEqual(record["outcome"], "skipped")
        self.assertIn("labels", record["reason"])
        self.assertEqual(self.remote_head(), self.pr["headRefOid"])
        self.watcher.gh.pr_merge_state.assert_called_once_with(7)
        self.watcher.gh.comment.assert_not_called()
        self.assertEqual(self.watcher.gh.relabel.call_args_list, [
            call(7, ["agent-working"], []), call(7, [], ["agent-working"]),
        ])

    def test_head_changed_in_github_metadata_before_push_abandons_the_update(self):
        self.text_conflict()
        self.fresh_fields["headRefOid"] = self.base
        self.assertEqual(self.tick()["outcome"], "head moved")
        self.assertEqual(self.remote_head(), self.pr["headRefOid"])
        self.watcher.gh.pr_merge_state.assert_called_once_with(7)
        self.watcher.gh.comment.assert_not_called()

    def test_staged_leftover_marker_stops_the_update(self):
        self.text_conflict()
        self.codex.side_effect = lambda *args, **kwargs: self.resolve_text(*args, **kwargs, text="<<<<<<< HEAD\nPR\n")
        self.assertEqual(self.tick()["outcome"], "stopped")
        self.assert_stopped("conflict markers remain: edit.gd")
        self.runner.assert_not_called()

    def test_unmerged_index_stops_even_when_the_working_file_has_no_markers(self):
        self.text_conflict()
        self.codex.side_effect = lambda *args, **kwargs: self.resolve_text(*args, **kwargs, stage=False)
        self.tick()
        self.assert_stopped("unmerged paths remain: edit.gd")
        self.runner.assert_not_called()

    def test_protected_path_conflict_aborts_without_codex_or_push(self):
        path = ".github/check.yml"
        self.prepare_conflict({path: (b"old\n", b"master\n", b"PR\n")})
        self.assertEqual(self.tick()["outcome"], "stopped")
        self.assert_stopped(path)
        self.codex.assert_not_called()
        self.runner.assert_not_called()

    def test_gitlink_conflict_outside_the_configured_protected_paths_aborts(self):
        path = "other/submodule"

        def gitlink(oid):
            work.git(str(self.source), "update-index", "--add", "--cacheinfo", f"160000,{oid},{path}")
            work.git(str(self.source), "commit", "-qm", "move submodule")
            return work.head(str(self.source))

        common = gitlink("1" * 40)
        self.base = gitlink("2" * 40)
        work.git(str(self.source), "checkout", "-qb", "issue", common)
        gitlink("3" * 40)
        self.open_fixture()
        self.assertEqual(self.tick()["outcome"], "stopped")
        self.assert_stopped(path)
        self.codex.assert_not_called()
        self.runner.assert_not_called()

    def test_scope_is_rechecked_after_checks(self):
        self.text_conflict()

        def change_protected_file(native, extra):
            self.write_file(self.checkout, ".github/master.yml", "modified during checks")
            return self.check_candidate(native, extra)

        self.runner.side_effect = change_protected_file
        self.assertEqual(self.tick()["outcome"], "stopped")
        self.assert_stopped(".github/master.yml")

    def test_head_moving_during_checks_abandons_the_merge(self):
        self.text_conflict()

        def move_head(native, extra):
            work.git(str(self.remote), "update-ref", "refs/heads/issue", self.base)
            return self.check_candidate(native, extra)

        self.runner.side_effect = move_head
        self.assertEqual(self.tick()["outcome"], "head moved")
        self.assertEqual(self.remote_head(), self.base)
        self.assertIsNone(work.merge_head(str(self.checkout)))
        self.assertEqual(work.head(str(self.checkout)), self.pr["headRefOid"])
        self.watcher.gh.comment.assert_not_called()
        self.watcher.gh.relabel.assert_called_with(7, [], ["agent-working"])

    def test_lease_protects_a_head_that_moves_after_the_last_check(self):
        self.text_conflict()
        git = work.git

        def git_with_head_move(workdir, *args):
            if args[0] == "push":
                git(str(self.remote), "update-ref", "refs/heads/issue", self.base)
            return git(workdir, *args)

        with patch("work.git", side_effect=git_with_head_move):
            self.assertEqual(self.tick()["outcome"], "head moved")
        self.assertEqual(self.remote_head(), self.base)
        self.watcher.gh.comment.assert_not_called()
        self.assertEqual(self.watcher.load(7).rounds, 0)

    def test_same_conflict_after_an_update_stops_before_calling_codex_again(self):
        self.text_conflict()
        self.tick()
        updated = self.remote_head()
        work.git(str(self.source), "checkout", "-q", "master")
        self.write_file(self.source, "edit.gd", "new master change\n")
        self.base = self.commit(self.source)
        work.git(str(self.source), "push", "-q", str(self.remote), "master")
        self.pr["headRefOid"] = updated
        self.assertEqual(self.tick()["outcome"], "stopped")
        self.assert_stopped("the same conflicts reappeared after the factory update: edit.gd")
        self.codex.assert_called_once()
        self.assertEqual(self.watcher.load(7).rounds, 1)


class ChecksTest(TempFactory):
    def test_regression_imports_even_when_godot_cache_exists(self):
        (self.root / "Project/project-keynes/.godot").mkdir(parents=True)
        (self.root / "tools/map_authoring/tests").mkdir(parents=True)
        self.write_file(self.root, "tools/ci/run_regression_checks.py")
        runner = checks.Runner(self.cfg, str(self.root), str(self.root))
        with patch("checks.static_guards", return_value=[]), patch.object(runner, "_run") as execute:
            runner.run(native=False, extra=[])
        reg = next(args[1] for args, _ in execute.call_args_list if args[0] == "regression")
        self.assertIn("--import", reg)

    def test_base_cache_retries_only_nonpassing_checks(self):
        passed = {"name": "static:a.py", "ok": True}
        failed = {"name": "static:b.py", "ok": False}
        recovered = {**failed, "ok": True}
        cache = self.root / f"{HEAD}.json"
        cache.write_text(json.dumps([passed, failed]), encoding="utf-8")
        self.cfg["checks"]["unit"] = []
        for script in ("a.py", "b.py", "run_regression_checks.py"):
            self.write_file(self.root, f"tools/ci/{script}")
        with (patch("checks.static_guards", return_value=["a.py", "b.py"]),
              patch("checks.Runner._run", side_effect=[failed, {"name": "regression", "ok": True}, recovered])
              as execute):
            first = checks.base_results(self.cfg, str(self.root), HEAD, str(self.root), str(self.root))
            self.assertEqual(checks.failed(first), ["static:b.py"])
            self.assertEqual([r["name"] for r in json.loads(cache.read_text())], ["static:a.py", "regression"])
            second = checks.base_results(self.cfg, str(self.root), HEAD, str(self.root), str(self.root))
            third = checks.base_results(self.cfg, str(self.root), HEAD, str(self.root), str(self.root))
        self.assertEqual(checks.failed(second), [])
        self.assertEqual(third, second)
        self.assertEqual([c.args[0] for c in execute.call_args_list], ["static:b.py", "regression", "static:b.py"])

    def test_missing_static_guard_raises_even_if_cached(self):
        self.write_guard_list(self.root, "missing_guard.py")
        runner = checks.Runner(self.cfg, str(self.root), str(self.root))
        cached = [{"name": "static:missing_guard.py", "ok": True}]
        with (patch.object(runner, "_run") as execute,
              self.assertRaisesRegex(RuntimeError, "tools/ci/missing_guard.py")):
            runner.run(native=False, extra=[], cached=cached)
        execute.assert_not_called()

    def test_missing_regression_script_raises_before_execution(self):
        self.write_guard_list(self.root)
        self.cfg["checks"]["unit"] = []
        runner = checks.Runner(self.cfg, str(self.root), str(self.root))
        with (patch.object(runner, "_run") as execute,
              self.assertRaisesRegex(RuntimeError, "tools/ci/run_regression_checks.py")):
            runner.run(native=False, extra=[])
        execute.assert_not_called()

    def test_missing_unit_directory_or_script_raises_before_execution(self):
        self.write_guard_list(self.root)
        runner = checks.Runner(self.cfg, str(self.root), str(self.root))
        for args, path in ((self.cfg["checks"]["unit"][0], "tools/map_authoring/tests"),
                           (["tools/map_authoring/test_script.py"], "tools/map_authoring/test_script.py")):
            with self.subTest(args=args):
                self.cfg["checks"]["unit"] = [args]
                with patch.object(runner, "_run") as execute, self.assertRaisesRegex(RuntimeError, path):
                    runner.run(native=False, extra=[])
                execute.assert_not_called()

    def test_missing_extra_script_raises_before_execution(self):
        self.write_guard_list(self.root)
        self.cfg["checks"]["unit"] = []
        self.write_file(self.root, "tools/ci/run_regression_checks.py")
        runner = checks.Runner(self.cfg, str(self.root), str(self.root))
        with (patch.object(runner, "_run", return_value={"ok": True}) as execute,
              self.assertRaisesRegex(RuntimeError, "tools/ci/extra_replay.py")):
            runner.run(native=False, extra=["tools/ci/extra_replay.py --days 10"])
        self.assertEqual([c.args[0] for c in execute.call_args_list], ["regression"])


class AdapterTest(TempFactory):
    def test_ci_waits_for_actions_and_checks(self):
        completed = CIRun("completed", "success")
        running = CIRun("in_progress", None)
        failed = CIRun("completed", "failure")
        for workflows, runs, expected in [
            (None, [], "error"),
            ([completed], None, "error"),
            ([], [completed], "pending"),
            ([completed, running], [completed], "pending"),
            ([completed], [], "pending"),
            ([completed], [failed, CIRun("queued", None)], "pending"),
            ([completed], [failed], "failure"),
            ([completed, completed], [completed, CIRun("completed", "skipped")], "success"),
        ]:
            with self.subTest(workflows=workflows, runs=runs):
                self.assertEqual(CIFacts(HEAD, workflows, runs).state(), expected)

    def test_ci_requests_both_lists_for_the_head_sha(self):
        completed = Result(0, '{"status":"completed","conclusion":"success"}\n', "")
        with patch("github.sh", side_effect=[completed, completed]) as cli:
            self.assertEqual(GitHub("example/repo").ci_state(HEAD), "success")
        self.assertIn(f"repos/example/repo/actions/runs?head_sha={HEAD}", cli.call_args_list[0].args[0])
        self.assertIn(f"repos/example/repo/commits/{HEAD}/check-runs", cli.call_args_list[1].args[0])

    def test_ci_records_failure_from_either_query(self):
        failure = Result(1, "partial output", "HTTP 503")
        completed = Result(0, '{"status":"completed","conclusion":"success"}\n', "")
        for results, endpoint in [([failure], "/actions/runs?"),
                                  ([completed, failure], "/check-runs")]:
            with self.subTest(endpoint=endpoint):
                gh = GitHub("example/repo")
                with patch("github.sh", side_effect=results) as cli:
                    self.assertEqual(gh.ci_state(HEAD), "error")
                self.assertEqual(cli.call_count, len(results))
                self.assertEqual(len(gh.errors), 1)
                for part in (endpoint, HEAD, "HTTP 503"):
                    self.assertIn(part, gh.errors[0])

    def test_save_patch_keeps_tracked_and_untracked_edits(self):
        tree = self.root / "tree"
        tree.mkdir()
        work.git(str(tree), "init", "-q")
        (tree / "tracked.gd").write_text("before\n", encoding="utf-8")
        work.git(str(tree), "add", "tracked.gd")
        base = work.git(str(tree), "write-tree")
        (tree / "tracked.gd").write_text("after\n", encoding="utf-8")
        (tree / "new.gd").write_text("new\n", encoding="utf-8")
        (tree / ".factory-disagree.md").write_text("scratch\n", encoding="utf-8")
        path = self.root / "fix.patch"
        self.assertEqual(work.save_patch(str(tree), base, path), [path])
        patch_text = path.read_text(encoding="utf-8")
        for line in ("diff --git a/tracked.gd b/tracked.gd", "-before\n+after\n",
                     "diff --git a/new.gd b/new.gd", "+new\n"):
            self.assertIn(line, patch_text)
        self.assertNotIn(".factory-disagree.md", patch_text)

    def test_save_patch_includes_dirty_submodule_and_skips_clean_submodule(self):
        source, tree = self.root / "source", self.root / "tree"
        for repo in (source, tree):
            repo.mkdir()
            work.git(str(repo), "init", "-q")
            work.git(str(repo), "config", "user.name", "Factory Test")
            work.git(str(repo), "config", "user.email", "factory@example.invalid")
        (source / "tracked.cpp").write_text("before\n", encoding="utf-8")
        work.git(str(source), "add", "tracked.cpp")
        work.git(str(source), "-c", "commit.gpgsign=false", "commit", "-qm", "Submodule base")
        for name in ("gdext/godot-cpp", "vendor/clean", "vendor/untracked"):
            work.git(str(tree), "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(source), name)
        work.git(str(tree), "-c", "commit.gpgsign=false", "commit", "-qm", "Superproject base")
        child = tree / "gdext/godot-cpp"
        (child / "tracked.cpp").write_text("after\n", encoding="utf-8")
        work.git(str(child), "add", "tracked.cpp")
        (child / "new.bin").write_bytes(b"\0new binary content\xff")
        (tree / "vendor/untracked/new.txt").write_text("untracked only\n", encoding="utf-8")

        path = self.root / "fix.patch"
        child_path = self.root / "fix.gdext__godot-cpp.patch"
        untracked_path = self.root / "fix.vendor__untracked.patch"
        self.assertEqual(work.save_patch(str(tree), work.head(str(tree)), path), [path, child_path, untracked_path])
        self.assertIn("diff --git a/gdext/godot-cpp b/gdext/godot-cpp", path.read_text(encoding="utf-8"))
        patch_text = child_path.read_text(encoding="utf-8")
        self.assertIn("-before\n+after\n", patch_text)
        self.assertIn("diff --git a/new.bin b/new.bin", patch_text)
        self.assertIn("GIT binary patch", patch_text)
        work.git(str(source), "apply", "--check", str(child_path))
        self.assertIn("+untracked only\n", untracked_path.read_text(encoding="utf-8"))
        self.assertFalse((self.root / "fix.vendor__clean.patch").exists())

    def test_prepare_forces_submodule_checkout_and_cleans_inside(self):
        with patch("work._is_sparse", return_value=False), patch("work.must", return_value="") as git:
            work.prepare(str(self.root), "fork", "master", "test")
        sub = self.root / "gdext/godot-cpp"
        git.assert_has_calls([
            call(["git", "-C", str(self.root), "submodule", "update", "--init", "--checkout", "--force",
                  "gdext/godot-cpp"], timeout=3600),
            call(["git", "-C", str(sub), "clean", "-fdq"]),
        ])

    def test_ensure_leaves_existing_checkout_for_prepare_to_reset(self):
        (self.root / ".git").touch()
        with patch("work.must") as git:
            work.ensure(str(self.root), str(self.root), "fork/master")
        git.assert_not_called()

    def test_changed_includes_dirty_submodule_and_protected_nested_files(self):
        with patch("work.git", side_effect=["gdext/godot-cpp\0", "tools/ci/.factory-test\0.factory-note\0"]) as git:
            files = work.changed(str(self.root), HEAD)
        self.assertIn("--ignore-submodules=none", git.call_args_list[0].args)
        self.assertEqual(work.scope(self.cfg, files), (["tools/ci/.factory-test"], ["gdext/godot-cpp"], []))

    def test_local_review_reports_missing_open_finding_level(self):
        output = {"finding_state": {"complete": True, "introduced": ["missing"]}}
        with patch("qodo.sh", return_value=Result(0, json.dumps(output), "")):
            result = qodo.local_review("unused", str(self.root), "repo", HEAD, "context", 1)
        self.assertEqual(result["unknown"], [{"id": "missing"}])
        self.assertFalse(result["informational"])

    def test_rule_sync_attempts_remaining_rules_and_returns_failure(self):
        rule = dict(category="test", severity="warning", content="test", good_examples=[], bad_examples=[])
        spec = {"scope": "test", "rules": [{**rule, "name": name} for name in ("first", "second")]}
        path = self.root / "rules.json"
        path.write_text(json.dumps(spec))
        with (patch.object(sync_rules, "RULES", path), patch.object(sys, "argv", ["sync_rules.py", "--apply"]),
              patch("sync_rules.existing", return_value={}),
              patch("sync_rules.sh", side_effect=[Result(1, "", "failed"), Result(0, "{}", "")]) as cli):
            self.assertEqual(sync_rules.main(), 1)
            self.assertEqual(cli.call_count, 2)


class PollScriptsTest(TempFactory):
    def test_poll_distinguishes_unmerged_factory_from_broken_checkout(self):
        runner = self.root / "runner"
        runner.mkdir()
        (runner / ".git").touch()
        fake_git = self.root / "git"
        fake_git.write_text('#!/bin/sh\nif [ "$1" = ls-tree ]; then printf "%s" "$FACTORY_TEST_ENTRY"; fi\n')
        fake_git.chmod(0o755)
        env = {**os.environ, "PATH": f"{self.root}:/usr/bin:/bin", "KEYNES_REPO": str(self.root),
               "KEYNES_FACTORY_HOME": str(self.root), "KEYNES_FACTORY_PYTHON": sys.executable}
        args = ["/bin/zsh", str(FACTORY / "poll.sh"), "--dry"]
        for entry, expected in (("", 0), ("tools/factory", 1)):
            with self.subTest(entry=entry):
                result = subprocess.run(args, env={**env, "FACTORY_TEST_ENTRY": entry}, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected)
                self.assertEqual("watch_prs.py is missing" in result.stderr, bool(expected))
        factory = runner / "tools/factory"
        factory.mkdir(parents=True)
        (factory / "watch_prs.py").write_text("import sys\nprint(sys.executable, sys.argv[1])\n")
        result = subprocess.run(args, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"{sys.executable} --dry")
        env.pop("KEYNES_FACTORY_PYTHON")
        fallback = self.root / "python3"
        fallback.symlink_to(sys.executable)
        result = subprocess.run(args, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip().endswith(" --dry"))

    def test_installer_plist_carries_configured_python(self):
        path = self.root / "launch.plist"
        script = (FACTORY / "install_poller.sh").read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        factory = self.root / "factory"
        factory.mkdir()
        (factory / "common.py").write_text((FACTORY / "common.py").read_text())
        self.cfg["tools"]["python"] = "/test/path with spaces & symbols/python3"
        (factory / "config.json").write_text(json.dumps(self.cfg))
        subprocess.run([sys.executable, "-", str(factory), str(path), "test", str(self.root), str(self.root)],
                       input=script, text=True, check=True)
        env = plistlib.loads(path.read_bytes())["EnvironmentVariables"]
        self.assertEqual(env["KEYNES_FACTORY_PYTHON"], self.cfg["tools"]["python"])


class EnsureTest(unittest.TestCase):
    def test_reference_goes_after_update(self):
        with tempfile.TemporaryDirectory() as d:
            main = Path(d) / "main"
            (main / work.GODOT_CPP / ".git").mkdir(parents=True)
            workdir = str(Path(d) / "work")
            with (patch.object(work, "common_dir", return_value=str(main / ".git")),
                  patch.object(work, "_is_sparse", return_value=False),
                  patch.object(work, "must", return_value="") as must):
                work.ensure(str(main), workdir, "fork/master")
            must.assert_has_calls([
                call(["git", "-C", workdir, "submodule", "update", "--reference", str(main / work.GODOT_CPP),
                      "--init", work.GODOT_CPP], timeout=3600),
                call(["git", "-C", str(Path(workdir) / work.GODOT_CPP), "ls-files", "--deleted", "-z", "--"]),
            ])


class WorktreeTest(TempFactory):
    OUTSIDE = "tools/ci/check_project.py"

    def setUp(self):
        super().setUp()
        self.main, submodule = self.root / "main", self.root / "submodule"
        main = self.main
        for repo in (main, submodule):
            repo.mkdir()
            work.git(str(repo), "init", "-q", "-b", "master")
            work.git(str(repo), "config", "user.name", "Factory Test")
            work.git(str(repo), "config", "user.email", "factory@example.invalid")
        self.write_file(submodule, "sub.cpp", "int main() {}\n")
        self.write_file(submodule, "include/sub.h")
        self.commit_all(submodule)
        work.git(str(main), "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                 str(submodule), work.GODOT_CPP)
        self.write_file(main, self.OUTSIDE, "# factory check\n")
        self.write_file(main, "tools/factory/watch_prs.py")
        self.write_guard_list(main, "check_project.py")
        self.base = self.commit_all(main)
        work.git(str(main), "remote", "add", "fork", str(main))
        self.runner = self.root / "runner"
        self.agent = self.root / "work"
        work.git(str(main), "worktree", "add", "--detach", str(self.runner), self.base)
        self.make_sparse(self.runner)
        self.assertFalse((self.runner / self.OUTSIDE).exists())
        self.enterContext(patch.dict(os.environ, {"GIT_ALLOW_PROTOCOL": "file"}))

    def commit_all(self, repo):
        work.git(str(repo), "add", "-A")
        work.git(str(repo), "-c", "commit.gpgsign=false", "commit", "-qm", "test checkout")
        return work.head(str(repo))

    def make_sparse(self, tree):
        work.git(str(tree), "sparse-checkout", "set", "--no-cone", "/tools/factory/", "/.github/")

    def existing_sparse_agent(self):
        work.git(str(self.runner), "worktree", "add", "--detach", str(self.agent), self.base)
        self.make_sparse(self.agent)
        self.assertFalse((self.agent / self.OUTSIDE).exists())

    def assert_full_agent(self):
        self.assertEqual(work.git(str(self.agent), "config", "--worktree", "--get", "core.sparseCheckout"), "false")
        self.assertTrue((self.agent / self.OUTSIDE).is_file())
        self.assertTrue((self.agent / work.GODOT_CPP / "sub.cpp").is_file())

    def test_ensure_from_sparse_runner_creates_full_checkout(self):
        work.ensure(str(self.runner), str(self.agent), self.base)
        self.assert_full_agent()
        self.assertFalse((self.runner / self.OUTSIDE).exists())

    def test_prepare_repairs_existing_sparse_checkout(self):
        self.existing_sparse_agent()
        self.assertEqual(work.prepare(str(self.agent), "fork", "master", "factory-test"), self.base)
        self.assert_full_agent()

    def test_prepare_repairs_sparse_index_even_when_config_is_off(self):
        self.existing_sparse_agent()
        work.git(str(self.agent), "config", "--worktree", "core.sparseCheckout", "false")
        self.assertEqual(work.prepare(str(self.agent), "fork", "master", "factory-test"), self.base)
        self.assert_full_agent()

    def test_prepare_repairs_existing_sparse_submodule(self):
        work.ensure(str(self.runner), str(self.agent), self.base)
        submodule = self.agent / work.GODOT_CPP
        work.git(str(submodule), "sparse-checkout", "set", "--no-cone", "/include/")
        self.assertTrue((submodule / "include/sub.h").is_file())
        self.assertFalse((submodule / "sub.cpp").exists())

        self.assertEqual(work.prepare(str(self.agent), "fork", "master", "factory-test"), self.base)
        self.assertEqual(work.git(str(submodule), "config", "--get", "core.sparseCheckout"), "false")
        self.assertEqual((submodule / "sub.cpp").read_text(encoding="utf-8"), "int main() {}\n")

    def test_rejects_missing_submodule_file_after_update(self):
        original_must = work.must

        def remove_file_after_update(args, **kwargs):
            result = original_must(args, **kwargs)
            if args[3:5] == ["submodule", "update"]:
                (Path(args[2]) / work.GODOT_CPP / "sub.cpp").unlink()
            return result

        initial = self.root / "initial"
        work.ensure(str(self.runner), str(self.agent), self.base)
        for operation, args, directory in (
            (work.ensure, (str(self.runner), str(initial), self.base), initial),
            (work.prepare, (str(self.agent), "fork", "master", "factory-test"), self.agent),
        ):
            with self.subTest(operation=operation.__name__):
                with patch("work.must", side_effect=remove_file_after_update), self.assertRaises(RuntimeError) as error:
                    operation(*args)
                submodule = directory / work.GODOT_CPP
                self.assertEqual(str(error.exception),
                                 f"incomplete work tree at {submodule}: missing tracked files 'sub.cpp'")

    def test_prepare_rejects_incomplete_tree_after_submodule_update(self):
        work.git(str(self.main), "worktree", "add", "--detach", str(self.agent), self.base)
        original_must = work.must

        def interrupt_after_update(args, **kwargs):
            result = original_must(args, **kwargs)
            if args[3:5] == ["submodule", "update"]:
                if enable_sparse:
                    self.make_sparse(self.agent)
                else:
                    (self.agent / self.OUTSIDE).unlink()
            return result

        for enable_sparse, reason in ((False, self.OUTSIDE), (True, "sparse checkout is still active")):
            with (self.subTest(enable_sparse=enable_sparse), patch("work.must", side_effect=interrupt_after_update),
                  self.assertRaisesRegex(RuntimeError, f"incomplete work tree.*{reason}")):
                work.prepare(str(self.agent), "fork", "master", "factory-test")
