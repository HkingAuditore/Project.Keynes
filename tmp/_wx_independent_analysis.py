# -*- coding: utf-8 -*-
# 独立天气/气候数据研判脚本（流式按 tick 分块）。
# 目标文件：tile_data_record_20260622_145049.csv （6400 cells x 438 ticks）。
import pandas as pd, numpy as np, json, time, sys

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260622_145049.csv"
NC = 6400
WET = 0.02          # 湿润阈值（与历史报告一致，便于对比）
EPS = 1e-4

WT = ["CLEAR","RAIN","STORM","BLIZZARD","DROUGHT","FOG","HEATWAVE","MONSOON"]

CELL_COLS = ["cell_index","q","r","s","cell_lat_norm_arr","is_water_arr","elevation_arr",
    "terrain_arr","landform_arr","vegetation_arr","cover_arr",
    "temp_arr","moisture_arr","snow_cover_arr","sea_ice_frac_arr",
    "weather_precip_arr","weather_intensity_arr","weather_cloud_arr","weather_vapor_arr",
    "weather_convergence_arr","weather_instability_arr",
    "weather_type_arr","weather_target_type_arr","weather_transition_alpha_arr",
    "air_mass_temp_anomaly_arr","temperature_transport_anomaly_arr",
    "ocean_current_x_arr","ocean_current_y_arr","wind_x_arr","wind_y_arr",
    "wind_speed_arr","slp_arr","wind_stress_curl_arr",
    "soil_moisture_arr","vegetation_vitality_arr","vegetation_growth_pressure_arr",
    "vegetation_heat_stress_arr","vegetation_drought_stress_arr","vegetation_cold_stress_arr",
    "weather_dirty_mask"]
GLOB_COLS = ["tick_idx","weather_dirty_count","active_weather_ratio",
    "weather_refresh_convergence","weather_convergence_published",
    "weather_convergence_dirty_count","weather_convergence_delta_p95",
    "weather_transitioning_count","weather_transition_alpha_mean","weather_transition_alpha_p95",
    "weather_target_mismatch_count","climate_ocean_mag_p95","climate_wind_mag_p95",
    "climate_precip_p95","phys_sim_day","phys_daily_wind_season_phase","climate_max_temp_delta"]
USE = list(dict.fromkeys(CELL_COLS + GLOB_COLS))

def f(df,c): return pd.to_numeric(df[c],errors="coerce").to_numpy(np.float64)
def i(df,c): return pd.to_numeric(df[c],errors="coerce").fillna(0).to_numpy(np.int64)

# ---- accumulators ----
wet_cnt=np.zeros(NC); wet01=np.zeros(NC); wet005=np.zeros(NC)
precip_sum=np.zeros(NC); temp_sum=np.zeros(NC); n_seen=np.zeros(NC)
type_cell_hist=np.zeros((NC,8))     # per cell weather type frequency
# per type conditioned sums (global, land/water)
tc=np.zeros(8); t_land=np.zeros(8); t_water=np.zeros(8)
t_precip=np.zeros(8); t_int=np.zeros(8); t_temp=np.zeros(8); t_vap=np.zeros(8)
t_cloud=np.zeros(8); t_wspd=np.zeros(8); t_conv=np.zeros(8); t_inst=np.zeros(8)
# correlation accumulators
class Cor:
    __slots__=("n","sx","sy","sxy","sx2","sy2")
    def __init__(s): s.n=s.sx=s.sy=s.sxy=s.sx2=s.sy2=0.0
    def add(s,x,y):
        m=np.isfinite(x)&np.isfinite(y); x=x[m]; y=y[m]
        s.n+=x.size; s.sx+=x.sum(); s.sy+=y.sum()
        s.sxy+=(x*y).sum(); s.sx2+=(x*x).sum(); s.sy2+=(y*y).sum()
    def r(s):
        if s.n<2: return float("nan")
        cov=s.sxy-s.sx*s.sy/s.n; vx=s.sx2-s.sx*s.sx/s.n; vy=s.sy2-s.sy*s.sy/s.n
        d=(vx*vy)**0.5
        return float(cov/d) if d>0 else float("nan")
