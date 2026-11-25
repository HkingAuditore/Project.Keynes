#!/usr/bin/env python3
"""Per-frame metrics: percentiles, dropped frames, stutter runs, per-second buckets.

Why this file exists
--------------------
`analyze_android_perf.py` reads the PerfRecorder CSV (one row per simulated day)
and the `[heartbeat]` logcat line (~1 per 5 s), so its "p95 frame time" is really
a percentile over *window means*. That cannot answer "how many frames missed the
budget" or "which second stuttered": a 5 s mean hides every individual hitch.

This module holds the pure functions that a real per-frame series needs. It has
no I/O except `parse_frame_source`, no dependency outside the stdlib, and every
definition that a report depends on is written down below, so two people running
the same raw file get the same numbers.

Definitions (fixed on purpose -- do not silently change)
------------------------------------------------------
frame_ms        Duration of one frame, in milliseconds. Source-independent.
budget_ms       One vsync period. 1000/60 = 16.6667 ms for 60 Hz.
tolerance_ms    Slack added to the budget before a frame counts as dropped.
                Default 0.5 ms (3% of a 60 Hz period). It exists because
                SurfaceFlinger present timestamps are nanosecond-quantized: a
                perfect 60 Hz frame measures 16.666667 ms, which is 3e-7 ms over
                the float budget and would otherwise mark 100% of a smooth run as
                dropped. Pass 0 to get the strict comparison.
dropped frame   A frame with `frame_ms > budget_ms + tolerance_ms`. Counted per
                frame.
missed vsyncs   `max(0, round(frame_ms / budget_ms) - 1)`. One 40 ms frame on a
                60 Hz budget misses 1 vsync even though it is 2.4x the budget;
                summing this is the "how many frame slots did I lose" number.
jank run        A maximal sequence of consecutive dropped frames. Reported by
                frame count and by wall duration; single-frame runs are spikes,
                runs of >= 2 frames are stutter segments.
percentile      Linear interpolation on the sorted series, `q` in [0, 1] --
                deliberately the same algorithm as `pct()` in
                analyze_android_perf.py so a number quoted from either file agrees.

CLI (for whatever per-frame dump lands in a run directory)
----------------------------------------------------------
    python tools/perf/frame_metrics.py <file|dir> [--budget 16.667] [--json]
    python tools/perf/frame_metrics.py <file|dir> --buckets 1.0

Accepted input, detected per line:
    SurfaceFlinger latency triplet   `123456789012  123456789345  123456789000`
        (desired_present, actual_present, frame_ready -- nanoseconds). Frame time
        is the delta of actual_present. A leading single-integer line is read as
        the refresh period in ns. Pending rows (`0`, or 2**63-1) are skipped.
    timestamped                      `12.345,16.7` or `12.345 16.7` (t_s, frame_ms)
    bare frame time                  `16.7`
Lines that match nothing are ignored (logcat pasted in by accident is fine).
"""
import argparse
import json
import math
import os
import statistics
import sys

VSYNC_60HZ_MS = 1000.0 / 60.0
DROP_TOLERANCE_MS = 0.5
LONG_MAX = 2 ** 63 - 1
NANOS_PER_MS = 1_000_000.0
NANOS_PER_S = 1_000_000_000.0


# ── primitives ─────────────────────────────────────────────────────────────
def percentile(values, q):
    """Linear-interpolated percentile, q in [0, 1]. None for an empty series."""
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    if q <= 0.0:
        return vals[0]
    if q >= 1.0:
        return vals[-1]
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return vals[lo]
    return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo)


def is_drop(frame_ms, budget_ms=VSYNC_60HZ_MS, tolerance_ms=DROP_TOLERANCE_MS):
    """One frame over budget (plus tolerance)? The single predicate everything uses."""
    return frame_ms > budget_ms + tolerance_ms


def dropped_flags(frames, budget_ms=VSYNC_60HZ_MS, tolerance_ms=DROP_TOLERANCE_MS):
    """Boolean per frame: did it overrun the budget? (see is_drop)."""
    return [is_drop(f, budget_ms, tolerance_ms) for f in frames]


