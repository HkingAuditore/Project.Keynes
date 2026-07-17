import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 60); pd.set_option('display.max_rows', 300)
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
m = pd.read_csv(base+"market.csv")
MONEY=10000.0; GOODS=1000.0
days=sorted(m.day_index.unique()); first_d,last_d=days[0],days[-1]
print("market goods per epoch:", m[m.day_index==first_d].good_id.nunique())

# which goods are actually active (nonzero demand or stock or price change)?
act = m.groupby('good_id').agg(dem=('demand_ema','max'), bdem=('business_demand_ema','max'),
      sup=('offered_supply_ema','max'), stock=('stock','max'), price_min=('price','min'),
      price_max=('price','max'), short=('shortage_q16','max')).reset_index()
active = act[(act.dem>0)|(act.bdem>0)|(act.sup>0)|(act.stock>0)]
print("\n=== ACTIVE GOODS (demand/supply/stock >0) count:", len(active),"===")
print(active.sort_values('dem',ascending=False).head(30).to_string())

# for top food goods trace price/stock/shortage over time
print("\n=== PRICE trajectory for active goods (first vs last day) ===")
def good_trace(gid):
    g=m[m.good_id==gid].sort_values('day_index')
    return g
rows=[]
for gid in active.good_id:
    g=good_trace(gid)
    rows.append({'good':gid,'cat':g.category_id.iloc[0],'p_first':g.price.iloc[0]/MONEY,'p_last':g.price.iloc[-1]/MONEY,
        'p_ratio':g.price.iloc[-1]/max(1,g.price.iloc[0]),
        'stock_last':g.stock.iloc[-1]/GOODS,'dem_last':g.demand_ema.iloc[-1]/GOODS,
        'bdem_last':g.business_demand_ema.iloc[-1]/GOODS,'sup_last':g.offered_supply_ema.iloc[-1]/GOODS,
        'short_last':g.shortage_q16.iloc[-1]/65536,'anchor_last':g.cost_anchor_price.iloc[-1]/MONEY})
pt=pd.DataFrame(rows).sort_values('dem_last',ascending=False)
print(pt.to_string())

# key food goods deep trace
print("\n=== DEEP TRACE: highest-demand goods over time ===")
for gid in pt.good.head(6):
    g=good_trace(gid)
    print("\n--- %s (cat=%s) ---"%(gid,g.category_id.iloc[0]))
    sub=g[['day_index','price','stock','demand_ema','business_demand_ema','offered_supply_ema','shortage_q16','cost_anchor_price']].copy()
    sub['price']/=MONEY; sub['cost_anchor_price']/=MONEY
    for col in ['stock','demand_ema','business_demand_ema','offered_supply_ema']: sub[col]/=GOODS
    sub['shortage_q16']/=65536
    print(sub.iloc[::60].to_string(index=False))
    print("last:",{k:(round(v,2) if isinstance(v,float) else v) for k,v in sub.iloc[-1].to_dict().items()})