cor={k:Cor() for k in ["temp_abslat","precip_inst","precip_conv","precip_cloud",
    "soil_precip","vit_soil","vit_drought","snow_temp_land","seaice_temp_water",
    "growth_precip","vit_precip","precip_vapor"]}
# latitude band sums (10 bands by abs lat)
LB=10
lb_temp=np.zeros(LB); lb_precip=np.zeros(LB); lb_wet=np.zeros(LB); lb_snow=np.zeros(LB)
lb_seaice=np.zeros(LB); lb_n=np.zeros(LB); lb_land=np.zeros(LB); lb_inst=np.zeros(LB)
# time series (per tick)
TS={k:[] for k in ["tick","wet_area","jaccard","wtype_change","wetstate_change",
    "tta_signflip","temp_ping","mean_precip","nonclear_frac","gen_rate","diss_rate",
    "ocean_p95_water","wind_p95"]}
# ocean magnitude histogram (water cells)
OBIN=np.linspace(0,1.6,161); ocean_hist=np.zeros(len(OBIN)-1); ocean_n=0
wind_hist=np.zeros(len(OBIN)-1); wind_n=0
# spell tracking (weather event lifetime)
cur_type=None; cur_run=None
spell_cnt=np.zeros(8); spell_len=np.zeros(8); spell_max=np.zeros(8)
# prev-tick state
prev_wet=None; prev_type=None; prev_tta=None; prev_temp=None; prev_dtemp=None
lat_band=None; is_water0=None; elev0=None; latabs0=None
last_chunk={}
glob_rows=[]

