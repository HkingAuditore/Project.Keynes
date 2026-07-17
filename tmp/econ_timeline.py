import pandas as pd, numpy as np
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
MONEY=10000.0; GOODS=1000.0; Q16=65536.0
c=pd.read_csv(base+"cohorts.csv"); m=pd.read_csv(base+"market.csv"); r=pd.read_csv(base+"resources.csv"); b=pd.read_csv(base+"buildings.csv")
cd=sorted(c.day_index.unique())
def pop(pid,d):
    g=c[(c.day_index==d)&(c.profession_id==pid)]; return int(g.population.sum())
def price(g,d):
    x=m[(m.good_id==g)&(m.day_index==d)]; return round(x.price.iloc[0]/MONEY,3) if len(x) else None
def sup(g,d):
    x=m[(m.good_id==g)&(m.day_index==d)]; return round(x.offered_supply_ema.iloc[0]/GOODS,2) if len(x) else None
def sat(pid,d):
    g=c[(c.day_index==d)&(c.profession_id==pid)]
    return round((g.satisfaction_q16*g.population).sum()/max(1,g.population.sum())/Q16,2) if len(g) and g.population.sum()>0 else None
def res(rid,d):
    x=r[(r.resource_id==rid)&(r.day_index==d)]; return round(x.reserve.iloc[0],0) if len(x) else None
def bout(tid,d):
    x=b[(b.type_id==tid)&(b.day_index==d)]; return round(x.last_output.sum()/GOODS,1) if len(x) else None
def bown(tid,d):
    x=b[(b.type_id==tid)&(b.day_index==d)]; return int(x.filled_owner.sum()) if len(x) else None

print("day | hunter_pop artisan_pop forager_pop fisher_pop | tools_sup meat_sup food_sup gplant_price | wild_game | hunt_out hunt_owner knap_out")
for d in cd[::15]:
    print("%4d | H=%2d A=%2d Fo=%2d Fi=%2d | tool_sup=%5.2f meat_sup=%5.2f pfood_sup=%4.2f gplant_p=%.3f | wgame=%6.0f | huntout=%6.1f huntown=%2d knapout=%6.1f"%(
        d, pop(12,d),pop(2,d),pop(9,d),pop(8,d),
        sup('chipped_stone_tools',d) or -1, sup('game_meat',d) or -1, sup('processed_food',d) or -1, price('gathered_plants',d) or -1,
        res('wild_game',d) or -1, bout(238,d) or -1, bown(238,d) or -1, bout(90,d) or -1))
print("\nartisan sat / hunter sat / forager sat over time:")
for d in cd[::20]:
    print("day %4d artisan_sat=%s hunter_sat=%s forager_sat=%s fisher_sat=%s"%(d,sat(2,d),sat(12,d),sat(9,d),sat(8,d)))
