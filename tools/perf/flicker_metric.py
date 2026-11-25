#!/usr/bin/env python3
"""Terrain flicker metric: adjacent-frame residual under sub-pixel camera motion.

Why this metric
---------------
"Terrain textures flicker when you move or zoom out" is a claim about high-frequency
temporal noise: consecutive frames of the SAME static world, with the camera moved by
a fraction of a screen pixel, should be almost identical. Whatever changes pixel to
pixel between such frames is sampling aliasing -- nearest-neighbour tap switching, or
a texture array with no mip chain.

Definitions (fixed, so two people get the same number from the same PNGs)
-----------------------------------------------------------------------
luma              Rec.709 on sRGB-encoded 8-bit values: 0.2126R + 0.7152G + 0.0722B.
                  No linearisation: this measures what the eye sees changing.
abs_delta          |luma[t] - luma[t-1]| per pixel, 0..255.
median_abs_delta  Median over all pixels. Robust: one moving HUD element does not
                  hijack the number.
p99_abs_delta     99th percentile, for the "few loud pixels" case.
changed_ratio     Share of pixels with abs_delta >= 2 (2/255 is the smallest change
                  that survives 8-bit quantisation reliably). This is the headline
                  number, but it has a floor: a genuine sub-pixel motion on a smooth
                  gradient can move every pixel by less than 1 LSB and still score 0.
                  Reported three ways over the steps of a capture, because one number
                  cannot describe a bursty capture:
                    changed_ratio       median over steps -- the steady state.
                    changed_ratio_mean  mean over steps -- dominated by any burst, so it
                                        is the number to quote when *anything* changed.
                    changed_ratio_max   worst single step -- the burst itself.
                  A capture with 2 loud frames among 58 quiet ones has a median near 0
                  and a mean several times larger. Quoting only the median hides the
                  event; quoting only the mean lets two frames stand for the whole run.
changed_ratio_any Share of pixels with abs_delta >= 0.5, i.e. *any* 8-bit change.
                  Read together with changed_ratio it separates the two ways
                  changed_ratio can be small:
                    any >> changed      -> the motion registers, it is just small
                                           per pixel (sub-LSB); the metric's own
                                           quantisation floor, not a still image.
                    any == changed == 0 -> nothing moved at all.
hf_energy         Mean |Laplacian| of the abs_delta image: this is what separates
                  pixel-level flicker from a smooth, legitimate camera shift, which
                  produces a low-frequency band of delta along texture edges.
temporal_variance Mean over pixels of the variance across the whole sequence. A world
                  held still with only sub-pixel camera motion has a near-zero
                  variance; aliasing inflates it.

CLI
---
    python tools/perf/flicker_metric.py <frames_dir> [--label HIGH] [--zoom 20]
    python tools/perf/flicker_metric.py <run_dir> ...     # one table for several runs

A *run directory* is whatever the capture harness wrote: PNG files named so that
sorting them gives capture order (`frame_0000.png`, ...), plus an optional
`capture_meta.json` with `{label, zoom, tier, step_px, viewport}`.
"""
import argparse
import glob
import json
import os
import sys

try:
    import numpy as np
    from PIL import Image
    HAVE_DEPS = True
except Exception:  # pragma: no cover - declared dependency
    HAVE_DEPS = False

LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32) if HAVE_DEPS else None
CHANGED_THRESHOLD = 2.0
LAPLACIAN = np.array([[0.0, 1.0, 0.0], [1.0, -4.0, 1.0], [0.0, 1.0, 0.0]],
                     dtype=np.float32) if HAVE_DEPS else None


def to_luma(array):
    """RGB(A) -> luma plane; an existing 2-D plane passes through unchanged."""
    values = np.asarray(array, dtype=np.float32)
    if values.ndim == 3:
        return values[..., :3] @ LUMA
    return values


def load_luma(path):
    """PNG -> float32 luma plane."""
    with Image.open(path) as image:
        array = np.asarray(image.convert("RGB"), dtype=np.float32)
    return array @ LUMA


