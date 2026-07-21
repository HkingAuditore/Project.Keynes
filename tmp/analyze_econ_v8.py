import pandas as pd, numpy as np, os
pd.set_option('display.width',200); pd.set_option('display.max_columns',60)
B="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260721_104404_v8_cell1104_q15_r18_"
Q=65536.0

PROF={2:'artisan工匠',8:'fisher渔民',9:'forager采集者',12:'hunter猎人',20:'merchant商人',22:'miner矿工',31:'unemployed失业'}
GOODS="advanced_chips agricultural_machinery aluminum automobiles autonomous_systems batteries bauxite beverages bread bricks bronze_tools canned_fish cement chipped_stone_tools clay cloth clothing coal coke computers concrete construction_components copper copper_ore corn_grain cotton_fiber crude_oil dairy_products detergent edible_oil electric_motor electrical_equipment electricity electronic_components engines explosives fertilizer fine_clothing fine_furniture fish flax_fiber flint footwear fur furniture game_meat gathered_plants glass gold grain horses household_appliances industrial_chemicals industrial_machinery insulated_cable iron_ore jewelry latex lead lead_ore leather lime limestone livestock_products logs lubricants lumber machine_parts manganese_ore manuscripts meat medicinal_herbs natural_gas nuclear_fuel oceanic_vessels packaging paper petrochemicals pharmaceuticals phosphate_rock plastics potatoes pottery precision_tools prepared_staples printed_materials processed_food radio_equipment railway_equipment rare_earth_metals rare_earth_ore raw_hide raw_stone reactor_components refined_fuel rice_grain salt saltpeter scientific_instruments semiconductors silica_sand silver soap spices stainless_steel steam_engines steel sulfur synthetic_fiber synthetic_rubber telecom_equipment tin tin_ore tools vegetables wheat_grain wire wool zinc zinc_ore".split()
GMAP={i:g for i,g in enumerate(GOODS)}
RES="arable_land bauxite clay coal copper_ore fertile_soil flint freshwater_fish gold_ore iron_ore lead_ore limestone manganese_ore marine_fish natural_gas oil paddy_land pasture phosphate_rock plantation_land rare_earth salt saltpeter silica_sand silver_ore stone sulfur timber tin_ore wild_game zinc_ore".split()
RMAP={i:r for i,r in enumerate(RES)}

def q(x): return x/Q

# ============ SUMMARY ============
s=pd.read_csv(B+"summary.csv")
s.columns=[c.lstrip('\ufeff') for c in s.columns]
print("### SUMMARY days:",s.day_index.min(),"-",s.day_index.max(),"rows",len(s))
cols=['day_index','cohort_count','building_group_count','pending_construction_count','filled_owner_jobs','filled_employee_jobs','unemployed_population','births','deaths','building_wages_paid','building_wages_unpaid','building_investments_started','building_investment_candidates','building_investment_blocked_funds','building_investment_blocked_materials','building_investment_blocked_sponsor_capital','population_error','money_error','goods_error','producer_revenue','loss_suspended_building_groups']
avail=[c for c in cols if c in s.columns]
print(s[avail].iloc[[0,1,len(s)//4,len(s)//2,3*len(s)//4,-1]].to_string(index=False))
print("\n-- errors max:",s.population_error.abs().max(),s.money_error.abs().max(),s.goods_error.abs().max())
print("-- total births/deaths:",s.births.sum(),s.deaths.sum())
print("-- investments_started total:",s.building_investments_started.sum(),"| blocked funds/mat/cap:",s.building_investment_blocked_funds.sum(),s.building_investment_blocked_materials.sum(),s.building_investment_blocked_sponsor_capital.sum())
for c in ['building_wages_paid','building_wages_unpaid','building_resource_generated','building_resource_consumed']:
    if c in s.columns: print(f"-- {c}: last={s[c].iloc[-1]} mean={s[c].mean():.0f}")
