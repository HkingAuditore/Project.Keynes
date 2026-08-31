import csv, statistics as st
from collections import defaultdict

BASE = 'economy_record_20260831_140522_v25_cell650_q45_r10'

def load(name):
    f = open(BASE + '_' + name + '.csv', encoding='utf-8-sig')
    r = csv.reader(f); h = next(r)
    idx = {c: i for i, c in enumerate(h)}
    return h, idx, list(r)

h, ix, rows = load('cohorts')
print('cohorts rows', len(rows))
def g(row, k):
    v = row[ix[k]]
    if v == '' or v is None: return 0.0
    try: return float(v)
    except: return v

days = sorted({int(g(r,'day_index')) for r in rows})
print('days', len(days), days[0], days[-1])
sigs = sorted({g(r,'signature_id') for r in rows})
print('signatures', len(sigs))

# per-day totals (cell 650 only -> local)
by_day = defaultdict(list)
for r in rows: by_day[int(g(r,'day_index'))].append(r)

def series(fn):
    return [fn(by_day[d]) for d in days]

pop = series(lambda rs: sum(g(r,'population') for r in rs))
funds = series(lambda rs: sum(g(r,'funds') for r in rs))
inc = series(lambda rs: sum(g(r,'epoch_income') for r in rs))
exp = series(lambda rs: sum(g(r,'epoch_expense') for r in rs))
inkind = series(lambda rs: sum(g(r,'epoch_in_kind_income') for r in rs))
unemp = series(lambda rs: sum(g(r,'unemployed') for r in rs))
own = series(lambda rs: sum(g(r,'owner_employed') for r in rs))
emp = series(lambda rs: sum(g(r,'employee_employed') for r in rs))

def show(name, s, per_pop=None):
    n = len(s)
    a = st.mean(s[:90]); b = st.mean(s[-90:])
    print('%-28s first=%14.2f mid=%14.2f last=%14.2f  f90=%14.2f l90=%14.2f  min=%.2f max=%.2f' % (
        name, s[0], s[n//2], s[-1], a, b, min(s), max(s)))

print()
show('population', pop)
show('funds', funds)
show('income', inc)
show('expense', exp)
show('in_kind_income', inkind)
show('unemployed', unemp)
show('owner_employed', own)
show('employee_employed', emp)
show('funds_per_capita', [f/p if p else 0 for f,p in zip(funds,pop)])
show('net_income_pc', [(i-e)/p if p else 0 for i,e,p in zip(inc,exp,pop)])
show('unemployment_rate', [u/p if p else 0 for u,p in zip(unemp,pop)])

print('\n--- per signature (first 40d vs last 40d) ---')
print('%-14s %6s %6s %8s %8s %14s %14s %12s %12s %10s %10s' % (
 'sig','prof','merch','pop_f','pop_l','funds_pc_f','funds_pc_l','cov_f','cov_l','sat_f','sat_l'))
for s in sigs:
    rr = [r for r in rows if g(r,'signature_id')==s]
    rr.sort(key=lambda r: g(r,'day_index'))
    pf = st.mean([g(r,'population') for r in rr[:40]])
    pl = st.mean([g(r,'population') for r in rr[-40:]])
    ff = st.mean([g(r,'funds')/max(1,g(r,'population')) for r in rr[:40]])
    fl = st.mean([g(r,'funds')/max(1,g(r,'population')) for r in rr[-40:]])
    cf = st.mean([g(r,'livelihood_coverage_q16')/65536 for r in rr[:40]])
    cl = st.mean([g(r,'livelihood_coverage_q16')/65536 for r in rr[-40:]])
    sf = st.mean([g(r,'satisfaction_q16')/65536 for r in rr[:40]])
    sl = st.mean([g(r,'satisfaction_q16')/65536 for r in rr[-40:]])
    print('%-14s %6d %6d %8.2f %8.2f %14.0f %14.0f %12.3f %12.3f %10.3f %10.3f' % (
        ('%.0f'%s), rr[0][ix['profession_id']] and int(float(rr[0][ix['profession_id']])) or 0,
        int(float(rr[0][ix['is_merchant']])), pf, pl, ff, fl, cf, cl, sf, sl))

# worst need distribution late
from collections import Counter
c = Counter(int(float(r[ix['worst_need_id']])) for r in rows[-250:])
print('\nworst_need_id late (last 50 days):', c.most_common())
c2 = Counter(int(float(r[ix['worst_need_id']])) for r in rows[:250])
print('worst_need_id early:', c2.most_common())

# satisfaction / coverage raw ranges
sat = [g(r,'satisfaction_q16') for r in rows]
cov = [g(r,'livelihood_coverage_q16') for r in rows]
print('\nsatisfaction_q16 min/max', min(sat), max(sat), ' unique>0?', len(set(sat)))
print('livelihood_coverage_q16 min/max', min(cov), max(cov))
