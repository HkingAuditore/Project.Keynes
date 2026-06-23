# Verify user's two observations:
#  P1: precip is a single ITCZ-like band swinging N-S seasonally (no other blobs, no dissipation)
#  P2: snow_cover appears before/without snowfall(BLIZZARD); temperate has no BLIZZARD; rain falls on snow
import numpy as np, os
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
from scipy import ndimage
d=np.load("wx_arrays.npz"); dv=np.load("wx_derived.npz")
R,COL,C,T=64,100,6400,412
f=lambda k:d["f32_"+k]; i=lambda k:d["i8_"+k]; st=lambda k:d["st_"+k]
def line(s=""): print(s)
def hdr(s): print("\n"+"="*78+"\n"+s+"\n"+"="*78)
WT={0:"CLEAR",1:"RAIN",2:"STORM",3:"BLIZZARD",4:"DROUGHT",5:"FOG",6:"HEATWAVE",7:"MONSOON"}
water=st("is_water_arr").astype(bool); land=~water; elev=st("elevation_arr")
latdeg=dv["latdeg"]; latrow=(np.arange(R)-31.5)/31.5*90
precip=f("weather_precip_arr"); wt=i("weather_type_arr"); inten=f("weather_intensity_arr")
temp=f("temp_arr"); snow=f("snow_cover_arr"); snowpk=f("snowpack_arr")
G=lambda a:a.reshape(R,COL)
Pg=precip.reshape(T,R,COL)

hdr("P1. RAIN BLOBS: connected-component analysis per tick (x-wrap merged)")
def count_blobs(mask2d):
    lab,nb=ndimage.label(mask2d, structure=np.array([[0,1,0],[1,1,1],[0,1,0]]))
    if nb<=1: return lab,nb
    # merge across x-wrap seam (col0<->col99) same row
    parent=list(range(nb+1))
    def find(x):
        while parent[x]!=x: parent[x]=parent[parent[x]]; x=parent[x]
        return x
    def union(a,b):
        ra,rb=find(a),find(b)
        if ra!=rb: parent[max(ra,rb)]=min(ra,rb)
    for r in range(R):
        a,b=lab[r,0],lab[r,COL-1]
        if a>0 and b>0: union(a,b)
    roots=np.array([find(x) for x in range(nb+1)])
    return lab,len(set(roots[1:]))
nblobs=[]; largest_frac=[]; lon_span=[]; wet_area=[]
for t in range(T):
    m=Pg[t]>0.02
    wet_area.append(int(m.sum()))
    if m.sum()==0: nblobs.append(0); largest_frac.append(0); lon_span.append(0); continue
    lab,nb=ndimage.label(m, structure=np.array([[0,1,0],[1,1,1],[0,1,0]]))
    # wrap-merge for sizes
    parent=list(range(nb+1))
    def find(x):
        while parent[x]!=x: parent[x]=parent[parent[x]]; x=parent[x]
        return x
    for r in range(R):
        a,b=lab[r,0],lab[r,COL-1]
        if a>0 and b>0:
            ra,rb=find(a),find(b)
            if ra!=rb: parent[max(ra,rb)]=min(ra,rb)
    roots=np.array([find(lab[idx]) if lab[idx]>0 else 0 for idx in zip(*np.where(m))])
    uniq,cnts=np.unique(roots,return_counts=True)
    nblobs.append(len(uniq))
    big=uniq[np.argmax(cnts)]
    largest_frac.append(cnts.max()/m.sum())
    cols_in_big=np.where(np.array([find(lab[r,cc]) if lab[r,cc]>0 else -1 for r in range(R) for cc in range(COL)]).reshape(R,COL)==big)[1]
    lon_span.append(len(np.unique(cols_in_big)))
nblobs=np.array(nblobs); largest_frac=np.array(largest_frac); lon_span=np.array(lon_span); wet_area=np.array(wet_area)
line(f"rain blobs per tick: mean={nblobs.mean():.1f} median={np.median(nblobs):.0f} min={nblobs.min()} max={nblobs.max()}")
line(f"largest-blob share of wet area: mean={largest_frac.mean():.2f} (1.0=single structure)")
line(f"largest-blob longitudinal span (of {COL} cols): mean={lon_span.mean():.0f} max={lon_span.max()} (zonal band if ~{COL})")
line(f"total wet-cell count over time: min={wet_area.min()} max={wet_area.max()} -> never 0 => band never fully dissipates" if wet_area.min()>0 else "wet area hits 0 sometimes")
# midlatitude vs tropical precip
trop=np.abs(latdeg)<25; mid=(np.abs(latdeg)>=35)&(np.abs(latdeg)<=65)
line(f"\nTROPICAL(|lat|<25): mean precip={precip[:,trop].mean():.4f}  precip cell-ticks(>0.02)={int((precip[:,trop]>0.02).sum())}")
line(f"MIDLAT(35-65):      mean precip={precip[:,mid].mean():.4f}  precip cell-ticks(>0.02)={int((precip[:,mid]>0.02).sum())}")
line(f"  -> midlat/tropical precip-mass ratio = {precip[:,mid].sum()/max(precip[:,trop].sum(),1e-9):.3f} (Earth midlat storm tracks are very wet)")
# fraction of all rain that is within the migrating tropical band
line(f"  share of ALL precip mass in |lat|<25 band: {100*precip[:,trop].sum()/precip.sum():.1f}%")

