import csv, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
base="economy_record_20260716_202435_v5_cell617_q10_r15_"
def load(n):
    with open(base+n+".csv",encoding="utf-8-sig") as f: return list(csv.DictReader(f))
summ=load("summary"); coh=load("cohorts"); bld=load("buildings")
def at(rows,e): return [r for r in rows if int(r["epoch_id"])==e]

# Track merchant(prof20) cohort + gold(type203) + silver(type242) epoch by epoch, first 40 epochs
print("epoch day | MERCHANT pop own_emp unemp funds sat | GOLD203 cnt fo er ef op util margin rev | SILVER242 fo op util rev | UNEMP_pool(prof31)")
for e in range(1,41):
    s=at(summ,e)
    if not s: continue
    day=s[0]["day_index"]
    mrow=[r for r in at(coh,e) if int(r["profession_id"])==20]
    urow=[r for r in at(coh,e) if int(r["profession_id"])==31]
    m=mrow[0] if mrow else None
    upop=sum(int(r["population"]) for r in urow)
    g=[r for r in at(bld,e) if int(r["type_id"])==203]
    si=[r for r in at(bld,e) if int(r["type_id"])==242]
    def agg(rows,keys):
        out={}
        for k in keys:
            if k in("op","util","margin"):
                out[k]="/".join(sorted({r[{"op":"operating_state","util":"planned_utilization_q16","margin":"realized_profit_margin_q16"}[k]] for r in rows}))
            else:
                out[k]=sum(int(r[k]) for r in rows)
        return out
    gg=agg(g,["count","filled_owner","employee_required","employee_filled","op","util","margin","last_revenue"]) if g else {}
    ss=agg(si,["filled_owner","op","util","last_revenue"]) if si else {}
    mstr=f"pop={m['population']} own={m['owner_employed']} un={m['unemployed']} funds={int(m['funds'])//1000}k sat={m['satisfaction_q16']}" if m else "NONE"
    print(f"e{e} d{day} | M {mstr} | G203 c{gg.get('count')} fo{gg.get('filled_owner')} er{gg.get('employee_required')} ef{gg.get('employee_filled')} op{gg.get('op')} u{gg.get('util')} m{gg.get('margin')} rev{gg.get('last_revenue')} | S242 fo{ss.get('filled_owner')} op{ss.get('op')} u{ss.get('util')} rev{ss.get('last_revenue')} | Upool={upop}")
