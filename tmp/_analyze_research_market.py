import csv
import collections
import json
from pathlib import Path

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')

sum_path = Path(str(prefix) + '_summary.csv')
with sum_path.open(encoding='utf-8', newline='') as f:
    rows = list(csv.DictReader(f))
print('summary rows', len(rows), 'day', rows[0]['day_index'], '->', rows[-1]['day_index'])
keys = [
    'unemployed_population', 'filled_owner_jobs', 'filled_employee_jobs',
    'merchant_cash', 'money_error', 'goods_error', 'population_error',
    'production_output_stock', 'merchant_procurement_spent',
    'desired_business_demand', 'funded_business_demand', 'unfunded_business_demand',
    'building_wages_paid', 'building_wages_unpaid',
]
for k in keys:
    vals = [float(r[k]) for r in rows if r.get(k) not in (None, '')]
    if not vals:
        continue
    print(f'SUM {k}: first={vals[0]:.3g} last={vals[-1]:.3g} min={min(vals):.3g} max={max(vals):.3g}')

last_day = rows[-1]['day_index']
by_good = collections.defaultdict(lambda: {
    'stock': 0.0, 'demand': 0.0, 'biz': 0.0, 'short': 0.0, 'price': 0.0,
    'n': 0, 'unfunded': 0.0, 'funded': 0.0, 'desired': 0.0,
})
tech_series = []
mkt = Path(str(prefix) + '_market.csv')
with mkt.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        gid = r['good_id']
        day = r['day_index']
        stock = float(r['stock'])
        dem = float(r['demand_ema'])
        biz = float(r['business_demand_ema'] or 0)
        short = float(r['shortage_q16'] or 0)
        price = float(r['price'] or 0)
        unf = float(r.get('unfunded_business_demand') or 0)
        funded = float(r.get('funded_business_demand') or 0)
        desired = float(r.get('desired_business_demand') or 0)
        if day == last_day:
            g = by_good[gid]
            g['stock'] += stock
            g['demand'] += dem
            g['biz'] += biz
            g['short'] += short
            g['price'] += price
            g['unfunded'] += unf
            g['funded'] += funded
            g['desired'] += desired
            g['n'] += 1
        if 'tech' in gid or gid in ('technology_points', 'knowledge') or 'research' in gid:
            tech_series.append((
                int(day), gid, stock, dem, biz, short, price, unf, funded, desired,
                float(r.get('household_available_stock') or 0),
                float(r.get('offered_supply_ema') or 0),
                float(r.get('realized_withdrawal_ema') or 0),
            ))

print('\n=== last-day goods ranked by business_demand_ema ===')
ranked = sorted(by_good.items(), key=lambda kv: kv[1]['biz'], reverse=True)[:20]
for gid, g in ranked:
    print(
        f"{gid}: stock={g['stock']:.0f} dem={g['demand']:.0f} biz={g['biz']:.0f} "
        f"desired={g['desired']:.0f} funded={g['funded']:.0f} unfunded={g['unfunded']:.0f} "
        f"short={g['short']/max(g['n'],1):.0f} price={g['price']/max(g['n'],1):.0f}"
    )

print('\n=== last-day goods ranked by shortage_q16 ===')
ranked = sorted(by_good.items(), key=lambda kv: kv[1]['short'] / max(kv[1]['n'], 1), reverse=True)[:15]
for gid, g in ranked:
    print(
        f"{gid}: short_avg={g['short']/g['n']:.0f} stock={g['stock']:.0f} "
        f"dem={g['demand']:.0f} biz={g['biz']:.0f} price={g['price']/g['n']:.0f}"
    )

