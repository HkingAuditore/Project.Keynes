import csv, math, collections

P = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_200553.csv'
def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r

g = {}
with open(P, encoding='utf-8-sig', newline='') as f:
    for row in csv.DictReader(f):
        col, rw = cube_to_offset(int(row['q']), int(row['r']))
        t = int(row['tick_idx'])
        g[(col, rw, t)] = (float(row['slp_arr']), float(row['wind_x_arr']),
                           float(row['wind_y_arr']), float(row['wind_speed_arr']),
                           float(row['cell_pos_x_arr']), row['is_water_arr'] in ('1','true','True'),
                           float(row['ocean_current_x_arr']), float(row['ocean_current_y_arr']))
W, H = 100, 64
ticks = sorted({k[2] for k in g})

def mean(v):
    v = [x for x in v if x == x]
    return sum(v)/len(v) if v else float('nan')

T = ticks[-1]
print('=== SLP 有符号纬向差分剖面 mean_row(slp[c+1]-slp[c])，tick %d ===' % T)
sig = []
for c in range(W):
    c2 = (c+1) % W
    d = [g[(c2,rw,T)][0]-g[(c,rw,T)][0] for rw in range(H) if (c,rw,T) in g and (c2,rw,T) in g]
    sig.append(mean(d))
for c in range(W):
    v = sig[c]
    n = int(abs(v)*1500)
    bar = ('-'*n) if v < 0 else ('+'*n)
    print('%3d->%3d  %+.6f %s' % (c, (c+1)%W, v, bar))
print('sum(should be ~0) = %.8f' % sum(sig))
interior = sorted(abs(x) for x in sig)
print('median|d| = %.6f   max|d| = %.6f at col %d' % (interior[len(interior)//2], max(abs(x) for x in sig), max(range(W), key=lambda c: abs(sig[c]))))

print()
print('=== 接缝跳变随时间（每 tick，mean_row）===')
print('%6s %10s %10s %10s %10s %10s' % ('tick','d(98->99)','d(99->0)','d(0->1)','medianInner','ratio'))
for t in ticks:
    per = []
    for c in range(W):
        c2 = (c+1) % W
        per.append(mean([abs(g[(c2,rw,t)][0]-g[(c,rw,t)][0]) for rw in range(H) if (c,rw,t) in g and (c2,rw,t) in g]))
    inner = sorted(per[2:97]); med = inner[len(inner)//2]
    print('%6d %10.6f %10.6f %10.6f %10.6f %10.2f' % (t, per[98], per[99], per[0], med, per[99]/med))

print()
print('=== 99->0 有符号跳变的逐 row 分布（tick %d），看是否与纬度相关 ===' % T)
for rw in range(0, H, 2):
    a = g.get((99,rw,T)); b = g.get((0,rw,T)); c1 = g.get((98,rw,T)); c2 = g.get((1,rw,T))
    if not (a and b and c1 and c2): continue
    print('row %2d  slp 98=%+.5f 99=%+.5f 0=%+.5f 1=%+.5f   d(99->0)=%+.5f  d(98->99)=%+.5f' % (
        rw, c1[0], a[0], b[0], c2[0], b[0]-a[0], a[0]-c1[0]))

print()
print('=== 列平均 wind_x / wind_y（tick %d），看 col0/99 是否方向锁定 ===' % T)
for c in list(range(0,6))+[48,49,50]+list(range(94,100)):
    wx = mean([g[(c,rw,T)][1] for rw in range(H) if (c,rw,T) in g])
    wy = mean([g[(c,rw,T)][2] for rw in range(H) if (c,rw,T) in g])
    ox = mean([g[(c,rw,T)][6] for rw in range(H) if (c,rw,T) in g and g[(c,rw,T)][5]])
    oy = mean([g[(c,rw,T)][7] for rw in range(H) if (c,rw,T) in g and g[(c,rw,T)][5]])
    print('col %3d  <wx>=%+.4f <wy>=%+.4f |<w>|=%.4f   <ox>=%+.5f <oy>=%+.5f |<o>|=%.5f' % (
        c, wx, wy, math.hypot(wx,wy), ox, oy, math.hypot(ox,oy)))
