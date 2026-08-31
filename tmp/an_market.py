import csv, statistics as st
from collections import defaultdict

BASE = 'economy_record_20260831_140522_v25_cell650_q45_r10'
f = open(BASE + '_market.csv', encoding='utf-8-sig')
r = csv.reader(f); H = next(r)
ix = {c: i for i, c in enumerate(H)}
rows = list(r)
print('market rows', len(rows), 'cols', len(H))
def g(row,k):
    v = row[ix[k]]
    if v=='' or v is None: return 0.0
    try: return float(v)
    except: return v

days = sorted({int(g(x,'day_index')) for x in rows})
print('days', len(days), days[0], days[-1])
goods = sorted({x[ix['good_id']] for x in rows})
print('goods', len(goods))

byg = defaultdict(list)
for x in rows: byg[x[ix['good_id']]].append(x)
for k in byg: byg[k].sort(key=lambda x: g(x,'day_index'))

# active goods: any nonzero stock, demand, supply, or production reserve over the run
active = []
for gid, rs in byg.items():
    tot_stock = sum(g(x,'stock') for x in rs)
    tot_dem = sum(g(x,'demand_ema') for x in rs)
    tot_sup = sum(g(x,'offered_supply_ema') for x in rs)
    tot_res = sum(g(x,'production_input_reserve') for x in rs)
    tot_wh = sum(g(x,'realized_withdrawal_ema') for x in rs)
    if tot_stock or tot_dem or tot_sup or tot_res or tot_wh:
        active.append((gid, tot_stock, tot_dem, tot_sup, tot_res, tot_wh))
print('\nactive goods:', len(active), 'of', len(goods))

def mw(rs, k, n=90):
    v=[g(x,k) for x in rs]
    return st.mean(v[:n]) if len(v)>=n else st.mean(v), st.mean(v[-n:]) if len(v)>=n else st.mean(v)

print('\n=== ACTIVE GOODS: first90 vs last90 ===')
print('%-26s %12s %12s %10s %10s %10s %10s %10s %10s %8s %8s %10s' % (
 'good','stock_f','stock_l','dem_f','dem_l','sup_f','sup_l','wd_f','wd_l','shortF','shortL','priceF/L'))
act = []
for gid, ts, td, tsup, tres, twh in active:
    rs = byg[gid]
    sf, sl = mw(rs,'stock'); df, dl = mw(rs,'demand_ema'); spf, spl = mw(rs,'offered_supply_ema')
    wf, wl = mw(rs,'realized_withdrawal_ema')
    shf, shl = mw(rs,'shortage_q16')
    pf = st.mean([g(x,'price') for x in rs[:90]]); pl = st.mean([g(x,'price') for x in rs[-90:]])
    act.append((td+tsup+twh, gid, sf,sl,df,dl,spf,spl,wf,wl,shf/65536,shl/65536,pf,pl))
act.sort(reverse=True)
for _, gid, sf,sl,df,dl,spf,spl,wf,wl,shf,shl,pf,pl in act[:45]:
    print('%-26s %12.0f %12.0f %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f %8.2f %8.2f %10.0f/%.0f' % (
        gid, sf,sl,df,dl,spf,spl,wf,wl,shf,shl,pf,pl))

# merchant aggregates dedup by (epoch_row_id, cell)
seen=set(); merch=[]
for x in rows:
    k=(x[ix['epoch_row_id']], x[ix['cell_idx']])
    if k in seen: continue
    seen.add(k); merch.append(x)
merch.sort(key=lambda x: g(x,'day_index'))
print('\n=== MERCHANT (dedup %d rows) ===' % len(merch))
for k in ['merchant_cash','merchant_inventory_retail_value','merchant_inventory_liquidation_value',
          'merchant_economic_assets','merchant_procurement_margin_value','merchant_trade_purchase_cash',
          'merchant_trade_sale_cash','merchant_operating_outflow','merchant_liquidity_coverage_q16',
          'merchant_effective_buy_factor_q16']:
    v=[g(x,k) for x in merch]
    print('%-42s first=%16.0f last=%16.0f  f90=%16.0f l90=%16.0f' % (k, v[0], v[-1], st.mean(v[:90]), st.mean(v[-90:])))

# aggregate stock/withdrawal over active goods per day
print('\n=== DAILY AGGREGATE (active goods) ===')
byd = defaultdict(list)
for x in rows: byd[int(g(x,'day_index'))].append(x)
actset = {a[1] for a in active}
agg = {}
for k in ['stock','household_available_stock','demand_ema','business_demand_ema','offered_supply_ema',
          'realized_withdrawal_ema','production_input_reserve','merchant_procurement_shortfall',
          'desired_business_demand','funded_business_demand','unfunded_business_demand',
          'trade_import_ema','trade_export_ema','trade_inbound','trade_outbound']:
    agg[k] = [sum(g(x,k) for x in byd[d] if x[ix['good_id']] in actset) for d in days]
for k,v in agg.items():
    print('%-34s first=%12.0f mid=%12.0f last=%12.0f f90=%12.0f l90=%12.0f' % (
        k, v[0], v[len(v)//2], v[-1], st.mean(v[:90]), st.mean(v[-90:])))

# price index: goods present both windows with nonzero stock
pf=[];pl=[]
for gid,_,_,_,_,_ in active:
    rs=byg[gid]
    a=st.mean([g(x,'price') for x in rs[:90]]); b=st.mean([g(x,'price') for x in rs[-90:]])
    if a>0 and b>0: pf.append(a); pl.append(b)
print('\nprice index (equal-weight, active goods n=%d): first=%.1f last=%.1f  ratio=%.3f' % (
    len(pf), st.mean(pf), st.mean(pl), st.mean(pl)/st.mean(pf)))
