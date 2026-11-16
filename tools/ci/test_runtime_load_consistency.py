"""Reject incomplete load coverage and differences hidden by equal final state."""
import copy
import json
import unittest

from check_runtime_load_consistency import (DAILY_DAYS, COMMAND_DAYS, EXPECTED_DOMAINS,
    command_coverage, compare, daily_coverage, pressure_errors)
from check_golden_determinism import read_result


def domains(day):
    return {name: {"hash": "123", "state_day": day, "scope": "whole"} for name in EXPECTED_DOMAINS}


def daily():
    rows = [{"day": day, "domain_hashes": domains(day), "whole_economy_hash": "123",
             "values": [day, 0, 160, 0, 0, 0, 100, 20, 10, 3, 1000, [3], [4]]}
            for day in range(1, DAILY_DAYS + 1)]
    lines = ["LOAD_CONSISTENCY_SETUP=" + json.dumps({"cadence": "production", "seed": 20260727, "days": DAILY_DAYS}),
             'GOLDEN_BOOTSTRAP={"resource_columns": [1]}']
    lines += ["GOLDEN_DIAGNOSTIC=" + json.dumps({"day": day, "whole_economy_hash": "123"})
              for day in range(1, DAILY_DAYS + 1)]
    return {"days": rows}, lines


def command_result():
    return {"commands": [{"day": d, "operation": "military_target", "value": d + 1} for d in range(1, COMMAND_DAYS + 1)],
            "rows": [{"day": d, "domains": domains(d), "gm_receipt": {"ok": True, "effective_day": d + 2},
                      "country_name": f"Replay day {d-2}" if d >= 3 else "Committed View Replay",
                      "military": {"target_value": d + 1}, "whole_economy_hash": "123", "resources": "456"}
                     for d in range(1, COMMAND_DAYS + 1)]}


class LoadEvidenceTests(unittest.TestCase):
    def test_full_daily_and_command_evidence_is_accepted(self):
        self.assertEqual(daily_coverage(*daily()), [])
        self.assertEqual(command_coverage(command_result(), range(1, COMMAND_DAYS + 1)), [])

    def test_missing_day_domain_raw_values_and_real_cadence_rejected(self):
        for field in ("day", "domain", "raw", "ledger", "cadence", "diagnostics"):
            payload, lines = daily()
            if field == "day": payload["days"].pop(3)
            if field == "domain": payload["days"][3]["domain_hashes"].pop("ECONOMY")
            if field == "raw": payload["days"][3]["values"] = []
            if field == "ledger": payload["days"][3]["values"][3] = 1
            if field == "cadence": lines[0] = lines[0].replace("production", "injected")
            if field == "diagnostics": lines.pop()
            with self.subTest(field=field):
                self.assertTrue(daily_coverage(payload, lines))

    def test_equal_final_state_does_not_hide_intermediate_difference(self):
        reference, _ = daily()
        actual = copy.deepcopy(reference)
        actual["days"][3]["domain_hashes"]["ECONOMY"]["hash"] = "456"
        self.assertEqual(actual["days"][-1], reference["days"][-1])
        self.assertEqual(compare(reference, actual)["path"], "result.days[3].domain_hashes.ECONOMY.hash")

    def test_command_receipts_and_actual_effective_days_are_checked(self):
        for field in ("commands", "gm_receipt", "country_name", "military", "resources"):
            actual = command_result()
            if field == "commands": actual[field] = []
            else: actual["rows"][3].pop(field)
            with self.subTest(field=field):
                self.assertTrue(command_coverage(actual, range(1, COMMAND_DAYS + 1)))

    def test_resume_compares_pending_commands_and_all_continued_days(self):
        reference = command_result()
        actual = copy.deepcopy(reference)
        actual["rows"] = actual["rows"][5:]
        self.assertIsNone(compare(reference, actual, resume=True))
        actual["rows"][0]["country_name"] = "late"
        self.assertIsNotNone(compare(reference, actual, resume=True))
        actual = copy.deepcopy(reference)
        actual["rows"] = actual["rows"][6:]
        self.assertTrue(command_coverage(actual, range(6, COMMAND_DAYS + 1)))

    def test_pressure_requires_work_inside_the_full_game_lifetime(self):
        worker = {"pid": 1, "exit": 0, "samples": [
            {"kind": k, "monotonic": t, "cpu_seconds": cpu, "iterations": work}
            for k, t, cpu, work in [("ready", 1, 0, 0), ("working", 3, 1, 10),
                                    ("working", 5, 2, 20), ("finished", 7, 3, 30)]]}
        self.assertEqual(pressure_errors([worker], 2, 6, 1), [])
        for mutation in ("count", "late_start", "early_stop", "no_work", "exit", "no_samples"):
            changed = copy.deepcopy(worker)
            if mutation == "late_start": changed["samples"][0]["monotonic"] = 2.5
            if mutation == "early_stop": changed["samples"][-1]["monotonic"] = 5.5
            if mutation == "no_work": changed["samples"][2]["cpu_seconds"] = 1
            if mutation == "exit": changed["exit"] = 1
            if mutation == "no_samples": changed["samples"] = []
            with self.subTest(mutation=mutation):
                self.assertTrue(pressure_errors([changed], 2, 6, 2 if mutation == "count" else 1))

    def test_errors_and_leaks_fail_even_with_complete_payload_and_exit_zero(self):
        for message in ("SCRIPT ERROR: failed", "ERROR: failed", "[FAIL] ledger",
                        "WARNING: ObjectDB instances leaked at exit"):
            lines = ["GOLDEN_RESULT=" + json.dumps(daily()[0]), message]
            with self.subTest(message=message):
                self.assertTrue(read_result(lines, "GOLDEN_RESULT=", 0)[1])


if __name__ == "__main__":
    unittest.main()
