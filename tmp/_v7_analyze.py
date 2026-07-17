import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 90); pd.set_option('display.max_rows', 200)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_140702_v7_cell1060_q32_r17_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")
days=sorted(C.day_index.unique())
print("epochs:",S.epoch_id.nunique(),"day range:",S.day_index.min(),"-",S.day_index.max())
print("守恒误差 pop/money/goods:", S.population_error.abs().max(), S.money_error.abs().max(), S.goods_error.abs().max())

print("\n############ 1. 出生/死亡机制是否生效 ############")
bd=S[['day_index','births','deaths']].copy()
print("births 总和:",S.births.sum()," deaths 总和:",S.deaths.sum())
print("births 非零周期数:",(S.births>0).sum(),"/ ",len(S))
print(bd.iloc[::40].to_string(index=False))

print("\n############ 2. 全局就业/人口 (summary) ############")
g=S[['day_index','filled_owner_jobs','filled_employee_jobs','unemployed_population','cohort_count','building_group_count','loss_suspended_building_groups','pending_construction_count']].copy()
print(g.iloc[::40].to_string(index=False))
print("首:",g.iloc[0].to_dict())
print("末:",g.iloc[-1].to_dict())

print("\n############ 3. cell1060 人口/财富分组 ############")
C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22,11,18]),'elite','producer'))
pm=C.groupby(['day_index','grp']).population.sum().unstack(fill_value=0).reindex(days).fillna(0)
fm=C.groupby(['day_index','grp']).funds.sum().unstack(fill_value=0).reindex(days).fillna(0)
tot=fm.sum(axis=1).replace(0,np.nan)
print("人口分组(每40):"); print(pm.iloc[::40].astype(int).to_string())
print("\n财富占比%(每40):")
fp=pd.DataFrame({c:(fm[c]/tot*100).round(1) for c in fm.columns})
print(fp.iloc[::40].to_string())
print("\ncell总人口:",int(pm.sum(axis=1).iloc[0]),"->",int(pm.sum(axis=1).iloc[-1]))

print("\n############ 4. 满意度 & worst_need ############")
sat=C.groupby('day_index').apply(lambda x:(x.satisfaction_q16*x.population).sum()/max(x.population.sum(),1)/65535, include_groups=False).reindex(days).round(3)
print("满意度(每40):"); print(sat.iloc[::40].to_string())
print("\n末期各cohort:")
dN=days[-1]
print(C[C.day_index==dN][['profession_id','population','funds','is_merchant','satisfaction_q16','worst_need_id','owner_employed','employee_employed','unemployed']].to_string(index=False))

print("\n############ 5. 贸易系统活跃度 ############")
tr=S[['day_index','trade_topology_ready','trade_candidates_accepted','trade_orders_dispatched','trade_orders_arrived','trade_capacity_used','trade_rejected_profit','trade_rejected_cash']].copy()
print(tr.iloc[::40].to_string(index=False))
print("累计 orders_arrived:",S.trade_orders_arrived.sum(),"candidates_accepted:",S.trade_candidates_accepted.sum())
