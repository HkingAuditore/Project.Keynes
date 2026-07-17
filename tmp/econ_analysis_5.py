import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 60); pd.set_option('display.max_rows', 200)
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
r = pd.read_csv(base+"resources.csv")
MONEY=10000.0; GOODS=1000.0
days=sorted(r.day_index.unique()); first_d,last_d=days[0],days[-1]

print("=== RESOURCE reserves (cell 1031) first vs last ===")
piv = r.pivot_table(index='resource_id', columns='day_index', values='reserve')
tbl = pd.DataFrame({'first':piv[first_d],'last':piv[last_d]})
tbl['ratio']=tbl['last']/tbl['first'].replace(0,np.nan)
tbl['depleted_%']=(1-tbl['ratio'])*100
# only resources that changed meaningfully
chg = tbl[(tbl['first']>0)].sort_values('depleted_%',ascending=False)
print(chg.to_string())

print("\n=== depleting resources trace (top 6 by depletion) ===")
for rid in chg.head(6).index:
    g=r[r.resource_id==rid].sort_values('day_index')
    vals=g.reserve.values
    print("%-16s first=%.1f min=%.1f last=%.1f  (day of min=%d)"%(rid, vals[0], vals.min(), vals[-1], g.day_index.values[vals.argmin()]))

# key: wild_game (hunting), flint, marine_fish
print("\n=== KEYSTONE resource trajectories ===")
for rid in ['wild_game','flint','marine_fish','gold_ore','fertile_soil','stone']:
    if rid in piv.index:
        g=r[r.resource_id==rid].sort_values('day_index')
        s=g.reserve.values
        idx=np.linspace(0,len(s)-1,7).astype(int)
        print("%-14s:"%rid, " ".join("%.0f"%s[i] for i in idx))
