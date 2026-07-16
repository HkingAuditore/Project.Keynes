import csv, collections

BASE="economy_record_20260716_113937_v5_cell643_q-5_r16_"
FOOD_GOODS={"grain","bread","wheat_grain","corn_grain","rice_grain","potatoes","processed_food","vegetables","fish","meat","game_meat","canned_fish"}

rows=list(csv.DictReader(open(BASE+"market.csv",encoding="utf-8-sig")))
print("market rows:",len(rows))
bygood=collections.defaultdict(list)
for r in rows: bygood[r["good_id"]].append(r)
print("distinct goods:",len(bygood))

def num(x):
    try: return int(x)
    except:
        try: return float(x)
        except: return x

print("\n===== FOOD-RELATED MARKET GOODS (FIRST vs LAST epoch) =====")
for g in sorted(FOOD_GOODS):
    if g in bygood:
        d=bygood[g]
        first=d[0]; last=d[-1]
        stock_max=max(num(x["stock"]) for x in d)
        tin_max=max(num(x["trade_inbound"]) for x in d)
        print(f"\n{g}: epochs={len(d)} stock_max={stock_max} trade_in_max={tin_max}")
        for label,x in [("FIRST",first),("LAST",last)]:
            print(f"  {label} ep{x['epoch_id']} d{x['day_index']}: stock={x['stock']} price={x['price']} shortage_q16={x['shortage_q16']} demand_ema={x['demand_ema']} offered={x['offered_supply_ema']} hh_avail={x['household_available_stock']} merch_target={x['merchant_inventory_target']} merch_short={x['merchant_procurement_shortfall']} cost_anchor={x['cost_anchor_price']} tin={x['trade_inbound']} tout={x['trade_outbound']}")
    else:
        print(f"\n{g}: NOT PRESENT in market")

print("\n\n===== BUILDINGS =====")
brows=list(csv.DictReader(open(BASE+"buildings.csv",encoding="utf-8-sig")))
print("building rows:",len(brows))
btypes=collections.Counter(r["type_id"] for r in brows)
print("distinct building type_ids:",dict(btypes))
opstates=collections.Counter(r["operating_state"] for r in brows)
print("operating_state counts:",dict(opstates))
bytype=collections.defaultdict(list)
for r in brows: bytype[r["type_id"]].append(r)
print("\n--- per building type (FIRST & LAST) ---")
for t in sorted(bytype):
    d=bytype[t]
    first=d[0]; last=d[-1]
    print(f"\ntype {t}: n={len(d)}")
    for lbl,x in [("FIRST",first),("LAST",last)]:
        print(f"  {lbl} ep{x['epoch_id']} d{x['day_index']}: is_const={x['is_construction']} grp={x['group_index']} cnt={x['count']} own_filled={x['filled_owner']} emp_req={x['employee_required']} emp_filled={x['employee_filled']} wage_susp={x['wage_suspended']} cap={x['capacity_q16']} profit_m={x['realized_profit_margin_q16']} severe={x['severe_loss_cycles']} op={x['operating_state']} in={x['last_input']} out={x['last_output']} sold={x['last_sold']} disc={x['last_discarded']} rev={x['last_revenue']} in_cost={x['last_input_cost']} wages={x['last_wages_paid']}/{x['last_wages_due']}")

print("\n\n===== RESOURCES =====")
rrows=list(csv.DictReader(open(BASE+"resources.csv",encoding="utf-8-sig")))
print("resource rows:",len(rrows))
byres=collections.defaultdict(list)
for r in rrows: byres[r["resource_id"]].append(num(r["reserve"]))
print("distinct resources:",len(byres))
print("resource_id : min / max / first / last")
for rid in sorted(byres):
    v=byres[rid]
    print(f"  {rid}: min={min(v)} max={max(v)} first={v[0]} last={v[-1]}")