def dropped_frames(frames, budget_ms=VSYNC_60HZ_MS, tolerance_ms=DROP_TOLERANCE_MS):
    """Count of frames over budget. See module docstring for the definition."""
    return sum(1 for f in frames if is_drop(f, budget_ms, tolerance_ms))


def missed_vsyncs(frames, budget_ms=VSYNC_60HZ_MS):
    """Total frame slots lost, `max(0, round(f/budget) - 1)` summed."""
    if budget_ms <= 0:
        raise ValueError("budget_ms must be > 0")
    total = 0
    for f in frames:
        slots = int(round(f / budget_ms)) - 1
        if slots > 0:
            total += slots
    return total


def jank_runs(frames, budget_ms=VSYNC_60HZ_MS, tolerance_ms=DROP_TOLERANCE_MS):
    """Every maximal run of consecutive over-budget frames, in order of start."""
    runs = []
    start = None
    total = 0.0
    for index, frame in enumerate(frames):
        if is_drop(frame, budget_ms, tolerance_ms):
            if start is None:
                start = index
                total = 0.0
            total += frame
        elif start is not None:
            runs.append({"start_index": start, "end_index": index - 1,
                         "frames": index - start, "ms": total})
            start = None
    if start is not None:
        runs.append({"start_index": start, "end_index": len(frames) - 1,
                     "frames": len(frames) - start, "ms": total})
    return runs


def longest_jank_run(frames, budget_ms=VSYNC_60HZ_MS, min_frames=1,
                     tolerance_ms=DROP_TOLERANCE_MS):
    """The run with the largest wall duration among runs of >= min_frames."""
    runs = [r for r in jank_runs(frames, budget_ms, tolerance_ms)
            if r["frames"] >= max(1, min_frames)]
    if not runs:
        return None
    return max(runs, key=lambda r: (r["ms"], r["frames"]))


def worst_frames(frames, budget_ms=VSYNC_60HZ_MS, top=5,
                 tolerance_ms=DROP_TOLERANCE_MS):
    """The top slowest frames with their index, so a spike can be located."""
    ranked = sorted(range(len(frames)), key=lambda i: -frames[i])[:max(0, top)]
    return [{"index": i, "frame_ms": frames[i],
             "over_budget": is_drop(frames[i], budget_ms, tolerance_ms)} for i in ranked]



# ── whole-series summary ───────────────────────────────────────────────────
def nominal_period(frames, lo_ms=2.0, hi_ms=100.0):
    """The tick the app actually paces at: modal 0.5 ms bin of the intervals.

    A device refresh header (the 120 Hz `8333333` in a SurfaceFlinger dump) says what
    the panel can do, not what the app targets: this game paces at 2 refresh periods
    (16.67 ms). Taking the panel period as the budget marks every 60 fps frame as
    dropped, so the nominal must come from the series itself.
    """
    bins = {}
    for frame in frames:
        if lo_ms <= frame <= hi_ms:
            key = round(frame * 2) / 2.0
            bins[key] = bins.get(key, 0) + 1
    if not bins:
        return None
    return max(bins.items(), key=lambda item: (item[1], -item[0]))[0]


def split_regimes(frames, stamps_s=None, ratio=1.4, min_frames=120):
    """Split the series where the pacing changes (e.g. 60 fps -> 30 fps).

    One budget cannot describe a run that changes tick mid-way: against 16.67 ms the
    30 fps half is 100% "dropped" by construction, and every stutter runs forever. The
    split is a single change point, chosen where the two halves' median interval
    differs most, and only accepted when the ratio reaches `ratio`.
    """
    count = len(frames)
    if count < min_frames * 2:
        return []
    best = None
    for percent in range(10, 91, 2):
        cut = int(count * percent / 100.0)
        if cut < min_frames or count - cut < min_frames:
            continue
        left = statistics.median(frames[:cut])
        right = statistics.median(frames[cut:])
        if left <= 0 or right <= 0:
            continue
        score = abs(math.log(left / right))
        if best is None or score > best[0]:
            best = (score, cut, left, right)
    if best is None:
        return []
    score, cut, left, right = best
    ratio_now = max(left, right) / min(left, right)
    if ratio_now < ratio:
        return []
    segments = [(0, cut), (cut, count)]
    out = []
    for start, end in segments:
        part = frames[start:end]
        nominal = nominal_period(part)
        out.append({"from_index": start, "to_index": end - 1,
                    "frames": end - start,
                    "nominal_ms": nominal,
                    "median_ms": round(statistics.median(part), 2),
                    "from_s": (round(stamps_s[start] - stamps_s[0], 3)
                               if stamps_s else None),
                    "to_s": (round(stamps_s[end - 1] - stamps_s[0], 3)
                             if stamps_s else None)})
    return out


