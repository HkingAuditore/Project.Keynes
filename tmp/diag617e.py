import csv, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
base="economy_record_20260716_202435_v5_cell617_q10_r15_"
def load(n):
    with open(base+n+".csv",encoding="utf-8-sig") as f: return list(csv.DictReader(f))
summ=load("summary"); bld=load("buildings")
def at(rows,e): return [r for r in rows if int(r["epoch_id"])==e]
epochs=sorted({int(r["epoch_id"]) for r in summ})

# global suspended + unemployed over time
print("=== GLOBAL suspended / unemployed / wages ===")
for e in [1,10,15,30,60,127,253,505]:
    s=at(summ,e)
    if not s: continue
    s=s[0]
    print(f"  e{e} d{s['day_index']}: suspended={s['loss_suspended_building_groups']} unemp={s['unemployed_population']} wagesPaid={s['building_wages_paid']} supportIssued={s['producer_support_money_issued']}")

# what buildings in cell617 produce food? list all local production output goods at e1
print("\n=== cell617 local building outputs (e1) — what's produced locally? ===")
# buildings.csv doesn't have good name, only type_id. Show type + last_output + last_resource_generated
rows=at(bld,1)
for r in sorted(rows,key=lambda x:int(x["type_id"])):
    o=int(r["last_output"]); res=int(r["last_resource_generated"])
    print(f"  type{r['type_id']:>3} cnt={r['count']:>3} out={o:>8} resGen={res:>8} osig={r['owner_signature_id']} er={r['employee_required']}")
