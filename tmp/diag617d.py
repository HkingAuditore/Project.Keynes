import csv, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
base="economy_record_20260716_202435_v5_cell617_q10_r15_"
def load(n):
    with open(base+n+".csv",encoding="utf-8-sig") as f: return list(csv.DictReader(f))
mkt=load("market")
def at(rows,e): return [r for r in rows if int(r["epoch_id"])==e]

# find food goods with high shortage; track price + shortage over e1..e16
# first, at e10 list goods by price desc that have demand
e=10
rows=at(mkt,e)
rows_sorted=sorted(rows,key=lambda r:int(r["price"]),reverse=True)
print("=== e10 top-15 goods by price (with demand_ema>0 or shortage>0) ===")
cnt=0
for r in rows_sorted:
    if int(r["demand_ema"])>0 or int(r["shortage_q16"])>0:
        print(f"  {r['good_id']:>28} price={r['price']:>9} stock={r['stock']:>8} demEMA={r['demand_ema']:>8} shortage={r['shortage_q16']:>6} cat={r['category_id']}")
        cnt+=1
        if cnt>=15: break

# track gold stock over time (post-fix: should NOT accumulate)
print("\n=== GOLD stock trajectory (post bullion-fix check) e1..e16, e100, e500 ===")
for e in [1,2,3,5,8,10,12,14,16,100,505]:
    r=[x for x in at(mkt,e) if x["good_id"]=="gold"]
    if r: print(f"  e{e}: gold stock={r[0]['stock']:>10} price={r[0]['price']} demEMA={r[0]['demand_ema']} realizedWD={r[0]['realized_withdrawal_ema']} merchTarget={r[0]['merchant_inventory_target']}")

# track a key staple food price over e1..e16
print("\n=== staple food price/shortage over e1..e16 (pick highest-shortage food at e10) ===")
food_id=None
for r in rows_sorted:
    if int(r["shortage_q16"])>30000 and ("food" in r["good_id"] or "meat" in r["good_id"] or "grain" in r["good_id"] or "fish" in r["good_id"] or "plant" in r["good_id"] or "produce" in r["good_id"]):
        food_id=r["good_id"]; break
print("tracking:",food_id)
if food_id:
    for e in range(1,17):
        r=[x for x in at(mkt,e) if x["good_id"]==food_id]
        if r: print(f"  e{e}: {food_id} price={r[0]['price']:>9} stock={r[0]['stock']:>8} shortage={r[0]['shortage_q16']:>6} demEMA={r[0]['demand_ema']}")