print('\ntech-like series rows', len(tech_series))
if tech_series:
    gids = sorted(set(t[1] for t in tech_series))
    print('tech gids', gids)
    for gid in gids:
        pts = [t for t in tech_series if t[1] == gid]
        print(f'--- {gid} n={len(pts)} day {pts[0][0]}->{pts[-1][0]}')
        for label, idx in [('first', 0), ('mid', len(pts) // 2), ('last', -1)]:
            t = pts[idx]
            print(
                f'  {label}: day={t[0]} stock={t[2]} dem={t[3]} biz={t[4]} short={t[5]} '
                f'price={t[6]} unfunded={t[7]} funded={t[8]} desired={t[9]} '
                f'hh_avail={t[10]} supply_ema={t[11]} withdraw_ema={t[12]}'
            )

# buildings: look for research / knowledge / school type patterns
bld = Path(str(prefix) + '_buildings.csv')
# collect type_id employment over last day and trajectories for low-staffed groups
last_types = collections.defaultdict(lambda: {
    'count': 0, 'groups': 0, 'owner_req': 0, 'owner_fill': 0,
    'emp_req': 0, 'emp_fill': 0, 'out': 0, 'in': 0, 'rev': 0, 'wages': 0,
    'states': collections.Counter(), 'rej': collections.Counter(),
})
type_series = collections.defaultdict(list)
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        tid = r['type_id']
        day = int(r['day_index'])
        owner_req = float(r['owner_required'] or 0)
        owner_fill = float(r['filled_owner'] or 0)
        emp_req = float(r['employee_required'] or 0)
        emp_fill = float(r['employee_filled'] or 0)
        out = float(r['last_output'] or 0)
        rec = {
            'day': day,
            'owner_req': owner_req, 'owner_fill': owner_fill,
            'emp_req': emp_req, 'emp_fill': emp_fill,
            'out': out, 'inp': float(r['last_input'] or 0),
            'rev': float(r['last_revenue'] or 0),
            'wages': float(r['last_wages_paid'] or 0),
            'state': r.get('operating_state', ''),
            'cap': float(r.get('capacity_q16') or 0),
            'emp_rej': r.get('employment_rejection_reason', ''),
            'emp_elig': r.get('employment_eligible', ''),
            'surv_short': float(r.get('survival_shortage_q16') or 0),
            'margin': float(r.get('realized_profit_margin_q16') or 0),
        }
        type_series[tid].append(rec)
        if r['day_index'] == last_day:
            g = last_types[tid]
            g['groups'] += 1
            g['count'] += float(r['count'] or 0)
            g['owner_req'] += owner_req
            g['owner_fill'] += owner_fill
            g['emp_req'] += emp_req
            g['emp_fill'] += emp_fill
            g['out'] += out
            g['in'] += float(r['last_input'] or 0)
            g['rev'] += float(r['last_revenue'] or 0)
            g['wages'] += float(r['last_wages_paid'] or 0)
            g['states'][r.get('operating_state', '')] += 1
            if r.get('employment_rejection_reason'):
                g['rej'][r['employment_rejection_reason']] += 1

print('\n=== last-day building types by employee vacancy ===')
vacancy = []
for tid, g in last_types.items():
    vac = (g['emp_req'] - g['emp_fill']) + (g['owner_req'] - g['owner_fill'])
    vacancy.append((vac, tid, g))
vacancy.sort(reverse=True)
for vac, tid, g in vacancy[:25]:
    fill_o = g['owner_fill'] / g['owner_req'] if g['owner_req'] else 1
    fill_e = g['emp_fill'] / g['emp_req'] if g['emp_req'] else 1
    print(
        f"{tid}: vac={vac:.0f} groups={g['groups']} count={g['count']:.0f} "
        f"owner={g['owner_fill']:.0f}/{g['owner_req']:.0f}({fill_o:.0%}) "
        f"emp={g['emp_fill']:.0f}/{g['emp_req']:.0f}({fill_e:.0%}) "
        f"out={g['out']:.0f} rev={g['rev']:.0f} states={dict(g['states'])} "
        f"rej={dict(g['rej'].most_common(3))}"
    )

# Identify likely research buildings: high vacancy + low output, or name heuristics later via type_id int
# Also print types with zero emp fill but nonzero emp req
print('\n=== types with emp_req>0 and emp_fill==0 on last day ===')
for vac, tid, g in vacancy:
    if g['emp_req'] > 0 and g['emp_fill'] == 0:
        print(
            f"{tid}: emp_req={g['emp_req']:.0f} owner={g['owner_fill']:.0f}/{g['owner_req']:.0f} "
            f"out={g['out']:.0f} states={dict(g['states'])} rej={dict(g['rej'])}"
        )

# cohorts: profession staffing
coh = Path(str(prefix) + '_cohorts.csv')
last_prof = collections.defaultdict(lambda: {
    'pop': 0, 'funds': 0, 'income': 0, 'expense': 0, 'sat': 0, 'n': 0,
    'unemp': 0, 'owner': 0, 'employee': 0, 'merchant': 0,
})
with coh.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['day_index'] != last_day:
            continue
        p = last_prof[r['profession_id']]
        pop = float(r['population'] or 0)
        p['pop'] += pop
        p['funds'] += float(r['funds'] or 0)
        p['income'] += float(r['epoch_income'] or 0)
        p['expense'] += float(r['epoch_expense'] or 0)
        p['sat'] += float(r['satisfaction_q16'] or 0) * pop
        p['n'] += 1
        p['unemp'] += float(r['unemployed'] or 0)
        p['owner'] += float(r['owner_employed'] or 0)
        p['employee'] += float(r['employee_employed'] or 0)
        p['merchant'] += int(float(r['is_merchant'] or 0) > 0)

print('\n=== last-day professions by population ===')
for pid, p in sorted(last_prof.items(), key=lambda kv: kv[1]['pop'], reverse=True):
    sat = p['sat'] / p['pop'] if p['pop'] else 0
    print(
        f"prof {pid}: pop={p['pop']:.0f} funds={p['funds']:.0f} income={p['income']:.0f} "
        f"expense={p['expense']:.0f} sat={sat:.0f} unemp={p['unemp']:.0f} "
        f"owner={p['owner']:.0f} emp={p['employee']:.0f} merchant_rows={p['merchant']}"
    )

# dump profile signals briefly
prof_path = Path(str(prefix) + '_profile.json')
if prof_path.exists():
    data = json.loads(prof_path.read_text(encoding='utf-8'))
    print('\nprofile signals:', data.get('signals'))
    # print first few signal entries if structured
    sig = data.get('signals')
    if isinstance(sig, list):
        for s in sig[:10]:
            print(' ', s)
    elif isinstance(sig, dict):
        for k, v in list(sig.items())[:10]:
            print(' ', k, v)
