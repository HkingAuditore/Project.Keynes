import pandas as pd, numpy as np
pd.set_option('display.width',260); pd.set_option('display.max_columns',90)
B="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260721_104404_v8_cell1104_q15_r18_"
Q=65536.0
s=pd.read_csv(B+"summary.csv"); s.columns=[c.lstrip('\ufeff') for c in s.columns]
mon=['day_index','bullion_money_issued','gold_accepted','silver_accepted','gold_money_issued','silver_money_issued','producer_support_money_issued','building_owner_mobility','building_investments_started','building_investment_candidates','loss_suspended_building_groups','merchant_procurement_budget','merchant_procurement_spent','trade_orders_dispatched','trade_orders_arrived','trade_candidates_accepted']
av=[c for c in mon if c in s.columns]
print("=== MONEY ISSUANCE / MOBILITY / TRADE (summary, sampled) ===")
idx=[0,len(s)//4,len(s)//2,3*len(s)//4,-1]
print(s[av].iloc[idx].to_string(index=False))
print("\n-- cumulative gold_money_issued:",s.gold_money_issued.sum(),"silver:",s.silver_money_issued.sum(),"bullion:",s.bullion_money_issued.sum())
print("-- cumulative producer_support_money_issued:",s.producer_support_money_issued.sum())
print("-- cumulative owner_mobility:",s.building_owner_mobility.sum(),"| investments_started:",s.building_investments_started.sum())
print("-- trade dispatched/arrived cumulative:",s.trade_orders_dispatched.sum(),s.trade_orders_arrived.sum(),"| candidates_accepted:",s.trade_candidates_accepted.sum())

# total money in cell over time (sum cohort funds)
c=pd.read_csv(B+"cohorts.csv"); c.columns=[x.lstrip('\ufeff') for x in c.columns]
tot=c.groupby('day_index').funds.sum()
print("\n=== TOTAL cohort funds in cell over time ===")
for day in [tot.index[0],tot.index[len(tot)//4],tot.index[len(tot)//2],tot.index[3*len(tot)//4],tot.index[-1]]:
    print(f"day {day}: {tot[day]:,}")
print("growth factor:",round(tot.iloc[-1]/tot.iloc[0],2))

# communal_hearth (type 30) trajectory
b=pd.read_csv(B+"buildings.csv"); b.columns=[x.lstrip('\ufeff') for x in b.columns]
ch=b[(b.type_id==30)&(b.is_construction==0)]
print("\n=== communal_hearth (forager-owned food processor) trajectory ===")
cols=['day_index','last_input','last_output','last_sold','last_revenue','last_input_cost','last_wages_paid','realized_profit_margin_q16']
sub=ch[cols].copy(); sub['margin']=sub.realized_profit_margin_q16/Q; sub['profit']=sub.last_revenue-sub.last_input_cost-sub.last_wages_paid
idx2=[ch.index[0],ch.index[len(ch)//4],ch.index[len(ch)//2],ch.index[-1]]
print(sub.loc[idx2][['day_index','last_input','last_output','last_sold','last_revenue','last_input_cost','profit','margin']].to_string(index=False))
print("communal_hearth cumulative profit:",int((ch.last_revenue-ch.last_input_cost-ch.last_wages_paid).sum()))

# gold/silver mines (204,243) wages over life
for t,nm in [(204,'placer_gold'),(243,'surface_silver')]:
    mm=b[(b.type_id==t)&(b.is_construction==0)]
    print(f"\n{nm}: cum revenue={int(mm.last_revenue.sum())} cum wages_paid={int(mm.last_wages_paid.sum())} cum resource_extracted={int(mm.last_resource.sum())}")
