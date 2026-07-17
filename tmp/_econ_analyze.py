import pandas as pd, numpy as np
pd.set_option('display.width', 220); pd.set_option('display.max_columns', 80); pd.set_option('display.max_rows', 200)
base = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260717_114418_v5_cell1031_q3_r17_"
S = pd.read_csv(base+"summary.csv"); B = pd.read_csv(base+"buildings.csv")
C = pd.read_csv(base+"cohorts.csv"); M = pd.read_csv(base+"market.csv"); R = pd.read_csv(base+"resources.csv")

print("############ 1. 就业/失业口径核对 ############")
# summary
d = S[['day_index','filled_owner_jobs','filled_employee_jobs','unemployed_population']].copy()
print("SUMMARY 首末:")
print(d.head(3).to_string(index=False)); print(d.tail(3).to_string(index=False))
# cohort 层面 - 用最后一个 epoch 与第一个 epoch
for tag,ep in [("首epoch",C.epoch_id.min()),("末epoch",C.epoch_id.max())]:
    c=C[C.epoch_id==ep]
    print(f"\n--- COHORT {tag}(epoch={ep}) ---")
    print(c[['profession_id','ethnicity_id','population','funds','is_merchant','owner_employed','employee_employed','unemployed','satisfaction_q16','worst_need_id']].to_string(index=False))
    print("  合计 pop=%d owner_emp=%d emp_emp=%d unemp=%d" % (c.population.sum(), c.owner_employed.sum(), c.employee_employed.sum(), c.unemployed.sum()))

print("\n############ 2. 人口/失业率 时间序列 (cohort聚合) ############")
g = C.groupby('day_index').agg(popn=('population','sum'), owner=('owner_employed','sum'),
    emp=('employee_employed','sum'), unemp=('unemployed','sum'), funds=('funds','sum')).reset_index()
g['emp_total']=g.owner+g.emp
g['unemp_rate']=(g.unemp/g.popn).round(4)
sel=g.iloc[::40].copy()
print(sel.to_string(index=False))
# summary 全局口径
sg=S[['day_index','filled_owner_jobs','filled_employee_jobs','unemployed_population']].copy()
sg['total']=sg.filled_owner_jobs+sg.filled_employee_jobs+sg.unemployed_population
print("\nSUMMARY全局就业口径(每40行):")
print(sg.iloc[::40].to_string(index=False))

print("\n############ 3. 建筑运营状态 (末epoch) ############")
be=B[B.epoch_id==B.epoch_id.max()]
cols=['type_id','count','owner_required','filled_owner','employee_required','employee_filled','wage_suspended','operating_state','last_input','last_output','last_sold','last_discarded','last_revenue','last_wages_paid','last_wages_due','realized_profit_margin_q16','planned_utilization_q16']
print(be[cols].to_string(index=False))
print("\n建筑 operating_state 分布(全时段):")
print(B.operating_state.value_counts())
