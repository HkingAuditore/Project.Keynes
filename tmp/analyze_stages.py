import csv, sys, json
from collections import Counter, defaultdict
csv.field_size_limit(sys.maxsize)
path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\perf_record_20260707_202818.csv"

def is_num(s):
    try:
        float(s); return True
    except: return False

with open(path, newline='', encoding='utf-8-sig') as f:
    r = csv.reader(f)
    header = next(r)
    idx = {h:i for i,h in enumerate(header)}
    def col(name): return idx.get(name, -1)

    nd_stage = Counter(); nd_sub = Counter(); nd_path = Counter()
    oc_stage = Counter(); oc_sub = Counter(); oc_path = Counter()
    nd_ms_stage = defaultdict(list); oc_ms_stage = defaultdict(list)
    bd = {}
    bd_cols = ['bd_climate_ocean_ms','bd_climate_ocean_water_ms','bd_climate_ocean_land_ms',
               'bd_climate_wind_air_ms','bd_climate_wind_ms','bd_climate_wind_surface_ms','bd_climate_stage_b_ms']
    bd_vals = {c:[] for c in bd_cols}
    nd_round_slice = []
    nd_ready = Counter()
    nrows=0
    nd_ms_all=[]; oc_ms_all=[]
    for row in r:
        nrows+=1
        def get(c):
            i=col(c)
            return row[i] if i>=0 and i<len(row) else ""
        ns=get('j_native_daily_sim_stage'); nd_stage[ns]+=1
        nsub=get('j_native_daily_sim_substage'); nd_sub[nsub]+=1
        npa=get('j_native_daily_sim_path'); nd_path[npa]+=1
        os_=get('j_ocean_currents_stage'); oc_stage[os_]+=1
        osub=get('j_ocean_currents_substage'); oc_sub[osub]+=1
        opa=get('j_ocean_currents_path'); oc_path[opa]+=1
        # ms by stage
        i=col('j_native_daily_sim_ms'); v=row[i] if i>=0 and i<len(row) else ""
        if is_num(v): nd_ms_all.append(float(v))
        ii=col('j_native_daily_sim_stage')
        if is_num(v): nd_ms_stage[ns].append(float(v))
        i=col('j_ocean_currents_ms'); v2=row[i] if i>=0 and i<len(row) else ""
        if is_num(v2): oc_ms_all.append(float(v2))
        if is_num(v2): oc_ms_stage[os_].append(float(v2))
        for c in bd_cols:
            ci=col(c); val=row[ci] if ci>=0 and ci<len(row) else ""
            if is_num(val): bd_vals[c].append(float(val))
        rsc=get('bd_climate_round_slice_count')
        if is_num(rsc): nd_round_slice.append(float(rsc))
        nd_ready[get('bd_climate_native_daily_active_default_ready')]+=1

import statistics as st
def pct(vals, p):
    if not vals: return None
    s=sorted(vals); k=int(min(len(s)-1, len(s)*p)); return round(s[k],3)
def summ(vals):
    if not vals: return None
    return dict(mean=round(st.mean(vals),3), p95=pct(vals,0.95), max=round(max(vals),3), n=len(vals))

out={}
out['nrows']=nrows
out['native_daily_stage_counts']=dict(nd_stage.most_common())
out['native_daily_substage_counts']=dict(nd_sub.most_common(20))
out['native_daily_path_counts']=dict(nd_path.most_common())
out['native_daily_ms_by_stage']={k:summ(v) for k,v in nd_ms_stage.items() if v}
out['ocean_stage_counts']=dict(oc_stage.most_common())
out['ocean_substage_counts']=dict(oc_sub.most_common(20))
out['ocean_path_counts']=dict(oc_path.most_common())
out['ocean_ms_by_stage']={k:summ(v) for k,v in oc_ms_stage.items() if v}
out['bd_climate_node_ms']={c.replace('bd_climate_','').replace('_ms',''):summ(v) for c,v in bd_vals.items() if v}
out['native_daily_ms_total']=summ(nd_ms_all)
out['ocean_ms_total']=summ(oc_ms_all)
out['native_daily_round_slice_count']=summ(nd_round_slice)
out['native_daily_active_ready']=dict(nd_ready)

with open(r'D:\Godot\ProjectKeynes\Project.Keynes\tmp\stage_analysis.json','w') as g:
    json.dump(out,g,indent=2)

print("=== native_daily_sim stage counts (top) ===")
for k,v in nd_stage.most_common(15): print(f"  {k!r}: {v}")
print("=== native_daily_sim ms by stage ===")
for k,v in sorted(out['native_daily_ms_by_stage'].items(), key=lambda x:-x[1]['mean']):
    print(f"  {k}: mean={v['mean']} p95={v['p95']} max={v['max']} n={v['n']}")
print("=== ocean_currents stage counts (top) ===")
for k,v in oc_stage.most_common(15): print(f"  {k!r}: {v}")
print("=== ocean_currents ms by stage ===")
for k,v in sorted(out['ocean_ms_by_stage'].items(), key=lambda x:-x[1]['mean']):
    print(f"  {k}: mean={v['mean']} p95={v['p95']} max={v['max']} n={v['n']}")
print("=== native daily graph node ms (bd_climate_*) ===")
for k,v in sorted(out['bd_climate_node_ms'].items(), key=lambda x:-x[1]['mean']):
    print(f"  {k}: mean={v['mean']} p95={v['p95']} max={v['max']} n={v['n']}")
print("=== native_daily_active_ready ===", out['native_daily_active_ready'])
print("=== round_slice_count ===", out['native_daily_round_slice_count'])
