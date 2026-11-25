"""Contract tests for flicker_metric.py, on synthetic frames.

The metric only earns trust if it separates three cases cleanly on data whose answer is
known: a static capture (no flicker), a smooth sub-pixel shift (low-frequency, low
hf_energy), and pixel-level aliasing (high median and high hf_energy).
"""
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

PERF = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERF))

import flicker_metric as fm  # noqa: E402


def write_png(path, array):
    Image.fromarray(np.clip(array, 0, 255).astype(np.uint8), mode="RGB").save(path)


def pattern(height=48, width=64, period=4):
    rows = np.arange(height)[:, None]
    cols = np.arange(width)[None, :]
    checker = ((rows // (period // 2)) + (cols // (period // 2))) % 2
    return (checker * 200.0 + 20.0)


def to_rgb(gray):
    return np.stack([gray, gray, gray], axis=-1)


class PairMetricTest(unittest.TestCase):
    def test_identical_frames_are_zero(self):
        frame = to_rgb(pattern())
        out = fm.pair_metrics(frame, frame)
        self.assertEqual(out["median_abs_delta"], 0.0)
        self.assertEqual(out["changed_ratio"], 0.0)
        self.assertEqual(out["hf_energy"], 0.0)

    def test_uniform_shift_is_low_frequency(self):
        # A one-pixel horizontal translation of a horizontal gradient: many changed
        # pixels, but the delta map is a smooth vertical band, so hf_energy stays low.
        cols = np.arange(64)[None, :].repeat(48, axis=0).astype(float) * 2.0
        before = to_rgb(cols)
        after = to_rgb(np.roll(cols, 1, axis=1))
        out = fm.pair_metrics(before, after)
        self.assertGreater(out["changed_ratio"], 0.5)
        self.assertLess(out["hf_energy"], out["median_abs_delta"] * 3.0)

    def test_tap_switching_is_high_frequency(self):
        # Aliasing shows up as a delta that is uncorrelated pixel to pixel, which is
        # what a neighbour-texel tap jump produces. A per-pixel random delta is the
        # same signature, and unlike a smooth shift its laplacian does not cancel.
        rng = np.random.default_rng(20261125)
        base = pattern(period=4)
        noise = rng.uniform(-50.0, 50.0, base.shape)
        out = fm.pair_metrics(to_rgb(base), to_rgb(base + noise))
        self.assertGreater(out["median_abs_delta"], 10.0)
        self.assertGreater(out["hf_energy"], 5.0)


class SequenceMetricTest(unittest.TestCase):
    def test_static_sequence_has_zero_variance(self):
        frames = [to_rgb(pattern()) for _ in range(4)]
        out = fm.sequence_metrics(frames)
        self.assertEqual(out["steps"], 3)
        self.assertEqual(out["temporal_variance"], 0.0)
        self.assertEqual(out["median_abs_delta"], 0.0)

    def test_flickering_sequence_has_high_variance(self):
        plain = pattern()
        inverted = 20.0 + (1 - (np.arange(48)[:, None] // 2
                                + np.arange(64)[None, :] // 2) % 2) * 200.0
        frames = [to_rgb(plain), to_rgb(inverted), to_rgb(plain), to_rgb(inverted)]
        out = fm.sequence_metrics(frames)
        self.assertGreater(out["temporal_variance"], 1000.0)
        self.assertGreater(out["median_abs_delta"], 100.0)
        self.assertEqual(len(out["per_step"]), 3)

    def test_needs_two_frames(self):
        self.assertIn("error", fm.sequence_metrics([to_rgb(pattern())]))


class QuantisationTest(unittest.TestCase):
    """A sub-LSB shift must not read as "nothing happened" without saying so."""

    @staticmethod
    def shift_edge(plane, steps):
        # Right-shift with edge replication. np.roll would wrap the first column to the last
        # one and produce a single 63-step jump, which is a *changed* pixel and would make
        # the "changed_ratio is zero" assertion fail for the wrong reason.
        out = plane.copy()
        if steps <= 0:
            return out
        out[:, :steps] = plane[:, :1]
        out[:, steps:] = plane[:, :-steps]
        return out

    def ramp(self, slope=1.0):
        cols = np.arange(64)[None, :].repeat(48, axis=0).astype(float) * slope + 40.0
        return to_rgb(cols)

    def test_one_lsb_shift_is_below_changed_but_above_any(self):
        # A one-pixel shift of a gradient with slope 1.0 changes every pixel by exactly one
        # 8-bit step. That is real motion, but it is under the >=2 headline threshold.
        before = self.ramp()
        after = to_rgb(self.shift_edge(np.asarray(before, dtype=float)[..., 0], 1))
        out = fm.pair_metrics(before, after)
        self.assertEqual(out["changed_ratio"], 0.0)
        self.assertGreater(out["changed_ratio_any"], 0.5)

    def test_relaxed_threshold_reaches_the_same_pixels(self):
        before = self.ramp()
        after = to_rgb(self.shift_edge(np.asarray(before, dtype=float)[..., 0], 1))
        strict = fm.pair_metrics(before, after)
        relaxed = fm.pair_metrics(before, after, 0.5)
        self.assertEqual(relaxed["changed_ratio"], relaxed["changed_ratio_any"])
        self.assertGreater(relaxed["changed_ratio"], strict["changed_ratio"])

    def test_sequence_carries_the_relaxed_number(self):
        plane = np.asarray(self.ramp(), dtype=float)[..., 0]
        frames = [to_rgb(self.shift_edge(plane, step)) for step in range(4)]
        out = fm.sequence_metrics(frames)
        self.assertEqual(out["changed_ratio"], 0.0)
        self.assertGreater(out["changed_ratio_any"], 0.5)
        self.assertEqual(out["changed_threshold"], 2.0)


class StepStatisticsTest(unittest.TestCase):
    """One statistic cannot describe a bursty capture: the median hides the event, the
    mean lets two loud frames speak for the whole run. Both are exported, so a table
    built from this data has to state which one it quoted."""

    quiet = np.full((24, 32), 100.0)
    loud = np.full((24, 32), 200.0)

    def test_single_burst_shows_in_mean_and_max_not_median(self):
        frames = [to_rgb(self.quiet) for _ in range(6)]
        frames[3] = to_rgb(self.loud)
        # Steps: q->q, q->q, q->B, B->q, q->q  =>  [0, 0, 1, 1, 0]
        out = fm.sequence_metrics(frames)
        self.assertEqual(out["changed_ratio"], 0.0)
        self.assertAlmostEqual(out["changed_ratio_mean"], 0.4, places=4)
        self.assertAlmostEqual(out["changed_ratio_max"], 1.0, places=4)

    def test_every_run_reports_all_three(self):
        out = fm.sequence_metrics([to_rgb(self.quiet) for _ in range(3)])
        for key in ("changed_ratio", "changed_ratio_mean", "changed_ratio_max",
                    "changed_ratio_any", "changed_ratio_any_mean",
                    "changed_ratio_any_max"):
            self.assertIn(key, out)
        self.assertEqual(out["changed_ratio"], out["changed_ratio_max"])


class DirectoryTest(unittest.TestCase):
    def test_reads_pngs_in_name_order_and_meta(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for index, value in enumerate([10.0, 12.0, 14.0]):
                write_png(directory / f"frame_{index:04d}.png",
                          to_rgb(np.full((24, 32), value)))
            (directory / "capture_meta.json").write_text(
                '{"label": "high_zoom20", "tier": "HIGH", "zoom": 20, "step_px": 0.1}',
                encoding="utf-8")
            out = fm.analyze_run(tmp)
        self.assertEqual(out["frames"], 3)
        self.assertEqual(out["meta"]["tier"], "HIGH")
        self.assertAlmostEqual(out["median_abs_delta"], 2.0, places=2)

    def test_missing_directory_is_reported_not_raised(self):
        out = fm.analyze_run(str(Path(tempfile.gettempdir()) / "nope-not-here"))
        self.assertIn("error", out)


if __name__ == "__main__":
    unittest.main()
