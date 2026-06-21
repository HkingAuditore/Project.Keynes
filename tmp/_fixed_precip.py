import csv, sys, math
PATH=sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_013108.csv'
def fv(s):
    try:return float(s)
    except:return 0.0
def iv(s):
    try:return int(float(s))
    except:return -1
C={'tick':1,'precip':163,'water':223,'wt':220}
CELLS=20000
psum=[0.0]*CELLS; psq=[0.0]*CELLS; pn=[0]*CELLS; wflag=[0]*CELLS; rain_n=[0]*CELLS
cur=None; ci=0; maxci=0
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); next(rd)
for r in rd:
    if len(r)<=220: continue
    t=r[C['tick']]
    if t!=cur: cur=t; ci=0
    cid=ci; ci+=1
    if cid>=CELLS: continue
    if cid>maxci: maxci=cid
    p=fv(r[C['precip']]); psum[cid]+=p; psq[cid]+=p*p; pn[cid]+=1
    wflag[cid]=iv(r[C['water']])
    if iv(r[C['wt']]) in (1,2,3,7): rain_n[cid]+=1
ncells=maxci+1
wet=0; wet_const=0; frozen=0; persistent_rain=0
wet_w=0; wet_l=0; pr_w=0; pr_l=0; nw=0; nl=0
for c in range(ncells):
    if pn[c]<2: continue
    if wflag[c]>0: nw+=1
    else: nl+=1
    m=psum[c]/pn[c]; var=psq[c]/pn[c]-m*m; sd=math.sqrt(max(0.0,var))
    if m>0.03:
        wet+=1
        if wflag[c]>0: wet_w+=1
        else: wet_l+=1
        if sd<0.008: wet_const+=1
    if sd<0.002: frozen+=1
    if pn[c]>0 and rain_n[c] > 0.9*pn[c]:
        persistent_rain+=1
        if wflag[c]>0: pr_w+=1
        else: pr_l+=1
print('cells=%d ticks(avg pn)=%.0f  water=%d land=%d'%(ncells,sum(pn)/max(1,ncells),nw,nl))
print('wet cells (time-mean precip>0.03): %d (%.1f%%)  [water %d / land %d]'%(wet,100.0*wet/ncells,wet_w,wet_l))
print('  of which nearly-constant precip (std<0.008): %d (%.1f%% of all cells)  <- "固定降水"'%(wet_const,100.0*wet_const/ncells))
print('frozen precip (std<0.002, basically never changes): %d (%.1f%%)'%(frozen,100.0*frozen/ncells))
print('persistent precipitating (>90%% of ticks classified RAIN/STORM/BLIZ/MONSOON): %d (%.1f%%)  [water %d / land %d]'%(
    persistent_rain,100.0*persistent_rain/ncells,pr_w,pr_l))
