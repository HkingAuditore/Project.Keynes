import pandas as pd, numpy as np
pd.set_option('display.width', 260); pd.set_option('display.max_columns', 70); pd.set_option('display.max_rows', 300)
base = "D:/Godot/ProjectKeynes/Project.Keynes/tmp/economy_record_20260717_114418_v5_cell1031_q3_r17_"
b = pd.read_csv(base+"buildings.csv")
MONEY=10000.0; GOODS=1000.0; Q16=65536.0
days=sorted(b.day_index.unique()); first_d,last_d=days[0],days[-1]
print("buildings rows/epoch:", len(b[b.day_index==first_d]), " type_ids:", sorted(b.type_id.unique()))

def snap(d): return b[b.day_index==d]
f,l=snap(first_d),snap(last_d)

# building groups by type, operating state
def btbl(df):
    g=df.groupby('type_id').apply(lambda x: pd.Series({
        'groups':len(x),'count':x['count'].sum(),
        'filled_owner':x.filled_owner.sum(),'owner_req':x.owner_required.sum(),
        'emp_filled':x.employee_filled.sum(),'emp_req':x.employee_required.sum(),
        'suspended':(x.operating_state!=0).sum(),
        'margin':(x.realized_profit_margin_q16/Q16).mean(),
        'util':(x.planned_utilization_q16/Q16).mean(),
        'rev':x.last_revenue.sum()/MONEY,'incost':x.last_input_cost.sum()/MONEY,
        'wages':x.last_wages_paid.sum()/MONEY,'output':x.last_output.sum()/GOODS,
        'sold':x.last_sold.sum()/GOODS,'input':x.last_input.sum()/GOODS,
        'resource':x.last_resource.sum()/GOODS,'res_gen':x.last_resource_generated.sum()/GOODS}),
        include_groups=False).reset_index()
    return g.sort_values('count',ascending=False)
print("\n=== BUILDINGS FIRST DAY (type_id) ===")
print(btbl(f).to_string())
print("\n=== BUILDINGS LAST DAY (type_id) ===")
print(btbl(l).to_string())

# operating state trajectory
print("\n=== operating_state over time (# suspended groups) ===")
ost=b.groupby('day_index').apply(lambda g: pd.Series({
    'total':len(g),'active':(g.operating_state==0).sum(),'suspended':(g.operating_state!=0).sum(),
    'avg_margin':(g.realized_profit_margin_q16/Q16).mean(),'avg_util':(g.planned_utilization_q16/Q16).mean(),
    'total_output':g.last_output.sum()/GOODS,'total_sold':g.last_sold.sum()/GOODS}),include_groups=False).reset_index()
print(ost.iloc[::40].to_string())
print("last:",{k:round(v,3) for k,v in ost.iloc[-1].to_dict().items()})

# which type suspended when? trace per type suspended count
print("\n=== suspended count by type over time ===")
susp=b[b.operating_state!=0].groupby(['day_index','type_id']).size().unstack(fill_value=0)
if len(susp): print(susp.iloc[::50].to_string())

# per-group detail last day: show each group
print("\n=== EACH GROUP LAST DAY ===")
cols=['group_index','type_id','count','filled_owner','owner_required','employee_filled','employee_required',
      'operating_state','severe_loss_cycles','realized_profit_margin_q16','planned_utilization_q16',
      'last_input','last_output','last_sold','last_discarded','last_revenue','last_input_cost','last_wages_paid','last_resource']
ll=l[cols].copy()
ll['margin']=(ll.realized_profit_margin_q16/Q16).round(3); ll['util']=(ll.planned_utilization_q16/Q16).round(3)
ll['rev']=(ll.last_revenue/MONEY).round(0); ll['incost']=(ll.last_input_cost/MONEY).round(0); ll['wage']=(ll.last_wages_paid/MONEY).round(0)
ll['out']=(ll.last_output/GOODS).round(2); ll['sold']=(ll.last_sold/GOODS).round(2); ll['inp']=(ll.last_input/GOODS).round(2)
print(ll[['group_index','type_id','count','filled_owner','owner_required','employee_filled','employee_required','operating_state','severe_loss_cycles','margin','util','inp','out','sold','rev','incost','wage']].to_string(index=False))
