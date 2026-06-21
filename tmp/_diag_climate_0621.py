import pandas as pd, numpy as np, json, time
t0 = time.time()
CSV = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260621_024425.csv'
OUT = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_diag_climate_0621.json'
WT = {0:'CLEAR',1:'RAIN',2:'STORM',3:'BLIZZARD',4:'DROUGHT',5:'FOG',6:'HEATWAVE',7:'MONSOON'}

cols = ['tick_idx','phys_sim_day','was_skipped_day','cell_index',
        'cell_lat_norm_arr','is_water_arr','elevation_arr',
        'cell_pos_x_arr','cell_pos_y_arr',
        'weather_precip_arr','weather_cloud_arr','weather_cloud_water_arr',
        'weather_vapor_arr','weather_type_arr']

print("[*] loading ...")
df = pd.read_csv(CSV, usecols=cols)
print(f"    loaded {len(df):,} rows in {time.time()-t0:.1f}s")

# 按 (cell, sim_day) 去重：每个 game-day 每 cell 一个代表值（跳日重复行折叠）
df = df.drop_duplicates(['cell_index','phys_sim_day'], keep='first')
df = df.sort_values(['cell_index','phys_sim_day']).reset_index(drop=True)
print(f"    after dedup (cell,day): {len(df):,} rows  in {time.time()-t0:.1f}s")

cell = df['cell_index'].astype(int).values
day  = df['phys_sim_day'].astype(int).values
precip = df['weather_precip_arr'].astype(float).values
cloud  = df['weather_cloud_arr'].astype(float).values
cloudw = df['weather_cloud_water_arr'].astype(float).values
vapor  = df['weather_vapor_arr'].astype(float).values
wtype  = df['weather_type_arr'].astype(int).values
iw     = df['is_water_arr'].astype(int).values
lat    = df['cell_lat_norm_arr'].astype(float).values
posx   = df['cell_pos_x_arr'].astype(float).values
posy   = df['cell_pos_y_arr'].astype(float).values

NC = int(cell.max())+1
ndays = np.zeros(NC); wet=np.zeros(NC); damp=np.zeros(NC); dry=np.zeros(NC)
psum=np.zeros(NC); pmax=np.zeros(NC); cloudsum=np.zeros(NC); cloudwmax=np.zeros(NC)
nswitch=np.zeros(NC,int); typemask=np.zeros(NC,int)
c_iw=np.zeros(NC,int); c_lat=np.zeros(NC); c_px=np.zeros(NC); c_py=np.zeros(NC)

# per-cell sequential metrics
WET_TH = 0.02      # 降水算"湿"的阈值
DRY_TH = 0.005     # 低于此算"干/晴"
prev_cell=-1; prev_type=-1
for i in range(len(df)):
    ce=cell[i]
    ndays[ce]+=1
    p=precip[i]
    if p>WET_TH: wet[ce]+=1
    if p>DRY_TH: damp[ce]+=1
    else: dry[ce]+=1
    psum[ce]+=p
    if p>pmax[ce]: pmax[ce]=p
    cloudsum[ce]+=cloud[i]
    if cloudw[i]>cloudwmax[ce]: cloudwmax[ce]=cloudw[i]
    tp=wtype[i]; typemask[ce]|=(1<<tp)
    if ce==prev_cell:
        if tp!=prev_type: nswitch[ce]+=1
    prev_cell=ce; prev_type=tp
    c_iw[ce]=iw[i]; c_lat[ce]=lat[i]; c_px[ce]=posx[i]; c_py[ce]=posy[i]

valid = ndays>0
wet_ratio = np.where(valid, wet/np.maximum(ndays,1), 0)
dry_ratio = np.where(valid, dry/np.maximum(ndays,1), 0)
ntypes = np.array([bin(m).count('1') for m in typemask])
pmean = np.where(valid, psum/np.maximum(ndays,1),0)

def frac(mask, sub=None):
    if sub is None: sub=valid
    d=valid&sub
    return float((mask&d).sum())/max(int(d.sum()),1)

land = valid&(c_iw==0); water = valid&(c_iw==1)
out={}
out['meta']={'rows_dedup':int(len(df)),'cells':int(valid.sum()),
             'land_cells':int(land.sum()),'water_cells':int(water.sum()),
             'days_per_cell_median':float(np.median(ndays[valid]))}

