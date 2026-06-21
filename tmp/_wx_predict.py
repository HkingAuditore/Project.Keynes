import csv, sys, math
from collections import defaultdict
try: sys.stdout.reconfigure(encoding='utf-8')
except Exception: pass
PATH = sys.argv[1]
NAMES = {0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
RAINY={1,2,3,7}; DRYY={0,4}
RATES=[1.0,0.5,0.35,0.25,0.2]

def iv(s):
    try: return int(float(s))
    except Exception: return -1
def fv(s):
    try: return float(s)
    except Exception: return 0.0

f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); header=next(rd)
col={n:i for i,n in enumerate(header)}
TICK=col['tick_idx']; CID=col['cell_index']; WT=col['weather_type_arr']
TGT=col['weather_target_type_arr']; ALPHA=col['weather_transition_alpha_arr']
PREV=col['weather_prev_type_arr']; SKIP=col['was_skipped_day']; WATER=col['is_water_arr']

seq=defaultdict(list)          # cid -> raw type 序列(按tick)
alpha_hist=defaultdict(int); tgt_eq=0; tgt_ne=0; total=0; skip_rows=0; maxcell=0
for r in rd:
    if len(r)<=WT: continue
    cid=iv(r[CID])
    if cid<0: continue
    if cid>maxcell: maxcell=cid
    wt=iv(r[WT]); tg=iv(r[TGT]); al=fv(r[ALPHA])
    seq[cid].append(wt); total+=1
    if r[SKIP].strip().lower()=='true' or iv(r[SKIP])==1: skip_rows+=1
    if al<=0.001: alpha_hist['=0']+=1
    elif al>=0.999: alpha_hist['=1']+=1
    else: alpha_hist['(0,1)']+=1
    if tg==wt: tgt_eq+=1
    else: tgt_ne+=1
ncells=maxcell+1

print('=== 步骤1：实证过渡是否生效 (CSV 现状) ===')
print('  样本(cell-tick)=%d  cells=%d'%(total,ncells))
print('  transition_alpha 分布:  =0 %.1f%%   (0,1) %.2f%%   =1 %.1f%%'%(
    100*alpha_hist['=0']/total,100*alpha_hist['(0,1)']/total,100*alpha_hist['=1']/total))
print('  target_type == weather_type: %.2f%%   (不等: %.2f%%)'%(100*tgt_eq/total,100*tgt_ne/total))
print('  was_skipped_day 行占比: %.1f%%'%(100*skip_rows/total))
print('  判读: alpha 几乎全 0/1 且 target≡type → 过渡未生效, 最终 type = 瞬时分类 (横跳根因坐实)')

def stats(seqs):
    gwt=defaultdict(int); trans_sum=0; cnt=0; mat=defaultdict(int)
    perma_rain=perma_dry=0; bucket={'0':0,'1-5':0,'6-20':0,'21-100':0,'>100':0}
    for cid,s in seqs.items():
        if len(s)<5: continue
        cnt+=1; tr=0; rn=0; dn=0
        for k,wt in enumerate(s):
            gwt[wt]+=1
            if wt in RAINY: rn+=1
            if wt in DRYY: dn+=1
            if k>0 and s[k-1]!=wt:
                tr+=1; a,b=s[k-1],wt
                if 0<=a<8 and 0<=b<8: mat[(a,b)]+=1
        trans_sum+=tr
        if tr==0: bucket['0']+=1
        elif tr<=5: bucket['1-5']+=1
        elif tr<=20: bucket['6-20']+=1
        elif tr<=100: bucket['21-100']+=1
        else: bucket['>100']+=1
        if rn>0.9*len(s): perma_rain+=1
        if dn>0.9*len(s): perma_dry+=1
    gt=sum(gwt.values())
    bc=(mat.get((3,0),0)+mat.get((0,3),0))
    rs=(mat.get((1,2),0)+mat.get((2,1),0))
    return {'cnt':cnt,'gwt':gwt,'gt':gt,'trans_avg':trans_sum/max(1,cnt),'trans_sum':trans_sum,
            'mat':mat,'perma_rain':100*perma_rain/max(1,cnt),'perma_dry':100*perma_dry/max(1,cnt),
            'bucket':bucket,'bliz_clear':100*bc/max(1,trans_sum),'rain_storm':100*rs/max(1,trans_sum)}

