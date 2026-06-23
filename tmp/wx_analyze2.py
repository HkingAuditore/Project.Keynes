# Sections 4-8: zonal climate, fronts/monsoon/typhoon, ocean-vs-land,
# snow/snowline, weather->climate->veg coupling, weird-distribution checks.
# Renders spatial + zonal + temporal figures to wx_figs/.
import numpy as np, os
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap, BoundaryNorm

d = np.load("wx_arrays.npz"); dv = np.load("wx_derived.npz")
R, COL, C, T = 64, 100, 6400, 412
f32=lambda k:d["f32_"+k]; i8=lambda k:d["i8_"+k]; sc=lambda k:d["sc_"+k]; st=lambda k:d["st_"+k]
def line(s=""): print(s)
def hdr(s): print("\n"+"="*78+"\n"+s+"\n"+"="*78)
def grid(a): return a.reshape(R,COL)   # row=lat(0=S pole), col=lon

WT_NAMES={0:"CLEAR",1:"RAIN",2:"STORM",3:"BLIZZARD",4:"DROUGHT",5:"FOG",6:"HEATWAVE",7:"MONSOON"}
lat=st("cell_lat_norm_arr"); water=st("is_water_arr").astype(bool); land=~water
elev=st("elevation_arr")
precip=f32("weather_precip_arr"); inten=f32("weather_intensity_arr")
temp=f32("temp_arr"); moist=f32("moisture_arr"); snow=f32("snow_cover_arr")
snowpk=f32("snowpack_arr"); seaice=f32("sea_ice_frac_arr"); veg=f32("vegetation_vitality_arr")
cloudw=f32("weather_cloud_water_arr"); vapor=f32("weather_vapor_arr"); conv=f32("weather_convergence_arr")
wt=i8("weather_type_arr")
precip_frac=dv["precip_frac"]; latdeg=dv["latdeg"]; abslat=dv["abslat"]

pm = precip.mean(axis=0)        # time-mean precip per cell
tm = temp.mean(axis=0); mm=moist.mean(axis=0); sm=snow.mean(axis=0); vm=veg.mean(axis=0)
icem=seaice.mean(axis=0)

# ---- zonal means by latitude row ----
def zonal(per_cell, mask=None):
    a=per_cell.copy().astype(float)
    if mask is not None: a[~mask]=np.nan
    return np.nanmean(grid(a),axis=1)   # length R
latrow = grid(lat)[:,0]
zlatdeg=(latrow-0.5)*180

hdr("4. GLOBAL-SCALE ZONAL CLIMATE (does 3-cell circulation emerge?)")
zp=zonal(pm); zt=zonal(tm); zpf=zonal(precip_frac)
line("lat_band(deg)   meanTemp  meanPrecip  precipFrac  (sample every 4th row, S->N)")
for r in range(0,R,4):
    line(f"  {zlatdeg[r]:+6.1f}    {zt[r]:7.3f}   {zp[r]:9.4f}   {zpf[r]:6.3f}")
# locate ITCZ (precip max near equator) and subtropical dry belts
eq_band=(np.abs(zlatdeg)<15); sub_band=(np.abs(zlatdeg)>20)&(np.abs(zlatdeg)<40); mid_band=(np.abs(zlatdeg)>45)&(np.abs(zlatdeg)<70)
line(f"equatorial(|lat|<15) mean precip={np.nanmean(zp[eq_band]):.4f}")
line(f"subtropical(20-40)   mean precip={np.nanmean(zp[sub_band]):.4f}  (should be a DRY minimum)")
line(f"midlat(45-70)        mean precip={np.nanmean(zp[mid_band]):.4f}  (storm-track wet)")
line(f"temp gradient eq->pole: eq={np.nanmean(zt[eq_band]):.3f} pole={np.nanmean(zt[np.abs(zlatdeg)>75]):.3f}")

hdr("5. FRONTS / MONSOON / TYPHOON")
cf=sc("weather_cold_front_count"); wf=sc("weather_warm_front_count")
line(f"cold_front_count over ticks: mean={np.nanmean(cf):.1f} min={np.nanmin(cf):.0f} max={np.nanmax(cf):.0f}")
line(f"warm_front_count over ticks: mean={np.nanmean(wf):.1f} min={np.nanmin(wf):.0f} max={np.nanmax(wf):.0f}")
line(f"cold:warm ratio mean={np.nanmean(cf)/max(np.nanmean(wf),1e-6):.2f}")
# MONSOON spatial: where does type 7 occur (by latitude, land/coast)
mon=(wt==7); mon_by_cell=mon.mean(axis=0)
mlat=latdeg[mon_by_cell>0]
if mlat.size:
    line(f"MONSOON: {int((mon_by_cell>0).sum())} cells ever; |lat| mean={np.mean(np.abs(mlat)):.1f} deg; on-land frac={np.mean(land[mon_by_cell>0]):.2f}")
