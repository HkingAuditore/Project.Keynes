import pandas as pd, numpy as np
pd.set_option('display.width', 200); pd.set_option('display.max_columns', 60)
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
s = pd.read_csv(base+"summary.csv")
print("=== SUMMARY shape:", s.shape)
print("epochs range day_index:", s.day_index.min(), "->", s.day_index.max(), " rows:", len(s))
print("unique epoch_id:", s.epoch_id.nunique(), " stages:", s.stage.unique()[:10])

MONEY=10000.0; GOODS=1000.0; Q16=65536.0
# key columns over time
cols = ['day_index','cohort_count','filled_owner_jobs','filled_employee_jobs','unemployed_population',
        'building_group_count','pending_construction_count','loss_suspended_building_groups',
        'production_output_stock','production_output_discarded','production_output_retained','production_output_supported',
        'producer_support_money_issued','building_wages_paid','building_wages_unpaid',
        'building_resource_generated','building_resource_consumed','building_resource_net_delta',
        'merchant_procurement_budget','merchant_procurement_spent','merchant_procurement_reserved',
        'production_input_reserved','production_input_reserve_shortfall',
        'population_error','money_error','goods_error']
d = s[cols].copy()
print("\n=== FIRST 5 epochs ===")
print(d.head(5).to_string())
print("\n=== LAST 5 epochs ===")
print(d.tail(5).to_string())

# employment ratio
tot_emp = s.filled_owner_jobs + s.filled_employee_jobs
labor = tot_emp + s.unemployed_population
print("\n=== EMPLOYMENT ===")
print("first: employed=%d unemployed=%d rate_unemp=%.1f%%"%(tot_emp.iloc[0], s.unemployed_population.iloc[0], 100*s.unemployed_population.iloc[0]/labor.iloc[0]))
print("last : employed=%d unemployed=%d rate_unemp=%.1f%%"%(tot_emp.iloc[-1], s.unemployed_population.iloc[-1], 100*s.unemployed_population.iloc[-1]/labor.iloc[-1]))
print("owner_jobs const?", s.filled_owner_jobs.describe()[['min','max','mean']].to_dict())
print("employee_jobs:", s.filled_employee_jobs.describe()[['min','max','mean']].to_dict())
print("unemployed:", s.unemployed_population.describe()[['min','max','mean']].to_dict())

# audit errors
print("\n=== AUDIT ERRORS (should be ~0) ===")
print("pop_err abs max:", s.population_error.abs().max(), " money_err abs max:", s.money_error.abs().max(), " goods_err abs max:", s.goods_error.abs().max())

# production economics
print("\n=== PRODUCTION FLOW (money units /MONEY) ===")
for c in ['production_output_stock','production_output_supported','producer_support_money_issued','building_wages_paid','building_wages_unpaid','merchant_procurement_budget','merchant_procurement_spent']:
    print("%-32s mean=%12.0f  last=%12.0f"%(c, s[c].mean()/MONEY, s[c].iloc[-1]/MONEY))

print("\n=== support ratio: producer_support vs total output value ===")
# supported stock * ... ; approximate: production_output_supported is qty*? Actually supported is qty units
print("output_stock(qty) mean=%.0f supported(qty) mean=%.0f discarded mean=%.0f retained mean=%.0f"%(
    s.production_output_stock.mean(), s.production_output_supported.mean(), s.production_output_discarded.mean(), s.production_output_retained.mean()))
print("support_money/wages_paid ratio last:", s.producer_support_money_issued.iloc[-1]/max(1,s.building_wages_paid.iloc[-1]))

print("\n=== resource net delta ===")
print("gen mean=%.0f consumed mean=%.0f net mean=%.0f (net<0 => depleting)"%(
    s.building_resource_generated.mean(), s.building_resource_consumed.mean(), s.building_resource_net_delta.mean()))
