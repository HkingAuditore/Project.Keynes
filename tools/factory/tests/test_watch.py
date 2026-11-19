import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common import Result, load_config  # noqa: E402
from verdict import CIFacts, CIRun  # noqa: E402
from watch_prs import PrState, Watcher, decide  # noqa: E402

HEAD = "a" * 40
SKIP = ["blocked", "needs-investigation"]


def pr(**kw):
    return {"number": 7, "headRefOid": HEAD, "isDraft": False, "isCrossRepository": False, "labels": [], **kw}


def review(status="completed", sha=HEAD, findings=None):
    return {"review_session": {"status": status, "commit_sha": sha}, "findings": findings or []}


def finding(i, level="action_required", status="pending"):
    return {"id": i, "action_level": level, "attribution_status": status, "title": f"f{i}"}


class Decide(unittest.TestCase):
    def d(self, p=None, r=None, st=None, limit=3):
        return decide(p or pr(), r, st or PrState(), SKIP, limit)

    def test_fix_on_blocking_findings_at_head(self):
        d = self.d(r=review(findings=[finding("x"), finding("y", "informational")]))
        self.assertEqual((d.action, [f["id"] for f in d.findings]), ("fix", ["x"]))

    def test_recommended_level_also_blocks(self):
        self.assertEqual(self.d(r=review(findings=[finding("x", "remediation_recommended")])).action, "fix")

    def test_closed_findings_do_not_block(self):
        self.assertEqual(self.d(r=review(findings=[finding("x", status="implemented")])).action, "skip")

    def test_missing_or_unknown_action_level_stops_before_fixing_other_findings(self):
        for item in (finding("x", "new_level"), {"id": "x", "attribution_status": "pending"}):
            with self.subTest(item=item):
                d = self.d(r=review(findings=[item, finding("y")]))
                self.assertEqual(d.action, "stop")
                self.assertIn("x (status='pending', action_level=", d.reason)

    def test_waits_for_review_of_head(self):
        self.assertEqual(self.d(r=review(sha="b" * 40, findings=[finding("x")])).action, "skip")
        self.assertEqual(self.d(r=review(status="started", findings=[finding("x")])).action, "skip")
        self.assertEqual(self.d(r=None).action, "skip")
        self.assertEqual(self.d(r={"review_session": None}).action, "skip")

    def test_failed_review_stops(self):
        self.assertEqual(self.d(r=review(status="failed")).action, "stop")

    def test_skips_draft_cross_repo_and_labels(self):
        r = review(findings=[finding("x")])
        self.assertEqual(self.d(p=pr(isDraft=True), r=r).action, "skip")
        self.assertEqual(self.d(p=pr(isCrossRepository=True), r=r).action, "skip")
        self.assertEqual(self.d(p=pr(labels=["blocked"]), r=r).action, "skip")

    def test_does_not_retry_where_it_stopped(self):
        st = PrState(gave_up_at=HEAD, reason="x")
        self.assertEqual(self.d(r=review(findings=[finding("x")]), st=st).action, "skip")

    def test_old_attempt_is_skipped_if_a_person_restores_that_head(self):
        st = PrState(gave_up_at="b" * 40, attempted=[HEAD])
        r = review(findings=[finding("x")])
        self.assertEqual(self.d(r=r, st=st).action, "skip")
        st.pushed.append(HEAD)
        self.assertEqual(self.d(r=r, st=st).action, "fix")

    def test_same_findings_after_own_fix_stops(self):
        st = PrState(pushed=[HEAD], rounds=1, seen=[["x"]])
        self.assertEqual(self.d(r=review(findings=[finding("x")]), st=st).action, "stop")

    def test_round_limit_after_own_fixes(self):
        st = PrState(pushed=[HEAD], rounds=3, seen=[["a"], ["b"], ["c"]])
        self.assertEqual(self.d(r=review(findings=[finding("x")]), st=st).action, "stop")

    def test_a_person_pushing_resets_rounds(self):
        st = PrState(pushed=["c" * 40], rounds=3, seen=[["x"]])
        self.assertEqual(self.d(r=review(findings=[finding("x")]), st=st).action, "fix")

    def test_disputed_findings_are_left_to_a_person(self):
        st = PrState(disputed=["x"])
        d = self.d(r=review(findings=[finding("x")]), st=st)
        self.assertEqual(d.action, "skip")
        d = self.d(r=review(findings=[finding("x"), finding("y")]), st=st)
        self.assertEqual([f["id"] for f in d.findings], ["y"])


