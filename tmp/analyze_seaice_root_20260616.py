import csv, math, sys
from collections import defaultdict
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass

path = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260616_215851.csv"
with open(path, "r", encoding="utf-8-sig", newline="") as f:
    header = next(csv.reader(f))
idx = {n: i for i, n in enumerate(header)}
def gf(row, name):
    j = idx.get(name)
    if j is None: return float("nan")
    try: return float(row[j])
    except: return float("nan")

FORM, MELT = 0.14, 0.22
ICE_DELAY = 1.0

# ---- 第一遍：找几个极地/中纬水体 cell，并统计 was_skipped/dt 分布 ----
# 同时统计 temp<FORM 水体的 t_eff 分布
sample_cells = {}     # lat band -> cell_index
skipped = defaultdict(int)
teff_block = 0        # t_eff>=FORM 导致 diff_freeze=0 的占比
teff_total = 0
tta_pos = 0
big_tta = 0
sum_tta = 0.0
# t_eff 重新分桶
teff_bucket = defaultdict(lambda: dict(n=0, sfrac=0.0, nfroz=0))

# 收集 cell 的 lat（用首次出现）
cell_lat = {}

with open(path, "r", encoding="utf-8-sig", newline="") as f:
    r = csv.reader(f); next(r)
    for row in r:
        ws = gf(row, "was_skipped_day")
        # was_skipped 是每行重复的全局值，按 tick 去重统计意义不大，这里只看分布
        ci = gf(row, "cell_index")
        if math.isnan(ci): continue
        ci = int(ci)
        lat = gf(row, "cell_lat_norm_arr"); w = gf(row, "is_water_arr")
        if ci not in cell_lat and not math.isnan(lat):
            cell_lat[ci] = (lat, w)
        if w > 0.5:
            temp = gf(row, "temp_arr"); tta = gf(row, "temperature_transport_anomaly_arr")
            upw = gf(row, "upwelling_strength_arr"); frac = gf(row, "sea_ice_frac_arr")
            if math.isnan(temp) or math.isnan(frac): continue
            t_eff = temp
            if not math.isnan(tta) and tta > 0: t_eff += ICE_DELAY * tta
            if not math.isnan(upw) and upw > 0.3: t_eff -= 0.5*upw
            t_eff = max(0.0, min(1.0, t_eff))
            if temp < FORM:
                teff_total += 1
                if t_eff >= FORM: teff_block += 1
                if not math.isnan(tta) and tta > 0: tta_pos += 1
                if not math.isnan(tta) and tta > 0.05: big_tta += 1
                if not math.isnan(tta): sum_tta += tta
                tb = teff_bucket[round(t_eff,2)]; tb["n"]+=1; tb["sfrac"]+=frac
                if frac>=0.5: tb["nfroz"]+=1

print("================= 问题1 根因定位 =================")
print(f"temp<{FORM} 的水体样本: {teff_total}")
if teff_total>0:
    print(f"  其中 t_eff(含洋流加成) >= form阈值 → diff_freeze=0(完全无法结冰): {teff_block} ({100.0*teff_block/teff_total:.1f}%)")
    print(f"  tta>0(暖流抬升)占比: {100.0*tta_pos/teff_total:.1f}%   tta>0.05: {100.0*big_tta/teff_total:.1f}%   mean tta={sum_tta/teff_total:.4f}")
print("\nt_eff(含洋流加成) 重新分桶 → 海冰frac (对比之前按 temp 分桶):")
print(f"{'t_eff':>6}{'n':>7}{'meanFrac':>9}{'frozen%':>8}")
for t in sorted(teff_bucket.keys()):
    tb=teff_bucket[t]
    if tb["n"]<20: continue
    print(f"{t:>6.2f}{tb['n']:>7}{tb['sfrac']/tb['n']:>9.3f}{100.0*tb['nfroz']/tb['n']:>8.1f}")

# ---- 选定 cell 做时间序列 ----
# 找 band0(lat~0.05) / band1(0.15) / band8(0.85) 的水体 cell
picks = {}
for ci,(lat,w) in cell_lat.items():
    if w<=0.5: continue
    for tgt,name in [(0.07,"北极水"),(0.16,"近北极水"),(0.85,"南近极水")]:
        if abs(lat-tgt)<0.02 and name not in picks:
            picks[name]=ci
print("\n选定时间序列 cell:", {k:(v, round(cell_lat[v][0],3)) for k,v in picks.items()})

series = {name: [] for name in picks}
want = set(picks.values())
with open(path, "r", encoding="utf-8-sig", newline="") as f:
    r = csv.reader(f); next(r)
    for row in r:
        ci = gf(row,"cell_index")
        if math.isnan(ci) or int(ci) not in want: continue
        ci=int(ci)
        rec = dict(tick=gf(row,"tick_idx"), temp=gf(row,"temp_arr"),
                   frac=gf(row,"sea_ice_frac_arr"), insol=gf(row,"insolation_now_arr"),
                   tta=gf(row,"temperature_transport_anomaly_arr"),
                   soff=gf(row,"temp_season_offset_arr"), sp=gf(row,"phys_daily_wind_season_phase"))
        for name,c in picks.items():
            if c==ci: series[name].append(rec)

for name in picks:
    s = series[name]
    if not s: continue
    s.sort(key=lambda x:x["tick"])
    # 每 ~12 行采样一次打印，避免太长
    step = max(1, len(s)//28)
    print(f"\n----- {name} cell#{picks[name]} (lat={cell_lat[picks[name]][0]:.3f}) 时间序列 -----")
    print(f"{'tick':>6}{'sp':>5}{'temp':>6}{'soff':>6}{'insol':>6}{'tta':>6}{'frac':>6}")
    for k in range(0,len(s),step):
        x=s[k]
        print(f"{x['tick']:>6.0f}{x['sp']:>5.2f}{x['temp']:>6.3f}{x['soff']:>6.3f}{x['insol']:>6.3f}{x['tta']:>6.3f}{x['frac']:>6.3f}")
