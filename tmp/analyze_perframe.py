import csv, sys, json, statistics as st
csv.field_size_limit(sys.maxsize)

COLS = ['tick_idx','t_sus_ms','t_render_ms','t_ui_ms','fast_ms','fps',
        'j_season_refresh_ms','j_natural_resource_daily_ms','j_enum_atlas_upload_ms',
        'j_ocean_currents_ms','j_native_daily_sim_ms','j_dynamic_visual_atlas_upload_ms',
        'largest_slice_job','largest_slice_ms','sim_frame_budget_ms',
        'over_1ms_count_300','sus_sim_p95_300','sus_sim_avg_300']
JOBKEYS = ['j_season_refresh_ms','j_natural_resource_daily_ms','j_enum_atlas_upload_ms',
           'j_ocean_currents_ms','j_native_daily_sim_ms','j_dynamic_visual_atlas_upload_ms']

def is_num(s):
    try: float(s); return True
    except Exception: return False

rows=[]
with open('perf_record_20260707_202818.csv', newline='', encoding='utf-8-sig') as f:
    r=csv.reader(f); header=next(r); idx={h:i for i,h in enumerate(header)}
    for row in r:
        d={}
        ok=True
        for c in COLS:
            v=row[idx[c]]
            if is_num(v): d[c]=float(v)
            else: d[c]=0.0
        rows.append(d)

n=len(rows)
budget=st.mean([d['sim_frame_budget_ms'] for d in rows]) if rows else 8

# per-frame stacked layers
layers=[]
for d in rows:
    s=sum(d[k] for k in JOBKEYS)
    rem=max(0.0, d['t_sus_ms']-s)
    layers.append({
        'tick':int(d['tick_idx']),
        'sus':d['t_sus_ms'],'render':d['t_render_ms'],'ui':d['t_ui_ms'],'fast':d['fast_ms'],
        'native':d['j_native_daily_sim_ms'],'ocean':d['j_ocean_currents_ms'],
        'natres':d['j_natural_resource_daily_ms'],'dynatlas':d['j_dynamic_visual_atlas_upload_ms'],
        'enumatlas':d['j_enum_atlas_upload_ms'],'season':d['j_season_refresh_ms'],
        'rem':rem,'lslice':d['largest_slice_job'],'lslice_ms':d['largest_slice_ms'],
        'over1':d['over_1ms_count_300'],'p95_300':d['sus_sim_p95_300']})

def pct(vals,p):
    s=sorted(vals); 
    if not s: return 0
    return s[min(len(s)-1,int(len(s)*p))]

# per-job percentile table
jobtab=[]
for k in JOBKEYS:
    vals=[d[k] for d in rows]
    jobtab.append((k.replace('j_','').replace('_ms',''),
        min(vals), st.mean(vals), st.median(vals), pct(vals,0.9), pct(vals,0.95), max(vals),
        sum(1 for v in vals if v>0)))

# worst frames by t_sus
worst=sorted(layers,key=lambda x:-x['sus'])[:14]

# frame where each frame's dominant cost
def dom(d):
    parts={'native_daily_sim':d['native'],'ocean_currents':d['ocean'],'natural_resource':d['natres'],
           'dyn_atlas':d['dynatlas'],'enum_atlas':d['enumatlas'],'season':d['season'],'other':d['rem']}
    return max(parts,key=parts.get)
domcount={}
for d in layers:
    kk=dom(d); domcount[kk]=domcount.get(kk,0)+1

# average composition per frame
avg={k:st.mean([d[k] for d in layers]) for k in ['native','ocean','natres','dynatlas','enumatlas','season','rem','sus','render','ui']}

out={'n':n,'budget':budget,'layers':layers,'jobtab':jobtab,'worst':worst,
     'domcount':domcount,'avg':avg,
     'sus_mean':st.mean([d['sus'] for d in layers]),
     'sus_p95':pct([d['sus'] for d in layers],0.95),
     'sus_max':max(d['sus'] for d in layers),
     'over_budget':sum(1 for d in layers if d['sus']>budget)}
with open('D:/Godot/ProjectKeynes/Project.Keynes/tmp/perframe.json','w') as g:
    json.dump(out,g)
print("frames:",n,"budget:",budget)
print("sus mean/p95/max:",out['sus_mean'],out['sus_p95'],out['sus_max'],"over:",out['over_budget'])
print("avg composition (ms/frame):",{k:round(v,3) for k,v in avg.items()})
print("dominant-cost frame counts:",domcount)
print("JOB percentiles:")
for j in jobtab:
    print("  %-22s min=%.3f mean=%.3f p50=%.3f p90=%.3f p95=%.3f max=%.3f nz=%d"%(j[0],j[1],j[2],j[3],j[4],j[5],j[6],j[7]))