class MergeDecision(unittest.TestCase):
    def setUp(self):
        self.workflow = CIRun("completed", "success", id=101, name="Runtime")
        self.check = CIRun("completed", "success", id=102, name="Save and restore")
        self.ci = CIFacts(HEAD, [self.workflow], [self.check])

    def d(self, p=None, r=None, state=None, **opts):
        options = {"auto_merge": True, "ci": self.ci, **opts}
        return decide(p or pr(mergeable="MERGEABLE"), r or review(), state or PrState(), SKIP, 3, **options)

    def test_merges_clean_head_with_green_ci_and_lists_information(self):
        info = finding("info", "informational")
        closed = finding("old", status="implemented")
        d = self.d(r=review(findings=[info, closed]))
        self.assertEqual((d.action, d.findings), ("merge", [info]))

    def test_disabled_auto_merge_skips_clean_pr(self):
        self.assertEqual(self.d(auto_merge=False).action, "skip")

    def test_draft_cross_repo_and_each_skip_label_prevent_merge(self):
        for flags in ({"isDraft": True}, {"isCrossRepository": True}, *({"labels": [label]} for label in SKIP)):
            with self.subTest(flags=flags):
                self.assertEqual(self.d(p=pr(mergeable="MERGEABLE", **flags)).action, "skip")

    def test_factory_labels_and_no_auto_merge_prevent_merge(self):
        for label in ("agent-needs-help", "agent-working", "no-auto-merge"):
            with self.subTest(label=label):
                d = self.d(p=pr(mergeable="MERGEABLE", labels=[label]))
                self.assertEqual(d.action, "skip")
                self.assertFalse(d.needs_ci)

    def test_waits_for_completed_review_of_current_head(self):
        for r in (review(sha="older-head"), review(status="started"), {"review_session": None}):
            self.assertEqual(self.d(r=r).action, "skip")
        self.assertEqual(self.d(r=review(status="failed")).action, "stop")

    def test_unknown_finding_fields_and_missing_list_stop_merge(self):
        items = [finding("status", status="unknown"), finding("open", level="unknown"),
                 finding("closed", status="implemented", level=None)]
        for item in items:
            with self.subTest(item=item):
                self.assertEqual(self.d(r=review(findings=[item])).action, "stop")
        self.assertEqual(self.d(r={"review_session": review()["review_session"]}).action, "stop")

    def test_open_blocking_findings_prevent_merge_even_if_disputed(self):
        for level in ("action_required", "remediation_recommended"):
            with self.subTest(level=level):
                r = review(findings=[finding("block", level), finding("info", "informational")])
                self.assertEqual(self.d(r=r).action, "fix")
                self.assertEqual(self.d(r=r, state=PrState(disputed=["block"])).action, "skip")

    def test_conflicting_and_unknown_mergeability_prevent_merge(self):
        for status in ("CONFLICTING", "UNKNOWN", None):
            with self.subTest(status=status):
                self.assertEqual(self.d(p=pr(mergeable=status)).action, "skip")

    def test_ci_requires_evidence_for_same_head(self):
        for ci in (None, replace(self.ci, sha="older-head")):
            d = self.d(ci=ci)
            self.assertEqual(d.action, "skip")
            self.assertTrue(d.needs_ci)

    def test_missing_or_incomplete_workflows_and_checks_wait(self):
        for ci in (replace(self.ci, workflows=[]),
                   replace(self.ci, workflows=[self.workflow, replace(self.workflow, status="queued")]),
                   replace(self.ci, checks=[self.check, replace(self.check, status="in_progress")])):
            with self.subTest(ci=ci):
                self.assertEqual(self.d(ci=ci).action, "skip")
                self.assertEqual(ci.state(strict=True), "pending")

    def test_workflow_is_required_and_a_completed_check_query_may_be_empty(self):
        self.assertEqual(self.d(ci=replace(self.ci, checks=[])).action, "merge")

    def test_each_workflow_and_check_conclusion_must_be_success(self):
        for conclusion in ("failure", "cancelled", "neutral", "skipped", None):
            for ci in (replace(self.ci, workflows=[self.workflow, replace(self.workflow, conclusion=conclusion)]),
                       replace(self.ci, checks=[self.check, replace(self.check, conclusion=conclusion)])):
                with self.subTest(ci=ci):
                    self.assertEqual(self.d(ci=ci).action, "skip")
                    self.assertEqual(ci.state(strict=True), "failure")

    def test_failed_ci_query_stops(self):
        for ci in (replace(self.ci, workflows=None), replace(self.ci, checks=None)):
            self.assertEqual(self.d(ci=ci).action, "stop")


