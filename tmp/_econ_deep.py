import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 90); pd.set_option('display.max_rows', 300)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_114418_v5_cell1031_q3_r17_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")
d0,dN=C.day_index.min(),C.day_index.max()

print("############ A. 阶层(profession)人口/资金 演化 ############")
piv_pop=C.pivot_table(index='day_index',columns='profession_id',values='population',aggfunc='sum')
piv_fund=C.pivot_table(index='day_index',columns='profession_id',values='funds',aggfunc='sum')
print("各profession人口(每60周期):"); print(piv_pop.iloc[::60].fillna(0).astype(int).to_string())
print("\n各profession资金(每60周期):"); print(piv_fund.iloc[::60].fillna(0).astype(int).to_string())

print("\n############ B. 满意度/worst_need 演化 ############")
sat=C.groupby('day_index').apply(lambda x:(x.satisfaction_q16*x.population).sum()/max(x.population.sum(),1)/65535, include_groups=False).round(3)
print("人口加权满意度(每40):"); print(sat.iloc[::40].to_string())
print("\nworst_need_id 末期分布:"); print(C[C.day_index==dN][['profession_id','population','worst_need_id','satisfaction_q16']].to_string(index=False))

print("\n############ C. 物价 演化 (全部120种商品有交易的) ############")
# 找有价格且价格变化大的商品
mp=M.pivot_table(index='day_index',columns='good_id',values='price',aggfunc='mean')
last=mp.iloc[-1]; first=mp.iloc[0]
chg=((last-first)/first.replace(0,np.nan)).sort_values()
print("价格变化最大(涨):"); print(chg.dropna().tail(12).round(2).to_string())
print("价格变化最大(跌):"); print(chg.dropna().head(12).round(2).to_string())
# 总体物价指数
print("\n有效商品数(price>0)按周期:")
pc=M[M.price>0].groupby('day_index').good_id.nunique()
print(pc.iloc[::50].to_string())

print("\n############ D. 库存/短缺 ############")
short=M.groupby('day_index').apply(lambda x:(x.shortage_q16>0).sum(), include_groups=False)
print("短缺商品数(shortage_q16>0)每50:"); print(short.iloc[::50].to_string())
# 末期高短缺商品
me=M[M.day_index==dN].sort_values('shortage_q16',ascending=False)
print("\n末期短缺TOP10:"); print(me[['good_id','stock','price','demand_ema','offered_supply_ema','shortage_q16','household_available_stock']].head(10).to_string(index=False))

print("\n############ E. 资源储量演化 ############")
rp=R.pivot_table(index='day_index',columns='resource_id',values='reserve',aggfunc='sum')
print("资源储量(每60):"); print(rp.iloc[::60].astype(int).to_string())

print("\n############ F. 建筑用工错配 (末epoch) 汇总 ############")
be=B[B.day_index==dN].copy()
be['owner_gap']=be.filled_owner-be.owner_required
print(be[['type_id','count','owner_required','filled_owner','owner_gap','employee_required','employee_filled','last_output','last_sold','last_discarded','last_revenue','realized_profit_margin_q16']].to_string(index=False))

print("\n############ G. summary 生产/工资/资源 宏观 ############")
sm=S[['day_index','production_output_stock','production_output_discarded','production_output_supported','producer_support_money_issued','building_wages_paid','building_resource_generated','building_resource_consumed','merchant_procurement_spent']].copy()
print(sm.iloc[::50].to_string(index=False))
