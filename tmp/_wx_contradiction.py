"""诊断"矛盾":天气几乎都在降水,但湿度仍普遍偏干。
核心问题:moisture += moisture_delta*intensity + precip*0.35 (无衰减,line2585)。
若真'几乎都在降水',moisture应冲到1.0;它却停在低位 -> 要么'假降水'(分类门太低,小雨判RAIN),要么precip实际很小。
"""
import numpy as np, sys
from collections import deque
NPZ  = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v12.npz'
PREV = sys.argv[2] if len(sys.argv) > 2 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v11.npz'

def load(path):
    z = np.load(path, allow_pickle=True)
    NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
    warm = 40 if ND >= 80 else max(2, ND // 4)
    is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
    has_river = z['st_has_river_arr'] > 0.5
    hop = np.full(NC, -1, int); dq = deque()
    for c in range(NC):
        if is_water[c]: hop[c] = 0; dq.append(c)
    while dq:
        c = dq.popleft()
        for k in range(6):
            nb = NB[c, k]
            if nb >= 0 and hop[nb] < 0: hop[nb] = hop[c] + 1; dq.append(nb)
    dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))[warm:]
    return dict(z=z, NC=NC, ND=ND, warm=warm, is_water=is_water, land=land,
               has_river=has_river, hop=hop, dy=dy)

names = {0: 'CLEAR', 1: 'RAIN', 2: 'STORM', 3: 'BLIZZARD', 4: 'DROUGHT', 5: 'FOG', 6: 'HEATWAVE', 7: 'MONSOON'}
WET = {1, 2, 7}  # RAIN/STORM/MONSOON = "在降水"

d = load(NPZ)
land = d['land']; river = land & d['has_river']; hop = d['hop']; coast = land & (hop == 1)
print(f'=== v12 (land_evap=1.6) NPZ={NPZ.split(chr(92))[-1]} ND={d["ND"]} land={int(land.sum())} ===')
print('字段:', sorted(d['z'].files))

# moisture 字段自动探测 (每日优先)
mkey = 'moisture_arr' if 'dy_moisture_arr' in d['z'].files else None
wt = d['dy']('weather_type_arr').astype(int)
precip = d['dy']('weather_precip_arr')
vapor = d['dy']('weather_vapor_arr')
cloudw = d['dy']('weather_cloud_water_arr')
cloud = d['dy']('weather_cloud_arr')
soil = d['dy']('soil_moisture_arr')
moist = d['dy']('moisture_arr') if mkey else None

wtL = wt[:, land]; ppL = precip[:, land]

print('\n=== [1] 陆地天气类型分布 (量化"几乎都在降水") ===')
wet_occ = 0.0
for k, nm in names.items():
    m = wtL == k
    occ = m.mean() * 100
    if occ < 0.05: continue
    mean_pp = ppL[m].mean() if m.any() else 0
    med_pp = np.median(ppL[m]) if m.any() else 0
    flag = ' <-降水类' if k in WET else ''
    print(f'  {nm:>8}: 时占比{occ:5.1f}%  precip均值={mean_pp:.4f} 中位={med_pp:.4f}{flag}')
    if k in WET: wet_occ += occ
print(f'  >>> 降水类(RAIN+STORM+MONSOON)合计时占比 = {wet_occ:.1f}%')
print(f'  >>> precip>0.02 的格-天占比 = {(ppL > 0.02).mean()*100:.1f}%   precip>0.05 = {(ppL > 0.05).mean()*100:.1f}%')

print('\n=== [2] "假降水"检验: RAIN格的precip量级分布 (陆地) ===')
for k in (1, 2, 7):
    m = wtL == k
    if m.sum() < 10: continue
    pp = ppL[m]
    print(f'  {names[k]:>8}: p10/25/50/75/90 = {np.percentile(pp,10):.4f}/{np.percentile(pp,25):.4f}/{np.percentile(pp,50):.4f}/{np.percentile(pp,75):.4f}/{np.percentile(pp,90):.4f}')
print('  (参考:分类门 陆地RAIN第二档 precip>0.022。若中位≈0.022-0.03 => 大量"刚过门的小雨"被显示成RAIN)')

