import csv, statistics as st
from collections import defaultdict, Counter

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
active=[gid for gid,rs in byg.items() if (sum(g(x,'stock') for x in rs)+sum(g(x,'demand_ema') for x in rs)
        +sum(g(x,'offered_supply_ema') for x in rs)+sum(g(x,'realized_withdrawal_ema') for x in rs)
        +sum(g(x,'production_input_reserve') for x in rs))]

print('=== TRADE STATE per good (full run sums / last180) ===')
print('%-22s %6s %8s %8s %8s %8s %8s %8s %8s  %s' % ('good','enab','sigAge','dispDel','attempts','reliefF','reliefL','in','out','lastRej'))
for gid in sorted(active):
    rs = byg[gid]
    en = st.mean([g(x,'trade_enabled') for x in rs])
    sa = st.mean([g(x,'trade_signal_age_days') for x in rs])
    dd = st.mean([g(x,'trade_first_dispatch_delay_days') for x in rs])
    att = sum(1 for x in rs if g(x,'trade_last_attempt_day')>0)
    rf = st.mean([g(x,'trade_relief_pressure_q16') for x in rs[:90]])/65536
    rl = st.mean([g(x,'trade_relief_pressure_q16') for x in rs[-90:]])/65536
    ib = sum(g(x,'trade_inbound') for x in rs); ob = sum(g(x,'trade_outbound') for x in rs)
    rj = Counter(x[ix['trade_last_rejection_reason']] for x in rs)
    print('%-22s %6.0f %8.0f %8.0f %8d %8.2f %8.2f %8.0f %8.0f  %s' % (
        gid, en, sa, dd, att, rf, rl, ib, ob, dict(rj.most_common(4))))

print('\n=== TIME SERIES (quarterly samples) ===')
def ts(gid, keys):
    rs = byg[gid]
    print('-- %s' % gid)
    n = len(rs)
    for k in keys:
        v = [g(x,k) for x in rs]
        samp = [v[int(i*(n-1)/11)] for i in range(12)]
        print('   %-30s' % k + ' '.join('%10.1f' % s for s in samp))
for gid in ['fish','logs','game_meat','prepared_staples','rice_grain','gathered_plants','charcoal','bast_fiber','lumber','clothing']:
    ts(gid, ['stock','household_available_stock','demand_ema','offered_supply_ema','realized_withdrawal_ema','shortage_q16','price'])

print('\n=== price movement stats (full-run) ===')
for gid in sorted(active):
    rs=byg[gid]
    p=[g(x,'price') for x in rs]
    if p[0] and max(p):
        print('%-22s first=%12.0f min=%12.0f max=%12.0f last=%12.0f  max/min=%8.2f  last/first=%8.3f' % (
            gid, p[0], min(p), max(p), p[-1], max(p)/max(1e-9,min(p)), p[-1]/max(1e-9,p[0])))
