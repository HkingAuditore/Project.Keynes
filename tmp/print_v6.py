import json
d = json.load(open(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/analysis_output/analysis_v6_20260612_130635.json', encoding='utf-8'))

print('=== weather_run_length (天气停留段长度，单位 tick) ===')
for k, v in sorted(d['weather_run_length'].items()):
    print(f"  {k}: samples={v['samples']:>5}, mean={v['mean']:6.2f}, median={v['median']:5.1f}, p25={v['p25']:5.1f}, p75={v['p75']:5.1f}, p99={v['p99']:6.1f}, max={v['max']}")

print()
print('=== weather_geo: 天气类型分布（按纬度带×水陆） ===')
print(f"{'band':>10} {'water':>5} {'n':>7}  type_dist")
for x in d['weather_geo']:
    print(f"  {x['lat_band']:>10} {x['is_water']:>3}  {x['n']:>6}  " + ", ".join(f"{k}:{v:.2f}" for k, v in x['dist'].items()))

print()
print('=== temp_continuity_geo: 温度逐tick差分按纬度×水陆 ===')
print(f"{'band':>10} {'water':>5} {'n':>7} {'mean':>8} {'max':>8} {'l1%':>7} {'l2%':>7} {'pp%':>7} {'ppS%':>7}")
for x in d['temp_continuity_geo']:
    print(f"  {x['lat_band']:>10} {x['is_water']:>3}  {x['samples']:>6} {x['mean_abs_delta']:>8.4f} {x['max_abs_delta']:>8.4f} {x['jump_l1_ratio']*100:>7.2f} {x['jump_l2_ratio']*100:>7.2f} {x['pp_ratio']*100:>7.2f} {x['pp_strong_ratio']*100:>7.2f}")

print()
print('=== ping-pong 示例 (前 12 个) ===')
for ex in d['temp_continuity_examples'][:12]:
    print(f"  cell={ex['cell']:>4}, lat={ex['lat']:.2f}, water={ex['is_water']}, ticks={ex['ticks']}, "
          f"temps={[round(t,4) for t in ex['temps']]}, d1={ex['d1']:+.4f}, d2={ex['d2']:+.4f}")
