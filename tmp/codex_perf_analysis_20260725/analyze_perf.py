import csv
import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict


NUMERIC_FIELDS = [
    "fps", "speed_multiplier", "fast_ms", "t_sus_ms", "t_render_ms", "t_ui_ms",
    "largest_slice_ms", "sus_sim_avg_300", "sus_sim_p95_300", "sus_sim_max_300",
    "continuation_frames", "continuation_slices", "continuation_country_slices",
    "continuation_economy_slices", "continuation_wall_ms",
    "continuation_max_frame_wall_ms", "continuation_max_slice_ms",
    "continuation_last_slice_ms", "continuation_budget_ms",
]


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    low = int(math.floor(position))
    high = int(math.ceil(position))
    if low == high:
        return ordered[low]
    return ordered[low] * (high - position) + ordered[high] * (position - low)


def stats(values):
    clean = [v for v in values if v is not None]
    if not clean:
        return {"count": 0, "sum": 0.0, "mean": None, "p50": None,
                "p95": None, "p99": None, "max": None}
    return {
        "count": len(clean),
        "sum": sum(clean),
        "mean": sum(clean) / len(clean),
        "p50": percentile(clean, 0.50),
        "p95": percentile(clean, 0.95),
        "p99": percentile(clean, 0.99),
        "max": max(clean),
    }


def parse_json_map(value):
    if not value:
        return {}
    try:
        parsed = json.loads(value)
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        return {}


