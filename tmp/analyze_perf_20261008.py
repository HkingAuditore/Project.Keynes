"""Counter deltas and per-day probe aggregation; nested probes overlap."""
import csv, statistics, collections, json
from pathlib import Path
rows = list(csv.DictReader(open('tmp/perf_record_20261008_181820.csv', encoding='utf-8-sig')))
a, b = rows[0], rows[-1]
days = int(b['runtime_graph_simulation_committed_day']) - int(a['runtime_graph_simulation_committed_day'])
seconds = (int(b['timestamp_ms']) - int(a['timestamp_ms'])) / 1000
phases = {k: (int(b['runtime_graph_worker_time_'+k+'_us']) - int(a['runtime_graph_worker_time_'+k+'_us'])) / 1e6 for k in ['execute','input_wait','clock_wait','boundary_wait','overhead','total']}
gaps = []
regular_seconds = regular_days = 0
for index, (left, right) in enumerate(zip(rows, rows[1:]), 1):
    span = (int(right['timestamp_ms']) - int(left['timestamp_ms'])) / 1000
    advanced = int(right['runtime_graph_simulation_committed_day']) - int(left['runtime_graph_simulation_committed_day'])
    if span > 1:
        gaps.append({'row':index, 'seconds':span, 'days':advanced})
    else:
        regular_seconds += span
        regular_days += advanced
def summary(values):
    ordered = sorted(values)
    return {'count':len(values), 'avg':statistics.mean(values), 'p95':ordered[int((len(ordered)-1)*.95)], 'max':max(values)}
cost = collections.defaultdict(lambda: collections.defaultdict(float))
for row in csv.DictReader(open('tmp/perf_20261008_cost_baseline.csv')):
    if int(row['day']) > 5 and row.get('ms'):
        cost[row['phase']][int(row['day'])] += float(row['ms'])
result = {
    'rows':len(rows), 'elapsed_seconds':seconds, 'committed_days':days,
    'end_to_end_days_per_second':days/seconds,
    'worker_counter_delta_seconds':phases,
    'unrecorded_phase_seconds':phases['total']-sum(v for k,v in phases.items() if k!='total'),
    'execute_ms_per_day':phases['execute']*1000/days,
    'execute_only_days_per_second':days/phases['execute'],
    'regular_intervals_days_per_second':regular_days/regular_seconds,
    'gaps_over_1_second':gaps,
    'timing_ms_excluding_first_row':{k:summary([float(r[k]) for r in rows[1:]]) for k in ['sched_day_capture_ms','sched_day_total_ms','frame_wall_ms','clock_full_ms','t_render_ms']},
    'new_game_cost_ms_per_day':{k:summary(list(v.values())) for k,v in cost.items()},
    'limitations':['Long intervals do not identify their cause.', 'New-game probes are a different state.', 'Nested probes overlap.', 'Headless benchmark failed row-count and throughput acceptance.'],
}
Path('tmp/perf_20261008_analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k not in ['new_game_cost_ms_per_day','gaps_over_1_second']},ensure_ascii=False,indent=2))
print('cost rank',sorted([(statistics.mean(v.values()),k) for k,v in cost.items()],reverse=True)[:15])
