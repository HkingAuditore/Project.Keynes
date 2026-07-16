# -*- coding: utf-8 -*-
import pandas as pd, numpy as np, json
BASE="D:/Godot/ProjectKeynes/Project.Keynes/tmp/"
PRE="economy_record_20260716_222059_v5_cell578_q11_r14_"
Q16=65536.0; MONEY=10000.0; GOODS=1000.0
GOOD={0:"advanced_chips",6:"bauxite",8:"bread",13:"chipped_stone_tools",14:"clay",16:"clothing",24:"corn_grain",39:"fish",41:"flint",43:"fur",45:"game_meat",46:"gathered_plants",48:"gold",49:"grain",60:"leather",64:"logs",66:"lumber",82:"pottery",84:"prepared_staples",86:"processed_food",91:"raw_hide",92:"raw_stone",101:"silver",103:"spices",113:"tools",114:"vegetables"}
def gname(i): return GOOD.get(i, f"g{i}")
BTYPE={30:"communal_hearth",65:"flint_quarry",69:"gathering_ground",79:"household_weaving_shelter",90:"knapping_workshop",98:"lumber_plant",102:"marine_fish_collector",106:"merchant_post",203:"placer_gold_working",238:"stone_age_hunting_camp",239:"stone_collector",242:"surface_silver_working",251:"timber_collector"}
def bname(i): return BTYPE.get(i, f"b{i}")
def load(n):
    d=pd.read_csv(BASE+PRE+n+".csv"); d.columns=[c.lstrip("\ufeff") for c in d.columns]; return d

b=load("buildings")
last=b["day_index"].max(); first=b["day_index"].min()
bl=b[b["day_index"]==last].copy()

# building type aggregation at last day
def q(x): return x/Q16
bl["margin"]=q(bl["realized_profit_margin_q16"])
bl["util"]=q(bl["planned_utilization_q16"])
agg=bl.groupby("type_id").agg(
    groups=("group_index","size"),
    count=("count","sum"),
    emp_req=("employee_required","sum"),
    emp_filled=("employee_filled","sum"),
    owner_filled=("filled_owner","sum"),
    margin=("margin","mean"),
    util=("util","mean"),
    wage_susp=("wage_suspended","sum"),
    op_state=("operating_state","mean"),
    sev_loss=("severe_loss_cycles","mean"),
    in_=("last_input","sum"),
    out=("last_output","sum"),
    sold=("last_sold","sum"),
    discard=("last_discarded","sum"),
    retained=("last_retained","sum"),
    rev=("last_revenue","sum"),
    incost=("last_input_cost","sum"),
    wpaid=("last_wages_paid","sum"),
    wdue=("last_wages_due","sum"),
).reset_index()
agg["emp_fill_rate"]=agg["emp_filled"]/agg["emp_req"].replace(0,np.nan)
agg["sell_rate"]=agg["sold"]/agg["out"].replace(0,np.nan)
agg["net"]=(agg["rev"]-agg["incost"]-agg["wpaid"])/MONEY
agg=agg.sort_values("count",ascending=False)
out={}
out["buildings_last_by_type"]=[]
for _,r in agg.head(30).iterrows():
    out["buildings_last_by_type"].append(dict(
        type=bname(int(r["type_id"])), type_id=int(r["type_id"]), groups=int(r["groups"]), workers=int(r["count"]),
        emp_req=int(r["emp_req"]), emp_filled=int(r["emp_filled"]), emp_fill=round(float(r["emp_fill_rate"]) if r["emp_fill_rate"]==r["emp_fill_rate"] else 0,3),
        owner_filled=int(r["owner_filled"]),
        margin=round(float(r["margin"]),3), util=round(float(r["util"]),3),
        op_state=round(float(r["op_state"]),2), wage_susp=int(r["wage_susp"]),
        sev_loss=round(float(r["sev_loss"]),1),
        out_units=round(float(r["out"])/GOODS,1), sold_units=round(float(r["sold"])/GOODS,1),
        discard_units=round(float(r["discard"])/GOODS,1), sell_rate=round(float(r["sell_rate"]) if r["sell_rate"]==r["sell_rate"] else 0,3),
        net_profit=round(float(r["net"]),1)))

