import csv, sys, math
PATH=sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_013108.csv'
def fv(s):
    try:return float(s)
    except:return 0.0
def iv(s):
    try:return int(float(s))
    except:return -1
def smoothstep(e0,e1,x):
    if e1<=e0:return 0.0
    t=max(0.0,min(1.0,(x-e0)/(e1-e0)));return t*t*(3-2*t)
C={'tick':1,'cloud':161,'wt':220,'water':223}
# find last tick
last=None
f=open(PATH,encoding='utf-8-sig',newline='');rd=csv.reader(f);next(rd)
for r in rd:
    if len(r)>C['tick']: last=r[C['tick']]
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
CLOUDY={1,2,3,5,7}
bias={2:1.18,7:1.12,5:1.20,3:1.06}
clouds=[]; wt_cloud={}; n=0; cloudy_n=0
cover_vis=0; cover_strong=0
f=open(PATH,encoding='utf-8-sig',newline='');rd=csv.reader(f);next(rd)
for r in rd:
    if len(r)<=C['wt'] or r[C['tick']]!=last: continue
    n+=1
    cl=fv(r[C['cloud']]); wt=iv(r[C['wt']])
    clouds.append(cl); wt_cloud.setdefault(wt,[]).append(cl)
    if wt in CLOUDY:
        cloudy_n+=1
        if wt==5: cc=min(1.0,smoothstep(0.02,0.45,cl)*1.15+0.10)
        else: cc=min(1.0,smoothstep(0.15,0.58,cl)*bias.get(wt,1.0))
        if cc>0.10: cover_vis+=1
        if cc>0.40: cover_strong+=1
def q(a,p):
    a=sorted(a);return a[min(len(a)-1,int(p*len(a)))] if a else float('nan')
print('last tick=%s  cells=%d'%(last,n))
print('\n=== cloud field distribution (all cells, last tick) ===')
print('  p10=%.3f p25=%.3f p50=%.3f p75=%.3f p90=%.3f p99=%.3f max=%.3f'%(
    q(clouds,.1),q(clouds,.25),q(clouds,.5),q(clouds,.75),q(clouds,.9),q(clouds,.99),max(clouds)))
for thr in (0.15,0.25,0.35,0.45,0.58):
    c=sum(1 for x in clouds if x>thr)
    print('  cloud>%.2f : %5.1f%% of all cells'%(thr,100.0*c/n))
print('\n=== cloud by weather_type (mean / p50 / p90) ===')
for wt in sorted(wt_cloud):
    a=wt_cloud[wt]
    print('  %-9s n=%5d  mean=%.3f p50=%.3f p90=%.3f'%(NAMES.get(wt,wt),len(a),sum(a)/len(a),q(a,.5),q(a,.9)))
print('\n=== simulated shader output (current smoothstep(0.15,0.58)) ===')
print('  cloudy-type cells (RAIN/STORM/BLIZ/FOG/MONSOON): %d (%.1f%% of map)'%(cloudy_n,100.0*cloudy_n/n))
print('  -> cloud_cover>0.10 (visible cloud): %d (%.1f%% of map)  <- 加 billboard 扩散后≈满屏来源'%(cover_vis,100.0*cover_vis/n))
print('  -> cloud_cover>0.40 (strong cloud):  %d (%.1f%% of map)'%(cover_strong,100.0*cover_strong/n))
