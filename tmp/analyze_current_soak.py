import csv,json,re,sys,statistics,pathlib,math
def stats(v):
    v=sorted(v)
    if not v:return {}
    return dict(n=len(v),avg=round(statistics.mean(v),4),median=round(statistics.median(v),4),p95=round(v[math.ceil(len(v)*.95)-1],4),p99=round(v[math.ceil(len(v)*.99)-1],4),max=round(v[-1],4))
for arg in sys.argv[1:]:
    p=pathlib.Path(arg); s=json.loads((p/'session.json').read_text(encoding='utf-8-sig'))
    frames=list(csv.DictReader((p/'frame_samples.csv').open(encoding='utf-8-sig')))
    perf=list(csv.DictReader((p/'perf.csv').open(encoding='utf-8-sig')))
    out={'session':{k:s.get(k) for k in ['state','native_days_per_second','native_committed_days','max_observed_commit_gap_ms','health_errors','auto_pod_active']},'frames':len(frames),'perf_rows':len(perf)}
    out['frame_stats']={k:stats([float(r[k]) for r in frames if r.get(k)]) for k in ['frame_wall_ms','last_fast_tick_ms','writeback_lag_days','climate_pod_plan_ms']}
    out['perf_stats']={k:stats([float(r[k]) for r in perf if r.get(k)]) for k in ['fast_ms','clock_full_ms','runtime_graph_visual_apply_ms','runtime_graph_country_territory_sync_ms','runtime_graph_event_dispatch_ms']}
    out['long_frames']=[{k:r[k] for k in ['frame_idx','timestamp_ms','frame_wall_ms','clock_day','completed_days','writeback_lag_days']} for r in frames if float(r['frame_wall_ms'])>100]
    logs=p.with_suffix('.log').read_text(encoding='utf-8-sig',errors='replace')
    costs={}
    start=int(s['runtime_report_record_start']['completed_days'])
    for line in logs.splitlines():
        if re.match(r'\[(economy-boundary-cost|economy-prelude-cost|runtime-day-cost|economy-open-finish)\]',line):
            vals=dict(re.findall(r'(\w+)=([\d.]+)',line))
            if int(vals.get('day',0))<=start:continue
            tag=line.split(']')[0][1:]
            for k,v in vals.items():
                if k not in ['day','ok','pending']:costs.setdefault(tag+'.'+k,[]).append(float(v))
    out['sampled_costs']={k:stats(v) for k,v in costs.items()}
    out['stage_ms_final_snapshot']=s['runtime_report_end']['economy_replay_stage_ms']
    (p/'analysis.json').write_text(json.dumps(out,indent=2),encoding='utf-8')
    print(p, json.dumps(out,indent=2))
