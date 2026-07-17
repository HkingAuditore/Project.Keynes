import pandas as pd, numpy as np, json
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
MONEY=10000.0; GOODS=1000.0; Q16=65536.0
s=pd.read_csv(base+"summary.csv"); c=pd.read_csv(base+"cohorts.csv")
m=pd.read_csv(base+"market.csv"); r=pd.read_csv(base+"resources.csv"); b=pd.read_csv(base+"buildings.csv")

PROF={0:'agri_worker',2:'artisan',8:'fisher',9:'forager',12:'hunter',20:'merchant',22:'miner',27:'subsist_farmer',31:'unemployed'}
NEED={10:'produce',11:'protein',13:'staple_food'}
BTYPE={30:'communal_hearth',65:'flint_quarry',69:'gathering_ground',79:'weaving_shelter',90:'knapping_workshop',
       102:'fish_collector',106:'merchant_post',203:'placer_gold',238:'hunting_camp',239:'stone_collector',242:'subsistence_farm'}

out={}
# ---- GLOBAL summary ----
days=s.day_index.tolist()
emp=(s.filled_owner_jobs+s.filled_employee_jobs)
out['global']={
 'day':days,
 'labor_owner':s.filled_owner_jobs.tolist(),
 'labor_employee':s.filled_employee_jobs.tolist(),
 'unemployed':s.unemployed_population.tolist(),
 'labor_total':(emp+s.unemployed_population).tolist(),
 'suspended':s.loss_suspended_building_groups.tolist(),
 'merch_budget':(s.merchant_procurement_budget/MONEY).tolist(),
 'merch_spent':(s.merchant_procurement_spent/MONEY).tolist(),
 'merch_reserved':(s.merchant_procurement_reserved/MONEY).tolist(),
 'subsidy':(s.producer_support_money_issued/MONEY).tolist(),
 'wages_paid':(s.building_wages_paid/MONEY).tolist(),
 'res_gen':s.building_resource_generated.tolist(),
 'res_con':s.building_resource_consumed.tolist(),
 'out_stock':s.production_output_stock.tolist(),
 'out_supported':s.production_output_supported.tolist(),
 'out_retained':s.production_output_retained.tolist(),
}
out['global_kpi']={
 'labor_first':int((emp+s.unemployed_population).iloc[0]),
 'labor_last':int((emp+s.unemployed_population).iloc[-1]),
 'owner_first':int(s.filled_owner_jobs.iloc[0]),'owner_last':int(s.filled_owner_jobs.iloc[-1]),
 'susp_last':int(s.loss_suspended_building_groups.iloc[-1]),
 'merch_spend_ratio_last':float(s.merchant_procurement_spent.iloc[-1]/s.merchant_procurement_budget.iloc[-1]),
 'merch_reserved_last':float(s.merchant_procurement_reserved.iloc[-1]/MONEY),
}

# ---- CELL population by profession ----
cdays=sorted(c.day_index.unique())
prof_series={}
for pid in sorted(c.profession_id.unique()):
    ser=[]
    for d in cdays:
        g=c[(c.day_index==d)&(c.profession_id==pid)]
        ser.append(int(g.population.sum()))
    prof_series[PROF.get(pid,str(pid))]=ser
out['cell_pop']={'day':cdays,'by_prof':prof_series}

# ---- CELL funds by profession ----
funds_series={}
for pid in sorted(c.profession_id.unique()):
    ser=[]
    for d in cdays:
        g=c[(c.day_index==d)&(c.profession_id==pid)]
        ser.append(round(g.funds.sum()/MONEY,0))
    funds_series[PROF.get(pid,str(pid))]=ser
out['cell_funds']={'day':cdays,'by_prof':funds_series}

# wealth concentration: merchant+miner share of total funds
tot_funds=[]; elite_share=[]
for d in cdays:
    g=c[c.day_index==d]; tf=g.funds.sum()
    elite=g[g.profession_id.isin([20,22])].funds.sum()
    tot_funds.append(round(tf/MONEY,0)); elite_share.append(round(100*elite/max(1,tf),1))
out['cell_wealth']={'day':cdays,'total_funds':tot_funds,'elite_share_pct':elite_share}

# ---- CELL satisfaction pop-weighted ----
sat=[]; 
for d in cdays:
    g=c[c.day_index==d]; sat.append(round((g.satisfaction_q16*g.population).sum()/max(1,g.population.sum())/Q16,3))
out['cell_sat']={'day':cdays,'sat':sat}

# ---- MARKET prices: raw vs processed ----
raw=['gathered_plants','fish','flint','raw_hide','raw_stone']
proc=['processed_food','chipped_stone_tools','game_meat','logs','cloth','fur']
mdays=sorted(m.day_index.unique())
def price_series(gid):
    g=m[m.good_id==gid].sort_values('day_index'); return (g.price/MONEY).round(4).tolist()
out['prices']={'day':mdays,'raw':{g:price_series(g) for g in raw},'proc':{g:price_series(g) for g in proc}}
# shortage for processed
out['shortage']={'day':mdays,'proc':{g:(m[m.good_id==g].sort_values('day_index').shortage_q16/Q16).round(3).tolist() for g in proc}}

# ---- RESOURCES: wild_game & key ----
rdays=sorted(r.day_index.unique())
def res_series(rid):
    g=r[r.resource_id==rid].sort_values('day_index'); return g.reserve.round(1).tolist()
out['resources']={'day':rdays,'wild_game':res_series('wild_game'),'clay':res_series('clay'),
    'fertile_soil':res_series('fertile_soil'),'timber':res_series('timber')}

# ---- BUILDING output/util by type ----
bdays=sorted(b.day_index.unique())
btype_out={}; btype_util={}
for tid in sorted(b.type_id.unique()):
    o=[]; u=[]
    for d in bdays:
        g=b[(b.day_index==d)&(b.type_id==tid)]
        o.append(round(g.last_output.sum()/GOODS,2))
        u.append(round((g.planned_utilization_q16/Q16).mean(),3) if len(g) else 0)
    nm=BTYPE.get(tid,str(tid))
    btype_out[nm]=o; btype_util[nm]=u
out['buildings']={'day':bdays,'output':btype_out,'util':btype_util}

# KPI cell
f0=c[c.day_index==cdays[0]]; fL=c[c.day_index==cdays[-1]]
out['cell_kpi']={
 'pop_first':int(f0.population.sum()),'pop_last':int(fL.population.sum()),
 'cohorts_first':int(len(f0)),'cohorts_last':int(len(fL)),
 'funds_first':round(f0.funds.sum()/MONEY,0),'funds_last':round(fL.funds.sum()/MONEY,0),
 'elite_share_last':elite_share[-1],
 'wild_game_depleted_pct':round(100*(1-res_series('wild_game')[-1]/res_series('wild_game')[0]),1),
 'sat_last':sat[-1],
 'dead_profs':[PROF.get(p) for p in [12,2] ],
}
def _conv(o):
    if isinstance(o,(np.integer,)): return int(o)
    if isinstance(o,(np.floating,)): return float(o)
    if isinstance(o,np.ndarray): return o.tolist()
    raise TypeError(str(type(o)))
json.dump(out,open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/econ_report_data.json","w"),ensure_ascii=False,default=_conv)
print("KPI global:",json.dumps(out['global_kpi'],ensure_ascii=False))
print("KPI cell:",json.dumps(out['cell_kpi'],ensure_ascii=False))
print("wealth elite share first->last:",elite_share[0],"->",elite_share[-1])
print("saved econ_report_data.json")