t0=time.time(); k=0
reader=pd.read_csv(PATH,usecols=USE,chunksize=NC,encoding="utf-8-sig",low_memory=False)
for df in reader:
    if len(df)!=NC:
        # 末尾或非对齐块：按 cell_index 兜底
        df=df.sort_values("cell_index")
    ci=i(df,"cell_index")
    # 按 cell_index 排序保证数组对齐
    order=np.argsort(ci); df=df.iloc[order]
    tick=int(pd.to_numeric(df["tick_idx"],errors="coerce").iloc[0])
    temp=f(df,"temp_arr"); precip=f(df,"weather_precip_arr"); inten=f(df,"weather_intensity_arr")
    cloud=f(df,"weather_cloud_arr"); vapor=f(df,"weather_vapor_arr"); conv=f(df,"weather_convergence_arr")
    inst=f(df,"weather_instability_arr"); wtype=i(df,"weather_type_arr")
    snow=f(df,"snow_cover_arr"); seaice=f(df,"sea_ice_frac_arr"); moist=f(df,"moisture_arr")
    tta=f(df,"temperature_transport_anomaly_arr"); amta=f(df,"air_mass_temp_anomaly_arr")
    ocx=f(df,"ocean_current_x_arr"); ocy=f(df,"ocean_current_y_arr")
    wspd=f(df,"wind_speed_arr")
    soil=f(df,"soil_moisture_arr"); vit=f(df,"vegetation_vitality_arr")
    growth=f(df,"vegetation_growth_pressure_arr"); drought=f(df,"vegetation_drought_stress_arr")
    isw=i(df,"is_water_arr").astype(bool)
    if lat_band is None:
        latn=f(df,"cell_lat_norm_arr"); latabs0=np.abs(latn)
        mx=np.nanmax(latabs0); mx=mx if mx>0 else 1.0
        lat_band=np.clip((latabs0/mx*LB).astype(int),0,LB-1)
        is_water0=isw.copy(); elev0=f(df,"elevation_arr")
    land=~isw
    # per-cell wet freq
    wet_cnt+=(precip>WET); wet01+=(precip>0.01); wet005+=(precip>0.005)
    precip_sum+=precip; temp_sum+=temp; n_seen+=1
    type_cell_hist[np.arange(NC),np.clip(wtype,0,7)]+=1
    # per type conditioned
    for w in range(8):
        m=wtype==w; c=m.sum()
        if c:
            tc[w]+=c; t_land[w]+=(m&land).sum(); t_water[w]+=(m&isw).sum()
            t_precip[w]+=precip[m].sum(); t_int[w]+=inten[m].sum(); t_temp[w]+=temp[m].sum()
            t_vap[w]+=vapor[m].sum(); t_cloud[w]+=cloud[m].sum(); t_wspd[w]+=wspd[m].sum()
            t_conv[w]+=conv[m].sum(); t_inst[w]+=inst[m].sum()
    # correlations
    cor["temp_abslat"].add(temp,latabs0); cor["precip_inst"].add(precip,inst)
    cor["precip_conv"].add(precip,conv); cor["precip_cloud"].add(precip,cloud)
    cor["precip_vapor"].add(precip,vapor)
    cor["soil_precip"].add(soil,precip); cor["vit_soil"].add(vit,soil)
    cor["vit_drought"].add(vit,drought); cor["growth_precip"].add(growth,precip)
    cor["vit_precip"].add(vit,precip)
    cor["snow_temp_land"].add(snow[land],temp[land])
    cor["seaice_temp_water"].add(seaice[isw],temp[isw])
    # lat band sums
    for b in range(LB):
        m=lat_band==b; mm=m.sum()
        if mm:
            lb_temp[b]+=temp[m].sum(); lb_precip[b]+=precip[m].sum()
            lb_wet[b]+=(precip[m]>WET).sum(); lb_snow[b]+=snow[m].sum()
            lb_seaice[b]+=seaice[m].sum(); lb_n[b]+=mm; lb_inst[b]+=inst[m].sum()
            lb_land[b]+=land[m].sum()
    # ocean / wind magnitude hist (water)
    omag=np.hypot(ocx,ocy)[isw]; omag=omag[np.isfinite(omag)]
    ocean_hist+=np.histogram(omag,bins=OBIN)[0]; ocean_n+=omag.size
    wmag=wspd[np.isfinite(wspd)]; wind_hist+=np.histogram(wmag,bins=OBIN)[0]; wind_n+=wmag.size
    # time series
    wet=precip>WET
    TS["tick"].append(tick); TS["wet_area"].append(int(wet.sum()))
    TS["mean_precip"].append(float(precip.mean())); TS["nonclear_frac"].append(float((wtype!=0).mean()))
    om_w=np.hypot(ocx,ocy)[isw]; TS["ocean_p95_water"].append(float(np.nanpercentile(om_w,95)) if om_w.size else 0.0)
    TS["wind_p95"].append(float(np.nanpercentile(wspd,95)))
    if prev_wet is not None:
        inter=(wet&prev_wet).sum(); uni=(wet|prev_wet).sum()
        TS["jaccard"].append(float(inter/uni) if uni else 1.0)
        TS["wtype_change"].append(float((wtype!=prev_type).mean()))
        TS["wetstate_change"].append(float((wet!=prev_wet).mean()))
        mboth=(np.abs(tta)>EPS)&(np.abs(prev_tta)>EPS)
        TS["tta_signflip"].append(float((np.sign(tta[mboth])!=np.sign(prev_tta[mboth])).mean()) if mboth.sum() else 0.0)
        dtemp=temp-prev_temp
        if prev_dtemp is not None:
            mm=(np.abs(dtemp)>1e-5)&(np.abs(prev_dtemp)>1e-5)
            TS["temp_ping"].append(float((np.sign(dtemp[mm])!=np.sign(prev_dtemp[mm])).mean()) if mm.sum() else 0.0)
        else: TS["temp_ping"].append(0.0)
        gen=((prev_type==0)&(wtype!=0)).sum(); diss=((prev_type!=0)&(wtype==0)).sum()
        TS["gen_rate"].append(int(gen)); TS["diss_rate"].append(int(diss))
        prev_dtemp=dtemp
    else:
        for kk in ["jaccard","wtype_change","wetstate_change","tta_signflip","temp_ping"]: TS[kk].append(np.nan)
        TS["gen_rate"].append(0); TS["diss_rate"].append(0)
    # spell tracking
    if cur_type is None:
        cur_type=wtype.copy(); cur_run=np.ones(NC,int)
    else:
        same=wtype==cur_type
        ended=~same
        for w in range(8):
            em=ended&(cur_type==w)
            if em.any():
                rl=cur_run[em]; spell_cnt[w]+=em.sum(); spell_len[w]+=rl.sum()
                spell_max[w]=max(spell_max[w],rl.max())
        cur_run=np.where(same,cur_run+1,1); cur_type=wtype.copy()
    # globals
    gr={c:df[c].iloc[0] for c in GLOB_COLS}
    glob_rows.append(gr)
    prev_wet=wet; prev_type=wtype.copy(); prev_tta=tta.copy(); prev_temp=temp.copy()
    last_chunk={"q":i(df,"q"),"r":i(df,"r"),"s":i(df,"s"),"temp":temp,"precip":precip,
        "wtype":wtype,"wspd":wspd,"wx":f(df,"wind_x_arr"),"wy":f(df,"wind_y_arr"),
        "slp":f(df,"slp_arr"),"conv":conv,"inst":inst,"amta":amta,"isw":isw,
        "curl":f(df,"wind_stress_curl_arr"),"vapor":vapor}
    k+=1
    if k%60==0: print(f"PROGRESS {k}/438 tick={tick} {time.time()-t0:.1f}s",flush=True)

