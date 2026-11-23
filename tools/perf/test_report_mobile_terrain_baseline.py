import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from report_mobile_terrain_baseline import build_report, read_captures


def timing(mean, samples=240):
    return {"samples": samples, "mean": mean, "median": mean, "p95": mean}


def baseline_fixture():
    captures, traces = [], []
    for scene in ("opening", "explored"):
        for scale in (100, 75):
            for layer in ("land", "water", "vegetation"):
                # Exercise both orders of the full/omitted pair.
                layers = (layer, "") if layer == "water" else ("", layer)
                for omitted in layers:
                    identity = {
                        "process_id": 100 + len(captures),
                        "start_unix_s": 10 * len(captures) + 1,
                        "end_unix_s": 10 * len(captures) + 5,
                    }
                    capture = {
                        **identity, "ok": True, "fixed_view": True, "sizes_ok": True,
                        "scene": scene, "scale_percent": scale, "omitted_layer": omitted,
                        "day": 0 if scene == "opening" else 2, "speed": 1.0,
                        "camera_center": [200, 300], "camera_zoom": 0.5,
                        "godot": "4.6.3", "os": "macOS", "driver": "metal", "adapter": "M2",
                        "engine_max_fps": 0, "vsync_mode": 0, "display_refresh_hz": 60,
                        "window_px": [1600, 960], "vegetation_px": [1600, 960],
                        "fog_px": [800, 480],
                        "land_water_px": [1200, 720] if scale == 75 else [1600, 960],
                        "frame_interval_ms": timing(16),
                        "window_draw_cpu_ms": timing(3 if omitted else 4),
                        "window_draw_gpu_ms": timing(None, samples=0),
                    }
                    if scale == 75:
                        capture["terrain_draw_cpu_ms"] = timing(2 if omitted else 5)
                    captures.append(capture)
                    traces.append({
                        **identity, "source": "fixture.trace",
                        "gpu_work_ms": timing(6 if omitted else 8),
                        "present_wait_ms": timing(0 if omitted else 1),
                        "present_interval_ms": timing(17),
                    })
    return captures, traces


class MobileTerrainBaselineTest(unittest.TestCase):
    def test_reports_layer_work_separately_from_present_wait(self):
        captures, traces = baseline_fixture()
        report = build_report(captures, traces)
        self.assertEqual(len(report), 12)
        for row in report:
            with self.subTest(scene=row["scene"], scale=row["scale_percent"], layer=row["layer"]):
                uses_terrain = row["scale_percent"] == 75 and row["layer"] != "vegetation"
                self.assertEqual(row["draw_cpu_viewport"], "terrain" if uses_terrain else "window")
                self.assertEqual(row["full_minus_omitted_mean_ms"], {
                    "draw_cpu": 3 if uses_terrain else 1, "gpu_work": 2, "present_wait": 1,
                })
                self.assertEqual(abs(row["full"]["capture"]["start_unix_s"]
                                     - row["omitted"]["capture"]["start_unix_s"]), 10)
                self.assertEqual(row["full"]["capture"]["frame_interval_ms"]["p95"], 16)
                self.assertEqual(row["omitted"]["trace"]["present_wait_ms"]["samples"], 240)
                self.assertEqual(row["omitted"]["trace"]["present_interval_ms"]["p95"], 17)

    def test_refuses_missing_or_unmatched_system_trace(self):
        # Godot reports a successful draw capture even when its Metal GPU timer
        # returns no values. That capture alone must not pass baseline acceptance.
        captures, traces = baseline_fixture()
        with self.assertRaisesRegex(ValueError, "matching system trace"):
            build_report(captures, [])
        traces[0]["end_unix_s"] += 1
        with self.assertRaisesRegex(ValueError, "matching system trace"):
            build_report(captures, traces)

    def test_can_compare_each_layer_with_one_full_capture_per_scene_and_scale(self):
        captures, traces = baseline_fixture()
        # Keep the opening full capture for each scene and scale, plus all omissions.
        indices = [i for i, capture in enumerate(captures) if i % 6 == 0 or capture["omitted_layer"]]
        report = build_report([captures[i] for i in indices], [traces[i] for i in indices])
        self.assertEqual(len(report), 12)
        for row in report:
            self.assertEqual((row["full"]["capture"]["process_id"] - 100) % 6, 0)

    def test_refuses_missing_or_invalid_timings(self):
        for name, value in (
            ("present_wait_ms", timing(None, samples=0)),
            ("gpu_work_ms", timing(0)),
            ("present_interval_ms", timing(float("nan"))),
        ):
            with self.subTest(metric=name):
                captures, traces = baseline_fixture()
                traces[0][name] = value
                with self.assertRaisesRegex(ValueError, name):
                    build_report(captures, traces)
        captures, traces = baseline_fixture()
        captures[0]["window_draw_cpu_ms"] = timing(3, samples=0)
        with self.assertRaisesRegex(ValueError, "window_draw_cpu_ms"):
            build_report(captures, traces)

    def test_refuses_missing_layer_or_changed_capture_conditions(self):
        captures, traces = baseline_fixture()
        with self.assertRaisesRegex(ValueError, "vegetation"):
            build_report(captures[:-2], traces[:-2])
        captures[1]["camera_zoom"] = 0.75
        with self.assertRaisesRegex(ValueError, "camera_zoom"):
            build_report(captures, traces)
        captures[1]["camera_zoom"] = 0.5
        captures[1]["land_water_px"] = [0, 0]
        with self.assertRaisesRegex(ValueError, "land_water_px"):
            build_report(captures, traces)

    def test_refuses_historical_frame_interval_without_draw_captures(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "window.log"
            path.write_text("Average FPS: 60.0. Frame interval P95: 19.70 ms.\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "no windowed draw captures"):
                read_captures([path])
            capture = baseline_fixture()[0][0]
            with path.open("a", encoding="utf-8") as handle:
                handle.write("[mobile-terrain-draw] " + json.dumps(capture) + "\n")
            self.assertEqual(read_captures([path]), [capture])

    def test_refuses_non_object_draw_record(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "window.log"
            path.write_text("[mobile-terrain-draw] []\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "invalid windowed draw record"):
                read_captures([path])


if __name__ == "__main__":
    unittest.main()
