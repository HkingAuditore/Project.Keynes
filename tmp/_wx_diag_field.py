import csv, sys
from collections import defaultdict
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
PATH=sys.argv[1]
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
RAINY={1,2,3,7}; DRYY={0,4}
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); H=next(rd); c={n:i for i,n in enumerate(H)}
CID=c['cell_index']; WT=c['weather_type_arr']; PRE=c['weather_precip_arr']
VAP=c['weather_vapor_arr']; CLD=c['weather_cloud_arr']; TMP=c['temp_arr']
WAT=c['is_water_arr']; LAT=c['cell_lat_norm_arr']; SKIP=c['was_skipped_day']; INST=c['weather_instability_arr']
def fv(s):
    try:return float(s)
    except Exception:return 0.0
def iv(s):
    try:return int(float(s))
    except Exception:return -1
ty=defaultdict(list); pr=defaultdict(list)
vsum=defaultdict(float); psum=defaultdict(float); csum=defaultdict(float); isum=defaultdict(float); n=defaultdict(int)
tmp_of={}; wat_of={}; lat_of={}; maxc=0
for r in rd:
    if len(r)<=WT: continue
    if r[SKIP].strip().lower()=='true': continue   # 仅看有效天气 tick(排除跳过日)
    cid=iv(r[CID])
    if cid<0: continue
    if cid>maxc:maxc=cid
    wt=iv(r[WT]); p=fv(r[PRE])
    ty[cid].append(wt); pr[cid].append(p)
    vsum[cid]+=fv(r[VAP]); psum[cid]+=p; csum[cid]+=fv(r[CLD]); isum[cid]+=fv(r[INST]); n[cid]+=1
    tmp_of[cid]=fv(r[TMP]); wat_of[cid]=iv(r[WAT]); lat_of[cid]=fv(r[LAT])
ncell=maxc+1
def runs(seq,val):
    out=[]; cur=0
    for x in seq:
        if x==val: cur+=1
        elif cur>0: out.append(cur); cur=0
    if cur>0: out.append(cur)
    return out
def med(a): a=sorted(a); return a[len(a)//2] if a else 0
def mean(a): return sum(a)/len(a) if a else 0.0
def q(a,p): a=sorted(a); return a[min(len(a)-1,int(p*len(a)))] if a else 0.0

bc=[]; pr_rain=[]; pr_dry=[]
for cid in range(ncell):
    s=ty[cid]
    if len(s)<5: continue
    if any((s[k-1]==3 and s[k]==0) or (s[k-1]==0 and s[k]==3) for k in range(1,len(s))): bc.append(cid)
    rn=sum(1 for x in s if x in RAINY); dn=sum(1 for x in s if x in DRYY)
    if rn>0.9*len(s): pr_rain.append(cid)
    if dn>0.9*len(s): pr_dry.append(cid)
print('=== 有效天气 tick (已排除跳过日) ===')
print('  cells=%d  avg有效tick/cell=%.0f'%(ncell, mean([n[c] for c in range(ncell) if n[c]>0])))

print('\n=== A. BLIZZARD<->CLEAR 横跳格 (n=%d, %.1f%% of cells) ==='%(len(bc),100*len(bc)/max(1,ncell)))
if bc:
    allp=[]; near=0; cross=0; tot=0; temps=[]; blr=[]; clr=[]
    for cid in bc:
        ps=pr[cid]; allp+=ps; temps.append(tmp_of[cid]); tot+=len(ps)
        for x in ps:
            if 0.025<=x<=0.035: near+=1
        for k in range(1,len(ps)):
            if (ps[k-1]<0.030)!=(ps[k]<0.030): cross+=1
        blr+=runs(ty[cid],3); clr+=runs(ty[cid],0)
    print('  precip: p10=%.4f p50=%.4f p90=%.4f mean=%.4f  (分类门 meaningful_precip=0.030)'%(q(allp,.1),q(allp,.5),q(allp,.9),mean(allp)))
    print('  precip 落在阈值带[0.025,0.035]: %.1f%%   <-- 越高=越多时间卡在横跳危险区'%(100*near/max(1,tot)))
    print('  precip 穿越 0.030 频率: 每100有效tick %.1f 次'%(100*cross/max(1,tot)))
    print('  这些格 temp: p10=%.3f p50=%.3f p90=%.3f  (SNOW_FREEZE_T=0.24, <=此值直接暴雪)'%(q(temps,.1),q(temps,.5),q(temps,.9)))
    print('  BLIZZARD 连续段长(有效tick): 中位=%d 均值=%.1f'%(med(blr),mean(blr)))
    print('  CLEAR    连续段长(有效tick): 中位=%d 均值=%.1f'%(med(clr),mean(clr)))
    print('  解读: 段长中位<=3 → 高频抖动(过渡可吸收); >=4 → 较长周期真实交替(过渡rate=0.35吸收不掉)')

def pic(cells,label):
    if not cells: print('  %-9s 无'%label); return
    print('  %-9s n=%4d | vapor=%.3f precip=%.4f cloud=%.3f inst=%.3f temp=%.3f 水占比=%.2f lat=%.2f'%(
        label,len(cells),mean([vsum[c]/n[c] for c in cells]),mean([psum[c]/n[c] for c in cells]),
        mean([csum[c]/n[c] for c in cells]),mean([isum[c]/n[c] for c in cells]),
        mean([tmp_of[c] for c in cells]),mean([wat_of[c] for c in cells]),mean([lat_of[c] for c in cells])))
allc=[c for c in range(ncell) if n[c]>=5]
print('\n=== B. 永雨/永旱/全部 场量画像 (定位 vapor 稳态) ===')
pic(pr_rain,'永雨格'); pic(pr_dry,'永旱格'); pic(allc,'全部格')
print('\n  解读: 若永雨格 vapor 锁高、永旱格 vapor 锁低且都 std 小 → 水汽稳态(平流摊平), 属 vapor_transport_gain/precip_sink 标定问题')
