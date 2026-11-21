import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common import Result, load_config  # noqa: E402
from github import GitHub  # noqa: E402
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
        cfg = load_config()
        cfg["autoMerge"] = False
        cfg["limits"]["prReviewRounds"] = limit
        return decide(p or pr(), r, st or PrState(), cfg)

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

    def test_skips_issue_branches_until_handed_over(self):
        # No label is the safe state: an issue PR whose labelling failed is still skipped.
        owned = pr(headRefName="agent/issue-11", labels=[])
        reason = "the issue runner has not handed this PR over"
        self.assertEqual(self.d(p=owned, r=review(findings=[finding("x")])).reason, reason)
        self.assertEqual(self.d(p={**owned, "mergeable": "CONFLICTING"}).action, "skip")
        cfg = load_config()
        self.assertEqual(decide(owned, review(), PrState(), cfg).reason, reason)
        handed = {**owned, "labels": ["factory-handoff"]}
        self.assertEqual(self.d(p=handed, r=review(findings=[finding("x")])).action, "fix")
        self.assertEqual(self.d(p=pr(headRefName="feature/x"), r=review(findings=[finding("x")])).action, "fix")

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
        cfg = load_config()
        cfg["autoMerge"] = opts.pop("auto_merge", True)
        options = {"ci": self.ci, "changed_files": [], **opts}
        return decide(p or pr(mergeable="MERGEABLE"), r or review(), state or PrState(), cfg, **options)

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

    def test_unknown_mergeability_waits(self):
        for status in ("UNKNOWN", None):
            with self.subTest(status=status):
                self.assertEqual(self.d(p=pr(mergeable=status)).action, "skip")
        self.assertEqual(self.d(p=pr(mergeable="UNKNOWN"), r=review(findings=[finding("x")])).action, "skip")

    def test_conflicting_head_updates_without_review_or_ci(self):
        cfg = load_config()
        p = pr(mergeable="CONFLICTING")
        for r in (None, review(status="failed"), review(findings=[finding("x")])):
            with self.subTest(review=r):
                self.assertEqual(decide(p, r, PrState(), cfg).action, "update")

    def test_conflict_update_respects_skip_conditions(self):
        cfg = load_config()
        blocked = [*SKIP, cfg["labels"]["help"], cfg["labels"]["working"]]
        for flags in ({"isDraft": True}, {"isCrossRepository": True}, *({"labels": [label]} for label in blocked)):
            with self.subTest(flags=flags):
                self.assertEqual(decide(pr(mergeable="CONFLICTING", **flags), None, PrState(), cfg).action, "skip")
        p = pr(mergeable="CONFLICTING")
        self.assertEqual(decide(p, None, PrState(gave_up_at=HEAD), cfg).action, "skip")
        cfg["autoUpdateConflicts"] = False
        self.assertEqual(decide(p, review(findings=[finding("x")]), PrState(), cfg).action, "skip")

    def test_conflict_update_does_not_retry_an_already_attempted_factory_head(self):
        p = pr(mergeable="CONFLICTING")
        st = PrState(pushed=[HEAD], rounds=1, update_attempted=[HEAD])
        self.assertEqual(decide(p, None, st, load_config()).action, "skip")

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
        self.pr = pr(mergeable="MERGEABLE", url="https://example.invalid/pr/7", state="OPEN",
                     baseRefName="master", baseRefOid="c" * 40, changedFiles=1)
        self.fresh_pr = dict(self.pr)
        self.files = [{"filename": "scripts/test.gd", "status": "modified"}]
        self.merge_sha = "b" * 40
        self.enterContext(patch.object(self.watcher, "prs", return_value=[self.pr]))
        self.enterContext(patch("qodo.pr_review", return_value=review(findings=[finding("info", "informational")])))
        self.cli = self.enterContext(patch("github.sh", side_effect=self.github_query))
        self.must = self.enterContext(patch("github.must", side_effect=self.github_request))
        self.fail_checks = False
        self.fail_files = False
        self.fail_help_label = False
        self.fail_working_label_removal = False
        self.merge_error = None
        self.preflight_error = None
        self.read_error = None
        self.merge_state = "MERGED"
        self.reported_head = HEAD
        self.check_result = "success"
        self.workflow_result = "success"
        self.rerun = False

    def github_request(self, args):
        if args[1] == "api" and "/pulls/7/files" in args[2]:
            if self.fail_files:
                raise RuntimeError("HTTP 503")
            return "\n".join(json.dumps(item) for item in self.files)
        if args[1:3] == ["pr", "merge"]:
            if self.merge_error:
                raise RuntimeError(self.merge_error)
            return ""
        if args[1:3] == ["pr", "view"]:
            if "labels" in args[5].split(","):
                if self.preflight_error:
                    raise RuntimeError(self.preflight_error)
                return json.dumps({**self.fresh_pr, "labels": [{"name": x} for x in self.fresh_pr["labels"]]})
            if self.read_error:
                raise RuntimeError(self.read_error)
            commit = {"oid": self.merge_sha} if self.merge_state == "MERGED" else None
            return json.dumps({"state": self.merge_state, "headRefOid": self.reported_head,
                               "mergeCommit": commit})
        self.fail(f"unexpected GitHub command: {args}")

    def github_query(self, args, **kw):
        if args[1] != "api":
            return Result(0, "", "")
        if "/issues/7/labels" in args[2]:
            if self.fail_help_label and "POST" in args:
                return Result(1, "", "HTTP 503 adding label")
            if self.fail_working_label_removal and "DELETE" in args:
                return Result(1, "", "HTTP 503 removing label")
            return Result(0, "", "")
        workflow = "/actions/runs?" in args[2]
        if not workflow and self.fail_checks:
            return Result(1, "", "HTTP 503")
        run = {"id": 10 if workflow else 11, "status": "completed", "conclusion": "success",
               "name": "Runtime workflow" if workflow else "Runtime check", "url": "https://example.invalid/run"}
        if workflow:
            run.update(workflow_id=21, run_number=2, run_attempt=2, conclusion=self.workflow_result)
        else:
            run["conclusion"] = self.check_result
        runs = [run]
        if self.rerun:
            if workflow:
                old = "failure" if self.workflow_result == "success" else "success"
                runs = [{**run, "id": 9, "run_number": 1, "run_attempt": 3, "conclusion": old},
                        run, {**run, "run_attempt": 1, "conclusion": old}]
            elif "filter=latest" not in args[2]:
                old = "failure" if self.check_result == "success" else "success"
                runs.append({**run, "id": 8, "conclusion": old})
        return Result(0, "\n".join(json.dumps(item) for item in runs), "")

    def record(self):
        return json.loads((self.home / "runs" / f"merge-pr-7-{self.watcher.stamp}.json").read_text())

    def test_merges_with_head_guard_and_records_ci_and_review_evidence(self):
        self.assertEqual(self.watcher.tick(None), 0)
        self.assertEqual(self.must.call_args_list[-2], call(
            ["gh", "pr", "merge", "7", "--repo", "hrhgit/Project.Keynes", "--merge", "--match-head-commit", HEAD]))
        self.assertEqual(self.must.call_args_list[-3].args[0][:4], ["gh", "pr", "view", "7"])
        queried = [c.args[0][2] for c in self.cli.call_args_list if c.args[0][1] == "api"]
        self.assertEqual(queried, [f"repos/hrhgit/Project.Keynes/actions/runs?head_sha={HEAD}",
                                   f"repos/hrhgit/Project.Keynes/commits/{HEAD}/check-runs?filter=latest"])
        self.assertEqual(self.cli.call_args.args[0][:4], ["gh", "pr", "comment", "7"])
        comment = self.cli.call_args.kwargs["stdin"]
        self.assertIn("Factory merged PR #7", comment)
        for value in (HEAD, "Runtime workflow", "Runtime check", "info"):
            self.assertIn(value, comment)
        record = self.record()
        self.assertEqual((record["outcome"], record["reviewedSha"], record["mergeCommit"]),
                         ("merged", HEAD, self.merge_sha))
        self.assertEqual(record["githubErrors"], [])
        self.assertEqual(record["ci"]["workflows"][0]["id"], 10)
        self.assertEqual(record["ci"]["checks"][0]["id"], 11)
        self.assertEqual(record["informationalFindings"][0]["id"], "info")

    def test_failed_merge_command_labels_pr_and_records_error(self):
        self.merge_error = "head changed"
        self.assertEqual(self.watcher.tick(None), 1)
        self.assert_stopped("head changed")

    def test_successful_merge_with_failed_follow_up_still_comments_and_records_merged(self):
        self.read_error = "HTTP 503"
        self.assertEqual(self.watcher.tick(None), 0)
        record = self.record()
        self.assertEqual(record["outcome"], "merged")
        self.assertIsNone(record["mergeCommit"])
        self.assertIn("HTTP 503", record["githubErrors"][0])
        self.assertIsNone(self.watcher.load(7).gave_up_at)
        self.assertIn("Factory merged PR #7", self.cli.call_args.kwargs["stdin"])
        self.assertTrue(all("/issues/7/labels" not in c.args[0][2] for c in self.cli.call_args_list))

    def assert_reported_not_merged(self):
        self.assertEqual(self.watcher.tick(None), 1)
        record = self.record()
        self.assertEqual(record["outcome"], "not_merged")
        self.assertIsNone(record["mergeCommit"])
        self.assertEqual(record["githubErrors"], [])
        self.assertIn(self.merge_state, record["error"])
        self.assertIn(self.reported_head, record["error"])
        self.assertIsNone(self.watcher.load(7).gave_up_at)
        self.assertNotIn("merge_requested_at", vars(self.watcher.load(7)))
        comments = [c.kwargs["stdin"] for c in self.cli.call_args_list if c.args[0][1:3] == ["pr", "comment"]]
        self.assertEqual(len(comments), 1)
        self.assertIn("Factory stopped", comments[0])
        self.assertIn(record["error"], comments[0])
        self.assertIn("will not retry", comments[0])
        self.assertIn("Remove `agent-needs-help`", comments[0])
        self.assert_help_label_added()

    def test_open_after_merge_stops_with_not_merged(self):
        self.merge_state = "OPEN"
        self.assert_reported_not_merged()

    def test_closed_after_merge_stops_with_not_merged(self):
        self.merge_state = "CLOSED"
        self.assert_reported_not_merged()

    def test_merged_at_a_different_head_stops_with_not_merged(self):
        self.reported_head = "d" * 40
        self.assert_reported_not_merged()

    def test_removing_help_label_allows_same_head_to_retry(self):
        self.merge_state = "OPEN"
        self.assert_reported_not_merged()
        self.must.reset_mock()
        self.pr["labels"] = self.fresh_pr["labels"] = ["agent-needs-help"]
        self.assert_skipped("has a label that blocks auto-merge")
        self.pr["labels"] = self.fresh_pr["labels"] = []
        self.merge_state = "MERGED"
        self.assertEqual(self.watcher.tick(None), 0)
        self.assertEqual(self.record()["outcome"], "merged")
        self.assertEqual(self.must.call_args_list[-2].args[0][-1], HEAD)

    def test_failed_help_label_add_saves_stop_and_blocks_next_tick(self):
        self.merge_state = "OPEN"
        self.fail_help_label = True
        self.assertEqual(self.watcher.tick(None), 1)
        record = self.record()
        self.assertEqual(record["outcome"], "not_merged")
        self.assertIn("HTTP 503 adding label", record["githubErrors"][0])
        state = self.watcher.load(7)
        self.assertEqual((state.gave_up_at, state.reason), (HEAD, record["error"]))
        comment = self.cli.call_args.kwargs["stdin"]
        self.assertIn("could not add `agent-needs-help`", comment)
        self.assertIn("HTTP 503 adding label", comment)
        self.assertIn("after the next push", comment)

        self.must.reset_mock()
        self.cli.reset_mock()
        self.assert_skipped("stopped at this head")
        self.cli.assert_not_called()

    def test_working_label_removal_failure_preserves_help_label_retry(self):
        self.merge_state = "OPEN"
        self.fail_working_label_removal = True
        self.assertEqual(self.watcher.tick(None), 1)
        record = self.record()
        self.assertEqual(record["outcome"], "not_merged")
        self.assertIn("HTTP 503 removing label", record["githubErrors"][0])
        self.assertIsNone(self.watcher.load(7).gave_up_at)
        comment = next(c.kwargs["stdin"] for c in self.cli.call_args_list if c.args[0][1:3] == ["pr", "comment"])
        self.assertIn("Remove `agent-needs-help`", comment)

    def test_legacy_queue_marker_does_not_block_merging(self):
        path = self.watcher.state_path(7)
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"merge_requested_at": HEAD, "rounds": 2}), encoding="utf-8")
        self.assertEqual(self.watcher.tick(None), 0)
        self.assertEqual(self.record()["outcome"], "merged")
        state = self.watcher.load(7)
        self.assertEqual(state.rounds, 2)
        self.assertNotIn("merge_requested_at", vars(state))

    def test_changes_in_pr_state_before_merge_are_recorded_as_skips(self):
        for fields, reason in (({"labels": ["no-auto-merge"]}, "label that blocks auto-merge"),
                               ({"labels": ["agent-working"]}, "label that blocks auto-merge"),
                               ({"labels": ["documentation"]}, "labels changed"),
                               ({"headRefOid": "d" * 40}, "head changed"),
                               ({"mergeable": "CONFLICTING"}, "merge conflicts"),
                               ({"baseRefOid": "e" * 40}, "base changed")):
            with self.subTest(fields=fields):
                self.fresh_pr = {**self.pr, **fields}
                self.must.reset_mock()
                self.assertEqual(self.watcher.tick(None), 0)
                self.assert_no_merge_command()
                self.assertEqual(self.record()["outcome"], "skipped")
                self.assertIn(reason, self.record()["reason"])
                self.assertIsNone(self.watcher.load(7).gave_up_at)

    def test_failed_pr_reread_skips_without_merging(self):
        self.preflight_error = "HTTP 503"
        self.assert_skipped("the PR could not be re-read before merge")
        record = self.record()
        self.assertEqual(record["outcome"], "skipped")
        self.assertIn("HTTP 503", record["githubErrors"][0])

    def test_preflight_skip_allows_tick_to_consider_next_pr(self):
        self.fresh_pr["labels"] = ["no-auto-merge"]
        next_pr = {**self.pr, "number": 8, "labels": ["blocked"], "url": "https://example.invalid/pr/8"}
        self.watcher.prs.return_value = [self.pr, next_pr]
        with patch("qodo.pr_review", return_value=review()) as reviewed:
            self.assertEqual(self.watcher.tick(None), 0)
        # PR 8's skip label needs no review, so tick() does not read one for it.
        self.assertEqual([c.args[1] for c in reviewed.call_args_list], [self.pr["url"]])
        self.assert_no_merge_command()

    def test_unhanded_issue_pr_costs_no_review_lookup(self):
        issue_pr = {**self.pr, "number": 8, "headRefName": "agent/issue-11", "url": "https://example.invalid/pr/8"}
        self.watcher.prs.return_value = [issue_pr]
        with patch("qodo.pr_review", return_value=review()) as reviewed:
            self.assertEqual(self.watcher.tick(None), 0)
        reviewed.assert_not_called()
        self.assert_no_merge_command()

    def test_passed_reruns_replace_failed_ci_attempts(self):
        self.rerun = True
        self.assertEqual(self.watcher.tick(None), 0)
        record = self.record()
        self.assertEqual(record["outcome"], "merged")
        self.assertEqual([r["id"] for r in record["ci"]["workflows"]], [10])
        self.assertEqual([r["id"] for r in record["ci"]["checks"]], [11])

    def test_latest_failed_workflow_or_check_still_blocks(self):
        self.rerun = True
        for self.workflow_result, self.check_result in (("failure", "success"), ("success", "failure")):
            with self.subTest(workflow=self.workflow_result, check=self.check_result):
                self.assert_skipped("CI on the head is failure")

    def test_protected_paths_require_a_person_even_when_renamed(self):
        for path in (".github/workflows/check.yml", "tools/factory/watch_prs.py", "tools/ci/size_baseline.json",
                     ".qodo/config.toml", "gdext/godot-cpp", "gdext/rebuild.sh"):
            with self.subTest(path=path):
                self.files = [{"filename": "a.txt", "status": "renamed", "previous_filename": path}]
                self.assert_skipped("a person merges this PR")

    def test_native_changes_require_both_libraries(self):
        libs = self.watcher.cfg["paths"]["nativeLibraries"]
        self.files = [{"filename": "gdext/src/world.cpp", "status": "modified"},
                      {"filename": libs[0], "status": "modified"}]
        self.pr["changedFiles"] = self.fresh_pr["changedFiles"] = 2
        self.assert_skipped("C++ changed but the macOS libraries were not rebuilt")
        self.pr["changedFiles"] = self.fresh_pr["changedFiles"] = 3
        self.files.append({"filename": libs[1], "status": "removed"})
        self.assert_skipped("C++ changed but the macOS libraries were not rebuilt")
        self.files[-1]["status"] = "modified"
        self.assertEqual(self.watcher.tick(None), 0)
        self.assertEqual(self.record()["outcome"], "merged")

    def test_failed_or_incomplete_changed_files_query_skips(self):
        self.fail_files = True
        self.assert_skipped("changed files could not be read")
        self.fail_files = False
        self.files.clear()
        self.assert_skipped("changed files could not be read")

    def test_ci_query_error_labels_pr_without_attempting_merge(self):
        self.fail_checks = True
        self.assertEqual(self.watcher.tick(None), 1)
        self.assert_no_merge_command()
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
        self.assert_no_merge_command()
        self.assertEqual(self.cli.call_count, 2)
        self.assertTrue(all(c.args[0][1] == "api" for c in self.cli.call_args_list))
        self.assertFalse((self.home / "runs").exists())

    def assert_stopped(self, error):
        record = self.record()
        self.assertEqual(record["outcome"], "stopped")
        self.assertIn(error, record["error"])
        self.assertEqual(self.watcher.load(7).gave_up_at, HEAD)
        self.assert_help_label_added()

    def assert_help_label_added(self):
        self.assertIn(call(["gh", "api", "repos/hrhgit/Project.Keynes/issues/7/labels", "--method", "POST",
                            "--input", "-"], stdin='{"labels": ["agent-needs-help"]}'), self.cli.call_args_list)

    def assert_no_merge_command(self):
        self.assertFalse(any(c.args[0][1:3] == ["pr", "merge"] for c in self.must.call_args_list))

    def assert_skipped(self, reason):
        with patch("builtins.print") as output:
            self.assertEqual(self.watcher.tick(None), 0)
        self.assert_no_merge_command()
        decision = json.loads(output.call_args.args[0])
        self.assertEqual(decision["action"], "skip")
        self.assertIn(reason, decision["reason"])


