import csv, math
from collections import defaultdict

path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260616_211345.csv"
with open(path, "r", encoding="utf-8", newline="") as f:
    reader = csv.reader(f); header = next(reader)
idx = {name: i for i, name in enumerate(header)}
def gf(row, name):
    try: return float(row[idx[name]])
    except: return float("nan")

# 第一遍：找出每个 cell_index 的 lat_norm / is_water / elevation（取第一次出现）
cell_lat = {}
cell_water = {}
cell_elev = {}
with open(path, "r", encoding="utf-8", newline="") as f:
    reader = csv.reader(f); next(reader)
    for row in reader:
        ci = int(float(row[idx["cell_index"]]))
        if ci not in cell_lat:
            cell_lat[ci] = gf(row,"cell_lat_norm_arr")
            cell_water[ci] = gf(row,"is_water_arr")
            cell_elev[ci] = gf(row,"elevation_arr")

# 选取代表 cell：最北极、最南极、最接近赤道，且优先选海洋 cell 以排除海拔惩罚
def pick(cond):
    cands = [ci for ci in cell_lat if cond(ci)]
    return cands

north_water = sorted([ci for ci in cell_lat if cell_lat[ci]<0.03 and cell_water[ci]>0.5], key=lambda c:cell_lat[c])
south_water = sorted([ci for ci in cell_lat if cell_lat[ci]>0.97 and cell_water[ci]>0.5], key=lambda c:-cell_lat[c])
eq_water    = sorted([ci for ci in cell_lat if abs(cell_lat[ci]-0.5)<0.02 and cell_water[ci]>0.5], key=lambda c:abs(cell_lat[c]-0.5))

print("北极海洋cell候选:", north_water[:5], [round(cell_lat[c],3) for c in north_water[:5]])
print("南极海洋cell候选:", south_water[:5], [round(cell_lat[c],3) for c in south_water[:5]])
print("赤道海洋cell候选:", eq_water[:5], [round(cell_lat[c],3) for c in eq_water[:5]])

targets = {}
if north_water: targets[north_water[0]] = "北极洋"
if south_water: targets[south_water[0]] = "南极洋"
if eq_water:    targets[eq_water[0]]    = "赤道洋"
# 再加一个北极陆地 cell 对比
north_land = sorted([ci for ci in cell_lat if cell_lat[ci]<0.05 and cell_water[ci]<0.5], key=lambda c:cell_lat[c])
if north_land: targets[north_land[0]] = "北极陆"

print("\n追踪 cell:", {c:targets[c] for c in targets}, "\n")
for c in targets:
    print(f"  cell {c} ({targets[c]}): lat={cell_lat[c]:.3f} water={cell_water[c]:.0f} elev={cell_elev[c]:.3f}")

# 第二遍：抽取这些 cell 的时间序列
series = defaultdict(list)  # cell -> list of (tick, phase, temp, baseline, base_yr, soff, insol, daylen, therm, seaice)
with open(path, "r", encoding="utf-8", newline="") as f:
    reader = csv.reader(f); next(reader)
    for row in reader:
        ci = int(float(row[idx["cell_index"]]))
        if ci not in targets: continue
        series[ci].append((
            int(float(row[idx["tick_idx"]])),
            gf(row,"phys_daily_wind_season_phase"),
            gf(row,"temp_arr"), gf(row,"temp_baseline_arr"),
            gf(row,"temp_baseline_year_arr"), gf(row,"temp_season_offset_arr"),
            gf(row,"insolation_now_arr"), gf(row,"day_length_arr"),
            gf(row,"thermal_energy_arr"), gf(row,"sea_ice_frac_arr"),
        ))

for c in targets:
    s = series[c]
    # 按 tick 排序去重（同 tick 可能多次）
    seen=set(); rows=[]
    for r in sorted(s, key=lambda x:x[0]):
        if r[0] in seen: continue
        seen.add(r[0]); rows.append(r)
    print(f"\n===== cell {c} ({targets[c]}) 时间序列（每 ~20 tick 抽样）=====")
    print(f"{'tick':>6} {'phase':>6} {'temp':>6} {'baseln':>7} {'targ*':>6} {'base_yr':>7} {'s_off':>6} {'insol':>6} {'daylen':>6} {'therm':>6} {'seaice':>6}")
    elev = cell_elev[c]
    alt_lin = elev*0.40
    t_hi = max(0.0,min(1.0,(elev-0.45)/(1-0.45)))
    alt_hi = t_hi*t_hi*(3-2*t_hi)*0.22
    alt_pen = alt_lin+alt_hi
    for k,r in enumerate(rows):
        if k % 20 != 0 and k != len(rows)-1: continue
        tick,phase,temp,baseln,base_yr,soff,insol,daylen,therm,seaice = r
        temp_year = max(0.0, min(1.0, base_yr - alt_pen))
        targ = max(0.0, min(1.0, temp_year + soff))
        print(f"{tick:>6} {phase:>6.2f} {temp:>6.3f} {baseln:>7.3f} {targ:>6.3f} {base_yr:>7.3f} {soff:>6.3f} {insol:>6.3f} {daylen:>6.3f} {therm:>6.3f} {seaice:>6.3f}")
    # 统计 baseline 的全程波动范围
    bvals=[r[3] for r in rows]
    tvals=[r[2] for r in rows]
    print(f"  baseline 范围: [{min(bvals):.3f}, {max(bvals):.3f}]  振幅={max(bvals)-min(bvals):.3f}")
    print(f"  temp     范围: [{min(tvals):.3f}, {max(tvals):.3f}]  振幅={max(tvals)-min(tvals):.3f}")
