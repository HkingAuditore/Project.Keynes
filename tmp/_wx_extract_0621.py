import pandas as pd, numpy as np, time
t0=time.time()
CSV=r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260621_024425.csv'
OUT=r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_0621.npz'

daily_cols=['temp_arr','temp_arr_prev','air_mass_temp_anomaly_arr','temperature_transport_anomaly_arr',
            'wind_x_arr','wind_y_arr','wind_speed_arr',
            'weather_vapor_arr','weather_cloud_arr','weather_cloud_water_arr',
            'weather_precip_arr','weather_convergence_arr','weather_type_arr','temp_anomaly_arr']
static_cols=['terrain_arr','elevation_arr','moisture_arr','vegetation_arr','soil_moisture_arr',
             'vegetation_vitality_arr','has_river_arr','river_discharge_30d_arr','sea_ice_frac_arr',
             'q','r','s','cell_pos_x_arr','cell_pos_y_arr','is_water_arr']
idcols=['cell_index','phys_sim_day']
cols=idcols+daily_cols+static_cols

print('[*] loading...')
df=pd.read_csv(CSV,usecols=cols)
df=df.drop_duplicates(['cell_index','phys_sim_day'],keep='first')
print(f'    {len(df):,} rows  {time.time()-t0:.1f}s')

cell=df['cell_index'].astype(int).values
day=df['phys_sim_day'].astype(int).values
NC=int(cell.max())+1
days=np.sort(np.unique(day)); ND=len(days)
dmap={d:i for i,d in enumerate(days)}
di=np.array([dmap[d] for d in day]); ci=cell

# static (per cell, first occurrence)
stat={}
seen=np.zeros(NC,bool)
order=np.argsort(day,kind='stable')  # earliest day first per cell after this stable order on (cell,day)
# Build static by taking, for each cell, the row with smallest day
first_idx={}
for k in range(len(df)):
    c=ci[k]
    if c not in first_idx or day[k]<day[first_idx[c]]:
        first_idx[c]=k
fidx=np.array([first_idx[c] for c in range(NC)])
for col in static_cols:
    stat[col]=df[col].values[fidx].astype(float)

# daily matrices [ND, NC]
daily={}
for col in daily_cols:
    M=np.full((ND,NC),np.nan,dtype=np.float32)
    M[di,ci]=df[col].astype(float).values
    daily[col]=M

# ---- rebuild neighbor topology from cube coords ----
q=stat['q'].astype(int); r=stat['r'].astype(int)
qr2idx={}
for c in range(NC):
    qr2idx[(q[c],r[c])]=c
dirs=[(1,-1),(1,0),(0,1),(-1,1),(-1,0),(0,-1)]  # (dq,dr)
NB=np.full((NC,6),-1,dtype=np.int32)
for c in range(NC):
    for d,(dq,dr) in enumerate(dirs):
        nb=qr2idx.get((q[c]+dq,r[c]+dr),-1)
        NB[c,d]=nb
nb_count=(NB>=0).sum(1)
print(f'    neighbor: mean={nb_count.mean():.2f} (interior should be 6), cells with 6={int((nb_count==6).sum())}')

# infer hex_size from CSV cell_pos so neighbor_aligned threshold matches C++ ratio (~0.18*spacing)
px=stat['cell_pos_x_arr']; py=stat['cell_pos_y_arr']
dists=[]
for c in range(NC):
    for d in range(6):
        nb=NB[c,d]
        if nb>=0:
            dists.append(((px[c]-px[nb])**2+(py[c]-py[nb])**2)**0.5)
d_nb=float(np.median(dists))
hex_size=d_nb*0.55  # threshold hex_size*0.31177 ~= 0.18*d_nb (mirror C++ ratio)
print(f'    median neighbor spacing(csv cell_pos)={d_nb:.3f} -> hex_size={hex_size:.3f}')

# check base_m (moisture) static-ness across days
mois=daily.get('weather_vapor_arr')  # placeholder; check moisture separately
# moisture is static_col but let's verify variability from raw
mvar=df.groupby('cell_index')['moisture_arr'].std().fillna(0).mean()
print(f'    mean per-cell std of moisture_arr across days = {mvar:.4f} (small=static climate humidity)')

np.savez_compressed(OUT, days=days, NC=NC, ND=ND, hex_size=hex_size, d_nb=d_nb,
                    NB=NB, px=px, py=py,
                    **{f'st_{k}':v for k,v in stat.items()},
                    **{f'dy_{k}':v for k,v in daily.items()})
print(f'[OK] {time.time()-t0:.1f}s -> {OUT}  (ND={ND}, NC={NC})')