def per_second_counts(times, slow_below=45):
    """Frames per wall-clock second, as a distribution.

    This is the check for "was the fps limit changed during the run": a limiter that
    drops to 30 leaves whole seconds near 30, which a frame-weighted median hides.
    """
    if not times:
        return None
    base = int(times[0])
    counts = {}
    for stamp in times:
        key = int(stamp) - base
        counts[key] = counts.get(key, 0) + 1
    values = [count for count in counts.values()]
    if not values:
        return None
    return {
        "seconds": len(values),
        "min": min(values),
        "p5": round(percentile(values, 0.05), 1),
        "p50": round(percentile(values, 0.50), 1),
        "p95": round(percentile(values, 0.95), 1),
        "max": max(values),
        "seconds_below_45fps": sum(1 for value in values if value < slow_below),
    }


def frame_stats(frames, budget_ms=None, timestamps_s=None,
                stutter_min_frames=2, tolerance_ms=DROP_TOLERANCE_MS):
    """Everything a performance verdict needs from one frame series.

    timestamps_s, when given, must be the same length as frames and is used to
    turn an index into "which second". Without it the same numbers are still
    produced; only the *_s / *_at_s fields are null.
    """
    series = [float(f) for f in frames]
    n = len(series)
    if n == 0:
        return {"frames": 0, "budget_ms": budget_ms, "coverage_s": None}

    if timestamps_s is not None and len(timestamps_s) != n:
        raise ValueError("timestamps_s must be the same length as frames")
    times = [float(t) for t in timestamps_s] if timestamps_s is not None else None

    measured_nominal = nominal_period(series)
    budget_source = "explicit" if budget_ms is not None else "measured_nominal"
    if budget_ms is None:
        budget_ms = measured_nominal or VSYNC_60HZ_MS

    regimes = split_regimes(series, times)
    for regime in regimes:
        part = series[regime["from_index"]:regime["to_index"] + 1]
        own = regime["nominal_ms"] or budget_ms
        regime["frame_ms"] = {
            "p50": round(percentile(part, 0.50), 3),
            "p95": round(percentile(part, 0.95), 3),
            "p99": round(percentile(part, 0.99), 3),
            "max": round(max(part), 3)}
        regime["dropped_vs_own"] = dropped_frames(part, own, tolerance_ms)
        regime["dropped_vs_budget"] = dropped_frames(part, budget_ms, tolerance_ms)
        regime["fps_from_median"] = (round(1000.0 / statistics.median(part), 2)
                                     if statistics.median(part) > 0 else None)
        if times:
            regime["capture_ratio"] = _capture_ratio(
                times[regime["from_index"]:regime["to_index"] + 1],
                len(part), own)
        else:
            regime["capture_ratio"] = None
        within = longest_jank_run(part, own, stutter_min_frames, tolerance_ms)
        if within:
            within = dict(within)
            within["start_index"] += regime["from_index"]
            within["end_index"] += regime["from_index"]
            regime["jank_run_longest"] = _annotate_run(within, times)
        else:
            regime["jank_run_longest"] = None

    drops = dropped_flags(series, budget_ms, tolerance_ms)
    drop_count = sum(1 for d in drops if d)
    # With a mid-run pacing change, a single-budget jank run spans the whole slow half
    # and means nothing; take the longest run measured inside one regime instead.
    if regimes:
        runs = [r["jank_run_longest"] for r in regimes if r["jank_run_longest"]]
        run = max(runs, key=lambda r: r["ms"]) if runs else None
        run = {k: v for k, v in run.items()
               if k not in ("start_s", "end_s")} if run else None
    else:
        run = longest_jank_run(series, budget_ms, stutter_min_frames, tolerance_ms)
    spike = longest_jank_run(series, budget_ms, 1, tolerance_ms)
    all_runs = jank_runs(series, budget_ms, tolerance_ms)

    mean = sum(series) / n
    out = {
        "frames": n,
        "budget_ms": round(budget_ms, 4),
        "budget_source": budget_source,
        "measured_nominal_ms": measured_nominal,
        "tolerance_ms": tolerance_ms,
        "regimes": regimes,
        # 0 means the pacing never changed during the run -- which is the evidence
        # that a frame-rate limit was not rewritten mid-run.
        "pacing_changes": max(0, len(regimes) - 1),
        "per_second": per_second_counts(times),
        "coverage_s": (round(times[-1] - times[0], 3) if times and n > 1 else None),
        "frame_ms": {
            "mean": round(mean, 3),
            "p50": round(percentile(series, 0.50), 3),
            "p95": round(percentile(series, 0.95), 3),
            "p99": round(percentile(series, 0.99), 3),
            "max": round(max(series), 3),
            "min": round(min(series), 3),
        },
        "fps_from_mean": round(1000.0 / mean, 2) if mean > 0 else None,
        "dropped": {
            "frames": drop_count,
            "pct": round(100.0 * drop_count / n, 2),
            "missed_vsyncs": missed_vsyncs(series, budget_ms),
        },
        "jank_run_longest": _annotate_run(run, times),
        "spike_longest": _annotate_run(spike, times),
        "jank_runs_total": len(all_runs),
        "jank_runs_stutter": sum(1 for r in all_runs if r["frames"] >= stutter_min_frames),
        "worst": _annotate_worst(worst_frames(series, budget_ms, 5, tolerance_ms), times),
        "stutter_min_frames": stutter_min_frames,
        # Captured frames vs the slots the covered time span allows. Measured against
        # each regime's own pacing: judging a 30 fps half against 60 Hz slots reports
        # 67% "capture loss" for frames the app simply never tried to draw.
        "capture_ratio": (
            min((r["capture_ratio"] for r in regimes
                 if r.get("capture_ratio") is not None), default=None)
            if regimes else _capture_ratio(times, n, measured_nominal or budget_ms)),
    }
    return out


