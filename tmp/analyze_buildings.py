import pandas as pd, numpy as np
pd.set_option('display.width',260); pd.set_option('display.max_columns',80)
B="D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260721_104404_v8_cell1104_q15_r18_"
Q=65536.0
BT={30:'communal_hearth',65:'flint_quarry',67:'fresh_fishing',70:'gathering_ground',80:'weaving_shelter',91:'knapping_wksp',107:'merchant_post',204:'placer_gold',239:'hunting_camp',243:'surface_silver',252:'timber_collect'}
b=pd.read_csv(B+"buildings.csv"); b.columns=[x.lstrip('\ufeff') for x in b.columns]
b['bt']=b.type_id.map(BT).fillna(b.type_id.astype(str))
b['margin']=b.realized_profit_margin_q16/Q
days=sorted(b.day_index.unique()); last=days[-1]
# focus on operating (non-construction) buildings
op=b[b.is_construction==0]
print("=== BUILDINGS at LAST day",last," (non-construction) ===")
d=op[op.day_index==last]
agg=d.groupby('bt').agg(cnt=('count','sum'),grp=('group_index','count'),
   emp_req=('employee_required','sum'),emp_fill=('employee_filled','sum'),
   inp=('last_input','sum'),out=('last_output','sum'),sold=('last_sold','sum'),disc=('last_discarded','sum'),ret=('last_retained','sum'),
   resrc=('last_resource','sum'),resgen=('last_resource_generated','sum'),
   rev=('last_revenue','sum'),inpcost=('last_input_cost','sum'),wpaid=('last_wages_paid','sum'),wdue=('last_wages_due','sum'),
   margin=('margin','mean'),opstate=('operating_state','mean'))
agg['profit']=agg.rev-agg.inpcost-agg.wpaid
print(agg[['cnt','grp','emp_req','emp_fill','inp','out','sold','disc','resrc','resgen','rev','inpcost','wpaid','profit','margin','opstate']].round(2).to_string())

print("\n=== operating_state codes present ===")
print(op.operating_state.value_counts())
print("\n=== investment_rejection_reason codes (all rows) ===")
print(b.investment_rejection_reason.value_counts())

print("\n=== margin trajectory by building type (sampled) ===")
sample=[days[0],days[len(days)//4],days[len(days)//2],days[3*len(days)//4],last]
rows=[]
for day in sample:
    dd=op[op.day_index==day]; g=dd.groupby('bt').margin.mean(); r={'day':day}
    for k in g.index: r[k]=round(g[k],2)
    rows.append(r)
print(pd.DataFrame(rows).set_index('day').T.to_string())

print("\n=== wages paid/due & revenue per building type (last day) totals across sim life ===")
tot=op.groupby('bt').agg(rev=('last_revenue','sum'),wpaid=('last_wages_paid','sum'),wdue=('last_wages_due','sum'),inpcost=('last_input_cost','sum'),resrc=('last_resource','sum'),resgen=('last_resource_generated','sum'))
tot['wage_shortfall']=tot.wdue-tot.wpaid
print(tot.round(0).to_string())

print("\n=== construction / investment activity ===")
con=b[b.is_construction==1]
print("construction rows total:",len(con),"| distinct days with construction:",con.day_index.nunique())
if len(con): print(con.groupby('bt').agg(days=('day_index','nunique'),grp=('group_index','count')).to_string())
