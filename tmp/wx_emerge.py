# Deep emergence diagnostic on wx_133.npz: is the circulation/moisture capable of
# emergent traveling, self-dissipating weather systems?
import numpy as np
d=np.load("wx_133.npz"); R,COL,C=64,100,6400; T=d["ticks"].size
f=lambda k:d["f32_"+k]; i=lambda k:d["i8_"+k]; st=lambda k:d["st_"+k]
water=st("is_water_arr").astype(bool); land=~water
latrow=(np.arange(R)-31.5)/31.5*90
precip=f("weather_precip_arr"); vapor=f("weather_vapor_arr"); cw=f("weather_cloud_water_arr")
wx=f("wind_x_arr"); wy=f("wind_y_arr"); wspd=f("wind_speed_arr"); slp=f("slp_arr")
conv=f("weather_convergence_arr"); temp=f("temp_arr"); wt=i("weather_type_arr")
def line(s=""): print(s)
def hdr(s): print("\n"+"="*70+"\n"+s+"\n"+"="*70)

def tac(field, lags=(1,5,20,50,120)):
    # temporal autocorr of the field's anomaly (subtract time-mean per cell)
    a=field-field.mean(0,keepdims=True)
    out={}
    for k in lags:
        if k<T: out[k]=float(np.corrcoef(a[:-k].ravel(),a[k:].ravel())[0,1])
    return out

hdr("A. IS THE CIRCULATION STATIONARY? (wind / SLP temporal autocorr)")
line(f"T={T} ticks. Anomaly autocorr: 1.0=frozen/quasi-stationary, decay=traveling features.")
line(f"  wind_x : {tac(wx)}")
line(f"  wind_y : {tac(wy)}")
line(f"  SLP    : {tac(slp)}")
line(f"  wind_speed: {tac(wspd)}")
# how much does the wind change at all over time? std-over-time / std-over-space
wx_t_std = wx.std(0).mean(); wx_s_std = wx.std(1).mean()
line(f"  wind_x temporal-std/spatial-std = {wx_t_std/max(wx_s_std,1e-9):.3f} (low => wind barely changes in time)")
slp_t_std=slp.std(0).mean(); slp_s_std=slp.std(1).mean()
line(f"  SLP temporal-std/spatial-std = {slp_t_std/max(slp_s_std,1e-9):.3f}")

hdr("B. DO SLP LOWS TRAVEL? (midlat pressure-min longitude over time)")
g_slp=slp.reshape(T,R,COL)
mid=(np.abs(latrow)>=35)&(np.abs(latrow)<=65)
# for each tick, in N midlat band, longitude of min SLP
nrow=np.where(latrow>35)[0]
if nrow.size:
    band=g_slp[:,nrow,:].mean(1)            # [T,COL] zonal SLP in N midlat
    minlon=np.argmin(band,1)
    # does the min longitude drift coherently or jump randomly?
    dlon=np.diff(minlon.astype(int)); dlon=((dlon+COL//2)%COL)-COL//2  # wrap to [-50,50]
    line(f"N-midlat SLP-min longitude: std={minlon.std():.1f} cols, mean|step|={np.abs(dlon).mean():.1f} cols/tick")
    line(f"  net drift over window={((minlon[-1]-minlon[0]+COL//2)%COL)-COL//2} cols (coherent travel if large & monotone)")
    # autocorr of the midlat SLP zonal pattern
    ba=band-band.mean(0,keepdims=True)
    line(f"  midlat SLP zonal-pattern autocorr lag1={np.corrcoef(ba[:-1].ravel(),ba[1:].ravel())[0,1]:.2f} lag20={np.corrcoef(ba[:-20].ravel(),ba[20:].ravel())[0,1]:.2f}")

hdr("C. MOISTURE RECHARGE-DISCHARGE? (does precip deplete vapor & force dissipation)")
# spatial: are rain cells vapor-depleted?
pm=precip.mean(0); vm=vapor.mean(0)
rainy=pm>np.percentile(pm,90)
line(f"time-mean vapor: rainy-cells(top10% precip)={vm[rainy].mean():.3f} vs dry-cells={vm[~rainy].mean():.3f}")
line(f"  spatial corr(time-mean precip, time-mean vapor) land = {np.corrcoef(pm[land],vm[land])[0,1]:.3f} (NEG=rain depletes vapor)")
# temporal at-cell: precip[t] vs vapor change next step
dv=vapor[1:]-vapor[:-1]   # vapor tendency
pr0=precip[:-1]
ok=land[None,:].repeat(T-1,0)
line(f"  corr(precip[t], vapor_tendency[t->t+1]) land = {np.corrcoef(pr0[ok],dv[ok])[0,1]:.3f} (NEG=raining lowers vapor next step)")
# do rain cells persist or pulse? precip temporal autocorr
line(f"  precip temporal autocorr: {tac(precip,(1,5,20,50))}")
# vapor temporal autocorr (recharge time)
line(f"  vapor  temporal autocorr: {tac(vapor,(1,5,20,50))}")

hdr("D. OCEAN RAIN GENERATION (are systems born on the ocean, or only advected in?)")
# precip 'onset' events: cell goes from dry(<0.01) to wet(>0.03) between ticks
on=(precip[:-1]<0.01)&(precip[1:]>0.03)
on_ocean=on&water[None,:]; on_land=on&land[None,:]
line(f"precip onset events: ocean={int(on_ocean.sum())} land={int(on_land.sum())} (ocean/land={on_ocean.sum()/max(on_land.sum(),1):.2f})")
line(f"  ocean cells ever precipitating(>0.03): {int((precip[:,water]>0.03).any(0).sum())}/{int(water.sum())}")
# is ocean precip co-located with convergence (emergent) or just downwind of land?
oc=water[None,:]&(precip>0.03)
if oc.sum()>0:
    line(f"  ocean rain cells: mean convergence={conv[oc].mean():.3f} vs ocean-all conv={conv[:,water].mean():.3f}")
    line(f"  ocean rain cells: mean vapor={vapor[oc].mean():.3f} (high vapor source present?)")

hdr("E. CURRENT BAND STATE (precip, with Stage5 wave active)")
from scipy import ndimage
g=precip.reshape(T,R,COL); struct=np.array([[0,1,0],[1,1,1],[0,1,0]])
largest=[]
for t in range(0,T,3):
    m=g[t]>0.02
    if m.sum()==0: continue
    lab,nb=ndimage.label(m,structure=struct)
    if nb==0: continue
    _,cn=np.unique(lab[m],return_counts=True); largest.append(cn.max()/m.sum())
largest=np.array(largest)
line(f"largest-blob share (no wrap-merge, every 3rd tick): mean={largest.mean():.2f} (was 0.47 pre-Stage5)")
trop=np.abs(latrow)<25
line(f"precip mass in |lat|<25 band: {100*g[:,np.abs(latrow)<25,:].sum()/g.sum():.1f}%")
print("\n[done]")
