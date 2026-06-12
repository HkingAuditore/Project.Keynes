#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v6 分析：聚焦三个问题
  1. 降水是否过多？     - 全局/地理切片/时间切片下的 precip 分布、湿日比例、对比地球
  2. 天气是否符合自然规律？ - 类型分布、转换次数、停留时长、随纬度/季节的合理性
  3. 温度是否在局部 tick 内 ping-pong 或不连续跳变？
       - 同 cell 跨 tick 一阶/二阶差分（绝对值与符号反转）
       - 滑窗内方向反转计数
"""
import pandas as pd
import numpy as np
import json, os, sys, time

CSV = r'D:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260612_204203.csv'
OUT_DIR = r'D:/Godot/ProjectKeynes/Project.Keynes/tmp/analysis_output'
os.makedirs(OUT_DIR, exist_ok=True)

USECOLS = [
    'tick_idx','cell_index','cell_lat_norm_arr','is_water_arr','elevation_arr',
    'temp_arr','temp_arr_prev',
    'weather_precip_arr','weather_cloud_arr','weather_cloud_water_arr',
    'weather_intensity_arr','weather_vapor_arr',
    'weather_type_arr','weather_prev_type_arr','weather_target_type_arr',
    'weather_transition_alpha_arr',
    'insolation_now_arr','snow_cover_arr','sea_ice_frac_arr',
]

def lat_band(lat):
    # 把 0~1 归一化纬度划分到 10 个带（每带宽 0.1）
    b = int(np.clip(lat * 10, 0, 9))
    return b

def main():
    t0 = time.time()
    print(f"[*] 读取: {CSV}")

    # === 累加器 ===
    n_rows = 0
    tick_set = set()
    cell_meta = {}  # cell_index -> (lat, is_water, elev)

    # ----- 1. 降水 -----
    # 全局
    precip_sum = 0.0; precip_sq_sum = 0.0; precip_n = 0
    precip_max = 0.0
    wet_count = 0          # precip > 0.001
    heavy_count = 0        # precip > 0.05
    extreme_count = 0      # precip > 0.20
    # 地理切片：按 (lat_band, is_water)
    geo_precip = {}        # (lb, iw) -> dict(sum, sq, n, wet, heavy, max)
    # 时间切片：按 tick 聚合
    tick_precip = {}       # tick -> [sum, n, wet]

    # ----- 2. 天气 -----
    # 全局类型计数
    type_count = {}        # type -> count
    # 地理类型计数
    geo_type = {}          # (lb, iw) -> dict(type -> count)
    # 转换：与 prev_type 不同 => 转换 (这是模型已经记录的"上一帧类型")
    transition_count = 0
    transitioning_count = 0  # transition_alpha > 0
    # 按 cell 记录最近一次类型，统计真转换、停留长度
    last_type_per_cell = {}    # cell -> type
    run_length = {}            # cell -> 当前停留 tick 数
    runs_summary = []          # 完成的停留段长度抽样（按 lat_band）
    runs_by_band = {}          # lb -> list of run lengths（最多取 10000）
    # ----- 3. 温度连续性（关键）-----
    # 流式：按 cell 维护最近 4 个 tick 的 temp，检测：
    #   abs(d1) > J1            => 一阶跳变
    #   sign(d1) != sign(d2)    => 方向反转 (可能 ping-pong)
    #   方向反转 且 abs(d1)+abs(d2) > J2 => "明显的 ping-pong"
    cell_recent = {}    # cell -> list of (tick, temp) 最近 4 个
    jump_count_l1 = 0   # |Δ| > 0.05
    jump_count_l2 = 0   # |Δ| > 0.10
    jump_count_l3 = 0   # |Δ| > 0.20
    delta_max = 0.0
    delta_max_info = None
    pingpong_count = 0          # 方向反转
    pingpong_strong = 0         # 反转且两段都 > 0.02
    pingpong_examples = []      # 抽样
    delta_sum = 0.0; delta_sq_sum = 0.0; delta_n = 0
    # 按地理切片
    geo_temp_jump = {}   # (lb, iw) -> dict(n_delta, sum_abs, max_abs, jumps_l1, jumps_l2, pp, pp_strong)

    chunk_iter = pd.read_csv(CSV, usecols=USECOLS, chunksize=400000)
    for ci, chunk in enumerate(chunk_iter):
        n_rows += len(chunk)
        # 按 tick 排序非必需，因 CSV 本就 (tick, cell) 顺序写入
        # 收集 cell_meta
        if cell_meta == {}:
            uniq = chunk.drop_duplicates('cell_index')
            for _, r in uniq.iterrows():
                cell_meta[int(r['cell_index'])] = (
                    float(r['cell_lat_norm_arr']),
                    int(r['is_water_arr']),
                    float(r['elevation_arr']) if not pd.isna(r['elevation_arr']) else 0.0,
                )

        # ----- 降水 -----
        p = chunk['weather_precip_arr'].astype(float).values
        precip_sum += p.sum()
        precip_sq_sum += (p*p).sum()
        precip_n += len(p)
        precip_max = max(precip_max, float(p.max()))
        wet_count += int((p > 0.001).sum())
        heavy_count += int((p > 0.05).sum())
        extreme_count += int((p > 0.20).sum())

        lats = chunk['cell_lat_norm_arr'].astype(float).values
        iws  = chunk['is_water_arr'].astype(int).values
        bands = np.clip((lats * 10).astype(int), 0, 9)
        types = chunk['weather_type_arr'].astype(int).values
        prev_types = chunk['weather_prev_type_arr'].astype(int).values
        ticks = chunk['tick_idx'].astype(int).values
        cells = chunk['cell_index'].astype(int).values
        temps = chunk['temp_arr'].astype(float).values

        # ----- 地理切片降水 -----
        # 用 pandas groupby 加速
        df_g = pd.DataFrame({'lb':bands,'iw':iws,'p':p,'t':types})
        g_p = df_g.groupby(['lb','iw'])['p'].agg(['sum','count','max',
                                                  lambda s:(s>0.001).sum(),
                                                  lambda s:(s>0.05).sum(),
                                                  lambda s:(s*s).sum()]).reset_index()
        g_p.columns = ['lb','iw','sum','count','max','wet','heavy','sq']
        for _, r in g_p.iterrows():
            k = (int(r['lb']), int(r['iw']))
            d = geo_precip.setdefault(k, {'sum':0.0,'sq':0.0,'n':0,'wet':0,'heavy':0,'max':0.0})
            d['sum'] += float(r['sum']); d['sq'] += float(r['sq'])
            d['n']   += int(r['count']); d['wet'] += int(r['wet']); d['heavy'] += int(r['heavy'])
            d['max'] = max(d['max'], float(r['max']))

        # ----- 时间切片降水 (按 tick) -----
        df_t = pd.DataFrame({'tick':ticks,'p':p})
        g_t = df_t.groupby('tick')['p'].agg(['sum','count', lambda s:(s>0.001).sum()]).reset_index()
        g_t.columns = ['tick','sum','count','wet']
        for _, r in g_t.iterrows():
            tk = int(r['tick'])
            d = tick_precip.setdefault(tk, [0.0, 0, 0])
            d[0] += float(r['sum']); d[1] += int(r['count']); d[2] += int(r['wet'])

        # ----- 天气类型分布 -----
        ut, ct = np.unique(types, return_counts=True)
        for tp, c in zip(ut, ct):
            type_count[int(tp)] = type_count.get(int(tp),0) + int(c)
        # 地理切片
        df_w = pd.DataFrame({'lb':bands,'iw':iws,'t':types})
        g_w = df_w.groupby(['lb','iw','t']).size().reset_index(name='c')
        for _, r in g_w.iterrows():
            k = (int(r['lb']), int(r['iw']))
            geo_type.setdefault(k, {})
            geo_type[k][int(r['t'])] = geo_type[k].get(int(r['t']),0) + int(r['c'])
        # 转换计数（基于 prev_type 字段）
        diff = (types != prev_types)
        transition_count += int(diff.sum())
        ta = chunk['weather_transition_alpha_arr'].astype(float).values
        transitioning_count += int((ta > 0).sum())

        tick_set.update(np.unique(ticks).tolist())

        # ----- 温度连续性 (核心) -----
        # 逐行处理（向量化版本：先按 cell 归类）
        # 为了保证按 tick 顺序，CSV 已是 (tick, cell)；但 chunk 边界可能切断 cell 序列。
        # 使用 cell_recent 字典 持久化 即可跨 chunk。
        for i in range(len(chunk)):
            ce = int(cells[i]); tk = int(ticks[i]); te = float(temps[i])
            lb = int(bands[i]); iw = int(iws[i])
            tp_now = int(types[i])

            # ---- 天气停留 ----
            prev_t = last_type_per_cell.get(ce, None)
            if prev_t is None:
                last_type_per_cell[ce] = tp_now
                run_length[ce] = 1
            elif prev_t == tp_now:
                run_length[ce] = run_length.get(ce,1) + 1
            else:
                # 段结束
                rl = run_length.get(ce, 1)
                lst = runs_by_band.setdefault(lb, [])
                if len(lst) < 8000:
                    lst.append(rl)
                last_type_per_cell[ce] = tp_now
                run_length[ce] = 1

            # ---- 温度差分 ----
            recent = cell_recent.get(ce, [])
            recent.append((tk, te))
            if len(recent) > 4:
                recent = recent[-4:]
            cell_recent[ce] = recent
            if len(recent) >= 2:
                d1 = recent[-1][1] - recent[-2][1]
                ad1 = abs(d1)
                delta_sum += ad1; delta_sq_sum += ad1*ad1; delta_n += 1
                if ad1 > delta_max:
                    delta_max = ad1
                    delta_max_info = {'cell':ce,'tick_a':recent[-2][0],'tick_b':recent[-1][0],
                                      't_a':recent[-2][1],'t_b':recent[-1][1],
                                      'lat':cell_meta.get(ce,(None,None,None))[0],
                                      'is_water':cell_meta.get(ce,(None,None,None))[1]}
                if ad1 > 0.05: jump_count_l1 += 1
                if ad1 > 0.10: jump_count_l2 += 1
                if ad1 > 0.20: jump_count_l3 += 1

                gk = (lb, iw)
                gd = geo_temp_jump.setdefault(gk, {'n':0,'sum_abs':0.0,'max_abs':0.0,
                                                   'l1':0,'l2':0,'pp':0,'pp_strong':0})
                gd['n'] += 1; gd['sum_abs'] += ad1
                if ad1 > gd['max_abs']: gd['max_abs'] = ad1
                if ad1 > 0.05: gd['l1'] += 1
                if ad1 > 0.10: gd['l2'] += 1

                if len(recent) >= 3:
                    d2 = recent[-2][1] - recent[-3][1]
                    # 方向反转 (ping-pong 候选)
                    if d1*d2 < 0:
                        pingpong_count += 1
                        gd['pp'] += 1
                        if abs(d1) > 0.02 and abs(d2) > 0.02:
                            pingpong_strong += 1
                            gd['pp_strong'] += 1
                            if len(pingpong_examples) < 50:
                                pingpong_examples.append({
                                    'cell':ce,'lat':cell_meta.get(ce,(None,None,None))[0],
                                    'is_water':iw,
                                    'ticks':[r[0] for r in recent[-3:]],
                                    'temps':[r[1] for r in recent[-3:]],
                                    'd1':d1,'d2':d2})

        if (ci+1) % 5 == 0:
            print(f"  ... 已处理 {n_rows:,} 行, ticks={len(tick_set)}, 用时 {time.time()-t0:.1f}s")

    # === 整理输出 ===
    out = {}
    out['meta'] = {
        'csv': os.path.basename(CSV),
        'rows': n_rows,
        'ticks': len(tick_set),
        'tick_min': min(tick_set) if tick_set else None,
        'tick_max': max(tick_set) if tick_set else None,
        'cells': len(cell_meta),
        'water_cells': sum(1 for v in cell_meta.values() if v[1]==1),
        'duration_s': round(time.time()-t0, 1),
    }

    # ----- 1. 降水 -----
    mean = precip_sum/max(precip_n,1)
    var  = precip_sq_sum/max(precip_n,1) - mean*mean
    out['precip_global'] = {
        'mean': mean,
        'std':  float(np.sqrt(max(var,0))),
        'max':  precip_max,
        'wet_ratio_gt_0p001':   wet_count/max(precip_n,1),
        'heavy_ratio_gt_0p05':  heavy_count/max(precip_n,1),
        'extreme_ratio_gt_0p20':extreme_count/max(precip_n,1),
        'samples': precip_n,
    }
    # 地理切片（lat_band × is_water）
    geo_p_out = []
    for (lb,iw), d in sorted(geo_precip.items()):
        n = d['n']
        m = d['sum']/max(n,1)
        v = d['sq']/max(n,1) - m*m
        geo_p_out.append({
            'lat_band': f'{lb*0.1:.1f}-{(lb+1)*0.1:.1f}',
            'lb':lb,'is_water':iw,
            'n':n, 'mean':m, 'std':float(np.sqrt(max(v,0))),
            'max':d['max'],
            'wet_ratio':d['wet']/max(n,1),
            'heavy_ratio':d['heavy']/max(n,1),
        })
    out['precip_geo'] = geo_p_out

    # 时间切片（每 tick 平均降水）
    sorted_ticks = sorted(tick_precip.keys())
    tk_series = []
    for tk in sorted_ticks:
        s,n,w = tick_precip[tk]
        tk_series.append({'tick':tk,'mean_precip':s/max(n,1),'wet_ratio':w/max(n,1),'n':n})
    out['precip_time_series'] = tk_series  # 完整序列，供画图
    # 时间切片摘要：按 100tick 桶汇总
    bucket = {}
    for it in tk_series:
        b = it['tick']//100
        d = bucket.setdefault(b, {'sum':0.0,'wet':0.0,'n':0,'tk_n':0})
        d['sum'] += it['mean_precip']; d['wet'] += it['wet_ratio']; d['tk_n'] += 1
    tb_out = []
    for b in sorted(bucket.keys()):
        d = bucket[b]
        tb_out.append({'tick_bucket':f'{b*100}-{b*100+99}',
                       'mean_precip':d['sum']/max(d['tk_n'],1),
                       'wet_ratio':d['wet']/max(d['tk_n'],1)})
    out['precip_time_bucket'] = tb_out

    # ----- 2. 天气 -----
    total_t = sum(type_count.values())
    out['weather_global'] = {
        'type_dist': {str(k): {'count':v,'ratio':v/max(total_t,1)} for k,v in sorted(type_count.items())},
        'transition_count_total': transition_count,
        'transition_per_row': transition_count/max(n_rows,1),
        'transitioning_count_total': transitioning_count,
        'transitioning_ratio': transitioning_count/max(n_rows,1),
    }
    geo_t_out = []
    for (lb,iw), td in sorted(geo_type.items()):
        n = sum(td.values())
        geo_t_out.append({
            'lat_band':f'{lb*0.1:.1f}-{(lb+1)*0.1:.1f}','lb':lb,'is_water':iw,
            'n':n,
            'dist':{str(k):round(v/max(n,1),4) for k,v in sorted(td.items())},
        })
    out['weather_geo'] = geo_t_out
    # 停留段统计
    run_stat = {}
    for lb, lst in runs_by_band.items():
        if not lst:
            continue
        a = np.array(lst)
        run_stat[f'{lb*0.1:.1f}-{(lb+1)*0.1:.1f}'] = {
            'samples': len(a),
            'mean': float(a.mean()),
            'median': float(np.median(a)),
            'p25': float(np.percentile(a,25)),
            'p75': float(np.percentile(a,75)),
            'p99': float(np.percentile(a,99)),
            'max': int(a.max()),
        }
    out['weather_run_length'] = run_stat

    # ----- 3. 温度连续性 -----
    dmean = delta_sum/max(delta_n,1)
    dvar  = delta_sq_sum/max(delta_n,1) - dmean*dmean
    out['temp_continuity_global'] = {
        'samples': delta_n,
        'mean_abs_delta': dmean,
        'std_abs_delta':  float(np.sqrt(max(dvar,0))),
        'max_abs_delta':  delta_max,
        'max_delta_info': delta_max_info,
        'jumps_gt_0p05':  jump_count_l1, 'jumps_gt_0p05_ratio':  jump_count_l1/max(delta_n,1),
        'jumps_gt_0p10':  jump_count_l2, 'jumps_gt_0p10_ratio':  jump_count_l2/max(delta_n,1),
        'jumps_gt_0p20':  jump_count_l3, 'jumps_gt_0p20_ratio':  jump_count_l3/max(delta_n,1),
        'pingpong_count': pingpong_count, 'pingpong_ratio': pingpong_count/max(delta_n,1),
        'pingpong_strong_count': pingpong_strong,
        'pingpong_strong_ratio': pingpong_strong/max(delta_n,1),
    }
    out['temp_continuity_examples'] = pingpong_examples
    geo_c_out = []
    for (lb,iw), gd in sorted(geo_temp_jump.items()):
        n = gd['n']
        geo_c_out.append({
            'lat_band':f'{lb*0.1:.1f}-{(lb+1)*0.1:.1f}','lb':lb,'is_water':iw,
            'samples': n,
            'mean_abs_delta': gd['sum_abs']/max(n,1),
            'max_abs_delta':  gd['max_abs'],
            'jump_l1_ratio':  gd['l1']/max(n,1),
            'jump_l2_ratio':  gd['l2']/max(n,1),
            'pp_ratio':       gd['pp']/max(n,1),
            'pp_strong_ratio':gd['pp_strong']/max(n,1),
        })
    out['temp_continuity_geo'] = geo_c_out

    out_path = os.path.join(OUT_DIR, 'analysis_v6_v2.json')
    with open(out_path,'w',encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2, default=float)
    print(f"[OK] 写入 {out_path}, rows={n_rows:,}, ticks={len(tick_set)}, 用时 {time.time()-t0:.1f}s")

if __name__ == '__main__':
    main()
