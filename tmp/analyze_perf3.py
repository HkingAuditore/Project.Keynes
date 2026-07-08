import csv, json, sys

path = sys.argv[1] if len(sys.argv) > 1 else "D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_record_20260707_222750.csv"
outp = sys.argv[2] if len(sys.argv) > 2 else "D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_analysis3.json"

with open(path, newline='', encoding='utf-8', errors='replace') as f:
    r = csv.reader(f)
    header = next(r)
    col = {h: i for i, h in enumerate(header)}

def gi(name, default=None):
    return col.get(name, default)

jobs = ['native_daily_sim', 'ocean_currents', 'enum_atlas_upload',
        'dynamic_visual_atlas_upload', 'natural_resource_daily', 'season_refresh']

FRAME = gi('t_sus_ms')
BUDGET = gi('sim_frame_budget_ms')
FPS = gi('fps')
FAST = gi('fast_ms')
REND = gi('t_render_ms')
UI = gi('t_ui_ms')
LS_JOB = gi('largest_slice_job')
LS_STAGE = gi('largest_slice_stage')
LS_MS = gi('largest_slice_ms')
OVER1 = gi('over_1ms_count_300')
SUSP95 = gi('sus_sim_p95_300')
SUSMAX = gi('sus_sim_max_300')

def to_f(s):
    try:
        return float(s)
    except Exception:
        return 0.0

def to_b(s):
    return str(s).strip().lower() in ('true', '1', 'yes')

nrows = 0
frame = []; budget = []; fps = []; fast = []; rend = []; ui = []
ls_job = []; ls_stage = []; ls_ms = []; over1 = []; susp95 = []; susmax = []
job_ms = {j: [] for j in jobs}
job_stage = {j: [] for j in jobs}
job_skip = {j: [] for j in jobs}

with open(path, newline='', encoding='utf-8', errors='replace') as f:
    r = csv.reader(f)
    next(r)
    for row in r:
        nrows += 1
        frame.append(to_f(row[FRAME]))
        budget.append(to_f(row[BUDGET]) if BUDGET is not None else 8.0)
        fps.append(to_f(row[FPS]))
        fast.append(to_f(row[FAST]))
        rend.append(to_f(row[REND]))
        ui.append(to_f(row[UI]))
        ls_job.append(row[LS_JOB] if LS_JOB is not None else '')
        ls_stage.append(row[LS_STAGE] if LS_STAGE is not None else '')
        ls_ms.append(to_f(row[LS_MS]) if LS_MS is not None else 0.0)
        over1.append(to_f(row[OVER1]) if OVER1 is not None else 0.0)
        susp95.append(to_f(row[SUSP95]) if SUSP95 is not None else 0.0)
        susmax.append(to_f(row[SUSMAX]) if SUSMAX is not None else 0.0)
        for j in jobs:
            base = 'j_' + j + '_'
            job_ms[j].append(to_f(row[col[base + 'ms']]))
            job_stage[j].append(row[col[base + 'stage']])
            job_skip[j].append(to_b(row[col[base + 'skip']]))

print("nrows", nrows)
bud = budget[0] if budget else 8.0
print("frame_budget_ms (row0):", bud)

def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    k = int(round((len(s) - 1) * p / 100.0))
    k = max(0, min(len(s) - 1, k))
    return s[k]

def stats(vals):
    if not vals:
        return dict(n=0, mean=0.0, p50=0.0, p90=0.0, p95=0.0, p99=0.0, max=0.0)
    return dict(n=len(vals), mean=sum(vals) / len(vals), p50=pct(vals, 50),
                p90=pct(vals, 90), p95=pct(vals, 95), p99=pct(vals, 99), max=max(vals))

ts = stats(frame)
print("\n=== t_sus_ms (per-frame sim) ===")
for k, v in ts.items():
    print("  %-6s %8.3f" % (k, v))
for thr in (4, 6, 8, 12, 16):
    c = sum(1 for x in frame if x > thr)
    print("  >%2dms : %d ticks (%.1f%%)" % (thr, c, 100.0 * c / len(frame)))

