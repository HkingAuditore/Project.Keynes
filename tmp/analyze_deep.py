# -*- coding: utf-8 -*-
import pandas as pd, numpy as np, json
BASE="D:/Godot/ProjectKeynes/Project.Keynes/tmp/"
PRE="economy_record_20260716_222059_v5_cell578_q11_r14_"
Q16=65536.0; MONEY=10000.0; GOODS=1000.0
PROF={0:"agri_worker",1:"apprentice",2:"artisan",3:"chemist",4:"construction_worker",5:"electrician",6:"engineer",7:"enslaved_laborer",8:"fisher",9:"forager",10:"forestry_worker",11:"guild_master",12:"hunter",13:"indentured_laborer",14:"industrial_worker",15:"industrialist",16:"journeyman",17:"landlord",18:"machinist",19:"manager",20:"merchant",21:"metallurgist",22:"miner",23:"pastoralist",24:"petroleum_worker",25:"researcher",26:"serf",27:"subsistence_farmer",28:"technician",29:"tenant_farmer",30:"transport_worker",31:"unemployed",32:"worker"}
def load(n):
    d=pd.read_csv(BASE+PRE+n+".csv"); d.columns=[c.lstrip("\ufeff") for c in d.columns]; return d
out={}

# ---- cohort employment breakdown over time ----
c=load("cohorts"); c["prof"]=c["profession_id"].map(PROF)
emp=[]
for d,g in c.groupby("day_index"):
    row=dict(day=int(d))
    row["owner_emp"]=int(g["owner_employed"].sum())
    row["emp_emp"]=int(g["employee_employed"].sum())
    row["unemp"]=int(g["unemployed"].sum())
    row["pop"]=int(g["population"].sum())
    emp.append(row)
emp=sorted(emp,key=lambda x:x["day"])
out["employment_breakdown"]=[emp[i] for i in sorted(set([0,1,2,3,len(emp)//4,len(emp)//2,3*len(emp)//4,len(emp)-1]))]

# ---- who becomes unemployed: profession pop trend ----
watchp=["forager","hunter","fisher","artisan","miner","unemployed","merchant"]
ptrend={}
for p in watchp:
    sub=c[c["prof"]==p]
    pts=[]
    for d,g in sub.groupby("day_index"):
        pts.append((int(d), int(g["population"].sum()), round(float(g["funds"].sum()/MONEY),0),
                    round(float(g["satisfaction_q16"].mean()/Q16),3)))
    pts=sorted(pts)
    if pts:
        idxs=sorted(set([0,len(pts)//2,len(pts)-1]))
        ptrend[p]=[dict(day=pts[i][0],pop=pts[i][1],funds=pts[i][2],sat=pts[i][3]) for i in idxs]
out["prof_pop_funds_sat_trend"]=ptrend

# ---- income/expense/net by profession over time (net accumulation) ----
# funds distribution: gini-ish concentration at last day
last=c["day_index"].max()
cl=c[c["day_index"]==last]
tot_funds=cl["funds"].sum()
share={}
for p,g in cl.groupby("prof"):
    if g["funds"].sum()>0:
        share[p]=round(float(g["funds"].sum()/tot_funds),4)
out["funds_share_last"]=dict(sorted(share.items(),key=lambda x:-x[1]))
out["total_funds_last_yuan"]=round(float(tot_funds/MONEY),0)

# income vs expense by profession, last
inc={}
for p,g in cl.groupby("prof"):
    if g["population"].sum()>0:
        inc[p]=dict(pop=int(g["population"].sum()),
                    inc=round(float(g["epoch_income"].sum()/MONEY),1),
                    exp=round(float(g["epoch_expense"].sum()/MONEY),1),
                    funds=round(float(g["funds"].sum()/MONEY),0))
out["income_expense_last"]=inc

# ---- total money supply trend (all cohorts + is money conserved? gold/silver minting) ----
mt=[]
for d,g in c.groupby("day_index"):
    mt.append((int(d), round(float(g["funds"].sum()/MONEY),0)))
mt=sorted(mt)
out["total_cohort_funds_trend"]=[dict(day=mt[i][0],funds=mt[i][1]) for i in sorted(set([0,len(mt)//4,len(mt)//2,3*len(mt)//4,len(mt)-1]))]

# ---- buildings: worker(count) vs slots to understand "owner absorbs labor" ----
b=load("buildings")
bl=b[b["day_index"]==last]
# total labor by role
out["labor_absorption_last"]=dict(
    sum_count=int(bl["count"].sum()),
    sum_filled_owner=int(bl["filled_owner"].sum()),
    sum_emp_filled=int(bl["employee_filled"].sum()),
    note="count=workers in group; filled_owner may exceed 1 when many owner-operators share a group")
# per building: count vs employee_filled vs filled_owner
rows=[]
for _,r in bl.iterrows():
    rows.append(dict(type_id=int(r["type_id"]),count=int(r["count"]),
        filled_owner=int(r["filled_owner"]),emp_req=int(r["employee_required"]),
        emp_filled=int(r["employee_filled"]),util=round(r["planned_utilization_q16"]/Q16,3)))
out["per_building_labor_last"]=rows

print(json.dumps(out,ensure_ascii=False,indent=1,default=str))
