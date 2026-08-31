import csv, statistics as st
from collections import defaultdict
BASE='economy_record_20260831_140522_v25_cell650_q45_r10'
def load(n):
    f=open(BASE+'_'+n+'.csv',encoding='utf-8-sig'); r=csv.reader(f); h=next(r)
    return h,{c:i for i,c in enumerate(h)},list(r)

H,ix,rows=load('market')
def g(x,k):
    v=x[ix[k]]
    if v in ('',None): return 0.0
    try: return float(v)
    except: return v
days=sorted({int(g(x,'day_index')) for x in rows})
byg=defaultdict(list)
for x in rows: byg[x[ix['good_id']]].append(x)
for k in byg: byg[k].sort(key=lambda x:g(x,'day_index'))

print('=== FISH collapse onset ===')
rs=byg['fish']
prev=None
for x in rs:
    s=g(x,'stock')
    if prev is not None and prev>0 and s==0:
        print('  first zero-stock day:',int(g(x,'day_index')),' prev stock',prev); break
    prev=s
# last positive
lastpos=[x for x in rs if g(x,'stock')>0]
print('  last positive stock day:',int(g(lastpos[-1],'day_index')) if lastpos else None)
print('  runs of zero stock at end:', sum(1 for x in rs[-200:] if g(x,'stock')==0),'/200')
print('  days with stock>0 total:', sum(1 for x in rs if g(x,'stock')>0))

print('\n=== trade_signal_age_days trajectory (sample every 60d) ===')
for gid in ['fish','rice_grain','prepared_staples','gathered_plants','logs','charcoal','turf_block','reed_bundle']:
    rs=byg[gid]; v=[g(x,'trade_signal_age_days') for x in rs]
    print('  %-20s' % gid + ' '.join('%8.0f' % v[i] for i in range(0,len(v),60)))

print('\n=== trade_last_attempt_day trajectory ===')
for gid in ['fish','rice_grain','prepared_staples','charcoal']:
    rs=byg[gid]; v=[g(x,'trade_last_attempt_day') for x in rs]
    print('  %-20s' % gid + ' '.join('%8.0f' % v[i] for i in range(0,len(v),60)))

print('\n=== rejection reason codes seen ===')
from collections import Counter
c=Counter(x[ix['trade_last_rejection_reason']] for x in rows)
print(c.most_common())

print('\n=== SIGNAL AGE vs SIM DAY (is it absolute day?) ===')
rs=byg['fish']
for i in range(0,len(rs),90):
    print('  day=%d  sigAge=%.0f  attemptDay=%.0f  deadlineExceeded=%s' % (
        g(rs[i],'day_index'), g(rs[i],'trade_signal_age_days'), g(rs[i],'trade_last_attempt_day'),
        rs[i][ix['trade_deadline_exceeded']]))

# ---- RESOURCES ----
print('\n\n===== RESOURCES =====')
H2,ix2,r2=load('resources')
def g2(x,k):
    v=x[ix2[k]]
    if v in ('',None): return 0.0
    try: return float(v)
    except: return v
byres=defaultdict(list)
for x in r2: byres[x[ix2['resource_id']]].append(x)
for k in byres: byres[k].sort(key=lambda x:g2(x,'day_index'))
print('%-18s %14s %14s %12s %12s %10s %10s %10s %10s' % ('resource','openF','reserveL','natNetTot','artifExtTot','appliedTot','pendingEnd','safeYield','projLifeL'))
for rid,rs in sorted(byres.items()):
    op=g2(rs[0],'opening_reserve'); fin=g2(rs[-1],'reserve')
    if op==0 and fin==0 and sum(abs(g2(x,'natural_net_change')) for x in rs)==0: continue
    nat=sum(g2(x,'natural_net_change') for x in rs)
    ext=sum(g2(x,'artificial_extraction_applied') for x in rs)
    app=sum(g2(x,'artificial_change_applied') for x in rs)
    pend=g2(rs[-1],'artificial_change_pending')
    print('%-18s %14.1f %14.1f %12.1f %12.1f %10.1f %10.1f %10.0f %10s' % (
        rid, op, fin, nat, ext, app, pend, g2(rs[-1],'safe_yield'), ('%.0f'%g2(rs[-1],'projected_life_days'))))

print('\n-- resource time series (nonzero, changed) --')
for rid,rs in sorted(byres.items()):
    op=g2(rs[0],'opening_reserve')
    fin=g2(rs[-1],'reserve')
    if op==0: continue
    if abs(fin-op)/max(1e-9,abs(op)) < 1e-6: continue
    v=[g2(x,'reserve') for x in rs]; n=len(v)
    print('  %-16s' % rid + ' '.join('%12.1f' % v[int(i*(n-1)/11)] for i in range(12)))