# TYPHOON proxy: STORM on water, low-lat, high intensity
typ = (wt==2) & water[None,:] & (np.abs(latdeg)[None,:]<45) & (inten>0.6)
typ_cells=typ.any(axis=0)
line(f"TYPHOON proxy (STORM+water+|lat|<45+intensity>0.6): {int(typ_cells.sum())} cells ever, {int(typ.sum())} cell-ticks; max intensity={inten[(wt==2)&water[None,:]].max() if ((wt==2)&water[None,:]).any() else 0:.2f}")

hdr("6. OCEAN vs LAND weather generation")
for nm,mask in [("OCEAN",water),("LAND",land)]:
    sub=wt[:,mask].ravel(); n=sub.size
    frac={t:100*np.mean(sub==t) for t in range(8)}
    line(f"{nm}: "+"  ".join(f"{WT_NAMES[t][:4]}={frac[t]:.2f}%" for t in [0,1,2,3,4,5,7]))
    line(f"   mean precip={precip[:,mask].mean():.4f}  mean cloud_water={cloudw[:,mask].mean():.4f}  mean vapor={vapor[:,mask].mean():.4f}")

hdr("7. SNOW / SNOWLINE / SEA-ICE coupling")
# snow should track cold temp & high elev/lat
has_snow=(snow>0.05)
sc_cells=has_snow.any(axis=0)
if sc_cells.any():
    line(f"cells with snow ever: {int(sc_cells.sum())} ({100*sc_cells.sum()/C:.1f}%)")
    snmask=has_snow.mean(axis=0)>0.05
    line(f"  among snowy cells: mean temp={tm[snmask].mean():.3f} (cold?) mean |lat|={np.abs(latdeg)[snmask].mean():.1f} mean elev={elev[snmask].mean():.3f}")
    line(f"  non-snow cells:    mean temp={tm[~snmask].mean():.3f} mean |lat|={np.abs(latdeg)[~snmask].mean():.1f} mean elev={elev[~snmask].mean():.3f}")
# correlation snow vs temp (per-cell time-mean)
def corr(a,b,m=None):
    a=a.ravel() if a.ndim==1 else a; b=b.ravel() if b.ndim==1 else b
    if m is not None: a,b=a[m],b[m]
    ok=np.isfinite(a)&np.isfinite(b)
    if ok.sum()<3 or np.std(a[ok])==0 or np.std(b[ok])==0: return float('nan')
    return float(np.corrcoef(a[ok],b[ok])[0,1])
line(f"corr(time-mean snow, time-mean temp) per cell = {corr(sm,tm):.3f} (expect strong NEGATIVE)")
line(f"corr(snow, |lat|) = {corr(sm,np.abs(latdeg)):.3f} (expect POSITIVE)")
line(f"corr(snow, elev) on land = {corr(sm,elev,land):.3f} (expect POSITIVE)")
line(f"sea-ice: cells ever icy={int((seaice>0.05).any(axis=0).sum())}; corr(ice,|lat|)={corr(icem,np.abs(latdeg)):.3f}; ocean-only |lat| of icy={np.abs(latdeg)[(icem>0.05)].mean() if (icem>0.05).any() else float('nan'):.1f}")

hdr("8. WEATHER -> CLIMATE -> VEGETATION coupling")
line(f"corr(time-mean precip, time-mean moisture) = {corr(pm,mm):.3f} (expect POSITIVE)")
line(f"corr(time-mean precip, time-mean veg_vitality) land = {corr(pm,vm,land):.3f}")
line(f"corr(time-mean moisture, time-mean veg) land = {corr(mm,vm,land):.3f}")
# temporal lag: global precip anomaly vs global moisture next-step
gp=precip.mean(1); gm=moist.mean(1)
line(f"corr(global precip[t], global moisture[t]) = {np.corrcoef(gp,gm)[0,1]:.3f}")
line(f"corr(global precip[t], global moisture[t+1]) = {np.corrcoef(gp[:-1],gm[1:])[0,1]:.3f}")

hdr("9. WEIRD-DISTRIBUTION / ARTIFACT CHECKS")
# NaNs
for k in ["weather_precip_arr","temp_arr","moisture_arr","weather_vapor_arr","weather_cloud_water_arr"]:
    a=f32(k); line(f"  NaN in {k}: {int(np.isnan(a).sum())}")
