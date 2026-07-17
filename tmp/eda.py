import pandas as pd, numpy as np, os, glob, json

BASE = "D:/Godot/ProjectKeynes/Project.Keynes/tmp"
PREF = "economy_record_20260717_104150_v5_cell1110_q21_r18"
BLD_DIR = "D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/data/economy/buildings"
Q16 = 65536.0

def q(x):  # q16 to float
    return (x.astype(float)/Q16) if hasattr(x,'astype') else float(x)/Q16

# ---- building name mapping (alphabetical stable id = type_id) ----
bnames = sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(BLD_DIR+"/*.tres"))
type2name = {i:n for i,n in enumerate(bnames)}

def rd(name):
    return pd.read_csv(f"{BASE}/{PREF}_{name}.csv", low_memory=False)

out = []
def log(*a):
    s = " ".join(str(x) for x in a)
    out.append(s)

# ============ SUMMARY ============
log("="*70); log("SUMMARY (per-epoch)"); log("="*70)
s = rd("summary")
n_ep = len(s)
log(f"epochs recorded: {n_ep}")
log(f"day_index range: {s.day_index.min()} .. {s.day_index.max()}")
log(f"columns: {list(s.columns)}")
log("--- key series first vs last ---")
for c in ["cohort_count","building_group_count","pending_construction_count",
          "filled_owner_jobs","filled_employee_jobs","unemployed_population",
          "production_output_stock","production_output_discarded","production_output_retained",
          "production_output_supported","producer_support_money_issued",
          "building_wages_paid","building_wages_unpaid",
          "building_resource_generated","building_resource_consumed","building_resource_net_delta",
          "loss_suspended_building_groups",
          "merchant_procurement_budget","merchant_procurement_reserved","merchant_procurement_spent",
          "production_input_reserve_shortfall","population_error","money_error","goods_error"]:
    first, last = s[c].iloc[0], s[c].iloc[-1]
    log(f"  {c:38s} first={first:>18.3g}  last={last:>18.3g}  min={s[c].min():.3g}  max={s[c].max():.3g}")
log("--- unemployment share of (employed+unemployed) ---")
denom = s.filled_owner_jobs + s.filled_employee_jobs + s.unemployed_population
share = (s.unemployed_population/denom.replace(0,np.nan)*100)
log(f"  unemployed %: first={share.iloc[0]:.2f}  last={share.iloc[-1]:.2f}  mean={share.mean():.2f}  max={share.max():.2f}")
log("--- waste ratio (discarded / (stock+discarded+retained)) ---")
tot_out = s.production_output_stock + s.production_output_discarded + s.production_output_retained
waste = s.production_output_discarded/tot_out.replace(0,np.nan)*100
log(f"  waste %: first={waste.iloc[0]:.2f}  last={waste.iloc[-1]:.2f}  mean={waste.mean():.2f}  max={waste.max():.2f}")
log("--- wage unpaid ratio ---")
wun = s.building_wages_unpaid/ (s.building_wages_paid+s.building_wages_unpaid).replace(0,np.nan)*100
log(f"  unpaid wage %: first={wun.iloc[0]:.2f}  last={wun.iloc[-1]:.2f}  mean={wun.mean():.2f}  max={wun.max():.2f}")
log(f"  loss_suspended_building_groups: min={s.loss_suspended_building_groups.min()} max={s.loss_suspended_building_groups.max()} mean={s.loss_suspended_building_groups.mean():.2f}")
log(f"  production_input_reserve_shortfall: min={s.production_input_reserve_shortfall.min():.3g} max={s.production_input_reserve_shortfall.max():.3g} mean={s.production_input_reserve_shortfall.mean():.3g}")
log(f"  population_error/money_error/goods_error all: pop_max={s.population_error.max()} money_max={s.money_error.max()} goods_max={s.goods_error.max()}")
log(f"  trade_runtime_mode values: {s.trade_runtime_mode.value_counts().to_dict()}")
log(f"  epoch_active: {s.epoch_active.value_counts().to_dict()}")
log(f"  stage values: {s.stage.value_counts().to_dict()}")

