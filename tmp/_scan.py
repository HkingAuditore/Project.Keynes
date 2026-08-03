import csv, sys, io, json, collections
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
p = r'tmp\perf_record_20260803_164328.csv'
rows = list(csv.DictReader(open(p, encoding='utf-8-sig', newline='')))
n = len(rows)
def fl(v):
    try: return float(v)
    except Exception: return 0.0

# Counters are cumulative; use the last-minus-first delta over the run.
def delta(c):
    vals = [fl(x.get(c, '')) for x in rows if x.get(c, '') != '']
    return (vals[-1] - vals[0]) / max(1, len(vals) - 1) if len(vals) > 1 else 0.0

stage_wall = collections.Counter()
for x in rows:
    s = x.get('continuation_stage_wall_ms', '')
    if s:
        for k, v in json.loads(s).items(): stage_wall[k] += float(v)
stage_wall = {k: v/n for k, v in stage_wall.items()}

STAGES = ['person_commit', 'family_commit', 'building_commit', 'household_market',
          'building_production', 'building_employment', 'aggregate_publish',
          'building_plan', 'ledger_apply', 'epoch_begin', 'trade_planning',
          'structural_commit']

print('每天：阶段耗时 vs 该阶段内的线性查表步数')
print('%-24s %10s %14s %12s %10s' % ('stage', 'ms/day', 'scan steps/day', 'est ms*', 'lookup%'))
tot_ms = tot_scan = 0.0
NS = 1.1e-6   # ms per scan step, calibrated below
out = []
for s in STAGES:
    ms = stage_wall.get('economy:' + s, 0.0)
    steps = delta('bd_economy_scan_steps_stage_' + s)
    out.append((ms, steps, s))
    tot_ms += ms; tot_scan += steps
out.sort(reverse=True)
for ms, steps, s in out:
    est = steps * NS
    share = (est / ms * 100) if ms > 0.01 else 0
    print('%-24s %10.2f %14s %12.2f %9.0f%%' % (s, ms, format(int(steps), ','), est,
                                                min(share, 999)))
print('%-24s %10.2f %14s %12.2f' % ('TOTAL', tot_ms, format(int(tot_scan), ','),
                                    tot_scan * NS))

print('\n各线性查表函数每天的扫描步数与调用次数')
for c, label in [('scan_steps_find_building_group', 'find_building_group'),
                 ('scan_steps_find_signature', 'find_cohort_slot/find_signature'),
                 ('scan_steps_membership_fallback', 'family_membership_index 回退'),
                 ('scan_steps_person_linear', 'promote/move 人物全扫'),
                 ('scan_steps_family_linear', 'create_family 姓氏去重全扫')]:
    steps = delta('bd_economy_' + c)
    calls = delta('bd_economy_' + c.replace('steps', 'calls'))
    per = (steps / calls) if calls > 0 else 0
    print('  %-34s steps=%14s  calls=%12s  steps/call=%9.0f' % (
        label, format(int(steps), ','), format(int(calls), ',') if calls else '-', per))

print('\n规模')
for c in ['building_group_count', 'cohort_count', 'notable_person_count',
          'family_count', 'family_membership_edge_count', 'market_count']:
    print('  %-32s %s' % (c, rows[-1].get('bd_economy_' + c)))
