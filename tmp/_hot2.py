import csv, sys, io, json, collections
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
p = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260803_160231.csv'
with open(p, encoding='utf-8-sig', newline='') as f:
    r = csv.DictReader(f); rows = list(r); cols = r.fieldnames
n = len(rows)
def fl(v):
    try: return float(v)
    except Exception: return 0.0

agg = collections.Counter(); cnt = collections.Counter(); mx = collections.Counter()
for x in rows:
    for key, target in (('continuation_stage_wall_ms', agg),
                        ('continuation_stage_counts', cnt)):
        s = x.get(key, '')
        if not s: continue
        try: d = json.loads(s)
        except Exception: continue
        for k, v in d.items(): target[k] += float(v)
    s = x.get('continuation_stage_max_slice_ms', '')
    if s:
        try:
            for k, v in json.loads(s).items(): mx[k] = max(mx[k], float(v))
        except Exception: pass

print('--- economy continuation stages ---')
print('%-34s %10s %10s %10s' % ('stage', 'ms/day', 'slices/day', 'max_slice'))
for k, v in agg.most_common():
    print('%-34s %10.2f %10.2f %10.3f' % (k, v/n, cnt[k]/n, mx[k]))
print('%-34s %10.2f' % ('TOTAL', sum(agg.values())/n))
print()
for c in ['continuation_wall_ms', 'continuation_max_slice_ms', 'continuation_slices',
          'continuation_frames', 'continuation_budget_ms']:
    v = [fl(x[c]) for x in rows]; s = sorted(v)
    print('%-30s mean=%9.2f p95=%9.2f max=%9.2f' % (c, sum(v)/n, s[int(n*.95)], s[-1]))

print('\n--- worker parallelism ---')
for c in cols:
    if 'worker_tasks_max' in c or 'worker_dispatches' in c or 'worker_cpu_ms' in c \
       or 'worker_ms' in c or 'worker_task_sum' in c:
        v = [fl(x[c]) for x in rows]
        if sum(v) == 0: continue
        s = sorted(v)
        print('  %-62s mean=%9.3f max=%9.3f' % (c[3:], sum(v)/n, s[-1]))

print('\n--- scale knobs ---')
for c in cols:
    if c.startswith('bd_economy_') and any(k in c for k in
        ['per_slice','cycle_days','estimated_','slices_per_epoch','deadline','due_cells',
         'settlement_phase_count','rolling']):
        vals = set(x[c] for x in rows)
        if len(vals) <= 3: print('  %-56s %s' % (c[11:], sorted(vals)))
        else:
            v=[fl(x[c]) for x in rows]; print('  %-56s mean=%.1f max=%.1f' % (c[11:], sum(v)/n, max(v)))
