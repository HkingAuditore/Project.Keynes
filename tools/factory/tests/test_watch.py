import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from watch_prs import PrState, decide  # noqa: E402

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


if __name__ == "__main__":
    unittest.main()
