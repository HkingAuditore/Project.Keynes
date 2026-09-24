import csv
import collections
from pathlib import Path

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')
bld = Path(str(prefix) + '_buildings.csv')

# Focus on type 71 early_knowledge_institution rows in detail
print('=== early_knowledge_institution (71) raw sample ===')
n = 0
rej = collections.Counter()
inv = collections.Counter()
states = collections.Counter()
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['type_id'] != '71':
            continue
        n += 1
        states[r.get('operating_state', '')] += 1
        rej[r.get('employment_rejection_reason', '')] += 1
        inv[r.get('investment_rejection_reason', '')] += 1
        if n <= 3 or n % 400 == 0 or int(r['day_index']) in (5101, 5699, 6297):
            interesting = {
                k: r[k] for k in [
                    'day_index', 'group_index', 'count', 'owner_required', 'filled_owner',
                    'employee_required', 'employee_filled', 'last_output', 'last_input',
                    'operating_state', 'capacity_q16', 'investment_candidate',
                    'investment_rejection_reason', 'employment_rejection_reason',
                    'employment_eligible', 'employment_vacancy', 'employment_pool_population',
                    'survival_shortage_q16', 'funded_capacity_q16', 'owner_working_capital_allocated',
                    'investment_required_capital', 'investment_blocked' if False else 'construction_ready_days',
                    'is_construction', 'merchant_debt_principal',
                ] if k in r
            }
            print(interesting)
print('total type71 rows', n, 'states', dict(states))
print('employment_rej', dict(rej.most_common(10)))
print('investment_rej', dict(inv.most_common(10)))

# Also check type 72 merchant and investment for research materials
print('\n=== investment candidates on this cell over time ===')
inv_by_day = collections.defaultdict(lambda: collections.Counter())
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r.get('investment_candidate') in ('1', 'true', 'True'):
            inv_by_day[int(r['day_index'])][r['type_id']] += 1
days = sorted(inv_by_day)
if days:
    for day in [days[0], days[len(days)//2], days[-1]]:
        print(day, dict(inv_by_day[day]))

# summary: any research-related global fields?
sum_path = Path(str(prefix) + '_summary.csv')
with sum_path.open(encoding='utf-8', newline='') as f:
    rows = list(csv.DictReader(f))
# look for columns mentioning research
cols = [c for c in rows[0].keys() if 'research' in c or 'tech' in c or 'knowledge' in c]
print('summary research-ish cols', cols)

# unemployed profession growth vs food shortage
coh = Path(str(prefix) + '_cohorts.csv')
mkt = Path(str(prefix) + '_market.csv')
unemp = []
with coh.open(encoding='utf-8', newline='') as f:
    by_day = collections.defaultdict(float)
    for r in csv.DictReader(f):
        if r['profession_id'] == '43':
            by_day[int(r['day_index'])] += float(r['population'] or 0)
    unemp = sorted(by_day.items())
print('unemployed profession onset', unemp[0] if unemp else None, 'last', unemp[-1] if unemp else None, 'max', max(unemp, key=lambda x: x[1]) if unemp else None)

# tools crisis - may block investment
for gid in ['tools', 'bronze_tools', 'chipped_stone_tools', 'logs', 'gathered_plants']:
    series = []
    with mkt.open(encoding='utf-8', newline='') as f:
        for r in csv.DictReader(f):
            if r['good_id'] == gid:
                series.append((int(r['day_index']), float(r['stock']), float(r['demand_ema'] or 0),
                               float(r['business_demand_ema'] or 0), float(r['price'] or 0),
                               float(r.get('shortage_q16') or 0),
                               float(r.get('unfunded_business_demand') or 0)))
    if not series:
        continue
    print(f'\n{gid} first/mid/last:')
    for idx in [0, len(series)//2, -1]:
        print(' ', series[idx])