# operating_state distribution across whole timeline
opd=[]
for d,grp in b.groupby("day_index"):
    n=len(grp)
    opd.append(dict(day=int(d), total=n,
                    normal=int((grp["operating_state"]==0).sum()),
                    suspended=int((grp["operating_state"]==1).sum()),
                    other=int((grp["operating_state"]>1).sum()),
                    wage_susp=int(grp["wage_suspended"].sum()),
                    empty_owner=int((grp["filled_owner"]==0).sum())))
opd=sorted(opd,key=lambda x:x["day"])
out["op_state_trend"]=[opd[i] for i in sorted(set([0,len(opd)//4,len(opd)//2,3*len(opd)//4,len(opd)-1]))]

# how many building groups have 0 employees required (self-run) vs need employees
allbld=b[b["day_index"]==last]
out["employ_structure_last"]=dict(
    total_groups=int(len(allbld)),
    groups_need_employees=int((allbld["employee_required"]>0).sum()),
    groups_selfrun=int((allbld["employee_required"]==0).sum()),
    total_emp_slots=int(allbld["employee_required"].sum()),
    total_emp_filled=int(allbld["employee_filled"].sum()),
    total_owner_slots=int(len(allbld)),
    total_owner_filled=int(allbld["filled_owner"].sum()),
    unfilled_owner=int((allbld["filled_owner"]==0).sum()),
)

# ---------- MARKET ----------
m=load("market")
ml=m[m["day_index"]==last].copy()
ml["price"]=ml["price"]/MONEY
ml["anchor"]=ml["cost_anchor_price"]/MONEY
ml["shortage"]=ml["shortage_q16"]/Q16
ml["stock_u"]=ml["stock"]/GOODS
ml["dem"]=ml["demand_ema"]/GOODS
ml["bdem"]=ml["business_demand_ema"]/GOODS
ml["sup"]=ml["offered_supply_ema"]/GOODS
ml["short_target"]=ml["merchant_procurement_shortfall"]/GOODS
ml=ml[(ml["demand_ema"]>0)|(ml["stock"]>0)|(ml["offered_supply_ema"]>0)]
mrows=[]
for _,r in ml.sort_values("demand_ema",ascending=False).head(25).iterrows():
    mrows.append(dict(good=str(r["good_id"]),
        price=round(float(r["price"]),3), anchor=round(float(r["anchor"]),3),
        stock=round(float(r["stock_u"]),1), demand=round(float(r["dem"]),1),
        biz_demand=round(float(r["bdem"]),1), supply=round(float(r["sup"]),1),
        shortage=round(float(r["shortage"]),3), procure_short=round(float(r["short_target"]),1)))
out["market_last_top_demand"]=mrows

# price trend for staple goods over time
watch=["gathered_plants","game_meat","chipped_stone_tools","flint","pottery","fish","processed_food","clothing","logs","raw_stone","gold"]
ptr={}
for gid in watch:
    sub=m[m["good_id"]==gid].sort_values("day_index")
    if len(sub)==0: continue
    pts=[]
    idxs=sorted(set([0,len(sub)//2,len(sub)-1]))
    for i in idxs:
        rr=sub.iloc[i]
        pts.append(dict(day=int(rr["day_index"]),price=round(rr["price"]/MONEY,3),
            anchor=round(rr["cost_anchor_price"]/MONEY,3), stock=round(rr["stock"]/GOODS,1),
            shortage=round(rr["shortage_q16"]/Q16,3), dem=round(rr["demand_ema"]/GOODS,1)))
    ptr[gid]=pts
out["price_trend_watch"]=ptr

# ---------- RESOURCES ----------
r=load("resources")
rl=r[r["day_index"]==last]
rf=r[r["day_index"]==first]
res={}
for rid in r["resource_id"].unique():
    a=rf[rf["resource_id"]==rid]["reserve"]
    z=rl[rl["resource_id"]==rid]["reserve"]
    if len(a) and len(z):
        res[str(rid)]=dict(first=float(a.iloc[0]), last=float(z.iloc[0]),
                           change=round(float(z.iloc[0]-a.iloc[0]),1))
out["resources"]=res

print(json.dumps(out,ensure_ascii=False,indent=1,default=str))
