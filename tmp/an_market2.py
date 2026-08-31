import csv, statistics as st
from collections import defaultdict

BASE = 'economy_record_20260831_140522_v25_cell650_q45_r10'
f = open(BASE + '_market.csv', encoding='utf-8-sig')
r = csv.reader(f); H = next(r)
ix = {c: i for i, c in enumerate(H)}
rows = list(r)
def g(row,k):
    v = row[ix[k]]
    if v=='' or v is None: return 0.0
    try: return float(v)
    except: return v
days = sorted({int(g(x,'day_index')) for x in rows})

byg = defaultdict(list)
for x in rows: byg[x[ix['good_id']]].append(x)
for k in byg: byg[k].sort(key=lambda x: g(x,'day_index'))

active = []
for gid, rs in byg.items():
    s = (sum(g(x,'stock') for x in rs) + sum(g(x,'demand_ema') for x in rs)
         + sum(g(x,'offered_supply_ema') for x in rs) + sum(g(x,'realized_withdrawal_ema') for x in rs)
         + sum(g(x,'production_input_reserve') for x in rs))
    if s: active.append(gid)
actset = set(active)
print('active goods', len(active), sorted(active))

def mw(rs,k,n=90):
    v=[g(x,k) for x in rs]
    return st.mean(v[:n]), st.mean(v[-n:])

print('\n=== ACTIVE GOODS DETAIL ===')
hdr = ('good','stockF','stockL','hhF','hhL','demF','demL','supF','supL','wdF','wdL',
       'tgtF','tgtL','shortF','shortL','costF','priceF','priceL','x_anchorF','x_anchorL')
print('%-22s' % 'good' + ''.join('%11s' % c for c in hdr[1:]))
for gid in sorted(active, key=lambda k: -st.mean([g(x,'price') for x in byg[k][-90:]])*max(1,st.mean([g(x,'demand_ema') for x in byg[k][-90:]]))):
    rs = byg[gid]
    sf,sl = mw(rs,'stock'); hf,hl = mw(rs,'household_available_stock')
    df,dl = mw(rs,'demand_ema'); spf,spl = mw(rs,'offered_supply_ema')
    wf,wl = mw(rs,'realized_withdrawal_ema'); tf,tl = mw(rs,'merchant_inventory_target')
    shf,shl = mw(rs,'shortage_q16'); cf,cl = mw(rs,'cost_anchor_price')
    pf,pl = mw(rs,'price')
    print('%-22s' % gid + ''.join('%11.0f' % v for v in (sf,sl,hf,hl,df,dl,spf,spl,wf,wl,tf,tl))
          + '%11.2f%11.2f%11.0f%11.0f%11.0f%11.1f%11.1f' % (shf/65536, shl/65536, cf, pf, pl,
              (pf/cf) if cf else float('nan'), (pl/cl) if cl else float('nan')))

print('\n=== DAILY AGGREGATE over active goods ===')
byd = defaultdict(list)
for x in rows: byd[int(g(x,'day_index'))].append(x)
for k in ['stock','household_available_stock','demand_ema','business_demand_ema','offered_supply_ema',
          'realized_withdrawal_ema','production_input_reserve','construction_material_reserve',
          'merchant_inventory_target','merchant_procurement_shortfall',
          'desired_business_demand','funded_business_demand','unfunded_business_demand',
          'trade_import_ema','trade_export_ema','trade_inbound','trade_outbound']:
    v=[sum(g(x,k) for x in byd[d] if x[ix['good_id']] in actset) for d in days]
    print('%-34s first=%12.0f mid=%12.0f last=%12.0f f90=%12.0f l90=%12.0f' % (
        k, v[0], v[len(v)//2], v[-1], st.mean(v[:90]), st.mean(v[-90:])))

# trade activity per good
print('\n=== TRADE per good (last 180d) ===')
for gid in sorted(active):
    rs=[x for x in byg[gid] if g(x,'day_index')>=days[-180]]
    sig=sum(g(x,'trade_source_signals') for x in rs); dig=sum(g(x,'trade_destination_signals') for x in rs)
    att=sum(1 for x in rs if g(x,'trade_last_attempt_day')>0)
    rej=defaultdict(int)
    for x in rs:
        rr=x[ix['trade_last_rejection_reason']]
        if rr and rr!='0' and rr!='': rej[rr]+=1
    ib=sum(g(x,'trade_inbound') for x in rs); ob=sum(g(x,'trade_outbound') for x in rs)
    if sig or dig or att or ib or ob:
        print('%-22s sig=%6.0f dsig=%6.0f attempts=%5d rej=%s in=%8.0f out=%8.0f' % (gid,sig,dig,att,dict(rej),ib,ob))
