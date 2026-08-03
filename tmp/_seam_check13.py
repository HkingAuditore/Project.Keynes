import csv
import math

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

# 最小二乘拟合（无 numpy，手写高斯消元）：基 = [1, cos(2πpx), sin(2πpx), cos(4πpx), sin(4πpx)]
def fit_row(rr, exclude=set()):
    px = [c / W for c in range(W)]
    ys = [f_(cells[(c, rr)], 'slp_arr') for c in range(W)]
    basis = []
    for c in range(W):
        basis.append([1.0,
                      math.cos(2*math.pi*px[c]), math.sin(2*math.pi*px[c]),
                      math.cos(4*math.pi*px[c]), math.sin(4*math.pi*px[c])])
    # 正规方程 A^T A x = A^T y
    n = 5
    ata = [[0.0]*n for _ in range(n)]
    aty = [0.0]*n
    for c in range(W):
        if c in exclude:
            continue
        for a in range(n):
            for b in range(n):
                ata[a][b] += basis[c][a]*basis[c][b]
            aty[a] += basis[c][a]*ys[c]
    # 高斯消元
    M = [row[:] + [aty[i]] for i, row in enumerate(ata)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(M[r][col]))
        M[col], M[piv] = M[piv], M[col]
        d = M[col][col]
        if abs(d) < 1e-12:
            continue
        for r in range(n):
            if r != col:
                fac = M[r][col]/d
                for cc in range(n+1):
                    M[r][cc] -= fac*M[col][cc]
    coef = [M[i][n]/M[i][i] if abs(M[i][i]) > 1e-12 else 0.0 for i in range(n)]
    resid = []
    for c in range(W):
        fit = sum(coef[a]*basis[c][a] for a in range(n))
        resid.append(ys[c] - fit)
    return coef, resid

# 对 row 30：排除接缝区 cols 94..99,0..4 拟合，看残差在接缝的形状
rr = 30
excl = set(list(range(94, 100)) + list(range(0, 5)))
coef, resid = fit_row(rr, excl)
print('row 30 harmonic fit coef [1,c1,s1,c2,s2]:', ['%+.4f' % v for v in coef])
print('residual around seam (cols 90-99, 0-9):')
for c in list(range(90, 100)) + list(range(0, 10)):
    mark = ' <== EXCLUDED' if c in excl else ''
    print('  col %2d: resid=%+.4f%s' % (c, resid[c], mark))

# 所有行：拟合非接缝区，取接缝残差（col0 与 col99 的残差差）→ 逐行异常分量
print()
print('per-row seam residual (fit cols 10..89, extrapolate to seam):')
seam_resid = []
for rr2 in range(H):
    excl2 = set(list(range(92, 100)) + list(range(0, 8)))
    _, res = fit_row(rr2, excl2)
    # 异常分量 = col0 残差（接缝东侧）与 col99 残差（西侧）的均值差
    east = sum(res[0:3])/3.0
    west = sum(res[97:100])/3.0
    seam_resid.append(east - west)
    if rr2 % 4 == 0:
        print('  row %2d: east_resid=%+.4f west_resid=%+.4f diff(e-w)=%+.4f' % (rr2, east, west, east-west))

# 异常分量的纬度剖面
import statistics
m = statistics.mean(seam_resid)
print()
print('seam residual lat profile: mean=%.4f' % m)
print('by row:', ' '.join('%+.3f' % v for v in seam_resid))
