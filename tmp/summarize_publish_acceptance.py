from pathlib import Path
import json,re,statistics,math
root=Path(__file__).resolve().parent
def stats(v):
    v=sorted(v)
    return {'n':len(v),'avg':statistics.mean(v),'median':statistics.median(v),'p95':v[math.ceil(.95*len(v))-1],'p99':v[math.ceil(.99*len(v))-1],'max':v[-1]} if v else {}
out={}
for name in ['codex_soak_60x40_default120','publish_optimized120']+[f'publish_final60_{i}' for i in range(1,6)]:
    path=root/name/'session.json'
    if not path.exists():continue
    s=json.loads(path.read_text(encoding='utf-8-sig'))
    if 'native_days_per_second' not in s:continue
    report=s['runtime_report_end']
    metrics={}
    for line in (root/(name+'.log')).read_text(encoding='utf-8-sig',errors='replace').splitlines():
        m=re.match(r'\[(economy-(?:aggregate|ledger|boundary)-cost|runtime-day-cost)\]',line)
        if not m:continue
        vals=dict(re.findall(r'(\w+)=([\d.]+)',line))
        if int(vals.get('day',0)) <= s['runtime_report_record_start']['completed_days']:continue
        for k,v in vals.items():
            if k.endswith('_ms') or k=='ms':metrics.setdefault(m[1]+'.'+k,[]).append(float(v))
    out[name]={k:s[k] for k in ['native_days_per_second','native_committed_days','max_observed_commit_gap_ms','health_errors']}
    out[name]['authority']={k:report.get(k) for k in ['worker_fault_count','domain_stage_fallback_count','economy_formula_backing','economy_production_writer_effective','authoritative_domain_mask','economy_authority_switch_count']}
    out[name]['metrics']={k:stats(v) for k,v in metrics.items()}
(root/'publish_acceptance_summary.json').write_text(json.dumps(out,indent=2),encoding='utf-8')
for name,data in out.items():
    print(name, 'rate=',round(data['native_days_per_second'],3),'gap=',data['max_observed_commit_gap_ms'],'faults=',data['authority']['worker_fault_count'])
    for k,v in data['metrics'].items():print(' ',k, 'avg/median/p95/max',*(round(v[x],3) for x in ['avg','median','p95','max']))
