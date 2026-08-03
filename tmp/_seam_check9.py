import csv

rows = list(csv.DictReader(open(r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_103658.csv', encoding='utf-8')))

def f(r, k):
    try:
        return float(r[k])
    except Exception:
        return 0.0

cells = {}
for r in rows:
    q, rr = int(r['q']), int(r['r'])
    col = q + (rr - (rr & 1)) // 2
    cells[(col, rr)] = r

# 对每行：找 slp 相邻列跳变最大的位置（59->0 记为位置 59）
pos_hist = {}
for rr in range(40):
    best_pos, best_val = -1, -1.0
    for c in range(60):
        c2 = (c + 1) % 60
        v = abs(f(cells[(c2, rr)], 'slp_arr') - f(cells[(c, rr)], 'slp_arr'))
        if v > best_val:
            best_val, best_pos = v, c
    pos_hist[best_pos] = pos_hist.get(best_pos, 0) + 1
print('max-jump position histogram (col index; 59 = seam 59->0):')
for p in sorted(pos_hist):
    print('  col %2d: %d rows' % (p, pos_hist[p]))

# 接缝附近窗口的 slp 值：cols 56..59, 0..3，每 4 行一行
print()
print('slp window cols 56-59 | 0-3 (every 4th row):')
for rr in range(0, 40, 4):
    vals = [f(cells[(c, rr)], 'slp_arr') for c in [56, 57, 58, 59, 0, 1, 2, 3]]
    print('row %2d: %s | %s' % (rr,
          ' '.join('%+.3f' % v for v in vals[:4]),
          ' '.join('%+.3f' % v for v in vals[4:])))

# 检验：若把 synoptic 波陡区锚定在 px≈0，应表现为 seam 跳变符号在行间随机。
# 统计符号：slp(0)-slp(59) 的符号分布
signs = []
for rr in range(40):
    d = f(cells[(0, rr)], 'slp_arr') - f(cells[(59, rr)], 'slp_arr')
    signs.append('+' if d > 0 else '-')
print()
print('sign of slp(col0)-slp(col59) by row:')
print(''.join(signs))
