import csv, math

P = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_200553.csv'
def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r

with open(P, encoding='utf-8-sig', newline='') as f:
    rd = csv.DictReader(f)
    hdr = rd.fieldnames
    start = hdr.index('cell_index')
    cellfields = hdr[start+4:]      # 跳过 cell_index,q,r,s
    rows = [r for r in rd if int(r['tick_idx']) >= 6482]

T = max(int(r['tick_idx']) for r in rows)
g = {}
for r in rows:
    if int(r['tick_idx']) != T: continue
    col, rw = cube_to_offset(int(r['q']), int(r['r']))
    g[(col, rw)] = r
W, H = 100, 64

def mean(v):
    v=[x for x in v if x==x]
    return sum(v)/len(v) if v else float('nan')

results = []
for k in cellfields:
    # 只处理数值字段
    try:
        float(g[(0,0)][k])
    except Exception:
        continue
    per = []
    for c in range(W):
        c2 = (c+1) % W
        ds = []
        for rw in range(H):
            a = g.get((c,rw)); b = g.get((c2,rw))
            if not a or not b: continue
            try: ds.append(abs(float(a[k]) - float(b[k])))
            except Exception: pass
        per.append(mean(ds))
    inner = sorted(x for x in per[2:97] if x==x)
    if not inner: continue
    med = inner[len(inner)//2]
    if med < 1e-9:
        # 全图基本恒定，跳过
        seam = max(per[97], per[98], per[99], per[0])
        if seam < 1e-9: continue
        results.append((float('inf'), k, med, per[98], per[99], per[0]))
        continue
    seam = max(per[98], per[99], per[0])
    results.append((seam/med, k, med, per[98], per[99], per[0]))

results.sort(reverse=True, key=lambda x: (x[0] if x[0]!=float('inf') else 1e18))
print('接缝跳变 / 内部中位数  排行（tick %d）' % T)
print('%8s  %-34s %10s %10s %10s %10s' % ('ratio','field','med_inner','d(98->99)','d(99->0)','d(0->1)'))
for ratio, k, med, a, b, c in results:
    if ratio < 1.3: continue
    print('%8.2f  %-34s %10.6f %10.6f %10.6f %10.6f' % (ratio, k, med, a, b, c))
print()
print('--- 接缝连续（ratio<1.3）的字段 ---')
print(', '.join(k for ratio,k,_,_,_,_ in results if ratio < 1.3))
