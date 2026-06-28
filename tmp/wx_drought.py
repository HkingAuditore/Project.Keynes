import csv
from collections import defaultdict

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_164054.csv"
NAMES = {0:"CLEAR",1:"RAIN",2:"STORM",3:"BLIZZARD",4:"DROUGHT",5:"FOG",6:"HEATWAVE",7:"MONSOON"}

def f(x):
    try: return float(x)
    except: return 0.0
def ii(x):
    try: return int(float(x))
    except: return 0

# per-cell ordered sequence of display weather type, plus static climate sample
seq = defaultdict(list)          # cell -> [wtype,...] in tick order
clim = {}                        # cell -> (sum_temp,sum_vapor,sum_precip,sum_cloud,sum_lat,is_water,n)

rows=0
with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    iCell=ix["cell_index"]; iWT=ix["weather_type_arr"]
    iW=ix["is_water_arr"]; iT=ix["temp_arr"]; iV=ix["weather_vapor_arr"]
    iP=ix["weather_precip_arr"]; iC=ix["weather_cloud_arr"]; iLat=ix["cell_lat_norm_arr"]
    for row in rdr:
        rows+=1
        c=ii(row[iCell]); wt=ii(row[iWT])
        seq[c].append(wt)
        a=clim.get(c)
        if a is None:
            clim[c]=[f(row[iT]),f(row[iV]),f(row[iP]),f(row[iC]),f(row[iLat]),ii(row[iW]),1]
        else:
            a[0]+=f(row[iT]); a[1]+=f(row[iV]); a[2]+=f(row[iP]); a[3]+=f(row[iC])
            a[4]+=f(row[iLat]); a[6]+=1

ncells=len(seq)
print("rows=%d cells=%d ticks/cell~=%d" % (rows,ncells,rows//max(1,ncells)))

# ---------- Q1: never-change cells ----------
static_by_type=defaultdict(lambda:[0,0,0.0,0.0,0.0,0.0,0.0])  # (type,water)->[n, water, T,V,P,C,Lat]
varieties=defaultdict(int)
for c,s in seq.items():
    types=set(s)
    varieties[len(types)]+=1
    if len(types)==1:
        wt=s[0]; a=clim[c]; n=a[6]; water=1 if a[5]>0 else 0
        key=(wt,water)
        g=static_by_type[key]
        g[0]+=1
        g[2]+=a[0]/n; g[3]+=a[1]/n; g[4]+=a[2]/n; g[5]+=a[3]/n; g[6]+=a[4]/n
print("\n=== per-cell DISTINCT display-type count ===")
for k in sorted(varieties): print("  %d types: %d cells (%.1f%%)" % (k,varieties[k],100.0*varieties[k]/ncells))
nstatic=varieties.get(1,0)
print("  -> never-change: %d/%d = %.1f%%" % (nstatic,ncells,100.0*nstatic/ncells))

print("\n=== Q1: WHAT are the never-change cells? (mean climate of each static group) ===")
print("  type(water?)        cells   mean_temp vapor  precip cloud  lat")
for key in sorted(static_by_type, key=lambda k:-static_by_type[k][0]):
    wt,water=key; g=static_by_type[key]; n=g[0]
    print("  %-9s %-7s %5d    %.3f   %.3f  %.4f %.3f  %.3f" % (
        NAMES[wt], "water" if water else "land", n, g[2]/n, g[3]/n, g[4]/n, g[5]/n, g[6]/n))

# ---------- Q2: DROUGHT<->RAIN alternation persistence ----------
def rle(s):
    out=[]; 
    for v in s:
        if out and out[-1][0]==v: out[-1][1]+=1
        else: out.append([v,1])
    return out

dr_cells=0
sum_drought_runs=[]; sum_rain_runs=[]
direct_DR=0; via_clear_DR=0     # transitions between drought and rain: adjacent vs separated
samples=[]
for c,s in seq.items():
    types=set(s)
    if 4 in types and 1 in types:
        dr_cells+=1
        segs=rle(s)
        for v,L in segs:
            if v==4: sum_drought_runs.append(L)
            if v==1: sum_rain_runs.append(L)
        # count drought<->rain transitions
        for i in range(len(segs)-1):
            a=segs[i][0]; b=segs[i+1][0]
            if (a==4 and b==1) or (a==1 and b==4): direct_DR+=1
        # via clear: drought ... (only clear/other between) ... rain
        for i in range(len(segs)-2):
            a=segs[i][0]; mid=segs[i+1][0]; b=segs[i+2][0]
            if ((a==4 and b==1) or (a==1 and b==4)): via_clear_DR+=1
        if len(samples)<6:
            samples.append((c,segs))

def stat(a):
    if not a: return (0,0,0)
    a2=sorted(a); n=len(a2)
    return (sum(a)/n, a2[n//2], max(a2))

print("\n=== Q2: cells showing BOTH DROUGHT and RAIN ===")
print("  such cells: %d/%d (%.1f%%)" % (dr_cells,ncells,100.0*dr_cells/ncells))
m,med,mx=stat(sum_drought_runs)
print("  DROUGHT run-length (consecutive ticks): mean=%.1f median=%d max=%d  (~%.0f / %d / %.0f days @9d/tick)"%(m,med,mx,m*9,med*9,mx*9))
m,med,mx=stat(sum_rain_runs)
print("  RAIN    run-length (consecutive ticks): mean=%.1f median=%d max=%d  (~%.0f / %d / %.0f days @9d/tick)"%(m,med,mx,m*9,med*9,mx*9))
print("  adjacent DROUGHT<->RAIN segment transitions (no CLEAR between): %d" % direct_DR)
print("  DROUGHT<->RAIN separated by exactly one CLEAR/other segment   : %d" % via_clear_DR)

print("\n=== sample DROUGHT/RAIN cell sequences (run-length encoded; (type,len_ticks)) ===")
for c,segs in samples:
    comp=" ".join("%s:%d"%(NAMES[v][:2],L) for v,L in segs if L>=1)
    print("  cell %d:" % c)
    print("    "+comp[:240])
