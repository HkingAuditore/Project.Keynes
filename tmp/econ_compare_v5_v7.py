import pandas as pd, numpy as np, json
MONEY=10000.0; GOODS=1000.0; Q16=65536.0
V5="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
V7="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_140702_v7_cell1060_q32_r17_"
PROF={0:'agri_worker',2:'artisan',8:'fisher',9:'forager',12:'hunter',20:'merchant',22:'miner',27:'subsist_farmer',31:'unemployed'}
NEED={10:'produce',11:'protein',13:'staple_food'}
BTYPE={30:'communal_hearth',65:'flint_quarry',69:'gathering_ground',79:'weaving_shelter',90:'knapping_workshop',
       102:'fish_collector',106:'merchant_post',203:'placer_gold',238:'hunting_camp',239:'stone_collector',242:'subspecies_farm'}

def col(df,name):
    return df[name] if name in df.columns else pd.Series([0]*len(df))
def load(b):
    return dict(s=pd.read_csv(b+"summary.csv"),c=pd.read_csv(b+"cohorts.csv"),
                m=pd.read_csv(b+"market.csv"),r=pd.read_csv(b+"resources.csv"),b=pd.read_csv(b+"buildings.csv"))

def compute(tag, D):
    s,c,m,r,b=D['s'],D['c'],D['m'],D['r'],D['b']
    out={}
    days=s.day_index.tolist()
    emp=(s.filled_owner_jobs+s.filled_employee_jobs)
    out['global']={'day':days,'labor_owner':s.filled_owner_jobs.tolist(),
        'labor_employee':s.filled_employee_jobs.tolist(),
        'unemployed':s.unemployed_population.tolist(),
        'labor_total':(emp+s.unemployed_population).tolist(),
        'suspended':s.loss_suspended_building_groups.tolist(),
        'merch_budget':(s.merchant_procurement_budget/MONEY).tolist(),
        'merch_spent':(s.merchant_procurement_spent/MONEY).tolist(),
        'subsidy':(s.producer_support_money_issued/MONEY).tolist(),
        'births':col(s,'births').tolist(),'deaths':col(s,'deaths').tolist(),
        'pending_construction':col(s,'pending_construction_count').tolist(),
        'wages_paid':(s.building_wages_paid/MONEY).tolist(),
        'res_gen':s.building_resource_generated.tolist(),
        'res_con':s.building_resource_consumed.tolist()}
    cdays=sorted(c.day_index.unique())
    prof_pop={}; prof_fund={}
    for pid in sorted(c.profession_id.unique()):
        prof_pop[PROF.get(pid,str(pid))]=[int(c[(c.day_index==d)&(c.profession_id==pid)].population.sum()) for d in cdays]
        prof_fund[PROF.get(pid,str(pid))]=[round(c[(c.day_index==d)&(c.profession_id==pid)].funds.sum()/MONEY,0) for d in cdays]
    tot_funds=[]; elite_share=[]
    for d in cdays:
        g=c[c.day_index==d]; tf=g.funds.sum(); elite=g[g.profession_id.isin([20,22])].funds.sum()
        tot_funds.append(round(tf/MONEY,0)); elite_share.append(round(100*elite/max(1,tf),1))
    sat=[round((g.satisfaction_q16*g.population).sum()/max(1,g.population.sum())/Q16,3) for d in cdays]
    out['cell']={'day':cdays,'pop_by_prof':prof_pop,'fund_by_prof':prof_fund,
        'tot_funds':tot_funds,'elite_share_pct':elite_share,'sat':sat}
    mdays=sorted(m.day_index.unique())
    raw=['gathered_plants','fish','flint','raw_hide','raw_stone']
    proc=['processed_food','chipped_stone_tools','game_meat','logs','cloth','fur']
    out['raw_goods']=raw; out['proc_goods']=proc
    def ps(gid):
        g=m[m.good_id==gid].sort_values('day_index'); return (g.price/MONEY).round(4).tolist()
    def ss(gid):
        g=m[m.good_id==gid].sort_values('day_index'); return (g.shortage_q16/Q16).round(2).tolist()
    out['prices']={'day':mdays,'raw':{g:ps(g) for g in raw},'proc':{g:ps(g) for g in proc}}
    out['shortage']={'day':mdays,'proc':{g:ss(g) for g in proc}}
    def rs(rid):
        g=r[r.resource_id==rid].sort_values('day_index'); return g.reserve.round(1).tolist()
    out['resources']={'day':sorted(r.day_index.unique()),'wild_game':rs('wild_game'),
        'clay':rs('clay'),'fertile_soil':rs('fertile_soil'),'timber':rs('timber'),'salt':rs('salt')}
    bdays=sorted(b.day_index.unique())
    btype_out={}; btype_util={}
    for tid in sorted(b.type_id.unique()):
        o=[round(b[(b.day_index==d)&(b.type_id==tid)].last_output.sum()/GOODS,2) for d in bdays]
        u=[round((b[(b.day_index==d)&(b.type_id==tid)].planned_utilization_q16/Q16).mean(),3) if len(b[(b.day_index==d)&(b.type_id==tid)]) else 0 for d in bdays]
        btype_out[BTYPE.get(tid,str(tid))]=o; btype_util[BTYPE.get(tid,str(tid))]=u
    out['buildings']={'day':bdays,'output':btype_out,'util':btype_util}
    # trade (v7 only has meaningful)
    tfields=['trade_runtime_mode','trade_topology_ready','trade_topology_generation','trade_country_generation',
             'trade_orders_in_flight','trade_orders_dispatched','trade_orders_arrived','trade_capacity_used',
             'trade_capacity_available','trade_candidates_accepted','trade_rejected_profit','trade_rejected_capacity',
             'trade_rejected_stock','trade_rejected_cash','trade_rejected_route']
    out['trade']={f:s[f].tolist() for f in tfields if f in s.columns}
    # KPI
    f0=c[c.day_index==cdays[0]]; fL=c[c.day_index==cdays[-1]]
    wg=rs('wild_game')
    out['kpi']={
        'cell_pop_first':int(f0.population.sum()),'cell_pop_last':int(fL.population.sum()),
        'cell_pop_delta_pct':round(100*(fL.population.sum()-f0.population.sum())/max(1,f0.population.sum()),1),
        'cohorts_first':int(len(f0)),'cohorts_last':int(len(fL)),
        'elite_share_first':elite_share[0],'elite_share_last':elite_share[-1],
        'sat_first':sat[0],'sat_last':sat[-1],
        'labor_first':int((emp+s.unemployed_population).iloc[0]),'labor_last':int((emp+s.unemployed_population).iloc[-1]),
        'unemployed_first':int(s.unemployed_population.iloc[0]),'unemployed_last':int(s.unemployed_population.iloc[-1]),
        'suspended_last':int(s.loss_suspended_building_groups.iloc[-1]),
        'merch_spend_ratio_last':round(float(s.merchant_procurement_spent.iloc[-1]/max(1,s.merchant_procurement_budget.iloc[-1])),4),
        'merch_reserved_last':round(float(s.merchant_procurement_reserved.iloc[-1]/MONEY),0),
        'pending_construction_last':int(s.pending_construction_count.iloc[-1]),
        'births_total':int(col(s,'births').sum()),
        'loss_suspended_peak':int(s.loss_suspended_building_groups.max()),
        'wild_game_depleted_pct':round(100*(1-wg[-1]/max(1,wg[0])),1),
        'audit_pop_ok':bool((s.population_error==0).all()),
        'audit_money_ok':bool((s.money_error==0).all()),
        'audit_goods_ok':bool((s.goods_error==0).all()),
        'professions':[PROF.get(p,str(p)) for p in sorted(c.profession_id.unique())],
    }
    return out

runs={}
runs['v5']=compute('v5',load(V5))
runs['v7']=compute('v7',load(V7))
out={'runs':runs}
def _conv(o):
    if isinstance(o,(np.integer,)): return int(o)
    if isinstance(o,(np.floating,)): return float(o)
    if isinstance(o,np.ndarray): return o.tolist()
    if isinstance(o,(np.bool_,)): return bool(o)
    raise TypeError(str(type(o)))
json.dump(out,open("D:/Godot/ProjectKeynes/Project.Keynes/tmp/econ_compare_v5_v7.json","w"),ensure_ascii=False,default=_conv)
print("=== KPI comparison ===")
for k in ['cell_pop_first','cell_pop_last','cell_pop_delta_pct','elite_share_first','elite_share_last',
          'sat_first','sat_last','labor_first','labor_last','unemployed_first','unemployed_last',
          'suspended_last','merch_spend_ratio_last','merch_reserved_last','pending_construction_last',
          'births_total','loss_suspended_peak','wild_game_depleted_pct','audit_pop_ok','audit_goods_ok']:
    print(f"  {k:24s} v5={runs['v5']['kpi'][k]}  v7={runs['v7']['kpi'][k]}")
print("saved econ_compare_v5_v7.json")
