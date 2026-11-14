#!/usr/bin/env python3
"""Repeat and refactor checks must reject broken or incomplete evidence."""
import argparse
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_golden_determinism import candidate_path, difference, load_comparison, read_result
from check_intent_baselines import read_evidence
from run_regression_checks import EXPECTED_ERRORS, fixture_errors


class EvidenceTests(unittest.TestCase):
    def test_candidate_requires_absolute_external_path(self):
        from run_regression_checks import ROOT
        with self.assertRaises(argparse.ArgumentTypeError):
            candidate_path("relative.json")
        with self.assertRaises(argparse.ArgumentTypeError):
            candidate_path(str(ROOT / "candidate.json"))
        with tempfile.TemporaryDirectory() as directory:
            outside = Path(directory).resolve()
            self.assertEqual(candidate_path(str(outside / "candidate.json")), outside / "candidate.json")
            (outside / "alias").symlink_to(ROOT, target_is_directory=True)
            with self.assertRaises(argparse.ArgumentTypeError):
                candidate_path(str(outside / "alias/candidate.json"))

    def test_missing_or_malformed_comparison_is_rejected_before_running(self):
        parser = argparse.ArgumentParser()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidate.json"
            for content in (None, "{", "[]", "{}", "null"):
                if content is not None:
                    path.write_text(content)
                with self.subTest(content=content), patch("sys.stderr"), self.assertRaises(SystemExit):
                    load_comparison(parser, path)

    def test_first_difference_identifies_day_domain_and_field(self):
        expected = {"days": [{"day": 1, "domain_hashes": {"COUNTRY": {"hash": "abc"}}}]}
        actual = {"days": [{"day": 1, "domain_hashes": {"COUNTRY": {"hash": "abd"}}}]}
        self.assertEqual(difference(expected, actual), {
            "path": "result.days[0].domain_hashes.COUNTRY.hash", "expected": "abc", "actual": "abd"})

    def test_golden_result_rejects_failed_missing_duplicate_and_malformed_evidence(self):
        for lines, code in [([], 0), (["GOLDEN_RESULT={}"], 0),
                            (["GOLDEN_RESULT={"], 0),
                            (["GOLDEN_RESULT={\"days\": []}"] * 2, 0),
                            (["GOLDEN_RESULT={\"days\": []}", "[FAIL] invariant"], 0),
                            (["GOLDEN_RESULT={\"days\": []}"], 1)]:
            with self.subTest(lines=lines, code=code):
                self.assertTrue(read_result(lines, "GOLDEN_RESULT=", code)[1])

    def test_declared_negative_builder_diagnostic(self):
        name = "ideology_effect_override_test"
        diagnostic = EXPECTED_ERRORS[name][0]
        self.assertEqual(fixture_errors(name, [diagnostic]), [])
        self.assertTrue(fixture_errors("another_fixture", [diagnostic]))

    def test_declared_diagnostic_must_occur_exactly_once(self):
        name = "ideology_effect_override_test"
        diagnostic = EXPECTED_ERRORS[name][0]
        self.assertTrue(fixture_errors(name, []))
        self.assertTrue(fixture_errors(name, [diagnostic, diagnostic]))

    def test_declared_diagnostic_does_not_hide_other_failures(self):
        name = "ideology_effect_override_test"
        diagnostic = EXPECTED_ERRORS[name][0]
        for error in ["SCRIPT ERROR: aborted", "ERROR: unexpected", "[FAIL] assertion",
                      "WARNING: ObjectDB instances leaked at exit"]:
            with self.subTest(error=error):
                self.assertTrue(fixture_errors(name, [diagnostic, error]))

    def test_complete_result(self):
        self.assertEqual(read_evidence(['RESULT={"cash": 12}'], "RESULT=", 0),
                         ({"cash": 12}, []))

    def test_assertion_failure_despite_zero_exit(self):
        _, errors = read_evidence(['RESULT={"cash": 12}', "[FAIL] ledger"], "RESULT=", 0)
        self.assertTrue(errors)

    def test_script_error_and_leak(self):
        for message in ["SCRIPT ERROR: failed", "ERROR: failed",
                        "WARNING: ObjectDB instances leaked at exit"]:
            with self.subTest(message=message):
                _, errors = read_evidence(['RESULT={"cash": 12}', message], "RESULT=", 0)
                self.assertTrue(errors)

    def test_missing_or_duplicate_result(self):
        for lines in [[], ['RESULT={"cash": 12}', 'RESULT={"cash": 12}']]:
            self.assertIsNone(read_evidence(lines, "RESULT=", 0)[0])

    def test_bad_json_empty_or_failed_process(self):
        for payload in ["{", "{}", "[]", "null"]:
            self.assertTrue(read_evidence(["RESULT=" + payload], "RESULT=", 0)[1])
        self.assertTrue(read_evidence(['RESULT={"cash": 12}'], "RESULT=", 1)[1])

    def test_receipts_and_every_saved_byte_digest_are_compared(self):
        expected = dict(receipts=[dict(quantity=2, cash=8)], country_sha256="abc",
                        economy_sha256="def", restored_economy_sha256="ghi")
        for field in expected:
            changed = expected | {field: [] if field == "receipts" else "changed"}
            with self.subTest(field=field):
                self.assertIsNotNone(difference(expected, changed))


if __name__ == "__main__":
    unittest.main()
