import csv, sys
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
PATH=sys.argv[1]
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); H=next(rd); c={n:i for i,n in enumerate(H)}
def gi(name): return c.get(name,-1)
TI=gi('tick_idx'); SK=gi('was_skipped_day')
WD=gi('climate_wind_delta_p95'); WM=gi('climate_wind_mag_p95')
SD=gi('climate_slp_delta_p95'); OD=gi('climate_ocean_delta_p95')
NZ=gi('climate_transport_nonzero_ratio'); CP=gi('climate_current_pass')
seen={}
for r in rd:
    if len(r)<=TI: continue
    t=r[TI]
    if t in seen: continue
    def g(idx): return r[idx] if 0<=idx<len(r) else ''
    seen[t]=(g(WD), g(WM), g(SD), g(OD), g(SK), g(NZ))
def col(idx):
    out=[]
    for v in seen.values():
        try: out.append(float(v[idx]))
        except Exception: pass
    return out
def q(a,p):
    a=sorted(a); return a[min(len(a)-1,int(p*len(a)))] if a else 0.0
print('=== 风场/气压时间动态 (per-tick 去重; 唯一tick=%d) ==='%len(seen))
for name,idx in [('wind_mag_p95',1),('wind_delta_p95',0),('slp_delta_p95',2),('ocean_delta_p95',3)]:
    a=col(idx); nz=sum(1 for x in a if abs(x)>1e-6)
    print('  %-15s p10=%.5f p50=%.5f p90=%.5f  非零tick=%.0f%%'%(name,q(a,.1),q(a,.5),q(a,.9),100*nz/max(1,len(a))))
sk=col(4); skcnt=sum(1 for x in sk if x>0.5)
print('  跳过日 tick 占比 %.0f%%'%(100*skcnt/max(1,len(sk))))
print('\n判读: wind_delta_p95/slp_delta_p95 p50≈0 → 风场/气压准静态(冻结,平流搬的是不变的场);')
print('      >0 且非零tick高 → 风场在动(synoptic 漂移生效), 那不流动的锅在 vapor 锚定+平流位移')