class MergeWorkflow(unittest.TestCase):
    def setUp(self):
        self.home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        cfg = load_config()
        cfg["home"] = str(self.home)
        self.watcher = Watcher(cfg, dry=False)
        self.pr = pr(mergeable="MERGEABLE", url="https://example.invalid/pr/7")
        self.merge_sha = "b" * 40
        self.enterContext(patch.object(self.watcher, "prs", return_value=[self.pr]))
        self.enterContext(patch("qodo.pr_review", return_value=review(findings=[finding("info", "informational")])))
        self.cli = self.enterContext(patch("github.sh", side_effect=self.github_query))
        self.must = self.enterContext(patch("github.must", side_effect=[
            "", json.dumps({"state": "MERGED", "headRefOid": HEAD, "mergeCommit": {"oid": self.merge_sha}})
        ]))
        self.fail_checks = False

    def github_query(self, args, **kw):
        if args[1] != "api":
            return Result(0, "", "")
        workflow = "/actions/runs?" in args[2]
        if not workflow and self.fail_checks:
            return Result(1, "", "HTTP 503")
        run = {"id": 10 if workflow else 11, "status": "completed", "conclusion": "success",
               "name": "Runtime workflow" if workflow else "Runtime check", "url": "https://example.invalid/run"}
        return Result(0, json.dumps(run) + "\n", "")

    def record(self):
        return json.loads((self.home / "runs" / f"merge-pr-7-{self.watcher.stamp}.json").read_text())

    def test_merges_with_head_guard_and_records_ci_and_review_evidence(self):
        self.assertEqual(self.watcher.tick(None), 0)
        self.assertEqual(self.must.call_args_list[0], call(
            ["gh", "pr", "merge", "7", "--repo", "hrhgit/Project.Keynes", "--merge", "--match-head-commit", HEAD]))
        queried = [c.args[0][2] for c in self.cli.call_args_list if c.args[0][1] == "api"]
        self.assertEqual(queried, [f"repos/hrhgit/Project.Keynes/actions/runs?head_sha={HEAD}",
                                   f"repos/hrhgit/Project.Keynes/commits/{HEAD}/check-runs?filter=all"])
        self.assertEqual(self.cli.call_args.args[0][:4], ["gh", "pr", "comment", "7"])
        comment = self.cli.call_args.kwargs["stdin"]
        for value in (HEAD, "Runtime workflow", "Runtime check", "info"):
            self.assertIn(value, comment)
        record = self.record()
        self.assertEqual((record["outcome"], record["reviewedSha"], record["mergeCommit"]),
                         ("merged", HEAD, self.merge_sha))
        self.assertEqual(record["ci"]["workflows"][0]["id"], 10)
        self.assertEqual(record["ci"]["checks"][0]["id"], 11)
        self.assertEqual(record["informationalFindings"][0]["id"], "info")

    def test_failed_merge_command_labels_pr_and_records_error(self):
        self.must.side_effect = RuntimeError("head changed")
        self.assertEqual(self.watcher.tick(None), 1)
        self.assert_stopped("head changed")

    def test_queued_merge_is_not_reported_as_merged(self):
        self.must.side_effect = ["", json.dumps({"state": "OPEN", "headRefOid": HEAD, "mergeCommit": None})]
        self.assertEqual(self.watcher.tick(None), 1)
        self.assert_stopped("GitHub did not confirm a merge")

    def test_ci_query_error_labels_pr_without_attempting_merge(self):
        self.fail_checks = True
        self.assertEqual(self.watcher.tick(None), 1)
        self.must.assert_not_called()
        self.assert_stopped("CI state could not be read")
        self.assertIn("HTTP 503", self.record()["githubErrors"][0])

    def test_disabled_auto_merge_does_not_query_ci_or_write(self):
        self.watcher.cfg["autoMerge"] = False
        self.assertEqual(self.watcher.tick(None), 0)
        self.must.assert_not_called()
        self.cli.assert_not_called()
        self.assertFalse((self.home / "runs").exists())

    def test_dry_run_reads_evidence_without_writes(self):
        self.watcher.dry = True
        self.assertEqual(self.watcher.tick(None), 0)
        self.must.assert_not_called()
        self.assertEqual(self.cli.call_count, 2)
        self.assertTrue(all(c.args[0][1] == "api" for c in self.cli.call_args_list))
        self.assertFalse((self.home / "runs").exists())

    def assert_stopped(self, error):
        record = self.record()
        self.assertEqual(record["outcome"], "stopped")
        self.assertIn(error, record["error"])
        self.assertEqual(self.watcher.load(7).gave_up_at, HEAD)
        self.assertEqual(self.cli.call_args.args[0][:4], ["gh", "pr", "edit", "7"])
        self.assertIn("agent-needs-help", self.cli.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
