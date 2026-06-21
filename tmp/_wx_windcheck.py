import numpy as np
z=np.load(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_0621.npz')
wx=np.nan_to_num(z['dy_wind_x_arr'].astype(np.float64))
wy=np.nan_to_num(z['dy_wind_y_arr'].astype(np.float64))
ws=np.nan_to_num(z['dy_wind_speed_arr'].astype(np.float64))
ND,NC=wx.shape
# normalize directions
mag=np.sqrt(wx*wx+wy*wy)+1e-9
ux=wx/mag; uy=wy/mag
# adjacent-day direction dot product (1 = identical direction = frozen)
dots=[]
for d in range(1,ND):
    dot=ux[d-1]*ux[d]+uy[d-1]*uy[d]
    dots.append(dot.mean())
dots=np.array(dots)
print(f'wind speed: mean={ws.mean():.3f}  p95={np.percentile(ws,95):.3f}')
print(f'adjacent-day wind DIRECTION dot product: mean={dots.mean():.4f} (1.0=frozen direction)')
print(f'  -> mean turn angle per sampled-day ~ {np.degrees(np.arccos(np.clip(dots.mean(),-1,1))):.1f} deg')
# per-cell temporal std of wind components (low = static wind field)
print(f'per-cell time-std wind_x mean={wx.std(0).mean():.4f}  wind_y mean={wy.std(0).mean():.4f}')
print(f'per-cell time-std |wind| mean={mag.std(0).mean():.4f}  (vs mean |wind| {mag.mean():.3f})')
# how much does the wind field pattern persist? correlation of wind_x map day0 vs dayK
base=wx[0]-wx[0].mean()
cors=[]
for d in range(0,ND,max(ND//20,1)):
    a=wx[d]-wx[d].mean()
    c=(base*a).sum()/(np.sqrt((base*base).sum()*(a*a).sum())+1e-9)
    cors.append((int(z['days'][d]),round(float(c),3)))
print('wind_x spatial-pattern correlation vs day0:',cors)
