import pandas as pd, numpy as np, json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

CSV = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/tile_data_record_20260621_024425.csv'
HOV = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_hovmoller_0621.npy'
OUTPNG = r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_diag_climate_0621.png'

cols=['cell_index','phys_sim_day','weather_precip_arr','weather_cloud_water_arr',
      'cell_pos_x_arr','cell_pos_y_arr','is_water_arr','weather_type_arr']
df=pd.read_csv(CSV,usecols=cols)
df=df.drop_duplicates(['cell_index','phys_sim_day'])

df['wet']=(df['weather_precip_arr']>0.02).astype(float)
g=df.groupby('cell_index').agg(
    wet_ratio=('wet','mean'),
    px=('cell_pos_x_arr','first'),
    py=('cell_pos_y_arr','first'),
    iw=('is_water_arr','first'),
    pmean=('weather_precip_arr','mean')).reset_index()

hov=np.load(HOV)  # [day, lon]

# pick representative cells: 2 perma-rain, 2 perma-dry, 2 intermittent
days=np.sort(df['phys_sim_day'].unique())
def series(ci):
    sub=df[df.cell_index==ci].sort_values('phys_sim_day')
    return sub['phys_sim_day'].values, sub['weather_precip_arr'].values
land=g[g.iw==0]
perma_rain=land[land.wet_ratio>0.95].sort_values('pmean',ascending=False)['cell_index'].head(2).tolist()
perma_dry =land[land.wet_ratio<0.02]['cell_index'].head(2).tolist()
intermit  =land[(land.wet_ratio>0.35)&(land.wet_ratio<0.6)]['cell_index'].head(2).tolist()

fig=plt.figure(figsize=(16,11))

# (1) spatial wet_ratio map
ax1=fig.add_subplot(2,2,1)
sc=ax1.scatter(g.px,g.py,c=g.wet_ratio,cmap='RdYlBu_r',s=14,vmin=0,vmax=1)
ax1.set_title('(1) Per-cell rain frequency over 430 game-days\n(red=permanent rain, blue=permanent dry)  -- huge fixed blocks',fontsize=11)
ax1.set_xlabel('map x'); ax1.set_ylabel('map y'); ax1.invert_yaxis()
plt.colorbar(sc,ax=ax1,label='wet-day ratio')

# (2) Hovmoller precip  day x lon
ax2=fig.add_subplot(2,2,2)
vmax=np.percentile(hov[hov>0],95) if (hov>0).any() else 0.05
im=ax2.imshow(hov,aspect='auto',origin='lower',cmap='viridis',vmax=vmax,
              extent=[0,hov.shape[1],0,hov.shape[0]])
ax2.set_title('(2) Hovmoller: precip vs (longitude-band, day)\nVERTICAL stripes = rain bands DO NOT move (Jaccard 0.96)',fontsize=11)
ax2.set_xlabel('longitude band (west->east)'); ax2.set_ylabel('sampled day index')
plt.colorbar(im,ax=ax2,label='mean precip')

# (3) wet_ratio histogram (U-shape)
ax3=fig.add_subplot(2,2,3)
ax3.hist(g[g.iw==0].wet_ratio,bins=20,alpha=0.7,label='land',color='tab:green')
ax3.hist(g[g.iw==1].wet_ratio,bins=20,alpha=0.5,label='water',color='tab:blue')
ax3.set_title('(3) Distribution of per-cell rain frequency\nU-shape (piled at 0 and 1) = bimodal perma-rain / perma-dry',fontsize=11)
ax3.set_xlabel('wet-day ratio'); ax3.set_ylabel('cell count'); ax3.legend()

# (4) representative time series
ax4=fig.add_subplot(2,2,4)
for ci in perma_rain:
    d,p=series(ci); ax4.plot(d,p,color='tab:red',alpha=0.8,lw=0.8)
for ci in perma_dry:
    d,p=series(ci); ax4.plot(d,p,color='tab:blue',alpha=0.8,lw=0.8)
for ci in intermit:
    d,p=series(ci); ax4.plot(d,p,color='tab:gray',alpha=0.8,lw=0.8)
ax4.set_title('(4) Precip time series of sample land cells\nred=stuck wet, blue=stuck dry, gray=intermittent (rare)',fontsize=11)
ax4.set_xlabel('game day'); ax4.set_ylabel('precip')

plt.tight_layout()
plt.savefig(OUTPNG,dpi=110)
print('saved',OUTPNG)
print('perma_rain sample cells',perma_rain,'perma_dry',perma_dry,'intermit',intermit)
