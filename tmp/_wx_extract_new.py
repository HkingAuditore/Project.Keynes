import pandas as pd, numpy as np, time, sys
t0=time.time()
CSV=sys.argv[1] if len(sys.argv)>1 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260621_154003.csv'
OUT=sys.argv[2] if len(sys.argv)>2 else r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_new.npz'

daily_cols=['temp_arr','temp_arr_prev','air_mass_temp_anomaly_arr','temperature_transport_anomaly_arr',
            'wind_x_arr','wind_y_arr','wind_speed_arr',
            'weather_vapor_arr','weather_cloud_arr','weather_cloud_water_arr',
            'weather_precip_arr','weather_convergence_arr','weather_type_arr','temp_anomaly_arr',
            'temp_baseline_arr','temp_season_offset_arr','insolation_dev_arr','temp_365d_arr',
            'soil_moisture_arr','river_discharge_30d_arr']
static_cols=['terrain_arr','elevation_arr','moisture_arr','vegetation_arr',
             'vegetation_vitality_arr','has_river_arr','sea_ice_frac_arr',
             'q','r','s','cell_pos_x_arr','cell_pos_y_arr','is_water_arr']
idcols=['cell_index','phys_sim_day']
cols=idcols+daily_cols+static_cols

print('[*] loading...')
df=pd.read_csv(CSV,usecols=cols)
df=df.drop_duplicates(['cell_index','phys_sim_day'],keep='first')
_n0=len(df)
df=df.dropna(subset=['cell_index','phys_sim_day'])   # 滤掉不完整行(cell_index NaN：CSV 写入中断/末行截断)
print(f'    {len(df):,} rows  {time.time()-t0:.1f}s  (dropped {_n0-len(df)} NaN-id rows)')

cell=df['cell_index'].astype(int).values
day=df['phys_sim_day'].astype(int).values
NC=int(cell.max())+1
days=np.sort(np.unique(day)); ND=len(days)
dmap={d:i for i,d in enumerate(days)}
di=np.array([dmap[d] for d in day]); ci=cell

stat={}
first_idx={}
for k in range(len(df)):
    c=ci[k]
    if c not in first_idx or day[k]<day[first_idx[c]]:
        first_idx[c]=k
fidx=np.array([first_idx[c] for c in range(NC)])
for col in static_cols:
    stat[col]=df[col].values[fidx].astype(float)

daily={}
for col in daily_cols:
    M=np.full((ND,NC),np.nan,dtype=np.float32)
    M[di,ci]=df[col].astype(float).values
    daily[col]=M

q=stat['q'].astype(int); r=stat['r'].astype(int)
qr2idx={}
for c in range(NC):
    qr2idx[(q[c],r[c])]=c
dirs=[(1,-1),(1,0),(0,1),(-1,1),(-1,0),(0,-1)]
NB=np.full((NC,6),-1,dtype=np.int32)
for c in range(NC):
    for d,(dq,dr) in enumerate(dirs):
        nb=qr2idx.get((q[c]+dq,r[c]+dr),-1)
        NB[c,d]=nb
nb_count=(NB>=0).sum(1)
print(f'    neighbor: mean={nb_count.mean():.2f} cells with 6={int((nb_count==6).sum())}')

px=stat['cell_pos_x_arr']; py=stat['cell_pos_y_arr']
dists=[]
for c in range(NC):
    for d in range(6):
        nb=NB[c,d]
        if nb>=0:
            dists.append(((px[c]-px[nb])**2+(py[c]-py[nb])**2)**0.5)
d_nb=float(np.median(dists))
hex_size=d_nb*0.55
print(f'    median neighbor spacing={d_nb:.3f} -> hex_size={hex_size:.3f}')

np.savez_compressed(OUT, days=days, NC=NC, ND=ND, hex_size=hex_size, d_nb=d_nb,
                    NB=NB, px=px, py=py,
                    **{f'st_{k}':v for k,v in stat.items()},
                    **{f'dy_{k}':v for k,v in daily.items()})
print(f'[OK] {time.time()-t0:.1f}s -> {OUT}  (ND={ND}, NC={NC})')
