# -*- coding: utf-8 -*-
import pandas as pd
import numpy as np
import json, sys

BASE = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/"
PRE = "economy_record_20260716_222059_v5_cell578_q11_r14_"

Q16 = 65536.0
MONEY = 10000.0
GOODS = 1000.0

# ---- id maps (from code exploration) ----
GOOD = {0:"advanced_chips",1:"agri_machinery",2:"aluminum",3:"automobiles",4:"autonomous_sys",5:"batteries",6:"bauxite",7:"beverages",8:"bread",9:"bricks",10:"bronze_tools",11:"canned_fish",12:"cement",13:"chipped_stone_tools",14:"clay",15:"cloth",16:"clothing",17:"coal",18:"coke",19:"computers",20:"concrete",21:"construction_comp",22:"copper_ore",23:"copper",24:"corn_grain",25:"cotton_fiber",26:"crude_oil",27:"dairy",28:"detergent",29:"edible_oil",30:"electric_motor",31:"electrical_eq",32:"electricity",33:"electronic_comp",34:"engines",35:"explosives",36:"fertilizer",37:"fine_clothing",38:"fine_furniture",39:"fish",40:"flax_fiber",41:"flint",42:"footwear",43:"fur",44:"furniture",45:"game_meat",46:"gathered_plants",47:"glass",48:"gold",49:"grain",50:"horses",51:"appliances",52:"industrial_chem",53:"industrial_mach",54:"insulated_cable",55:"iron_ore",56:"jewelry",57:"latex",58:"lead_ore",59:"lead",60:"leather",61:"lime",62:"limestone",63:"livestock_prod",64:"logs",65:"lubricants",66:"lumber",67:"machine_parts",68:"manganese_ore",69:"manuscripts",70:"meat",71:"medicinal_herbs",72:"natural_gas",73:"nuclear_fuel",74:"oceanic_vessels",75:"packaging",76:"paper",77:"petrochemicals",78:"pharma",79:"phosphate_rock",80:"plastics",81:"potatoes",82:"pottery",83:"precision_tools",84:"prepared_staples",85:"printed_mat",86:"processed_food",87:"radio_eq",88:"railway_eq",89:"rare_earth_metal",90:"rare_earth_ore",91:"raw_hide",92:"raw_stone",93:"reactor_comp",94:"refined_fuel",95:"rice_grain",96:"salt",97:"saltpeter",98:"scientific_inst",99:"semiconductors",100:"silica_sand",101:"silver",102:"soap",103:"spices",104:"stainless_steel",105:"steam_engines",106:"steel",107:"sulfur",108:"synthetic_fiber",109:"synthetic_rubber",110:"telecom_eq",111:"tin_ore",112:"tin",113:"tools",114:"vegetables",115:"wheat_grain",116:"wire",117:"wool",118:"zinc_ore",119:"zinc"}

PROF = {0:"agri_worker",1:"apprentice",2:"artisan",3:"chemist",4:"construction_worker",5:"electrician",6:"engineer",7:"enslaved_laborer",8:"fisher",9:"forager",10:"forestry_worker",11:"guild_master",12:"hunter",13:"indentured_laborer",14:"industrial_worker",15:"industrialist",16:"journeyman",17:"landlord",18:"machinist",19:"manager",20:"merchant",21:"metallurgist",22:"miner",23:"pastoralist",24:"petroleum_worker",25:"researcher",26:"serf",27:"subsistence_farmer",28:"technician",29:"tenant_farmer",30:"transport_worker",31:"unemployed",32:"worker"}

def load(name):
    df = pd.read_csv(BASE+PRE+name+".csv")
    df.columns = [c.lstrip("\ufeff") for c in df.columns]
    return df

