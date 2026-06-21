import csv, sys, math
from collections import defaultdict
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
PATH=sys.argv[1]
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); H=next(rd); c={n:i for i,n in enumerate(H)}
CID=c['cell_index']; PRE=c['weather_precip_arr']; VAP=c['weather_vapor_arr']; CLD=c['weather_cloud_arr']
TMP=c['temp_arr']; LAT=c['cell_lat_norm_arr']; WAT=c['is_water_arr']; SKIP=c['was_skipped_day']
def fv(s):
    try: return float(s)
    except Exception: return 0.0
def iv(s):
    try: return int(float(s))
    except Exception: return -1
n=defaultdict(int)
s_p=defaultdict(float); ss_p=defaultdict(float)
s_v=defaultdict(float); ss_v=defaultdict(float)
s_c=defaultdict(float); ss_c=defaultdict(float)
tmp_of={}; lat_of={}; wat_of={}
for r in rd:
    if len(r)<=CLD: continue
    if r[SKIP].strip().lower()=='true': continue   # 仅有效天气 tick
    cid=iv(r[CID])
    if cid<0: continue
    p=fv(r[PRE]); v=fv(r[VAP]); cl=fv(r[CLD])
    n[cid]+=1
    s_p[cid]+=p; ss_p[cid]+=p*p
    s_v[cid]+=v; ss_v[cid]+=v*v
    s_c[cid]+=cl; ss_c[cid]+=cl*cl
    tmp_of[cid]=fv(r[TMP]); lat_of[cid]=fv(r[LAT]); wat_of[cid]=iv(r[WAT])
cells=[cid for cid in n if n[cid]>=5]
print('=== 流动性量化 (排除跳过日; cells=%d) ==='%len(cells))
def stats(s,ss):
    means=[]; tvars=[]
    for cid in cells:
        m=s[cid]/n[cid]; var=max(0.0, ss[cid]/n[cid]-m*m)
        means.append(m); tvars.append(var)
    gm=sum(means)/len(means)
    svar=sum((m-gm)**2 for m in means)/len(means)   # 跨格的时间均值方差 = "固定空间 pattern"强度
    mtvar=sum(tvars)/len(tvars)                       # 平均逐格时间方差 = "随时间流动变化"强度
    fi=mtvar/(svar+mtvar) if (svar+mtvar)>0 else 0.0
    return gm,svar,mtvar,fi
for label,(s,ss) in [('precip',(s_p,ss_p)),('vapor',(s_v,ss_v)),('cloud',(s_c,ss_c))]:
    gm,svar,mtvar,fi=stats(s,ss)
    print('  %-6s 均值=%.4f | 空间方差(固定pattern)=%.5f  时间方差(流动)=%.5f  流动指数=%.3f'%(label,gm,svar,mtvar,fi))
print('  流动指数=时间方差/(空间+时间方差): →0=纯固定空间pattern(本地锚定,不流动); →0.5+=明显随时间流动')
# precip 变异系数
cvs=0; cvt=0
for cid in cells:
    m=s_p[cid]/n[cid]
    if m<0.005: continue
    sd=math.sqrt(max(0.0,ss_p[cid]/n[cid]-m*m)); cvt+=1
    if sd/m<0.5: cvs+=1
print('\n  有降水格中 CV(=std/mean)<0.5 占 %.1f%% (越高=越多格降水量近恒定不变)'%(100*cvs/max(1,cvt)))
# vapor(时间均值) ~ temp 空间相关
vm=[s_v[cid]/n[cid] for cid in cells]; tt=[tmp_of[cid] for cid in cells]
mv=sum(vm)/len(vm); mt=sum(tt)/len(tt)
cov=sum((vm[i]-mv)*(tt[i]-mt) for i in range(len(cells)))/len(cells)
sv=math.sqrt(sum((x-mv)**2 for x in vm)/len(vm)); st=math.sqrt(sum((x-mt)**2 for x in tt)/len(tt))
print('  vapor(时间均值) vs temp 空间相关 r=%.3f (高=vapor 由本地温度/气候决定=本地锚定铁证)'%(cov/(sv*st) if sv*st>0 else 0))
