# Verify Stage 6 recharge-discharge: did persistence drop? Compare wx_133 (pre) vs wx_145 (post).
import numpy as np
from scipy import ndimage
R,COL,C=64,100,6400
def analyze(npz,label):
    d=np.load(npz); T=d["ticks"].size
    f=lambda k:d["f32_"+k]; i=lambda k:d["i8_"+k]; st=lambda k:d["st_"+k]
    water=st("is_water_arr").astype(bool); land=~water
    latrow=(np.arange(R)-31.5)/31.5*90
    precip=f("weather_precip_arr"); vapor=f("weather_vapor_arr"); wt=i("weather_type_arr")
    print(f"\n===== {label} (T={T}) =====")
    # discharge working? corr(precip[t], vapor tendency)
    dv=vapor[1:]-vapor[:-1]; pr0=precip[:-1]; ok=land[None,:].repeat(T-1,0)
    print(f"[放电] corr(precip[t], Δvapor[t->t+1]) land = {np.corrcoef(pr0[ok],dv[ok])[0,1]:+.3f} (want NEG)")
    pm=precip.mean(0); vm=vapor.mean(0)
    print(f"[放电] spatial corr(precip,vapor) land = {np.corrcoef(pm[land],vm[land])[0,1]:+.3f} (want toward/below 0)")
    # persistence: precip temporal autocorr
    pa=precip-precip.mean(0,keepdims=True)
    ac={k:round(float(np.corrcoef(pa[:-k].ravel(),pa[k:].ravel())[0,1]),2) for k in (1,5,20,50) if k<T}
    print(f"[持久] precip temporal autocorr = {ac}")
    # commit cadence (ticks with zero weather_type change)
    chg=(wt[1:]!=wt[:-1]).sum(1); zero=(chg==0).sum()
    cad = T/max(T-zero,1)
    print(f"[节律] zero-change ticks={zero}/{T-1} -> ~{cad:.1f} ticks/weather-step")
    # SPELL LENGTHS (consecutive ticks precip>0.02) — the "week of rain" metric
    wetmat=(precip>0.02)
    runs=[]
    for c in range(C):
        col=wetmat[:,c]
        if not col.any(): continue
        idx=np.where(np.diff(np.concatenate(([0],col.view(np.int8),[0])))!=0)[0]
        runs.extend((idx[1::2]-idx[0::2]).tolist())
    runs=np.array(runs)
    if runs.size:
        # convert to weather-days using cadence
        wd=runs/cad
        print(f"[雨段] n={runs.size} 长度(ticks): median={np.median(runs):.0f} p90={np.percentile(runs,90):.0f} max={runs.max()} (T={T})")
        print(f"       折算天气日(÷{cad:.1f}): median={np.median(wd):.1f}d p90={np.percentile(wd,90):.1f}d  >=7天比例={100*np.mean(wd>=7):.1f}%  全程不停={int((runs>=T*0.95).sum())}格")
    # global precip sanity
    print(f"[总量] global mean precip={precip.mean():.4f} | precip cell-tick frac(>0.02)={100*wetmat.mean():.2f}%")
    # ocean onset
    on=(precip[:-1]<0.01)&(precip[1:]>0.03)
    print(f"[海生] precip onset: ocean={int((on&water[None,:]).sum())} land={int((on&land[None,:]).sum())} (ocean/land={ (on&water[None,:]).sum()/max((on&land[None,:]).sum(),1):.2f})")
    # largest-blob share
    g=precip.reshape(T,R,COL); struct=np.array([[0,1,0],[1,1,1],[0,1,0]]); ls=[]
    for t in range(0,T,4):
        m=g[t]>0.02
        if m.sum()==0: continue
        lab,nb=ndimage.label(m,structure=struct)
        if nb==0: continue
        _,cn=np.unique(lab[m],return_counts=True); ls.append(cn.max()/m.sum())
    print(f"[单带] largest-blob share (no-merge) = {np.mean(ls):.2f}")
    return

import os
if os.path.exists("wx_133.npz"): analyze("wx_133.npz","PRE Stage6 (133100)")
analyze("wx_145.npz","POST Stage6 (145859)")
