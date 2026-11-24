import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest

from apple_trace import pair_swaps
from report import PROTOCOL, compare, load_capture


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

    def test_failed_run_is_rejected(self):
        (self.folder / "outcome.txt").write_text("29 checks, 2 failures")
        with self.assertRaisesRegex(ValueError, "incomplete or failed benchmark"):
            load_capture(self.folder)

    def test_device_baseline_comparison(self):
        original = {
            "protocol": PROTOCOL, "model": "MacBookAir", "godot": "4.6.3",
            "conditions": {"device": "m2", "window_px": [1600, 960]},
            "measurements": {"full": {"draw_callback_ms": {"samples": 240, "p95_ms": 16.67, "above_25_ms": 0}}},
        }
        other = copy.deepcopy(original)
        result = compare(other, original)
        self.assertEqual(result["changes"]["full/draw_callback_ms"]["delta_p95_ms"], 0)
        other["conditions"]["window_px"] = [1920, 1080]
        other["model"] = "MacBookPro"
        other["godot"] = "4.5"
        result = compare(other, original)
        self.assertFalse(result["comparable"])
        self.assertEqual(result["different_conditions"], ["godot", "model", "window_px"])
        other.pop("godot")
        with self.assertRaisesRegex(ValueError, "missing device model or Godot version"):
            compare(other, original)

    def test_history_cannot_be_used_as_baseline(self):
        archived = json.loads(Path(__file__).with_name("iphone-16e.json").read_text())
        with self.assertRaisesRegex(ValueError, "historical diagnostic"):
            compare(archived, archived)


class DisplaySwapTest(unittest.TestCase):
    def test_only_matches_selected_requests_after_their_gpu_work(self):
        requests = [(10, 1, 9), (20, 2, 8), (30, 3, 9), (40, 4, 8), (50, 5, 9)]
        swaps = {9: [12, 17, 36, 56], 8: [26, 46]}
        self.assertEqual(pair_swaps(requests, {1, 3}, swaps, {1: 15, 3: 34}), [17, 36])

    def test_rejects_ambiguous_and_reused_swaps(self):
        requests = [(10, 1, 9), (20, 2, 8), (30, 3, 9)]
        for swaps, error in [
            ({9: [16, 17], 8: [26]}, "2 candidates"),
            ({9: [26], 8: [26]}, "duplicate or out-of-order"),
        ]:
            with self.subTest(swaps=swaps), self.assertRaisesRegex(ValueError, error):
                pair_swaps(requests, {1, 2}, swaps, {1: 15, 2: 25})

    def test_missing_swap_is_never_replaced_by_one_from_a_later_request(self):
        requests = [(10, 1, 9), (20, 2, 8), (30, 3, 9)]
        swaps = {9: [12, 35], 8: [26]}
        self.assertEqual(pair_swaps(requests, {1, 2}, swaps, {1: 15, 2: 25}), [26])


if __name__ == "__main__":
    unittest.main()
