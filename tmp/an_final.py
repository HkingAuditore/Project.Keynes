import csv, statistics as st
from collections import defaultdict
BASE='economy_record_20260831_140522_v25_cell650_q45_r10'
def load(n):
    f=open(BASE+'_'+n+'.csv',encoding='utf-8-sig'); r=csv.reader(f); h=next(r)
    return h,{c:i for i,c in enumerate(h)},list(r)
def mk(ix):
    def g(x,k):
        v=x[ix[k]]
        if v in ('',None): return 0.0
        try: return float(v)
        except: return v
    return g

# --- resources: paddy_land etc over time
H,ix,rows=load('resources'); g=mk(ix)
print('=== LAND / RESOURCE availability in cell 650 (first vs last) ===')
byres=defaultdict(list)
for x in rows: byres[x[ix['resource_id']]].append(x)
for k in byres: byres[k].sort(key=lambda x:g(x,'day_index'))
for rid in ['paddy_land','arable_land','plantation_land','pasture','fertile_soil','marine_fish','wild_game','timber']:
    rs=byres[rid]
    print('  %-18s opening=%14.1f  final=%14.1f  min=%14.1f max=%14.1f  safe_yield=%10.0f projLife=%s' % (
        rid, g(rs[0],'opening_reserve'), g(rs[-1],'reserve'),
        min(g(x,'reserve') for x in rs), max(g(x,'reserve') for x in rs),
        g(rs[-1],'safe_yield'), ('%.0f'%g(rs[-1],'projected_life_days'))))

# --- cohorts: population trajectory + satisfaction
H,ix,rows=load('cohorts'); g=mk(ix)
days=sorted({int(g(x,'day_index')) for x in rows})
byd=defaultdict(list)
for x in rows: byd[int(g(x,'day_index'))].append(x)
pop=[sum(g(x,'population') for x in byd[d]) for d in days]
sat=[sum(g(x,'satisfaction_q16')*g(x,'population') for x in byd[d])/max(1,sum(g(x,'population') for x in byd[d]))/65536 for d in days]
cov=[sum(g(x,'livelihood_coverage_q16')*g(x,'population') for x in byd[d])/max(1,sum(g(x,'population') for x in byd[d]))/65536 for d in days]
print('\n=== POPULATION / SATISFACTION trajectory (12 samples over %d days) ===' % len(days))
for nm,v in [('population',pop),('satisfaction(w)',sat),('livelihood_cov(w)',cov)]:
    print('  %-18s' % nm + ' '.join('%8.3f' % v[int(i*(len(v)-1)/11)] for i in range(12)))
print('  population first=%d last=%d max=%d min=%d' % (pop[0],pop[-1],max(pop),min(pop)))
print('  satisfaction first=%.3f last=%.3f  drop=%.3f' % (sat[0],sat[-1],sat[0]-sat[-1]))
print('  coverage     first=%.3f last=%.3f' % (cov[0],cov[-1]))

# onset of satisfaction decline
base=st.mean(sat[:30])
onset=None
for i,v in enumerate(sat):
    if v < base-0.05: onset=days[i]; break
print('  satisfaction first day 0.05 below 30d baseline:', onset, '(day index %d -> sim day %s)' % (0,onset))

# --- market: staple_food goods sales/demand
H,ix,rows=load('market'); g=mk(ix)
print('\n=== FOOD GOODS: shortage (=1 - sales/demand) trajectory ===')
byg=defaultdict(list)
for x in rows: byg[x[ix['good_id']]].append(x)
for k in byg: byg[k].sort(key=lambda x:g(x,'day_index'))
for gid in ['rice_grain','prepared_staples','gathered_plants','game_meat','fish','charcoal']:
    rs=byg[gid]; v=[g(x,'shortage_q16')/65536 for x in rs]
    print('  %-18s' % gid + ' '.join('%6.2f' % v[int(i*(len(v)-1)/11)] for i in range(12)))

# --- summary conservation + headline
H,ix,rows=load('summary'); g=mk(ix)
print('\n=== CONSERVATION AUDITS (global) ===')
for k in ['population_error','money_error','goods_error']:
    v=[g(x,k) for x in rows]
    print('  %-18s max_abs=%s  nonzero_days=%d' % (k, max(abs(y) for y in v), sum(1 for y in v if y)))
print('\n=== HEADLINE (global summary) ===')
for k in ['building_group_count','building_investments_started','building_investment_candidates',
          'filled_owner_jobs','filled_employee_jobs','unemployed_population','births','deaths',
          'building_owner_mobility','building_owner_job_reallocations','trade_orders_arrived',
          'trade_orders_dispatched','production_output_discarded','production_output_stock']:
    v=[g(x,k) for x in rows]
    print('  %-38s total=%16.0f  first90mean=%14.2f last90mean=%14.2f' % (k,sum(v),st.mean(v[:90]),st.mean(v[-90:])))

# --- discard share
H,ix,rows=load('buildings'); g=mk(ix)
real=[x for x in rows if g(x,'group_index')>=0 and g(x,'is_construction')==0]
late=[x for x in real if g(x,'day_index')>=days[-90]]
o=sum(g(x,'last_output') for x in late); d=sum(g(x,'last_discarded') for x in late)
s=sum(g(x,'last_sold') for x in late); r=sum(g(x,'last_retained') for x in late)
print('\n=== OUTPUT DISPOSITION (real groups, last 90d, cell 650) ===')
print('  output=%.0f  sold=%.0f (%.1f%%)  discarded=%.0f (%.1f%%)  retained=%.0f (%.1f%%)' % (
    o,s,100*s/max(1,o),d,100*d/max(1,o),r,100*r/max(1,o)))
