import csv
from pathlib import Path

def i(v, d=0):
    if v in (None, ""):
        return d
    return int(float(v))

bpath = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_buildings.csv")
cpath = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_cohorts.csv")
mpath = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29_market.csv")

print("BUILDING 320 days 10-40 and 2440-2510 and any output>0")
with bpath.open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if i(row.get("investment_candidate", 0)) or i(row["is_construction"]) or i(row["type_id"]) != 320:
            continue
        day = i(row["day_index"])
        output = i(row["last_output"])
        if not (day <= 40 or 2440 <= day <= 2515 or output > 0 or i(row["severe_loss_cycles"]) > 0):
            continue
        print(day, "st", i(row["operating_state"]), "m", i(row["realized_profit_margin_q16"]),
              "u", i(row["planned_utilization_q16"]), "fu", i(row["funded_capacity_q16"]),
              "out", output, "sold", i(row["last_sold"]), "disc", i(row["last_discarded"]),
              "rev", i(row["last_revenue"]), "liv", i(row["owner_livelihood_required"]),
              "gap", i(row["viability_income_gap"]), "sev", i(row["severe_loss_cycles"]),
              "fill", i(row["filled_owner"]), "req", i(row["owner_required"]),
              "clim", i(row.get("last_climate_capacity_q16", 0)),
              "res", i(row["last_resource"]))

print("\nMINER days 10-40 and 2440-2510")
with cpath.open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if i(row["profession_id"]) != 28:
            continue
        day = i(row["day_index"])
        if day <= 40 or 2440 <= day <= 2510:
            print(day, "pop", i(row["population"]), "own", i(row["owner_employed"]),
                  "un", i(row["unemployed"]), "funds", i(row["funds"]),
                  "inc", i(row["epoch_income"]), "exp", i(row["epoch_expense"]),
                  "liv", i(row["livelihood_coverage_q16"]))

print("\nSILVER_ORE 10-40")
with mpath.open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        if row["good_id"] != "silver_ore":
            continue
        day = i(row["day_index"])
        if day <= 40 or 2440 <= day <= 2510:
            print(day, "stock", i(row["stock"]), "px", i(row["price"]),
                  "dem", i(row["demand_ema"]), "sup", i(row["offered_supply_ema"]),
                  "wd", i(row["realized_withdrawal_ema"]),
                  "anchor", i(row["cost_anchor_price"]))