# ============ COHORTS ============
log("\n"+"="*70); log("COHORTS"); log("="*70)
c = rd("cohorts")
log(f"rows: {len(c)}  distinct epochs: {c.epoch_row_id.nunique()}  distinct cohort_index: {c.cohort_index.nunique()}")
epc = c.groupby('epoch_row_id').size()
log(f"cohort rows per epoch: min={epc.min()} max={epc.max()} mean={epc.mean():.1f}")
# aggregate per epoch
g = c.groupby('epoch_row_id').agg(popn=('population','sum'),
    own=('owner_employed','sum'), emp=('employee_employed','sum'),
    unem=('unemployed','sum'), funds=('funds','sum'),
    n=('population','size'), merch=('is_merchant','sum'))
g['unem_pct'] = g.unem/(g.own+g.emp+g.unem).replace(0,np.nan)*100
log(f"total population first epoch={g.popn.iloc[0]:.0f} last={g.popn.iloc[-1]:.0f}")
log(f"unemployed first={g.unem.iloc[0]:.0f} last={g.unem.iloc[-1]:.0f}  % first={g.unem_pct.iloc[0]:.2f} last={g.unem_pct.iloc[-1]:.2f}")
log(f"owner_employed first={g.own.iloc[0]:.0f} last={g.own.iloc[-1]:.0f}")
log(f"employee_employed first={g.emp.iloc[0]:.0f} last={g.emp.iloc[-1]:.0f}")
log(f"merchant cohorts count (is_merchant sum) first={g.merch.iloc[0]:.0f} last={g.merch.iloc[-1]:.0f}")
log(f"total funds first={g.funds.iloc[0]:.0f} last={g.funds.iloc[-1]:.0f}  (money sub-units; /10000 = units)")
# by profession
log("--- by profession_id (last epoch recorded) ---")
last_ep = c.epoch_row_id.max()
cl = c[c.epoch_row_id==last_ep]
by_prof = cl.groupby('profession_id').agg(pop=('population','sum'),unem=('unemployed','sum'),
    own=('owner_employed','sum'),emp=('employee_employed','sum'),funds=('funds','sum'),n=('population','size'))
by_prof['unem_pct']=by_prof.unem/(by_prof.own+by_prof.emp+by_prof.unem).replace(0,np.nan)*100
log(by_prof.sort_values('pop',ascending=False).to_string())
# satisfaction / worst_need
log("--- satisfaction_q16 (last epoch) quantiles ---")
log(f"  min={c.satisfaction_q16.min()} max={c.satisfaction_q16.max()} mean={q(c.satisfaction_q16).mean():.3f}")
log(f"  worst_need_id value counts (top): {c.worst_need_id.value_counts().head(8).to_dict()}")
# funds distribution last epoch
log("--- funds per person (last epoch) quantiles (funds/10000/pop) ---")
fp = (cl.funds/10000.0/cl.population.replace(0,np.nan))
log(f"  min={fp.min():.2f} p25={fp.quantile(.25):.2f} median={fp.median():.2f} p75={fp.quantile(.75):.2f} max={fp.max():.2f}")

# ============ BUILDINGS ============
log("\n"+"="*70); log("BUILDINGS"); log("="*70)
b = rd("buildings")
log(f"rows: {len(b)}  distinct epochs: {b.epoch_row_id.nunique()}")
log(f"is_construction value counts: {b.is_construction.value_counts().to_dict()}")
log(f"operating_state value counts: {b.operating_state.value_counts().to_dict()}  (0=active,1=suspended_loss)")
log(f"wage_suspended value counts: {b.wage_suspended.value_counts().to_dict()}")
# type distribution + names
bt = b.groupby('type_id').agg(n=('type_id','size'),
    is_constr=('is_construction','mean'),
    op_susp=('operating_state','mean'),
    wage_susp=('wage_suspended','mean'))
bt['name']=[type2name.get(i,'?') for i in bt.index]
bt = bt.sort_values('n',ascending=False)
log("--- top building types by row count (name | rows | %construction | %suspended | %wage_susp) ---")
for i,r in bt.head(25).iterrows():
    log(f"  [{i:3d}] {r['name']:28s} n={int(r.n):5d}  constr={r.is_constr:.2f}  susp={r.op_susp:.2f}  wsup={r.wage_susp:.2f}")
