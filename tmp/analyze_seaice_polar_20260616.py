import csv, math, sys
from collections import defaultdict
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass

path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260616_215851.csv"

with open(path, "r", encoding="utf-8-sig", newline="") as f:
    reader = csv.reader(f); header = next(reader)
idx = {n: i for i, n in enumerate(header)}
print("=== 列名 ===")
for i, n in enumerate(header):
    print(f"  [{i:>2}] {n}")

def gf(row, name):
    j = idx.get(name)
    if j is None: return float("nan")
    try: return float(row[j])
    except: return float("nan")

# 季节相位列自动探测
season_col = None
for cand in ("phys_daily_wind_season_phase", "season_phase", "phys_season_phase"):
    if cand in idx: season_col = cand; break
tick_col = None
for cand in ("tick_idx", "phys_sim_day", "sim_day"):
    if cand in idx: tick_col = cand; break
print(f"\nseason_col={season_col}  tick_col={tick_col}")

FORM = 0.14   # sea_ice_form_threshold
MELT = 0.22   # sea_ice_melt_threshold

NB = 10
def band(lat): return min(NB-1, max(0, int(lat*NB)))
def season_idx(sp):
    # season_phase ∈ [0,4): 0=spring 1=summer 2=autumn 3=winter (按半球不同)
    return int(math.floor(sp)) & 3 if not math.isnan(sp) else -1

# ── 问题2：极地按季节相位的温度 ────────────────────────────────
# 按 (band, is_water, season_bucket) 统计 mean/max temp、target、anomaly
def altpen(elev):
    lin = elev*0.40; t = max(0.0, min(1.0, (elev-0.45)/0.55)); hi = t*t*(3-2*t)*0.22
    return lin+hi

pol = defaultdict(lambda: dict(n=0, st=0.0, mx=-1.0, mn=2.0, starg=0.0, sair=0.0, stta=0.0, sdev=0.0, soff=0.0))

# ── 问题1：冷却但无海冰 ────────────────────────────────────────
seaice_n = 0
cold_no_ice = 0       # temp<FORM 但 frac<0.5
cold_no_ice_any = 0   # temp<FORM 但 frac<0.05
cold_with_ice = 0
# 冷却无冰的 cell 的特征
cni_insol = 0.0; cni_daylen = 0.0; cni_temp = 0.0; cni_lat = 0.0; cni_tick = defaultdict(int)
# 温度 vs frac 分桶
tbucket = defaultdict(lambda: dict(n=0, sfrac=0.0, nfrozen=0))  # key = round(temp,2)

has_frac = "sea_ice_frac_arr" in idx
has_insol = "insolation_now_arr" in idx
has_daylen = "day_length_arr" in idx

with open(path, "r", encoding="utf-8-sig", newline="") as f:
    reader = csv.reader(f); next(reader)
    for row in reader:
        w = 1 if gf(row, "is_water_arr") > 0.5 else 0
        lat = gf(row, "cell_lat_norm_arr"); temp = gf(row, "temp_arr")
        if math.isnan(lat) or math.isnan(temp): continue
        sp = gf(row, season_col) if season_col else float("nan")
        sb = season_idx(sp)
        elev = gf(row, "elevation_arr")
        byr = gf(row, "temp_baseline_year_arr"); soff = gf(row, "temp_season_offset_arr")
        air = gf(row, "air_mass_temp_anomaly_arr"); tta = gf(row, "temperature_transport_anomaly_arr")
        dev = gf(row, "insolation_dev_arr")
        ty = max(0.0, min(1.0, byr-altpen(elev))) if not math.isnan(byr) and not math.isnan(elev) else float("nan")
        targ = max(0.0, min(1.0, ty+soff)) if not math.isnan(ty) and not math.isnan(soff) else float("nan")

        k = (band(lat), w, sb)
        a = pol[k]; a["n"] += 1; a["st"] += temp
        if temp > a["mx"]: a["mx"] = temp
        if temp < a["mn"]: a["mn"] = temp
        if not math.isnan(targ): a["starg"] += targ
        a["sair"] += air if not math.isnan(air) else 0.0
        a["stta"] += tta if not math.isnan(tta) else 0.0
        a["sdev"] += dev if not math.isnan(dev) else 0.0
        a["soff"] += soff if not math.isnan(soff) else 0.0

        if w == 1 and has_frac:
            frac = gf(row, "sea_ice_frac_arr")
            if math.isnan(frac): continue
            seaice_n += 1
            tb = tbucket[round(temp, 2)]; tb["n"] += 1; tb["sfrac"] += frac
            if frac >= 0.5: tb["nfrozen"] += 1
            if temp < FORM:
                if frac < 0.5: cold_no_ice += 1
                if frac < 0.05: cold_no_ice_any += 1
                if frac >= 0.5: cold_with_ice += 1
                if frac < 0.5:
                    cni_insol += gf(row, "insolation_now_arr") if has_insol else 0.0
                    cni_daylen += gf(row, "day_length_arr") if has_daylen else 0.0
                    cni_temp += temp; cni_lat += lat
                    if tick_col: cni_tick[gf(row, tick_col)] += 1

