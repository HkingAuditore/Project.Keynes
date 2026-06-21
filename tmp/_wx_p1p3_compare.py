"""P1 温差季节反转 + P3 内陆湿润 修复前后对比图(英文标签避免字体问题)。"""
import numpy as np, matplotlib, warnings
warnings.filterwarnings('ignore')
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from collections import deque

V8 = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v8.npz'
V7 = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_v7.npz'


def p1_bands(npz):
    z = np.load(npz, allow_pickle=True)
    py = z['py'].astype(float); is_water = z['st_is_water_arr'] > 0.5
    warm = 40
    dy = lambda k: z['dy_' + k].astype(float)
    temp = dy('temp_arr')[warm:]; dev = dy('insolation_dev_arr')[warm:]; base = dy('temp_baseline_arr')[warm:]
    good = (base > 0.3) & np.isfinite(temp) & np.isfinite(dev)
    devg = np.where(good, dev, np.nan)
    dlo = np.nanpercentile(devg, 33, axis=0); dhi = np.nanpercentile(devg, 67, axis=0)
    wm = good & (dev >= dhi[None, :]); cm = good & (dev <= dlo[None, :])
    def sm(m):
        den = m.sum(0); num = np.where(m, temp, 0.0).sum(0)
        return np.where(den > 5, num / np.maximum(den, 1), np.nan)
    warmT, coldT = sm(wm), sm(cm)
    ny = (py - py.min()) / (py.max() - py.min() + 1e-9)
    b, wd, cd = [], [], []
    for k in range(10):
        lo, hi = k / 10, (k + 1) / 10
        mb = (ny >= lo) & (ny < hi); L = mb & ~is_water; S = mb & is_water
        b.append((lo + hi) / 2)
        if L.sum() < 5 or S.sum() < 5:
            wd.append(np.nan); cd.append(np.nan); continue
        wd.append(np.nanmean(warmT[L]) - np.nanmean(warmT[S]))
        cd.append(np.nanmean(coldT[L]) - np.nanmean(coldT[S]))
    return np.array(b), np.array(wd), np.array(cd)


def hop_wet(npz):
    z = np.load(npz, allow_pickle=True)
    NC = int(z['NC']); NB = z['NB']; is_water = z['st_is_water_arr'] > 0.5
    ND = int(z['ND']); warm = 40 if ND >= 80 else max(2, ND // 4)
    precip = np.nan_to_num(z['dy_weather_precip_arr'].astype(float))
    wet = (precip[warm:] > 0.02).mean(0)
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
    xs, ws = [], []
    for h in range(0, 9):
        m = (hop == h) if h < 8 else (hop >= 8)
        if m.sum() < 3:
            continue
        xs.append(h); ws.append(wet[m].mean() * 100)
    return np.array(xs), np.array(ws)


b, wd, cd = p1_bands(V8)
x7, w7 = hop_wet(V7); x8, w8 = hop_wet(V8)

fig, ax = plt.subplots(1, 2, figsize=(14, 5))
W = 0.035
ax[0].bar(b - W / 2, wd, W, label='warm season (land - sea)', color='tab:red')
ax[0].bar(b + W / 2, cd, W, label='cold season (land - sea)', color='tab:blue')
ax[0].axhline(0, color='k', lw=0.8)
ax[0].set_xlabel('latitude band  (ny: 0=south, 1=north)')
ax[0].set_ylabel('land - sea temperature diff')
ax[0].set_title('P1 FIXED: seasonal reversal\n(warm: land>sea, cold: land<sea)')
ax[0].legend()
ax[1].plot(x7, w7, 'o--', color='gray', label='before (v7)')
ax[1].plot(x8, w8, 'o-', color='tab:green', label='after P1+P2 (v8)')
ax[1].set_xlabel('hops from nearest ocean')
ax[1].set_ylabel('wet-day %')
ax[1].set_title('P3 IMPROVED: inland wet-day %\n(land perma_dry 76.5% -> 61.0%)')
ax[1].legend()
fig.tight_layout()
out = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_p1p3_compare.png'
fig.savefig(out, dpi=120)
print('[OK]', out)
