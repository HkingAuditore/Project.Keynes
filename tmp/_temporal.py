import csv, sys
from collections import Counter, defaultdict
PATH = sys.argv[1] if len(sys.argv)>1 else r'Project.Keynes/tmp/tile_data_record_20260619_234914.csv'
C={'tick':1,'simday':61,'solvetick':48,'windperiod':82,'windran':122,'windphase':121,
   'activeratio':44,'wt':220,'terr':213,'cell':144,'precip':163,'skipped':3,'convstride':49}
WT={0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}
LAKE=18
def iv(s):
    try: return int(float(s))
    except: return -1
def fv(s):
    try: return float(s)
    except: return 0.0

per_tick={}              # tick -> diag tuple (first row)
cell_types=defaultdict(set)     # cell -> set of wt over ticks
lake_cells=set()
cell_terr={}
n=0
with open(PATH,encoding='utf-8-sig',newline='') as f:
    rd=csv.reader(f); next(rd)
    for r in rd:
        if len(r)<=C['terr']: continue
        n+=1
        tick=iv(r[C['tick']]); cell=iv(r[C['cell']]); wt=iv(r[C['wt']]); terr=iv(r[C['terr']])
        if tick not in per_tick:
            per_tick[tick]=(iv(r[C['simday']]),iv(r[C['solvetick']]),fv(r[C['windperiod']]),
                            iv(r[C['windran']]),fv(r[C['windphase']]),fv(r[C['activeratio']]),
                            iv(r[C['skipped']]),fv(r[C['convstride']]))
        cell_types[cell].add(wt)
        if cell not in cell_terr: cell_terr[cell]=terr
        if terr==LAKE: lake_cells.add(cell)

ticks=sorted(per_tick)
print(f"rows={n}  unique_ticks={len(ticks)}  ticks={ticks[:30]}")
print(f"unique_cells={len(cell_types)}")
print("\n=== per-tick diagnostics (tick: simday solve_tick wind_period wind_ran wind_phase active_ratio skipped conv_stride) ===")
for t in ticks[:30]:
    d=per_tick[t]
    print(f"  t={t}: day={d[0]} solveT={d[1]} windPer={d[2]:.0f} windRan={d[3]} windPhase={d[4]:.3f} active={d[5]:.4f} skip={d[6]} convStride={d[7]:.0f}")

# temporal variation: distinct weather types per cell
distinct=Counter()
for cell,s in cell_types.items():
    distinct[len(s)]+=1
tot=len(cell_types)
print(f"\n=== temporal variation: # distinct weather types per cell over {len(ticks)} ticks ===")
for k in sorted(distinct):
    print(f"  {k} type(s): {distinct[k]} cells ({100.0*distinct[k]/tot:.1f}%)")
static=distinct.get(1,0)
print(f"  -> FULLY STATIC (never changes): {100.0*static/tot:.1f}% of cells")

# never-rain vs always-wet
PRECIP_T={1,2,3,7}  # RAIN/STORM/BLIZZARD/MONSOON
never_wet=sum(1 for s in cell_types.values() if not (s & PRECIP_T))
always_wet=sum(1 for s in cell_types.values() if s <= PRECIP_T)  # only precip types
print(f"\n  never any precip-type (always dry): {100.0*never_wet/tot:.1f}%")
print(f"  always precip-type (never dry): {100.0*always_wet/tot:.1f}%")

# lake now
ln=len(lake_cells)
lake_static=sum(1 for c in lake_cells if len(cell_types[c])==1)
lake_dist=Counter()
for c in lake_cells:
    for wt in cell_types[c]: lake_dist[wt]+=1  # union (presence)
print(f"\n=== LAKE cells={ln}  fully-static={100.0*lake_static/max(ln,1):.1f}% ===")
print("  lake weather presence(union over ticks): "+', '.join(f"{WT[k]} {v}" for k,v in lake_dist.most_common()))
lake_always_storm=sum(1 for c in lake_cells if cell_types[c]<= {2})
lake_has_storm=sum(1 for c in lake_cells if 2 in cell_types[c])
print(f"  lake always-only-STORM: {100.0*lake_always_storm/max(ln,1):.1f}%   lake ever-STORM: {100.0*lake_has_storm/max(ln,1):.1f}%")