print('\n=== [3] 湿度是否真低 (陆地 p10/50/90), 对比 v11 ===')
dp = load(PREV)
landp = dp['land']
def cmp_field(name, cur2d, prevkey, transform=lambda x: x):
    cur = transform(cur2d).mean(0)  # 每格时间均值
    try:
        prev = transform(dp['dy'](prevkey)).mean(0)
        pstr = f'{np.percentile(prev[landp],50):.3f}'
    except Exception:
        pstr = 'n/a'
    print(f'  {name:26}: v12 陆地 p10/50/90={np.percentile(cur[land],10):.3f}/{np.percentile(cur[land],50):.3f}/{np.percentile(cur[land],90):.3f}'
          f'  河边={cur[river].mean():.3f}  |  v11中位={pstr}')
if moist is not None:
    cmp_field('moisture_arr(地块湿度)', moist, 'moisture_arr')
cmp_field('soil实际(0.5+距平)', soil, 'soil_moisture_arr', lambda x: 0.5 + x)
cmp_field('weather_vapor(大气水汽)', vapor, 'weather_vapor_arr')
cmp_field('weather_cloud_water', cloudw, 'weather_cloud_water_arr')
cmp_field('weather_cloud(云量)', cloud, 'weather_cloud_arr')

print('\n=== [M] 动态moisture(=湿度图层HUMIDITY显示的cell.moisture)时间演化 ===')
if moist is not None:
    mL = moist[:, land]; T = mL.shape[0]
    print(f'  陆地中位: 第1天={np.median(mL[0]):.3f}  1/4程={np.median(mL[max(1,T//4)]):.3f}  半程={np.median(mL[T//2]):.3f}  末天={np.median(mL[-1]):.3f}')
    print(f'  全程陆地 p10/50/90={np.percentile(mL,10):.3f}/{np.percentile(mL,50):.3f}/{np.percentile(mL,90):.3f}')
    for h in [1, 2, 4, 6, 8]:
        m = (hop == h) if h < 8 else (hop >= 8)
        if m.sum() < 3: continue
        print(f'    hop{h}: 第1天中位={np.median(moist[0, m]):.3f}  末天中位={np.median(moist[-1, m]):.3f}')
    print(f'  [对照] soil实际(0.5+距平)末天陆地中位={np.median((0.5 + soil[-1])[land]):.3f}')
    print('  (若末天≈第1天且≈0.33 => cell.moisture没被天气更新写回 => 湿度图层=静态地形湿度,与动态天气脱节,这就是"矛盾")')

print('\n=== [4] 矛盾交叉: 按moisture分桶,看各桶的"在降水"比例+precip ===')
if moist is not None:
    mflat = moist[:, land].ravel(); wflat = wtL.ravel(); pflat = ppL.ravel()
    iswet = np.isin(wflat, list(WET))
    for lo, hi in [(0.0,0.25),(0.25,0.4),(0.4,0.55),(0.55,0.7),(0.7,1.01)]:
        sel = (mflat >= lo) & (mflat < hi)
        if sel.sum() < 50: continue
        print(f'  moisture[{lo:.2f},{hi:.2f}): 占比{sel.mean()*100:5.1f}%  其中降水类{iswet[sel].mean()*100:5.1f}%  precip均值={pflat[sel].mean():.4f}')
    print('  (若低moisture桶里"降水类"比例仍很高 => 下雨没能把地块浇湿,即假降水/补充不敌抽干)')

print('\n=== [5] 内陆雨日% by hop (precip>0.02), 对比v11 ===')
ppp = dp['dy']('weather_precip_arr'); hopp = dp['hop']
for h in range(1, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    mp = (hopp == h) if h < 8 else (hopp >= 8)
    if m.sum() < 3: continue
    wet = (precip[:, m] > 0.02).mean() * 100
    wetp = (ppp[:, mp] > 0.02).mean() * 100 if mp.sum() >= 3 else float('nan')
    print(f'  hop{h}: v12雨日 {wet:5.1f}% (precip均{precip[:,m].mean():.4f})   | v11雨日 {wetp:5.1f}%')
