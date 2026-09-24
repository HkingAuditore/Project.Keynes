import csv
from pathlib import Path

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')
sum_path = Path(str(prefix) + '_summary.csv')
with sum_path.open(encoding='utf-8', newline='') as f:
    rows = list(csv.DictReader(f))

keys = [
    'building_investments_started', 'building_investment_blocked_funds',
    'building_investment_blocked_materials', 'building_investment_blocked_sponsor_capital',
    'building_investment_blocked_resources', 'building_investment_probability_skips',
    'building_investment_capital_transferred', 'building_investment_candidates',
    'building_investment_demand_limited', 'building_investment_material_limited',
    'building_investment_capital_limited', 'building_investment_owner_population_limited',
    'building_investment_buildings_started', 'building_investment_jobs_started',
    'building_investment_employment_gap', 'desired_business_demand', 'funded_business_demand',
    'unfunded_business_demand', 'merchant_cash',
]
print('day', rows[0]['day_index'], '->', rows[-1]['day_index'])
for k in keys:
    vals = [float(r[k]) for r in rows]
    print(f'{k}: first={vals[0]:.3g} last={vals[-1]:.3g} min={min(vals):.3g} max={max(vals):.3g} sum={sum(vals):.3g}')

# When did any investment start?
started = [(int(r['day_index']), float(r['building_investments_started'])) for r in rows if float(r['building_investments_started']) > 0]
print('days with investments_started', len(started), 'first few', started[:10], 'last few', started[-5:])

# Compare blocked reasons share
for day_idx in [0, len(rows)//2, -1]:
    r = rows[day_idx]
    print(f"\nday {r['day_index']}: candidates={r['building_investment_candidates']} started={r['building_investments_started']} "
          f"blocked_funds={r['building_investment_blocked_funds']} mats={r['building_investment_blocked_materials']} "
          f"sponsor={r['building_investment_blocked_sponsor_capital']} res={r['building_investment_blocked_resources']} "
          f"prob_skip={r['building_investment_probability_skips']} demand_lim={r['building_investment_demand_limited']} "
          f"mat_lim={r['building_investment_material_limited']} cap_lim={r['building_investment_capital_limited']} "
          f"owner_pop_lim={r['building_investment_owner_population_limited']}")

# type 71 rejection reason timeline
bld = Path(str(prefix) + '_buildings.csv')
from collections import Counter, defaultdict
rej_by_day = {}
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['type_id'] != '71':
            continue
        rej_by_day[int(r['day_index'])] = (
            r['investment_rejection_reason'],
            r.get('investment_required_capital', ''),
            r.get('investment_score_q16', ''),
            r.get('investment_payback_days', ''),
            r.get('investment_driver_good_id', ''),
            r.get('investment_driver_pressure_q16', ''),
            r.get('investment_return_on_capital_q16', ''),
            r.get('investment_shortage_q16', ''),
            r.get('investment_selected_material_good_ids', ''),
            r.get('investment_selected_material_quantities', ''),
        )
# summarize rejection transitions
counts = Counter(v[0] for v in rej_by_day.values())
print('\ntype71 rejection counts', dict(counts))
# find transition day from 3 to 0
prev = None
for day in sorted(rej_by_day):
    cur = rej_by_day[day][0]
    if prev is None:
        prev = cur
        print('start rej', day, rej_by_day[day])
    elif cur != prev:
        print('transition', day, prev, '->', cur, rej_by_day[day])
        prev = cur
print('end', max(rej_by_day), rej_by_day[max(rej_by_day)])
