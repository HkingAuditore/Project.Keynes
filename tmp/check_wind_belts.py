"""风带验收检查（wind-belt-lat-fix 2026-08-03）。

用法：
    python tmp/check_wind_belts.py tmp/tile_data_record_YYYYMMDD_HHMMSS.csv

判定的四件事（每项独立 PASS/FAIL）：
  1. 纬度输入是否恢复：水体风速应该重现风带四档 (ITCZ .15 / 信风 .85 / 西风 1.10 / 极地 .65)，
     而不是恒定 0.65。这是 ny 单位错配的直接指纹。
  2. 三圈环流是否成形：低纬东风(信风) / 中纬西风 / 极地东风，符号要和 wind_belt.gd 一致。
  3. 风带是否沿纬线：纬向风 u 的方差应由纬度(行)主导，而不是经度(列)。
  4. 时变性：方向恒定度 |mean(单位风矢量)| 中位数应落在地球量级 (中纬 0.3~0.6)，
     而不是 0.95+。

纬度约定：cell_lat_norm = row/(height-1)，0 = 第 0 行，0.5 = 赤道，1 = 末行。
lat_signed = (ny-0.5)*2；abs_lat 分带界：ITCZ<0.05、信风<0.40、西风<0.70、其余极地。
"""

import csv
import math
import statistics
import sys
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else r'tmp/tile_data_record_20260803_212031.csv'

WANT = ['tick_idx', 'cell_index', 'q', 'r', 'cell_lat_norm_arr',
        'wind_x_arr', 'wind_y_arr', 'wind_speed_arr', 'is_water_arr',
        'ocean_current_x_arr', 'ocean_current_y_arr']


def smoothstep(a, b, x):
    if abs(b - a) < 1e-12:
        return 1.0 if x >= a else 0.0
    t = (x - a) / (b - a)
    t = 0.0 if t < 0 else (1.0 if t > 1 else t)
    return t * t * (3.0 - 2.0 * t)


def belt_u_and_speed(ny):
    """镜像 wind_belt.gd / world_ext_internal.h::wind_belt_at + wind_belt_speed_at。"""
    ls = (ny - 0.5) * 2.0
    al = abs(ls)
    sl = -1.0 if ls < -0.001 else 1.0
    # 方向用半带宽 0.06
    wi = 1.0 - smoothstep(0.05 - 0.06, 0.05 + 0.06, al)
    wt = smoothstep(0.05 - 0.06, 0.05 + 0.06, al) * (1.0 - smoothstep(0.40 - 0.06, 0.40 + 0.06, al))
    ww = smoothstep(0.40 - 0.06, 0.40 + 0.06, al) * (1.0 - smoothstep(0.70 - 0.06, 0.70 + 0.06, al))
    wp = smoothstep(0.70 - 0.06, 0.70 + 0.06, al)
    bx = wi * -0.20 + wt * -1.0 + ww * 1.0 + wp * -1.0
    by = wt * (-0.20 * sl) + ww * (0.10 * sl) + wp * (-0.20 * sl)
    n = math.hypot(bx, by)
    u = bx / n if n > 0.01 else 1.0
    # 速度用半带宽 0.03/0.04
    si = 1.0 - smoothstep(0.05 - 0.03, 0.05 + 0.03, al)
    st = smoothstep(0.05 - 0.03, 0.05 + 0.03, al) * (1.0 - smoothstep(0.40 - 0.04, 0.40 + 0.04, al))
    sw = smoothstep(0.40 - 0.04, 0.40 + 0.04, al) * (1.0 - smoothstep(0.70 - 0.04, 0.70 + 0.04, al))
    sp = smoothstep(0.70 - 0.04, 0.70 + 0.04, al)
    spd = si * 0.15 + st * 0.85 + sw * 1.10 + sp * 0.65
    return u, spd


def band_of(ny):
    al = abs((ny - 0.5) * 2.0)
    if al < 0.05:
        return 'ITCZ'
    if al < 0.40:
        return '信风(东风)'
    if al < 0.70:
        return '西风'
    return '极地东风'


f = open(PATH, newline='', encoding='utf-8-sig')
rd = csv.reader(f)
hdr = next(rd)
ix = {k: hdr.index(k) for k in WANT}

series = defaultdict(list)
snap_by_tick = defaultdict(dict)
oc_states = defaultdict(set)
for row in rd:
    t = int(row[ix['tick_idx']])
    c = int(row[ix['cell_index']])
    u, v = float(row[ix['wind_x_arr']]), float(row[ix['wind_y_arr']])
    series[c].append((t, u, v))
    oc_states[c].add((row[ix['ocean_current_x_arr']], row[ix['ocean_current_y_arr']]))
    snap_by_tick[t][c] = (int(row[ix['r']]), float(row[ix['cell_lat_norm_arr']]), u, v,
                          float(row[ix['wind_speed_arr']]),
                          row[ix['is_water_arr']].strip().lower() in ('1', 'true'),
                          int(row[ix['q']]))
f.close()

