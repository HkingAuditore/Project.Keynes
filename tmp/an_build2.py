import csv, statistics as st
from collections import defaultdict, Counter
BASE='economy_record_20260831_140522_v25_cell650_q45_r10'
f=open(BASE+'_buildings.csv',encoding='utf-8-sig'); r=csv.reader(f); H=next(r)
ix={c:i for i,c in enumerate(H)}; rows=list(r)
def g(x,k):
    v=x[ix[k]]
    if v in ('',None): return 0.0
    try: return float(v)
    except: return v
days=sorted({int(g(x,'day_index')) for x in rows})
real=[x for x in rows if g(x,'group_index')>=0 and g(x,'is_construction')==0]
cand=[x for x in rows if g(x,'group_index')==-1]

print('=== REAL GROUP ROWS: survival / opportunity / investment fields ===')
KEYS=['survival_priority','survival_shortage_q16','opportunity_owner_income_per_day',
 'opportunity_disposable_survival_power_per_day','opportunity_executable_capacity_q16',
 'opportunity_in_kind_retail_value','monetary_quota_absorption_q16','monetary_quote_capped',
 'investment_stealable','investment_candidate','investment_utilization_q16','investment_shortage_q16',
 'investment_required_capital','investment_projected_profit_per_day','investment_return_on_capital_q16',
 'investment_score_q16','investment_payback_days','projected_owner_income_per_day',
 'owner_living_cost_per_day','owner_livelihood_required','viability_income_gap','filled_owner',
 'owner_required','owner_capacity','count','planned_utilization_q16','last_output','last_sold',
 'last_discarded','last_retained','operating_state','wage_suspended','employee_required']
for k in KEYS:
    if k not in ix: print('  MISSING',k); continue
    v=[g(x,k) for x in real]
    nz=[y for y in v if y]
    print('  %-46s nz=%5d/%5d  sum=%14.0f  mean_nz=%14.2f  max=%12.0f' % (
        k, len(nz), len(v), sum(v), st.mean(nz) if nz else 0, max(v)))

print('\n=== per type_id (real rows, last 90d): survival + opportunity + staffing ===')
last90=[x for x in real if g(x,'day_index')>=days[-90]]
byt=defaultdict(list)
for x in last90: byt[int(g(x,'type_id'))].append(x)
hdr=['count','owner_capacity','filled_owner','owner_required','survival_priority','survival_shortage_q16',
     'opportunity_executable_capacity_q16','opportunity_owner_income_per_day','investment_candidate',
     'investment_utilization_q16','investment_shortage_q16','investment_score_q16','investment_stealable',
     'last_output','last_sold','last_discarded','planned_utilization_q16']
print('%-6s'%'type'+''.join('%12s'%h[:11] for h in hdr))
for t,rs in sorted(byt.items()):
    print('%-6d'%t+''.join('%12.2f'%st.mean([g(x,k) for x in rs]) for k in hdr))

print('\n=== CANDIDATE rejection by type (last 180d) ===')
lc=[x for x in cand if g(x,'day_index')>=days[-180]]
bt=defaultdict(Counter)
for x in lc: bt[int(g(x,'type_id'))][x[ix['investment_rejection_reason']]]+=1
NAMES={'0':'NONE','1':'PEND_CONSTRUCT','2':'SUSPENDED_CAP','3':'OWNER_VACANCY','4':'CAP_SUFFICIENT',
 '5':'OWNER_LIVELIHOOD','6':'SELL_THROUGH','7':'DISCARD','8':'INPUT_CHAIN','9':'TARGET_MARGIN',
 '10':'PAYBACK','11':'SPONSOR_CAPITAL','12':'MATERIALS','13':'RESOURCE','14':'PROBABILITY',
 '15':'MARKET_SIGNAL','16':'GROWTH_LIMIT','17':'UNSUPPORTED_KIND','18':'NO_COST_ADVANTAGE'}
for t,c in sorted(bt.items(), key=lambda kv:-sum(kv[1].values())):
    tot=sum(c.values())
    s=' '.join('%s:%d(%.0f%%)'%(NAMES.get(k,k),v,100*v/tot) for k,v in c.most_common(5))
    print('  type %3d n=%5d  %s' % (t,tot,s))

print('\n=== candidate type_id distribution: how many DISTINCT types are evaluated? ===')
print('  distinct candidate types:', len({int(g(x,'type_id')) for x in cand}), 'of 395 catalog types')
print('  most-evaluated:', Counter(int(g(x,'type_id')) for x in cand).most_common(15))

print('\n=== time trend of rejection reasons (quarterly) ===')
n=len(days)
for i in range(6):
    lo=days[int(i*n/6)]; hi=days[int((i+1)*n/6)-1]
    sub=[x for x in cand if lo<=g(x,'day_index')<=hi]
    c=Counter(x[ix['investment_rejection_reason']] for x in sub)
    print('  window %d days %d-%d n=%d : %s' % (i,lo,hi,len(sub),
        ' '.join('%s:%d'%(NAMES.get(k,k),v) for k,v in c.most_common(6))))