# operating (non-construction) building stats, last epoch
bl = b[b.epoch_row_id==b.epoch_row_id.max()]
bop = bl[bl.is_construction==0]
log(f"\nlast epoch operating building rows: {len(bop)}")
if len(bop):
    own_req = bop.owner_required.replace(0,np.nan)
    emp_req = bop.employee_required.replace(0,np.nan)
    log(f"  owner fill ratio mean={ (bop.filled_owner/own_req).mean():.3f}  (0 means unfilled)")
    log(f"  employee fill ratio mean={ (bop.employee_filled/emp_req).mean():.3f}")
    log(f"  % with zero owner fill: {(bop.filled_owner==0).mean()*100:.1f}")
    log(f"  % with zero employee fill: {(bop.employee_filled==0).mean()*100:.1f}")
    log(f"  last_margin_gap_q16 mean={q(bop.last_margin_gap_q16).mean():.4f}  median={q(bop.last_margin_gap_q16).median():.4f}")
    log(f"  realized_profit_margin_q16: present? { (bop.realized_profit_margin_q16!=0).mean()*100:.1f}% nonzero")
    log(f"  severe_loss_cycles>0: {(bop.severe_loss_cycles>0).mean()*100:.1f}%")
    log(f"  last_discarded sum={bop.last_discarded.sum():.3g}  last_retained sum={bop.last_retained.sum():.3g}  last_sold sum={bop.last_sold.sum():.3g}")
    log(f"  last_resource_generated sum={bop.last_resource_generated.sum():.3g}  last_resource sum(consumed)={bop.last_resource.sum():.3g}")
    log(f"  last_revenue sum={bop.last_revenue.sum():.3g}  last_input_cost sum={bop.last_input_cost.sum():.3g}  last_wages_paid sum={bop.last_wages_paid.sum():.3g}  last_wages_due sum={bop.last_wages_due.sum():.3g}")

# ============ MARKET ============
log("\n"+"="*70); log("MARKET"); log("="*70)
m = rd("market")
log(f"rows: {len(m)}  distinct goods: {m.good_id.nunique()}  distinct epochs: {m.epoch_row_id.nunique()}")
log(f"storage_mode value counts: {m.storage_mode.value_counts().to_dict()}")
log(f"trade_enabled value counts: {m.trade_enabled.value_counts().to_dict()}")
# which goods ever had stock or demand or non-default price
m['active'] = (m.stock>0)|(m.demand_ema>0)|(m.business_demand_ema>0)
active_goods = m[m.active].good_id.unique()
log(f"goods with any activity (stock>0|demand>0|busdemand>0): {len(active_goods)} of {m.good_id.nunique()}")
# last epoch snapshot of active goods
ml = m[m.epoch_row_id==m.epoch_row_id.max()]
mla = ml[ml.good_id.isin(active_goods)]
cols=["good_id","stock","price","demand_ema","business_demand_ema","offered_supply_ema","shortage_q16","price_pressure_total_q16","cost_anchor_price","category_id","storage_mode"]
log(f"--- last epoch: {len(mla)} active goods (stock>0/demand>0) ---")
log(mla[cols].sort_values('stock',ascending=False).to_string(index=False))
log(f"\ncategory_id distribution among ALL goods: {m.category_id.value_counts().to_dict()}")
# price dynamics: pick a few active goods, show price first vs last
log("--- price trajectory (first vs last epoch) for active goods ---")
for gid in list(mla.good_id):
    sub = m[m.good_id==gid].sort_values('epoch_row_id')
    if len(sub)>=2:
        log(f"  {gid:28s} price first={sub.price.iloc[0]:.0f} last={sub.price.iloc[-1]:.0f}  shortage_last={sub.shortage_q16.iloc[-1]:.0f}  pprice_last={sub.price_pressure_total_q16.iloc[-1]:.0f}")

# ============ RESOURCES ============
log("\n"+"="*70); log("RESOURCES"); log("="*70)
r = rd("resources")
log(f"rows: {len(r)}  distinct resources: {r.resource_id.nunique()}  distinct epochs: {r.epoch_row_id.nunique()}")
r0 = r[r.epoch_row_id==r.epoch_row_id.min()].set_index('resource_id').reserve
r1 = r[r.epoch_row_id==r.epoch_row_id.max()].set_index('resource_id').reserve
rr = pd.DataFrame({'first':r0,'last':r1}).fillna(0)
rr['change_%']=(rr.last-rr.first)/rr.first.replace(0,np.nan)*100
log(rr.sort_values('last',ascending=False).to_string())

txt = "\n".join(out)
with open(BASE+"/eda_report.txt","w",encoding="utf-8") as f:
    f.write(txt)
print(txt)
