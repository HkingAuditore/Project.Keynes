import csv, sys, io, json, collections
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

def load(p):
    with open(p, encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))
def fl(v):
    try: return float(v)
    except Exception: return 0.0
def stages(rows):
    agg = collections.Counter()
    for x in rows:
        s = x.get('continuation_stage_wall_ms', '')
        if s:
            for k, v in json.loads(s).items(): agg[k] += float(v)
    return {k: v/len(rows) for k, v in agg.items()}
def mean(rows, c): return sum(fl(x.get(c, '')) for x in rows)/len(rows)
def pk(rows, c): return max(fl(x.get(c, '')) for x in rows)

A = load(r'tmp\perf_record_20260803_161249.csv')   # before: linear scan
B = load(r'tmp\perf_record_20260803_161817.csv')   # after: hash index
sa, sb = stages(A), stages(B)

print('=== economy continuation stages (ms/day) ===')
print('%-38s %9s %9s %9s' % ('stage', 'before', 'after', 'delta'))
for k in sorted(set(sa) | set(sb), key=lambda k: -sa.get(k, 0)):
    a, b = sa.get(k, 0), sb.get(k, 0)
    print('%-38s %9.2f %9.2f %+9.2f' % (k, a, b, b-a))
print('%-38s %9.2f %9.2f %+9.2f' % ('TOTAL', sum(sa.values()), sum(sb.values()),
                                    sum(sb.values())-sum(sa.values())))

print('\n=== person_commit internals (ms/day) ===')
for k in ['retire', 'index', 'bind_jobs', 'claims', 'equity', 'promote']:
    c = 'bd_economy_person_commit_%s_ms' % k
    print('  %-14s before mean=%8.3f max=%8.3f   after mean=%7.3f max=%7.3f' % (
        k, mean(A, c), pk(A, c), mean(B, c), pk(B, c)))

print('\n=== top-line ===')
for c in ['continuation_wall_ms', 'continuation_max_slice_ms', 'continuation_slices',
          't_sus_ms', 'j_economy_daily_ms']:
    print('  %-28s before mean=%9.2f max=%9.2f   after mean=%8.2f max=%8.2f' % (
        c, mean(A, c), pk(A, c), mean(B, c), pk(B, c)))

print('\n=== scale ===')
for c in ['bd_economy_building_group_count', 'bd_economy_cohort_count',
          'bd_economy_notable_person_count', 'bd_economy_family_count']:
    print('  %-36s before=%-9s after=%s' % (c[11:], A[-1].get(c), B[-1].get(c)))
