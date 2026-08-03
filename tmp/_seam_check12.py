import csv

path = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_112649.csv'
rows = list(csv.DictReader(open(path, encoding='utf-8')))

def f_(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r
W, H = 100, 64

# 打印若干行的完整 slp 剖面（减行均值），并数过零次数
def profile(rr):
    vals = [f_(cells[(c, rr)], 'slp_arr') for c in range(W)]
    m = sum(vals) / len(vals)
    return [v - m for v in vals]

def zero_crossings(prof):
    n = 0
    for c in range(W):
        a = prof[c]; b = prof[(c + 1) % W]
        if (a < 0) != (b < 0):
            n += 1
    return n

print('row | zero_crossings | max|jump| position | seam jump')
for rr in [0, 5, 10, 16, 24, 30, 40, 48, 56, 60]:
    prof = profile(rr)
    zc = zero_crossings(prof)
    jumps = [abs(prof[(c + 1) % W] - prof[c]) for c in range(W)]
    mj = max(range(W), key=lambda c: jumps[c])
    seam = jumps[W - 1]
    print('row %2d | zc=%d | maxjump at col %d (%.4f) | seam %.4f' % (rr, zc, mj, jumps[mj], seam))

# 打印 row 30 的完整剖面（10 列一组）
print()
rr = 30
prof = profile(rr)
print('row 30 profile (mean-subtracted), 100 cols:')
for g in range(10):
    seg = prof[g*10:(g+1)*10]
    print('  cols %2d-%2d: %s' % (g*10, g*10+9, ' '.join('%+.3f' % v for v in seg)))

# 同时看 wind_x/wind_y 在接缝窗口（row 30）
print()
print('row 30 wind window cols 96-99 | 0-3:')
for c in [96, 97, 98, 99, 0, 1, 2, 3]:
    r = cells[(c, 30)]
    print('  col %2d: wx=%+.3f wy=%+.3f slp=%+.4f psi=%+.3f ocx=%+.4f ocy=%+.4f terrain=%d' % (
        c, f_(r,'wind_x_arr'), f_(r,'wind_y_arr'), f_(r,'slp_arr'),
        f_(r,'ocean_psi_arr'), f_(r,'ocean_current_x_arr'), f_(r,'ocean_current_y_arr'),
        int(f_(r,'terrain_arr'))))
