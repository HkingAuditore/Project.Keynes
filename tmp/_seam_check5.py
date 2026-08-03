import csv, math

rows = list(csv.DictReader(open(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_103658.csv', encoding='utf-8')))

def f(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

W, H = 60, 40
cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r

# odd-r 邻居方向（与 CUBE_DIRECTIONS 0=E,1=NE,2=NW,3=W,4=SW,5=SE 对应）
def nb(col, row, d, wrap):
    if d == 0:   c, rr = col + 1, row
    elif d == 1: c, rr = (col + (1 if row & 1 else 0)), row - 1
    elif d == 2: c, rr = (col - (0 if row & 1 else 1)), row - 1
    elif d == 3: c, rr = col - 1, row
    elif d == 4: c, rr = (col - (0 if row & 1 else 1)), row + 1
    else:        c, rr = (col + (1 if row & 1 else 0)), row + 1
    if rr < 0 or rr >= H:
        return None
    if wrap:
        c = c % W
    elif c < 0 or c >= W:
        return None
    return (c, rr)

SQ = 0.8660254037844386
DX = [2*SQ, SQ, -SQ, -2*SQ, -SQ, SQ]
DY = [0.0, -1.5, -1.5, 0.0, 1.5, 1.5]
OC_SCALE = 0.13

def grad_psi(col, row, wrap):
    r0 = cells[(col, row)]
    p0 = f(r0, 'ocean_psi_arr')
    gx = gy = 0.0
    for d in range(6):
        n = nb(col, row, d, wrap)
        if n is None:
            pn = 0.0  # 出界 = land → psi=0
        else:
            rn = cells[n]
            pn = f(rn, 'ocean_psi_arr') if f(rn, 'is_water_arr') > 0.5 else 0.0
        dp = pn - p0
        gx += dp * DX[d]; gy += dp * DY[d]
    return gx / 3.0, gy / 3.0

# 对比：measured oc 与 -rot(grad)*scale 的残差（wrap vs nowrap 两种假设）
res_wrap_seam, res_nowrap_seam = [], []
res_wrap_int, res_nowrap_int = [], []
for (col, row), r in cells.items():
    if f(r, 'is_water_arr') < 0.5:
        continue
    mx, my = f(r, 'ocean_current_x_arr'), f(r, 'ocean_current_y_arr')
    gx_w, gy_w = grad_psi(col, row, True)
    gx_n, gy_n = grad_psi(col, row, False)
    pw = (mx - (-gy_w * OC_SCALE))**2 + (my - (gx_w * OC_SCALE))**2
    pn = (mx - (-gy_n * OC_SCALE))**2 + (my - (gx_n * OC_SCALE))**2
    if col in (0, 59):
        res_wrap_seam.append(pw); res_nowrap_seam.append(pn)
    elif 20 <= col <= 39:
        res_wrap_int.append(pw); res_nowrap_int.append(pn)

def rms(v): return math.sqrt(sum(v)/len(v)) if v else 0.0
print('interior(cols20-39): rms residual wrap=%.4f nowrap=%.4f (n=%d)' % (rms(res_wrap_int), rms(res_nowrap_int), len(res_wrap_int)))
print('seam(cols0,59)     : rms residual wrap=%.4f nowrap=%.4f (n=%d)' % (rms(res_wrap_seam), rms(res_nowrap_seam), len(res_wrap_seam)))
print()
print('解读：若 seam 处 nowrap 残差明显更小 → 求解器把接缝当墙（邻居未回绕）；')
print('      若 wrap 残差处处相近 → 求解器拓扑已回绕，墙来自其它项。')
