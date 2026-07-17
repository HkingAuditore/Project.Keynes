import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 90); pd.set_option('display.max_rows', 200)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_140702_v7_cell1060_q32_r17_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")
days=sorted(C.day_index.unique()); dN=days[-1]

print("############ A. 建筑末期快照 (type_id -> 状态) ############")
be=B[B.day_index==dN]
cols=['type_id','count','owner_required','filled_owner','employee_required','employee_filled','operating_state','last_output','last_sold','last_revenue','realized_profit_margin_q16','wage_suspended']
print(be[cols].to_string(index=False))
print("\n建筑数:",be.type_id.nunique(),"  operating_state分布(全期):",dict(B.operating_state.value_counts()))

print("\n############ B. 关键商品价格&库存&供给 (末期短缺TOP) ############")
me=M[M.day_index==dN].sort_values('shortage_q16',ascending=False)
print(me[['good_id','stock','price','demand_ema','offered_supply_ema','shortage_q16','trade_enabled','trade_import_ema','trade_export_ema']].head(15).to_string(index=False))

print("\n############ C. 价格变化 首->末 ############")
mp=M.pivot_table(index='day_index',columns='good_id',values='price',aggfunc='mean')
chg=((mp.iloc[-1]-mp.iloc[0])/mp.iloc[0].replace(0,np.nan)).dropna().sort_values()
print("跌幅TOP:");print(chg.head(8).round(2).to_string())
print("涨幅TOP:");print(chg.tail(8).round(2).to_string())

print("\n############ D. 贸易字段全景 (为何0成交) ############")
tcols=['day_index','trade_scan_total','trade_completed_scans','trade_ready_candidates','trade_candidates_generated','trade_candidates_accepted','trade_rejected_profit','trade_rejected_capacity','trade_rejected_stock','trade_rejected_cash','trade_rejected_route','trade_capacity_available']
print(S[tcols].iloc[::60].to_string(index=False))
print("\n各rejected累计:")
for c in ['trade_candidates_generated','trade_candidates_accepted','trade_rejected_profit','trade_rejected_capacity','trade_rejected_stock','trade_rejected_cash','trade_rejected_route','trade_rejected_order_cap']:
    print(f"  {c}: {S[c].sum()}")

print("\n############ E. 出生相关: 满意度足够高为何births=0 ############")
print("末期满意度分布:", C[C.day_index==dN].satisfaction_q16.tolist())
print("deaths 与 满意度: 后期satisfaction=0.90 但 deaths 仍持续:")
print(S[['day_index','births','deaths']].iloc[::40].to_string(index=False))

print("\n############ F. 货币发行(贵金属) ############")
mcols=['day_index','bullion_money_issued','gold_money_issued','silver_money_issued','producer_revenue','producer_support_money_issued','building_wages_paid']
print(S[mcols].iloc[::60].to_string(index=False))
