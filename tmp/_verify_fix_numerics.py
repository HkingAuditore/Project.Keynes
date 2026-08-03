import csv
import math

PATH = r'tmp/tile_data_record_20260803_200553.csv'
SQRT3 = math.sqrt(3.0)

# hex_utils.gd CUBE_DIRECTIONS 序：0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
CUBE_DIRS = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]


def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r


def offset_to_cube(col, row):
    return col - (row - (row & 1)) // 2, row


def wrap_min_image_dx(dx, period):
    if period <= 0.0:
        return dx
    half = period * 0.5
    if dx > half:
        return dx - period
    if dx < -half:
        return dx + period
    return dx


cells = {}
with open(PATH, newline='', encoding='utf-8-sig') as f:
    for row in csv.DictReader(f):
        try:
            q, r = int(row['q']), int(row['r'])
        except (KeyError, TypeError, ValueError):
            continue
        key = (q, r)
        if key in cells:
            continue
        cells[key] = (float(row['cell_pos_x_arr']), float(row['cell_pos_y_arr']))

cols = [cube_to_offset(q, r)[0] for q, r in cells]
rows = [r for _, r in cells]
width = max(cols) + 1
height = max(rows) + 1
period = width * SQRT3
print('grid width=%d height=%d  ->  wrap_period_x = %.4f' % (width, height, period))
print()

# 取接缝列（col 0 与 col width-1）与一个内部列做对比
def report(col_label, col, row=20):
    q, r = offset_to_cube(col, row)
    if (q, r) not in cells:
        print('  [%s] col=%d row=%d not in CSV' % (col_label, col, row))
        return
    sx, sy = cells[(q, r)]
    print('  [%s] col=%2d row=%d  pos_x=%8.3f' % (col_label, col, row, sx))
    for d, (dq, dr) in enumerate(CUBE_DIRS):
        nq, nr = q + dq, r + dr
        ncol, nrow = cube_to_offset(nq, nr)
        if nrow < 0 or nrow >= height:
            continue
        nq, nr = offset_to_cube(ncol % width, nrow)   # map_data.gd posmod 环绕
        if (nq, nr) not in cells:
            continue
        nx, ny = cells[(nq, nr)]
        raw = nx - sx
        fixed = wrap_min_image_dx(raw, period)
        dy = ny - sy
        raw_ang = math.degrees(math.atan2(dy, raw))
        fix_ang = math.degrees(math.atan2(dy, fixed))
        flag = '  <== WRAPPED, direction flipped' if abs(raw - fixed) > 1e-6 else ''
        print('     d=%d nbcol=%2d  raw_dx=%9.3f (ang %7.1f)   fixed_dx=%7.3f (ang %7.1f)%s'
              % (d, ncol % width, raw, raw_ang, fixed, fix_ang, flag))
    print()


report('seam  col 0', 0)
report('seam  col W-1', width - 1)
report('interior', width // 2)
