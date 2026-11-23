import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest

from report import HERE, PROTOCOL, compare, load_capture


class CoastCaptureTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.folder = Path(tmp.name)
        (self.folder / "outcome.txt").write_text("23 checks, 0 failures")
        self.records = []
        for i in range(4):
            r = dict(protocol=PROTOCOL, platform="Android", model="test", build="release",
                     scene="explored-coast", driver="vulkan", adapter="test", arm=i,
                     process_id=12, godot="4.6.3", start_unix_s=5*i, end_unix_s=5*i+4,
                     scale_percent=100, camera_zoom=1.75, day=3, ok=True,
                     omitted_layer="water" if i % 2 else "", refresh_hz=60, vsync=1,
                     engine_max_fps=0, window_px=[1600, 960], screen_px=[1600, 960],
                     explored_land_water_fractions=[[.4, .4]]*5, draw_calls={"samples": 240},
                     raw_frame_interval_ms=[16.67]*240,
                     camera_centers=[[1059.36376953125 + j*320/240, 924] for j in range(1,241)])
            self.records.append(r)
            (self.folder / f"coast-{i}.png").write_bytes(
                b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + struct.pack(">II", *r["window_px"]))
            self.write_arm(i)

    def write_arm(self, i):
        (self.folder / f"coast-{i}.json").write_text(json.dumps(self.records[i]))

    def test_common_route_accepts_another_platform(self):
        self.assertEqual(load_capture(self.folder)[1]["driver"], "vulkan")

    def test_matching_drift_across_all_arms_is_still_wrong(self):
        for i, r in enumerate(self.records):
            r["camera_centers"][120][0] += 1
            self.write_arm(i)
        with self.assertRaisesRegex(ValueError, "route mismatch"):
            load_capture(self.folder)

    def test_unrelated_failed_run_cannot_use_historical_exception(self):
        (self.folder / "outcome.txt").write_text("29 checks, 2 failures")
        with self.assertRaisesRegex(ValueError, "not the archived"):
            load_capture(self.folder)

    def test_device_baseline_comparison(self):
        original = json.loads((HERE/"iphone-16e.json").read_text())
        other = copy.deepcopy(original)
        result = compare(other, original)
        self.assertEqual(result["changes"]["full/display_intervals_ms"]["delta_p95_ms"], 0)
        other["conditions"]["window_px"] = [1600, 960]
        result = compare(other, original)
        self.assertFalse(result["comparable"])
        self.assertEqual(result["different_conditions"], ["window_px"])


if __name__ == "__main__":
    unittest.main()
