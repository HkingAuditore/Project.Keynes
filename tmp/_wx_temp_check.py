import numpy as np
from collections import deque
z = np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v6.npz', allow_pickle=True)
NC = int(z['NC']); NB = z['NB']; is_water = z['st_is_water_arr'] > 0.5
temp = np.nan_to_num(z['dy_temp_arr'].astype(float))
vap = np.nan_to_num(z['dy_weather_vapor_arr'].astype(float))
elev = np.nan_to_num(z['st_elevation_arr'].astype(float))
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
inl = (hop >= 3) & (~is_water)
ti = temp[:, inl].mean(1)
print('inland mean-temp: year=%.3f summerPeak=%.3f winterLow=%.3f' % (ti.mean(), ti.max(), ti.min()))
pk = int(ti.argmax())
tp = temp[pk, inl]
cap = np.clip(0.18 + 0.82 * tp - 0.18 * elev[inl], 0.14, 1.0)
rhp = vap[pk, inl] / np.clip(cap, 0.001, None)
print('inland summer-day temp pctile[50,75,90,99]:', np.round(np.percentile(tp, [50, 75, 90, 99]), 3))
print('inland summer-day rh   pctile[50,75,90,99]:', np.round(np.percentile(rhp, [50, 75, 90, 99]), 3))
print('inland-summer temp>0.45: %.1f%%   temp>0.55: %.1f%%   temp>0.65: %.1f%%' %
      ((tp > 0.45).mean() * 100, (tp > 0.55).mean() * 100, (tp > 0.65).mean() * 100))
# 热力对流候选：温度高且有起码水汽(rh>0.12) 的内陆夏季格占比
conv_cand = ((tp > 0.45) & (rhp > 0.12)).mean() * 100
print('inland-summer 热力对流候选(temp>0.45 & rh>0.12): %.1f%%' % conv_cand)
