import csv
from pathlib import Path

path = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_buildings.csv")
Q16 = 65536

def i(v, d=0):
    if v in (None, ""):
        return d
    return int(float(v))

first_suspend = None
last_active = None
samples = []
prev_state = None
state_changes = []
max_margin = None
min_margin = None
last_nonzero_output_day = None
miner_rows = []

# also scan cohorts for miner
cpath = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_cohorts.csv")

with path.open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if i(row.get("investment_candidate", 0)):
            continue
        if i(row["is_construction"]):
            continue
        if i(row["type_id"]) != 320:
            continue
        day = i(row["day_index"])
        state = i(row["operating_state"])
        margin = i(row["realized_profit_margin_q16"])
        util = i(row["planned_utilization_q16"])
        output = i(row["last_output"])
        sold = i(row["last_sold"])
        discarded = i(row["last_discarded"])
        revenue = i(row["last_revenue"])
        liv = i(row["owner_livelihood_required"])
        gap = i(row["viability_income_gap"])
        severe = i(row["severe_loss_cycles"])
        rec = i(row["recovery_cycles"])
        filled = i(row["filled_owner"])
        required = i(row["owner_required"])
        if output > 0:
            last_nonzero_output_day = day
        if max_margin is None or margin > max_margin[0]:
            max_margin = (margin, day)
        if min_margin is None or margin < min_margin[0]:
            min_margin = (margin, day)
        if prev_state is None or state != prev_state:
            state_changes.append({
                "day": day, "from": prev_state, "to": state,
                "margin": margin, "util": util, "output": output,
                "sold": sold, "discarded": discarded, "revenue": revenue,
                "livelihood": liv, "gap": gap, "severe": severe,
                "recovery": rec, "filled": filled, "required": required,
            })
            prev_state = state
        if first_suspend is None and state == 1:
            first_suspend = day
        if state == 0:
            last_active = day
        if day in (10, 15, 20, 25, 30, 40, 50, 70, 100) or day % 365 == 10 or (first_suspend and abs(day - first_suspend) <= 20 and day % 5 == 0):
            samples.append({
                "day": day, "state": state, "margin": margin, "util": util,
                "output": output, "sold": sold, "discarded": discarded,
                "revenue": revenue, "livelihood": liv, "gap": gap,
                "severe": severe, "filled": filled, "price_proxy": None,
            })

print("first_suspend", first_suspend)
print("last_active", last_active)
print("last_nonzero_output", last_nonzero_output_day)
print("max_margin", max_margin, "min_margin", min_margin)
print("STATE CHANGES", len(state_changes))
for c in state_changes[:20]:
    print(c)
if len(state_changes) > 20:
    print("... later ...")
    for c in state_changes[-8:]:
        print(c)

print("\nEARLY SAMPLES")
for s in samples[:15]:
    print(s)

# miner profession_id 28 from prior analysis
last_miner_day = None
miner_last = None
with cpath.open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if i(row["profession_id"]) != 28:
            continue
        last_miner_day = i(row["day_index"])
        miner_last = {
            "day": last_miner_day,
            "pop": i(row["population"]),
            "funds": i(row["funds"]),
            "income": i(row["epoch_income"]),
            "expense": i(row["epoch_expense"]),
            "owners": i(row["owner_employed"]),
            "unemp": i(row["unemployed"]),
            "liv": i(row["livelihood_coverage_q16"]),
        }

print("\nMINER LAST", miner_last)

# silver_ore market first/last already known; grab price at suspend if we have day
mpath = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_market.csv")
want_days = {10, 15, 20, 25, 30, first_suspend or 0, last_miner_day or 0, 8916}
silver_pts = []
with mpath.open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if row["good_id"] != "silver_ore":
            continue
        day = i(row["day_index"])
        if day in want_days or day % 180 == 10:
            silver_pts.append({
                "day": day,
                "stock": i(row["stock"]),
                "price": i(row["price"]),
                "demand": i(row["demand_ema"]),
                "supply": i(row["offered_supply_ema"]),
                "withdraw": i(row["realized_withdrawal_ema"]),
            })
print("\nSILVER_ORE MARKET")
for p in silver_pts:
    if p["day"] <= 400 or p["day"] in want_days or p["day"] >= 8700:
        print(p)
