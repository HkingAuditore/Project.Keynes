import pandas as pd, numpy as np, json
pd.set_option('display.width', 260); pd.set_option('display.max_columns', 90); pd.set_option('display.max_rows', 300)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_152531_v7_cell1166_q17_r19_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")
S.columns=[c.lstrip('\ufeff') for c in S.columns]
days=sorted(C.day_index.unique())

print("############ cell1166 人口/财富分组 ############")
C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22,11,18]),'elite','producer'))
pm=C.groupby(['day_index','grp']).population.sum().unstack(fill_value=0).reindex(days).fillna(0)
fm=C.groupby(['day_index','grp']).funds.sum().unstack(fill_value=0).reindex(days).fillna(0)
tot=fm.sum(axis=1).replace(0,np.nan)
print("人口(每80):"); print(pm.iloc[::80].astype(int).to_string())
print("\n财富占比%(每80):")
fp=pd.DataFrame({c:(fm[c]/tot*100).round(1) for c in fm.columns})
print(fp.iloc[::80].to_string())
print("\ncell1166 总人口 首->末:", int(pm.sum(axis=1).iloc[0]),"->",int(pm.sum(axis=1).iloc[-1]))

print("\n############ cell1166 满意度 (worst-need satisfaction) ############")
C['sat']=C.satisfaction_q16/65536.0
wsat=C.groupby('day_index').apply(lambda d:(d.sat*d.population).sum()/max(d.population.sum(),1))
print("满意度加权 首:",round(wsat.iloc[0],3)," 末:",round(wsat.iloc[-1],3)," 最低:",round(wsat.min(),3))
print(wsat.iloc[::80].round(3).to_string())

print("\n############ cell1166 建筑 owner 轨迹(按type聚合) ############")
bt=B.groupby(['day_index','type_id']).agg(fo=('filled_owner','sum'),cnt=('count','sum'),
    out=('last_output','sum'),inp=('last_input','sum'),margin=('realized_profit_margin_q16','mean')).reset_index()
types=B.type_id.unique()
pivot=bt.pivot(index='day_index',columns='type_id',values='fo').fillna(0)
print("各type filled_owner(每120):")
print(pivot.iloc[::120].astype(int).to_string())
# 哪些 type 归零
last_fo=pivot.iloc[-1]; first_fo=pivot.iloc[0]
dead=[t for t in pivot.columns if first_fo[t]>0 and last_fo[t]==0]
print("\n从有到无(owner归零)的 type_id:",dead)

print("\n############ cell1166 市场:短缺/价格异常 good ############")
M['g']=M.good_id.astype(str)
last_day=days[-1]
ml=M[M.day_index==last_day]
ml=ml.assign(sh=ml.shortage_q16/65536.0)
top=ml.sort_values('sh',ascending=False).head(12)
print("末期短缺TOP(good_id, stock, price, demand_ema, offered_supply_ema, shortage):")
print(top[['g','stock','price','demand_ema','offered_supply_ema','shortage_q16','trade_inbound','trade_outbound']].to_string(index=False))

print("\n############ 贸易 per-good 是否真的有流动 ############")
tsum=M.groupby('g').agg(imp=('trade_import_ema','sum'),exp=('trade_export_ema','sum'),
    inb=('trade_inbound','sum'),outb=('trade_outbound','sum'),ten=('trade_enabled','max')).reset_index()
tsum=tsum[(tsum.imp!=0)|(tsum.exp!=0)|(tsum.inb!=0)|(tsum.outb!=0)]
print("有任何贸易流动的 good 数:",len(tsum))
print(tsum.head(20).to_string(index=False))
print("trade_enabled=1 的 good 数:", (M.groupby('g').trade_enabled.max()==1).sum())