def pair_metrics(before, after, changed_threshold=CHANGED_THRESHOLD):
    """One adjacent pair -> flicker numbers."""
    before = to_luma(before)
    after = to_luma(after)
    if before.shape != after.shape:
        raise ValueError(f"frame sizes differ: {before.shape} vs {after.shape}")
    delta = np.abs(after - before)
    laplacian = _convolve_same(delta, LAPLACIAN)
    return {
        "median_abs_delta": round(float(np.median(delta)), 4),
        "mean_abs_delta": round(float(delta.mean()), 4),
        "p99_abs_delta": round(float(np.percentile(delta, 99)), 4),
        "max_abs_delta": round(float(delta.max()), 2),
        "changed_ratio": round(float((delta >= changed_threshold).mean()), 5),
        # Same image, threshold relaxed to "any 8-bit change". This is the control that
        # tells a sub-LSB camera shift apart from a frozen image; see the module docstring.
        "changed_ratio_any": round(float((delta >= 0.5).mean()), 5),
        "hf_energy": round(float(np.abs(laplacian).mean()), 4),
    }


def _convolve_same(image, kernel):
    """3x3 correlation, zero padded, no scipy dependency."""
    height, width = image.shape
    padded = np.pad(image, 1, mode="edge")
    out = np.zeros_like(image)
    for dy in range(3):
        for dx in range(3):
            weight = kernel[dy, dx]
            if weight == 0.0:
                continue
            out += weight * padded[dy:dy + height, dx:dx + width]
    return out


def sequence_metrics(frames, changed_threshold=CHANGED_THRESHOLD):
    """Whole capture -> per-step series plus the sequence-level numbers."""
    if len(frames) < 2:
        return {"steps": 0, "error": "need at least 2 frames"}
    planes = [to_luma(frame) for frame in frames]
    shapes = {plane.shape for plane in planes}
    if len(shapes) != 1:
        return {"steps": 0, "error": "frame sizes differ", "shapes": list(map(str, shapes))}
    steps = [pair_metrics(planes[index - 1], planes[index], changed_threshold)
             for index in range(1, len(planes))]
    stacked = np.stack(planes, axis=0)
    variance = stacked.var(axis=0)
    per_step_median = [step["median_abs_delta"] for step in steps]
    per_step_changed = [step["changed_ratio"] for step in steps]
    per_step_any = [step["changed_ratio_any"] for step in steps]
    return {
        "frames": len(frames),
        "steps": len(steps),
        "changed_threshold": changed_threshold,
        "median_abs_delta": round(float(np.median(per_step_median)), 4),
        "p90_step_median": round(float(np.percentile(per_step_median, 90)), 4),
        "max_step_median": round(float(np.max(per_step_median)), 4),
        # Median is the steady state, mean is what a burst does to the run, max is the
        # burst itself. A capture can look clean by median and loud by mean; see the
        # module docstring. All three are exported so nobody has to guess which was used.
        "changed_ratio": round(float(np.median(per_step_changed)), 5),
        "changed_ratio_mean": round(float(np.mean(per_step_changed)), 5),
        "changed_ratio_max": round(float(np.max(per_step_changed)), 5),
        "changed_ratio_any": round(float(np.median(per_step_any)), 5),
        "changed_ratio_any_mean": round(float(np.mean(per_step_any)), 5),
        "changed_ratio_any_max": round(float(np.max(per_step_any)), 5),
        "hf_energy": round(float(np.median([s["hf_energy"] for s in steps])), 4),
        "temporal_variance": round(float(variance.mean()), 4),
        "temporal_variance_p99": round(float(np.percentile(variance, 99)), 3),
        "per_step": steps,
    }


def find_frames(run_dir):
    """PNGs in capture order. Sorting by name is the contract."""
    paths = sorted(glob.glob(os.path.join(run_dir, "*.png")))
    return paths