# 过渡状态机重放 (与 field_solver.gd:645-671 / world_ext.cpp:4402-4416 逐行一致)
def replay(seqs, rate):
    out={}
    for cid,s in seqs.items():
        if not s: continue
        cur=s[0]; prev=s[0]; tgt=s[0]; alpha=1.0; ds=[cur]
        for k in range(1,len(s)):
            raw=s[k]
            if tgt!=raw:
                prev=cur; tgt=raw; alpha=0.0
            elif prev==tgt or cur==tgt:
                prev=tgt; alpha=0.0
            else:
                alpha=min(1.0,max(0.0,alpha+rate))
            disp = tgt if alpha>=1.0 else prev
            if alpha>=1.0:
                prev=tgt; alpha=0.0
            cur=disp; ds.append(disp)
        out[cid]=ds
    return out

raw=stats(seq)
res={r:stats(replay(seq,r)) for r in RATES}

print('\n=== 步骤2：预测启用过渡 (各 rate 梯度) ===')
print('  rate 越小=确认越慢=吸收越强;  ⌈1/rate⌉ = 切换确认所需连续 tick')
hdr='  %-26s %10s'%('指标','现状(关)')
for r in RATES: hdr+=' %9s'%('r=%.2f'%r)
print(hdr)
def row(label, fn):
    line='  %-26s %10s'%(label, fn(raw))
    for r in RATES: line+=' %9s'%fn(res[r])
    print(line)
row('avg transitions/cell', lambda d:'%.1f'%d['trans_avg'])
row('总转换数', lambda d:'%d'%d['trans_sum'])
row('BLIZZARD<->CLEAR 占转换%', lambda d:'%.1f'%d['bliz_clear'])
row('RAIN<->STORM 占转换%', lambda d:'%.1f'%d['rain_storm'])
row('永雨%', lambda d:'%.1f'%d['perma_rain'])
row('永旱%', lambda d:'%.1f'%d['perma_dry'])
row('恒定格(0转换)%', lambda d:'%.1f'%(100*d['bucket']['0']/max(1,d['cnt'])))

R=0.35
print('\n=== rate=%.2f 详情：类型占比 现状→预测 ==='%R)
allw=sorted(set(list(raw['gwt'])+list(res[R]['gwt'])),key=lambda k:-raw['gwt'].get(k,0))
for w in allw:
    rp=100*raw['gwt'].get(w,0)/max(1,raw['gt']); dp=100*res[R]['gwt'].get(w,0)/max(1,res[R]['gt'])
    print('  %-9s %6.2f%% -> %6.2f%%  (%+.2f)'%(NAMES.get(w,w),rp,dp,dp-rp))

def top(mat,n=6):
    tot=sum(mat.values()); ps=sorted(mat.items(),key=lambda kv:-kv[1])[:n]
    return [(NAMES[a],NAMES[b],c,100*c/max(1,tot)) for (a,b),c in ps]
print('\n  现状 TOP 横跳对:')
for a,b,c,p in top(raw['mat']): print('    %-8s -> %-8s %7d (%.1f%%)'%(a,b,c,p))
print('  预测(r=%.2f) TOP 横跳对:'%R)
for a,b,c,p in top(res[R]['mat']): print('    %-8s -> %-8s %7d (%.1f%%)'%(a,b,c,p))
print('\n(注: 一阶预测, 假设场量/raw分类序列不变, 忽略 type->moisture 二阶反馈; skip_day 也推进状态机=偏乐观下界)')
