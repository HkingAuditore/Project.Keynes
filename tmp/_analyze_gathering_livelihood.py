import csv
from pathlib import Path

prefix = Path(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260920_205205_v25_cell1740_q-14_r29')
bld = Path(str(prefix) + '_buildings.csv')
mkt = Path(str(prefix) + '_market.csv')
coh = Path(str(prefix) + '_cohorts.csv')

GOODS = 1000.0
MONEY = 10000.0
Q16 = 65536.0

print('=== active gathering_ground (type 103, count>0) ===')
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['type_id'] != '103' or float(r['count'] or 0) <= 0:
            continue
        day = int(r['day_index'])
        if day not in (5101, 5699, 6297):
            continue
        out = float(r['last_output'] or 0)
        rev = float(r['last_revenue'] or 0)
        sold = float(r['last_sold'] or 0)
        disc = float(r['last_discarded'] or 0)
        ret = float(r['last_retained'] or 0)
        inp = float(r['last_input'] or 0)
        incost = float(r['last_input_cost'] or 0)
        wages = float(r['last_wages_paid'] or 0)
        margin = float(r['realized_profit_margin_q16'] or 0)
        proj = float(r['projected_owner_income_per_day'] or 0)
        live = float(r['owner_livelihood_required'] or 0)
        gap = float(r['viability_income_gap'] or 0)
        surv = float(r['survival_shortage_q16'] or 0)
        ink = float(r.get('last_in_kind_livelihood_value') or 0)
        print(
            f"day {day}: count={r['count']} owner={r['filled_owner']}/{r['owner_required']} "
            f"out={out} ({out/GOODS:.2f}u) sold={sold} retained={ret} discarded={disc} "
            f"rev={rev} ({rev/MONEY:.2f}$) input={inp} input_cost={incost} wages={wages} "
            f"margin_q16={margin} ({margin/Q16:.3f}) proj_inc/day={proj} ({proj/MONEY:.2f}$) "
            f"live_req={live} ({live/MONEY:.2f}$) gap={gap} surv_short={surv/Q16:.3f} "
            f"ink_live={ink} rej={r['investment_rejection_reason']}"
        )

print('\n=== expansion candidates (count=0) same days ===')
with bld.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['type_id'] != '103' or float(r['count'] or 0) > 0:
            continue
        day = int(r['day_index'])
        if day not in (5101, 5699, 6297):
            continue
        print(
            f"day {day}: rej={r['investment_rejection_reason']} score={r.get('investment_score_q16')} "
            f"cap_need={r.get('investment_required_capital')} driver={r.get('investment_driver_good_id')} "
            f"pressure={r.get('investment_driver_pressure_q16')} payback={r.get('investment_payback_days')} "
            f"proj_profit/day={r.get('investment_projected_profit_per_day')} "
            f"mats={r.get('investment_selected_material_good_ids')} qty={r.get('investment_selected_material_quantities')} "
            f"owner_live_req={r.get('owner_livelihood_required')} proj_inc={r.get('projected_owner_income_per_day')} "
            f"viability_gap={r.get('viability_income_gap')} surv={r.get('survival_shortage_q16')}"
        )

print('\n=== gathered_plants market + forager cohort ===')
with mkt.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['good_id'] != 'gathered_plants':
            continue
        day = int(r['day_index'])
        if day not in (5101, 5699, 6297):
            continue
        print(
            f"plants day {day}: stock={float(r['stock'])/GOODS:.2f}u dem_ema={float(r['demand_ema'])/GOODS:.2f}u "
            f"price={float(r['price'])/MONEY:.2f}$/u shortage={float(r['shortage_q16'])/Q16:.3f} "
            f"withdraw={float(r['realized_withdrawal_ema'])/GOODS:.2f}u supply={float(r['offered_supply_ema'])/GOODS:.2f}u"
        )

with coh.open(encoding='utf-8', newline='') as f:
    for r in csv.DictReader(f):
        if r['profession_id'] != '13':  # forager
            continue
        day = int(r['day_index'])
        if day not in (5101, 5699, 6297):
            continue
        pop = float(r['population'])
        print(
            f"forager day {day}: pop={pop} funds={float(r['funds'])/MONEY:.0f}$ "
            f"cash_inc={float(r['epoch_income'])/MONEY:.2f}$ exp={float(r['epoch_expense'])/MONEY:.2f}$ "
            f"ink={float(r['epoch_in_kind_income'])/MONEY:.2f}$ "
            f"live_cov={float(r['livelihood_coverage_q16'])/Q16:.3f} sat={float(r['satisfaction_q16'])/Q16:.3f} "
            f"owner={r['owner_employed']} unemp={r['unemployed']} worst_need={r['worst_need_id']}"
        )
