import pandas as pd, numpy as np
pd.set_option('display.width', 260); pd.set_option('display.max_columns', 90); pd.set_option('display.max_rows', 300)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_152531_v7_cell1166_q17_r19_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")
S.columns=[c.lstrip('\ufeff') for c in S.columns]
days=sorted(C.day_index.unique())
print("cell:",C.cell_idx.unique()[:3]," epochs:",S.epoch_id.nunique(),"day:",S.day_index.min(),"-",S.day_index.max(),"rows:",len(S))
print("守恒误差 pop/money/goods:", S.population_error.abs().max(), S.money_error.abs().max(), S.goods_error.abs().max())

print("\n############ P0-A 出生机制 ############")
print("births 总和:",S.births.sum()," deaths 总和:",S.deaths.sum()," births非零周期:",(S.births>0).sum(),"/",len(S))
print(S[['day_index','births','deaths','cohort_count']].iloc[::60].to_string(index=False))

print("\n############ P0-B 贸易系统链路 ############")
tcols=['day_index','trade_runtime_mode','trade_topology_ready','trade_scan_total','trade_completed_scans',
       'trade_source_signals','trade_destination_signals','trade_ready_candidates','trade_candidates_generated',
       'trade_candidates_accepted','trade_rejected_profit','trade_rejected_capacity','trade_rejected_stock',
       'trade_rejected_cash','trade_rejected_route','trade_rejected_order_cap',
       'trade_orders_dispatched','trade_orders_arrived','trade_orders_in_flight','trade_capacity_used']
print("末期快照:")
last=S.iloc[-1]
for c in tcols[1:]:
    print(f"  {c:32s} = {last[c]}")
print("\n累计(sum) 关键量:")
for c in ['trade_scan_total','trade_completed_scans','trade_candidates_generated','trade_candidates_accepted',
          'trade_orders_dispatched','trade_orders_arrived','trade_rejected_profit','trade_rejected_capacity',
          'trade_rejected_stock','trade_rejected_cash','trade_rejected_route','trade_rejected_order_cap']:
    print(f"  {c:32s} = {S[c].sum()}")

print("\n############ 全局就业/建筑 ############")
g=S[['day_index','filled_owner_jobs','filled_employee_jobs','unemployed_population','cohort_count','building_group_count','loss_suspended_building_groups','pending_construction_count']].copy()
print("首:",g.iloc[0].to_dict()); print("末:",g.iloc[-1].to_dict())
print(g.iloc[::80].to_string(index=False))
