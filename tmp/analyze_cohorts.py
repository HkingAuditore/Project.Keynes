import pandas as pd, numpy as np
pd.set_option('display.width',240); pd.set_option('display.max_columns',60)
B="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260721_104404_v8_cell1104_q15_r18_"
Q=65536.0
PROF={2:'artisan工匠',8:'fisher渔民',9:'forager采集者',12:'hunter猎人',20:'merchant商人',22:'miner矿工',31:'unemployed失业'}
c=pd.read_csv(B+"cohorts.csv"); c.columns=[x.lstrip('\ufeff') for x in c.columns]
c['prof']=c.profession_id.map(PROF).fillna(c.profession_id.astype(str))
c['sat']=c.satisfaction_q16/Q
c['funds_pp']=c.funds/c.population.replace(0,np.nan)
c['inc_pp']=c.epoch_income/c.population.replace(0,np.nan)
c['exp_pp']=c.epoch_expense/c.population.replace(0,np.nan)
c['inkind_pp']=c.epoch_in_kind_income/c.population.replace(0,np.nan)
c['livcov']=c.livelihood_coverage_q16/Q
c['cashcov']=c.cash_expense_coverage_q16/Q

days=sorted(c.day_index.unique())
last=days[-1]; first=days[0]; mid=days[len(days)//2]

print("=== PER-PROFESSION at LAST day",last,"(non-merchant cohorts aggregated) ===")
def snap(day):
    d=c[c.day_index==day]
    g=d.groupby('prof').agg(pop=('population','sum'),funds=('funds','sum'),
        inc=('epoch_income','sum'),exp=('epoch_expense','sum'),inkind=('epoch_in_kind_income','sum'),
        sat=('sat','mean'),livcov=('livcov','mean'),cashcov=('cashcov','mean'),n=('cohort_index','count'))
    g['funds_pp']=g.funds/g['pop']
    g['inc_pp']=g.inc/g['pop']
    g['exp_pp']=g.exp/g['pop']
    g['inkind_pp']=g.inkind/g['pop']
    g['net_pp']=(g.inc+g.inkind-g.exp)/g['pop']
    return g
gl=snap(last)
print(gl[['pop','n','funds_pp','inc_pp','inkind_pp','exp_pp','net_pp','sat','livcov','cashcov']].round(1).to_string())

print("\n=== SAME at FIRST day",first,"===")
gf=snap(first)
print(gf[['pop','funds_pp','inc_pp','exp_pp','sat']].round(1).to_string())

print("\n=== FUNDS-PER-PERSON trajectory by profession (sampled days) ===")
sample=[first,days[len(days)//5],days[2*len(days)//5],mid,days[3*len(days)//5],days[4*len(days)//5],last]
rows=[]
for day in sample:
    g=snap(day); r={'day':day}
    for p in g.index: r[p]=round(g.loc[p,'funds_pp'],0)
    rows.append(r)
print(pd.DataFrame(rows).set_index('day').to_string())

print("\n=== POPULATION trajectory by profession ===")
rows=[]
for day in sample:
    g=snap(day); r={'day':day}
    for p in g.index: r[p]=int(g.loc[p,'pop'])
    rows.append(r)
print(pd.DataFrame(rows).set_index('day').to_string())

print("\n=== SATISFACTION trajectory ===")
rows=[]
for day in sample:
    g=snap(day); r={'day':day}
    for p in g.index: r[p]=round(g.loc[p,'sat'],3)
    rows.append(r)
print(pd.DataFrame(rows).set_index('day').to_string())

# worst need per profession at last day
print("\n=== worst_need_id distribution at last day (non-merchant) ===")
d=c[(c.day_index==last)]
print(d.groupby(['prof','worst_need_id']).population.sum().to_string())
