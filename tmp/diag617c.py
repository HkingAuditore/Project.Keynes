import csv, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
base="economy_record_20260716_202435_v5_cell617_q10_r15_"
def load(n):
    with open(base+n+".csv",encoding="utf-8-sig") as f: return list(csv.DictReader(f))
bld=load("buildings"); mkt=load("market")
def at(rows,e): return [r for r in rows if int(r["epoch_id"])==e]

print("=== GOLD type203 full cost ledger e7..e16 ===")
cols=["filled_owner","employee_required","employee_filled","last_output","last_sold","last_revenue","last_input_cost","last_wages_paid","last_wages_due","last_expected_revenue","last_operating_cost","last_margin_gap_q16","realized_profit_margin_q16","planned_utilization_q16","severe_loss_cycles","operating_state","last_base_wages_due","last_bonus_due"]
for e in range(7,17):
    g=[r for r in at(bld,e) if int(r["type_id"])==203]
    if not g: continue
    a={c:sum(int(r[c]) for r in g) for c in cols}
    print(f"e{e}: fo={a['filled_owner']} ef={a['employee_filled']} out={a['last_output']} sold={a['last_sold']} REV={a['last_revenue']} inCost={a['last_input_cost']} wagesPaid={a['last_wages_paid']} wagesDue={a['last_wages_due']} baseWageDue={a['last_base_wages_due']} bonusDue={a['last_bonus_due']} expRev={a['last_expected_revenue']} opCost={a['last_operating_cost']} marginGap={a['last_margin_gap_q16']} realizedM={a['realized_profit_margin_q16']} util={a['planned_utilization_q16']} slc={a['severe_loss_cycles']} op={a['operating_state']}")

# gold market: is stock still accumulating? (post-fix check)
print("\n=== GOLD market signal (find good col) ===")
print("market header sample:", mkt[0].keys() if mkt else "none")
