import csv, math
from collections import defaultdict

path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260616_211345.csv"
with open(path, "r", encoding="utf-8", newline="") as f:
    reader = csv.reader(f); header = next(reader)
idx = {name: i for i, name in enumerate(header)}
def gf(row, name):
    try: return float(row[idx[name]])
    except: return float("nan")

cell_lat={}; cell_water={}; cell_elev={}
with open(path, "r", encoding="utf-8", newline="") as f:
    reader = csv.reader(f); next(reader)
    for row in reader:
        ci=int(float(row[idx["cell_index"]]))
        if ci not in cell_lat:
            cell_lat[ci]=gf(row,"cell_lat_norm_arr"); cell_water[ci]=gf(row,"is_water_arr"); cell_elev[ci]=gf(row,"elevation_arr")

# 取北半球高纬 (lat~0.13, ~57N) 与南半球高纬 (lat~0.87) 的海洋 cell
def near(latv, water, tol=0.01):
    cs=[ci for ci in cell_lat if abs(cell_lat[ci]-latv)<tol and (cell_water[ci]>0.5)==water]
    return sorted(cs, key=lambda c:abs(cell_lat[c]-latv))

targets={}
for latv,name in [(0.12,"N高纬洋"),(0.12,"N高纬陆"),(0.88,"S高纬洋"),(0.88,"S高纬陆"),(0.22,"N中纬洋")]:
    want_water = "洋" in name
    cs=near(latv, want_water)
    if cs:
        targets[cs[0]]=name
print("追踪:", {c:(targets[c],round(cell_lat[c],3),round(cell_elev[c],3),int(cell_water[c])) for c in targets})

series=defaultdict(list)
with open(path, "r", encoding="utf-8", newline="") as f:
    reader=csv.reader(f); next(reader)
    for row in reader:
        ci=int(float(row[idx["cell_index"]]))
        if ci not in targets: continue
        series[ci].append((int(float(row[idx["tick_idx"]])),gf(row,"phys_daily_wind_season_phase"),
            gf(row,"temp_arr"),gf(row,"temp_baseline_arr"),gf(row,"temp_baseline_year_arr"),
            gf(row,"temp_season_offset_arr"),gf(row,"insolation_now_arr"),gf(row,"insolation_dev_arr"),
            gf(row,"thermal_energy_arr"),gf(row,"sea_ice_frac_arr"),gf(row,"temperature_transport_anomaly_arr"),
            gf(row,"air_mass_temp_anomaly_arr")))

def altpen(elev):
    lin=elev*0.40; t=max(0.0,min(1.0,(elev-0.45)/0.55)); hi=t*t*(3-2*t)*0.22; return lin+hi

for c in targets:
    rows=[]; seen=set()
    for r in sorted(series[c],key=lambda x:x[0]):
        if r[0] in seen: continue
        seen.add(r[0]); rows.append(r)
    ap=altpen(cell_elev[c])
    print(f"\n===== cell {c} ({targets[c]}) lat={cell_lat[c]:.3f} elev={cell_elev[c]:.3f} altpen={ap:.3f} =====")
    print(f"{'tick':>6} {'phase':>5} {'temp':>6} {'baseln':>6} {'targ':>6} {'b_yr':>5} {'soff':>6} {'idev':>6} {'insol':>5} {'therm':>6} {'ice':>5} {'tta':>6} {'air':>6}")
    bvals=[];tvals=[];targs=[]
    for k,r in enumerate(rows):
        tick,phase,temp,baseln,byr,soff,insol,idev,therm,ice,tta,air=r
        ty=max(0.0,min(1.0,byr-ap)); targ=max(0.0,min(1.0,ty+soff))
        bvals.append(baseln);tvals.append(temp);targs.append(targ)
        if k%18==0 or k==len(rows)-1:
            print(f"{tick:>6} {phase:>5.2f} {temp:>6.3f} {baseln:>6.3f} {targ:>6.3f} {byr:>5.2f} {soff:>6.3f} {idev:>6.3f} {insol:>5.2f} {therm:>6.3f} {ice:>5.2f} {tta:>6.3f} {air:>6.3f}")
    import statistics
    print(f"  目标 targ 范围[{min(targs):.3f},{max(targs):.3f}] 振幅={max(targs)-min(targs):.3f} 均值={statistics.mean(targs):.3f}")
    print(f"  baseline   范围[{min(bvals):.3f},{max(bvals):.3f}] 振幅={max(bvals)-min(bvals):.3f} 均值={statistics.mean(bvals):.3f}")
    print(f"  temp(最终) 范围[{min(tvals):.3f},{max(tvals):.3f}] 振幅={max(tvals)-min(tvals):.3f} 均值={statistics.mean(tvals):.3f}")
