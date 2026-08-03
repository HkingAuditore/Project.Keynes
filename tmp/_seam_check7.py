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

for rr in [0, 2]:
    print('=== row %d ===' % rr)
    slp_line = ' '.join('%+.3f' % f(cells[(c, rr)], 'slp_arr') for c in range(60))
    print('slp:', slp_line)
    # 逐列差分，标出最大跳变位置
    diffs = []
    for c in range(60):
        a = f(cells[(c, rr)], 'slp_arr')
        b = f(cells[((c + 1) % 60, rr)], 'slp_arr')
        diffs.append(b - a)
    order = sorted(range(60), key=lambda i: -abs(diffs[i]))
    print('top-5 |delta| at edge c->c+1:', [(c, round(diffs[c], 4)) for c in order[:5]])
    print()

# 全图：每行 slp 的接缝跳变 vs 该行最大内部跳变
print('row | seam_jump(59->0) | max_interior_jump | rank_of_seam(1=largest)')
for rr in range(40):
    vals = [f(cells[(c, rr)], 'slp_arr') for c in range(60)]
    diffs = [vals[(c + 1) % 60] - vals[c] for c in range(60)]
    seam = abs(diffs[59])
    interior = [abs(diffs[c]) for c in range(59)]
    rank = 1 + sum(1 for x in interior if x > seam)
    print('%3d | %.4f | %.4f | %d' % (rr, seam, max(interior), rank))
