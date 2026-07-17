import pandas as pd, numpy as np
pd.set_option('display.width', 240); pd.set_option('display.max_columns', 60); pd.set_option('display.max_rows', 200)
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
c = pd.read_csv(base+"cohorts.csv")
MONEY=10000.0
days = sorted(c.day_index.unique()); first_d,last_d=days[0],days[-1]
def snap(day): return c[c.day_index==day]
f,l = snap(first_d), snap(last_d)

print("=== POP TRAJECTORY (cell 1031) ===")
traj = c.groupby('day_index').apply(lambda g: pd.Series({
    'pop':g.population.sum(),'owner_emp':g.owner_employed.sum(),'emp_emp':g.employee_employed.sum(),
    'unemp':g.unemployed.sum(),'funds':g.funds.sum(),'cohorts':len(g),
    'sat':(g.satisfaction_q16*g.population).sum()/max(1,g.population.sum())/65535,
    'income':g.epoch_income.sum(),'expense':g.epoch_expense.sum()}), include_groups=False).reset_index()
print(traj.iloc[::30].to_string())
print("last:",{k:round(v,2) for k,v in traj.iloc[-1].to_dict().items()})

def prof_tbl(df):
    g=df.groupby('profession_id').apply(lambda x: pd.Series({
        'pop':x.population.sum(),'cohorts':len(x),'funds':x.funds.sum(),
        'owner':x.owner_employed.sum(),'emp':x.employee_employed.sum(),'unemp':x.unemployed.sum(),
        'sat':(x.satisfaction_q16*x.population).sum()/max(1,x.population.sum())/65535,
        'inc':x.epoch_income.sum(),'exp':x.epoch_expense.sum()}), include_groups=False).reset_index()
    g['funds_pc']=(g.funds/g['pop'].replace(0,np.nan)/MONEY).round(0)
    return g.sort_values('pop',ascending=False)
print("\n=== BY PROFESSION (first day", first_d,") ===")
print(prof_tbl(f).to_string())
print("\n=== BY PROFESSION (last day", last_d,") ===")
print(prof_tbl(l).to_string())

print("\n=== worst_need distribution (last day) ===")
print(l.groupby('worst_need_id').population.sum().sort_values(ascending=False).to_string())
print("worst_need (first day):")
print(f.groupby('worst_need_id').population.sum().sort_values(ascending=False).to_string())

print("\n=== income vs expense (pop-weighted daily net per capita, cell) ===")
traj['net']=traj.income-traj.expense
print("first net=%.0f last net=%.0f"%(traj.net.iloc[0]/MONEY, traj.net.iloc[-1]/MONEY))
print("funds first=%.0f last=%.0f (%.1fx)"%(traj.funds.iloc[0]/MONEY,traj.funds.iloc[-1]/MONEY,traj.funds.iloc[-1]/traj.funds.iloc[0]))

# merchant
print("\n=== MERCHANT cohort (cell) ===")
mm=c[c.is_merchant==1]
if len(mm):
    mt=mm.groupby('day_index').apply(lambda g:pd.Series({'pop':g.population.sum(),'funds':g.funds.sum()}),include_groups=False).reset_index()
    print(mt.iloc[::60].to_string()); print("last:",mt.iloc[-1].to_dict())
    print("merchant funds share of cell last: %.1f%%"%(100*mt.funds.iloc[-1]/l.funds.sum()))
