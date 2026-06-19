import csv

PATH = r'Project.Keynes/tmp/tile_data_record_20260619_201314.csv'
C = {'cloud':161,'precip':163,'vapor':167,'conv':168,'inst':169,'tta':193,
     'terrain':213,'wt':220,'is_water':223}

def fv(s):
    try: return float(s)
    except: return 0.0
def iv(s):
    try: return int(float(s))
    except: return -1
def cl(x): return 0.0 if x<0 else (1.0 if x>1 else x)

def meaningful(precip, cloud, vapor):
    return precip>0.030 or (precip>0.022 and cloud>0.22 and vapor>0.28)

# committed-current drive (omit frontogenesis -> lower bound on drive_old)
def drive_old(tta,inst,conv):
    return max(cl(tta/0.16), cl((inst-0.78)/0.16), cl((conv-0.38)/0.16))

# Candidates: function(tta,inst,conv)->drive_new
CANDS = {
 'cur (inst.78 conv.38)':         lambda t,i,c: max(cl(t/0.16), cl((i-0.78)/0.16), cl((c-0.38)/0.16)),
 'A no-inst conv.38':             lambda t,i,c: max(cl(t/0.16), cl((c-0.38)/0.16)),
 'B no-inst conv.42':             lambda t,i,c: max(cl(t/0.16), cl((c-0.42)/0.14)),
 'C strict-inst.90 conv.38':      lambda t,i,c: max(cl(t/0.16), cl((i-0.90)/0.10), cl((c-0.38)/0.16)),
 'D strict-inst.88 conv.42':      lambda t,i,c: max(cl(t/0.16), cl((i-0.88)/0.10), cl((c-0.42)/0.14)),
 'E no-inst conv.45':             lambda t,i,c: max(cl(t/0.16), cl((c-0.45)/0.12)),
}
SUPP=0.95
def mult(d): return (1-SUPP)+SUPP*d

res={k:{'wet':0,'n':0,'byq':[[0,0],[0,0],[0,0],[0,0]]} for k in CANDS}
res['__actual__']={'wet':0,'n':0}
# convergence quartile edges from observed water dist
QED=[0.193,0.308,0.373]
def qi(c):
    if c<QED[0]:return 0
    if c<QED[1]:return 1
    if c<QED[2]:return 2
    return 3

water=0
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        if iv(row[C['is_water']])!=1: continue
        terr=iv(row[C['terrain']])
        if terr==18: continue  # lake
        water+=1
        precip=fv(row[C['precip']]); cloud=fv(row[C['cloud']]); vapor=fv(row[C['vapor']])
        conv=fv(row[C['conv']]); inst=fv(row[C['inst']]); tta=fv(row[C['tta']])
        # actual recorded wet
        if meaningful(precip,cloud,vapor):
            res['__actual__']['wet']+=1
        res['__actual__']['n']+=1
        do=drive_old(tta,inst,conv); mo=mult(do)
        if mo<1e-6: mo=1e-6
        praw=precip/mo
        q=qi(conv)
        for k,fn in CANDS.items():
            dn=fn(tta,inst,conv); pn=praw*mult(dn)
            r=res[k]; r['n']+=1
            if meaningful(pn,cloud,vapor):
                r['wet']+=1; r['byq'][q][0]+=1
            r['byq'][q][1]+=1

a=res['__actual__']
print(f"water non-lake cells={water}")
print(f"ACTUAL recorded wet(meaningful_precip) = {100.0*a['wet']/max(a['n'],1):.1f}%  (sanity vs reported water RAIN+STORM 47.6%)\n")
print("candidate -> estimated water wet%% (and raining-share by convergence quartile Q1 low..Q4 high):")
for k in CANDS:
    r=res[k]; n=max(r['n'],1)
    qs=' '.join(f"Q{j+1}={100.0*r['byq'][j][0]/max(r['byq'][j][1],1):.0f}%" for j in range(4))
    print(f"  {k:28s}: wet={100.0*r['wet']/n:5.1f}%   [{qs}]")
