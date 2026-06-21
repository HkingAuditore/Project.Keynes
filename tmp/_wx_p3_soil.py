"""P3 soil_moisture 干旱诊断: 内陆/河流旁为何 soil 大旱。
- soil 时间演化幅度: ≈0 → soil 冻结(初值卡住,不随降水/河流变)。
- soil by hop: 内陆土壤湿度随离海距离衰减?
- 河流格 vs 河流邻居 vs 普通内陆 soil 对比 → 河流是否给邻近土壤补水。
- soil ~ precip / discharge / elev / hop 相关 → soil 由什么驱动。
"""
import numpy as np, sys
from collections import deque
NPZ = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v9.npz'
z = np.load(NPZ, allow_pickle=True)
NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']; warm = 40 if ND >= 80 else max(2, ND // 4)
is_water = z['st_is_water_arr'] > 0.5; land = ~is_water
has_river = z['st_has_river_arr'] > 0.5
elev = z['st_elevation_arr'].astype(float)
dy = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
soil = dy('soil_moisture_arr')[warm:]
disch = dy('river_discharge_30d_arr')[warm:]
precip = dy('weather_precip_arr')[warm:]
T = soil.shape[0]
sm = soil.mean(0); pm = precip.mean(0); dm = disch.mean(0)
soil_amp = soil.max(0) - soil.min(0)

print(f'NPZ={NPZ.split(chr(92))[-1]} T={T} land={int(land.sum())} river_cells={int((has_river & land).sum())}')
print(f'soil 全局: 陆地均={sm[land].mean():.3f} 海洋均={sm[is_water].mean():.3f} 陆地中位={np.median(sm[land]):.3f}')
print(f'soil 时间演化幅度(陆地 max-min 均)={soil_amp[land].mean():.4f}  (≈0 → soil 冻结,不随天气变)')

hop = np.full(NC, -1, int); dq = deque()
for c in range(NC):
    if is_water[c]:
        hop[c] = 0; dq.append(c)
while dq:
    c = dq.popleft()
    for k in range(6):
        nb = NB[c, k]
        if nb >= 0 and hop[nb] < 0:
            hop[nb] = hop[c] + 1; dq.append(nb)

print('\n=== soil_moisture by hop(离海) ===')
print(f'{"hop":>4}{"n":>6}{"soil":>8}{"precip":>9}{"disch":>9}{"elev":>7}')
for h in range(0, 9):
    m = (hop == h) if h < 8 else (hop >= 8)
    if m.sum() < 3:
        continue
    print(f'{h:>4}{int(m.sum()):>6}{sm[m].mean():>8.3f}{pm[m].mean():>9.4f}{dm[m].mean():>9.4f}{elev[m].mean():>7.3f}')

river = has_river & land
river_nb = np.zeros(NC, bool)
for c in range(NC):
    if land[c] and not has_river[c]:
        for k in range(6):
            nb = NB[c, k]
            if nb >= 0 and has_river[nb]:
                river_nb[c] = True; break
plain = land & (~has_river) & (~river_nb)
print('\n=== 河流是否补给邻近土壤? ===')
for label, m in [('河流格', river), ('河流邻居格', river_nb & land), ('普通内陆', plain)]:
    if m.sum() < 3:
        continue
    print(f'  {label:>8}: n={int(m.sum()):>5} soil={sm[m].mean():.3f} precip={pm[m].mean():.4f} disch={dm[m].mean():.4f} soil<0.2占比={ (sm[m] < 0.2).mean()*100:.1f}%')

print('\n=== soil 由什么驱动(陆地相关) ===')
lm = land
print(f'  soil ~ precip    = {np.corrcoef(sm[lm], pm[lm])[0, 1]:+.3f}  (高=跟降水)')
print(f'  soil ~ discharge = {np.corrcoef(sm[lm], dm[lm])[0, 1]:+.3f}  (高=河流补给有效)')
print(f'  soil ~ elevation = {np.corrcoef(sm[lm], elev[lm])[0, 1]:+.3f}')
print(f'  soil ~ (-hop)    = {np.corrcoef(sm[lm], -hop[lm].astype(float))[0, 1]:+.3f}  (正=近海湿/内陆干)')
print(f'\n陆地 soil<0.2占比={ (sm[land] < 0.2).mean()*100:.1f}%  soil<0.1占比={ (sm[land] < 0.1).mean()*100:.1f}%  河流格 soil<0.2占比={ (sm[river] < 0.2).mean()*100:.1f}%')
