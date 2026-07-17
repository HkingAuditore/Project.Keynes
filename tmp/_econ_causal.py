import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 90)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_114418_v5_cell1031_q3_r17_"
B=pd.read_csv(base+"buildings.csv"); C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv")

# type_id 名称
tname={30:'communal_hearth',65:'flint_quarry',69:'gathering_ground',79:'weaving_shelter',
90:'knapping_workshop',102:'marine_fish_collector',106:'merchant_post',203:'placer_gold',
238:'hunting_camp',239:'stone_collector',242:'surface_silver'}

print("############ 建筑产出(last_output)随时间: 何时停产 ############")
bo=B.pivot_table(index='day_index',columns='type_id',values='last_output',aggfunc='sum')
bo.columns=[tname.get(c,c) for c in bo.columns]
print(bo.iloc[::40].astype(int).to_string())

print("\n############ 建筑 filled_owner 随时间 ############")
bf=B.pivot_table(index='day_index',columns='type_id',values='filled_owner',aggfunc='sum')
bf.columns=[tname.get(c,c) for c in bf.columns]
print(bf.iloc[::40].astype(int).to_string())

print("\n############ 关键商品 价格 & 库存 时间线 ############")
for g in ['flint','chipped_stone_tools','game_meat','fur','cloth','gathered_plants','fish','game_meat']:
    sub=M[M.good_id==g].set_index('day_index')
    if len(sub)==0: continue
    print(f"\n-- {g} --")
    print("price:", sub['price'].iloc[::60].tolist())
    print("stock:", sub['stock'].iloc[::60].tolist())
    print("supply_ema:", sub['offered_supply_ema'].iloc[::60].astype(int).tolist())

print("\n############ 货币分布: 商人 vs 生产者 占比 ############")
C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22]),'elite','producer'))
gm=C.groupby(['day_index','grp']).funds.sum().unstack(fill_value=0)
gm['total']=gm.sum(axis=1)
for c in ['merchant','elite','producer']:
    if c in gm: gm[c+'_pct']=(gm[c]/gm['total']*100).round(1)
print(gm[[c for c in gm.columns if c.endswith('_pct')]].iloc[::40].to_string())

print("\n############ 人口分组 时间线 ############")
pm=C.groupby(['day_index','grp']).population.sum().unstack(fill_value=0)
print(pm.iloc[::40].astype(int).to_string())
