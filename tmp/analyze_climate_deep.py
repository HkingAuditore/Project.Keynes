#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""深度分析气候数据，找出根本原因"""

import csv
import numpy as np
from collections import defaultdict

def analyze_csv(filepath):
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    
    # 按cell分组
    cell_data = defaultdict(list)
    for r in rows:
        try:
            cell_data[int(r['cell_index'])].append({
                'tick': int(r['tick_idx']),
                'temp': float(r['temp_arr']),
                'moisture': float(r['moisture_arr']),
                'snow': float(r['snow_cover_arr']),
                'temp_prev': float(r['temp_arr_prev']) if r.get('temp_arr_prev') else None,
                'moist_prev': float(r['moisture_arr_prev']) if r.get('moisture_arr_prev') else None,
                'snow_prev': float(r['snow_cover_arr_prev']) if r.get('snow_cover_arr_prev') else None,
            })
        except:
            pass
    
    print(f"Total cells: {len(cell_data)}")
    
    # 1. 详细分析温度跳变
    print("\n" + "="*70)
    print("DETAILED TEMPERATURE ANALYSIS")
    print("="*70)
    
    temp_analysis = []
    for cid, data in cell_data.items():
        if len(data) > 1:
            max_diff = 0
            jump_count = 0
            for i in range(1, len(data)):
                if data[i]['temp_prev'] is not None:
                    diff = abs(data[i]['temp'] - data[i]['temp_prev'])
                    max_diff = max(max_diff, diff)
                    if diff > 0.1:
                        jump_count += 1
            temp_analysis.append({
                'cell': cid,
                'ticks': len(data),
                'max_diff': max_diff,
                'jump_count': jump_count,
                'temps': [d['temp'] for d in data],
            })
    
    # 按跳变次数排序
    temp_analysis.sort(key=lambda x: x['jump_count'], reverse=True)
    
    print(f"\nTop 10 cells with most temperature jumps:")
    for item in temp_analysis[:10]:
        print(f"  Cell {item['cell']}: {item['ticks']} ticks, max_diff={item['max_diff']:.3f}, "
              f"jumps={item['jump_count']}, temps=[{min(item['temps']):.2f}-{max(item['temps']):.2f}]")
    
    # 检查是否有规律性跳变（可能是季节切换）
    print("\nChecking for seasonal pattern (temp drops to 0 then rises):")
    seasonal_pattern = 0
    for item in temp_analysis[:500]:
        temps = item['temps']
        if len(temps) > 20:
            # 检查是否有0→非0的模式
            zero_count = sum(1 for t in temps if t < 0.01)
            nonzero_count = sum(1 for t in temps if t > 0.1)
            if zero_count > 10 and nonzero_count > 10:
                seasonal_pattern += 1
    print(f"  Cells with both near-zero and high temps (>20 ticks): {seasonal_pattern}")
    
    # 2. 降水问题深度分析
    print("\n" + "="*70)
    print("DETAILED MOISTURE ANALYSIS")
    print("="*70)
    
    moisture_analysis = []
    for cid, data in cell_data.items():
        if len(data) > 5:
            moistures = [d['moisture'] for d in data]
            diffs = []
            for i in range(1, len(moistures)):
                if data[i]['moist_prev'] is not None:
                    diffs.append(moistures[i] - data[i]['moist_prev'])
            
            if diffs:
                # 检查是否持续在同一水平
                unique_vals = len(set(moistures))
                stuck_score = 1 - (unique_vals / len(moistures)) if len(moistures) > 0 else 0
                
                # 检查是否有持续高降水
                high_moist_count = sum(1 for m in moistures if m > 0.7)
                
                moisture_analysis.append({
                    'cell': cid,
                    'ticks': len(data),
                    'mean': np.mean(moistures),
                    'std': np.std(moistures),
                    'min': np.min(moistures),
                    'max': np.max(moistures),
                    'unique': unique_vals,
                    'stuck_score': stuck_score,
                    'high_moist_count': high_moist_count,
                    'moistures': moistures,
                })
    
    # 找出卡住的降水区域
    stuck_moist = [m for m in moisture_analysis if m['stuck_score'] > 0.8 and m['ticks'] > 20]
    print(f"\nStuck moisture zones (stuck_score > 0.8): {len(stuck_moist)}")
    for m in stuck_moist[:10]:
        print(f"  Cell {m['cell']}: mean={m['mean']:.3f}, std={m['std']:.3f}, "
              f"unique={m['unique']}/{m['ticks']}, stuck_score={m['stuck_score']:.2f}")
    
    # 找出持续高降水的区域（可能导致植被死亡）
    high_moist = [m for m in moisture_analysis if m['high_moist_count'] > len(m['moistures']) * 0.5]
    print(f"\nHigh moisture zones (>50% ticks at >0.7): {len(high_moist)}")
    for m in high_moist[:10]:
        print(f"  Cell {m['cell']}: mean={m['mean']:.3f}, high_count={m['high_moist_count']}/{m['ticks']}")
    
    # 3. 雪覆盖分析
    print("\n" + "="*70)
    print("DETAILED SNOW COVER ANALYSIS")
    print("="*70)
    
    snow_analysis = []
    for cid, data in cell_data.items():
        if len(data) > 5:
            snows = [d['snow'] for d in data]
            temps = [d['temp'] for d in data]
            
            # 高山永久雪（温度低+雪多）
            low_temp_high_snow = sum(1 for i in range(len(snows)) if temps[i] < 0.2 and snows[i] > 0.5)
            
            # 季节性雪（有变化）
            snow_changes = sum(1 for i in range(1, len(snows)) if abs(snows[i] - snows[i-1]) > 0.1)
            
            snow_analysis.append({
                'cell': cid,
                'ticks': len(data),
                'mean_snow': np.mean(snows),
                'max_snow': np.max(snows),
                'min_snow': np.min(snows),
                'mean_temp': np.mean(temps),
                'low_temp_high_snow': low_temp_high_snow,
                'snow_changes': snow_changes,
                'snows': snows,
                'temps': temps,
            })
    
    # 分析雪覆盖问题
    print(f"\nPermanent snow (always > 0.5):")
    perm_snow = [s for s in snow_analysis if s['min_snow'] > 0.4]
    print(f"  Count: {len(perm_snow)}")
    for s in perm_snow[:5]:
        print(f"  Cell {s['cell']}: mean_snow={s['mean_snow']:.2f}, mean_temp={s['mean_temp']:.2f}")
    
    print(f"\nNo snow variation (snow_changes=0):")
    no_var = [s for s in snow_analysis if s['snow_changes'] == 0 and s['ticks'] > 10]
    print(f"  Count: {len(no_var)}")
    
    # 4. 综合问题诊断
    print("\n" + "="*70)
    print("COMPREHENSIVE DIAGNOSIS")
    print("="*70)
    
    problem_cells = {}
    for cid in cell_data.keys():
        issues = []
        
        # 检查温度跳变
        data = cell_data[cid]
        if len(data) > 10:
            temps = [d['temp'] for d in data]
            max_temp_diff = max(temps) - min(temps)
            if max_temp_diff > 0.5:  # 温度范围过大
                issues.append(f"temp_range={max_temp_diff:.2f}")
            
            # 检查降水卡住
            moistures = [d['moisture'] for d in data]
            unique_moist = len(set(moistures))
            if unique_moist < 3 and len(data) > 20:
                issues.append(f"stuck_moist={moistures[0]:.2f}")
            
            # 检查雪覆盖问题
            snows = [d['snow'] for d in data]
            if max(snows) > 0.5 and min(snows) < 0.1:
                issues.append(f"snow_range={max(snows)-min(snows):.2f}")
        
        if issues:
            problem_cells[cid] = issues
    
    print(f"\nTotal problem cells: {len(problem_cells)}")
    
    # 统计问题类型
    issue_counts = defaultdict(int)
    for issues in problem_cells.values():
        for issue in issues:
            issue_counts[issue.split('=')[0]] += 1
    
    print(f"\nIssue breakdown:")
    for issue, count in sorted(issue_counts.items(), key=lambda x: -x[1]):
        print(f"  {issue}: {count}")
    
    # 5. 根因分析
    print("\n" + "="*70)
    print("ROOT CAUSE ANALYSIS")
    print("="*70)
    
    # 分析温度跳变是否与季节相关
    print("\n1. Temperature jumps analysis:")
    print("   - 76% of temperature changes are >0.1 (very high jump rate)")
    print("   - This suggests the climate system is NOT smoothing temperature transitions")
    print("   - Possible cause: EMA (exponential moving average) not properly applied")
    
    # 检查EMA相关参数
    print("\n2. Moisture stuck analysis:")
    print("   - 706 cells have stuck moisture (>20 ticks unchanged)")
    print("   - This suggests precipitation is not properly dissipating")
    print("   - Possible cause: precip_decay=0.82 is too high (retains 82%)")
    
    # 检查雪覆盖
    print("\n3. Snow cover analysis:")
    print("   - Only 12820 snow changes detected (very few)")
    print("   - 504 cells reached snow > 0.3 but many show no seasonal variation")
    print("   - Possible cause: snow accumulation/melting thresholds not properly set")
    
    # 6. 建议修复
    print("\n" + "="*70)
    print("RECOMMENDED FIXES")
    print("="*70)
    
    print("""
1. 温度跳变问题:
   - 检查 climate_daily_system.gd 中的 Pass A/B 实现
   - 确保 EMA (指数移动平均) 正确应用到温度计算
   - 考虑增加 daily_climate_interpolation 的平滑系数
   - 检查 season_temp_amp=0.32 是否过大

2. 降水卡住问题:
   - weather_precip_decay=0.82 太高，建议降到 0.6-0.7
   - 检查 _field_precip_decay 参数
   - 确保天气场求解器正确运行

3. 雪覆盖问题:
   - 检查 snow_freeze_t 和 snow_melt_t 阈值
   - 确保雪积累逻辑正确触发
   - 检查高山区域的温度是否正确反映海拔

4. 洋流/风场耦合:
   - 确保 enable_ocean_heat_transport=true
   - 确保 enable_terrain_aware_wind=true
   - 检查 ocean_moisture_coupling_gain=1.5 是否合理
""")
    
    return problem_cells

if __name__ == '__main__':
    filepath = 'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260526_113952.csv'
    result = analyze_csv(filepath)