LT = max(snap_by_tick)
snap = snap_by_tick[LT]
height = max(d[0] for d in snap.values()) + 1
width = max(d[6] + (d[0] - (d[0] & 1)) // 2 for d in snap.values()) + 1
print('文件 %s' % PATH)
print('cell=%d  tick=%d  推断网格=%dx%d  分析 tick=%d'
      % (len(snap), len(snap_by_tick), width, height, LT))

# 采样充分性：第 4 项测的是「一年之内风向变不变」，而风场 pass 远不是每 tick 跑一次
# （earth_like 下每 12 个游戏日才跑一次）。tick 数多≠独立样本多：真正的样本数是每个
# cell 出现过的不同风向数。样本太少时恒定度必然虚高，第 4 项不具判定力。
_upd = sorted(len({(u, v) for _, u, v in s}) for s in series.values())
_upd_med = _upd[len(_upd) // 2]
print('风场独立更新次数(每 cell 不同风向数)中位=%d  %s'
      % (_upd_med,
         'OK' if _upd_med >= 30 else
         '**样本不足**：第 4 项(时变性)不具判定力，需录到 >=30 次更新'
         '（约 %d 个游戏日，按每 12 日一次估）' % (30 * 12)))
print()
results = []

# ── 1. 风速四档（ny 单位指纹）───────────────────────────────────────────
water_spd = defaultdict(list)
for c, d in snap.items():
    if d[5]:
        water_spd[d[0]].append(d[4])
if water_spd:
    obs = {r: statistics.mean(v) for r, v in water_spd.items()}
    pred = {r: belt_u_and_speed(r / (height - 1))[1] for r in obs}
    rs = sorted(obs)
    mo = statistics.mean(obs.values())
    mp = statistics.mean(pred[r] for r in rs)
    no = sum((obs[r] - mo) ** 2 for r in rs) ** .5
    np_ = sum((pred[r] - mp) ** 2 for r in rs) ** .5
    cc = sum((obs[r] - mo) * (pred[r] - mp) for r in rs) / (no * np_ + 1e-12)
    lo = min(obs.values())
    ok = cc > 0.35
    results.append(('1. 纬度输入(风速四档)', ok,
                    '逐行相关=%+.3f (需>0.35)  水体风速下限=%.3f' % (cc, lo)))
    if abs(lo - 0.650) < 0.01:
        results[-1] = (results[-1][0], False,
                       results[-1][2] + '  <-- 下限恰为 SPEED_POLAR=0.650，ny 仍退化为全图极地！')

# ── 2. 三圈环流符号 ────────────────────────────────────────────────────
prof = defaultdict(list)
for c, d in snap.items():
    prof[d[0]].append(d[2])
bad = tot = 0
print('纬向平均风逐行剖面：')
print('  row  lat_signed  应有风带      模型u    实测u     东风占比  判定')
for r in sorted(prof):
    ny = r / (height - 1)
    pu, _ = belt_u_and_speed(ny)
    us = prof[r]
    mu = statistics.mean(us)
    ep = sum(1 for x in us if x > 0) / len(us) * 100
    if abs(pu) < 0.2:
        continue
    tot += 1
    good = pu * mu > 0
    if not good:
        bad += 1
    if r % 4 == 0:
        print('  %3d   %+.3f     %-11s  %+.2f   %+.4f   %5.1f%%    %s'
              % (r, (ny - 0.5) * 2, band_of(ny), pu, mu, ep, 'OK' if good else '**反了**'))
if tot:
    frac = bad / tot
    results.append(('2. 三圈环流符号', frac < 0.25,
                    '符号相反的行 %d/%d = %.0f%% (需<25%%)' % (bad, tot, frac * 100)))

# ── 3. 风带走向：纬度 vs 经度方差 ──────────────────────────────────────
by_row = defaultdict(list)
by_col = defaultdict(list)
for c, d in snap.items():
    r = d[0]
    col = d[6] + (r - (r & 1)) // 2
    by_row[r].append(d[2])
    by_col[col].append(d[2])
allu = [d[2] for d in snap.values()]
gm = statistics.mean(allu)
tv = sum((x - gm) ** 2 for x in allu)
br = sum(len(v) * (statistics.mean(v) - gm) ** 2 for v in by_row.values()) / tv
bc = sum(len(v) * (statistics.mean(v) - gm) ** 2 for v in by_col.values()) / tv
results.append(('3. 风带沿纬线', br > bc * 1.5,
                '纬向风 u：纬度解释 %.1f%% vs 经度 %.1f%% (需纬度 >1.5x 经度)'
                % (br * 100, bc * 100)))

# ── 4. 时变性 ──────────────────────────────────────────────────────────
cons = []
midlat = []
for c, s in series.items():
    if len(s) < 3:
        continue
    cx = statistics.mean(x[1] for x in s)
    cy = statistics.mean(x[2] for x in s)
    k = math.hypot(cx, cy)
    cons.append(k)
    if c in snap:
        al = abs((snap[c][0] / (height - 1) - 0.5) * 2.0)
        if 0.40 <= al < 0.70:
            midlat.append(k)
cons.sort()
med = statistics.median(cons)
med_mid = statistics.median(midlat) if midlat else float('nan')
results.append(('4. 时变性(方向恒定度)', med_mid < 0.80,
                '全图中位=%.3f  中纬度中位=%.3f (地球中纬 0.3~0.6，需<0.80)  >0.99 占比=%.1f%%'
                % (med, med_mid, sum(1 for x in cons if x > 0.99) / len(cons) * 100)))

# ── 附加：洋流静止度（无阈值，仅报告）────────────────────────────────
water = [c for c, d in snap.items() if d[5]]
if water:
    frozen = sum(1 for c in water if len(oc_states[c]) == 1) / len(water) * 100
    mags = sorted(math.hypot(*map(float, list(oc_states[c])[-1])) for c in water)
    still = sum(1 for m in mags if m < 1e-4) / len(mags) * 100
    print()
    print('附加（仅报告）洋流：全程单值 %.1f%%   量级<1e-4 %.1f%%   中位量级 %.4f'
          % (frozen, still, mags[len(mags) // 2]))

print()
print('=' * 78)
for name, ok, detail in results:
    print('  [%s] %-22s %s' % ('PASS' if ok else 'FAIL', name, detail))
print('=' * 78)
print('总体：%s' % ('全部通过' if all(r[1] for r in results) else '仍有 FAIL，见上'))
