import csv
from collections import Counter, defaultdict

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_164054.csv"
TYPE_NAMES=["CLEAR","RAIN","STORM","BLIZZARD","DROUGHT","FOG","HEATWAVE","MONSOON"]
def ii(x):
    try: return int(float(x))
    except: return 0
def f(x):
    try: return float(x)
    except: return 0.0

with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    iT=ix["weather_type_arr"]; iTgt=ix["weather_target_type_arr"]
    iPv=ix["weather_prev_type_arr"]; iAl=ix["weather_transition_alpha_arr"]
    disp=Counter(); tgt=Counter(); prev=Counter()
    alpha_hist=defaultdict(int); rows=0
    # per-cell: how many distinct TARGET types vs distinct DISPLAY types
    cell_tgt=defaultdict(set); cell_disp=defaultdict(set)
    iC=ix["cell_index"]
    # how often target != display (transition lag)
    lag=0
    for row in rdr:
        rows+=1
        d=ii(row[iT]); t=ii(row[iTgt]); p=ii(row[iPv]); a=f(row[iAl])
        ci=ii(row[iC])
        disp[d]+=1; tgt[t]+=1; prev[p]+=1
        cell_tgt[ci].add(t); cell_disp[ci].add(d)
        if d!=t: lag+=1
        ab=min(10,int(a*10)); alpha_hist[ab]+=1

tot=sum(disp.values())
print("rows=%d" % rows)
print("\n=== TARGET (classifier output) vs DISPLAY (after transition) ===")
print("  %-9s   TARGET            DISPLAY" % "TYPE")
for k in range(8):
    print("  %-9s  %8d(%6.3f%%)  %8d(%6.3f%%)" % (TYPE_NAMES[k],
        tgt.get(k,0),100.0*tgt.get(k,0)/max(1,tot),
        disp.get(k,0),100.0*disp.get(k,0)/max(1,tot)))
print("\n  display != target (in-transition / suppressed): %d (%.2f%%)" % (lag,100.0*lag/max(1,tot)))
print("\n=== TRANSITION ALPHA distribution (bin=0.1) ===")
for b in range(11):
    print("  alpha[%.1f-%.1f): %d (%.2f%%)" % (b/10.0,(b+1)/10.0,alpha_hist.get(b,0),100.0*alpha_hist.get(b,0)/max(1,tot)))
# per-cell variety
vt=Counter(len(s) for s in cell_tgt.values())
vd=Counter(len(s) for s in cell_disp.values())
print("\n=== PER-CELL TYPE VARIETY ===")
print("  TARGET  variety (distinct types a cell's classifier produced):", dict(sorted(vt.items())))
print("  DISPLAY variety (distinct types a cell actually showed)      :", dict(sorted(vd.items())))
ncells=len(cell_disp)
never_disp=sum(1 for ci in cell_disp if len(cell_disp[ci])==1)
multi_tgt_single_disp=sum(1 for ci in cell_disp if len(cell_tgt[ci])>1 and len(cell_disp[ci])==1)
print("  cells with single DISPLAY type: %d/%d (%.1f%%)" % (never_disp,ncells,100.0*never_disp/max(1,ncells)))
print("  cells whose classifier produced MULTIPLE types but DISPLAY stuck at ONE: %d (%.1f%%)" % (
    multi_tgt_single_disp,100.0*multi_tgt_single_disp/max(1,ncells)))
