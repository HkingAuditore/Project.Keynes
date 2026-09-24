import csv,json,collections
from pathlib import Path
p=Path('tmp/economy_record_20260921_094552_v25')
def read(d):
 with open(str(p)+'_'+d+'.csv',encoding='utf-8-sig',newline='') as f:yield from csv.DictReader(f)
def n(r,k):return int(r[k])
s=list(read('summary'));m=collections.defaultdict(dict);cs=collections.defaultdict(lambda:collections.defaultdict(int)); goods=collections.defaultdict(dict)
for r in read('market'):
 d,c=n(r,'day_index'),n(r,'cell_idx');m[c].setdefault(d,r)
 if d in [1,30,100,200,500,1000]:goods[c,d][r['good_id']]={k:n(r,k) for k in ['stock','price','demand_ema','business_demand_ema','construction_material_reserve','merchant_inventory_target']}
for r in read('cohorts'):
 d,c=n(r,'day_index'),n(r,'cell_idx');z=cs[c,d];merchant=r['is_merchant'].lower() in ['true','1'];key='merchant_' if merchant else 'other_'
 for k in ['population','funds','epoch_income','epoch_expense']:z[key+k]+=n(r,k)
 z['population']+=n(r,'population')
result={ 'prefix':str(p),'days':len(s),'audits':{k:max(abs(n(r,k)) for r in s) for k in ['population_error','money_error','goods_error']},'cells':{},'global':{} }
fields=['merchant_cash','merchant_inventory_liquidation_value','merchant_economic_assets','merchant_operating_outflow','merchant_liquidity_coverage_q16']
for c,byday in m.items():
 rs=list(byday.values());initial=n(rs[0],'merchant_cash');cash=[n(r,'merchant_cash') for r in rs];events={}
 for ratio in [.5,.1,.05]:
  ds=[d for d,r in byday.items() if n(r,'merchant_cash')<initial*ratio];best=run=0;prev=-2
  for d in ds:run=run+1 if d==prev+1 else 1;best=max(best,run);prev=d
  events[str(ratio)]={'first_day':ds[0] if ds else None,'days':len(ds),'longest_run':best}
 result['cells'][c]={'first':cash[0],'last':cash[-1],'change_pct':100*(cash[-1]/initial-1),'minimum':min(cash),'minimum_day':n(min(rs,key=lambda r:n(r,'merchant_cash')),'day_index'),'zero_days':cash.count(0),'events':events,'snapshots':{d:({k:n(byday[d],k) for k in fields}|dict(cs[c,d])) for d in [1,30,100,200,500,1000]},'top_inventory':{d:sorted([(g,v['stock']*v['price']/1000) for g,v in goods[c,d].items()],key=lambda x:-x[1])[:5] for d in [1,200,1000]}}
for k in ['merchant_cash','merchant_economic_assets','merchant_inventory_liquidation_value','merchant_procurement_spent','producer_support_money_issued','bullion_money_issued','merchant_credit_drawn','merchant_credit_repaid','merchant_trade_purchase_cash','merchant_trade_sale_cash','construction_goods_consumed']:
 result['global'][k]={'first':n(s[0],k),'last':n(s[-1],k),'min':min(n(r,k) for r in s),'max':max(n(r,k) for r in s),'sum_flow_only':sum(n(r,k) for r in s)}
result['local_cash_matches_global']=all(sum(n(m[c][n(r,'day_index')],'merchant_cash') for c in m)==n(r,'merchant_cash') for r in s)
result['global_population']={d:sum(cs[c,d]['population'] for c in m) for d in [1,30,100,200,500,1000]}
Path('tmp/merchant_liquidity_player_20260921/analysis.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
with open('tmp/merchant_liquidity_player_20260921/merchant_daily.csv','w',newline='',encoding='utf-8-sig') as f:
 w=csv.writer(f);w.writerow(['day','cell']+fields+['merchant_population','merchant_income','merchant_expense','population'])
 for c,byday in m.items():
  for d,r in byday.items():w.writerow([d,c]+[n(r,k) for k in fields]+[cs[c,d][k] for k in ['merchant_population','merchant_epoch_income','merchant_epoch_expense','population']])
print(json.dumps(result,indent=2))
