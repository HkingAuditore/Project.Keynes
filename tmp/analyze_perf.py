import csv, sys, json, statistics as st
csv.field_size_limit(sys.maxsize)

FRAME = ['fps','fast_ms','t_sus_ms','t_render_ms','t_ui_ms']
JOBS = ['j_season_refresh_ms','j_natural_resource_daily_ms','j_enum_atlas_upload_ms',
        'j_ocean_currents_ms','j_native_daily_sim_ms','j_dynamic_visual_atlas_upload_ms']
TOTALS = {'climate':'bd_climate_total_ms','weather':'bd_weather_total_ms'}
EXTRA = ['bd_sea_ice_atlas_elapsed_ms','bd_dynamic_visual_atlas_elapsed_ms','bd_enum_atlas_elapsed_ms']
CLIM_SUB = ['bd_climate_native_context_ms','bd_climate_season_ms','bd_climate_climate_ms',
 'bd_climate_weather_ms','bd_climate_hydrology_ms','bd_climate_ocean_ms','bd_climate_stage_b_ms',
 'bd_climate_render_prepare_ms','bd_climate_pass_a_ms','bd_climate_compute_ms','bd_climate_refresh_ms',
 'bd_climate_flush_ms','bd_climate_bundle_ms','bd_climate_advance_ms','bd_climate_field_commit_total_ms',
 'bd_climate_distribute_ms','bd_climate_summary_ms','bd_climate_cyclone_ms','bd_climate_wind_ms',
 'bd_climate_transp_ms','bd_climate_sea_ice_ms','bd_climate_finalizer_total_ms','bd_climate_round_bundle_ms']
WEA_SUB = ['bd_weather_native_context_ms','bd_weather_season_ms','bd_weather_climate_ms',
 'bd_weather_weather_ms','bd_weather_hydrology_ms','bd_weather_ocean_ms','bd_weather_stage_b_ms',
 'bd_weather_render_prepare_ms','bd_weather_pass_a_ms','bd_weather_compute_ms','bd_weather_refresh_ms',
 'bd_weather_flush_ms','bd_weather_bundle_ms','bd_weather_advance_ms','bd_weather_field_commit_total_ms',
 'bd_weather_distribute_ms','bd_weather_summary_ms','bd_weather_cyclone_ms','bd_weather_wind_ms',
 'bd_weather_transp_ms','bd_weather_sea_ice_ms']

def is_num(s):
    try:
        float(s); return True
    except Exception:
        return False

with open('perf_record_20260707_202818.csv', newline='', encoding='utf-8-sig') as f:
    r = csv.reader(f)
    header = next(r)
    idx = {h:i for i,h in enumerate(header)}
    def col(name): return idx[name]

    n=0
    frame_vals={c:[] for c in FRAME}
    job_vals={c:[] for c in JOBS}
    total_vals={c:[] for c in TOTALS.values()}
    extra_vals={c:[] for c in EXTRA}
    clim_vals={c:[] for c in CLIM_SUB}
    wea_vals={c:[] for c in WEA_SUB}
    sim_budget=[]; sus_p95_300=[]; sus_avg_300=[]; over1=[]; fast=[]
    ls_job={}; ls_stage={}
    for row in r:
        n+=1
        for c in FRAME:
            v=row[col(c)]
            if is_num(v): frame_vals[c].append(float(v))
        for c in JOBS:
            v=row[col(c)]
            if is_num(v): job_vals[c].append(float(v))
        for c in TOTALS.values():
            v=row[col(c)]
            if is_num(v): total_vals[c].append(float(v))
        for c in EXTRA:
            v=row[col(c)]
            if is_num(v): extra_vals[c].append(float(v))
        for c in CLIM_SUB:
            v=row[col(c)]
            if is_num(v): clim_vals[c].append(float(v))
        for c in WEA_SUB:
            v=row[col(c)]
            if is_num(v): wea_vals[c].append(float(v))
        b=row[col('sim_frame_budget_ms')]
        if is_num(b): sim_budget.append(float(b))
        p=row[col('sus_sim_p95_300')]
        if is_num(p): sus_p95_300.append(float(p))
        a=row[col('sus_sim_avg_300')]
        if is_num(a): sus_avg_300.append(float(a))
        o=row[col('over_1ms_count_300')]
        if is_num(o): over1.append(float(o))
        fm=row[col('fast_ms')]
        if is_num(fm): fast.append(float(fm))
        lj=row[col('largest_slice_job')]
        ls_job[lj]=ls_job.get(lj,0)+1
        lstg=row[col('largest_slice_stage')]
        ls_stage[lstg]=ls_stage.get(lstg,0)+1

