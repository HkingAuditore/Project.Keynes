import csv

def load(path):
    return list(csv.DictReader(open(path, encoding='utf-8-sig')))

def avg(rows, col, lo=10, hi=170):
    vals = []
    for r in rows[lo:hi]:
        v = r.get(col, '')
        try:
            vals.append(float(v))
        except ValueError:
            pass
    return sum(vals) / len(vals) if vals else float('nan')

t1 = load(r'D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260730_202819.csv')
t2 = load(r'D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260730_210447.csv')

cols = ['j_economy_daily_ms', 'bd_economy_epoch_begin_ms', 'bd_economy_prepare_ms', 'bd_economy_investment_ms',
        'bd_economy_building_commit_ms', 'bd_economy_household_market_ms', 'bd_economy_building_production_ms',
        'bd_economy_building_plan_ms', 'bd_economy_continuation_wall_ms',
        'bd_economy_investment_gate_capital_type_skips',
        'bd_economy_investment_type_evaluations', 'bd_economy_building_investment_candidates',
        'bd_economy_building_investment_started',
        'bd_economy_environment_hash', 'bd_economy_cohort_count']
header = '%-52s %12s %12s %8s' % ('col', 't1_new', 't2_new', 'delta%')
print(header)
for c in cols:
    a, b = avg(t1, c), avg(t2, c)
    d = (b - a) / a * 100 if a and a == a and b == b else float('nan')
    print('%-52s %12.3f %12.3f %8.1f' % (c, a, b, d))
print()
print('--- epoch_begin substages (t2_new avg ms/day) ---')
for c in sorted(t2[0].keys()):
    if c.startswith('bd_economy_epoch_begin_') and c != 'bd_economy_epoch_begin_ms':
        print('%-52s %10.3f' % (c, avg(t2, c)))
