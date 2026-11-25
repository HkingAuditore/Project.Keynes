#!/usr/bin/env python3
"""Summarize a Project.Keynes on-device performance run directory.

Usage:
    python tools/perf/analyze_android_perf.py <run_dir> [<run_dir> ...] [--outdir DIR] [--no-charts]

A run directory is what tools/android_perf_run.ps1 produces:
    perf_<label>.csv      PerfRecorder wide table (one row per simulated day)
    logcat.txt            full device log ([heartbeat] / [clock/rate] / errors)
    samples.log           periodic `top -H` / meminfo / thermal snapshots
    meminfo_end.txt thermalservice_end.txt battery_end.txt gfxinfo_end.txt
    run_meta.json         label / query / render overrides / done reason
    screenshots/*.png

Outputs (into the run dir, or --outdir):
    summary.json          machine-readable digest
    charts/*.png          fps, day cost, subsystem breakdown, CPU threads

Notes on the device CSV schema
------------------------------
On a real phone the daily graph runs on the native worker, so the SUS columns
(`t_sus_ms`, `j_*`, `sus_sim_*`) stay empty -- SUS is not what simulates there.
The per-day truth lives in `fast_ms` plus the `runtime_graph_*` worker timings.
Frame rate comes from the `[heartbeat]` lines (every ~5 s) and the per-day `fps`
snapshot; neither is a per-frame trace, so treat percentiles as windowed means.
"""
import argparse
import csv
import datetime
import json
import math
import os
import re
import statistics
import sys

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAVE_MPL = True
except Exception:  # pragma: no cover - charts are optional
    HAVE_MPL = False

# Sibling module: per-frame metrics. Imported by path because this script is
# normally run as `python tools/perf/analyze_android_perf.py` from anywhere.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import frame_metrics
    HAVE_FRAME_METRICS = True
except Exception:  # pragma: no cover - the per-frame module is shipped with this one
    frame_metrics = None
    HAVE_FRAME_METRICS = False


# ── helpers ────────────────────────────────────────────────────────────────
def as_float(value):
    if value is None:
        return None
    text = str(value).strip().replace("ms", "").replace("%", "").replace("d/f", "")
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if math.isnan(number) or math.isinf(number):
        return None
    return number


def pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def stats(values, digits=3):
    vals = [v for v in values if v is not None]
    if not vals:
        return {"n": 0}
    return {
        "n": len(vals),
        "mean": round(statistics.fmean(vals), digits),
        "p5": round(pct(vals, 0.05), digits),
        "p50": round(pct(vals, 0.50), digits),
        "p95": round(pct(vals, 0.95), digits),
        "min": round(min(vals), digits),
        "max": round(max(vals), digits),
    }


def find_csv(run_dir, meta):
    names = [n for n in os.listdir(run_dir)
             if n.lower().endswith(".csv")
             and not n.lower().startswith("render_trace")
             and n.lower() not in {p.lower() for p in FRAME_DUMP_PRIORITY}]
    if not names:
        return None
    if meta:
        for name in meta.get("csv_files") or []:
            base = os.path.basename(str(name))
            if base in names:
                return os.path.join(run_dir, base)
    names.sort(key=lambda n: os.path.getsize(os.path.join(run_dir, n)), reverse=True)
    for name in names:
        path = os.path.join(run_dir, name)
        if looks_like_perf_csv(path):
            return path
    return None


def looks_like_perf_csv(path):
    """Guard against a stray CSV (a frame dump, a trace export) being read as the
    PerfRecorder wide table: its header is the only cheap proof of identity."""
    try:
        with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
            header = handle.readline()
    except OSError:
        return False
    return any(key in header for key in ("fps", "fast_ms", "timestamp_ms", "runtime_graph_"))


# ── perf CSV ───────────────────────────────────────────────────────────────
# Only timing-ish runtime_graph fields; hashes/counters/masks are excluded on
# purpose -- they are 64-bit digests and would dominate any "largest" ranking.
GRAPH_TIMINGS = [
    "worker_time_execute_us",
    "worker_time_total_us",
    "worker_time_overhead_us",
    "worker_time_boundary_wait_us",
    "worker_time_input_wait_us",
    "climate_pod_plan_ms",
    "climate_stage_ms",
    "economy_epoch_fiscal_ms",
    "economy_fiscal_settlement_ms",
    "economy_income_subsidy_ms",
    "snapshot_staleness_ms",
    "visual_apply_ms",
    "gpu_upload_ms",
    "post_pulse_flush_ms",
    "event_dispatch_ms",
    "country_territory_sync_ms",
]

BD_DENY = ("hash", "digest", "bytes", "_at_us", "mask", "count", "units", "generation",
           "state", "_id", "index", "worker_time", "latency", "serve_us", "storage", "slab")


def bd_is_timing(name):
    if not name.endswith(("_ms", "_us")):
        return False
    return not any(token in name for token in BD_DENY)


def parse_perf_csv(path):
    rows = []
    with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(row)
    if not rows:
        return {"rows": 0}

    columns = list(rows[0].keys())

    def series(name):
        return [as_float(r.get(name)) for r in rows]

    frame = {}
    for name in ["fps", "fast_ms", "speed_multiplier", "t_sus_ms", "t_render_ms", "t_ui_ms"]:
        if name in columns:
            frame[name] = stats(series(name))

    graph = {}
    for name in GRAPH_TIMINGS:
        col = "runtime_graph_" + name
        if col in columns:
            st = stats(series(col))
            if st.get("n") and st.get("mean", 0) > 0:
                graph[name] = st

    bd_costs = []
    for col in columns:
        if not col.startswith("bd_"):
            continue
        short = col[len("bd_"):]
        if not bd_is_timing(short):
            continue
        st = stats(series(col))
        if st.get("n") and st.get("mean", 0) > 0:
            bd_costs.append({"key": short, "mean_ms": st["mean"], "p95_ms": st["p95"],
                             "max_ms": st["max"]})
    bd_costs.sort(key=lambda d: d["mean_ms"], reverse=True)

    fps_values = [v for v in series("fps") if v is not None]
    ts_values = [v for v in series("timestamp_ms") if v is not None]
    elapsed_s = round((ts_values[-1] - ts_values[0]) / 1000.0, 2) if len(ts_values) >= 2 else None
    days = [as_float(r.get("runtime_graph_simulation_committed_day")) for r in rows]
    days = [d for d in days if d is not None]

    return {
        "csv": path,
        "rows": len(rows),
        "columns": len(columns),
        "window_s": elapsed_s,
        "day_first": days[0] if days else None,
        "day_last": days[-1] if days else None,
        "skipped_rows": sum(1 for r in rows
                            if str(r.get("was_skipped_day", "")).strip().lower() == "true"),
        "frame": frame,
        "frame_ms": stats([1000.0 / v for v in fps_values if v > 0]),
        "graph_timings": graph,
        "breakdown_costs": bd_costs[:20],
        "series": {
            "fps": fps_values,
            "fast_ms": [v for v in series("fast_ms")],
        },
        "sus_instrumented": bool(frame.get("fps") and (frame.get("t_sus_ms", {}).get("max") or 0) > 0),
    }


# ── logcat ─────────────────────────────────────────────────────────────────
HEARTBEAT_RE = re.compile(r"\[heartbeat\](.*)")
CLOCK_RATE_RE = re.compile(r"\[clock/rate\](.*)")
# `adb logcat -v time` prefixes every line with `MM-DD HH:MM:SS.mmm`; that is the
# only wall-clock anchor in the run directory, so keep it instead of dropping it.
LOGCAT_TIME_RE = re.compile(r"^\s*(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s")


def logcat_seconds(line):
    """Seconds-of-day for a `-v time` logcat line, or None when it has no stamp."""
    match = LOGCAT_TIME_RE.match(line)
    if not match:
        return None
    hour, minute, second, milli = (int(match.group(i)) for i in (3, 4, 5, 6))
    return hour * 3600.0 + minute * 60.0 + second + milli / 1000.0


def parse_kv(text):
    out = {}
    for token in text.strip().split():
        if "=" in token:
            key, value = token.split("=", 1)
            out[key] = value
    return out


