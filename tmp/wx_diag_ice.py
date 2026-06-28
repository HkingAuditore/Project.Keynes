import csv
from collections import defaultdict

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_164054.csv"
def ii(x):
    try: return int(float(x))
    except: return 0
def f(x):
    try: return float(x)
    except: return 0.0

# sea ice knobs (climate_profile.gd)
K_FREEZE=0.40; K_MELT=1.45; T_FORM=0.06; T_MELT=0.11
INSOL_LOW=0.22; INSOL_HIGH=0.45; MELT_START=0.28; MELT_GAIN=1.35; CAP=0.070

def freeze_gate(ins):
    # fully open below low, fully closed above high (smoothstep down)
    if ins<=INSOL_LOW: return 1.0
    if ins>=INSOL_HIGH: return 0.0
    t=(ins-INSOL_LOW)/(INSOL_HIGH-INSOL_LOW)
    return 1.0-(t*t*(3.0-2.0*t))
def solar_melt(ins):
    if ins<=MELT_START: return 0.0
    return (ins-MELT_START)*MELT_GAIN

with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); header=next(rdr)
    ix={n:k for k,n in enumerate(header)}
    iW=ix["is_water_arr"]; iT=ix["temp_arr"]; iIce=ix["sea_ice_frac_arr"]
    iIns=ix["insolation_now_arr"]
    # cold water (temp<0.10): bin by insolation
    ins_bin=defaultdict(lambda:[0.0,0])     # ins bin -> [sum_ice,n]
    # net daily rate for cold water at frac~0.9 (does it hold?) and frac~0 (does it build?)
    drive_hold=[]   # at frac=0.9
    drive_build=[]  # at frac=0.05
    blocked=0; cold_n=0
    # steady state estimate: freeze vs melt drive sign for cold water
    rows=0
    for row in rdr:
        rows+=1
        if ii(row[iW])!=1: continue
        temp=f(row[iT]); ice=f(row[iIce]); ins=f(row[iIns])
        if temp<0.10:
            cold_n+=1
            ib=min(9,int(ins*10)); b=ins_bin[ib]; b[0]+=ice; b[1]+=1
            if ins>=INSOL_HIGH: blocked+=1
            # net rate at this temp/insol (t_eff~temp, ignore OHT)
            t_eff=temp
            df=max(T_FORM-t_eff,0.0); dm=max(t_eff-T_MELT,0.0)
            fg=freeze_gate(ins); sm=solar_melt(ins)
            # hold test: frac=0.9 -> solar_exposure ~ depends; approximate exposure=1
            rate_hold = K_FREEZE*df*fg - (K_MELT*dm + sm*1.0)
            rate_build= K_FREEZE*df*fg - (K_MELT*dm + sm*1.0)
            drive_hold.append(rate_hold)

print("rows=%d cold_water_ticks=%d" % (rows,cold_n))
print("\n=== COLD WATER (temp<0.10): mean_ice by INSOLATION bin ===")
for b in sorted(ins_bin):
    s,n=ins_bin[b]
    print("  insol[%.1f-%.1f): mean_ice=%.3f (n=%d)" % (b/10.0,(b+1)/10.0,s/max(1,n),n))
print("\n  cold-water ticks with insol>=%.2f (freeze FULLY blocked by solar gate): %.1f%%" % (
    INSOL_HIGH, 100.0*blocked/max(1,cold_n)))
# net drive stats for cold water
drive_hold.sort()
def pc(a,p): return a[min(len(a)-1,int(p*len(a)))] if a else 0.0
n=len(drive_hold)
pos=sum(1 for x in drive_hold if x>0)
print("\n=== NET ICE RATE for cold water (temp<0.10), per-day, no-OHT approx ===")
print("  (positive=freezing, negative=melting; cap=%.3f)" % CAP)
print("  p10=%.4f p50=%.4f p90=%.4f  | %% freezing(rate>0)=%.1f%%  %% melting=%.1f%%" % (
    pc(drive_hold,.1),pc(drive_hold,.5),pc(drive_hold,.9),100.0*pos/max(1,n),100.0*(n-pos)/max(1,n)))
print("  NOTE: freeze drive K_FREEZE*max(T_FORM-temp,0)*gate; e.g. temp=0.03 -> %.4f/day at gate=1 (=>%.0f days to reach flip 0.72)" % (
    K_FREEZE*max(T_FORM-0.03,0.0)*1.0, 0.72/max(1e-6,K_FREEZE*max(T_FORM-0.03,0.0)*1.0)))
