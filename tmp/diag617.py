import csv, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
base="economy_record_20260716_202435_v5_cell617_q10_r15_"

def load(name):
    with open(base+name+".csv",encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

summ=load("summary"); coh=load("cohorts"); bld=load("buildings")
epochs=sorted({int(r["epoch_id"]) for r in summ})
print("epochs:",epochs[0],"..",epochs[-1],"n=",len(epochs))

def at(rows,e): return [r for r in rows if int(r["epoch_id"])==e]
picks=[epochs[0],epochs[len(epochs)//4],epochs[len(epochs)//2],epochs[-1]]

print("\n=== SUMMARY ===")
for e in picks:
    s=at(summ,e)[0]
    print(f"e{e} d{s['day_index']}: fo={s['filled_owner_jobs']} fe={s['filled_employee_jobs']} unemp={s['unemployed_population']} susp={s['loss_suspended_building_groups']} bldgrp={s['building_group_count']}")

print("\n=== COHORTS by profession (cell617) ===")
for e in picks:
    rows=at(coh,e)
    byprof={}
    for r in rows:
        p=int(r["profession_id"])
        d=byprof.setdefault(p,{"pop":0,"funds":0,"own":0,"emp":0,"unemp":0,"n":0,"sat":0,"worst":set()})
        d["pop"]+=int(r["population"]); d["funds"]+=int(r["funds"])
        d["own"]+=int(r["owner_employed"]); d["emp"]+=int(r["employee_employed"])
        d["unemp"]+=int(r["unemployed"]); d["n"]+=1
        d["sat"]+=int(r["satisfaction_q16"]); d["worst"].add(r["worst_need_id"])
    print(f"-- e{e} d{at(summ,e)[0]['day_index']} totalpop={sum(v['pop'] for v in byprof.values())} --")
    for p in sorted(byprof):
        d=byprof[p]
        print(f"  prof{p:>2}: pop={d['pop']:>4} coh={d['n']:>3} funds={d['funds']:>12} own={d['own']:>4} emp={d['emp']:>4} unemp={d['unemp']:>4} sat={d['sat']//max(1,d['n']):>6} worst={sorted(d['worst'])}")

print("\n=== BUILDINGS: owner=merchant groups (type 106/203/242 etc) — filled vs count ===")
# gather all groups whose owner_signature_id maps to merchant profession — use owner_signature_id numeric; merchant prof=20
# We don't have prof directly in buildings; print all groups with count and filled_owner and owner_sig
for e in [epochs[0],epochs[-1]]:
    rows=at(bld,e)
    print(f"-- e{e} d{at(summ,e)[0]['day_index']} --")
    # aggregate by type_id
    bytype={}
    for r in rows:
        t=int(r["type_id"])
        d=bytype.setdefault(t,{"count":0,"fo":0,"er":0,"ef":0,"osig":set(),"opstate":set(),"util":set(),"margin":set(),"rev":0,"slc":set()})
        d["count"]+=int(r["count"]); d["fo"]+=int(r["filled_owner"])
        d["er"]+=int(r["employee_required"]); d["ef"]+=int(r["employee_filled"])
        d["osig"].add(r["owner_signature_id"]); d["opstate"].add(r["operating_state"])
        d["util"].add(r["planned_utilization_q16"]); d["margin"].add(r["realized_profit_margin_q16"])
        d["rev"]+=int(r["last_revenue"]); d["slc"].add(r["severe_loss_cycles"])
    for t in sorted(bytype):
        d=bytype[t]
        print(f"  type{t:>3}: cnt={d['count']:>3} fo={d['fo']:>3} er={d['er']:>3} ef={d['ef']:>3} osig={sorted(d['osig'])} op={sorted(d['opstate'])} slc={sorted(d['slc'])} rev={d['rev']}")
