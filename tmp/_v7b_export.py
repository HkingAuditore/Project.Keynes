import pandas as pd, numpy as np, json
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_152531_v7_cell1166_q17_r19_"
S=pd.read_csv(base+"summary.csv"); B=pd.read_csv(base+"buildings.csv")
C=pd.read_csv(base+"cohorts.csv"); M=pd.read_csv(base+"market.csv"); R=pd.read_csv(base+"resources.csv")
S.columns=[c.lstrip('\ufeff') for c in S.columns]
days=sorted(C.day_index.unique())
def conv(o):
    if isinstance(o,(np.integer,)): return int(o)
    if isinstance(o,(np.floating,)): return float(o)
    raise TypeError
D={}
D['meta']={'cell':int(C.cell_idx.iloc[0]),'day_min':int(S.day_index.min()),'day_max':int(S.day_index.max()),
           'rows':len(S),'err_pop':int(S.population_error.abs().max()),'err_money':int(S.money_error.abs().max()),
           'err_goods':int(S.goods_error.abs().max())}
D['days']=[int(d) for d in S.day_index.tolist()]
# 出生死亡
D['births']=[int(x) for x in S.births.tolist()]
D['deaths']=[int(x) for x in S.deaths.tolist()]
D['cohort_count']=[int(x) for x in S.cohort_count.tolist()]
# 就业
D['filled_owner']=[int(x) for x in S.filled_owner_jobs.tolist()]
D['filled_emp']=[int(x) for x in S.filled_employee_jobs.tolist()]
D['unemp']=[int(x) for x in S.unemployed_population.tolist()]
D['loss_suspended']=[int(x) for x in S.loss_suspended_building_groups.tolist()]
# 贸易链
D['trade']={
 'scan_total_last':int(S.trade_scan_total.iloc[-1]),'scan_total_sum':int(S.trade_scan_total.sum()),
 'completed_scans':int(S.trade_completed_scans.sum()),'candidates_generated':int(S.trade_candidates_generated.sum()),
 'candidates_accepted':int(S.trade_candidates_accepted.sum()),'orders_dispatched':int(S.trade_orders_dispatched.sum()),
 'orders_arrived':int(S.trade_orders_arrived.sum()),'source_signals':int(S.trade_source_signals.iloc[-1]),
 'dest_signals':int(S.trade_destination_signals.iloc[-1]),'topology_ready':bool(S.trade_topology_ready.iloc[-1]),
 'mode':str(S.trade_runtime_mode.iloc[-1]),
 'rej_profit':int(S.trade_rejected_profit.sum()),'rej_capacity':int(S.trade_rejected_capacity.sum()),
 'rej_stock':int(S.trade_rejected_stock.sum()),'rej_cash':int(S.trade_rejected_cash.sum()),
 'rej_route':int(S.trade_rejected_route.sum()),'rej_order_cap':int(S.trade_rejected_order_cap.sum()),
 'trade_enabled_goods':int((M.groupby(M.good_id.astype(str)).trade_enabled.max()==1).sum()),
 'goods_with_flow':int(0),  # 计算见下
}
M['g']=M.good_id.astype(str)
tsum=M.groupby('g').agg(imp=('trade_import_ema','sum'),exp=('trade_export_ema','sum'),inb=('trade_inbound','sum'),outb=('trade_outbound','sum'))
D['trade']['goods_with_flow']=int(((tsum.imp!=0)|(tsum.exp!=0)|(tsum.inb!=0)|(tsum.outb!=0)).sum())
# 人口财富分组
C['grp']=np.where(C.is_merchant==1,'merchant',np.where(C.profession_id.isin([20,22,11,18]),'elite','producer'))
pm=C.groupby(['day_index','grp']).population.sum().unstack(fill_value=0).reindex(days).fillna(0)
fm=C.groupby(['day_index','grp']).funds.sum().unstack(fill_value=0).reindex(days).fillna(0)
tot=fm.sum(axis=1).replace(0,np.nan)
for grp in ['producer','merchant','elite']:
    D['pop_'+grp]=[int(x) for x in (pm[grp] if grp in pm else pd.Series(0,index=days)).tolist()]
    ser=(fm[grp]/tot*100).round(2) if grp in fm else pd.Series(0,index=days)
    D['fw_'+grp]=[None if pd.isna(x) else float(x) for x in ser.tolist()]
D['pop_total']=[int(x) for x in pm.sum(axis=1).tolist()]
# 满意度
C['sat']=C.satisfaction_q16/65536.0
wsat=C.groupby('day_index').apply(lambda d:(d.sat*d.population).sum()/max(d.population.sum(),1))
D['sat']=[round(float(x),3) for x in wsat.reindex(days).ffill().tolist()]
# 建筑 owner by type (关键 type)
key_types=[30,65,69,79,90,102,106,203,238,239]
bt=B.groupby(['day_index','type_id']).filled_owner.sum().reset_index()
piv=bt.pivot(index='day_index',columns='type_id',values='filled_owner').reindex(days).fillna(0)
tname={30:'公共炉灶',65:'燧石采石场',69:'采集地',79:'织布棚',90:'打制石器工坊',102:'海鱼采集点',106:'商站',203:'砂金开采',238:'狩猎营地',239:'集石点'}
D['bld']={}
for t in key_types:
    if t in piv.columns:
        D['bld'][tname.get(t,str(t))]=[int(x) for x in piv[t].tolist()]
# 关键 good 价格&短缺
key_goods=['chipped_stone_tools','game_meat','fur','logs','processed_food','cloth','gathered_plants','raw_stone','flint']
D['price']={}; D['shortage']={}
for g in key_goods:
    sub=M[M.g==g].sort_values('day_index')
    if len(sub):
        sub=sub.groupby('day_index').agg(price=('price','mean'),sh=('shortage_q16','mean')).reindex(days).ffill()
        D['price'][g]=[None if pd.isna(x) else float(x) for x in sub.price.tolist()]
        D['shortage'][g]=[None if pd.isna(x) else round(float(x)/65536.0,3) for x in sub.sh.tolist()]
open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\_v7b_data.json","w",encoding="utf-8").write(json.dumps(D,default=conv,ensure_ascii=False))
print("exported keys:",list(D.keys()))
print("trade:",D['trade'])
print("births sum:",sum(D['births']),"deaths sum:",sum(D['deaths']))
print("pop_total 首末:",D['pop_total'][0],D['pop_total'][-1])