hdr("P2. SNOW COVER vs SNOWFALL(BLIZZARD) decoupling")
snowy=snow>0.2                      # [T,C] snow on ground
bliz=(wt==3)
line(f"snow-covered cell-ticks (snow_cover>0.2): {int(snowy.sum())}")
line(f"  of those, precip==0 (dry, snow purely from snowline floor): {100*np.mean(precip[snowy]==0):.1f}%")
line(f"  of those, precip>0.02 (active precip on snow): {100*np.mean(precip[snowy]>0.02):.1f}%")
# weather type ON snow-covered ground
line("weather TYPE distribution on snow-covered ground (snow_cover>0.2):")
sub=wt[snowy]
for t in [0,1,2,3,5,7]:
    line(f"   {WT[t]:9s}: {100*np.mean(sub==t):6.2f}%")
# rain vs blizzard on snow
ros=int((snowy&(wt==1)).sum()); bos=int((snowy&(wt==3)).sum())
line(f"RAIN-on-snow cell-ticks={ros}  vs  BLIZZARD-on-snow cell-ticks={bos}  (ratio rain/bliz={ros/max(bos,1):.1f})")
line(f"  temp of RAIN-on-snow: mean={temp[snowy&(wt==1)].mean():.3f} (cold rain that 'should' be snow if < {0.24:.2f})")
# snow appears before snowfall: per cell, first snow tick vs first blizzard tick
hdr("P2b. 'Snow appears before snowfall' — temporal ordering per cell")
ever_snow=snowy.any(0)
ever_bliz=bliz.any(0)
line(f"land cells that EVER have snow_cover>0.2: {int((ever_snow&land).sum())}")
line(f"  of those, cells that NEVER have a BLIZZARD: {int((ever_snow&land&~ever_bliz).sum())} ({100*(ever_snow&land&~ever_bliz).sum()/max((ever_snow&land).sum(),1):.1f}%)")
# for cells with both, does snow appear first?
def first_true(mat):
    idx=np.argmax(mat,0); idx[~mat.any(0)]=999999; return idx
fs=first_true(snowy); fb=first_true(bliz)
both=ever_snow&ever_bliz&land
snow_first=int((fs[both]<fb[both]).sum())
line(f"  cells with BOTH snow & blizzard (land): {int(both.sum())}; snow_cover appears BEFORE first blizzard in {snow_first} ({100*snow_first/max(int(both.sum()),1):.0f}%)")
# temperate snowfall deficit
hdr("P2c. Temperate-zone snowfall deficit")
for nm,m in [("TROPICAL |lat|<25",np.abs(latdeg)<25),("TEMPERATE 35-55",(np.abs(latdeg)>=35)&(np.abs(latdeg)<=55)),("POLAR >55",np.abs(latdeg)>55)]:
    ml=m&land
    sct=int((snowy[:,ml]).sum()); bct=int((bliz[:,ml]).sum())
    cold_precip=int(((precip[:,ml]>0.02)&(temp[:,ml]<0.31)).sum())
    line(f"  {nm:18s}: snow-cover cell-ticks={sct:7d}  BLIZZARD cell-ticks={bct:6d}  cold-precip(<0.31)cell-ticks={cold_precip:6d}")
    if cold_precip>0: line(f"        of cold precip, classified BLIZZARD={100*bct/max(cold_precip,1):.1f}% (rest = cold RAIN)")

# ============ FIGURES ============
# Hovmoller: zonal-mean precip (lat x time) — shows single band swinging
fig,axs=plt.subplots(2,2,figsize=(16,10))
zp=Pg.mean(2).T   # [R,T]
im=axs[0,0].imshow(zp,origin="lower",aspect="auto",cmap="Blues",extent=[0,T,latrow[0],latrow[-1]])
axs[0,0].set_title("Hovmoller: zonal-mean PRECIP (latitude vs time)\n-> single migrating ITCZ band?");axs[0,0].set_xlabel("tick");axs[0,0].set_ylabel("latitude deg")
plt.colorbar(im,ax=axs[0,0],fraction=0.04)
# blobs over time
axs[0,1].plot(nblobs,label="rain-blob count"); axs[0,1].plot(largest_frac*nblobs.max(),label="largest-share (scaled)",alpha=.6)
axs[0,1].set_title("Rain-blob count & dominance over time");axs[0,1].legend(fontsize=8);axs[0,1].set_xlabel("tick");axs[0,1].grid(alpha=.3)
# snapshots of precip at 4 times
for k,tt in enumerate([40,140,240,340]):
    ax=plt.subplot(4,4,9+k)
    ax.imshow(Pg[tt]>0.02,origin="lower",aspect="auto",cmap="Blues");ax.set_title(f"precip>0.02 @tick{tt}",fontsize=8);ax.set_xticks([]);ax.set_yticks([])
# snow_cover vs blizzard map
ax=plt.subplot(4,2,6)
sc_map=G(snow.mean(0)); ax.imshow(sc_map,origin="lower",aspect="auto",cmap="bone_r");ax.set_title("time-mean snow_cover",fontsize=9);ax.set_xticks([]);ax.set_yticks([])
ax=plt.subplot(4,2,8)
bl_map=G(bliz.mean(0)); im2=ax.imshow(bl_map,origin="lower",aspect="auto",cmap="cool");ax.set_title("BLIZZARD frequency (snowfall events)",fontsize=9);ax.set_xticks([]);ax.set_yticks([])
plt.colorbar(im2,ax=ax,fraction=0.04)
plt.tight_layout(); plt.savefig("wx_figs/observations.png",dpi=90); plt.close()
print("\n[saved wx_figs/observations.png]")