print("\n=== fps ===")
fpsv = [x for x in fps if x > 0]
print("  mean %.1f  min %.1f  p5 %.1f  p1 %.1f" % (sum(fpsv)/len(fpsv), min(fpsv), pct(fpsv,5), pct(fpsv,1)))
print("  fast_ms mean %.3f  max %.3f" % (sum(fast)/len(fast), max(fast)))
print("  t_render_ms mean %.3f  t_ui_ms mean %.3f" % (sum(rend)/len(rend), sum(ui)/len(ui)))

print("\n=== per-job (ms) ===")
print("%-30s %8s %8s %8s %8s %8s %8s" % ("job", "n_ran", "mean/f", "ran_mean", "p95", "p99", "max"))
job_summary = {}
total_ms = 0.0
for j in jobs:
    allm = job_ms[j]
    ran = [m for m, sk in zip(allm, job_skip[j]) if not sk and m > 0]
    st = stats(allm)
    rm = stats(ran)
    total_ms += sum(allm)
    job_summary[j] = dict(ran_n=rm['n'], mean_per_frame=st['mean'], ran_mean=rm['mean'],
                          p95=rm['p95'], p99=rm['p99'], max=rm['max'])
    print("%-30s %8d %8.3f %8.3f %8.3f %8.3f %8.3f" %
          (j, rm['n'], st['mean'], rm['mean'], rm['p95'], rm['p99'], rm['max']))
print("\n  share of total job-ms:")
for j in jobs:
    s = sum(job_ms[j])
    print("    %-30s %6.1f%%" % (j, 100.0 * s / total_ms))

print("\n=== largest_slice attribution ===")
from collections import Counter
lc = Counter(ls_job)
for j, c in lc.most_common():
    print("  %-30s %5d ticks (%.1f%%)" % (j, c, 100.0 * c / len(ls_job)))
print("  global worst largest_slice_ms: %.3f (job=%s stage=%s)" %
      (max(ls_ms), ls_job[ls_ms.index(max(ls_ms))], ls_stage[ls_ms.index(max(ls_ms))]))
print("  over_1ms_count_300 mean=%.2f max=%d" % (sum(over1)/len(over1), max(over1)))
print("  sus_sim_p95_300 mean=%.3f  sus_sim_max_300 mean=%.3f" %
      (sum(susp95)/len(susp95), sum(susmax)/len(susmax)))

for j in ['native_daily_sim', 'ocean_currents']:
    print("\n=== %s per-STAGE (ms, ran rows) ===" % j)
    stage_ms = {}
    for m, st, sk in zip(job_ms[j], job_stage[j], job_skip[j]):
        if sk or m <= 0:
            continue
        stage_ms.setdefault(st, []).append(m)
    total = sum(sum(v) for v in stage_ms.values())
    rows = []
    for st, v in stage_ms.items():
        s = stats(v)
        share = 100.0 * sum(v) / total if total else 0
        rows.append((st, s['n'], s['mean'], s['p95'], s['max'], share))
    rows.sort(key=lambda x: -x[2])
    print("%-26s %7s %8s %8s %8s %7s" % ("stage", "n", "mean", "p95", "max", "share%"))
    for st, n, mean, p95, mx, sh in rows:
        print("%-26s %7d %8.3f %8.3f %8.3f %6.1f%%" % (st, n, mean, p95, mx, sh))

out = dict(nrows=nrows, frame_budget=bud, t_sus=ts, jobs=job_summary,
           largest=dict(counter=dict(lc), worst_ms=float(max(ls_ms))))

hist = []
for lo in range(0, 160, 5):
    hi = lo + 5
    c = sum(1 for x in frame if lo / 10.0 <= x < hi / 10.0)
    hist.append([round(lo / 10.0, 1), c])
out['frame_hist'] = hist

stage_tables = {}
for j in jobs:
    stage_ms = {}
    for m, st, sk in zip(job_ms[j], job_stage[j], job_skip[j]):
        if sk or m <= 0:
            continue
        stage_ms.setdefault(st, []).append(m)
    total = sum(sum(v) for v in stage_ms.values())
    rows = []
    for st, v in stage_ms.items():
        s = stats(v)
        rows.append(dict(stage=st, n=s['n'], mean=s['mean'], p95=s['p95'],
                         max=s['max'], share=100.0 * sum(v) / total if total else 0))
    rows.sort(key=lambda x: -x['mean'])
    stage_tables[j] = rows
out['stage_tables'] = stage_tables

with open(outp, "w") as f:
    json.dump(out, f, indent=2)
print("\nwrote", outp)
