"""诊断：风向为何仍然常年不变。

问题：max_turn 已放开（wind_elapsed_days），所以若风向仍恒定，一定是 *目标方向* 恒定。
目标 = lat_w·v_base(静态) + pressure_w·v_grad(−∇SLP) + 海风(静态几何)。
故只需看 SLP 的「时间变化」相对「空间梯度」有多大 —— 时间项太弱就必然钉死风向。
"""
import csv
import math
import statistics
import sys
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else r'tmp/tile_data_record_20260803_215229.csv'
WIDTH, HEIGHT = 100, 64

WANT = ['tick_idx', 'cell_index', 'q', 'r', 'slp_arr', 'cell_lat_norm_arr',
        'wind_x_arr', 'wind_y_arr', 'phys_sim_day', 'phys_daily_wind_dir_delta_p95',
        'cell_pos_x_arr', 'cell_pos_y_arr']
f = open(PATH, newline='', encoding='utf-8-sig')
rd = csv.reader(f)
hdr = next(rd)
ix = {k: hdr.index(k) for k in WANT}
slp_ser = defaultdict(list)
wind_ser = defaultdict(list)
grid = {}
ticks = {}
for row in rd:
    t = int(row[ix['tick_idx']])
    c = int(row[ix['cell_index']])
    slp_ser[c].append((t, float(row[ix['slp_arr']])))
    wind_ser[c].append((t, float(row[ix['wind_x_arr']]), float(row[ix['wind_y_arr']])))
    ticks[t] = (row[ix['phys_sim_day']], row[ix['phys_daily_wind_dir_delta_p95']])
    if c not in grid:
        r = int(row[ix['r']])
        grid[c] = (int(row[ix['q']]) + (r - (r & 1)) // 2, r,
                   float(row[ix['cell_pos_x_arr']]), float(row[ix['cell_pos_y_arr']]))
f.close()

print('tick 数=%d  cell=%d' % (len(ticks), len(grid)))
sd = sorted({int(float(v[0])) for v in ticks.values() if v[0] not in ('', 'null')})
print('phys_sim_day 出现过的值: %s%s' % (sd[:18], ' ...' if len(sd) > 18 else ''))
print('  -> 单调且逐日推进? %s' % ('是' if len(sd) > 5 and sd[-1] - sd[0] >= len(sd) - 1 else '否/可疑'))
dd = sorted({v[1] for v in ticks.values()})
print('phys_daily_wind_dir_delta_p95 不同取值数=%d: %s' % (len(dd), dd[:8]))
print()

# ── SLP 时间变化 vs 空间梯度 ────────────────────────────────────────────
last = max(ticks)
snap = {c: dict(s)[last] for c, s in slp_ser.items() if last in dict(s)}
byid = {(g[0], g[1]): c for c, g in grid.items()}
NB_E = [(1, 0), (0, -1), (-1, -1), (-1, 0), (-1, 1), (0, 1)]
NB_O = [(1, 0), (1, -1), (0, -1), (-1, 0), (0, 1), (1, 1)]
sp_grad = []
for (col, r), c in byid.items():
    if c not in snap:
        continue
    for dc, dr in (NB_O if (r & 1) else NB_E):
        nr = r + dr
        if nr < 0 or nr >= HEIGHT:
            continue
        n = byid.get(((col + dc) % WIDTH, nr))
        if n is not None and n in snap:
            sp_grad.append(abs(snap[n] - snap[c]))
tmp_var = []
for c, s in slp_ser.items():
    v = [x[1] for x in sorted(set(s))]
    if len(v) > 2:
        tmp_var.append(statistics.pstdev(v))
sp_grad.sort()
tmp_var.sort()


def pc(l, p):
    return l[min(len(l) - 1, int(len(l) * p))]


print('SLP 相邻格空间差 |Δslp|: 中位=%.5f p90=%.5f' % (pc(sp_grad, .5), pc(sp_grad, .9)))
print('SLP 逐 cell 时间标准差:   中位=%.5f p90=%.5f' % (pc(tmp_var, .5), pc(tmp_var, .9)))
ratio = pc(tmp_var, .5) / max(1e-9, pc(sp_grad, .5))
print('时间/空间 比 = %.2f' % ratio)
print('  -> 要让风向逐日改变，时间扰动须能与相邻格空间差相抗；比值 <<1 则风向被静态场钉死')
print()

# ── SLP 时间变化里，纬向(静态)成分占多少 ────────────────────────────────
# 把每个 cell 的 slp 时间均值按行平均 = 纬向静态基线；看它解释了多少总空间方差
mean_by_cell = {}
for c, s in slp_ser.items():
    v = [x[1] for x in sorted(set(s))]
    mean_by_cell[c] = statistics.mean(v)
by_row = defaultdict(list)
for c, m in mean_by_cell.items():
    by_row[grid[c][1]].append(m)
allm = list(mean_by_cell.values())
gm = statistics.mean(allm)
tot = sum((x - gm) ** 2 for x in allm)
brow = sum(len(v) * (statistics.mean(v) - gm) ** 2 for v in by_row.values())
print('SLP 时间均值场：纬向(逐行)成分解释了 %.1f%% 的空间方差' % (brow / tot * 100))
print('  -> 越高说明 SLP 越是「纯纬向静态基线」，∇SLP 方向恒定 → 风向恒定')
print()

# ── 风向：目标 vs 实际 的时间变化 ────────────────────────────────────────
cons = []
for c, s in wind_ser.items():
    u = sorted(set(s))
    if len(u) < 3:
        continue
    cx = statistics.mean(x[1] for x in u)
    cy = statistics.mean(x[2] for x in u)
    cons.append(math.hypot(cx, cy))
cons.sort()
nstates = defaultdict(int)
for c, s in wind_ser.items():
    nstates[len({(round(x[1], 6), round(x[2], 6)) for x in s})] += 1
print('风向恒定度中位=%.4f' % pc(cons, .5))
print('每 cell 出现过的不同风向数分布(前8): %s'
      % sorted(nstates.items())[:8])
