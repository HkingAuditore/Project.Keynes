# -*- coding: utf-8 -*-
# 二次核实：正确纬度变换、TTA冻结vs平滑、湿区长期锁定、分类长期锁定。
import pandas as pd, numpy as np, time
PATH=r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260622_145049.csv"
NC=6400; WET=0.02
use=["tick_idx","cell_index","cell_lat_norm_arr","temp_arr","weather_precip_arr",
     "temperature_transport_anomaly_arr","is_water_arr","weather_type_arr","moisture_arr"]
# 相关性累积（正确赤道距离）
n=sx=sy=sxy=sx2=sy2=0.0
# TTA 时序
tta_sum=np.zeros(NC); tta_sq=np.zeros(NC); tta_n=np.zeros(NC)
tta_abs_per_tick=[]; tta_prev=None; tta_change=[]
latn0=None; isw0=None
first={}; last={}
k=0; t0=time.time()
for df in pd.read_csv(PATH,usecols=use,chunksize=NC,encoding="utf-8-sig",low_memory=False):
    df=df.sort_values("cell_index")
    tick=int(pd.to_numeric(df["tick_idx"],errors="coerce").iloc[0])
    latn=pd.to_numeric(df["cell_lat_norm_arr"],errors="coerce").to_numpy(float)
    temp=pd.to_numeric(df["temp_arr"],errors="coerce").to_numpy(float)
    precip=pd.to_numeric(df["weather_precip_arr"],errors="coerce").to_numpy(float)
    tta=pd.to_numeric(df["temperature_transport_anomaly_arr"],errors="coerce").to_numpy(float)
    wt=pd.to_numeric(df["weather_type_arr"],errors="coerce").fillna(0).to_numpy(int)
    isw=pd.to_numeric(df["is_water_arr"],errors="coerce").fillna(0).to_numpy(int).astype(bool)
    if latn0 is None:
        latn0=latn.copy(); isw0=isw.copy()
        first={"wet":precip>WET,"wt":wt.copy()}
    eqd=np.abs(latn-0.5)   # 赤道距离（假设 lat_norm∈[0,1], 0.5=赤道）
    m=np.isfinite(temp)&np.isfinite(eqd)
    x=eqd[m]; y=temp[m]
    n+=x.size; sx+=x.sum(); sy+=y.sum(); sxy+=(x*y).sum(); sx2+=(x*x).sum(); sy2+=(y*y).sum()
    tta_sum+=np.nan_to_num(tta); tta_sq+=np.nan_to_num(tta)**2; tta_n+=np.isfinite(tta)
    tta_abs_per_tick.append(float(np.nanmean(np.abs(tta))))
    if tta_prev is not None:
        d=np.abs(tta-tta_prev); tta_change.append(float(np.nanmean(d[isw])))
    tta_prev=tta.copy()
    last={"wet":precip>WET,"wt":wt.copy(),"tick":tick}
    k+=1
    if k%100==0: print(f"  {k}/438 {time.time()-t0:.1f}s",flush=True)

cov=sxy-sx*sy/n; vx=sx2-sx*sx/n; vy=sy2-sy*sy/n
corr_eq=cov/((vx*vy)**0.5)
tta_mean=tta_sum/np.maximum(tta_n,1)
tta_std=np.sqrt(np.maximum(tta_sq/np.maximum(tta_n,1)-tta_mean**2,0))
# 湿区/分类长期锁定（首 vs 末）
jac=lambda a,b:(a&b).sum()/max((a|b).sum(),1)
print("=== 纬度结构核实 ===")
print(f"lat_norm: min={np.nanmin(latn0):.4f} max={np.nanmax(latn0):.4f} mean={np.nanmean(latn0):.4f}")
print(f"corr(temp, |lat_norm-0.5|) 全程 = {corr_eq:.4f}")
print("=== TTA 冻结 vs 平滑 ===")
print(f"TTA 每tick平均|TTA|: min={min(tta_abs_per_tick):.5f} max={max(tta_abs_per_tick):.5f} mean={np.mean(tta_abs_per_tick):.5f}")
print(f"相邻tick水域平均|ΔTTA|: mean={np.mean(tta_change):.6f} max={max(tta_change):.6f}")
print(f"per-cell TTA 时序std(水域)均值: {np.nanmean(tta_std[isw0]):.5f}; (陆地){np.nanmean(tta_std[~isw0]):.5f}")
print("=== 长期锁定（首tick vs 末tick {}）===".format(last["tick"]))
print(f"湿区 Jaccard(首,末) = {jac(first['wet'],last['wet']):.4f}  (首湿={first['wet'].sum()} 末湿={last['wet'].sum()})")
print(f"天气类型不变cell比例(首==末) = {(first['wt']==last['wt']).mean():.4f}")
print(f"LOOP {k} ticks {time.time()-t0:.1f}s")
