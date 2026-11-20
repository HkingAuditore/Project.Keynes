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
             if n.lower().endswith(".csv") and not n.lower().startswith("render_trace")]
    if not names:
        return None
    if meta:
        for name in meta.get("csv_files") or []:
            base = os.path.basename(str(name))
            if base in names:
                return os.path.join(run_dir, base)
    names.sort(key=lambda n: os.path.getsize(os.path.join(run_dir, n)), reverse=True)
    return os.path.join(run_dir, names[0])


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


def heartbeat_series_of(run_dir):
    path = os.path.join(run_dir, "logcat.txt")
    if not os.path.exists(path):
        return []
    values = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "[heartbeat]" not in line:
                continue
            match = HEARTBEAT_RE.search(line)
            if not match:
                continue
            fields = parse_kv(match.group(1))
            value = as_float(fields.get("fps"))
            day = as_float(fields.get("day"))
            # day 0/loading 心跳是建图阶段的 5fps，不参与帧率统计。
            if value is not None and (day is None or day >= 1):
                values.append(value)
    return values


def print_summary(digest):
    label = digest["meta"].get("label", os.path.basename(digest["dir"]))
    perf = digest["perf"]
    print(f"=== {label} ===")
    meta = digest["meta"]
    print(f"  query={meta.get('query')}  render={meta.get('render_overrides') or '<default>'}")
    if not perf.get("rows"):
        print("  no perf CSV rows")
        return
    fps = perf["frame"].get("fps", {})
    fast = perf["frame"].get("fast_ms", {})
    hb = digest["logcat"].get("heartbeat", {}).get("fps", {})
    rate = digest["logcat"].get("clock_rate", {})
    print(f"  rows={perf['rows']} cols={perf['columns']} window={perf.get('window_s')}s "
          f"days {perf.get('day_first')}..{perf.get('day_last')}")
    print(f"  fps(day) mean={fps.get('mean')} p50={fps.get('p50')} p95={fps.get('p95')} min={fps.get('min')}")
    print(f"  fps(hb)  mean={hb.get('mean')} p5={hb.get('p5')} p50={hb.get('p50')} max={hb.get('max')}")
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
        digest["heartbeat_series"] = heartbeat_series_of(run_dir)
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
