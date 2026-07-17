import pandas as pd, numpy as np, json
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_114418_v5_cell1031_q3_r17_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")

tname={30:'公共炉灶',65:'燧石采石场',69:'采集地',79:'织布棚',90:'打制石器工坊',
102:'海鱼采集点',106:'商站',203:'砂金开采',238:'狩猎营地',239:'集石点',242:'地表采银'}
pname={2:'工匠(artisan)',8:'奴工(enslaved)',9:'渔民(fisher)',12:'行会长(guild_master)',20:'经营者(manager)',22:'冶金者(metallurgist)'}
D=sorted(C.day_index.unique())

def downsample(days, step=5):
    return days[::step]
days = D
step = 3
sd = days[::step]

# 1. 人口分组
C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22]),'elite','producer'))
pm=C.groupby(['day_index','grp']).population.sum().unstack(fill_value=0).reindex(days).fillna(0)
fm=C.groupby(['day_index','grp']).funds.sum().unstack(fill_value=0).reindex(days).fillna(0)
fm_tot=fm.sum(axis=1).replace(0,np.nan)
fpct={g:(fm[g]/fm_tot*100).round(2).fillna(0).tolist() for g in ['producer','merchant','elite'] if g in fm}

# 2. 满意度
sat=C.groupby('day_index').apply(lambda x:(x.satisfaction_q16*x.population).sum()/max(x.population.sum(),1)/65535, include_groups=False).reindex(days).round(4)

# 3. 全局就业(summary)
Ss=S.set_index('day_index')
glob={
 'owner': Ss['filled_owner_jobs'].reindex(days).tolist(),
 'emp': Ss['filled_employee_jobs'].reindex(days).tolist(),
 'unemp': Ss['unemployed_population'].reindex(days).tolist(),
}

# 4. 建筑产出
bo=B.pivot_table(index='day_index',columns='type_id',values='last_output',aggfunc='sum').reindex(days).fillna(0)
bf=B.pivot_table(index='day_index',columns='type_id',values='filled_owner',aggfunc='sum').reindex(days).fillna(0)
build_out={tname.get(c,str(c)):bo[c].astype(int).tolist() for c in bo.columns}
build_own={tname.get(c,str(c)):bf[c].astype(int).tolist() for c in bf.columns}

# 5. 关键商品价格
goods=['flint','chipped_stone_tools','game_meat','fur','cloth','gathered_plants','fish','raw_hide']
price={}; stock={}
for g in goods:
    sub=M[M.good_id==g].set_index('day_index').reindex(days)
    price[g]=sub['price'].fillna(0).astype(int).tolist()
    stock[g]=sub['stock'].fillna(0).astype(int).tolist()

# 6. 资源枯竭
res=['wild_game','clay','fertile_soil','flint','marine_fish']
rp=R.pivot_table(index='day_index',columns='resource_id',values='reserve',aggfunc='sum').reindex(days).fillna(0)
resd={r:(rp[r]/max(rp[r].iloc[0],1)*100).round(1).tolist() for r in res if r in rp}

# 7. 宏观生产
macro={
 'output': (Ss['production_output_stock'].reindex(days)/1e6).round(1).tolist(),
 'support': (Ss['producer_support_money_issued'].reindex(days)/1e6).round(1).tolist(),
 'wages': (Ss['building_wages_paid'].reindex(days)/1e6).round(1).tolist(),
 'discarded': (Ss['production_output_discarded'].reindex(days)/1e6).round(3).tolist(),
}

# 建筑末期快照表
dN=days[-1]
be=B[B.day_index==dN].copy()
be['name']=be.type_id.map(tname)
snap=be[['name','count','owner_required','filled_owner','last_output','last_sold','last_revenue','realized_profit_margin_q16']].to_dict('records')

out={
 'days': days,
 'pop': {g:pm[g].astype(int).tolist() for g in ['producer','merchant','elite'] if g in pm},
 'fpct': fpct,
 'sat': sat.fillna(0).tolist(),
 'glob': glob,
 'build_out': build_out,
 'build_own': build_own,
 'price': price, 'stock': stock,
 'res': resd,
 'macro': macro,
 'snap': snap,
}
def conv(o):
    if isinstance(o,(np.integer,)): return int(o)
    if isinstance(o,(np.floating,)): return float(o)
    return str(o)
with open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\_econ_data.json","w",encoding="utf-8") as f:
    json.dump(out,f,ensure_ascii=False,default=conv)
print("exported. days:",len(days),"range",days[0],"-",days[-1])
print("pop groups:",list(pm.columns))
print("producer pop:",pm['producer'].iloc[0],"->",pm['producer'].iloc[-1])
print("merchant funds pct:",fpct['merchant'][0],"->",fpct['merchant'][-1])
