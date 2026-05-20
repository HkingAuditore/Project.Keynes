import csv, statistics as st, sys

path = 'perf_record_20260520_140700.csv'
rows = list(csv.DictReader(open(path, encoding='utf-8')))
print('rows=', len(rows))

def f(c):
    out = []
    for r in rows:
        v = r.get(c, '')
        if v in ('', 'None', None):
            continue
        try:
            out.append(float(v))
        except Exception:
            pass
    return out

cols = [
    'fast_ms', 't_sus_ms', 't_render_ms', 't_ui_ms',
    'j_dynamic_visual_atlas_upload_ms',
    'j_refresh_climate_daily_ms',
    'j_weather_refresh_ms',
    'bd_dynamic_visual_atlas_elapsed_ms',
    'bd_dynamic_visual_atlas_dynamic_ms',
    'bd_dynamic_visual_atlas_ecology_ms',
    'bd_dynamic_visual_atlas_smooth_ms',
    'bd_dynamic_visual_atlas_ice_ms',
    'bd_dynamic_visual_atlas_mask_dirty_count',
    'bd_dynamic_visual_atlas_dynamic_dirty_cells',
    'bd_dynamic_visual_atlas_ecology_dirty_cells',
    'bd_dynamic_visual_atlas_smooth_dirty_cells',
    'bd_dynamic_visual_atlas_ice_dirty_cells',
    'bd_climate_pa_pushed_cells',
    'bd_climate_pa_total_cells',
    'bd_climate_pa_push_ratio',
    'bd_climate_total_ms',
]

def pct(v, p):
    if not v:
        return 0.0
    s = sorted(v)
    idx = int(len(s) * p)
    if idx >= len(s):
        idx = len(s) - 1
    return s[idx]

print('col,n,mean,p50,p95,p99,max')
for c in cols:
    v = f(c)
    if not v:
        print(f'{c},0,-,-,-,-,-')
        continue
    print(f'{c},{len(v)},{st.mean(v):.3f},{pct(v,0.5):.3f},{pct(v,0.95):.3f},{pct(v,0.99):.3f},{max(v):.3f}')

# 长帧分析：fast_ms top10
print('\n=== top10 longest fast_ms ticks ===')
indexed = []
for i, r in enumerate(rows):
    try:
        indexed.append((float(r['fast_ms']), i, r))
    except Exception:
        pass
indexed.sort(reverse=True)
print('rank,fast_ms,tick_idx,t_sus,t_render,j_dva_upload,bd_dva_elapsed,bd_dva_mask_dirty,bd_dva_dynamic_ms,bd_dva_ecology_ms,bd_dva_smooth_ms,largest_slice_path,largest_slice_ms,bd_climate_pa_push_ratio')
for rank, (fms, i, r) in enumerate(indexed[:10]):
    print(f"{rank+1},{fms:.2f},{r.get('tick_idx','')},{r.get('t_sus_ms','')},{r.get('t_render_ms','')},{r.get('j_dynamic_visual_atlas_upload_ms','')},{r.get('bd_dynamic_visual_atlas_elapsed_ms','')},{r.get('bd_dynamic_visual_atlas_mask_dirty_count','')},{r.get('bd_dynamic_visual_atlas_dynamic_ms','')},{r.get('bd_dynamic_visual_atlas_ecology_ms','')},{r.get('bd_dynamic_visual_atlas_smooth_ms','')},{r.get('largest_slice_path','')},{r.get('largest_slice_ms','')},{r.get('bd_climate_pa_push_ratio','')}")

# DVA upload >=10ms 的子模块时间分布
print('\n=== DVA upload >= 10ms 子模块平均 ===')
heavy = []
for r in rows:
    try:
        v = float(r.get('j_dynamic_visual_atlas_upload_ms', '') or 0)
        if v >= 10.0:
            heavy.append(r)
    except Exception:
        pass
print(f'count_heavy = {len(heavy)}')
if heavy:
    sub = ['bd_dynamic_visual_atlas_dynamic_ms','bd_dynamic_visual_atlas_ecology_ms','bd_dynamic_visual_atlas_smooth_ms','bd_dynamic_visual_atlas_ice_ms']
    for s in sub:
        vs = []
        for r in heavy:
            try:
                vs.append(float(r.get(s,'') or 0))
            except Exception: pass
        if vs:
            print(f'{s} mean={st.mean(vs):.3f} max={max(vs):.3f}')
    # path 分布
    from collections import Counter
    paths = Counter(r.get('bd_dynamic_visual_atlas_dynamic_path','') for r in heavy)
    print('dynamic_path:', paths.most_common(5))
    paths = Counter(r.get('bd_dynamic_visual_atlas_ecology_path','') for r in heavy)
    print('ecology_path:', paths.most_common(5))

# pa push ratio 分布
print('\n=== pa_push_ratio 分布 (climate Pass-A 真变占比) ===')
v = f('bd_climate_pa_push_ratio')
if v:
    bins = [0, 0.001, 0.01, 0.05, 0.1, 0.3, 0.5, 1.01]
    counts = [0]*(len(bins)-1)
    for x in v:
        for i in range(len(bins)-1):
            if bins[i] <= x < bins[i+1]:
                counts[i] += 1; break
    for i in range(len(bins)-1):
        print(f'  [{bins[i]:.3f},{bins[i+1]:.3f}) -> {counts[i]} ({counts[i]/len(v)*100:.1f}%)')
