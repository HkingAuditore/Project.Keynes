"""The saved quality gate (docs/factory/quality-gate.md) and the verdict code must agree.

The page says which Qodo action levels block and which are only reported. This test reads the page's
severity table and checks it against verdict.BLOCKING and judge(), including inputs the gate must refuse.
"""

import re
import sys
import unittest
from pathlib import Path

FACTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FACTORY))

from verdict import BLOCKING, Facts, judge  # noqa: E402

PAGE = FACTORY.parents[1] / "docs" / "factory" / "quality-gate.md"
HEAD = "abc123"
ROW = re.compile(r"^\| (High|Medium|Low) \| (\w+) \| (blocks|reported) \|", re.M)


def facts(**kw) -> Facts:
    base = dict(head=HEAD, checks_sha=HEAD, review_status="completed", review_sha=HEAD,
                ci_state="success", findings=[])
    base.update(kw)
    return Facts(**base)


def finding(level, status="pending"):
    return {"id": level, "attribution_status": status, "action_level": level, "title": f"t-{level}"}


class QualityGateTest(unittest.TestCase):
    def rows(self):
        rows = ROW.findall(PAGE.read_text(encoding="utf-8"))
        self.assertEqual([r[0] for r in rows], ["High", "Medium", "Low"], "the page must list High, Medium, Low once each")
        return rows

    def test_page_and_code_name_the_same_blocking_levels(self):
        blocks = {level for _, level, gate in self.rows() if gate == "blocks"}
        self.assertEqual(blocks, set(BLOCKING))

    def test_every_blocking_level_stops_a_done_report(self):
        for _, level, gate in self.rows():
            with self.subTest(level=level):
                v = judge(facts(findings=[finding(level)]))
                if gate == "blocks":
                    self.assertEqual(v.verdict, "NEEDS_FIX")
                else:
                    self.assertEqual(v.verdict, "READY")

    def test_low_is_reported_to_a_person_not_dropped(self):
        low = next(level for _, level, gate in self.rows() if gate == "reported")
        v = judge(facts(findings=[finding(low)]))
        self.assertEqual(v.verdict, "READY")
        self.assertEqual(len(v.for_human), 1)
        self.assertIn(f"t-{low}", v.for_human[0])

    def test_a_settled_blocking_finding_does_not_block(self):
        for status in ("implemented", "dismissed"):
            with self.subTest(status=status):
                self.assertEqual(judge(facts(findings=[finding("action_required", status)])).verdict, "READY")

    def test_refuses_done_without_a_review_of_the_head(self):
        for name, kw in (("older commit", dict(review_sha="old")), ("still running", dict(review_status="started")),
                         ("skipped", dict(review_status="skipped")), ("failed", dict(review_status="failed")),
                         ("none", dict(review_status=None, review_sha=None))):
            with self.subTest(review=name):
                self.assertEqual(judge(facts(**kw)).verdict, "NOT_DONE")

    def test_refuses_done_when_checks_did_not_run_on_the_head(self):
        self.assertEqual(judge(facts(checks_sha="old")).verdict, "NOT_DONE")

    def test_unknown_level_goes_to_a_person_and_is_never_ready(self):
        for level in ("urgent", "", None):
            with self.subTest(level=level):
                self.assertEqual(judge(facts(findings=[finding(level)])).verdict, "NEEDS_HUMAN")

    def test_a_stalled_loop_stops_instead_of_reporting_done(self):
        v = judge(facts(findings=[finding("action_required")], review_stalled=True))
        self.assertEqual(v.verdict, "NEEDS_HUMAN")
        v = judge(facts(findings=[finding("remediation_recommended")], review_rounds=3))
        self.assertEqual(v.verdict, "NEEDS_HUMAN")


if __name__ == "__main__":
    unittest.main()
