import pandas as pd, numpy as np
BASE="economy_record_20260716_162646_v5_cell501_q15_r12_"
Q16=65536.0
coh=pd.read_csv(BASE+"cohorts.csv"); summ=pd.read_csv(BASE+"summary.csv")
bld=pd.read_csv(BASE+"buildings.csv"); mkt=pd.read_csv(BASE+"market.csv")
for df in (coh,summ,bld,mkt): df.columns=[c.lstrip('\ufeff') for c in df.columns]

print("=== EARLY employment collapse (epoch 1-40) ===")
t=coh.groupby('epoch_id').agg(popn=('population','sum'),owner=('owner_employed','sum'),
   emp=('employee_employed','sum'),unemp=('unemployed','sum')).reset_index()
t['ur']=t.unemp/t.popn
print(t[t.epoch_id<=40][['epoch_id','popn','owner','emp','unemp','ur']].to_string(index=False))

print("\n=== profession pop trajectory (who becomes unemployed) ===")
# unemployed cohorts have profession_id = the unemployed profession. find it
print("unemployed flag by profession, epoch1 vs epoch40 vs last:")
for ep in [1,10,40,434]:
    sub=coh[coh.epoch_id==ep]
    g=sub.groupby('profession_id').agg(popn=('population','sum'),un=('unemployed','sum'),
       ownemp=('owner_employed','sum'),empemp=('employee_employed','sum')).reset_index()
    print(f"--- epoch {ep} ---")
    print(g.to_string(index=False))

print("\n=== building employee_required vs filled over time (all types) ===")
b=bld[~bld.is_construction.astype(bool)].copy()
be=b.groupby('epoch_id').agg(req=('employee_required','sum'),fill=('employee_filled','sum'),
   own_req=('count','sum'),own_fill=('filled_owner','sum')).reset_index()
print(be[be.epoch_id.isin([1,5,10,20,40,100,434])].to_string(index=False))

print("\n=== building types: employee_required by type at epoch 1 vs 434 ===")
for ep in [1,434]:
    sub=bld[(bld.epoch_id==ep)&(~bld.is_construction.astype(bool))]
    g=sub.groupby('type_id').agg(grp=('group_index','count'),cnt=('count','sum'),
      erq=('employee_required','sum'),efl=('employee_filled','sum'),
      ofl=('filled_owner','sum'),margin=('realized_profit_margin_q16',lambda x:(x/Q16).mean()),
      util=('planned_utilization_q16',lambda x:(x/Q16).mean()),opst=('operating_state','mean')).reset_index()
    print(f"--- epoch {ep} ---"); print(g.to_string(index=False))

print("\n=== goods that actually move (nonzero demand or changing price) ===")
m=mkt.copy()
gg=m.groupby('good_id').agg(dem=('demand_ema','mean'),pmin=('price','min'),pmax=('price','max'),
   bd=('business_demand_ema','mean')).reset_index()
active=gg[(gg.dem>0)|(gg.pmax!=gg.pmin)|(gg.bd>0)]
print("Active goods (%d of %d):" % (len(active), len(gg)))
print(active.to_string(index=False))

print("\n=== support money issued vs building wages (money creation check) ===")
print("producer_support_money_issued total:", summ.producer_support_money_issued.sum())
print("building_wages_paid total:", summ.building_wages_paid.sum())
print("merchant_procurement_spent total:", summ.merchant_procurement_spent.sum())
print("output supported total:", summ.production_output_supported.sum())
print("output discarded total:", summ.production_output_discarded.sum())
# fraction of output that is 'supported' (subsidy-absorbed) vs sold
print("\nsupported/stock ratio per epoch (sampled):")
s2=summ[['epoch_id','production_output_stock','production_output_supported','production_output_discarded','producer_support_money_issued']].copy()
s2['sup_ratio']=s2.production_output_supported/s2.production_output_stock
print(s2.iloc[::60].to_string(index=False))