def analyze(path, max_tick=None, speed=None):
    columns = None
    values = defaultdict(list)
    job_ms = defaultdict(list)
    largest_jobs = Counter()
    largest_stages = Counter()
    largest_substages = Counter()
    continuation_last_stages = Counter()
    continuation_last_substages = Counter()
    job_stages = defaultdict(Counter)
    job_substages = defaultdict(Counter)
    stage_counts = defaultdict(float)
    stage_wall = defaultdict(float)
    stage_row_maxima = defaultdict(list)
    substage_counts = defaultdict(float)
    substage_wall = defaultdict(float)
    substage_row_maxima = defaultdict(list)
    substage_work = defaultdict(float)
    row_count = 0
    first_timestamp = last_timestamp = None
    first_tick = last_tick = None
    skipped_days = 0
    parse_errors = 0
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        columns = reader.fieldnames or []
        dynamic_job_fields = [c for c in columns if c.startswith("j_") and c.endswith("_ms")]
        dynamic_stage_fields = [c for c in columns if c.startswith("j_") and c.endswith("_stage")]
        dynamic_substage_fields = [
            c for c in columns if c.startswith("j_") and c.endswith("_substage")]
        for row in reader:
            timestamp = number(row.get("timestamp_ms"))
            tick = number(row.get("tick_idx"))
            if max_tick is not None and tick is not None and tick > max_tick:
                continue
            row_speed = number(row.get("speed_multiplier"))
            if speed is not None and row_speed != speed:
                continue
            row_count += 1
            if timestamp is not None:
                first_timestamp = timestamp if first_timestamp is None else first_timestamp
                last_timestamp = timestamp
            if tick is not None:
                first_tick = tick if first_tick is None else first_tick
                last_tick = tick
            if str(row.get("was_skipped_day", "")).lower() == "true":
                skipped_days += 1
            for field in NUMERIC_FIELDS:
                v = number(row.get(field))
                if v is not None:
                    values[field].append(v)
            for field in dynamic_job_fields:
                v = number(row.get(field))
                if v is not None:
                    job_ms[field].append(v)
            if row.get("largest_slice_job"):
                largest_jobs[row["largest_slice_job"]] += 1
            if row.get("largest_slice_stage"):
                largest_stages[row["largest_slice_stage"]] += 1
            if row.get("largest_slice_substage"):
                largest_substages[row["largest_slice_substage"]] += 1
            if row.get("continuation_last_stage"):
                continuation_last_stages[row["continuation_last_stage"]] += 1
            if row.get("continuation_last_substage"):
                continuation_last_substages[row["continuation_last_substage"]] += 1
            for field in dynamic_stage_fields:
                if row.get(field):
                    job_stages[field][row[field]] += 1
            for field in dynamic_substage_fields:
                if row.get(field):
                    job_substages[field][row[field]] += 1
            count_map = parse_json_map(row.get("continuation_stage_counts", ""))
            wall_map = parse_json_map(row.get("continuation_stage_wall_ms", ""))
            max_map = parse_json_map(row.get("continuation_stage_max_slice_ms", ""))
            sub_count_map = parse_json_map(row.get("continuation_substage_counts", ""))
            sub_wall_map = parse_json_map(row.get("continuation_substage_wall_ms", ""))
            sub_max_map = parse_json_map(row.get("continuation_substage_max_slice_ms", ""))
            sub_work_map = parse_json_map(row.get("continuation_substage_work", ""))
            if (row.get("continuation_stage_counts") and not count_map) or (
                    row.get("continuation_stage_wall_ms") and not wall_map):
                parse_errors += 1
            for key, value in count_map.items():
                v = number(value)
                if v is not None:
                    stage_counts[key] += v
            for key, value in wall_map.items():
                v = number(value)
                if v is not None:
                    stage_wall[key] += v
            for key, value in max_map.items():
                v = number(value)
                if v is not None:
                    stage_row_maxima[key].append(v)
            for key, value in sub_count_map.items():
                v = number(value)
                if v is not None:
                    substage_counts[key] += v
            for key, value in sub_wall_map.items():
                v = number(value)
                if v is not None:
                    substage_wall[key] += v
            for key, value in sub_max_map.items():
                v = number(value)
                if v is not None:
                    substage_row_maxima[key].append(v)
            for key, value in sub_work_map.items():
                v = number(value)
                if v is not None:
                    substage_work[key] += v

    duration_s = None
    tick_delta = None
    if first_timestamp is not None and last_timestamp is not None:
        duration_s = max(0.0, (last_timestamp - first_timestamp) / 1000.0)
    if first_tick is not None and last_tick is not None:
        tick_delta = last_tick - first_tick
    throughput = tick_delta / duration_s if duration_s and tick_delta is not None else None
    stage_summary = {}
    for key in sorted(set(stage_counts) | set(stage_wall) | set(stage_row_maxima)):
        count = stage_counts.get(key, 0.0)
        wall = stage_wall.get(key, 0.0)
        stage_summary[key] = {
            "count": count,
            "total_ms": wall,
            "mean_slice_ms": wall / count if count else None,
            "row_max_p50_ms": percentile(stage_row_maxima.get(key, []), 0.50),
            "row_max_p95_ms": percentile(stage_row_maxima.get(key, []), 0.95),
            "max_slice_ms": max(stage_row_maxima.get(key, []), default=None),
        }
    substage_summary = {}
    for key in sorted(set(substage_counts) | set(substage_wall) |
                      set(substage_row_maxima) | set(substage_work)):
        count = substage_counts.get(key, 0.0)
        wall = substage_wall.get(key, 0.0)
        substage_summary[key] = {
            "count": count,
            "total_ms": wall,
            "mean_ms": wall / count if count else None,
            "row_max_p50_ms": percentile(substage_row_maxima.get(key, []), 0.50),
            "row_max_p95_ms": percentile(substage_row_maxima.get(key, []), 0.95),
            "max_ms": max(substage_row_maxima.get(key, []), default=None),
            "work": substage_work.get(key, 0.0),
        }
    job_summary = {key: stats(vals) for key, vals in job_ms.items() if vals}
    top_jobs = sorted(job_summary.items(), key=lambda item: (
        item[1]["p95"] or 0.0, item[1]["mean"] or 0.0), reverse=True)[:20]
    return {
        "file": os.path.basename(path),
        "bytes": os.path.getsize(path),
        "columns": len(columns),
        "rows": row_count,
        "duration_s": duration_s,
        "first_tick": first_tick,
        "last_tick": last_tick,
        "tick_delta": tick_delta,
        "ticks_per_second": throughput,
        "skipped_days": skipped_days,
        "json_parse_errors": parse_errors,
        "metrics": {field: stats(vals) for field, vals in values.items()},
        "largest_jobs": largest_jobs.most_common(12),
        "largest_stages": largest_stages.most_common(12),
        "largest_substages": largest_substages.most_common(12),
        "continuation_last_stages": continuation_last_stages.most_common(12),
        "continuation_last_substages": continuation_last_substages.most_common(12),
        "job_stages": {key: value.most_common(12) for key, value in job_stages.items()},
        "job_substages": {
            key: value.most_common(12) for key, value in job_substages.items()},
        "stages": stage_summary,
        "substages": substage_summary,
        "top_job_ms": top_jobs,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+")
    parser.add_argument("--output")
    parser.add_argument("--max-tick", type=float)
    parser.add_argument("--speed", type=float)
    args = parser.parse_args()
    reports = [analyze(path, max_tick=args.max_tick, speed=args.speed) for path in args.paths]
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(reports, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
    else:
        json.dump(reports, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
