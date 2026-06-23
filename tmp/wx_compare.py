# Compare pre-fix (wx_arrays.npz) vs post-fix (wx_new.npz), and diagnose why the
# single migrating rain band persists.
import numpy as np, os
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
from scipy import ndimage
R, COL, C = 64, 100, 6400
WT={0:"CLEAR",1:"RAIN",2:"STORM",3:"BLIZZARD",4:"DROUGHT",5:"FOG",6:"HEATWAVE",7:"MONSOON"}

def load(npz):
    d=np.load(npz); T=d["ticks"].size
    return d,T

def metrics(d,T,label):
    f=lambda k:d["f32_"+k]; i=lambda k:d["i8_"+k]; st=lambda k:d["st_"+k]
    water=st("is_water_arr").astype(bool); land=~water
    lat=st("cell_lat_norm_arr"); latdeg=(lat-0.5)*180; latrow=(np.arange(R)-31.5)/31.5*90
    precip=f("weather_precip_arr"); wt=i("weather_type_arr"); temp=f("temp_arr"); snow=f("snow_cover_arr")
    pm=precip.mean(0)
    print(f"\n===== {label} (T={T}) =====")
    # 1 ocean share
    po=precip[:,water].sum(); pl=precip[:,land].sum(); tot=po+pl
    print(f"[①] precip mass: ocean={100*po/tot:.1f}% land={100*pl/tot:.1f}% | ocean mean={precip[:,water].mean():.5f} land mean={precip[:,land].mean():.5f}")
    # 2 zonal
    g=precip.reshape(T,R,COL); zp=g.mean(2).mean(0)
    eq=np.abs(latrow)<15; sub=(np.abs(latrow)>20)&(np.abs(latrow)<40); mid=(np.abs(latrow)>=45)&(np.abs(latrow)<=70)
    print(f"[②] zonal precip: eq(|lat|<15)={np.nanmean(zp[eq]):.4f} subtrop(20-40)={np.nanmean(zp[sub]):.4f} midlat(45-70)={np.nanmean(zp[mid]):.4f}")
    print(f"     subtrop/eq ratio={np.nanmean(zp[sub])/max(np.nanmean(zp[eq]),1e-9):.2f} (want<1 dry belt)  midlat/eq={np.nanmean(zp[mid])/max(np.nanmean(zp[eq]),1e-9):.2f} (want a storm-track bump)")
    # 5 band concentration + blobs
    trop=np.abs(latdeg)<25
    print(f"[⑤] precip mass share in |lat|<25 band: {100*precip[:,trop].sum()/precip.sum():.1f}%")
    nblobs=[]; largest=[]; lonspan=[]
    struct=np.array([[0,1,0],[1,1,1],[0,1,0]])
    for t in range(T):
        m=g[t]>0.02
        if m.sum()==0: nblobs.append(0); largest.append(0); lonspan.append(0); continue
        lab,nb=ndimage.label(m,structure=struct)
        par=list(range(nb+1))
        def find(x):
            while par[x]!=x: par[x]=par[par[x]]; x=par[x]
            return x
        for r in range(R):
            a,b=lab[r,0],lab[r,COL-1]
            if a>0 and b>0:
                ra,rb=find(a),find(b)
                if ra!=rb: par[max(ra,rb)]=min(ra,rb)
        rootlab=np.array([find(x) if x>0 else 0 for x in range(nb+1)])
        flat=rootlab[lab[m]]
        uq,cn=np.unique(flat,return_counts=True)
        nblobs.append(len(uq)); big=uq[np.argmax(cn)]; largest.append(cn.max()/m.sum())
        cols=np.where((rootlab[lab]==big)&m)[1]
        lonspan.append(len(np.unique(cols)))
    nblobs=np.array(nblobs); largest=np.array(largest); lonspan=np.array(lonspan)
    print(f"     rain blobs/tick: mean={nblobs.mean():.1f} | largest-blob share={largest.mean():.2f} | largest lon-span={lonspan.mean():.0f}/{COL} cols")
    # 3 heatwave + types
    flatwt=wt.ravel()
    print(f"[③] HEATWAVE cell-ticks={int((flatwt==6).sum())} ({100*(flatwt==6).mean():.3f}%) | DROUGHT={int((flatwt==4).sum())} | type mix: "+" ".join(f"{WT[t][:4]}={100*np.mean(flatwt==t):.2f}" for t in [0,1,2,3,4,5,6,7]))
    # 6 snow
    snowy=snow>0.2; bliz=(wt==3)
    if snowy.sum()>0:
        print(f"[⑥] snow-cover cell-ticks={int(snowy.sum())} | of those precip>0.02={100*np.mean(precip[snowy]>0.02):.1f}% | BLIZZARD cell-ticks={int(bliz.sum())} | bliz/snow ratio={bliz.sum()/max(snowy.sum(),1):.4f}")
    return dict(latrow=latrow,zp=zp,g=g,T=T,nblobs=nblobs,largest=largest)

do=None
if os.path.exists("wx_arrays.npz"):
    d_old,T_old=load("wx_arrays.npz"); do=metrics(d_old,T_old,"PRE-FIX (20260623_101851)")
d_new,T_new=load("wx_new.npz"); dn=metrics(d_new,T_new,"POST-FIX (20260623_105213)")

# Hovmoller new + zonal compare
fig,axs=plt.subplots(2,2,figsize=(16,10))
im=axs[0,0].imshow(dn["g"].mean(2).T,origin="lower",aspect="auto",cmap="Blues",
                   extent=[0,dn["T"],dn["latrow"][0],dn["latrow"][-1]])
axs[0,0].set_title("POST-FIX Hovmoller: zonal-mean precip (lat vs time)\n-> still single migrating band?");axs[0,0].set_xlabel("tick");axs[0,0].set_ylabel("lat")
plt.colorbar(im,ax=axs[0,0],fraction=0.04)
axs[0,1].plot(dn["latrow"],dn["zp"],'b-o',ms=3,label="POST zonal precip")
if do is not None: axs[0,1].plot(do["latrow"],do["zp"],'r--',alpha=.6,label="PRE")
axs[0,1].set_title("Zonal precip profile (subtropical dry belt? midlat bump?)");axs[0,1].legend();axs[0,1].grid(alpha=.3);axs[0,1].set_xlabel("lat")
axs[1,0].plot(dn["nblobs"],label="POST blobs"); axs[1,0].plot(dn["largest"]*dn["nblobs"].max(),label="POST largest-share(scaled)",alpha=.6)
axs[1,0].set_title("blob count & dominance over time");axs[1,0].legend(fontsize=8);axs[1,0].grid(alpha=.3)
for k,tt in enumerate([30,90,150,210]):
    if tt<dn["T"]:
        ax=plt.subplot(4,4,13+k); ax.imshow(dn["g"][tt]>0.02,origin="lower",aspect="auto",cmap="Blues")
        ax.set_title(f"precip>0.02 @t{tt}",fontsize=7);ax.set_xticks([]);ax.set_yticks([])
plt.tight_layout(); plt.savefig("wx_figs/compare.png",dpi=90); plt.close()
print("\n[saved wx_figs/compare.png]")
