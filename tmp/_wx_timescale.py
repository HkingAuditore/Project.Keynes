import csv, sys
PATH=sys.argv[1]
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); H=next(rd); c={n:i for i,n in enumerate(H)}
TI=c['tick_idx']; SD=c['phys_sim_day']; SK=c['was_skipped_day']
sd0=None; sd1=None; utick=set(); ueff=set()
for r in rd:
    if len(r)<=TI: continue
    t=r[TI]
    try: sd=float(r[SD])
    except Exception: continue
    if sd0 is None: sd0=sd
    sd1=sd; utick.add(t)
    if r[SK].strip().lower()!='true': ueff.add(t)
span=sd1-sd0
neff=max(1,len(ueff))
print('sim_day %.0f -> %.0f  跨度=%.0f 天'%(sd0,sd1,span))
print('唯一tick=%d  有效(非skip)tick=%d'%(len(utick),neff))
print('每有效更新 ≈ %.2f sim_day'%(span/neff))
for label,upd in [('BLIZZARD段(中位30更新)',30),('CLEAR段(中位42更新)',42),('一轮交替(72更新)',72)]:
    days=upd*span/neff
    print('  %-22s ≈ %.0f 天 ≈ %.2f 年(/365)'%(label,days,days/365.0))