print("\n\n================= 问题2：极地/各带 按季节相位的温度 =================")
print("(season bucket: 0/1/2/3 = season_phase 落入的整数段; 注意南北半球季节相反)")
for w, wn in [(1, "海洋"), (0, "陆地")]:
    print(f"\n----- {wn} -----")
    print(f"{'band':>4}{'lat':>6}{'tag':>4}{'season':>7}{'n':>6}{'meanT':>7}{'maxT':>7}{'minT':>7}{'meanTarg':>9}{'air':>7}{'tta':>7}{'dev':>7}{'soff':>7}")
    for b in range(NB):
        lat_mid = (b+0.5)/NB; absd = abs(lat_mid-0.5)*2
        tag = "极" if absd > 0.7 else ("赤" if absd < 0.2 else "中")
        for s in range(4):
            a = pol[(b, w, s)]
            if a["n"] == 0: continue
            n = a["n"]
            print(f"{b:>4}{lat_mid:>6.2f}{tag:>4}{s:>7}{n:>6}{a['st']/n:>7.3f}{a['mx']:>7.3f}{a['mn']:>7.3f}{a['starg']/n:>9.3f}{a['sair']/n:>7.3f}{a['stta']/n:>7.3f}{a['sdev']/n:>7.3f}{a['soff']/n:>7.3f}")

print("\n\n================= 问题1：冷却但无海冰 =================")
print(f"海洋样本数={seaice_n}")
print(f"temp<{FORM}(form阈值) 的水体中: frac<0.5(无有效冰)={cold_no_ice}  frac<0.05(几乎无冰)={cold_no_ice_any}  frac>=0.5(已结冰)={cold_with_ice}")
if cold_no_ice > 0:
    print(f"  这些'冷却无冰'cell 平均: temp={cni_temp/cold_no_ice:.3f}  insol_now={cni_insol/cold_no_ice:.3f}  day_len={cni_daylen/cold_no_ice:.3f}  lat={cni_lat/cold_no_ice:.3f}")
    if tick_col:
        top = sorted(cni_tick.items(), key=lambda kv: -kv[1])[:8]
        print(f"  集中的 {tick_col}: " + ", ".join(f"{int(t)}:{c}" for t, c in top))

print("\n温度桶 → 平均海冰frac / 已结冰占比 (看 frac 是否随温度下降而上升):")
print(f"{'temp':>6}{'n':>7}{'meanFrac':>9}{'frozen%':>8}")
for t in sorted(tbucket.keys()):
    tb = tbucket[t]
    if tb["n"] < 5: continue
    print(f"{t:>6.2f}{tb['n']:>7}{tb['sfrac']/tb['n']:>9.3f}{100.0*tb['nfrozen']/tb['n']:>8.1f}")