print(f"LOOP DONE {k} ticks in {time.time()-t0:.1f}s",flush=True)
G=pd.DataFrame(glob_rows)
for c in G.columns: G[c]=pd.to_numeric(G[c],errors="coerce")

# ---------- last frame adjacency / fronts / clusters ----------
q=last_chunk["q"]; r=last_chunk["r"]
pos={(int(q[n]),int(r[n])):n for n in range(NC)}
DIRS=[(1,0),(1,-1),(0,-1),(-1,0),(-1,1),(0,1)]
edges=[]
for n in range(NC):
    qq,rr=int(q[n]),int(r[n])
    for dq,dr in DIRS:
        m=pos.get((qq+dq,rr+dr))
        if m is not None and m>n: edges.append((n,m))
edges=np.array(edges); a=edges[:,0]; b=edges[:,1]
lt=last_chunk["temp"]; lw=last_chunk["wtype"]; lc=last_chunk["conv"]; lp=last_chunk["precip"]
lwx=last_chunk["wx"]; lwy=last_chunk["wy"]; lslp=last_chunk["slp"]; lam=last_chunk["amta"]
tgrad=np.abs(lt[a]-lt[b])
wshear=np.hypot(lwx[a]-lwx[b],lwy[a]-lwy[b])
type_edge=(lw[a]!=lw[b]).mean()
tg95=np.percentile(tgrad,95); tg99=np.percentile(tgrad,99)
front_like=((tgrad>tg95)&((lc[a]+lc[b]>0.2)|(lp[a]+lp[b]>0.04))).mean()
wet_edge=(((lp[a]>WET)!=(lp[b]>WET))).mean()
# 冷暖气团边界：air_mass_temp_anomaly 跨零 + 风穿过梯度
amta_cross=((np.sign(lam[a])!=np.sign(lam[b]))&(np.abs(lam[a]-lam[b])>0.05)).mean()

def clusters(mask):
    idx=set(np.where(mask)[0].tolist()); seen=set(); comps=[]
    adj={}
    for (x,y) in edges:
        if mask[x] and mask[y]:
            adj.setdefault(x,[]).append(y); adj.setdefault(y,[]).append(x)
    for s0 in idx:
        if s0 in seen: continue
        st=[s0]; seen.add(s0); sz=0
        while st:
            u=st.pop(); sz+=1
            for v in adj.get(u,[]):
                if v not in seen: seen.add(v); st.append(v)
        comps.append(sz)
    comps.sort(reverse=True)
    return {"n":len(comps),"cells":int(mask.sum()),"max":int(comps[0]) if comps else 0}
