import csv, sys, io, json, collections
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
p = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260803_160231.csv'
with open(p, encoding='utf-8-sig', newline='') as f:
    r = csv.DictReader(f); rows = list(r); cols = r.fieldnames

def fl(v):
    try: return float(v)
    except Exception: return 0.0
def col(n): return [fl(x.get(n, '')) for x in rows]
def stat(n):
    v = col(n); s = sorted(v)
    return sum(v)/len(v), s[int(len(s)*.95)], s[-1], sum(v)

print('rows', len(rows), 'cells=%s goods=%s cohorts=%s buildings=%s merchants=%s families=%s' % (
    rows[-1].get('bd_economy_market_count'), rows[-1].get('bd_economy_good_count'),
    rows[-1].get('bd_economy_cohort_count'), rows[-1].get('bd_economy_building_group_count'),
    rows[-1].get('bd_economy_merchant_count'), rows[-1].get('bd_economy_family_count')))

for n in ['t_sus_ms','frame_wall_ms','continuation_wall_ms','continuation_slices',
          'clock_loop_ms','clock_full_ms']:
    m,p95,mx,tot = stat(n)
    print('%-26s mean=%8.3f p95=%8.3f max=%8.3f' % (n, m, p95, mx))

jobs = sorted(set(c[2:-3] for c in cols if c.startswith('j_') and c.endswith('_ms')
    and not any(c.endswith(s) for s in ['_slice_actual_ms','_slice_reported_ms',
        '_slice_reported_gap_ms','_slice_wrapper_wall_ms','_slice_job_shell_wall_ms',
        '_slice_job_shell_wrapper_gap_ms','_job_wrapper_gap_ms'])))
tot = []
for j in jobs:
    m,p95,mx,s = stat('j_%s_ms' % j)
    tot.append((s, m, p95, mx, j))
tot.sort(reverse=True)
grand = sum(t[0] for t in tot)
print('\n--- SUS jobs (total %.0f ms over %d days = %.2f ms/day) ---' % (grand, len(rows), grand/len(rows)))
print('%-32s %8s %8s %8s %6s' % ('job','mean','p95','max','share%'))
for t in tot:
    if t[0] <= 0: continue
    print('%-32s %8.3f %8.3f %8.3f %6.1f' % (t[4], t[1], t[2], t[3], 100*t[0]/grand))

agg = collections.Counter()
for x in rows:
    s = x.get('continuation_substage_wall_ms','')
    if not s: continue
    try: d = json.loads(s)
    except Exception: continue
    for k,v in d.items(): agg[k] += float(v)
print('\n--- economy continuation substages (ms/day) ---')
for k,v in agg.most_common(18):
    print('  %-52s %7.3f' % (k, v/len(rows)))

print('\n--- economy internal breakdown (ms/day) ---')
econ = [(stat(c)[0], c) for c in cols if c.startswith('bd_economy_') and c.endswith('_ms')]
econ.sort(reverse=True)
for m,c in econ[:26]:
    if m < 0.02: break
    print('  %-56s %7.3f' % (c[11:], m))

print('\n--- climate/other native (ms/day) ---')
oth = [(stat(c)[0], c) for c in cols if c.startswith('bd_') and c.endswith('_ms')
       and not c.startswith('bd_economy_')]
oth.sort(reverse=True)
for m,c in oth[:20]:
    if m < 0.05: break
    print('  %-56s %7.3f' % (c[3:], m))