def parse_render_trace(path):
    """render_trace_*.csv: one row per frame, with a segment label per sweep step."""
    rows = []
    with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        for row in csv.DictReader(handle):
            rows.append(row)
    if not rows:
        return {"rows": 0}
    segs, order = {}, []
    for row in rows:
        seg = (row.get("seg") or "").strip()
        if seg not in segs:
            segs[seg] = []
            order.append(seg)
        segs[seg].append(row)

    def col(group, key):
        return [as_float(r.get(key)) for r in group if as_float(r.get(key)) is not None]

    segments = []
    for seg in order:
        group = segs[seg]
        segments.append({
            "seg": seg,
            "samples": len(group),
            "fps": stats(col(group, "fps")),
            "frame_ms": stats(col(group, "frame_ms")),
            "setup_cpu_ms": stats(col(group, "setup_cpu_ms")),
            "draw_calls": stats(col(group, "draw_calls")),
            "primitives": stats(col(group, "primitives")),
            "objects": stats(col(group, "objects")),
        })

    baseline = next((s for s in segments if s["seg"] == "baseline"), None)
    base_ms = (baseline["frame_ms"].get("mean") or 0.0) if baseline else 0.0
    # solo 扫描（only_*）以"全关(none)"为空载地板：模块自身成本 = 该段帧时间 − 地板。
    floor = next((s for s in segments if s["seg"] in ("none", "floor_fog")), None)
    floor_ms = (floor["frame_ms"].get("mean") or 0.0) if floor else 0.0
    for seg in segments:
        frame_ms = seg["frame_ms"].get("mean") or 0.0
        if baseline:
            seg["delta_ms_vs_baseline"] = round(base_ms - frame_ms, 2)
            seg["share_of_frame_pct"] = round(100.0 * (base_ms - frame_ms) / base_ms, 1) if base_ms > 0 else None
        if seg["seg"].startswith(("only_", "fog_")) and seg["seg"] != "floor_fog":
            module_ms = max(0.0, frame_ms - floor_ms)
            seg["module_ms"] = round(module_ms, 2)
            seg["module_share_pct"] = round(100.0 * module_ms / base_ms, 1) if base_ms > 0 else None
    return {"rows": len(rows), "segments": segments, "csv": path}


def parse_logcat(path):
    if not os.path.exists(path):
        return {}
    heartbeats, rates = [], []
    counts = {"script_error": 0, "shader_error": 0, "stall": 0, "fatal": 0,
              "warning": 0, "economy_stall": 0}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "[heartbeat]" in line:
                match = HEARTBEAT_RE.search(line)
                if match:
                    heartbeats.append(parse_kv(match.group(1)))
            elif "[clock/rate]" in line:
                match = CLOCK_RATE_RE.search(line)
                if match:
                    rates.append(parse_kv(match.group(1)))
            if "SCRIPT ERROR" in line:
                counts["script_error"] += 1
            if "SHADER ERROR" in line:
                counts["shader_error"] += 1
            if "[stall]" in line:
                counts["stall"] += 1
            if "Fatal signal" in line or "FATAL EXCEPTION" in line:
                counts["fatal"] += 1
            if "[economy-stall]" in line:
                counts["economy_stall"] += 1
            if "WARNING" in line:
                counts["warning"] += 1

    def series(key):
        return [as_float(h.get(key)) for h in heartbeats]

    live = [h for h in heartbeats if (as_float(h.get("day")) or 0) >= 1] or heartbeats

    return {
        "heartbeat": {
            "count": len(heartbeats),
            "live_count": len(live),
            "fps": stats([as_float(h.get("fps")) for h in live]),
            "day_first": series("day")[0] if heartbeats else None,
            "day_last": series("day")[-1] if heartbeats else None,
            "last": heartbeats[-1] if heartbeats else {},
        },
        "clock_rate": {
            "count": len(rates),
            "dps": stats([as_float(r.get("dps")) for r in rates]),
            "cost_ms": stats([as_float(r.get("cost")) for r in rates]),
            "fps": stats([as_float(r.get("fps")) for r in rates]),
            "last": rates[-1] if rates else {},
        },
        "counts": counts,
    }


# ── top -H / meminfo / thermal samples ─────────────────────────────────────
THREAD_RE = re.compile(
    r"^\s*(\d+)\s+\S+\s+-?\d+\s+-?\d+\s+\S+\s+\S+\s+\S+\s+\S\s+([\d.]+)\s+[\d.]+\s+\S+\s+(.+?)\s+com\.projectkeynes\.game\s*$")
MEM_RE = re.compile(r"^\s*(TOTAL PSS|TOTAL RSS|Native Heap|Java Heap|Graphics|GL mtrack)\s*:?\s*(\d+)")
TEMP_RE = re.compile(r"Temperature\{[^}]*mValue=([\d.]+)")


def parse_samples(path):
    if not os.path.exists(path):
        return {}
    thread_cpu = {}
    samples = 0
    mem_points = []
    temps = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        in_cpu_block = False
        current = {}
        for line in handle:
            if "cpu sample" in line:
                if current:
                    samples += 1
                    for name, cpu in current.items():
                        thread_cpu.setdefault(name, []).append(cpu)
                current = {}
                in_cpu_block = True
                continue
            if in_cpu_block:
                match = THREAD_RE.match(line)
                if match:
                    cpu = as_float(match.group(2))
                    name = re.sub(r"\s+\d+$", "", match.group(3)).strip()
                    if cpu is not None:
                        current[name] = max(current.get(name, 0.0), cpu)
                    continue
                if line.strip().startswith("["):
                    in_cpu_block = False
            match = MEM_RE.match(line)
            if match:
                mem_points.append({"key": match.group(1), "kb": int(match.group(2))})
            temp = TEMP_RE.search(line)
            if temp:
                temps.append(as_float(temp.group(1)))
        if current:
            samples += 1
            for name, cpu in current.items():
                thread_cpu.setdefault(name, []).append(cpu)

    threads = []
    for name, values in thread_cpu.items():
        entry = stats(values)
        entry["thread"] = name
        threads.append(entry)
    threads.sort(key=lambda d: d.get("mean", 0), reverse=True)

    def mem(key):
        vals = [m["kb"] for m in mem_points if m["key"] == key]
        return {"start_kb": vals[0] if vals else None,
                "max_kb": max(vals) if vals else None,
                "end_kb": vals[-1] if vals else None}

    return {
        "cpu_samples": samples,
        "threads": threads[:16],
        "memory": {"total_pss": mem("TOTAL PSS"), "native_heap": mem("Native Heap"),
                   "graphics": mem("Graphics")},
        "temperature_c": stats(temps, 1),
    }


