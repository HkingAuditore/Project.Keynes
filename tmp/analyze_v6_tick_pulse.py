#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v6 专项二：节拍/同步 检测
  - 温度逐 tick 全局平均、|Δ| 全局平均、|Δ|>阈值 cell 数随 tick 的曲线
  - 看是否在某些固定 tick 上突然“全场跳变”（说明是全局节拍）
  - 同时输出降水的逐 tick 全局均值，看刷新节拍
"""
import pandas as pd, numpy as np, os, json, time

CSV = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260612_130635.csv'
OUT = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/analysis_output/analysis_v6_tick_pulse.json'
USECOLS = ['tick_idx','cell_index','temp_arr','temp_arr_prev',
           'weather_precip_arr','weather_type_arr','weather_prev_type_arr']

t0 = time.time()
# 全局：每个 tick 的统计
tick_stat = {}  # tick -> dict(temp_sum, temp_n, abs_d_sum, abs_d_n, cnt_l1, cnt_l2, cnt_l3, precip_sum,
               #              type_changed_count, max_abs_d)

for ci, chunk in enumerate(pd.read_csv(CSV, usecols=USECOLS, chunksize=400000)):
    ticks = chunk['tick_idx'].astype(int).values
    temp = chunk['temp_arr'].astype(float).values
    temp_p = chunk['temp_arr_prev'].astype(float).values
    p = chunk['weather_precip_arr'].astype(float).values
    tt = chunk['weather_type_arr'].astype(int).values
    pp = chunk['weather_prev_type_arr'].astype(int).values
    d = np.abs(temp - temp_p)
    tc = (tt != pp).astype(int)

    df = pd.DataFrame({
        'tick': ticks, 'temp': temp, 'd': d, 'p': p, 'tc': tc,
        'l1': (d > 0.05).astype(int), 'l2': (d > 0.10).astype(int), 'l3': (d > 0.20).astype(int),
    })
    g = df.groupby('tick').agg(
        temp_sum=('temp','sum'), temp_n=('temp','size'),
        abs_d_sum=('d','sum'), abs_d_max=('d','max'),
        precip_sum=('p','sum'),
        l1=('l1','sum'), l2=('l2','sum'), l3=('l3','sum'),
        type_changed=('tc','sum'),
    ).reset_index()
    for _, r in g.iterrows():
        tk = int(r['tick'])
        d0 = tick_stat.setdefault(tk, {'temp_sum':0.0,'n':0,'abs_d_sum':0.0,'abs_d_max':0.0,
                                       'precip_sum':0.0,'l1':0,'l2':0,'l3':0,'type_changed':0})
        d0['temp_sum'] += float(r['temp_sum']); d0['n'] += int(r['temp_n'])
        d0['abs_d_sum'] += float(r['abs_d_sum']); d0['abs_d_max'] = max(d0['abs_d_max'], float(r['abs_d_max']))
        d0['precip_sum'] += float(r['precip_sum'])
        d0['l1'] += int(r['l1']); d0['l2'] += int(r['l2']); d0['l3'] += int(r['l3'])
        d0['type_changed'] += int(r['type_changed'])

print(f'[*] aggregated {len(tick_stat)} ticks in {time.time()-t0:.1f}s')

# 整理为有序序列
ticks_sorted = sorted(tick_stat.keys())
out = {'ticks': []}
for tk in ticks_sorted:
    d0 = tick_stat[tk]
    n = d0['n']
    out['ticks'].append({
        'tick': tk,
        'mean_temp': d0['temp_sum']/n,
        'mean_abs_dT': d0['abs_d_sum']/n,
        'max_abs_dT': d0['abs_d_max'],
        'cells_jump_l1': d0['l1'],   # |dT|>0.05
        'cells_jump_l2': d0['l2'],   # |dT|>0.10
        'cells_jump_l3': d0['l3'],   # |dT|>0.20
        'mean_precip': d0['precip_sum']/n,
        'type_changed_cells': d0['type_changed'],
    })

# 找出 abs_dT 的"脉冲" tick
arr_d = np.array([x['mean_abs_dT'] for x in out['ticks']])
arr_t = np.array([x['tick'] for x in out['ticks']])
m, s = arr_d.mean(), arr_d.std()
spike_idx = np.where(arr_d > m + 2*s)[0]
out['spike_threshold'] = float(m + 2*s)
out['spike_ticks'] = [int(arr_t[i]) for i in spike_idx]
# 间隔分析
if len(spike_idx) >= 2:
    diffs = np.diff([arr_t[i] for i in spike_idx])
    out['spike_diff_stats'] = {
        'mean': float(diffs.mean()), 'min': int(diffs.min()),
        'max': int(diffs.max()), 'mode': int(np.bincount(diffs).argmax()) if (diffs>0).all() else None,
        'sample': diffs[:30].tolist(),
    }

# 降水脉冲 (变化的 tick)
pre = np.array([x['mean_precip'] for x in out['ticks']])
dp = np.abs(np.diff(pre))
m2, s2 = dp.mean(), dp.std()
ch_idx = np.where(dp > max(m2 + 2*s2, 1e-6))[0]
out['precip_change_ticks'] = [int(arr_t[i+1]) for i in ch_idx]
if len(ch_idx) >= 2:
    diffs = np.diff([arr_t[i+1] for i in ch_idx])
    out['precip_change_diff_stats'] = {
        'mean': float(diffs.mean()), 'min': int(diffs.min()), 'max': int(diffs.max()),
        'mode': int(np.bincount(diffs[diffs>0]).argmax()) if (diffs>0).any() else None,
        'sample': diffs[:30].tolist(),
    }

with open(OUT, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=2, default=float)
print(f'[OK] {OUT}')

# 简略打印
print('--- spike_ticks (mean |dT| > mean+2σ) 前 30 个 ---')
print(out['spike_ticks'][:30])
print('间隔统计:', out.get('spike_diff_stats'))
print('降水变更 tick 前 30:', out['precip_change_ticks'][:30])
print('降水变更间隔统计:', out.get('precip_change_diff_stats'))
print()
print('--- 头 30 ticks 的关键指标 ---')
print(f"{'tick':>5} {'meanT':>7} {'meandT':>7} {'maxdT':>7} {'l1':>5} {'l2':>5} {'l3':>5} {'precip':>7} {'tc':>5}")
for x in out['ticks'][:30]:
    print(f"{x['tick']:>5} {x['mean_temp']:>7.4f} {x['mean_abs_dT']:>7.4f} {x['max_abs_dT']:>7.4f} "
          f"{x['cells_jump_l1']:>5} {x['cells_jump_l2']:>5} {x['cells_jump_l3']:>5} "
          f"{x['mean_precip']:>7.4f} {x['type_changed_cells']:>5}")
