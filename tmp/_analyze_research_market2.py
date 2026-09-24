import csv
import collections
from pathlib import Path

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')

# Load type catalog from project if possible
import json
# Try to find building type names from compiled catalogs or data
root = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes')

# buildings trajectory for all types over time: staffing and output
bld = Path(str(prefix) + '_buildings.csv')
by_day_type = collections.defaultdict(lambda: collections.defaultdict(lambda: {
    'count': 0, 'owner_req': 0, 'owner_fill': 0, 'emp_req': 0, 'emp_fill': 0,
    'out': 0, 'inp': 0, 'rev': 0, 'groups': 0, 'cap': 0, 'states': collections.Counter(),
}))
all_types = set()
days = set()
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        day = int(r['day_index'])
        tid = int(r['type_id'])
        days.add(day)
        all_types.add(tid)
        g = by_day_type[day][tid]
        g['groups'] += 1
        g['count'] += float(r['count'] or 0)
        g['owner_req'] += float(r['owner_required'] or 0)
        g['owner_fill'] += float(r['filled_owner'] or 0)
        g['emp_req'] += float(r['employee_required'] or 0)
        g['emp_fill'] += float(r['employee_filled'] or 0)
        g['out'] += float(r['last_output'] or 0)
        g['inp'] += float(r['last_input'] or 0)
        g['rev'] += float(r['last_revenue'] or 0)
        g['cap'] += float(r.get('capacity_q16') or 0)
        g['states'][r.get('operating_state', '')] += 1

print('building types present:', sorted(all_types))
print('day span', min(days), max(days), 'n_days', len(days))

# Print every type's first/mid/last snapshot
sorted_days = sorted(days)
anchors = [sorted_days[0], sorted_days[len(sorted_days)//2], sorted_days[-1]]
for tid in sorted(all_types):
    print(f'\n=== type {tid} ===')
    for day in anchors:
        g = by_day_type[day][tid]
        if g['groups'] == 0:
            print(f'  day {day}: absent')
            continue
        print(
            f"  day {day}: groups={g['groups']} count={g['count']:.0f} "
            f"owner={g['owner_fill']:.0f}/{g['owner_req']:.0f} "
            f"emp={g['emp_fill']:.0f}/{g['emp_req']:.0f} "
            f"out={g['out']:.0f} inp={g['inp']:.0f} rev={g['rev']:.0f} "
            f"cap={g['cap']:.0f} states={dict(g['states'])}"
        )

# technology_points full series extremes
mkt = Path(str(prefix) + '_market.csv')
tp = []
with mkt.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['good_id'] != 'technology_points':
            continue
        tp.append(r)

nonzero = [r for r in tp if float(r['stock'] or 0) != 0 or float(r['demand_ema'] or 0) != 0
           or float(r['business_demand_ema'] or 0) != 0
           or float(r.get('desired_business_demand') or 0) != 0
           or float(r.get('funded_business_demand') or 0) != 0
           or float(r.get('offered_supply_ema') or 0) != 0
           or float(r.get('realized_withdrawal_ema') or 0) != 0]
print('\ntechnology_points rows', len(tp), 'nonzero-activity rows', len(nonzero))
if nonzero:
    for r in nonzero[:5] + nonzero[-5:]:
        print(r)

# price only trajectory
prices = [(int(r['day_index']), float(r['price'])) for r in tp]
print('tp price first/last/min/max', prices[0], prices[-1], min(prices, key=lambda x: x[1]), max(prices, key=lambda x: x[1]))

# gathered_plants crisis - food shortage may block research careers
gp = []
with mkt.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['good_id'] == 'gathered_plants':
            gp.append((int(r['day_index']), float(r['stock']), float(r['demand_ema']),
                       float(r['shortage_q16']), float(r['price'])))
print('\ngathered_plants first/mid/last:')
for idx in [0, len(gp)//2, -1]:
    print(' ', gp[idx])

# cohorts: unemployed profession 43 trajectory
coh = Path(str(prefix) + '_cohorts.csv')
by_day_prof = collections.defaultdict(lambda: collections.defaultdict(float))
with coh.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        day = int(r['day_index'])
        pid = r['profession_id']
        by_day_prof[day][pid] += float(r['population'] or 0)
        by_day_prof[day][pid + '_unemp'] += float(r['unemployed'] or 0)
        by_day_prof[day][pid + '_funds'] += float(r['funds'] or 0)
        by_day_prof[day][pid + '_income'] += float(r['epoch_income'] or 0)
        by_day_prof[day][pid + '_sat'] += float(r['satisfaction_q16'] or 0) * float(r['population'] or 0)

prof_ids = set()
for d, m in by_day_prof.items():
    for k in m:
        if not k.endswith(('_unemp', '_funds', '_income', '_sat')):
            prof_ids.add(k)
print('\nprofessions seen', sorted(prof_ids, key=lambda x: int(x)))
for day in anchors:
    print(f'day {day} professions:')
    for pid in sorted(prof_ids, key=lambda x: int(x)):
        pop = by_day_prof[day][pid]
        if pop <= 0:
            continue
        sat = by_day_prof[day][pid + '_sat'] / pop if pop else 0
        print(
            f"  {pid}: pop={pop:.0f} unemp={by_day_prof[day][pid+'_unemp']:.0f} "
            f"funds={by_day_prof[day][pid+'_funds']:.0f} income={by_day_prof[day][pid+'_income']:.0f} sat={sat:.0f}"
        )