def parse_battery_dump(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return {}
    temp = re.search(r"temperature:\s*(\d+)", text)
    level = re.search(r"level:\s*(\d+)", text)
    return {"temperature_c": (int(temp.group(1)) / 10.0) if temp else None,
            "level_pct": int(level.group(1)) if level else None}


def parse_thermal_dump(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return {}
    status = re.search(r"mStatus=(\d+)", text)
    temps = [as_float(t) for t in re.findall(r"mValue=([\d.]+)", text)]
    temps = [t for t in temps if t is not None]
    return {"status": int(status.group(1)) if status else None,
            "max_c": round(max(temps), 1) if temps else None}


# ── charts ─────────────────────────────────────────────────────────────────
def setup_fonts():
    if not HAVE_MPL:
        return
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    plt.rcParams["figure.dpi"] = 130
    plt.rcParams["axes.grid"] = True
    plt.rcParams["grid.alpha"] = 0.25
    plt.rcParams["axes.spines.top"] = False
    plt.rcParams["axes.spines.right"] = False


def save_fig(fig, path):
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)


def chart_run(run_dir, digest, label):
    if not HAVE_MPL:
        return []
    chart_dir = os.path.join(run_dir, "charts")
    os.makedirs(chart_dir, exist_ok=True)
    produced = []
    series = (digest.get("perf", {}).get("series") or {})
    fps = [v for v in series.get("fps") or [] if v]
    fast = [v for v in series.get("fast_ms") or [] if v is not None]

    if fps:
        fig, ax = plt.subplots(figsize=(10, 3.0))
        ax.plot(range(len(fps)), fps, color="#2f6f9f", linewidth=1.0, label="fps (per day)")
        ax.axhline(statistics.median(fps), color="#b4462f", linestyle="--", linewidth=1.2,
                   label=f"median {statistics.median(fps):.0f}")
        ax.set_xlabel("sampled day")
        ax.set_ylabel("fps")
        ax.set_title(f"{label} — fps snapshot at each simulated day")
        ax.legend(loc="lower right", fontsize=8)
        path = os.path.join(chart_dir, "fps_timeline.png")
        save_fig(fig, path); produced.append(path)

    if fast:
        fig, ax = plt.subplots(figsize=(10, 3.0))
        ax.plot(range(len(fast)), fast, color="#3f8f5f", linewidth=1.0, label="fast_ms (day cost)")
        p95 = pct(fast, 0.95)
        ax.axhline(p95, color="#b4462f", linestyle="--", linewidth=1.2, label=f"p95 {p95:.0f}ms")
        ax.set_xlabel("sampled day")
        ax.set_ylabel("ms")
        ax.set_title(f"{label} — per-day fast tick cost")
        ax.legend(loc="upper right", fontsize=8)
        path = os.path.join(chart_dir, "day_cost.png")
        save_fig(fig, path); produced.append(path)

    heartbeat_series = digest.get("heartbeat_series") or []
    if heartbeat_series:
        fig, ax = plt.subplots(figsize=(10, 3.0))
        ax.plot(range(len(heartbeat_series)), heartbeat_series, color="#8a6fb0", marker="o",
                markersize=2.5, linewidth=1.0, label="fps (5s heartbeat)")
        ax.axhline(statistics.median(heartbeat_series), color="#b4462f", linestyle="--",
                   linewidth=1.1,
                   label=f"median {statistics.median(heartbeat_series):.1f}")
        ax.set_xlabel("heartbeat sample (~5 s)")
        ax.set_ylabel("fps")
        ax.set_title(f"{label} — device frame rate over the run")
        ax.legend(loc="lower right", fontsize=8)
        path = os.path.join(chart_dir, "heartbeat_fps.png")
        save_fig(fig, path); produced.append(path)

        fig, ax = plt.subplots(figsize=(7, 3.0))
        frame_ms = [1000.0 / v for v in heartbeat_series if v > 0]
        ax.hist(frame_ms, bins=min(30, max(6, len(frame_ms) // 2)), color="#2f6f9f", alpha=0.85)
        for value, text in [(1000 / 60, "60fps"), (1000 / 30, "30fps"), (1000 / 20, "20fps")]:
            ax.axvline(value, color="#b4462f", linestyle="--", linewidth=1.0)
            ax.annotate(text, (value, ax.get_ylim()[1] * 0.9), fontsize=7, color="#b4462f")
        ax.set_xlabel("mean frame time per 5 s window (ms)")
        ax.set_ylabel("windows")
        ax.set_title(f"{label} — frame time distribution")
        path = os.path.join(chart_dir, "frame_hist.png")
        save_fig(fig, path); produced.append(path)

    trace = digest.get("render_trace") or {}
    segments = [s for s in (trace.get("segments") or []) if s["seg"] not in ("after_sweep",)]
    if segments:
        labels = [s["seg"] for s in segments]
        frames = [s["frame_ms"].get("mean") or 0 for s in segments]
        deltas = [s.get("delta_ms_vs_baseline") or 0 for s in segments]
        draws = [s["draw_calls"].get("mean") or 0 for s in segments]
        fig, axes = plt.subplots(1, 3, figsize=(15, 3.4))
        axes[0].bar(range(len(labels)), frames, color="#2f6f9f")
        axes[0].set_title("mean frame time (ms)")
        axes[1].bar(range(len(labels)), deltas, color="#b4462f")
        axes[1].set_title("cost vs baseline (ms)")
        axes[2].bar(range(len(labels)), draws, color="#3f8f5f")
        axes[2].set_title("draw calls")
        for ax in axes:
            ax.set_xticks(range(len(labels)))
            ax.set_xticklabels(labels, rotation=35, ha="right", fontsize=7)
        fig.suptitle(f"{label} - render layer sweep", fontsize=10)
        path = os.path.join(chart_dir, "render_segments.png")
        save_fig(fig, path); produced.append(path)

    bds = (digest.get("perf", {}).get("breakdown_costs") or [])[:12]
    if bds:
        fig, ax = plt.subplots(figsize=(8, 0.32 * len(bds) + 1.2))
        names = [b["key"] for b in bds][::-1]
        means = [b["mean_ms"] for b in bds][::-1]
        ax.barh(names, means, color="#8a6fb0")
        ax.set_xlabel("mean ms per day")
        ax.set_title(f"{label} — subsystem breakdown (ms-valued bd_* columns)")
        path = os.path.join(chart_dir, "top_breakdowns.png")
        save_fig(fig, path); produced.append(path)

    threads = (digest.get("samples", {}).get("threads") or [])[:10]
    if threads:
        fig, ax = plt.subplots(figsize=(8, 0.32 * len(threads) + 1.2))
        names = [t["thread"] for t in threads][::-1]
        means = [t.get("mean", 0) for t in threads][::-1]
        maxes = [t.get("max", 0) for t in threads][::-1]
        ax.barh(names, maxes, color="#d9c7a8", label="max %CPU")
        ax.barh(names, means, color="#b4462f", label="mean %CPU")
        ax.set_xlabel("% CPU (one core = 100%)")
        ax.set_title(f"{label} — device CPU per thread (top -H)")
        ax.legend(loc="lower right", fontsize=8)
        path = os.path.join(chart_dir, "cpu_threads.png")
        save_fig(fig, path); produced.append(path)

    return produced


def chart_compare(digests, outdir):
    if not HAVE_MPL or len(digests) < 2:
        return None
    labels = [d["meta"].get("label", os.path.basename(d["dir"])) for d in digests]
    hb = [(d.get("logcat", {}).get("heartbeat", {}) or {}).get("fps", {}) for d in digests]
    csv_fps = [(d.get("perf", {}).get("frame", {}) or {}).get("fps", {}) for d in digests]
    fast = [(d.get("perf", {}).get("frame", {}) or {}).get("fast_ms", {}) for d in digests]
    dps = [(d.get("logcat", {}).get("clock_rate", {}) or {}).get("dps", {}) for d in digests]

    panels = [
        ("heartbeat fps median", [h.get("p50") or 0 for h in hb]),
        ("heartbeat fps p5", [h.get("p5") or 0 for h in hb]),
        ("fast_ms p95", [f.get("p95") or 0 for f in fast]),
        ("days / second", [d.get("mean") or 0 for d in dps]),
    ]
    fig, axes = plt.subplots(1, len(panels), figsize=(15, 3.2))
    for ax, (title, values) in zip(axes, panels):
        ax.bar(range(len(labels)), values, color="#2f6f9f")
        ax.set_xticks(range(len(labels)))
        ax.set_xticklabels(labels, rotation=20, ha="right", fontsize=8)
        ax.set_title(title)
    path = os.path.join(outdir, "charts", "compare_runs.png")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    save_fig(fig, path)
    return path


# ── driver ─────────────────────────────────────────────────────────────────
def analyze(run_dir):
    meta = {}
    meta_path = os.path.join(run_dir, "run_meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, "r", encoding="utf-8-sig") as handle:
            meta = json.load(handle)
    csv_path = find_csv(run_dir, meta)
    perf = parse_perf_csv(csv_path) if csv_path else {"rows": 0}
    logcat = parse_logcat(os.path.join(run_dir, "logcat.txt"))
    digest = {
        "dir": run_dir,
        "meta": meta,
        "perf": perf,
        "logcat": logcat,
        "samples": parse_samples(os.path.join(run_dir, "samples.log")),
        "thermal": parse_thermal_dump(os.path.join(run_dir, "thermalservice_end.txt")),
        "battery": parse_battery_dump(os.path.join(run_dir, "battery_end.txt")),
    }
    trace = next((os.path.join(run_dir, n) for n in sorted(os.listdir(run_dir))
                  if n.lower().startswith("render_trace") and n.lower().endswith(".csv")), None)
    if trace:
        digest["render_trace"] = parse_render_trace(trace)
    return digest


def _stamped_kv(path, marker, pattern):
    """Yield (wall_seconds, kv) for `marker` lines in a `-v time` logcat.

    wall_seconds is None when the line carries no timestamp. Midnight rollover is
    folded into a day offset instead of producing a negative gap.
    """
    if not os.path.exists(path):
        return
    day_offset = 0.0
    previous = None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if marker not in line:
                continue
            match = pattern.search(line)
            if not match:
                continue
            stamp = logcat_seconds(line)
            wall = None
            if stamp is not None:
                if previous is not None and stamp + day_offset < previous - 3600.0:
                    day_offset += 86400.0
                wall = stamp + day_offset
                previous = wall
            yield wall, parse_kv(match.group(1))


def _relative(wall, first):
    return round(wall - first, 3) if (wall is not None and first is not None) else None


def heartbeat_timeline(run_dir):
    """Every `[heartbeat]` line as {t_s, wall, day, fps, stalls}, time-sorted.

    t_s is seconds since the first heartbeat, taken from the logcat `-v time`
    prefix. Without a timestamp t_s is None, so a caller can tell "unknown" apart
    from "at zero".
    """
    entries = []
    first = None
    for wall, fields in _stamped_kv(os.path.join(run_dir, "logcat.txt"),
                                    "[heartbeat]", HEARTBEAT_RE):
        if first is None:
            first = wall
        entries.append({
            "t_s": _relative(wall, first),
            "wall": wall,
            "day": as_float(fields.get("day")),
            "fps": as_float(fields.get("fps")),
            "speed": as_float(fields.get("speed")),
            "stalls": as_float(fields.get("stalls")),
        })
    return entries


def speed_profile(timeline):
    """Simulation speed over the run -- a second load variable that must be declared.

    A run that spends most of its window at 10x is a soak, not normal play, and its
    frame times are not comparable with a 1x run. Detected from the heartbeat's own
    `speed=` field, so the conclusion cannot silently describe a soak as gameplay.
    """
    stamped = [e for e in timeline
               if e.get("speed") is not None and e.get("t_s") is not None]
    if not stamped:
        return {"values": [], "changes": [], "dominant": None, "share_dominant": None}
    values = sorted({e["speed"] for e in stamped})
    changes = []
    for previous, current in zip(stamped, stamped[1:]):
        if current["speed"] != previous["speed"]:
            changes.append({"at_s": current["t_s"], "from": previous["speed"],
                            "to": current["speed"]})
    dominant = max(values, key=lambda v: sum(1 for e in stamped if e["speed"] == v))
    share = sum(1 for e in stamped if e["speed"] == dominant) / len(stamped)
    return {"values": values, "changes": changes, "dominant": dominant,
            "share_dominant": round(100.0 * share, 1),
            "heartbeats": len(stamped)}


def clock_timeline(run_dir):
    """`[clock/rate]` every ~2 s (world_clock.gd:515) with its wall-clock time.

    This is the clock half of the throttle question: `cost` is the day-loop cost
    in ms, `cap` the throughput cap the engine applied, `dps` days/second. A
    thermal throttle shows up here as cost rising and dps falling.
    """
    entries = []
    first = None
    for wall, fields in _stamped_kv(os.path.join(run_dir, "logcat.txt"),
                                    "[clock/rate]", CLOCK_RATE_RE):
        if first is None:
            first = wall
        entries.append({
            "t_s": _relative(wall, first),
            "wall": wall,
            "dps": as_float(fields.get("dps")),
            "speed": as_float(fields.get("speed")),
            "cap": as_float(fields.get("cap")),
            "cost_ms": as_float(fields.get("cost")),
            "fps": as_float(fields.get("fps")),
            "blocked": as_float(fields.get("blocked")),
            "budget_break": as_float(fields.get("budget_break")),
        })
    return entries



def heartbeat_series_of(run_dir):
    """Heartbeat fps values (day >= 1 only) for the charts; see heartbeat_timeline."""
    return [entry["fps"] for entry in heartbeat_timeline(run_dir)
            if entry["fps"] is not None and (entry["day"] is None or entry["day"] >= 1)]


def heartbeat_gaps(timeline, expected_s=5.0, factor=2.0):
    """Gaps between heartbeats, which are themselves a stall signal.

    The heartbeat fires when ~5 s of engine time have passed, so a blocked main
    thread delays the print by however long it was blocked: a 20 s gap is a ~20 s
    freeze, located to the second. That is the only stall evidence the raw data
    carries besides `[stall]` lines.
    """
    stamped = [e for e in timeline if e["t_s"] is not None]
    if len(stamped) < 2:
        return {"windows": len(stamped), "max_gap_s": None, "max_gap_at_s": None,
                "threshold_s": expected_s * factor, "long_gaps": []}
    long_gaps = []
    worst = None
    for previous, current in zip(stamped, stamped[1:]):
        gap = current["t_s"] - previous["t_s"]
        if worst is None or gap > worst["gap_s"]:
            worst = {"gap_s": round(gap, 2), "at_s": previous["t_s"],
                     "next_at_s": current["t_s"], "day": previous["day"],
                     "fps_before": previous["fps"]}
        if gap > expected_s * factor:
            long_gaps.append({"gap_s": round(gap, 2), "at_s": previous["t_s"],
                              "day": previous["day"], "fps_before": previous["fps"]})
    return {
        "windows": len(stamped),
        "max_gap_s": worst["gap_s"] if worst else None,
        "max_gap_at_s": worst["at_s"] if worst else None,
        "max_gap_day": worst["day"] if worst else None,
        "threshold_s": expected_s * factor,
        "long_gaps": long_gaps[:10],
    }


def slowest_windows(timeline, top=3):
    """The worst heartbeat windows (lowest fps) with their time, day and stall count."""
    live = [e for e in timeline
            if e["fps"] is not None and (e["day"] is None or e["day"] >= 1)]
    ranked = sorted(live, key=lambda e: e["fps"])[:max(0, top)]
    return [{"t_s": e["t_s"], "day": e["day"], "fps": e["fps"], "stalls": e["stalls"]}
            for e in ranked]


# ── samples.log / thermalservice timeline ──────────────────────────────────
SAMPLE_STAMP_RE = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\]\s?(.*)$")
THERMAL_STATUS_RE = re.compile(r"(?:mThermalStatus|Thermal Status|mStatus)\s*[:=]\s*(-?\d+)")
BATTERY_TEXT_RE = re.compile(r"(?:battery temp[^:]*:|temperature:)\s*([\d.]+)")
GUARD_TRIP_RE = re.compile(r"tripped at\s*([\d.]+)\s*C")


def parse_sample_timeline(path):
    """samples.log -> timed sample blocks.

    `Add-Sample` (android_perf_run.ps1:89-92) prefixes a sample with `[HH:mm:ss]`,
    and a multi-line sample (top -H, meminfo, thermalservice) is written as one
    value, so ONLY the first line of a block carries the stamp; the rest of the
    block inherits it. That inherited time is what makes a thermal reading
    placeable on the same axis as fps.
    """
    if not os.path.exists(path):
        return []
    events = []
    current = None
    temps = []
    day_offset = 0.0
    previous = None
    first = None

    def close():
        if current is None:
            return
        if temps:
            current["max_c"] = round(max(temps), 1)
        events.append(current)

    with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\r\n")
            match = SAMPLE_STAMP_RE.match(line)
            if match:
                close()
                temps = []
                hour, minute, second = (int(match.group(i)) for i in (1, 2, 3))
                stamp = hour * 3600.0 + minute * 60.0 + second
                if previous is not None and stamp + day_offset < previous - 3600.0:
                    day_offset += 86400.0
                wall = stamp + day_offset
                previous = wall
                if first is None:
                    first = wall
                text = match.group(4).strip()
                current = {"t_s": round(wall - first, 3), "wall": wall,
                           "kind": text.split()[0] if text else "",
                           "status": None, "max_c": None, "battery_c": None,
                           "text": text[:120]}
                body = match.group(4)
            else:
                if current is None:
                    continue
                body = line
            status = THERMAL_STATUS_RE.search(body)
            if status and current["status"] is None:
                current["status"] = int(status.group(1))
            temps.extend(as_float(value) for value in re.findall(r"mValue=([\d.]+)", body)
                         if as_float(value) is not None)
            battery = BATTERY_TEXT_RE.search(body)
            if battery:
                value = as_float(battery.group(1))
                if value is not None:
                    current["battery_c"] = round(value / 10.0 if value > 100 else value, 1)
            tripped = GUARD_TRIP_RE.search(body)
            if tripped:
                current["battery_c"] = as_float(tripped.group(1))
                current["kind"] = "thermal_guard"
    close()
    return events


def thermal_steps(events, throttle_status=1):
    """Status transitions from the sample timeline, with honest coverage numbers.

    `coverage_s` and `points` are reported on purpose: android_perf_run.ps1:236-238
    only samples thermalservice when sampleIdx is 2, 6 or 10, so a long run may
    carry three readings in its first minute and nothing after. A verdict that
    ignores that gap would over-claim.
    """
    series = [e for e in events if e["status"] is not None]
    transitions = []
    previous = None
    for event in series:
        if previous is None or event["status"] != previous:
            transitions.append({"t_s": event["t_s"], "status": event["status"],
                                "from": previous, "max_c": event["max_c"],
                                "battery_c": event["battery_c"], "reason": "status"})
            previous = event["status"]
    onset = next((t for t in transitions if t["status"] >= throttle_status), None)
    span = round(series[-1]["t_s"] - series[0]["t_s"], 1) if len(series) >= 2 else 0.0
    return {
        "points": len(series),
        "coverage_s": span,
        "first_t_s": series[0]["t_s"] if series else None,
        "last_t_s": series[-1]["t_s"] if series else None,
        "max_status": max((e["status"] for e in series), default=None),
        "transitions": transitions,
        "onset": onset,
        "throttled": bool(onset),
    }


def window_mean(series, key, center_s, window_s):
    """Mean of `key` over [center-window, center+window); None when nothing lands."""
    if center_s is None:
        return None
    values = [entry[key] for entry in series
              if entry.get(key) is not None and entry.get("t_s") is not None
              and center_s - window_s <= entry["t_s"] < center_s + window_s]
    return round(statistics.fmean(values), 2) if values else None


def thermal_coverage(steps, heartbeat):
    """How much of the run the thermal timeline covers, so a gap cannot be hidden.

    A run whose thermal readings stop in the first minute cannot support any
    statement about throttling later in that run; `uncovered_s` is what the report
    must show instead of a silent "no throttle seen".
    """
    run_span = next((e["t_s"] for e in reversed(heartbeat)
                     if e["t_s"] is not None), None)
    last = steps.get("last_t_s")
    steps["run_span_s"] = run_span
    steps["uncovered_s"] = (round(run_span - last, 1)
                            if run_span is not None and last is not None else None)
    return steps


def correlate_throttle(steps, heartbeat, clock, window_s=20.0):
    """For each thermal step, fps and day cost before vs after -- same device, same run.

    This is the only controlled comparison a throttle report is allowed to make:
    the two halves come from one continuous run, so package, scene and device are
    identical by construction and the only variable is the thermal state.
    """
    rows = []
    for step in steps.get("transitions") or []:
        at = step["t_s"]
        if at is None:
            continue
        half = window_s / 2.0
        window = step.get("window") or {}
        before_end = window.get("from_t_s")
        after_start = window.get("to_t_s")
        before_center = (before_end if before_end is not None else at) - half
        after_center = (after_start if after_start is not None else at) + half
        rows.append({
            "t_s": at,
            "window": window or None,
            "from": step["from"],
            "to": step["status"],
            "max_c": step["max_c"],
            "battery_c": step["battery_c"],
            "fps_before": window_mean(heartbeat, "fps", before_center, half),
            "fps_after": window_mean(heartbeat, "fps", after_center, half),
            "cost_before_ms": window_mean(clock, "cost_ms", before_center, half),
            "cost_after_ms": window_mean(clock, "cost_ms", after_center, half),
            "dps_before": window_mean(clock, "dps", before_center, half),
            "dps_after": window_mean(clock, "dps", after_center, half),
            "window_s": window_s,
        })
    return rows




# ── perfetto thermal CSV ───────────────────────────────────────────────────
# Contract (fixed by the group, produced by 实机 outside the repo):
#   <run_dir>/thermal_timeline.csv , header `ts_ms,cpu_freq_khz,thermal_status`,
#   ascending, >= 1 s granularity, ts_ms in CLOCK_REALTIME (wall clock).
THERMAL_CSV_NAME = "thermal_timeline.csv"


def _pc_utc_offset_s():
    return datetime.datetime.now().astimezone().utcoffset().total_seconds()


def parse_thermal_csv(path):
    """thermal_timeline.csv -> (rows, meta).

    Column names are sniffed (ts/ts_ms/ts_ns, cpu_freq_khz/mhz/ghz, thermal_status)
    and a per-core `cpu` column is aggregated with max across cores, because a raw
    perfetto cpu_frequency export is one row per CPU and a single series is what the
    analysis needs.
    """
    if not os.path.exists(path):
        return [], {"error": "missing"}
    rows = {}
    count = 0
    with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        fields = {(name or "").strip().lower(): name for name in (reader.fieldnames or [])}

        def pick(*names):
            for name in names:
                if name in fields:
                    return fields[name]
            return None

        tcol = pick("ts_ms", "ts", "timestamp_ms", "time_ms", "ts_ns", "ts_s", "time_s")
        fcol = pick("cpu_freq_khz", "cpufreq_khz", "freq_khz", "cpu_freq", "freq",
                    "cpu_freq_mhz", "cpu_freq_ghz", "khz")
        scol = pick("thermal_status", "thermalstatus", "status", "mstatus")
        ccol = pick("cpu", "core", "cpu_id")
        srccol = pick("thermal_source", "source", "sample_source")
        if tcol is None:
            return [], {"error": "no timestamp column", "header": list(fields)}
        t_scale = 1.0
        if tcol.lower().endswith("_ns"):
            t_scale = 1e-6
        elif tcol.lower().endswith("_s"):
            t_scale = 1e3
        f_scale = 1.0
        if fcol:
            if fcol.lower().endswith("ghz"):
                f_scale = 1e6
            elif fcol.lower().endswith("mhz"):
                f_scale = 1e3
        for raw in reader:
            count += 1
            stamp = as_float(raw.get(tcol))
            if stamp is None:
                continue
            t_ms = round(stamp * t_scale, 3)
            freq = as_float(raw.get(fcol)) if fcol else None
            status = as_float(raw.get(scol)) if scol else None
            source = ((raw.get(srccol) or "").strip().lower() or None) if srccol else None
            slot = rows.setdefault(t_ms, {"t_ms": t_ms, "freq_khz": None, "status": None,
                                          "source": None})
            if freq is not None:
                freq = round(freq * f_scale, 1)
                slot["freq_khz"] = freq if slot["freq_khz"] is None else max(slot["freq_khz"], freq)
            if status is not None:
                value = int(status)
                slot["status"] = value if slot["status"] is None else max(slot["status"], value)
            if source and (slot["source"] in (None, "held") or source == "measured"):
                slot["source"] = source
    ordered = [rows[key] for key in sorted(rows)]
    meta = {"rows": count, "points": len(ordered), "ts_column": tcol,
            "freq_column": fcol, "status_column": scol,
            "source_column": srccol,
            "measured_points": sum(1 for row in ordered if row["source"] == "measured"),
            "held_points": sum(1 for row in ordered if row["source"] == "held"),
            "multi_core_max": bool(ccol)}
    return ordered, meta


def parse_clock_snapshot_csv(path):
    """Derive the BOOTTIME -> CLOCK_REALTIME offset from a raw clock_snapshot dump.

    The capture side reports only whether it got a snapshot; the conversion and its
    verification live here. Two shapes are accepted:

    * wide:   columns `boottime_ns` / `realtime_ns` (possibly several rows)
    * narrow: trace_processor's one-row-per-clock shape, `clock_id`/`clock_name` +
              `clock_value`/`ts`/`value` (Android ClockId: 1=REALTIME, 6=BOOTTIME)

    Returns (offset_s, meta). offset_s is added to a BOOTTIME timestamp to reach
    CLOCK_REALTIME. Nothing is guessed: an unreadable dump yields offset None.
    """
    if not os.path.exists(path):
        return None, {"error": "missing"}
    with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        fields = {(name or "").strip().lower(): name for name in (reader.fieldnames or [])}
    if not rows:
        return None, {"error": "empty"}

    def pick(*names):
        for name in names:
            if name in fields:
                return fields[name]
        return None

    boot_col = pick("boottime_ns", "boottime", "boot_ns")
    real_col = pick("realtime_ns", "realtime", "real_ns")
    if boot_col and real_col:
        boot = as_float(rows[0].get(boot_col))
        real = as_float(rows[0].get(real_col))
        if boot is None or real is None:
            return None, {"error": "wide row unreadable"}
        scale = 1e-9 if max(boot, real) > 1e6 else 1.0
        return round(real * scale - boot * scale, 6), {
            "method": "clock_snapshot_wide", "boottime_ns": boot, "realtime_ns": real}

    id_col = pick("clock_id", "clock_name", "name")
    val_col = pick("clock_value", "ts", "value", "snapshot")
    if not id_col or not val_col:
        return None, {"error": "unrecognised columns", "header": list(fields)}
    named = {"1": "realtime", "6": "boottime", "CLOCK_REALTIME": "realtime",
             "REALTIME": "realtime", "CLOCK_BOOTTIME": "boottime", "BOOTTIME": "boottime"}
    seen = {}
    for row in rows:
        key = str(row.get(id_col, "")).strip()
        clock = named.get(key) or named.get(key.upper())
        if clock is None:
            continue
        value = as_float(row.get(val_col))
        if value is not None:
            seen.setdefault(clock, value)
    if "realtime" not in seen or "boottime" not in seen:
        return None, {"error": "realtime/boottime row missing", "found": sorted(seen)}
    real, boot = seen["realtime"], seen["boottime"]
    scale = 1e-9 if max(real, boot) > 1e6 else 1.0
    return round(real * scale - boot * scale, 6), {
        "method": "clock_snapshot_narrow", "realtime": real, "boottime": boot}


def _shift_to_walls(rows, offset_s, heartbeat_walls):
    """Apply an offset and return (walls, start_skew) on the logcat wall frame."""
    local = [row["t_ms"] / 1000.0 + offset_s for row in rows]
    sod = [value % 86400.0 for value in local]
    walls = [sod[0]]
    for value in sod[1:]:
        walls.append(value + 86400.0 if value < walls[-1] - 43200.0 else value)
        if walls[-1] < walls[-2]:
            walls[-1] += 86400.0
    k = round((heartbeat_walls[0] - walls[0]) / 86400.0)
    walls = [value + k * 86400.0 for value in walls]
    return walls, walls[0] - heartbeat_walls[0], k


def thermal_csv_wall(rows, heartbeat_walls, clock_offset_s=None, tolerance_s=300.0):
    """Map perfetto ts_ms onto the logcat wall frame, then VERIFY which model fits.

    Two things can be unknown: whether the CSV's ts is BOOTTIME or CLOCK_REALTIME, and
    the local timezone that logcat prints. Rather than assume, each plausible model is
    tried and the run's own heartbeat timeline decides: the right one lands within
    `tolerance_s`, a wrong one is off by hours. Every tried offset is kept in `tried`
    as evidence, and when none fits the map is rejected instead of guessed.
    """
    if not rows or not heartbeat_walls:
        return [], {"aligned": False, "reason": "no data"}
    tz = _pc_utc_offset_s()
    models = []
    if clock_offset_s is not None:
        models.append(("boottime+snapshot+pc_tz", clock_offset_s + tz, "clock_snapshot.csv"))
        models.append(("boottime+snapshot", clock_offset_s, "clock_snapshot.csv"))
    models.append(("realtime+pc_tz", tz, "pc_timezone"))
    tried = []
    for name, offset, source in models:
        walls, skew, k = _shift_to_walls(rows, offset, heartbeat_walls)
        span_ok = walls[-1] >= heartbeat_walls[0] - tolerance_s
        ok = abs(skew) <= tolerance_s and span_ok
        tried.append({"model": name, "offset_s": round(offset, 3),
                      "start_skew_s": round(skew, 1), "aligned": ok})
        if ok:
            return walls, {"aligned": True, "method": name, "offset_source": source,
                           "timezone_offset_s": offset,
                           "day_shift_s": k * 86400.0,
                           "start_skew_s": round(skew, 1),
                           "tolerance_s": tolerance_s, "tried": tried,
                           "reason": "start skew within tolerance"}
    return [], {"aligned": False, "method": "rejected", "offset_source": None,
                "tolerance_s": tolerance_s, "tried": tried,
                "reason": "no candidate offset lands on the run"}


def thermal_csv_steps(rows, times, drop_ratio=0.8):
    """Status/frequency steps from the perfetto CSV, with an onset INTERVAL.

    With a 5 s poll the real transition sits somewhere inside [previous measured
    sample, this measured sample], so a single-second onset would be false precision.
    Held rows (`thermal_source=held`) are interpolated values and are never allowed to
    decide a step; they are only carried along for the alignment view.
    """
    pairs = [(row, at) for row, at in zip(rows, times) if at is not None]
    if not pairs:
        return {"points": 0, "transitions": [], "onset": None, "throttled": False,
                "coverage_s": 0.0}
    unknown_source = all(row.get("source") is None for row, _ in pairs)
    measured = [(row, at) for row, at in pairs
                if row.get("source") in (None, "measured")]

    freqs = [row["freq_khz"] for row, _ in measured if row["freq_khz"] is not None]
    head = freqs[:max(1, len(freqs) // 5)] or freqs
    baseline = round(statistics.median(head), 1) if head else None
    threshold = round(baseline * drop_ratio, 1) if baseline else None

    transitions = []
    previous = None
    for row, at in measured:
        if row["status"] is None:
            continue
        if previous is None and row["status"] == 0:
            previous = (at, 0)
            continue          # the baseline reading is not a step
        if previous is None:
            transitions.append({"t_s": at, "status": row["status"], "from": None,
                                "max_c": None, "battery_c": None, "reason": "status",
                                "window": {"from_t_s": at, "to_t_s": at, "width_s": 0.0}})
            previous = (at, row["status"])
            continue
        if row["status"] != previous[1]:
            transitions.append({
                "t_s": at, "status": row["status"], "from": previous[1],
                "max_c": None, "battery_c": None, "reason": "status",
                "window": {"from_t_s": previous[0], "to_t_s": at,
                           "width_s": round(at - previous[0], 3)}})
        previous = (at, row["status"])

    if threshold:
        previous_at = None
        for row, at in measured:
            if row["freq_khz"] is not None:
                if row["freq_khz"] < threshold:
                    transitions.append({
                        "t_s": at, "status": 1, "from": 0, "max_c": None,
                        "battery_c": None, "reason": "freq_drop", "freq_khz": row["freq_khz"],
                        "window": {"from_t_s": previous_at if previous_at is not None else at,
                                   "to_t_s": at,
                                   "width_s": round(at - previous_at, 3)
                                   if previous_at is not None else 0.0}})
                    break
                previous_at = at

    transitions.sort(key=lambda item: item["t_s"])
    unique = []
    for item in transitions:
        if unique and abs(unique[-1]["t_s"] - item["t_s"]) < 1e-9:
            continue          # status change and frequency drop at the same sample
        unique.append(item)
    transitions = unique
    # A transition TO status 0 is the baseline, not a throttling onset.
    onset = next((item for item in transitions
                  if item.get("reason") == "freq_drop" or (item["status"] or 0) >= 1), None)
    stamps = [at for _, at in pairs]
    status_points = sum(1 for row, _ in measured if row["status"] is not None)
    return {
        "points": len(pairs),
        "status_measured_points": status_points,
        "held_points_excluded": len(pairs) - len(measured),
        "source_unknown": unknown_source,
        "coverage_s": round(stamps[-1] - stamps[0], 1) if len(stamps) >= 2 else 0.0,
        "first_t_s": stamps[0] if stamps else None,
        "last_t_s": stamps[-1] if stamps else None,
        "max_status": max((row["status"] for row, _ in measured
                           if row["status"] is not None), default=None),
        "baseline_freq_khz": baseline,
        "min_freq_khz": round(min(freqs), 1) if freqs else None,
        "drop_threshold_khz": threshold,
        "transitions": transitions,
        "onset": onset,
        "throttled": bool(onset),
        "source": "perfetto_thermal_csv",
    }




# ── completeness gate ──────────────────────────────────────────────────────
FRAME_DUMP_PRIORITY = ("frames_raw.csv", "sf_latency_blast.txt",
                       "sf_latency_raw.txt", "surfaceflinger_latency.txt")


def find_frame_dump(run_dir):
    """The per-frame dump, in the order it should be preferred (see 实机's capture)."""
    for name in FRAME_DUMP_PRIORITY:
        path = os.path.join(run_dir, name)
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return path
    return None


def align_sources(groups):
    """Rebase every source onto one wall-clock axis as `t_run_s`.

    logcat and samples.log are written during the same run but each is zeroed at
    its own first line, so a thermal reading and a heartbeat window would otherwise
    be compared with an offset of however long the script took to start. Returns the
    shared base wall time, or None when no source carried a timestamp.
    """
    walls = [e["wall"] for group in groups for e in group if e.get("wall") is not None]
    base = min(walls) if walls else None
    for group in groups:
        for entry in group:
            entry["t_run_s"] = (round(entry["wall"] - base, 3)
                                if base is not None and entry.get("wall") is not None
                                else None)
    return base


def source_coverage(name, stamps, run_span_s, expected_period_s=None, note=""):
    """One sampling source's effective interval vs the run it is meant to cover.

    A source that stops early, or has a hole inside it, cannot support a claim about
    the rest of the run. It is reported as INCOMPLETE with the missing range spelled
    out, instead of being silently averaged over -- missing data is itself a result.
    """
    clean = sorted(s for s in stamps if s is not None)
    threshold = max(3.0 * (expected_period_s or 0.0), 30.0)
    if not clean:
        return {"name": name, "status": "MISSING", "points": 0,
                "expected_period_s": expected_period_s,
                "missing_s": ([{"from_s": 0.0, "to_s": run_span_s, "reason": "none"}]
                              if run_span_s else []),
                "note": note or "no samples"}
    missing = []
    for previous, current in zip(clean, clean[1:]):
        if current - previous > threshold:
            missing.append({"from_s": previous, "to_s": current, "reason": "hole"})
    if run_span_s is not None and run_span_s - clean[-1] > threshold:
        missing.append({"from_s": clean[-1], "to_s": run_span_s, "reason": "tail"})
    return {"name": name,
            "status": "INCOMPLETE" if missing else "OK",
            "points": len(clean),
            "first_t_s": clean[0], "last_t_s": clean[-1],
            "expected_period_s": expected_period_s,
            "missing_s": missing, "note": note}


def completeness_report(sources, run_span_s):
    """The one verdict that goes at the top of a summary."""
    bad = [s for s in sources if s["status"] != "OK"]
    warnings = []
    for source in bad:
        for gap in source["missing_s"]:
            warnings.append("{0}: {1}..{2}s missing ({3})".format(
                source["name"], round(gap["from_s"], 1), round(gap["to_s"], 1),
                gap.get("reason", "")))
    return {"status": "INCOMPLETE" if bad else "COMPLETE",
            "run_span_s": run_span_s,
            "sources": sources,
            "warnings": warnings}



def swap_pss_kb(run_dir):
    """SwapPss from the end-of-run meminfo. Non-zero means the run went into paging."""
    path = os.path.join(run_dir, "meminfo_end.txt")
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return None
    match = re.search(r"TOTAL SWAP PSS:\s*(\d+)", text)
    return int(match.group(1)) if match else None


def baseline_assessment(digest):
    """Can this run's ABSOLUTE frame times be quoted as a baseline?

    A run that changed tier/limiter mid-way, ran mostly at 10x, or went into paging
    still describes the SHAPE of what happened (when, how long) but its absolute
    millisecond numbers are not comparable with another run. The check is derived from
    the run's own data so nobody has to remember to write the caveat by hand.
    """
    checks = []
    frames = digest.get("frames") or {}
    pacing = frames.get("pacing_changes") or 0
    regimes = frames.get("regimes") or []
    if pacing:
        detail = "%d pacing change(s): %s" % (pacing, ", ".join(
            "%s..%ss" % (r.get("from_s"), r.get("to_s")) for r in regimes))
    else:
        detail = "single pacing regime"
    checks.append({"check": "pacing_stable", "ok": pacing == 0, "detail": detail})

    speed = digest.get("speed_profile") or {}
    changes = speed.get("changes") or []
    if changes:
        chain = [changes[0]["from"]] + [change["to"] for change in changes]
        detail = "speed %s at %ss (dominant %sx for %s%% of heartbeats)" % (
            " -> ".join("%g" % value for value in chain), changes[0]["at_s"],
            speed.get("dominant"), speed.get("share_dominant"))
    else:
        detail = "constant speed %sx" % speed.get("dominant")
    checks.append({"check": "constant_sim_speed", "ok": not changes, "detail": detail})

    swap = digest.get("swap_pss_kb")
    checks.append({"check": "no_paging", "ok": swap is None or swap < 50_000,
                   "detail": ("SwapPss %d kB" % swap) if swap is not None
                   else "no meminfo"})

    rows = (digest.get("perf") or {}).get("rows") or 0
    checks.append({"check": "subsystem_csv", "ok": rows > 0,
                   "detail": ("%d rows" % rows) if rows else
                   "no PerfRecorder CSV -- no per-subsystem attribution"})

    blocking = [c for c in checks if not c["ok"] and c["check"] != "subsystem_csv"]
    return {"usable_for_absolute": not blocking,
            "checks": checks,
            "reasons": ["%s: %s" % (c["check"], c["detail"])
                        for c in checks if not c["ok"]]}


def print_summary(digest):
    complete = digest.get("completeness") or {}
    if complete and complete.get("status") != "COMPLETE":
        print(f"!! SUMMARY INCOMPLETE (run_span={complete.get('run_span_s')}s)")
        for warning in complete.get("warnings") or []:
            print(f"!!   {warning}")
        print("!!   a number below whose source stops early is NOT a run average")
    baseline = digest.get("baseline") or {}
    if baseline and not baseline.get("usable_for_absolute"):
        print("!! BASELINE NOT ABSOLUTE -- shape of events only, do not quote ms "
              "against another run")
        for reason in baseline.get("reasons") or []:
            print(f"!!   {reason}")
    label = digest["meta"].get("label", os.path.basename(digest["dir"]))
    perf = digest["perf"]
    print(f"=== {label} ===")
    meta = digest["meta"]
    print(f"  query={meta.get('query')}  render={meta.get('render_overrides') or '<default>'}")
    # The heartbeat block prints before the CSV guard on purpose: when the
    # PerfRecorder CSV never got exported, the heartbeat/gap timeline is the only
    # evidence left of whether the main thread froze and where.
    hb = digest["logcat"].get("heartbeat", {}).get("fps", {})
    print(f"  fps(hb)  mean={hb.get('mean')} p5={hb.get('p5')} p50={hb.get('p50')} max={hb.get('max')}")
    gaps = digest.get("heartbeat_gaps") or {}
    if gaps.get("max_gap_s") is not None:
        print(f"  hb gap   max={gaps['max_gap_s']}s at t={gaps['max_gap_at_s']}s "
              f"day={gaps.get('max_gap_day')} (>{gaps['threshold_s']}s: "
              f"{len(gaps.get('long_gaps') or [])})")
        for entry in (gaps.get("long_gaps") or [])[:3]:
            print(f"    gap {entry['gap_s']}s t={entry['at_s']}s day={entry['day']} "
                  f"fps_before={entry['fps_before']}")
    slow = digest.get("heartbeat_slowest") or []
    if slow:
        detail = "  ".join(f"t={s['t_s']}s fps={s['fps']} day={s['day']} stalls={s['stalls']}"
                           for s in slow)
        print(f"  hb worst {detail}")
    steps = digest.get("thermal_steps") or {}
    if steps.get("points"):
        onset = steps.get("onset")
        if onset:
            window = onset.get("window") or {}
            if window.get("width_s"):
                onset_text = (f"{window['from_t_s']}..{window['to_t_s']}s "
                              f"({window['width_s']}s window, {onset.get('reason')})")
            else:
                onset_text = f"t={onset['t_s']}s ({onset.get('reason')})"
        else:
            onset_text = "none"
        print(f"  thermal  src={digest.get('thermal_source')} points={steps['points']} "
              f"coverage={steps['coverage_s']}s max_status={steps['max_status']}")
        print(f"    onset  {onset_text}  from={digest.get('thermal_onset_source')} "
              f"measured_pts={steps.get('status_measured_points')} "
              f"held_excluded={steps.get('held_points_excluded')}"
              f" held_rows_in_grid={steps.get('held_points_in_grid')}"
              + ("  SOURCE-UNKNOWN" if steps.get("source_unknown") else ""))
        alignment = (digest.get("thermal_csv") or {}).get("alignment") or {}
        if alignment:
            print(f"    csv    {alignment.get('method')} "
                  f"skew={alignment.get('start_skew_s')}s "
                  f"offset={alignment.get('timezone_offset_s')}s "
                  f"src={alignment.get('offset_source')} "
                  f"day_shift={alignment.get('day_shift_s')}s")
            if not alignment.get("aligned"):
                print(f"    csv    REJECTED ({alignment.get('reason')}) -- "
                      f"thermal falls back to samples.log, offset not guessed")
        if steps.get("baseline_freq_khz"):
            print(f"    freq   baseline={steps['baseline_freq_khz']}kHz "
                  f"min={steps['min_freq_khz']}kHz "
                  f"drop_threshold={steps['drop_threshold_khz']}kHz")
        uncovered = steps.get("uncovered_s")
        if uncovered is not None and uncovered > (steps.get("coverage_s") or 0.0):
            print(f"    WARNING thermal timeline stops at t={steps['last_t_s']}s but the run "
                  f"lasts {steps['run_span_s']}s -- throttling after that point is UNMEASURED "
                  f"({uncovered}s uncovered; see android_perf_run.ps1:236-238)")
        for row in (digest.get("throttle_correlation") or [])[:3]:
            window = row.get("window") or {}
            where = (f"{window['from_t_s']}..{window['to_t_s']}s"
                     if window.get("width_s") else f"t={row['t_s']}s")
            print(f"    step {where} {row['from']}->{row['to']} "
                  f"fps {row['fps_before']}->{row['fps_after']} "
                  f"cost {row['cost_before_ms']}->{row['cost_after_ms']}ms "
                  f"dps {row['dps_before']}->{row['dps_after']}")
    else:
        print("  thermal  NO TIMELINE (no usable thermal_timeline.csv, "
              "no thermalservice block in samples.log)")
    frames = digest.get("frames")
    if frames:
        frame_ms = frames["frame_ms"]
        drop = frames["dropped"]
        print(f"  frames   n={frames['frames']} src={frames.get('source')} "
              f"coverage={frames.get('coverage_s')}s capture={frames.get('capture_ratio')} "
              f"budget={frames['budget_ms']}ms({frames.get('budget_source')}) "
              f"nominal={frames.get('measured_nominal_ms')}")
        print(f"  frames   p50={frame_ms['p50']} p95={frame_ms['p95']} "
              f"p99={frame_ms['p99']} max={frame_ms['max']}")
        for index, regime in enumerate(frames.get("regimes") or [], start=1):
            own = regime.get("frame_ms") or {}
            print(f"  regime {index} t={regime.get('from_s')}..{regime.get('to_s')}s "
                  f"frames={regime['frames']} nominal={regime.get('nominal_ms')}ms "
                  f"fps~{regime.get('fps_from_median')} p50={own.get('p50')} "
                  f"p95={own.get('p95')} p99={own.get('p99')} "
                  f"dropped_own={regime.get('dropped_vs_own')}")
        if not frames.get("pacing_changes"):
            print(f"  pacing   STABLE at {frames.get('measured_nominal_ms')}ms -- "
                  f"no frame-rate-limit change detected during the run")
        per_second = frames.get("per_second") or {}
        if per_second:
            print(f"  fps/sec  min={per_second['min']} p5={per_second['p5']} "
                  f"p50={per_second['p50']} max={per_second['max']} "
                  f"seconds_below_45fps={per_second['seconds_below_45fps']} "
                  f"of {per_second['seconds']}")
        cross = ("  <- MEANINGLESS ACROSS REGIMES, use per-regime"
                 if len(frames.get("regimes") or []) >= 2 else "")
        print(f"  frames   dropped={drop['frames']} ({drop['pct']}%) vs "
              f"{frames['budget_ms']}ms  missed_vsyncs={drop['missed_vsyncs']} "
              f"stutter_runs={frames['jank_runs_stutter']}{cross}")
        run = frames.get("jank_run_longest")
        if run:
            print(f"  frames   longest stutter {run['frames']} frames {run['ms']}ms "
                  f"at {run.get('start_s')}..{run.get('end_s')}s")
    else:
        print("  frames   NO FRAME SERIES (no frames_raw.csv / sf_latency_*.txt)")
    if not perf.get("rows"):
        print("  no perf CSV rows")
        return
    fps = perf["frame"].get("fps", {})
    fast = perf["frame"].get("fast_ms", {})
    rate = digest["logcat"].get("clock_rate", {})
    print(f"  rows={perf['rows']} cols={perf['columns']} window={perf.get('window_s')}s "
          f"days {perf.get('day_first')}..{perf.get('day_last')}")
    print(f"  fps(day) mean={fps.get('mean')} p50={fps.get('p50')} p95={fps.get('p95')} min={fps.get('min')}")
    print(f"  fast_ms  mean={fast.get('mean')} p50={fast.get('p50')} p95={fast.get('p95')} max={fast.get('max')}")
    print(f"  clock    dps mean={rate.get('dps', {}).get('mean')} cost mean={rate.get('cost_ms', {}).get('mean')}ms "
          f"p95={rate.get('cost_ms', {}).get('p95')}ms")
    for key, value in (perf.get("graph_timings") or {}).items():
        print(f"  graph {key:<32} mean={value['mean']:.2f} p95={value['p95']:.2f}")
    for bd in (perf.get("breakdown_costs") or [])[:6]:
        print(f"  bd    {bd['key']:<40} mean={bd['mean_ms']:.2f}ms max={bd['max_ms']:.2f}ms")
    for thread in (digest["samples"].get("threads") or [])[:5]:
        print(f"  cpu   {thread['thread']:<24} mean={thread.get('mean')}% max={thread.get('max')}%")
    pss = (digest["samples"].get("memory", {}) or {}).get("total_pss", {})
    print(f"  pss   start={pss.get('start_kb')}kB max={pss.get('max_kb')}kB end={pss.get('end_kb')}kB")
    thermal = digest.get("thermal") or {}
    print(f"  thermal status={thermal.get('status')} max={thermal.get('max_c')}C")
    battery = digest.get("battery") or {}
    print(f"  battery temp={battery.get('temperature_c')}C level={battery.get('level_pct')}%")
    trace = digest.get("render_trace") or {}
    for seg in (trace.get("segments") or []):
        frame = seg["frame_ms"]
        delta = seg.get("delta_ms_vs_baseline")
        module = seg.get("module_ms")
        print(f"  render {seg['seg']:<16} n={seg['samples']:<5} fps={seg['fps'].get('mean') or 0:6.1f} "
              f"module_ms={module if module is not None else 0:7.2f} "
              f"frame_ms={frame.get('mean') or 0:7.2f} setup_cpu={seg['setup_cpu_ms'].get('mean') or 0:5.2f} "
              f"draws={seg['draw_calls'].get('mean') or 0:5.0f} prims={seg['primitives'].get('mean') or 0:8.0f} "
              f"delta_vs_baseline={delta}")
    counts = digest["logcat"].get("counts", {})
    print(f"  errors script={counts.get('script_error')} shader={counts.get('shader_error')} "
          f"fatal={counts.get('fatal')} stall={counts.get('stall')}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Summarize on-device Project.Keynes perf runs")
    parser.add_argument("runs", nargs="+", help="run directory (or several for a comparison)")
    parser.add_argument("--outdir", default="", help="override output directory for summary.json")
    parser.add_argument("--no-charts", action="store_true")
    args = parser.parse_args(argv)

    setup_fonts()
    digests = []
    for run_dir in args.runs:
        if not os.path.isdir(run_dir):
            print(f"skip (not a directory): {run_dir}", file=sys.stderr)
            continue
        digest = analyze(run_dir)
        timeline = heartbeat_timeline(run_dir)
        clock = clock_timeline(run_dir)
        samples = parse_sample_timeline(os.path.join(run_dir, "samples.log"))
        csv_rows, csv_meta = parse_thermal_csv(os.path.join(run_dir, THERMAL_CSV_NAME))
        clock_offset, clock_meta = parse_clock_snapshot_csv(
            os.path.join(run_dir, "clock_snapshot.csv"))
        csv_walls, csv_align = thermal_csv_wall(
            csv_rows, [e["wall"] for e in timeline if e.get("wall") is not None],
            clock_offset)
        if csv_align.get("aligned"):
            for row, wall in zip(csv_rows, csv_walls):
                row["wall"] = wall
        base_wall = align_sources([timeline, clock, samples,
                                   csv_rows if csv_align.get("aligned") else []])
        digest["heartbeat_timeline"] = timeline
        digest["clock_timeline"] = clock
        digest["sample_timeline"] = samples
        digest["thermal_csv"] = (dict(csv_meta, alignment=csv_align)
                                 if csv_meta.get("points") else
                                 {"alignment": csv_align, "error": csv_meta.get("error")})
        digest["clock_snapshot"] = clock_meta
        digest["heartbeat_series"] = [e["fps"] for e in timeline
                                      if e["fps"] is not None
                                      and (e["day"] is None or e["day"] >= 1)]
        digest["heartbeat_gaps"] = heartbeat_gaps(timeline)
        digest["heartbeat_slowest"] = slowest_windows(timeline)
        # Thermal and heartbeat get compared on the shared wall axis, not on their
        # own zeroes: the two files start at different moments in the same run.
        aligned_hb = [dict(e, t_s=e["t_run_s"]) for e in timeline]
        aligned_samples = [dict(e, t_s=e["t_run_s"]) for e in samples]
        if csv_align.get("aligned") and csv_rows:
            # Onset comes from the measured-only file when the capture produced one:
            # a `held` row is an interpolated value and must never decide a step.
            onset_rows, onset_source = csv_rows, THERMAL_CSV_NAME
            measured_rows, measured_meta = parse_thermal_csv(
                os.path.join(run_dir, "thermal_status_measured.csv"))
            digest["thermal_measured_csv"] = measured_meta
            if measured_rows:
                m_walls, _, _ = _shift_to_walls(measured_rows,
                                                csv_align["timezone_offset_s"],
                                                [e["wall"] for e in timeline
                                                 if e.get("wall") is not None])
                for row, wall in zip(measured_rows, m_walls):
                    row["wall"] = wall
                    row["t_run_s"] = (round(wall - base_wall, 3)
                                      if base_wall is not None else None)
                onset_rows, onset_source = measured_rows, "thermal_status_measured.csv"
            steps = thermal_csv_steps(onset_rows,
                                      [row.get("t_run_s") for row in onset_rows])
            steps["held_points_in_grid"] = csv_meta.get("held_points")
            digest["thermal_onset_source"] = onset_source
            digest["thermal_source"] = "perfetto_thermal_csv"
        else:
            steps = thermal_steps(aligned_samples)
            digest["thermal_source"] = "samples.log"
            digest["thermal_onset_source"] = "samples.log"
        steps = thermal_coverage(steps, aligned_hb)
        digest["thermal_steps"] = steps
        digest["throttle_correlation"] = correlate_throttle(steps, aligned_hb, clock)

        dump = find_frame_dump(run_dir)
        frames_block = None
        if dump and HAVE_FRAME_METRICS:
            frames, stamps, frame_meta = frame_metrics.parse_frame_source(
                frame_metrics.read_source(dump))
            if frames:
                # Budget is derived inside frame_stats from the series' own pacing.
                # The dump's refresh header is the panel's capability (120 Hz here),
                # not the tick the app targets, and using it marks every 60 fps frame
                # as dropped.
                frames_block = frame_metrics.frame_stats(frames, None, stamps)
                frames_block["source"] = os.path.basename(dump)
                frames_block["parse"] = frame_meta
        digest["frames"] = frames_block

        spans = [e["t_run_s"] for e in timeline + clock if e.get("t_run_s") is not None]
        run_span = round(max(spans), 1) if spans else None
        thermal_stamps = [e["t_s"] for e in aligned_samples if e.get("status") is not None]
        if digest["thermal_source"] == "perfetto_thermal_csv":
            stamps = [row["t_run_s"] for row in csv_rows if row.get("t_run_s") is not None]
            deltas = [b - a for a, b in zip(stamps, stamps[1:]) if b > a]
            period = round(statistics.median(deltas), 2) if deltas else None
            thermal_cov = source_coverage("thermal", stamps, run_span, period,
                                          note="perfetto thermal_timeline.csv")
        else:
            thermal_cov = source_coverage("thermal", thermal_stamps, run_span, None,
                                          note="ps1 samples thermalservice at idx 2/6/10 only")
        sources = [
            source_coverage("heartbeat", [e["t_run_s"] for e in timeline], run_span, 5.0),
            source_coverage("clock/rate", [e["t_run_s"] for e in clock], run_span, 2.0),
            thermal_cov,
        ]
        if frames_block:
            ratio = frames_block.get("capture_ratio")
            covered = frames_block.get("coverage_s") or 0.0
            sparse = ratio is not None and ratio < 0.9
            short = run_span is not None and covered < run_span - 30.0
            missing = []
            if short:
                missing.append({"from_s": covered, "to_s": run_span,
                                "reason": "frame capture shorter than the run"})
            if sparse:
                missing.append({"from_s": 0.0, "to_s": covered,
                                "reason": f"sparse capture ratio {ratio}"})
            sources.append({
                "name": "frames", "points": frames_block["frames"],
                "status": "INCOMPLETE" if missing else "OK",
                "first_t_s": 0.0, "last_t_s": covered,
                "expected_period_s": frames_block["budget_ms"],
                "missing_s": missing,
                "note": "span only; frame origin is the capture start"})
        else:
            sources.append({"name": "frames", "status": "MISSING", "points": 0,
                            "first_t_s": None, "last_t_s": None, "expected_period_s": None,
                            "missing_s": [{"from_s": 0.0, "to_s": run_span or 0.0,
                                           "reason": "no frame dump"}],
                            "note": "looked for " + ", ".join(FRAME_DUMP_PRIORITY)})
        digest["completeness"] = completeness_report(sources, run_span)
        digest["speed_profile"] = speed_profile(timeline)
        digest["swap_pss_kb"] = swap_pss_kb(run_dir)
        digest["baseline"] = baseline_assessment(digest)
        digests.append(digest)
        print_summary(digest)
        outdir = args.outdir or run_dir
        os.makedirs(outdir, exist_ok=True)
        if not args.no_charts:
            digest["charts"] = chart_run(run_dir, digest,
                                        digest["meta"].get("label", os.path.basename(run_dir)))
        with open(os.path.join(outdir, "summary.json"), "w", encoding="utf-8") as handle:
            json.dump(digest, handle, ensure_ascii=False, indent=2, default=str)
        print(f"  summary -> {os.path.join(outdir, 'summary.json')}")

    if len(digests) > 1 and not args.no_charts:
        path = chart_compare(digests, os.path.dirname(os.path.abspath(args.runs[-1])))
        if path:
            print(f"comparison chart -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
