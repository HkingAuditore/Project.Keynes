import pandas as pd, numpy as np
pd.set_option('display.width',260); pd.set_option('display.max_columns',90)
B="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260721_104404_v8_cell1104_q15_r18_"
Q=65536.0
RES="arable_land bauxite clay coal copper_ore fertile_soil flint freshwater_fish gold_ore iron_ore lead_ore limestone manganese_ore marine_fish natural_gas oil paddy_land pasture phosphate_rock plantation_land rare_earth salt saltpeter silica_sand silver_ore stone sulfur timber tin_ore wild_game zinc_ore".split()
RMAP={i:r for i,r in enumerate(RES)}
r=pd.read_csv(B+"resources.csv"); r.columns=[x.lstrip('\ufeff') for x in r.columns]
r['res']=r.resource_id.map(RMAP).fillna(r.resource_id.astype(str))
days=sorted(r.day_index.unique()); last=days[-1]; first=days[0]
active=r.groupby('res').reserve.max()
active=active[active>0].index.tolist()
print("=== RESOURCES present (reserve>0 ever):",active)
print("\n=== at LAST day",last,"===")
d=r[r.day_index==last]
cols=['res','opening_reserve','natural_net_change','natural_positive_change','natural_negative_change','artificial_generation_applied','artificial_extraction_applied','reserve','safe_yield','projected_life_days']
print(d[d.res.isin(active)][cols].to_string(index=False))

print("\n=== reserve trajectory (extractable resources) ===")
sample=[first,days[len(days)//4],days[len(days)//2],days[3*len(days)//4],last]
for res in active:
    row={'res':res}
    rr=r[r.res==res]
    for day in sample:
        dd=rr[rr.day_index==day]
        row[day]=int(dd.reserve.iloc[0]) if len(dd) else None
    print(row)

print("\n=== cumulative flows per resource ===")
g=r.groupby('res').agg(nat_pos=('natural_positive_change','sum'),nat_neg=('natural_negative_change','sum'),
  art_gen=('artificial_generation_applied','sum'),art_ext=('artificial_extraction_applied','sum'))
print(g[g.index.isin(active)].to_string())