def _capture_ratio(times, count, budget_ms):
    if not times or count < 2 or budget_ms <= 0:
        return None
    expected = (times[-1] - times[0]) * 1000.0 / budget_ms
    return round((count - 1) / expected, 3) if expected > 0 else None



def _annotate_run(run, times):
    if run is None:
        return None
    out = dict(run)
    out["ms"] = round(out["ms"], 2)
    if times:
        out["start_s"] = round(times[run["start_index"]] - times[0], 3)
        out["end_s"] = round(times[run["end_index"]] - times[0], 3)
    return out


def _annotate_worst(items, times):
    if not times:
        return items
    for item in items:
        item["at_s"] = round(times[item["index"]] - times[0], 3)
    return items


def bucket_report(frames, timestamps_s, bucket_s=1.0, budget_ms=VSYNC_60HZ_MS,
                  tolerance_ms=DROP_TOLERANCE_MS):
    """Per-bucket percentiles, so a stutter can be pinned to a time range."""
    if len(frames) != len(timestamps_s):
        raise ValueError("timestamps_s must be the same length as frames")
    if bucket_s <= 0:
        raise ValueError("bucket_s must be > 0")
    if not frames:
        return []
    t0 = float(timestamps_s[0])
    groups = {}
    for frame, stamp in zip(frames, timestamps_s):
        key = int((float(stamp) - t0) // bucket_s)
        groups.setdefault(key, []).append(float(frame))
    out = []
    for key in sorted(groups):
        vals = groups[key]
        out.append({
            "from_s": round(key * bucket_s, 3),
            "to_s": round((key + 1) * bucket_s, 3),
            "frames": len(vals),
            "p50": round(percentile(vals, 0.50), 3),
            "p95": round(percentile(vals, 0.95), 3),
            "p99": round(percentile(vals, 0.99), 3),
            "max": round(max(vals), 3),
            "dropped": dropped_frames(vals, budget_ms, tolerance_ms),
        })
    return out


# ── parsing raw dumps ──────────────────────────────────────────────────────
def _ints(line):
    parts = line.replace(",", " ").split()
    out = []
    for part in parts:
        try:
            out.append(int(part))
        except ValueError:
            return None
    return out or None


def _floats(line):
    parts = line.replace(",", " ").split()
    if not parts:
        return None
    out = []
    for part in parts:
        try:
            value = float(part)
        except ValueError:
            return None
        if math.isnan(value) or math.isinf(value):
            return None
        out.append(value)
    return out


FRAME_COLUMNS = ("frame_ms", "frame_time_ms", "duration_ms", "frametime_ms", "ms",
                 "frame_time", "dur_ms")
TIME_COLUMNS = ("t_ms", "ts_ms", "timestamp_ms", "time_ms", "t_s", "ts", "timestamp",
                "time_s", "t", "time")


def _split_row(line):
    if "," in line:
        return [part.strip() for part in line.split(",")]
    return line.split()


def _detect_header(lines):
    """Find a CSV header row among the first few lines and map its columns.

    The capture side writes its own `frames_raw.csv`, and a plain 2-column assumption
    breaks as soon as it carries an index or a header: a `frame_idx,t_ms,frame_ms`
    file would silently yield zero frames. Detecting the header makes that file
    readable instead of empty.
    """
    for line in lines[:5]:
        text = line.strip()
        if not text or text.startswith(("#", "//")):
            continue
        parts = _split_row(text)
        lowered = [part.lower().replace(" ", "_") for part in parts]
        frame_index = next((i for i, name in enumerate(lowered)
                            if name in FRAME_COLUMNS), None)
        time_index = next((i for i, name in enumerate(lowered)
                           if name in TIME_COLUMNS), None)
        if frame_index is None and time_index is None:
            return None
        if len(parts) < 2 and frame_index is None and time_index != 0:
            return None
        return {"frame": frame_index, "time": time_index,
                "lowered": lowered, "raw": text}
    return None


def _parse_with_header(lines, header):
    """Rows under a detected header -> (frames_ms, stamps_s, meta)."""
    frame_index = header["frame"]
    time_index = header["time"]
    # Scale raw time values to SECONDS; frames stay in milliseconds.
    to_seconds = 1e-3
    if time_index is not None:
        name = header["lowered"][time_index]
        if name.endswith("_ns"):
            to_seconds = 1e-9
        elif name.endswith("_us"):
            to_seconds = 1e-6
        elif name.endswith("_s"):
            to_seconds = 1.0
    frames, stamps = [], []
    seen_header = False
    widest = max(index for index in (frame_index, time_index) if index is not None)
    for line in lines:
        text = line.strip()
        if not text or text.startswith(("#", "//")):
            continue
        if not seen_header and text == header["raw"]:
            seen_header = True
            continue
        parts = _split_row(text)
        if len(parts) <= widest:
            continue
        try:
            if frame_index is not None:
                frame = float(parts[frame_index])
                if not 0.0 < frame < 100000.0:
                    continue
                frames.append(frame)
                if time_index is not None:
                    stamps.append(float(parts[time_index]) * to_seconds)
            else:
                stamp = float(parts[time_index]) * to_seconds
                stamps.append(stamp)
                if len(stamps) >= 2:
                    frames.append((stamps[-1] - stamps[-2]) * 1000.0)
        except (ValueError, IndexError):
            continue
    if frame_index is not None:
        if len(stamps) == len(frames) and stamps:
            base = stamps[0]
            stamps = [round(value - base, 6) for value in stamps]
        else:
            stamps = None
    elif len(stamps) == len(frames) + 1 and stamps:
        base = stamps[0]
        stamps = [round(value - base, 6) for value in stamps[1:]]
    else:
        stamps = None
    return frames, stamps, {"shape": "csv_header", "columns": header["lowered"]}


def parse_frame_source(text):
    """Parse a raw dump into (frames, timestamps_s, meta).

    Handles the three shapes in the module docstring. Returns per-frame values in
    order of appearance, with timestamps relative to the first frame in seconds.

    A `dumpsys SurfaceFlinger --latency` sample covers only the last ~128 frames,
    so a full run is sampled repeatedly and appended. A header line (refresh
    period) therefore starts a NEW block, and frame deltas are only taken inside a
    block -- otherwise the jump between the end of one sample and the start of the
    next would look like a multi-second freeze.
    """
    latency_blocks = [[]]
    refresh_ns = None
    frames = []
    stamps = []
    shape = None

    lines = text.splitlines()
    header = _detect_header(lines)
    if header is not None:
        return _parse_with_header(lines, header)
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(("#", "//")):
            continue

        ints = _ints(line)
        if ints is not None and len(ints) == 3 and min(abs(v) for v in ints) > NANOS_PER_MS:
            latency_blocks[-1].append(ints)
            shape = shape or "surfaceflinger"
            continue
        if ints is not None and len(ints) == 1:
            if ints[0] > NANOS_PER_MS:
                # SurfaceFlinger latency header = refresh period, starts a block.
                if refresh_ns is None:
                    refresh_ns = ints[0]
                if latency_blocks[-1]:
                    latency_blocks.append([])
                shape = shape or "surfaceflinger"
                continue
            if 0.0 < ints[0] < 100000.0:
                frames.append(float(ints[0]))
                shape = shape or "bare_ms"
                continue
            continue

        if latency_blocks[0] or any(latency_blocks):
            continue                          # a non-row inside a latency dump

        floats = _floats(line)
        if floats is None:
            continue
        if len(floats) == 2:
            stamps.append(floats[0])
            frames.append(floats[1])
            shape = "timestamped"
        elif len(floats) == 1 and 0.0 < floats[0] < 100000.0:
            frames.append(floats[0])
            shape = shape or "bare_ms"

    if any(latency_blocks):
        block_frames = []
        block_stamps = []
        for block in latency_blocks:
            if not block:
                continue
            part_frames, part_stamps, refresh_ns = _from_latency(block, refresh_ns)
            block_frames.extend(part_frames)
            block_stamps.extend(part_stamps)
        frames, stamps = block_frames, block_stamps
        shape = "surfaceflinger"

    if stamps and len(stamps) == len(frames):
        base = stamps[0]
        stamps = [round(s - base, 6) for s in stamps]
        # Samples are appended in capture order; keep the series monotonic so a
        # re-sampled tail cannot produce a negative "at_s".
        for index in range(1, len(stamps)):
            if stamps[index] < stamps[index - 1]:
                stamps[index] = stamps[index - 1]
    else:
        stamps = None

    meta = {"shape": shape, "refresh_ms": (round(refresh_ns / NANOS_PER_MS, 4)
                                           if refresh_ns else None),
            "blocks": len([b for b in latency_blocks if b])}
    return frames, stamps, meta



def _from_latency(rows, refresh_ns):
    """Latency triplets -> frame times from actual_present deltas, stamps in seconds."""
    present = [actual for desired, actual, ready in rows
               if 0 < actual < LONG_MAX and 0 < desired < LONG_MAX]
    frames = []
    stamps = []
    for index in range(1, len(present)):
        delta_ns = present[index] - present[index - 1]
        if delta_ns <= 0:
            continue
        frames.append(delta_ns / NANOS_PER_MS)
        stamps.append(present[index] / NANOS_PER_S)
    if refresh_ns is None and frames:
        positive = sorted(frames)
        if positive:
            refresh_ns = positive[len(positive) // 2] * NANOS_PER_MS
    return frames, stamps, refresh_ns


# ── driver ─────────────────────────────────────────────────────────────────
def read_source(path):
    """Read a file, or every plausible per-frame file inside a run directory."""
    if os.path.isdir(path):
        names = sorted(n for n in os.listdir(path)
                       if n.lower().endswith((".csv", ".txt", ".log")))
        chunks = []
        for name in names:
            with open(os.path.join(path, name), "r", encoding="utf-8-sig",
                      errors="replace") as handle:
                chunks.append(handle.read())
        return "\n".join(chunks)
    with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
        return handle.read()


def print_report(stats, meta, buckets, top_buckets=5):
    frames = stats["frame_ms"]
    print(f"shape={meta.get('shape')} refresh_ms={meta.get('refresh_ms')} "
          f"budget_ms={stats['budget_ms']} ({stats.get('budget_source')}) "
          f"nominal={stats.get('measured_nominal_ms')}")
    print(f"frames={stats['frames']} coverage={stats['coverage_s']}s "
          f"mean_fps={stats['fps_from_mean']} capture={stats.get('capture_ratio')}")
    print(f"frame_ms p50={frames['p50']} p95={frames['p95']} p99={frames['p99']} "
          f"max={frames['max']}")
    for index, regime in enumerate(stats.get("regimes") or [], start=1):
        own = regime.get("frame_ms") or {}
        print(f"  regime {index}  t={regime.get('from_s')}..{regime.get('to_s')}s "
              f"frames={regime['frames']} nominal={regime.get('nominal_ms')}ms "
              f"fps~{regime.get('fps_from_median')} "
              f"p50={own.get('p50')} p95={own.get('p95')} p99={own.get('p99')} "
              f"dropped_vs_own={regime.get('dropped_vs_own')} "
              f"capture={regime.get('capture_ratio')}")
        if regime.get("jank_run_longest"):
            run = regime["jank_run_longest"]
            print(f"           longest stutter inside regime: {run['frames']} frames "
                  f"{run['ms']}ms at {run.get('start_s')}..{run.get('end_s')}s")
    dropped = stats["dropped"]
    print(f"dropped frames={dropped['frames']} ({dropped['pct']}%) "
          f"missed_vsyncs={dropped['missed_vsyncs']}  <- against {stats['budget_ms']}ms")
    run = stats["jank_run_longest"]
    if run:
        print(f"longest stutter (>= {stats['stutter_min_frames']} frames): "
              f"{run['frames']} frames, {run['ms']}ms, "
              f"frames {run['start_index']}..{run['end_index']}, "
              f"at_s={run.get('start_s')}..{run.get('end_s')}")
    else:
        print(f"longest stutter (>= {stats['stutter_min_frames']} frames): none")
    print(f"jank runs: total={stats['jank_runs_total']} "
          f"stutter={stats['jank_runs_stutter']}")
    print("worst frames:")
    for item in stats["worst"]:
        print(f"  idx={item['index']:<7} at_s={item.get('at_s')} "
              f"{item['frame_ms']}ms over_budget={item['over_budget']}")
    if buckets:
        hot = sorted(buckets, key=lambda b: -b["dropped"])[:top_buckets]
        print("worst buckets by dropped frames:")
        for bucket in hot:
            if bucket["dropped"] == 0:
                break
            print(f"  {bucket['from_s']}..{bucket['to_s']}s frames={bucket['frames']} "
                  f"p95={bucket['p95']} p99={bucket['p99']} max={bucket['max']} "
                  f"dropped={bucket['dropped']}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Per-frame metrics from a raw dump")
    parser.add_argument("source", help="per-frame file, or a run directory")
    parser.add_argument("--budget", type=float, default=None,
                        help="vsync budget in ms; defaults to the dump's refresh period")
    parser.add_argument("--tolerance", type=float, default=DROP_TOLERANCE_MS,
                        help="slack before a frame counts as dropped (ms, default 0.5)")
    parser.add_argument("--buckets", type=float, default=0.0,
                        help="bucket width in seconds for the per-time report")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--out", default="", help="write the JSON report here")
    parser.add_argument("--stutter-min-frames", type=int, default=2)
    args = parser.parse_args(argv)

    frames, stamps, meta = parse_frame_source(read_source(args.source))
    if not frames:
        print("no frame data recognized", file=sys.stderr)
        return 2
    # Derive the budget from the series unless the caller insists: the dump's refresh
    # header is the panel's capability, not the tick the app targets.
    budget = args.budget
    stats = frame_stats(frames, budget, stamps, args.stutter_min_frames, args.tolerance)
    buckets = bucket_report(frames, stamps, args.buckets, stats["budget_ms"],
                            args.tolerance) if (args.buckets and stamps) else []
    report = {"source": args.source, "parse": meta, "stats": stats,
              "buckets": buckets}
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_report(stats, meta, buckets)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print(f"report -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
