import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from forecast import ROOT, read_json
from work import compare, evaluate_proof, project_inputs, read_profile, trace, validate_trace
from work_scan import scan_source, dot, observed_dot

CAT = ROOT / "examples/catalog-work"
GD = ROOT / "examples"
LEAN = os.getenv("PERF_FORECAST_LEAN") or shutil.which("lean")
KEYNES = Path(os.getenv("PERF_FORECAST_KEYNES") or ROOT.parents[2])
GAME_SCRIPTS = KEYNES / "Project/project-keynes/scripts"
try:
    import gdtoolkit
    HAVE_GD = shutil.which("godot") is not None
except ImportError:
    HAVE_GD = False


class GeneralWorkTests(unittest.TestCase):
    def catalog(self, side, proof=None):
        return trace(CAT / (side + ".json"), read_json(CAT / "input.json"), None, proof)

    def test_catalog_pair(self):
        result = compare(self.catalog("before"), self.catalog("after"))
        self.assertEqual(result["outputs"], "match")
        self.assertEqual(result["observed_work"], "decreased")
        self.assertEqual(result["delta_after_minus_before"], {"catalog_read": -8, "lookup": 0})
        self.assertTrue(result["before"]["steps"][0]["path"])

    def test_source_only_matches_real_execution(self):
        for side in ("before", "after"):
            profile = CAT / (side + ".json")
            scenario = {"steps": [{"prices": [3, 7, 8], "orders": orders}
                                  for orders in ([], [0], [2, 1, 1, 0])]}
            model = trace(profile, scenario, None, None, source_only=True)
            actual = trace(profile, scenario, None, None)
            self.assertEqual([(s["output"], s["counts"]) for s in model["steps"]],
                             [(s["output"], s["counts"]) for s in actual["steps"]])

    def test_source_only_reports_unknowns(self):
        from work_static import Counter
        opts = {"entry": "target", "observe": {"enters": {"function": "target"}}}
        for src in ("import physics\ndef target(x): return x",
                    "def target(x): return opaque(x)",
                    "def target(x):\n if x: yield x\n return 3",
                    "def target(x):\n return len(x)\n len = 1"):
            with self.subTest(src=src), self.assertRaisesRegex(ValueError, "unresolved at line"):
                Counter(src, opts).record([{"x": [1]}])

    def test_source_only_matches_python_boolean_augmented_assignment(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "target.py").write_text("def target(x):\n    x += 1\n    return x\n")
            profile = folder / "profile.json"
            profile.write_text(json.dumps({
                "adapter": "python",
                "source": "target.py",
                "metrics": {"entries": "Target function entries"},
                "options": {"entry": "target", "observe": {"entries": {"function": "target"}}},
            }))
            scenario = {"steps": [{"x": True}, {"x": False}]}
            static = trace(profile, scenario, None, None, source_only=True)
            actual = trace(profile, scenario, None, None)
            result = compare(actual, static)
            self.assertEqual(result["outputs"], "match")
            self.assertEqual(result["observed_work"], "unchanged")

    def test_source_only_ignores_unreached_opaque_call(self):
        from work_static import Counter
        opts = {"entry": "target", "observe": {"enters": {"function": "target"}}}
        c = Counter("def target(x):\n if x: return opaque(x)\n return 7", opts)
        self.assertEqual(c.record([{"x": 0}])["steps"][0]["output"], 7)

    def test_refuse_incompatible_comparison(self):
        a, b = self.catalog("before"), self.catalog("after")
        b["metrics"]["lookup"] = "unrelated"
        with self.assertRaises(ValueError):
            compare(a, b)
        b["metrics"] = a["metrics"]
        b["scenario_sha256"] = "other"
        with self.assertRaises(ValueError):
            compare(a, b)

    def test_output_difference_and_missing_evidence(self):
        a, b = self.catalog("before"), self.catalog("after")
        b["steps"][0]["output"] += 1
        del b["steps"][1]["output"]
        report = compare(a, b)
        self.assertEqual(report["outputs"], "differ")
        self.assertEqual(report["mismatched_steps"], [0])
        self.assertEqual(report["missing_outputs"], [1])

    def test_refuse_bad_trace(self):
        for steps in ([], [{"counts": {}, "path": []}], [{"counts": {"n": -1}, "path": []}],
                      [{"counts": {"n": True}, "path": []}], [{"counts": {"n": 1}, "path": 0}]):
            with self.subTest(steps=steps), self.assertRaises(ValueError):
                validate_trace({"steps": steps, "locations": {"n": 2}}, [{}], {"n": "operations"})

    def test_observed_graph_preserves_loop_and_step_boundaries(self):
        report = {"locations": {"visit": 12}, "steps": [
            {"path": ["visit", "visit"]}, {"path": []}]}
        graph = observed_dot(report)
        self.assertIn('n2 -> n2 [label="1"]', graph)
        self.assertIn('n0 -> n1 [label="1"]', graph)
        self.assertNotIn("visit", observed_dot(report, 1))
        with self.assertRaises(ValueError):
            observed_dot(report, -1)

    def test_projection(self):
        fields = [{"key": "x", "as": "optional_symbol"}]
        self.assertEqual(project_inputs(fields, [{}, {"x": 1}, {"x": 1.0}, {"x": True}, {}]),
                         [[0], [1], [1], [2], [0]])
        with self.assertRaises(ValueError):
            project_inputs([{"key": "x", "as": "int"}], [{"x": False}])

    def test_trace_refuses_unmatched_probe(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "profile.json"
            profile = read_json(CAT / "before.json")
            profile["options"]["observe"]["lookup"]["statement"] = "missing()"
            p.write_text(json.dumps(profile))
            with self.assertRaisesRegex(ValueError, "missing or ambiguous"):
                trace(p, {"steps": []}, CAT / "before.py", None)

    def test_python_scan(self):
        g = scan_source(CAT / "before.py", "quote")
        fn, = g["functions"]
        self.assertTrue(any(a > b and label == "jump" for a, b, label in fn["edges"]))
        self.assertIn("digraph", dot(g))
        with self.assertRaises(ValueError):
            scan_source(CAT / "before.py", "missing")
        with self.assertRaises(ValueError):
            scan_source(CAT / "before.json")

    def test_python_scan_honors_declared_source_encoding(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "encoded.py"
            path.write_bytes("# coding: latin-1\ndef measure():\n    return len('café')\n".encode("latin-1"))
            report = scan_source(path, "measure")
        function, = report["functions"]
        self.assertEqual(function["name"], "measure")
        self.assertEqual(report["file_call_sites"], [{"line": 3, "target": "len"}])

    @unittest.skipUnless(shutil.which("clang++"), "clang++ needed")
    def test_clang_scan(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "sample.cpp"
            p.write_text("int choose(bool b) { if (b) return 2; return 1; }")
            fn, = scan_source(p)["functions"]
            self.assertIn("choose", fn["name"])
            self.assertTrue(any(sum(e[0] == n["id"] for e in fn["edges"]) == 2 for n in fn["nodes"]))

    @unittest.skipUnless(LEAN, "Lean executable needed")
    def test_model_and_wrong_trace(self):
        report = self.catalog("after", LEAN)
        self.assertTrue(report["proof"]["matched_trace"])
        request = read_json(CAT / "input.json")
        profile = read_profile(CAT / "after.json")
        prediction = evaluate_proof(LEAN, profile, CAT, request["steps"])
        self.assertEqual(prediction["totals"], report["totals"])
        report["steps"][0]["counts"]["lookup"] += 1
        with self.assertRaises(ValueError):
            evaluate_proof(LEAN, profile, CAT, request["steps"], report)

    @unittest.skipUnless(HAVE_GD and GAME_SCRIPTS.is_dir(), "Keynes sources, Godot and gdtoolkit needed")
    def test_real_sunlight(self):
        source = GAME_SCRIPTS / "simulation/climate/climate_math.gd"
        g = scan_source(source, "compute_annual_insolation_mean")
        self.assertIn("iterate", [k for a,b,k in g["functions"][0]["edges"]])
        r = trace(GD / "sunlight-profile.json", read_json(GD / "sunlight-steps.json"), source, None)
        self.assertEqual([s["counts"]["polar_night"] for s in r["steps"]], [0, 8, 0])
        self.assertEqual([s["counts"]["sample"] for s in r["steps"]], [16, 16, 1])

    @unittest.skipUnless(shutil.which("godot") and GAME_SCRIPTS.is_dir() and LEAN,
                         "Keynes sources, Godot and Lean needed")
    def test_real_cache(self):
        source = GAME_SCRIPTS / "rendering/land_base_cache.gd"
        r = trace(GD / "keynes-profile.json", read_json(GD / "keynes-steps.json"), source, LEAN)
        self.assertEqual(r["totals"]["request_texture_update"], 6)
        self.assertEqual(r["proof"]["totals"]["build_completed"], 3)

    def test_cli_accepts_stdin_and_rejects_wrong_request(self):
        cmd = [sys.executable, str(ROOT / "work.py"), "trace", str(CAT / "before.json"), "-"]
        ok = subprocess.run(cmd, input='{"steps":[]}', text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(ok.stdout)["totals"], {"lookup": 0, "catalog_read": 0})
        bad = subprocess.run(cmd, input='{"stpes":[]}', text=True, capture_output=True)
        self.assertEqual((bad.returncode, bad.stdout), (2, ""))


if __name__ == "__main__":
    unittest.main()
