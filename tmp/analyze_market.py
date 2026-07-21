import pandas as pd, numpy as np
pd.set_option('display.width',260); pd.set_option('display.max_columns',80)
B="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260721_104404_v8_cell1104_q15_r18_"
Q=65536.0
GOODS="advanced_chips agricultural_machinery aluminum automobiles autonomous_systems batteries bauxite beverages bread bricks bronze_tools canned_fish cement chipped_stone_tools clay cloth clothing coal coke computers concrete construction_components copper copper_ore corn_grain cotton_fiber crude_oil dairy_products detergent edible_oil electric_motor electrical_equipment electricity electronic_components engines explosives fertilizer fine_clothing fine_furniture fish flax_fiber flint footwear fur furniture game_meat gathered_plants glass gold grain horses household_appliances industrial_chemicals industrial_machinery insulated_cable iron_ore jewelry latex lead lead_ore leather lime limestone livestock_products logs lubricants lumber machine_parts manganese_ore manuscripts meat medicinal_herbs natural_gas nuclear_fuel oceanic_vessels packaging paper petrochemicals pharmaceuticals phosphate_rock plastics potatoes pottery precision_tools prepared_staples printed_materials processed_food radio_equipment railway_equipment rare_earth_metals rare_earth_ore raw_hide raw_stone reactor_components refined_fuel rice_grain salt saltpeter scientific_instruments semiconductors silica_sand silver soap spices stainless_steel steam_engines steel sulfur synthetic_fiber synthetic_rubber telecom_equipment tin tin_ore tools vegetables wheat_grain wire wool zinc zinc_ore".split()
GMAP={i:g for i,g in enumerate(GOODS)}
m=pd.read_csv(B+"market.csv"); m.columns=[x.lstrip('\ufeff') for x in m.columns]
m['good']=m.good_id.map(GMAP).fillna(m.good_id.astype(str))
m['price']=m.price/Q
m['shortage']=m.shortage_q16/Q
days=sorted(m.day_index.unique()); last=days[-1]
# goods that actually trade in this cell (nonzero stock or demand at some point)
active=m.groupby('good').agg(maxstock=('stock','max'),maxdem=('demand_ema','max'),maxprice=('price','max')).query('maxstock>0 or maxdem>0')
key=['gold','silver','game_meat','gathered_plants','fish','flint','chipped_stone_tools','raw_stone','fur','raw_hide','logs','medicinal_herbs','meat','spices','pottery','salt','wild_game']
print("=== KEY GOODS at LAST day",last,"===")
d=m[(m.day_index==last)]
show=d[d.good.isin(active.index)][['good','stock','price','demand_ema','business_demand_ema','offered_supply_ema','realized_withdrawal_ema','shortage','trade_enabled','trade_inbound','trade_outbound','cost_anchor_price']].copy()
show['cost_anchor']=show.cost_anchor_price/Q
print(show.sort_values('price',ascending=False).to_string(index=False))

print("\n=== PRICE trajectory for key goods (sampled) ===")
sample=[days[0],days[len(days)//4],days[len(days)//2],days[3*len(days)//4],last]
rows=[]
for g in ['gold','silver','game_meat','meat','gathered_plants','fish','flint','chipped_stone_tools','fur','pottery']:
    r={'good':g}
    for day in sample:
        dd=m[(m.day_index==day)&(m.good==g)]
        r[day]=round(dd.price.iloc[0],2) if len(dd) else None
    rows.append(r)
print(pd.DataFrame(rows).set_index('good').to_string())

print("\n=== STOCK trajectory (glut detection) ===")
rows=[]
for g in ['gold','silver','game_meat','gathered_plants','fish','flint','chipped_stone_tools','fur']:
    r={'good':g}
    for day in sample:
        dd=m[(m.day_index==day)&(m.good==g)]
        r[day]=int(dd.stock.iloc[0]) if len(dd) else None
    rows.append(r)
print(pd.DataFrame(rows).set_index('good').to_string())
