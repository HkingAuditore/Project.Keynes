import csv, math, collections

P = r'd:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260803_200553.csv'

def cube_to_offset(q, r):
    return q + (r - (r & 1)) // 2, r

# grid[(col,row)] = per-tick list
data = collections.defaultdict(dict)   # (col,row) -> tick -> tuple
with open(P, encoding='utf-8-sig', newline='') as f:
    rd = csv.DictReader(f)
    for row in rd:
        col, rw = cube_to_offset(int(row['q']), int(row['r']))
        t = int(row['tick_idx'])
        def g(k):
            try: return float(row[k])
            except Exception: return float('nan')
        data[(col, rw)][t] = dict(
            slp=g('slp_arr'), wx=g('wind_x_arr'), wy=g('wind_y_arr'),
            ws=g('wind_speed_arr'), ox=g('ocean_current_x_arr'), oy=g('ocean_current_y_arr'),
            psi=g('ocean_psi_arr'), curl=g('wind_stress_curl_arr'),
            water=row['is_water_arr'] in ('1','true','True'),
            posx=g('cell_pos_x_arr'), posy=g('cell_pos_y_arr'),
            up=g('upwelling_strength_arr'))

W, H = 100, 64
ticks = sorted({t for v in data.values() for t in v})
T = ticks[-1]
print('ticks', ticks[0], '..', T, 'n=', len(ticks))

def mean(v):
    v=[x for x in v if x==x]
    return sum(v)/len(v) if v else float('nan')

# ---- 1) 相邻列跨列跳变（同 row，col -> col+1，含 99->0 wrap）----
print()
print('=== 跨列跳变（同 row，最后一 tick）: |dSLP|  windDirDelta(rad)  |dPsi|(water) ===')
rowsout=[]
for c in range(W):
    c2=(c+1)%W
    dslp=[]; dwd=[]; dpsi=[]; docean=[]
    for rw in range(H):
        a=data.get((c,rw),{}).get(T); b=data.get((c2,rw),{}).get(T)
        if not a or not b: continue
        dslp.append(abs(a['slp']-b['slp']))
        aw=math.atan2(a['wy'],a['wx']); bw=math.atan2(b['wy'],b['wx'])
        d=abs(aw-bw)
        if d>math.pi: d=2*math.pi-d
        dwd.append(d)
        if a['water'] and b['water']:
            dpsi.append(abs(a['psi']-b['psi']))
            docean.append(math.hypot(a['ox']-b['ox'], a['oy']-b['oy']))
    rowsout.append((c,c2,mean(dslp),mean(dwd),mean(dpsi),mean(docean)))

vals=[r[2] for r in rowsout]
med=sorted(vals)[len(vals)//2]
for c,c2,a,b,d,e in rowsout:
    flag=''
    if a==a and a>3*med: flag='   <== SEAM'
    print('%3d->%3d  dSLP=%.6f (x%.1f med)  dWindDir=%.4f  dPsi=%.4f  dOcean=%.5f%s'%(c,c2,a,a/med if med else 0,b,d,e,flag))

# ---- 2) 该列纵向一致性 + 时间恒定性 ----
def circ_R(angles):
    if not angles: return float('nan')
    s=sum(math.sin(x) for x in angles)/len(angles)
    c=sum(math.cos(x) for x in angles)/len(angles)
    return math.hypot(s,c)

print()
print('=== 列内空间一致性 R (1=完全同向) 与时间恒定性 ===')
print('col  windR_spatial  oceanR_spatial  wind_dt_R  ocean_dt_R  meanWS  mean|ocean|  mean|curl|')
for c in range(W):
    wa=[]; oa=[]; wsl=[]; oml=[]; cul=[]
    wdt=[]; odt=[]
    for rw in range(H):
        rec=data.get((c,rw),{})
        a=rec.get(T)
        if not a: continue
        wa.append(math.atan2(a['wy'],a['wx']))
        wsl.append(a['ws'])
        wdt.append(circ_R([math.atan2(rec[t]['wy'],rec[t]['wx']) for t in ticks if t in rec]))
        if a['water']:
            if a['ox'] or a['oy']: oa.append(math.atan2(a['oy'],a['ox']))
            oml.append(math.hypot(a['ox'],a['oy']))
            cul.append(abs(a['curl']))
            odt.append(circ_R([math.atan2(rec[t]['oy'],rec[t]['ox']) for t in ticks if t in rec and (rec[t]['ox'] or rec[t]['oy'])]))
    print('%3d  %13.4f %15.4f %10.4f %11.4f %7.4f %11.5f %10.5f'%(
        c, circ_R(wa), circ_R(oa), mean(wdt), mean(odt), mean(wsl), mean(oml), mean(cul)))