# x-wrap edge: col0 vs col99 precip continuity
g=grid(pm);
line(f"x-edge precip: col0 mean={g[:,0].mean():.4f} col99 mean={g[:,-1].mean():.4f} (wrap should be similar)")
line(f"pole rows precip: row0(S)={g[0].mean():.4f} row63(N)={g[-1].mean():.4f} interior={g[20:44].mean():.4f}")
# stuck cells: zero temporal variance but nonzero precip
pv=precip.std(axis=0); stuck=(pv<1e-6)&(pm>0.02)
line(f"stuck precip cells (var~0 & precip>0.02): {int(stuck.sum())}")
# single-cell spikes: cell precip >> max neighbor (4-neighborhood on grid), persistently
gpm=grid(pm)
nb=np.full_like(gpm,np.nan)
nbmax=np.fmax.reduce([np.roll(gpm,1,0),np.roll(gpm,-1,0),np.roll(gpm,1,1),np.roll(gpm,-1,1)])
spike=(gpm>0.04)&(gpm>3*nbmax)
line(f"isolated precip spikes (>0.04 & >3x neighbor max): {int(spike.sum())}")
# perma-rain cell locations
pr_cells=np.where(precip_frac>=0.999)[0]
line(f"PERMA-RAIN cells (n={len(pr_cells)}): row(lat),col,elev,land?,latdeg")
for ci in pr_cells[:20]:
    r,c=divmod(ci,COL); line(f"   cell {ci}: row={r} col={c} elev={elev[ci]:.2f} {'LAND' if land[ci] else 'ocean'} lat={latdeg[ci]:+.0f}  precip_mean={pm[ci]:.3f}")

# ============ FIGURES ============
def savemap(ax,arr,title,cmap="viridis",vmin=None,vmax=None,mask_water=False):
    a=grid(arr.astype(float)).copy()
    if mask_water: a[grid(water)]=np.nan
    im=ax.imshow(a,origin="lower",aspect="auto",cmap=cmap,vmin=vmin,vmax=vmax)
    ax.set_title(title,fontsize=9); ax.set_xticks([]); ax.set_yticks([])
    plt.colorbar(im,ax=ax,fraction=0.025)
fig,axs=plt.subplots(3,3,figsize=(18,11))
savemap(axs[0,0],pm,"Time-mean PRECIP (perma-rain?)",cmap="Blues",vmax=np.percentile(pm,99))
savemap(axs[0,1],precip_frac,"Fraction-of-time RAINING",cmap="Blues",vmin=0,vmax=1)
savemap(axs[0,2],tm,"Time-mean TEMP",cmap="RdBu_r")
savemap(axs[1,0],mm,"Time-mean MOISTURE",cmap="BrBG")
savemap(axs[1,1],sm,"Time-mean SNOW cover",cmap="bone_r",vmin=0,vmax=max(sm.max(),0.01))
savemap(axs[1,2],vm,"Time-mean VEG vitality",cmap="YlGn")
# weather-type mode per cell
mode=np.zeros(C,int)
for c in range(C):
    mode[c]=np.bincount(wt[:,c],minlength=8).argmax()
cmap_t=ListedColormap(["#dddddd","#3b8bff","#7a2fff","#bfe9ff","#d99a00","#9aa0a6","#ff3030","#00b050"])
im=axs[2,0].imshow(grid(mode),origin="lower",aspect="auto",cmap=cmap_t,vmin=-0.5,vmax=7.5)
axs[2,0].set_title("Dominant weather TYPE per cell",fontsize=9);axs[2,0].set_xticks([]);axs[2,0].set_yticks([])
plt.colorbar(im,ax=axs[2,0],ticks=range(8),fraction=0.025)
savemap(axs[2,1],icem,"Time-mean SEA-ICE",cmap="PuBu",vmin=0,vmax=max(icem.max(),0.01))
savemap(axs[2,2],elev,"Elevation (ref)",cmap="terrain")
plt.tight_layout(); plt.savefig("wx_figs/maps.png",dpi=90); plt.close()

# zonal + temporal figure
fig,axs=plt.subplots(2,2,figsize=(15,9))
axs[0,0].plot(zlatdeg,zp,'b-o',ms=3); axs[0,0].set_title("Zonal mean PRECIP vs latitude (ITCZ/subtropics?)");axs[0,0].axhline(0,c='k',lw=.5);axs[0,0].set_xlabel("lat deg");axs[0,0].grid(alpha=.3)
ax2=axs[0,0].twinx(); ax2.plot(zlatdeg,zt,'r-',alpha=.6,label="temp"); ax2.set_ylabel("temp",color='r')
axs[0,1].plot(precip.mean(1),label="global mean precip"); axs[0,1].plot((precip>0.02).sum(1)/C,label="frac cells raining")
axs[0,1].set_title("Global precip over time (pulsing/dynamic?)");axs[0,1].legend(fontsize=8);axs[0,1].set_xlabel("tick");axs[0,1].grid(alpha=.3)
axs[1,0].plot(cf,label="cold fronts"); axs[1,0].plot(wf,label="warm fronts")
axs[1,0].set_title("Front counts over time");axs[1,0].legend(fontsize=8);axs[1,0].set_xlabel("tick");axs[1,0].grid(alpha=.3)
# type counts over time (stacked-ish)
for t in [1,2,7,3,4,5]:
    axs[1,1].plot((wt==t).sum(1),label=WT_NAMES[t])
axs[1,1].set_title("Active weather-type cell counts over time");axs[1,1].legend(fontsize=7,ncol=2);axs[1,1].set_xlabel("tick");axs[1,1].grid(alpha=.3)
plt.tight_layout(); plt.savefig("wx_figs/zonal_time.png",dpi=90); plt.close()
print("\n[figures saved: wx_figs/maps.png, wx_figs/zonal_time.png]")
