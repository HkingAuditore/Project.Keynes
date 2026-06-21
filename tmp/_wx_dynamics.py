import csv, sys, math
PATH=sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_041651.csv'
def fv(s):
    try:return float(s)
    except:return 0.0
def iv(s):
    try:return int(float(s))
    except:return -1
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
C={'tick':1,'wt':220,'cloud':161,'precip':163,'water':223}
CELLS=20000
prev_wt=[-1]*CELLS; trans=[0]*CELLS; rain_n=[0]*CELLS; dry_n=[0]*CELLS
pn=[0]*CELLS; psum=[0.0]*CELLS; psq=[0.0]*CELLS; wflag=[0]*CELLS
cur=None; ci=0; maxci=0
clouds=[]; precs=[]; gwt={}; sample=0; rows=0
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); next(rd)
for r in rd:
    if len(r)<=C['wt']: continue
    rows+=1
    t=r[C['tick']]
    if t!=cur: cur=t; ci=0
    cid=ci; ci+=1
    if cid>=CELLS: continue
    if cid>maxci: maxci=cid
    wt=iv(r[C['wt']]); p=fv(r[C['precip']]); cl=fv(r[C['cloud']])
    gwt[wt]=gwt.get(wt,0)+1
    sample+=1
    if sample%5==0: clouds.append(cl); precs.append(p)
    if prev_wt[cid]>=0 and wt!=prev_wt[cid]: trans[cid]+=1
    prev_wt[cid]=wt
    if wt in (1,2,3,7): rain_n[cid]+=1
    if wt in (0,4): dry_n[cid]+=1
    pn[cid]+=1; psum[cid]+=p; psq[cid]+=p*p; wflag[cid]=iv(r[C['water']])
ncells=maxci+1
def q(a,p):
    a=sorted(a);return a[min(len(a)-1,int(p*len(a)))] if a else float('nan')
gt=sum(gwt.values())
print('rows=%d cells=%d ticks(avg)=%.0f'%(rows,ncells,sum(pn)/max(1,ncells)))
print('\n=== cloud/precip field (sampled, RH门是否生效) ===')
print('  cloud p10=%.3f p50=%.3f p90=%.3f   (旧 013108: p50=0.61)'%(q(clouds,.1),q(clouds,.5),q(clouds,.9)))
print('  precip p10=%.4f p50=%.4f p90=%.4f'%(q(precs,.1),q(precs,.5),q(precs,.9)))
print('\n=== GLOBAL weather_type ===')
for w in sorted(gwt,key=lambda k:-gwt[k]):
    print('  %-9s %6.2f%%'%(NAMES.get(w,w),100.0*gwt[w]/gt))
# transitions
buckets={'0(恒定)':0,'1-5':0,'6-20':0,'21-100':0,'>100':0}
perma_rain=0; perma_dry=0; mostly_one=0; tr_sum=0; cnt=0
pstd_small=0
for c in range(ncells):
    if pn[c]<5: continue
    cnt+=1; tr=trans[c]; tr_sum+=tr
    if tr==0: buckets['0(恒定)']+=1
    elif tr<=5: buckets['1-5']+=1
    elif tr<=20: buckets['6-20']+=1
    elif tr<=100: buckets['21-100']+=1
    else: buckets['>100']+=1
    if rain_n[c]>0.9*pn[c]: perma_rain+=1
    if dry_n[c]>0.9*pn[c]: perma_dry+=1
    m=psum[c]/pn[c]; sd=math.sqrt(max(0.0,psq[c]/pn[c]-m*m))
    if sd<0.006: pstd_small+=1
print('\n=== TIME continuity: weather_type transitions per cell (over all ticks) ===')
for k in ['0(恒定)','1-5','6-20','21-100','>100']:
    print('  %-8s : %5.1f%% of cells'%(k,100.0*buckets[k]/max(1,cnt)))
print('  avg transitions/cell = %.1f over %d ticks (高=频繁跳变/不平滑; 接近0=恒定不变)'%(tr_sum/max(1,cnt),int(sum(pn)/max(1,ncells))))
print('\n=== SPATIAL extremes ===')
print('  永雨 (>90%% ticks 为 RAIN/STORM/BLIZ/MONSOON): %5.1f%% of cells'%(100.0*perma_rain/max(1,cnt)))
print('  永旱 (>90%% ticks 为 CLEAR/DROUGHT):           %5.1f%% of cells'%(100.0*perma_dry/max(1,cnt)))
print('  precip 时间 std<0.006 (几乎不变的格子):        %5.1f%% of cells'%(100.0*pstd_small/max(1,cnt)))