def main():
    out = {}
    # ---------- SUMMARY ----------
    s = load("summary")
    s = s.sort_values("day_index").reset_index(drop=True)
    s["employed"] = s["filled_owner_jobs"] + s["filled_employee_jobs"]
    s["total_pop_proxy"] = s["employed"] + s["unemployed_population"]
    s["unemp_rate"] = s["unemployed_population"] / s["total_pop_proxy"]
    s["discard_rate"] = s["production_output_discarded"] / (s["production_output_stock"].replace(0,np.nan))
    s["wage_unpaid_rate"] = s["building_wages_unpaid"] / (s["building_wages_paid"]+s["building_wages_unpaid"]).replace(0,np.nan)

    def snap(row):
        return dict(day=int(row["day_index"]),
                    employed=int(row["employed"]),
                    owner_jobs=int(row["filled_owner_jobs"]),
                    emp_jobs=int(row["filled_employee_jobs"]),
                    unemployed=int(row["unemployed_population"]),
                    unemp_rate=round(float(row["unemp_rate"]),4),
                    cohort_count=int(row["cohort_count"]),
                    building_groups=int(row["building_group_count"]),
                    pending_construction=int(row["pending_construction_count"]),
                    loss_suspended=int(row["loss_suspended_building_groups"]),
                    out_stock=int(row["production_output_stock"]),
                    out_discarded=int(row["production_output_discarded"]),
                    out_supported=int(row["production_output_supported"]),
                    support_money=int(row["producer_support_money_issued"]),
                    wages_paid=int(row["building_wages_paid"]),
                    wages_unpaid=int(row["building_wages_unpaid"]),
                    merch_budget=int(row["merchant_procurement_budget"]),
                    merch_spent=int(row["merchant_procurement_spent"]),
                    input_reserve_shortfall=int(row["production_input_reserve_shortfall"]),
                    pop_err=int(row["population_error"]), money_err=int(row["money_error"]), goods_err=int(row["goods_error"]))
    idxs = [0,1,2, len(s)//4, len(s)//2, 3*len(s)//4, len(s)-2, len(s)-1]
    idxs = sorted(set(i for i in idxs if 0<=i<len(s)))
    out["summary_timeline"] = [snap(s.iloc[i]) for i in idxs]
    out["summary_overall"] = dict(
        days=[int(s["day_index"].min()), int(s["day_index"].max())],
        epochs=len(s),
        employed_first=int(s["employed"].iloc[0]), employed_last=int(s["employed"].iloc[-1]),
        unemp_first=int(s["unemployed_population"].iloc[0]), unemp_last=int(s["unemployed_population"].iloc[-1]),
        unemp_rate_mean=round(float(s["unemp_rate"].mean()),4),
        unemp_rate_last=round(float(s["unemp_rate"].iloc[-1]),4),
        cohort_first=int(s["cohort_count"].iloc[0]), cohort_last=int(s["cohort_count"].iloc[-1]),
        pending_construction_max=int(s["pending_construction_count"].max()),
        loss_suspended_mean=round(float(s["loss_suspended_building_groups"].mean()),1),
        loss_suspended_last=int(s["loss_suspended_building_groups"].iloc[-1]),
        discard_rate_mean=round(float(s["discard_rate"].mean()),4),
        wage_unpaid_rate_mean=round(float(s["wage_unpaid_rate"].mean()),4),
        support_money_total=int(s["producer_support_money_issued"].sum()),
        audit_pop_err_max=int(s["population_error"].abs().max()),
        audit_money_err_max=int(s["money_error"].abs().max()),
        audit_goods_err_max=int(s["goods_error"].abs().max()),
    )

    # ---------- COHORTS ----------
    c = load("cohorts")
    c["prof"] = c["profession_id"].map(PROF)
    # latest epoch
    last_day = c["day_index"].max()
    first_day = c["day_index"].min()
    cl = c[c["day_index"]==last_day].copy()
    cf = c[c["day_index"]==first_day].copy()

    def agg_by_prof(dfx):
        g = dfx.groupby("prof").agg(pop=("population","sum"),
                                    funds=("funds","sum"),
                                    n=("population","size")).reset_index()
        g["funds"]=g["funds"]/MONEY
        return g.sort_values("pop",ascending=False)
    out["cohort_prof_last"] = agg_by_prof(cl).to_dict("records")
    out["cohort_prof_first"] = agg_by_prof(cf).to_dict("records")

    # per-cohort income/expense/satisfaction (latest)
    cl["sat"] = cl["satisfaction_q16"]/Q16
    cl["inc"] = cl["epoch_income"]/MONEY
    cl["exp"] = cl["epoch_expense"]/MONEY
    cl["net"] = cl["inc"]-cl["exp"]
    cl["fundsM"] = cl["funds"]/MONEY
    prof_detail = cl.groupby("prof").agg(pop=("population","sum"),
        funds=("fundsM","sum"), inc=("inc","sum"), exp=("exp","sum"),
        sat_w=("sat","mean")).reset_index()
    prof_detail["net"]=prof_detail["inc"]-prof_detail["exp"]
    prof_detail["funds_per_cap"]=prof_detail["funds"]/prof_detail["pop"].replace(0,np.nan)
    out["cohort_prof_detail_last"] = prof_detail.sort_values("pop",ascending=False).round(2).to_dict("records")

    # worst_need distribution latest
    wn = cl.copy()
    wn = wn[wn["population"]>0]
    need_pop = wn.groupby("worst_need_id")["population"].sum().sort_values(ascending=False)
    out["worst_need_last"] = {str(k):int(v) for k,v in need_pop.items()}

    # satisfaction trend across time (weighted)
    c["sat"]=c["satisfaction_q16"]/Q16
    trend=[]
    for d,grp in c.groupby("day_index"):
        w = np.average(grp["sat"], weights=grp["population"].clip(lower=1))
        unemp_pop = grp[grp["prof"]=="unemployed"]["population"].sum()
        tot = grp["population"].sum()
        trend.append(dict(day=int(d), sat=round(float(w),4), unemp_pop=int(unemp_pop), total_pop=int(tot),
                          unemp_share=round(float(unemp_pop/tot),4) if tot else 0))
    trend=sorted(trend,key=lambda x:x["day"])
    out["cohort_trend"]=[trend[i] for i in sorted(set([0,len(trend)//4,len(trend)//2,3*len(trend)//4,len(trend)-1]))]
    # merchant funds trend
    mt=[]
    for d,grp in c[c["is_merchant"]==1].groupby("day_index"):
        mt.append(dict(day=int(d), merch_funds=round(float(grp["funds"].sum()/MONEY),0), merch_pop=int(grp["population"].sum())))
    mt=sorted(mt,key=lambda x:x["day"])
    out["merchant_trend"]=[mt[i] for i in sorted(set([0,len(mt)//2,len(mt)-1]))] if mt else []

    # total population trend (proxy for demographics)
    poptr=[]
    for d,grp in c.groupby("day_index"):
        poptr.append((int(d), int(grp["population"].sum())))
    poptr=sorted(poptr)
    out["total_pop_trend"]={"first":poptr[0],"mid":poptr[len(poptr)//2],"last":poptr[-1],
                            "peak":max(poptr,key=lambda x:x[1]), "min":min(poptr,key=lambda x:x[1])}

    print(json.dumps(out, ensure_ascii=False, indent=1, default=str))

main()