def block(name, sub):
    perma_rain = (wet_ratio>0.80)
    perma_dry  = (wet_ratio<0.05)
    never_wet  = (wet==0)
    never_switch = (nswitch==0)
    one_type = (ntypes<=1)
    return {
      'n':int(sub.sum()),
      'perma_rain_ratio(wet>80%)':frac(perma_rain,sub),
      'perma_dry_ratio(wet<5%)':frac(perma_dry,sub),
      'never_wet_ratio(0 wet day)':frac(never_wet,sub),
      'never_switch_type_ratio':frac(never_switch,sub),
      'single_type_whole_run_ratio':frac(one_type,sub),
      'mean_type_switches':float(nswitch[sub].mean()) if sub.sum() else 0,
      'mean_distinct_types':float(ntypes[sub].mean()) if sub.sum() else 0,
      'mean_wet_ratio':float(wet_ratio[sub].mean()) if sub.sum() else 0,
      'mean_precip':float(pmean[sub].mean()) if sub.sum() else 0,
    }
out['ALL']=block('ALL',valid)
out['LAND']=block('LAND',land)
out['WATER']=block('WATER',water)

# wet_ratio 分布直方图（U 型=两极分化=永雨永旱并存）
bins=np.linspace(0,1,11)
hist_all=np.histogram(wet_ratio[valid],bins=bins)[0]
hist_land=np.histogram(wet_ratio[land],bins=bins)[0]
hist_water=np.histogram(wet_ratio[water],bins=bins)[0]
out['wet_ratio_hist_bins']=[f'{bins[i]:.1f}-{bins[i+1]:.1f}' for i in range(10)]
out['wet_ratio_hist_all']=hist_all.tolist()
out['wet_ratio_hist_land']=hist_land.tolist()
out['wet_ratio_hist_water']=hist_water.tolist()

# 天气类型时间占比（全部去重行）
ut,ct=np.unique(wtype,return_counts=True)
tot=ct.sum()
out['type_dist_all']={WT[int(k)]:round(float(v)/tot,4) for k,v in zip(ut,ct)}
utl,ctl=np.unique(wtype[np.isin(cell, np.where(c_iw==0)[0])],return_counts=True)

# ---- 空间移动：Hovmöller (day × lon_band) 平均降水 ----
LB=24
px_min,px_max=posx.min(),posx.max()
lonb=np.clip(((posx-px_min)/max(px_max-px_min,1e-9)*LB).astype(int),0,LB-1)
days_sorted=np.unique(day)
day_index={d:i for i,d in enumerate(days_sorted)}
ndi=len(days_sorted)
hov=np.zeros((ndi,LB)); hovn=np.zeros((ndi,LB))
di=np.array([day_index[d] for d in day])
for k in range(len(df)):
    hov[di[k],lonb[k]]+=precip[k]; hovn[di[k],lonb[k]]+=1
hov=np.where(hovn>0,hov/np.maximum(hovn,1),0)
np.save(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_hovmoller_0621.npy',hov)

# 水平条纹度：固定经度带降水的时间方差/经度方差。若降水带不移动，时间方差≈0
time_var=hov.var(axis=0).mean()      # 每个 lon 带随时间的变化（小=永雨永旱不动）
lon_var =hov.var(axis=1).mean()      # 同一天不同经度的差异
out['hovmoller']={'shape':[ndi,LB],'time_var_per_lonband':float(time_var),
                  'lon_var_per_day':float(lon_var),
                  'ratio_time_over_lon':float(time_var/max(lon_var,1e-9))}

# 降水质心随天移动距离（衡量"雨带是否整体平移"）
cent=[]
for d in days_sorted:
    m=(day==d)&(precip>WET_TH)
    if m.sum()>0:
        w=precip[m]; cx=(posx[m]*w).sum()/w.sum(); cy=(posy[m]*w).sum()/w.sum()
        cent.append((cx,cy))
cent=np.array(cent)
if len(cent)>2:
    step=np.linalg.norm(np.diff(cent,axis=0),axis=1)
    out['precip_centroid']={'n':len(cent),'mean_step_px':float(step.mean()),
        'centroid_std_x':float(cent[:,0].std()),'centroid_std_y':float(cent[:,1].std()),
        'map_width_px':float(px_max-px_min)}

# 相邻采样日"湿格集合" Jaccard（高=降水格几乎不变=不移动）
wet_sets=[]
for d in days_sorted:
    m=(day==d)&(precip>WET_TH)
    wet_sets.append(set(cell[m].tolist()))
jacc=[]
for a,b in zip(wet_sets[:-1],wet_sets[1:]):
    u=len(a|b); 
    if u>0: jacc.append(len(a&b)/u)
out['wet_set_jaccard_adjacent_days']={'mean':float(np.mean(jacc)) if jacc else None,
    'median':float(np.median(jacc)) if jacc else None,
    'note':'1.0=降水格集合完全不变(永雨永旱/不移动); 低=降水区在演化/移动'}

print(json.dumps(out,ensure_ascii=False,indent=2))
with open(OUT,'w',encoding='utf-8') as f: json.dump(out,f,ensure_ascii=False,indent=2)
print(f"\n[OK] {time.time()-t0:.1f}s -> {OUT}")
