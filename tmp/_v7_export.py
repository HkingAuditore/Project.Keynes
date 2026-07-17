# -*- coding: utf-8 -*-
import pandas as pd, numpy as np, json
def load(pfx):
    b=r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\%s_"%pfx
    return (pd.read_csv(b+"summary.csv"),pd.read_csv(b+"buildings.csv"),
            pd.read_csv(b+"cohorts.csv"),pd.read_csv(b+"market.csv"),pd.read_csv(b+"resources.csv"))

S,B,C,M,R = load("economy_record_20260717_140702_v7_cell1060_q32_r17")
# v5 for comparison
S5,B5,C5,M5,R5 = load("economy_record_20260717_114418_v5_cell1031_q3_r17")

def series(S,C,M,R,B):
    days=sorted(C.day_index.unique()); step=3; days=days
    Ss=S.set_index('day_index')
    C=C.copy()
    C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22,11,18]),'elite','producer'))
    pm=C.groupby(['day_index','grp']).population.sum().unstack(fill_value=0).reindex(days).fillna(0)
    fm=C.groupby(['day_index','grp']).funds.sum().unstack(fill_value=0).reindex(days).fillna(0)
    tot=fm.sum(axis=1).replace(0,np.nan)
    sat=C.groupby('day_index').apply(lambda x:(x.satisfaction_q16*x.population).sum()/max(x.population.sum(),1)/65535, include_groups=False).reindex(days).round(4)
    tname={30:'公共炉灶',65:'燧石采石场',69:'采集地',79:'织布棚',90:'打制石器工坊',102:'海鱼采集点',106:'商站',203:'砂金开采',238:'狩猎营地',239:'集石点',242:'地表采银'}
    bf=B.pivot_table(index='day_index',columns='type_id',values='filled_owner',aggfunc='sum').reindex(days).fillna(0)
    goods=['flint','chipped_stone_tools','game_meat','fur','cloth','gathered_plants','fish','raw_stone']
    price={g:(M[M.good_id==g].set_index('day_index').reindex(days)['price'].fillna(0).astype(int).tolist()) for g in goods}
    res=['wild_game','clay','fertile_soil','marine_fish']
    rp=R.pivot_table(index='day_index',columns='resource_id',values='reserve',aggfunc='sum').reindex(days).fillna(0)
    resd={r:(rp[r]/max(rp[r].iloc[0],1)*100).round(1).tolist() for r in res if r in rp}
    out={
      'days':days,
      'pop':{g:pm[g].astype(int).tolist() for g in ['producer','merchant','elite'] if g in pm},
      'fpct':{g:(fm[g]/tot*100).round(2).fillna(0).tolist() for g in ['producer','merchant','elite'] if g in fm},
      'sat':sat.fillna(0).tolist(),
      'glob':{'owner':Ss['filled_owner_jobs'].reindex(days).tolist(),'emp':Ss['filled_employee_jobs'].reindex(days).tolist(),'unemp':Ss['unemployed_population'].reindex(days).tolist()},
      'build_own':{tname.get(c,str(c)):bf[c].astype(int).tolist() for c in bf.columns},
      'price':price, 'res':resd,
    }
    # v7-only fields
    for f in ['births','deaths','trade_scan_total','trade_completed_scans','trade_candidates_generated','loss_suspended_building_groups']:
        if f in Ss.columns: out[f]=Ss[f].reindex(days).fillna(0).astype(int).tolist()
    out['loss_susp']=Ss['loss_suspended_building_groups'].reindex(days).fillna(0).astype(int).tolist() if 'loss_suspended_building_groups' in Ss else []
    return out

v7=series(S,C,M,R,B)
v5=series(S5,C5,M5,R5,B5)
# 对齐对比: 用各自 days 的归一化进度(0-1)重采样到同一 x
def kpi(S,C):
    C=C.copy();C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22,11,18]),'elite','producer'))
    d0=sorted(C.day_index.unique());dN=d0[-1]
    f0=C[C.day_index==d0[0]];fN=C[C.day_index==dN]
    def prodpct(x):
        fm=x.groupby('grp').funds.sum();return round(fm.get('producer',0)/max(fm.sum(),1)*100,1)
    return {'pop0':int(f0.population.sum()),'popN':int(fN.population.sum()),
            'prod_fpct0':prodpct(f0),'prod_fpctN':prodpct(fN),
            'owner0':int(S.iloc[0].filled_owner_jobs),'ownerN':int(S.iloc[-1].filled_owner_jobs)}
cmp={'v5':kpi(S5,C5),'v7':kpi(S,C),
     'v7_births':int(S.births.sum()),'v7_deaths':int(S.deaths.sum()),
     'v7_trade_arrived':int(S.trade_orders_arrived.sum()),'v7_trade_scans':int(S.trade_completed_scans.sum())}

def conv(o):
    if isinstance(o,np.integer):return int(o)
    if isinstance(o,np.floating):return float(o)
    return str(o)
with open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\_v7_data.json","w",encoding="utf-8") as f:
    json.dump({'v7':v7,'v5':v5,'cmp':cmp},f,ensure_ascii=False,default=conv)
print("exported. v7 days",len(v7['days']),"v5 days",len(v5['days']))
print("cmp:",json.dumps(cmp,ensure_ascii=False))