def read_meta(run_dir):
    path = os.path.join(run_dir, "capture_meta.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def analyze_run(run_dir, limit=0, changed_threshold=CHANGED_THRESHOLD):
    paths = find_frames(run_dir)
    if limit:
        paths = paths[:limit]
    if len(paths) < 2:
        return {"dir": run_dir, "error": "fewer than 2 frames",
                "frames_found": len(paths), "meta": read_meta(run_dir)}
    frames = [load_luma(path) for path in paths]
    shapes = {frame.shape for frame in frames}
    if len(shapes) != 1:
        return {"dir": run_dir, "error": "frame sizes differ", "shapes": list(shapes)}
    out = {"dir": run_dir, "meta": read_meta(run_dir)}
    out.update(sequence_metrics(frames, changed_threshold))
    return out


def print_table(results, baseline=None):
    print(f"{'run':<22}{'tier':<7}{'hex_px':>8}{'zoom':>7}{'steps':>7}"
          f"{'med|Δ|':>9}{'p90':>8}{'chg%med':>9}{'chg%avg':>9}{'chg%max':>9}"
          f"{'any%':>8}{'hf':>7}{'var':>9}")
    for result in results:
        if result.get("error"):
            print(f"{os.path.basename(result['dir']):<22}-- {result['error']}")
            continue
        meta = result.get("meta") or {}
        tier = str(meta.get("tier", "?"))
        zoom = meta.get("zoom")
        # hex_px is the axis that survives the move to the phone (content_scale differs);
        # camera_zoom does not. Print both so a table copied out of context cannot be
        # read against the wrong one.
        hex_px = meta.get("hex_px")
        print(f"{os.path.basename(result['dir']):<22}{tier:<7}"
              f"{('%.1f' % hex_px) if isinstance(hex_px, (int, float)) else '-':>8}"
              f"{('%.2f' % zoom) if isinstance(zoom, (int, float)) else '-':>7}"
              f"{result['steps']:>7}"
              f"{result['median_abs_delta']:>9.3f}"
              f"{result['p90_step_median']:>8.3f}"
              f"{100.0 * result['changed_ratio']:>8.3f}%"
              f"{100.0 * result.get('changed_ratio_mean', 0.0):>8.3f}%"
              f"{100.0 * result.get('changed_ratio_max', 0.0):>8.3f}%"
              f"{100.0 * result.get('changed_ratio_any', 0.0):>7.2f}%"
              f"{result['hf_energy']:>7.3f}"
              f"{result['temporal_variance']:>9.3f}")
    if baseline:
        for result in results:
            if result.get("error"):
                continue
            ratio = (result["temporal_variance"] / baseline["temporal_variance"]
                     if baseline.get("temporal_variance") else None)
            if ratio is not None:
                print(f"  {os.path.basename(result['dir'])}: "
                      f"temporal_variance = {ratio:.2f}x baseline")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Terrain flicker metric over PNG frames")
    parser.add_argument("runs", nargs="+", help="capture directory per run")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--out", default="", help="write the JSON report here")
    parser.add_argument("--limit", type=int, default=0, help="use only the first N frames")
    parser.add_argument("--baseline", default="", help="run dir to ratio against")
    parser.add_argument("--changed-threshold", type=float, default=CHANGED_THRESHOLD,
                        help="abs luma delta counted as a changed pixel (default 2, "
                             "the 8-bit quantisation floor); use 0.5 to ask whether "
                             "anything moved at all")
    args = parser.parse_args(argv)
    if not HAVE_DEPS:
        print("numpy and Pillow are required", file=sys.stderr)
        return 2

    results = [analyze_run(run, args.limit, args.changed_threshold) for run in args.runs]
    baseline = None
    if args.baseline:
        baseline = analyze_run(args.baseline, args.limit, args.changed_threshold)
    if args.json:
        print(json.dumps({"results": results, "baseline": baseline},
                         ensure_ascii=False, indent=2, default=str))
    else:
        print_table(results, baseline)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump({"results": results, "baseline": baseline}, handle,
                      ensure_ascii=False, indent=2, default=str)
        print(f"report -> {args.out}")
    return 0 if all(not r.get("error") for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
