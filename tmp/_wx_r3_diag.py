"""第二轮(211009)综合诊断：
  ① vapor 是否已恢复(对比 R1，验证回滚 rh_condense 止住了抽干)
  ② "雨云停海上不往内陆"——风场诊断：海岸风 onshore(从海吹向陆,带云进来) vs offshore/沿岸；
     风速是否内陆衰减(低风速→adv_w=advect*(0.55+0.45*wind_mag) 弱→云水停滞)
  ③ 各 hop 分层状态(precip/vapor/cw/风速/wet%)
"""
import numpy as np
from collections import deque

import sys, os
V3 = sys.argv[1] if len(sys.argv) > 1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v4.npz'   # NEW(有辐合)
R1 = sys.argv[2] if len(sys.argv) > 2 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v3.npz'   # OLD(无辐合)对照


def load(path):
    z = np.load(path, allow_pickle=True)
    NC = int(z['NC']); ND = int(z['ND']); NB = z['NB']
    px = z['px'].astype(float); py = z['py'].astype(float)
    is_water = z['st_is_water_arr'] > 0.5
    d = lambda k: np.nan_to_num(z['dy_' + k].astype(float))
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
    return dict(NC=NC, ND=ND, NB=NB, px=px, py=py, is_water=is_water, hop=hop,
                cw=d('weather_cloud_water_arr'), vapor=d('weather_vapor_arr'),
                precip=d('weather_precip_arr'), wx=d('wind_x_arr'), wy=d('wind_y_arr'),
                wspd=d('wind_speed_arr'))


def layers(g, warm=40):
    cwm = g['cw'][warm:].mean(0); vm = g['vapor'][warm:].mean(0); pm = g['precip'][warm:].mean(0)
    wsm = g['wspd'][warm:].mean(0); hop = g['hop']
    wet = (g['precip'][warm:] > 0.02).mean(0); land = ~g['is_water']
    print(f'  land_dry={(wet[land] < 0.05).mean():.3f}  perma_rain={(wet > 0.80).mean():.3f}')
    print(f'  {"hop":>4}{"n":>6}{"precip":>9}{"vapor":>8}{"cw":>9}{"wspd":>8}{"wet%":>7}')
    for h in [0, 1, 2, 3, 4, 5]:
        m = hop == h
        if m.sum() < 3:
            continue
        print(f'  {h:>4}{int(m.sum()):>6}{pm[m].mean():>9.4f}{vm[m].mean():>8.3f}'
              f'{cwm[m].mean():>9.4f}{wsm[m].mean():>8.3f}{wet[m].mean() * 100:>6.1f}')


def wind_diag(g, warm=40):
    NC, NB, px, py, is_water, hop = g['NC'], g['NB'], g['px'], g['py'], g['is_water'], g['hop']
    wxm = g['wx'][warm:].mean(0); wym = g['wy'][warm:].mean(0)
    coast = np.where(hop == 1)[0]
    on = off = al = 0
    for c in coast:
        sx = sy = 0.0; nw = 0
        for k in range(6):
            nb = NB[c, k]
            if nb >= 0 and is_water[nb]:
                sx += px[nb] - px[c]; sy += py[nb] - py[c]; nw += 1
        if nw == 0:
            continue
        sl = (sx * sx + sy * sy) ** 0.5
        if sl < 1e-6:
            continue
        sx /= sl; sy /= sl               # 朝海单位向量
        wl = (wxm[c] ** 2 + wym[c] ** 2) ** 0.5
        if wl < 1e-6:
            al += 1; continue
        dot = (wxm[c] * sx + wym[c] * sy) / wl   # 风·朝海： <0=风朝陆(onshore,好)
        if dot < -0.3:
            on += 1
        elif dot > 0.3:
            off += 1
        else:
            al += 1
    tot = max(len(coast), 1)
    print(f'  海岸格={len(coast)}  onshore(风把云带进陆)={on}({on / tot * 100:.0f}%)  '
          f'offshore(风朝海,云进不来)={off}({off / tot * 100:.0f}%)  沿岸/弱风={al}({al / tot * 100:.0f}%)')
    # 全图平均风速 & 海/陆风速
    wsm = g['wspd'][warm:].mean(0)
    print(f'  风速: 海洋={wsm[is_water].mean():.3f}  陆地={wsm[~is_water].mean():.3f}  '
          f'(adv_w=advect*(0.55+0.45*min(ws/1.2,1)) — 风速越低平流越弱)')


print('=' * 72); print('NEW 有辐合: %s' % os.path.basename(V3)); print('=' * 72)
g3 = load(V3); layers(g3); print('[风场诊断]'); wind_diag(g3)
print(); print('=' * 72); print('OLD 无辐合对照: %s' % os.path.basename(R1)); print('=' * 72)
g1 = load(R1); layers(g1); print('[风场诊断]'); wind_diag(g1)