cl={}
cl["wet"]=clusters(lp>WET)
for w,name in [(1,"RAIN"),(2,"STORM"),(3,"BLIZZARD"),(4,"DROUGHT"),(5,"FOG"),(6,"HEATWAVE"),(7,"MONSOON")]:
    cl[name]=clusters(lw==w)

# 台风诊断：STORM/MONSOON 簇 vs slp、wind、curl
storm_mask=(lw==2)|(lw==7)
def at(mask,arr): 
    v=arr[mask]; return float(v.mean()) if mask.sum() else 0.0
typhoon={"storm_monsoon_cells":int(storm_mask.sum()),
    "mean_wspd":at(storm_mask,last_chunk["wspd"]),"glob_wspd":float(last_chunk["wspd"].mean()),
    "mean_slp":at(storm_mask,lslp),"glob_slp":float(lslp.mean()),
    "mean_curl_abs":at(storm_mask,np.abs(last_chunk["curl"])),"glob_curl_abs":float(np.abs(last_chunk["curl"]).mean()),
    "mean_inst":at(storm_mask,last_chunk["inst"]),"on_water_frac":float(last_chunk["isw"][storm_mask].mean()) if storm_mask.sum() else 0.0}

# ---------- permanent rain/drought ----------
wf=wet_cnt/n_seen
isw=is_water0; land=~isw
def frac(mask): return float(mask.mean())
perm={
 "always_wet":frac(wf>=0.999),"wet_gt80":frac(wf>0.8),
 "always_dry":frac(wf<=0.001),"dry_gt95":frac(wf<0.05),
 "land_dry_gt95":float((wf[land]<0.05).mean()),"land_wet_gt80":float((wf[land]>0.8).mean()),
 "water_wet_gt80":float((wf[isw]>0.8).mean()),"water_dry_gt95":float((wf[isw]<0.05).mean()),
 "land_n":int(land.sum()),"water_n":int(isw.sum()),"water_frac":float(isw.mean())}

def pct(arr,ps): 
    a=np.array(arr,float); a=a[np.isfinite(a)]; 
    return {str(p):float(np.percentile(a,p)) for p in ps} if a.size else {}
def hist_pct(hist,bins,ps):
    cdf=np.cumsum(hist); tot=cdf[-1] if cdf[-1]>0 else 1
    out={}
    for p in ps:
        idx=np.searchsorted(cdf,tot*p/100.0); idx=min(idx,len(bins)-2)
        out[str(p)]=float((bins[idx]+bins[idx+1])/2)
    return out

R={}
R["meta"]={"ticks":k,"tick_lo":int(G["tick_idx"].min()),"tick_hi":int(G["tick_idx"].max()),
    "cells":NC,"water_frac":perm["water_frac"],"sim_day_lo":float(G["phys_sim_day"].min()),
    "sim_day_hi":float(G["phys_sim_day"].max()),
    "season_phase_lo":float(G["phys_daily_wind_season_phase"].min()),
    "season_phase_hi":float(G["phys_daily_wind_season_phase"].max())}
tot=tc.sum()
R["weather_types"]={WT[w]:{
    "share":float(tc[w]/tot),"land_share":float(t_land[w]/max(land.sum()*k,1)),
    "water_share":float(t_water[w]/max(isw.sum()*k,1)),
    "mean_precip":float(t_precip[w]/max(tc[w],1)),"mean_intensity":float(t_int[w]/max(tc[w],1)),
    "mean_temp":float(t_temp[w]/max(tc[w],1)),"mean_vapor":float(t_vap[w]/max(tc[w],1)),
    "mean_cloud":float(t_cloud[w]/max(tc[w],1)),"mean_wspd":float(t_wspd[w]/max(tc[w],1)),
    "mean_conv":float(t_conv[w]/max(tc[w],1)),"mean_inst":float(t_inst[w]/max(tc[w],1))} for w in range(8)}
