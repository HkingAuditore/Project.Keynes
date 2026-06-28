import csv
PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_164054.csv"
def f(x):
    try: return float(x)
    except: return 0.0
def ii(x):
    try: return int(float(x))
    except: return 0
seq=[]   # (tick, season_phase) for cell_index==0
with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); h=next(rdr); ix={n:k for k,n in enumerate(h)}
    iC=ix["cell_index"]; iT=ix["tick_idx"]; iSP=ix["phys_daily_wind_season_phase"]
    for row in rdr:
        if ii(row[iC])!=0: continue
        seq.append((ii(row[iT]), f(row[iSP])))
seq.sort()
# unwrap season phase (0..4 per year)
total=0.0
for i in range(1,len(seq)):
    d=seq[i][1]-seq[i-1][1]
    if d< -0.01: d+=4.0   # wrapped past year end
    total+=d
years=total/4.0
nt=seq[-1][0]-seq[0][0]
print("cell0 samples=%d  tick span=%d  unwrapped season-phase span=%.2f -> years=%.2f"%(len(seq),nt,total,years))
print("days/tick = 365*years/tick_span = %.2f"%(365.0*years/max(1,nt)))