class LabelAPI(unittest.TestCase):
    def test_relabel_uses_rest_and_ignores_delete_404(self):
        gh = GitHub("example/repo")
        missing = Result(1, "HTTP/2.0 404 Not Found\n", "gh: Not Found (HTTP 404)")
        with patch("github.sh", side_effect=[Result(0, "[]", ""), missing]) as cli:
            self.assertIsNone(gh.relabel(7, ["agent-needs-help", "second label"], ["work/queued #1"]))
        self.assertEqual(cli.call_args_list, [
            call(["gh", "api", "repos/example/repo/issues/7/labels", "--method", "POST", "--input", "-"],
                 stdin='{"labels": ["agent-needs-help", "second label"]}'),
            call(["gh", "api", "repos/example/repo/issues/7/labels/work%2Fqueued%20%231", "--method", "DELETE",
                  "--include", "--silent"]),
        ])
        self.assertEqual(gh.errors, [])

    def test_label_delete_errors_other_than_404_are_recorded(self):
        gh = GitHub("example/repo")
        with patch("github.sh", return_value=Result(1, "HTTP/2.0 403 Forbidden\n", "gh: Forbidden (HTTP 403)")):
            error = gh.relabel(7, [], ["agent-working"])
        self.assertIn("HTTP 403", error)
        self.assertEqual(gh.errors, [error])


if __name__ == "__main__":
    unittest.main()
