import csv
from pathlib import Path
from collections import Counter, defaultdict

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')
bld = Path(str(prefix) + '_buildings.csv')
mkt = Path(str(prefix) + '_market.csv')
coh = Path(str(prefix) + '_cohorts.csv')
sum_path = Path(str(prefix) + '_summary.csv')

# Focus types: 62 deadwood, 103 gathering_ground, 359 hunting
FOCUS = {'62', '103', '359', '299', '71', '72'}

def dump_type(tid):
    print(f'\n======== type {tid} ========')
    rej = Counter(); states = Counter(); emp_rej = Counter()
    samples = []
    series = []
    with bld.open(encoding='utf-8', newline='') as f:
        for r in csv.DictReader(f):
            if r['type_id'] != tid:
                continue
            # prefer active rows with count>0 or representative
            count = float(r['count'] or 0)
            key = (
                r['investment_rejection_reason'],
                r.get('employment_rejection_reason', ''),
                r.get('operating_state', ''),
            )
            if count > 0 or r['group_index'] != '-1':
                rej[r['investment_rejection_reason']] += 1
                emp_rej[r.get('employment_rejection_reason', '')] += 1
                states[r.get('operating_state', '')] += 1
            day = int(r['day_index'])
            if count > 0:
                series.append((day, count,
                    float(r['owner_required'] or 0), float(r['filled_owner'] or 0),
                    float(r['employee_required'] or 0), float(r['employee_filled'] or 0),
                    float(r['last_output'] or 0), float(r['last_revenue'] or 0),
                    float(r.get('realized_profit_margin_q16') or 0),
                    float(r.get('survival_shortage_q16') or 0),
                    float(r.get('capacity_q16') or 0),
                    float(r.get('projected_owner_income_per_day') or 0),
                    float(r.get('owner_livelihood_required') or 0),
                    r['investment_rejection_reason'],
                    r.get('investment_driver_good_id', ''),
                    r.get('investment_score_q16', ''),
                    r.get('investment_required_capital', ''),
                    r.get('employment_pool_population', ''),
                    r.get('employment_vacancy', ''),
                    r.get('employment_eligible', ''),
                    r.get('employment_rejection_reason', ''),
                    r.get('viability_income_gap', ''),
                    r.get('wage_suspended', ''),
                ))
            if day in (5101, 5459, 5699, 5829, 6297) and (count > 0 or float(r.get('investment_score_q16') or 0) > 0 or r['investment_rejection_reason'] not in ('0','')):
                samples.append(r)
    print('active-ish rej', dict(rej.most_common()))
    print('emp_rej', dict(emp_rej.most_common()))
    if series:
        for idx in [0, len(series)//2, -1]:
            s = series[idx]
            print(f'  active @{s[0]}: count={s[1]} owner={s[3]}/{s[2]} emp={s[5]}/{s[4]} out={s[6]} rev={s[7]} margin={s[8]} surv_short={s[9]} cap={s[10]} proj_inc={s[11]} live_req={s[12]} rej={s[13]} driver={s[14]} score={s[15]} cap_need={s[16]} pool={s[17]} vac={s[18]} elig={s[19]} emp_rej={s[20]} gap={s[21]} wage_sus={s[22]}')
    # candidate-only rows (count=0)
    cand_rej = Counter(); cand_driver = Counter()
    with bld.open(encoding='utf-8', newline='') as f:
        for r in csv.DictReader(f):
            if r['type_id'] != tid or float(r['count'] or 0) > 0:
                continue
            cand_rej[r['investment_rejection_reason']] += 1
            if r.get('investment_driver_good_id', '-1') not in ('', '-1'):
                cand_driver[r['investment_driver_good_id']] += 1
    print('candidate rej', dict(cand_rej.most_common()))
    print('candidate drivers', dict(cand_driver.most_common(5)))

for tid in ['62', '103', '359', '299']:
    dump_type(tid)

# Market: logs vs gathered_plants vs tools drivers
print('\n======== market goods of interest ========')
for gid in ['logs', 'gathered_plants', 'tools', 'bronze_tools', 'chipped_stone_tools', 'copper_tools', 'meat', 'hides', 'gold_dust']:
    pts = []
    with mkt.open(encoding='utf-8', newline='') as f:
        for r in csv.DictReader(f):
            if r['good_id'] != gid:
                continue
            pts.append(r)
    if not pts:
        print(gid, 'ABSENT')
        continue
    def snap(r):
        return (int(r['day_index']), float(r['stock']), float(r['demand_ema'] or 0),
                float(r['business_demand_ema'] or 0), float(r.get('desired_business_demand') or 0),
                float(r.get('funded_business_demand') or 0), float(r.get('unfunded_business_demand') or 0),
                float(r['price'] or 0), float(r.get('shortage_q16') or 0),
                float(r.get('offered_supply_ema') or 0), float(r.get('realized_withdrawal_ema') or 0))
    print(f'{gid}:')
    for idx in [0, len(pts)//2, -1]:
        print(' ', snap(pts[idx]))

# Cohorts disposable / income comparison
print('\n======== cohort livelihood last day ========')
last = None
with sum_path.open(encoding='utf-8', newline='') as f:
    rows = list(csv.DictReader(f))
    last = rows[-1]['day_index']
with coh.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['day_index'] != last:
            continue
        print(
            f"prof {r['profession_id']} pop={r['population']} funds={r['funds']} "
            f"inc={r['epoch_income']} exp={r['epoch_expense']} ink={r['epoch_in_kind_income']} "
            f"cash_cov={r['cash_expense_coverage_q16']} live_cov={r['livelihood_coverage_q16']} "
            f"sat={r['satisfaction_q16']} unemp={r['unemployed']} owner={r['owner_employed']} emp={r['employee_employed']} "
            f"worst={r['worst_need_id']}"
        )
