import pandas as pd, numpy as np
pd.set_option('display.width', 200); pd.set_option('display.max_columns', 60)
BASE = "economy_record_20260716_162646_v5_cell501_q15_r12_"
Q16 = 65536.0
def q16(x): return x / Q16

summ = pd.read_csv(BASE+"summary.csv")
coh  = pd.read_csv(BASE+"cohorts.csv")
mkt  = pd.read_csv(BASE+"market.csv")
bld  = pd.read_csv(BASE+"buildings.csv")
res  = pd.read_csv(BASE+"resources.csv")
for df in (summ,coh,mkt,bld,res):
    df.columns = [c.lstrip('\ufeff') for c in df.columns]

print("="*70)
print("SUMMARY: epochs=%d, day range %d-%d" % (summ.epoch_id.max(), summ.day_index.min(), summ.day_index.max()))
print("="*70)

# ---- 1. Population & unemployment trajectory ----
summ['total_pop_est'] = coh.groupby('epoch_id')['population'].sum().reindex(summ.epoch_id).values
print("\n--- Population & employment (sampled epochs) ---")
tot = coh.groupby('epoch_id').agg(popn=('population','sum'),
    owner=('owner_employed','sum'), emp=('employee_employed','sum'),
    unemp=('unemployed','sum'), funds=('funds','sum')).reset_index()
tot['unemp_rate'] = tot.unemp / tot.popn
tot = tot.merge(summ[['epoch_id','day_index','filled_owner_jobs','filled_employee_jobs','unemployed_population']], on='epoch_id', how='left')
sel = tot.iloc[::40].copy()
print(sel[['epoch_id','day_index','popn','owner','emp','unemp','unemp_rate','funds']].to_string(index=False))
print("\nFinal epoch:", tot.iloc[-1][['epoch_id','popn','owner','emp','unemp','unemp_rate','funds']].to_dict())
print("Peak unemp_rate=%.3f at epoch %d" % (tot.unemp_rate.max(), tot.loc[tot.unemp_rate.idxmax(),'epoch_id']))

# ---- 2. Building health ----
print("\n" + "="*70); print("BUILDINGS")
b = bld.copy()
for c in ['realized_profit_margin_q16','planned_utilization_q16','capacity_q16']:
    b[c[:-4]] = q16(b[c])
lastep = b.epoch_id.max()
bl = b[b.epoch_id==lastep]
print("\n--- Final epoch %d building groups by type ---" % lastep)
g = b[~b.is_construction.astype(bool)].groupby(['epoch_id','type_id']).agg(
    grp=('group_index','count'), cnt=('count','sum'),
    emp_req=('employee_required','sum'), emp_fill=('employee_filled','sum'),
    own_fill=('filled_owner','sum'),
    margin=('realized_profit_margin','mean'),
    util=('planned_utilization','mean'),
    wage_susp=('wage_suspended','sum'),
    sev_loss=('severe_loss_cycles','max'),
    op_state=('operating_state','mean')).reset_index()
gl = g[g.epoch_id==lastep]
print(gl.to_string(index=False))
print("\n--- Employment fill rate over time by type (avg margin) ---")
piv = g.groupby('epoch_id').agg(emp_req=('emp_req','sum'), emp_fill=('emp_fill','sum'), suspended=('wage_susp','sum')).reset_index()
piv['fill_rate']=piv.emp_fill/piv.emp_req
print(piv.iloc[::40].to_string(index=False))

print("\n--- operating_state distribution over time (0=normal,1=suspended) ---")
os_ = b[~b.is_construction.astype(bool)].groupby(['epoch_id','operating_state']).size().unstack(fill_value=0)
print(os_.iloc[::40])

# ---- 3. Summary financial flows ----
print("\n" + "="*70); print("SUMMARY FLOWS (sampled)")
cols=['epoch_id','day_index','filled_owner_jobs','filled_employee_jobs','unemployed_population',
      'production_output_stock','production_output_discarded','production_output_supported',
      'producer_support_money_issued','building_wages_paid','building_wages_unpaid',
      'loss_suspended_building_groups','merchant_procurement_spent',
      'population_error','money_error','goods_error']
print(summ[cols].iloc[::40].to_string(index=False))
print("\nMax errors: pop=%d money=%d goods=%d" % (summ.population_error.abs().max(), summ.money_error.abs().max(), summ.goods_error.abs().max()))
print("Total wages unpaid (sum):", summ.building_wages_unpaid.sum())
print("Total support money issued (sum):", summ.producer_support_money_issued.sum())
print("Total discarded output (sum):", summ.production_output_discarded.sum())

# ---- 4. Market/prices ----
print("\n" + "="*70); print("MARKET / PRICES")
m=mkt.copy()
m['price_f']=m.price/10000.0
mp = m.groupby(['epoch_id','good_id']).agg(price=('price','mean'), stock=('stock','mean'),
    dem=('demand_ema','mean'), shortage=('shortage_q16', lambda x: q16(x.mean())),
    anchor=('cost_anchor_price','mean')).reset_index()
goods = m.good_id.unique()
print("goods:", goods[:30])
for gd in goods:
    sub=mp[mp.good_id==gd]
    print("\n[%s] price first=%.1f last=%.1f max=%.1f min=%.1f | shortage last=%.3f | anchor last=%.1f" % (
        gd, sub.price.iloc[0], sub.price.iloc[-1], sub.price.max(), sub.price.min(),
        sub.shortage.iloc[-1], sub.anchor.iloc[-1]))

# ---- 5. Cohort funds/income by class ----
print("\n" + "="*70); print("COHORT CLASSES")
c=coh.copy()
cl = c.groupby(['epoch_id','profession_id']).agg(popn=('population','sum'), funds=('funds','sum'),
    inc=('epoch_income','sum'), exp=('epoch_expense','sum'),
    sat=('satisfaction_q16', lambda x: q16(x.mean())),
    unemp=('unemployed','sum')).reset_index()
cl['funds_pc']=cl.funds/cl.popn.replace(0,np.nan)
cl['net']=cl.inc-cl.exp
profs=c.profession_id.unique()
print("professions:", profs)
lastep_c=c.epoch_id.max()
print("\n--- Final epoch %d by profession ---" % lastep_c)
print(cl[cl.epoch_id==lastep_c][['profession_id','popn','funds','funds_pc','inc','exp','net','sat']].to_string(index=False))
print("\n--- Funds per capita trajectory by profession (sampled) ---")
for p in profs:
    sub=cl[cl.profession_id==p]
    print("%-14s funds_pc: start=%.0f mid=%.0f end=%.0f | sat end=%.3f | pop start=%.0f end=%.0f" % (
        p, sub.funds_pc.iloc[0], sub.funds_pc.iloc[len(sub)//2], sub.funds_pc.iloc[-1],
        sub.sat.iloc[-1], sub.popn.iloc[0], sub.popn.iloc[-1]))

# ---- worst need distribution ----
print("\n--- worst_need distribution final epoch ---")
print(c[c.epoch_id==lastep_c].groupby('worst_need_id')['population'].sum().sort_values(ascending=False))

# ---- resources ----
print("\n" + "="*70); print("RESOURCES")
r=res.copy()
rr=r.groupby(['epoch_id','resource_id'])['reserve'].sum().reset_index()
for rid in r.resource_id.unique():
    sub=rr[rr.resource_id==rid]
    print("[%s] reserve start=%.0f end=%.0f delta=%.0f" % (rid, sub.reserve.iloc[0], sub.reserve.iloc[-1], sub.reserve.iloc[-1]-sub.reserve.iloc[0]))