def stats(vals):
    vals=[v for v in vals if v is not None]
    if not vals: return None
    s=sorted(vals)
    return dict(n=len(s), mean=round(st.mean(s),4), median=round(st.median(s),4),
               p95=round(s[min(len(s)-1,int(len(s)*0.95))],4), max=round(max(s),4),
               sum=round(sum(s),2), nonzero=sum(1 for v in s if v>0))

out={}
out['n_rows']=n
out['frame']={c:stats(frame_vals[c]) for c in FRAME}
out['jobs']={c:stats(job_vals[c]) for c in JOBS}
out['totals']={k:stats(total_vals[v]) for k,v in TOTALS.items()}
out['extra']={c:stats(extra_vals[c]) for c in EXTRA}
out['climate_sub']={c:stats(clim_vals[c]) for c in CLIM_SUB}
out['weather_sub']={c:stats(wea_vals[c]) for c in WEA_SUB}
out['sim_budget_mean']=round(st.mean(sim_budget),3) if sim_budget else None
out['sus_p95_300_mean']=round(st.mean(sus_p95_300),3) if sus_p95_300 else None
out['sus_avg_300_mean']=round(st.mean(sus_avg_300),3) if sus_avg_300 else None
out['over1_mean']=round(st.mean(over1),3) if over1 else None
out['fast_mean']=round(st.mean(fast),3) if fast else None
out['ls_job']=ls_job
out['ls_stage']=ls_stage
fb=st.mean(sim_budget) if sim_budget else 8
exc=sum(1 for v in frame_vals['t_sus_ms'] if v>fb)
out['t_sus_over_budget_count']=exc
out['t_sus_over_budget_pct']=round(100*exc/len(frame_vals['t_sus_ms']),1) if frame_vals['t_sus_ms'] else None

with open('D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_analysis.json','w') as g:
    json.dump(out,g,indent=2)
print("rows:",n,"frame budget mean:",fb)
print("t_sus over budget:",exc,"/",len(frame_vals['t_sus_ms']),"=",out['t_sus_over_budget_pct'],"%")
print("SIM p95_300 mean:",out['sus_p95_300_mean'],"avg_300 mean:",out['sus_avg_300_mean'],"over1 mean:",out['over1_mean'],"fast mean:",out['fast_mean'])
print("LARGEST SLICE JOB:", json.dumps(ls_job))
print("LARGEST SLICE STAGE:", json.dumps(ls_stage))
print("\nFRAME:", json.dumps(out['frame'],indent=2))
print("\nJOBS:", json.dumps(out['jobs'],indent=2))
print("\nTOTALS:", json.dumps(out['totals'],indent=2))
print("\nEXTRA:", json.dumps(out['extra'],indent=2))

# job share of total sim time
tsus = out['frame']['t_sus_ms']['sum']
print("\nJOB SHARE OF t_sus total (%.1f ms):" % tsus)
for c,s in out['jobs'].items():
    print("  %-34s sum=%8.1f  share=%5.1f%%" % (c, s['sum'], 100*s['sum']/tsus))

print("\nCLIMATE SUB (sorted by sum):")
for c,s in sorted(out['climate_sub'].items(), key=lambda kv: -(kv[1]['sum'] if kv[1] else 0)):
    if s: print("  %-40s mean=%7.4f p95=%7.4f max=%7.4f sum=%8.1f nz=%d" % (c,s['mean'],s['p95'],s['max'],s['sum'],s['nonzero']))
print("\nWEATHER SUB (sorted by sum):")
for c,s in sorted(out['weather_sub'].items(), key=lambda kv: -(kv[1]['sum'] if kv[1] else 0)):
    if s: print("  %-40s mean=%7.4f p95=%7.4f max=%7.4f sum=%8.1f nz=%d" % (c,s['mean'],s['p95'],s['max'],s['sum'],s['nonzero']))

