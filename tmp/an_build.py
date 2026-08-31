import csv, statistics as st
from collections import defaultdict, Counter
BASE='economy_record_20260831_140522_v25_cell650_q45_r10'
f=open(BASE+'_buildings.csv',encoding='utf-8-sig'); r=csv.reader(f); H=next(r)
ix={c:i for i,c in enumerate(H)}; rows=list(r)
print('buildings rows',len(rows),'cols',len(H))
def g(x,k):
    v=x[ix[k]]
    if v in ('',None): return 0.0
    try: return float(v)
    except: return v
days=sorted({int(g(x,'day_index')) for x in rows})
print('days',len(days),days[0],days[-1])

# row classes
cons=[x for x in rows if g(x,'is_construction')!=0]
cand=[x for x in rows if g(x,'group_index')==-1]
real=[x for x in rows if g(x,'group_index')>=0 and g(x,'is_construction')==0]
print('rows: construction=%d candidate=%d real=%d' % (len(cons),len(cand),len(real)))
print('per day: cons=%.2f cand=%.2f real=%.2f' % (len(cons)/len(days),len(cand)/len(days),len(real)/len(days)))
print('\nbuilding types (type_id) present in real rows:', sorted({int(g(x,'type_id')) for x in real}))
print('group_index values:', sorted({int(g(x,'group_index')) for x in real}))
print('\ntype_id counts (real rows / days):')
c=Counter(int(g(x,'type_id')) for x in real)
days_n=len(days)
for t,n in sorted(c.items()): print('  type %3d : %6d rows -> %6.2f rows/day' % (t,n,n/days_n))

# Are these candidate rows (investment)? check investment columns on candidates
if cand:
    print('\n=== CANDIDATE (investment) rows: rejection reasons ===')
    print(Counter(x[ix['investment_rejection_reason']] for x in cand).most_common())
    for k in ['investment_score_q16','investment_payback_days','investment_required_capital',
              'investment_projected_profit_per_day','investment_utilization_q16','investment_shortage_q16',
              'investment_return_on_capital_q16','investment_cost_advantage_q16','opportunity_owner_income_per_day',
              'opportunity_executable_capacity_q16','opportunity_disposable_survival_power_per_day',
              'survival_priority','survival_shortage_q16','monetary_quota_absorption_q16','monetary_quote_capped',
              'investment_monetary_quota_initial','investment_monetary_quota_daily','investment_monetary_units',
              'investment_monetary_candidate_slots','investment_stealable']:
        if k not in ix: print('  MISSING',k); continue
        v=[g(x,k) for x in cand]
        nz=[y for y in v if y]
        print('  %-42s nz=%5d/%5d mean(nz)=%14.2f  first=%12.0f last=%12.0f' % (k,len(nz),len(v), st.mean(nz) if nz else 0, v[0],v[-1]))

print('\n=== REAL GROUPS: aggregate per day ===')
byd=defaultdict(list)
for x in real: byd[int(g(x,'day_index'))].append(x)
KEYS=['count','owner_capacity','owner_required','planned_owner_equivalent','filled_owner','owner_openings',
 'employee_required','employee_filled','wage_suspended','capacity_q16','purchase_intent_capacity_q16',
 'realized_profit_margin_q16','severe_loss_cycles','recovery_cycles','last_input','last_output','last_sold',
 'last_discarded','last_retained','last_resource','last_resource_generated','last_revenue','last_input_cost',
 'last_wages_paid','last_wages_due','last_expected_revenue','last_operating_cost','last_margin_gap_q16',
 'planned_utilization_q16','last_base_wages_due','last_base_wages_paid','last_bonus_due','last_bonus_paid',
 'owner_living_cost_per_day','owner_livelihood_required','viability_operating_cost','viability_income_gap',
 'projected_owner_income_per_day','owner_working_capital_allocated','funded_capacity_q16',
 'last_in_kind_livelihood_value','last_climate_capacity_q16','last_climate_lost_output',
 'merchant_debt_principal','merchant_debt_delinquent_cycles','operating_state']
series={}
for k in KEYS:
    if k not in ix: print('  MISSING',k); continue
    series[k]=[sum(g(x,k) for x in byd[d]) for d in days]
for k,v in series.items():
    print('  %-34s first=%12.0f mid=%12.0f last=%12.0f f90=%12.0f l90=%12.0f' % (k,v[0],v[len(v)//2],v[-1],st.mean(v[:90]),st.mean(v[-90:])))

print('\n=== operating_state counts (real rows) ===')
print(Counter((x[ix['operating_state']]) for x in real).most_common())

print('\n=== per type_id aggregate (last 90d) ===')
last90=[x for x in real if g(x,'day_index')>=days[-90]]
byt=defaultdict(list)
for x in last90: byt[int(g(x,'type_id'))].append(x)
hdr=['count','owner_capacity','filled_owner','employee_required','employee_filled','last_input','last_output',
     'last_sold','last_discarded','last_retained','last_revenue','last_input_cost','last_wages_paid',
     'last_expected_revenue','last_operating_cost','planned_utilization_q16','realized_profit_margin_q16',
     'projected_owner_income_per_day','owner_living_cost_per_day','viability_income_gap','last_climate_capacity_q16']
print('%-6s'%'type'+''.join('%13s'%h[:12] for h in hdr))
for t,rs in sorted(byt.items()):
    n=len(rs)/90.0
    vals=[]
    for k in hdr:
        vals.append(st.mean([g(x,k) for x in rs])*n if k in ix else 0)
    print('%-6d'%t+''.join('%13.1f'%v for v in vals))

print('\n=== suspension / loss ===')
susp=[x for x in real if g(x,'operating_state') not in (0,'0','')]
print('nonzero operating_state rows:',len(susp), Counter(x[ix['operating_state']] for x in susp).most_common())
for k in ['severe_loss_cycles','recovery_cycles','recovery_failed_reviews','suspended_restart_cycles',
          'suspended_liquidation_failed_reviews','wage_suspended']:
    if k not in ix: continue
    v=[g(x,k) for x in real]
    print('  %-36s last=%8.0f max=%8.0f  sum=%10.0f' % (k, series[k][-1] if k in series else 0, max(v), sum(v)))
