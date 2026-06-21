import csv, sys
PATH=sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260620_143812.csv'
NAMES={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZ',4:'DROUGHT',5:'FOG',6:'HEAT',7:'MONSOON'}
WT=220; TICK=1; PRECIP=163; CLOUD=161
CELLS=4000
prev=[-1]*CELLS
mat=[[0]*8 for _ in range(8)]
cur=None; ci=0
cr_precip=[]
f=open(PATH,encoding='utf-8-sig',newline='')
rd=csv.reader(f); next(rd)
for r in rd:
    if len(r)<=WT: continue
    t=r[TICK]
    if t!=cur: cur=t; ci=0
    cid=ci; ci+=1
    if cid>=CELLS: continue
    try: wt=int(float(r[WT]))
    except: continue
    p=0.0
    try: p=float(r[PRECIP])
    except: pass
    pv=prev[cid]
    if pv>=0 and 0<=wt<8 and 0<=pv<8 and pv!=wt:
        mat[pv][wt]+=1
        if (pv==0 and wt==1) or (pv==1 and wt==0):
            cr_precip.append(p)
    prev[cid]=wt
tot=sum(sum(row) for row in mat)
print('total transitions=%d'%tot)
pairs=[]
for a in range(8):
    for b in range(8):
        if a!=b and mat[a][b]>0: pairs.append((mat[a][b],a,b))
pairs.sort(reverse=True)
print('\n=== TOP transitions (A->B) ===')
for c,a,b in pairs[:16]:
    print('  %-7s -> %-7s : %7d  (%.1f%%)'%(NAMES[a],NAMES[b],c,100.0*c/tot))
if cr_precip:
    cr_precip.sort(); n=len(cr_precip)
    def q(p): return cr_precip[min(n-1,int(p*n))]
    inband=sum(1 for x in cr_precip if 0.024<=x<=0.036)
    print('\n=== CLEAR<->RAIN 转移时 precip 分布 (n=%d) ==='%n)
    print('  p10=%.4f p25=%.4f p50=%.4f p75=%.4f p90=%.4f'%(q(.1),q(.25),q(.5),q(.75),q(.9)))
    print('  在滞回带[0.024,0.036]内: %.1f%% (滞回本应拦下这些)'%(100.0*inband/n))
    print('  <0.024: %.1f%%   >0.036: %.1f%%'%(100.0*sum(1 for x in cr_precip if x<0.024)/n,100.0*sum(1 for x in cr_precip if x>0.036)/n))
