#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""分析气候数据，诊断气温跳变、降水问题、雪覆盖异常"""

import csv
import numpy as np
from collections import defaultdict

def analyze_csv(filepath):
    with open(filepath, 'r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    
    print(f"Total rows: {len(rows)}")
    
    # 转换数据
    data = []
    for r in rows:
        try:
            data.append({
                'tick_idx': int(r['tick_idx']),
                'cell_index': int(r['cell_index']),
                'temp': float(r['temp_arr']),
                'moisture': float(r['moisture_arr']),
                'snow_cover': float(r['snow_cover_arr']),
                'temp_prev': float(r['temp_arr_prev']) if r.get('temp_arr_prev') else None,
                'moisture_prev': float(r['moisture_arr_prev']) if r.get('moisture_arr_prev') else None,
                'snow_prev': float(r['snow_cover_arr_prev']) if r.get('snow_cover_arr_prev') else None,
            })
        except:
            pass
    
    print(f"Valid data rows: {len(data)}")
    
    # 1. 气温变化分析
    print("\n" + "="*60)
    print("TEMPERATURE ANALYSIS")
    print("="*60)
    
    temps = np.array([d['temp'] for d in data])
    temp_diffs = []
    for i in range(1, len(data)):
        if data[i]['temp_prev'] is not None:
            diff = abs(data[i]['temp'] - data[i]['temp_prev'])
            temp_diffs.append(diff)
    
    if temp_diffs:
        temp_diffs = np.array(temp_diffs)
        print(f"Temperature stats:")
        print(f"  Mean: {np.mean(temps):.4f}")
        print(f"  Std: {np.std(temps):.4f}")
        print(f"  Min: {np.min(temps):.4f}")
        print(f"  Max: {np.max(temps):.4f}")
        
        print(f"\nTemperature change (current - prev) stats:")
        print(f"  Mean diff: {np.mean(temp_diffs):.4f}")
        print(f"  Std diff: {np.std(temp_diffs):.4f}")
        print(f"  Max diff: {np.max(temp_diffs):.4f}")
        print(f"  Min diff: {np.min(temp_diffs):.4f}")
        
        # 找出大跳变
        big_jumps = temp_diffs[temp_diffs > 0.1]
        print(f"\nLarge jumps (>0.1): {len(big_jumps)} / {len(temp_diffs)} ({100*len(big_jumps)/len(temp_diffs):.1f}%)")
        if len(big_jumps) > 0:
            print(f"  Max jump: {np.max(big_jumps):.4f}")
            print(f"  Mean jump: {np.mean(big_jumps):.4f}")
        
        # 按cell分组分析
        cell_temps = defaultdict(list)
        for d in data:
            cell_temps[d['cell_index']].append(d['temp'])
        
        cell_jumps = []
        for cid, temps_list in cell_temps.items():
            if len(temps_list) > 1:
                for i in range(1, len(temps_list)):
                    diff = abs(temps_list[i] - temps_list[i-1])
                    if diff > 0.05:  # 阈值
                        cell_jumps.append((cid, temps_list[i-1], temps_list[i], diff))
        
        print(f"\nPer-cell analysis (jumps >0.05): {len(cell_jumps)} jumps")
        
    # 2. 降水分析
    print("\n" + "="*60)
    print("MOISTURE ANALYSIS")
    print("="*60)
    
    moistures = np.array([d['moisture'] for d in data])
    moisture_diffs = []
    for i in range(1, len(data)):
        if data[i]['moisture_prev'] is not None:
            diff = data[i]['moisture'] - data[i]['moisture_prev']
            moisture_diffs.append(diff)
    
    if moisture_diffs:
        moisture_diffs = np.array(moisture_diffs)
        print(f"Moisture stats:")
        print(f"  Mean: {np.mean(moistures):.4f}")
        print(f"  Std: {np.std(moistures):.4f}")
        print(f"  Min: {np.min(moistures):.4f}")
        print(f"  Max: {np.max(moistures):.4f}")
        
        print(f"\nMoisture change stats:")
        print(f"  Mean diff: {np.mean(moisture_diffs):.4f}")
        print(f"  Std diff: {np.std(moisture_diffs):.4f}")
        print(f"  Max diff: {np.max(moisture_diffs):.4f}")
        print(f"  Min diff: {np.min(moisture_diffs):.4f}")
        
        # 检查是否有区域降水持续不变
        print(f"\nChecking for stuck precipitation zones...")
        
        # 按cell分组
        cell_moist = defaultdict(list)
        for d in data:
            cell_moist[d['cell_index']].append(d['moisture'])
        
        stuck_cells = []
        for cid, moist_list in cell_moist.items():
            if len(moist_list) > 10:  # 至少10个tick的数据
                # 检查是否所有值相同
                if max(moist_list) - min(moist_list) < 0.001:
                    stuck_cells.append((cid, moist_list[0]))
                # 检查是否有连续高降水
                if max(moist_list) > 0.8 and len(set(moist_list)) < 3:
                    stuck_cells.append((cid, np.mean(moist_list)))
        
        print(f"  Cells with stuck moisture (>10 ticks same): {len(stuck_cells)}")
        
    # 3. 雪覆盖分析
    print("\n" + "="*60)
    print("SNOW COVER ANALYSIS")
    print("="*60)
    
    snow_covers = np.array([d['snow_cover'] for d in data])
    
    print(f"Snow cover stats:")
    print(f"  Mean: {np.mean(snow_covers):.4f}")
    print(f"  Std: {np.std(snow_covers):.4f}")
    print(f"  Min: {np.min(snow_covers):.4f}")
    print(f"  Max: {np.max(snow_covers):.4f}")
    
    # 按cell分析雪覆盖变化
    cell_snow = defaultdict(list)
    for d in data:
        cell_snow[d['cell_index']].append(d['snow_cover'])
    
    # 找出雪覆盖变化的cell
    snow_changes = []
    for cid, snow_list in cell_snow.items():
        if len(snow_list) > 1:
            for i in range(1, len(snow_list)):
                diff = abs(snow_list[i] - snow_list[i-1])
                if diff > 0.01:  # 有明显变化
                    snow_changes.append((cid, snow_list[i-1], snow_list[i], diff))
    
    print(f"\nSnow cover changes (>0.01 diff): {len(snow_changes)} changes")
    
    # 分析高山区域（假设高海拔=更多雪）
    print("\nAnalyzing mountain snow (cells with persistent snow > 0.3):")
    mountain_snow_cells = [cid for cid, snow_list in cell_snow.items() if max(snow_list) > 0.3]
    print(f"  Cells that reached snow > 0.3: {len(mountain_snow_cells)}")
    
    # 4. 按tick分析（时间序列）
    print("\n" + "="*60)
    print("TIME SERIES ANALYSIS (by tick)")
    print("="*60)
    
    tick_data = defaultdict(list)
    for d in data:
        tick_data[d['tick_idx']].append(d)
    
    # 选取几个代表性的tick
    sample_ticks = sorted(tick_data.keys())[:10]
    print(f"\nSample ticks: {sample_ticks}")
    for tick in sample_ticks:
        cells = tick_data[tick]
        temps_tick = [c['temp'] for c in cells]
        moist_tick = [c['moisture'] for c in cells]
        snow_tick = [c['snow_cover'] for c in cells]
        print(f"  Tick {tick}: cells={len(cells)}, temp=[{np.min(temps_tick):.3f}-{np.max(temps_tick):.3f}], "
              f"moist=[{np.min(moist_tick):.3f}-{np.max(moist_tick):.3f}], "
              f"snow=[{np.min(snow_tick):.3f}-{np.max(snow_tick):.3f}]")
    
    # 5. 找出问题区域
    print("\n" + "="*60)
    print("PROBLEM AREAS IDENTIFIED")
    print("="*60)
    
    # 问题1: 气温跳变
    jump_cells = set()
    for i in range(1, len(data)):
        if data[i]['temp_prev'] is not None:
            diff = abs(data[i]['temp'] - data[i]['temp_prev'])
            if diff > 0.15:  # 大跳变
                jump_cells.add(data[i]['cell_index'])
    print(f"\n1. Large temperature jumps (>0.15): {len(jump_cells)} unique cells")
    
    # 问题2: 降水卡住
    stuck_moist_cells = set()
    for cid, moist_list in cell_moist.items():
        if len(moist_list) > 20 and max(moist_list) - min(moist_list) < 0.001:
            stuck_moist_cells.add(cid)
    print(f"2. Stuck moisture (>20 ticks unchanged): {len(stuck_moist_cells)} cells")
    
    # 问题3: 雪覆盖不自然
    snow_issues = []
    for cid, snow_list in cell_snow.items():
        if len(snow_list) > 10:
            # 雪应该随季节变化
            if max(snow_list) > 0.1 and min(snow_list) < 0.01:
                # 雪有季节变化
                pass
            elif max(snow_list) > 0.3 and len(set(snow_list)) == 1:
                # 高山永久雪但没有变化
                snow_issues.append((cid, snow_list[0], 'permanent_no_change'))
            elif max(snow_list) == 0 and min(snow_list) > 0.1:
                # 有雪但不应该是永久的
                snow_issues.append((cid, np.mean(snow_list), 'unexpected_persistent'))
    
    print(f"3. Snow cover issues: {len(snow_issues)} cells")
    
    # 6. 综合诊断
    print("\n" + "="*60)
    print("DIAGNOSIS")
    print("="*60)
    
    # 检查是否有共同问题
    common_issues = jump_cells & stuck_moist_cells
    print(f"\nCells with both temp jumps AND stuck moisture: {len(common_issues)}")
    
    return {
        'temp_jumps': len(jump_cells),
        'stuck_moisture': len(stuck_moist_cells),
        'snow_issues': len(snow_issues),
        'common_issues': len(common_issues),
    }

if __name__ == '__main__':
    filepath = 'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260526_113952.csv'
    result = analyze_csv(filepath)
    print(f"\nSummary: {result}")
