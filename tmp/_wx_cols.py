import csv, sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
PATH=sys.argv[1]
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); H=next(rd)
KEY=['wind','slp','daily','_delta','advect','synopt','circ','ocean_delta','ocean_mag']
idxs=[(i,n) for i,n in enumerate(H) if any(k in n.lower() for k in KEY)]
TI=H.index('tick_idx') if 'tick_idx' in H else 0
maxi=max(i for i,_ in idxs) if idxs else 0
print('=== 匹配到的 风/气压/平流/delta 列 (%d) ==='%len(idxs))
for i,n in idxs: print('  [%d] %s'%(i,n))
seen={}
for r in rd:
    if len(r)<=maxi: continue
    t=r[TI]
    if t in seen: continue
    seen[t]={n:(r[i] if i<len(r) else '') for i,n in idxs}
print('\n=== 各列时间动态 (per-tick 去重, n_tick=%d) ==='%len(seen))
for i,n in idxs:
    vals=[]
    for d in seen.values():
        try: vals.append(float(d[n]))
        except Exception: pass
    if not vals: continue
    nz=sum(1 for x in vals if abs(x)>1e-6); vals.sort()
    print('  %-34s 非零tick=%3.0f%%  中位=%.5f  max=%.5f'%(n,100*nz/len(vals),vals[len(vals)//2],vals[-1]))
print('\n判读: 任一 *_delta_p95 列长期非零 → 对应场在动; 若所有 wind/slp delta 全=0 → 风/气压场冻结(root bug)')
