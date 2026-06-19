import csv

PATH = r'Project.Keynes/tmp/tile_data_record_20260619_184841.csv'
C = {'precip':163,'instability':169,'convergence':168,'transport_anom':193,
     'terrain':213,'is_water':223}

def fval(s):
    if not s: return 0.0
    try: return float(s)
    except: return 0.0

def clamp01(x): return 0.0 if x<0 else (1.0 if x>1 else x)

# Candidate new-drive parameter sets: (inst_thr, inst_band, conv_thr, conv_band, supp)
CANDS = {
 'A (conv.40 inst.78 supp.92)': (0.78,0.16, 0.40,0.16, 0.92),
 'B (conv.38 inst.78 supp.95)': (0.78,0.16, 0.38,0.16, 0.95),
 'C (conv.40 inst.80 supp.96)': (0.80,0.14, 0.40,0.14, 0.96),
}
OLD_SUPP=0.85

def old_drive(ocean_an, inst):
    return max(clamp01(ocean_an/0.16), clamp01((inst-0.74)/0.18))

def new_drive(ocean_an, inst, conv, p):
    it,ib,ct,cb,_=p
    return max(clamp01(ocean_an/0.16), clamp01((inst-it)/ib), clamp01((conv-ct)/cb))

# accumulate per candidate: water cells raining (>0.030) old vs new; precip by conv quartile
res = {k:{'wet_old':0,'wet_new':0,'n':0,'byq':[ [0,0],[0,0],[0,0],[0,0] ]} for k in CANDS}
# conv quartile edges (water) approx from earlier: p25~0.20,p50~0.31,p75~0.40
QED=[0.20,0.31,0.40]
def qidx(c):
    if c<QED[0]:return 0
    if c<QED[1]:return 1
    if c<QED[2]:return 2
    return 3

n_water=0
with open(PATH,'r',encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for row in rd:
        if len(row)<=C['is_water']: continue
        if int(fval(row[C['is_water']]))!=1: continue
        terr=int(fval(row[C['terrain']]))
        if terr==18: continue  # lake: not suppressed
        n_water+=1
        precip=fval(row[C['precip']]); inst=fval(row[C['instability']])
        conv=fval(row[C['convergence']]); oan=fval(row[C['transport_anom']])
        od=old_drive(oan,inst); omult=(1-OLD_SUPP)+OLD_SUPP*od
        for k,p in CANDS.items():
            supp=p[4]
            nd=new_drive(oan,inst,conv,p); nmult=(1-supp)+supp*nd
            # estimate new precip from recorded (already had old suppression)
            est = precip*(nmult/omult) if omult>1e-6 else precip
            r=res[k]; r['n']+=1
            if precip>0.030: r['wet_old']+=1
            if est>0.030: r['wet_new']+=1
            q=qidx(conv)
            r['byq'][q][0]+= (1 if est>0.030 else 0)
            r['byq'][q][1]+= 1

print(f"water non-lake cells: {n_water}\n")
for k in CANDS:
    r=res[k]; n=max(r['n'],1)
    print(f"=== {k} ===")
    print(f"  ocean raining(precip>0.030): OLD {100.0*r['wet_old']/n:.1f}%  ->  NEW {100.0*r['wet_new']/n:.1f}%")
    print( "  NEW raining-share by convergence quartile (Q1 low to Q4 high):")
    labels=['Q1<0.20','Q2','Q3','Q4>0.40']
    for qi in range(4):
        wet,tot=r['byq'][qi]
        print(f"    {labels[qi]}: {100.0*wet/max(tot,1):.1f}% rain  (n={tot})")
    print()