R["correlations"]={kk:cor[kk].r() for kk in cor}
R["lat_bands"]=[{"band":b,"mean_temp":float(lb_temp[b]/max(lb_n[b],1)),
    "mean_precip":float(lb_precip[b]/max(lb_n[b],1)),"wet_frac":float(lb_wet[b]/max(lb_n[b],1)),
    "mean_snow":float(lb_snow[b]/max(lb_n[b],1)),"mean_seaice":float(lb_seaice[b]/max(lb_n[b],1)),
    "mean_inst":float(lb_inst[b]/max(lb_n[b],1)),"land_frac":float(lb_land[b]/max(lb_n[b],1))} for b in range(LB)]
R["permanent"]=perm
R["fronts"]={"edges":int(len(edges)),"type_edge_frac":float(type_edge),
    "tgrad_p95":float(tg95),"tgrad_p99":float(tg99),"front_like_frac":float(front_like),
    "wet_edge_frac":float(wet_edge),"airmass_boundary_frac":float(amta_cross),
    "wshear_p95":float(np.percentile(wshear,95)),"wshear_p99":float(np.percentile(wshear,99))}
R["clusters"]=cl
R["typhoon"]=typhoon
def ts_stat(name):
    a=np.array(TS[name],float); a=a[np.isfinite(a)]
    return {"mean":float(a.mean()),"median":float(np.median(a)),"p05":float(np.percentile(a,5)),
        "p95":float(np.percentile(a,95)),"min":float(a.min()),"max":float(a.max())} if a.size else {}
R["dynamics"]={n:ts_stat(n) for n in ["jaccard","wtype_change","wetstate_change","tta_signflip",
    "temp_ping","wet_area","gen_rate","diss_rate","nonclear_frac","mean_precip","ocean_p95_water","wind_p95"]}
R["spells"]={WT[w]:{"count":int(spell_cnt[w]),"mean_len":float(spell_len[w]/max(spell_cnt[w],1)),
    "max_len":int(spell_max[w])} for w in range(8)}
R["fix_metrics"]={
    "tta_signflip_mean":R["dynamics"]["tta_signflip"]["mean"],
    "temp_ping_mean":R["dynamics"]["temp_ping"]["mean"],
    "ocean_mag_water_pct":hist_pct(ocean_hist,OBIN,[50,90,95,99]),
    "ocean_mag_water_max_bin":float(OBIN[np.max(np.where(ocean_hist>0))+1]) if ocean_hist.any() else 0.0,
    "wind_pct":hist_pct(wind_hist,OBIN,[50,95,99]),
    "weather_dirty_count_zero_frac":float((G["weather_dirty_count"]==0).mean()),
    "weather_dirty_count_mean":float(G["weather_dirty_count"].mean()),
    "active_weather_ratio_mean":float(G["active_weather_ratio"].mean()),
    "refresh_convergence_true_frac":float((G["weather_refresh_convergence"]==True).mean() if G["weather_refresh_convergence"].dtype==bool else (G["weather_refresh_convergence"].astype(str).str.lower()=="true").mean()),
    "convergence_published_true_frac":float((G["weather_convergence_published"].astype(str).str.lower()=="true").mean()),
    "ocean_mag_p95_global_mean":float(G["climate_ocean_mag_p95"].mean()),
}
# 极地低温 RAIN 比例（P2b 验收）：用 last frame 近似 + 全程统计需要逐tick，这里给全程
# 用 per-cell：寒冷格(温度<0.2)上 RAIN 出现次数 / 寒冷格总记录。逐tick已难回溯，改用 last frame。
cold=last_chunk["temp"]<0.2
R["fix_metrics"]["lastframe_cold_cells"]=int(cold.sum())
R["fix_metrics"]["lastframe_cold_rain_frac"]=float((last_chunk["wtype"][cold]==1).mean()) if cold.sum() else 0.0
R["fix_metrics"]["lastframe_cold_blizzard_frac"]=float((last_chunk["wtype"][cold]==3).mean()) if cold.sum() else 0.0

out=r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\_wx_independent_result.json"
json.dump(R,open(out,"w",encoding="utf-8"),indent=2,ensure_ascii=False)
print("WROTE",out)
print(json.dumps(R,ensure_ascii=False,indent=2))
