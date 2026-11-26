from math import ulp
import unittest

from forecast import ROOT, predict, read_json


def example(name):
    return read_json(ROOT / "examples" / (name + ".json"))


class ForecastTests(unittest.TestCase):
    def test_cache_rebuild_then_reuse(self):
        result = predict(example("land"))
        rows = result["scenarios"]
        self.assertEqual([r["trend"] for r in rows],
                         ["equal", "worse", "worse", "equal", "better", "better"])
        self.assertEqual([r["first_profitable_stable_frames"] for r in rows], [7] * 6)
        self.assertEqual(result["decision_sensitive_inputs"], ["stable_frames"])

    def test_cache_never_pays_when_more_expensive_to_read(self):
        request = example("land")
        request["inputs"]["read_ms"] = 7
        self.assertIsNone(predict(request)["scenarios"][0]["first_profitable_stable_frames"])

    def test_upper_bound_does_not_promise_actual_performance(self):
        request = example("calendar")
        for target, verdict in [(24, "not_ruled_out"), (100, "ruled_out")]:
            request["target"] = target
            for row in predict(request)["scenarios"]:
                self.assertEqual(row["after"], 24)
                self.assertEqual(row["target"], verdict)

    def test_memory_estimate(self):
        result = predict(example("demand-memory"))
        self.assertAlmostEqual(result["scenarios"][0]["improvement"], 93.545, places=2)

    def test_small_changes_are_kept_in_the_gain_range(self):
        delta = ulp(1.0)
        result = predict({
            "model": {
                "metric": "work", "kind": "estimate", "better": "lower",
                "parameters": {"baseline": "positive", "delta": "number"},
                "before": "baseline", "after": "baseline - delta",
            },
            "inputs": {"baseline": 1.0, "delta": [0, delta, -delta]},
        })
        self.assertEqual([row["trend"] for row in result["scenarios"]],
                         ["equal", "better", "worse"])
        self.assertEqual(result["improvement_range"], [-delta, delta])
        self.assertEqual(result["decision_sensitive_inputs"], ["delta"])

    def test_shared_inputs_and_sensitivity(self):
        request = example("catalog")
        request["inputs"]["common_ms"] = [0, 1]
        result = predict(request)
        self.assertEqual(len(result["scenarios"]), 6)
        self.assertEqual(result["decision_sensitive_inputs"], ["uses"])

    def test_formula_rejections(self):
        for formula in ["foo", "open('a')", "inputs.__class__", "2 ** 8", "1 / 0"]:
            with self.subTest(formula=formula), self.assertRaises((ValueError, ZeroDivisionError)):
                request = example("demand-memory")
                request["model"]["after"] = formula
                predict(request)

    def test_invalid_inputs(self):
        for value in [0, -1, 0.5, True, [], "4", float("inf")]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                request = example("land")
                request["inputs"]["stable_frames"] = value
                predict(request)

    def test_missing_and_unknown_parameters(self):
        for key in ["missing", "extra"]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                request = example("land")
                if key == "missing":
                    del request["inputs"]["read_ms"]
                else:
                    request["inputs"]["reed_ms"] = 1
                predict(request)


if __name__ == "__main__":
    unittest.main()
