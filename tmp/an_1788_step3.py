import csv, collections

BASE = "tmp/economy_record_20260828_231131_v25_cell1788_q34_r29_"

def load(name):
    with open(BASE + name + ".csv", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def f(x):
    try:
        return float(x)
    except Exception:
        return 0.0

m = load("market")
days = sorted({int(r["day_index"]) for r in m})
bygood = collections.defaultdict(list)
for r in m:
    bygood[r["good_id"]].append(r)
print("market goods=%d days=%d" % (len(bygood), len(days)))

active = []
for g, rows in bygood.items():
    st = [f(r["stock"]) for r in rows]
    dem = [f(r["demand_ema"]) for r in rows]
    hh = [f(r["household_available_stock"]) for r in rows]
    wd = [f(r["realized_withdrawal_ema"]) for r in rows]
    sup = [f(r["offered_supply_ema"]) for r in rows]
    if max(st) > 0 or max(dem) > 0 or max(sup) > 0:
        active.append((g, rows, st, dem, hh, wd, sup))
print("goods with any stock/demand/supply: %d" % len(active))
print("\n%-18s %10s %10s %10s %10s %10s %10s %8s %8s %10s" % (
    "good", "stock_l", "stock_max", "hh_avail_l", "dem_ema_l", "sup_ema_l", "withdraw_l", "short%", "price_l", "cost_anchor"))
for g, rows, st, dem, hh, wd, sup in sorted(active, key=lambda x: -max(x[3])):
    rl = rows[-1]
    shortshare = sum(1 for r in rows if f(r["shortage_q16"]) > 0) / len(rows)
    print("%-18s %10.0f %10.0f %10.0f %10.1f %10.1f %10.1f %7.0f%% %8.0f %10.0f" % (
        g, st[-1], max(st), hh[-1], dem[-1], sup[-1], wd[-1], shortshare * 100,
        f(rl["price"]), f(rl["cost_anchor_price"])))

print("\n-- trade diagnostics on active goods --")
print("%-18s %6s %10s %10s %10s %12s %10s %8s" % (
    "good", "tr_en", "sig_age", "last_att", "rej", "relief_q16", "inbound", "deadline"))
for g, rows, st, dem, hh, wd, sup in sorted(active, key=lambda x: -max(x[3])):
    rl = rows[-1]
    print("%-18s %6s %10s %10s %10s %12s %10s %8s" % (
        g, rl["trade_enabled"], rl["trade_signal_age_days"], rl["trade_last_attempt_day"],
        rl["trade_last_rejection_reason"], rl["trade_relief_pressure_q16"],
        rl["trade_inbound"], rl["trade_deadline_exceeded"]))

# cohorts full series
c = load("cohorts")
bysig = collections.defaultdict(list)
for r in c:
    bysig[r["signature_id"]].append(r)
print("\n-- cohorts --")
for s, rows in bysig.items():
    r0, rl = rows[0], rows[-1]
    print("sig=%s prof=%s merch=%s pop %s->%s funds %s->%s owner_emp %s->%s empl %s->%s unemp %s->%s inc %s exp %s inkind %s cashcov %s livcov %s sat %s" % (
        s, r0["profession_id"], r0["is_merchant"], r0["population"], rl["population"],
        r0["funds"], rl["funds"], r0["owner_employed"], rl["owner_employed"],
        r0["employee_employed"], rl["employee_employed"], r0["unemployed"], rl["unemployed"],
        rl["epoch_income"], rl["epoch_expense"], rl["epoch_in_kind_income"],
        rl["cash_expense_coverage_q16"], rl["livelihood_coverage_q16"], rl["satisfaction_q16"]))

# resources
res = load("resources")
byres = collections.defaultdict(list)
for r in res:
    byres[r["resource_id"]].append(r)
print("\n-- resources with reserve>0 at some point --")
for k, rows in byres.items():
    rv = [f(r["reserve"]) for r in rows]
    if max(rv) > 0:
        print("  %-22s reserve %.1f -> %.1f  min=%.1f  safe_yield_l=%s life_l=%s extract_tot=%.2f" % (
            k, rv[0], rv[-1], min(rv), rows[-1]["safe_yield"], rows[-1]["projected_life_days"],
            sum(f(r["artificial_extraction_applied"]) for r in rows)))
