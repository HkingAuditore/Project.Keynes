import csv
from pathlib import Path
from collections import defaultdict, Counter

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')
bld = Path(str(prefix) + '_buildings.csv')

# On days when type71 has rejection=0 and high score, what else is investing?
# Also which types actually gain count over the sample.
first_count = {}
last_count = {}
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        tid = r['type_id']
        day = int(r['day_index'])
        count = float(r['count'] or 0)
        if tid not in first_count:
            first_count[tid] = (day, count)
        last_count[tid] = (day, count)

print('count changes:')
for tid in sorted(first_count, key=int):
    print(f'  type {tid}: {first_count[tid]} -> {last_count[tid]} delta={last_count[tid][1]-first_count[tid][1]}')

# Owner vacancy on competing buildings when type71 rejected with reason 3
print('\nowner vacancy on rejection=3 days (sample):')
# pick day 5101, 5809
for day in [5101, 5458, 5459, 5809, 5829, 6297]:
    rows = []
    with bld.open(encoding='utf-8', newline='') as f:
        for r in csv.DictReader(f):
            if int(r['day_index']) != day:
                continue
            rows.append(r)
    print(f'day {day}:')
    for r in rows:
        oreq = float(r['owner_required'] or 0)
        ofill = float(r['filled_owner'] or 0)
        print(
            f"  t{r['type_id']} count={r['count']} owner={ofill}/{oreq} vac={oreq-ofill} "
            f"rej={r['investment_rejection_reason']} score={r.get('investment_score_q16')} "
            f"cap_need={r.get('investment_required_capital')} driver={r.get('investment_driver_good_id')} "
            f"mats={r.get('investment_selected_material_good_ids')} qty={r.get('investment_selected_material_quantities')}"
        )

# summary: on days type71 eligible (assume local), is investment capital going elsewhere?
sum_path = Path(str(prefix) + '_summary.csv')
with sum_path.open(encoding='utf-8', newline='') as f:
    summary = {int(r['day_index']): r for r in csv.DictReader(f)}

elig_days = []
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['type_id'] == '71' and r['investment_rejection_reason'] == '0' and float(r.get('investment_score_q16') or 0) > 0:
            elig_days.append(int(r['day_index']))
print('\neligible type71 days', len(elig_days), 'first', elig_days[:5], 'last', elig_days[-5:])
started_while_elig = 0
mat_lim = 0
cap_lim = 0
for d in elig_days:
    r = summary[d]
    if float(r['building_investments_started']) > 0:
        started_while_elig += 1
    mat_lim += float(r['building_investment_material_limited'])
    cap_lim += float(r['building_investment_capital_limited'])
print('while type71 eligible: days_with_any_start', started_while_elig,
      'sum material_limited', mat_lim, 'sum capital_limited', cap_lim)
