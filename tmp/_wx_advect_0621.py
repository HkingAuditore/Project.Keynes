"""离线平流式湿团模型 (Advective moisture-blob weather solver).

核心区别于旧"诊断式降水"：vapor / cloud_water 是随风平流的【守恒物质】。
  蒸发 E -> vapor(+)
  凝结 condensation: vapor -> cloud_water (内部转移, 守恒)
  降水 P: 消耗 cloud_water 移出系统(-),  P<=cw  (不能下超过现有云水)
  再蒸发 reevap: cloud_water -> vapor (干环境内部转移)
  地形抬升/辐合/移动低压 = 凝结&降水【效率调制】, 不是无条件降水源
=> 湿团随风移动; 下雨耗尽云水后该地变干(除非上游补给) => 自然消除永雨永旱.
"""
import numpy as np, time
from numba import njit

NPZ=r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_0621.npz'

# ---------------- helpers (copied from _wx_iter) ----------------
@njit(cache=True, fastmath=False)
def _smoothstep(e0,e1,x):
    if e1==e0: return 0.0
    t=(x-e0)/(e1-e0)
    if t<0.0: t=0.0
    elif t>1.0: t=1.0
    return t*t*(3.0-2.0*t)

@njit(cache=True)
def _is_water(t):
    return t==0 or t==1 or t==18 or t==19 or t==20 or t==21

@njit(cache=True)
def _veg_transp(v):
    if v==0: return 0.0
    if v==14 or v==19 or v==20: return 1.0
    if v==5 or v==7 or v==12: return 0.65
    if v==9 or v==13 or v==21: return 0.35
    return 0.18

@njit(cache=True)
def _terr_damp(t):
    if t==18: return 1.0
    if t==22: return 1.0
    if t==10: return 0.8
    if t==11: return 0.55
    if t==5: return 0.45
    return 0.0

@njit(cache=True)
def _aligned(idx,dx,dy,px,py,NB,hex_size):
    dl2=dx*dx+dy*dy
    if dl2<=0.0001: return -1
    inv=1.0/np.sqrt(dl2); ndx=dx*inv; ndy=dy*inv
    sx=px[idx]; sy=py[idx]
    best=-1; bestdot=hex_size*0.31176915
    for d in range(6):
        nb=NB[idx,d]
        if nb<0: continue
        tx=px[nb]-sx; ty=py[nb]-sy
        dot=tx*ndx+ty*ndy
        if dot>bestdot:
            bestdot=dot; best=nb
    return best

@njit(cache=True)
def _surface_src(idx,temp,base_m,wind_mag,ocean_an,on_water,is_lake,has_river,river_q,
                 terrain,VEG,SOIL,VITA,SICE,ocean_evap_gain,land_evap_gain,lake_evap_scale):
    temp_evap=_smoothstep(0.10,0.78,temp)
    wind_evap=0.70+wind_mag*0.55
    t=terrain[idx]
    wet_bonus=0.0
    if t==10 or t==11 or t==22: wet_bonus=0.010
    elif t==18: wet_bonus=0.016
    if on_water:
        sea_ice=SICE[idx]
        if sea_ice<0.0: sea_ice=0.0
        elif sea_ice>1.0: sea_ice=1.0
        src=(0.018+temp_evap*0.052)*ocean_evap_gain*wind_evap
        m=1.0+ocean_an*0.55
        if m<0.55: m=0.55
        elif m>1.45: m=1.45
        src*=m
        src*=(1.0-sea_ice*0.92)
        if is_lake: src*=lake_evap_scale
        return src if src>0.0 else 0.0
    soil=SOIL[idx]
    soil_norm=0.5+soil
    if soil_norm<0.0: soil_norm=0.0
    elif soil_norm>1.0: soil_norm=1.0
    vit=VITA[idx]
    if vit<0.0: vit=0.0
    elif vit>1.0: vit=1.0
    veg_flux=_veg_transp(VEG[idx])*(0.45+vit*0.65)
    src=(0.005+base_m*0.010+soil_norm*0.020+veg_flux*0.016+wet_bonus)*land_evap_gain*temp_evap*(0.85+wind_mag*0.25)
    if has_river:
        src+=(0.010+river_q*0.020)*land_evap_gain*temp_evap
    return src if src>0.0 else 0.0


# ---------------- advective moisture-blob solver ----------------
@njit(cache=True)
def simulate_advect(ND,NC,NB,px,py,pxn,pyn,hex_size,advect_steps,
                    terrain,elev,base_m,veg,soil,vita,has_river,river_q30,sea_ice,
                    dy_temp,dy_air,dy_TA,dy_wx,dy_wy,dy_wspd,
                    init_vapor,init_cw,init_precip,
                    # --- evaporation source ---
                    ocean_evap_gain,land_evap_gain,lake_evap_scale,
                    # --- advection (the heart) ---
                    advect_vapor,advect_cw,diffusion,
                    # --- saturation capacity ---
                    cap_base,cap_temp,cap_elev,
                    # --- condensation vapor->cw ---
                    rh_cond,sup_w,cond_rate,lift_cond,conv_cond,rain_shadow,
                    # --- precip: cw->ground ---
                    autoconv,base_frac,trig_lift,trig_conv,oro_precip_gain,instab_gain,
                    ocean_keep,cw_reevap,precip_inertia,
                    # --- precip stability ---
                    wet_terrain_damp,lake_precip_damp,soft_cap,softness,
                    # --- mobile lows ---
                    mlow_count,mlow_sigma,mlow_period,mlow_wind_amp,mlow_tang,mlow_inflow,world_seed,
                    out_precip,out_cw,out_cloud,out_vapor):
    vapor=init_vapor.copy(); cw=init_cw.copy(); precip=init_precip.copy()
    nv=np.empty(NC); ncw=np.empty(NC); npre=np.empty(NC); ncld=np.empty(NC)
    chain_idx=np.empty(8,dtype=np.int64); chain_w=np.empty(8)
    mcx=np.empty(8); mcy=np.empty(8)
    ewx=np.empty(NC); ewy=np.empty(NC); ews=np.empty(NC)
    mlow_inv2s2=1.0/(2.0*mlow_sigma*mlow_sigma)
    for d in range(ND):
        T=dy_temp[d]; AIR=dy_air[d]; TA=dy_TA[d]; WX=dy_wx[d]; WY=dy_wy[d]; WSPD=dy_wspd[d]
        # mobile low centers (drift east with day)
        nml=0
        if mlow_wind_amp>0.0 and mlow_count>0:
            nml=int(mlow_count)
            if nml>8: nml=8
            for j in range(nml):
                h=(np.uint32(world_seed)*np.uint32(2654435761)+np.uint32(j)*np.uint32(40503)+np.uint32(1013904223))
                h=h^(h>>np.uint32(16)); h=h*np.uint32(2246822519); h=h^(h>>np.uint32(13))
                hx=float(h & np.uint32(0xFFFF))/65535.0
                hy=float((h>>np.uint32(16)) & np.uint32(0xFFFF))/65535.0
                cx=hx+float(d)/mlow_period
                cx=cx-np.floor(cx)
                cy=0.20+0.60*hy+0.05*np.sin(float(d)*0.045+float(j)*1.7)
                if cy<0.04: cy=0.04
                elif cy>0.96: cy=0.96
                mcx[j]=cx; mcy[j]=cy
        # ---- effective wind = background + moving cyclonic circulation (the key) ----
        for i in range(NC):
            vx=WX[i]*WSPD[i]; vy=WY[i]*WSPD[i]
            if nml>0:
                pmx=pxn[i]; pmyv=pyn[i]
                for j in range(nml):
                    ddxm=pmx-mcx[j]
                    if ddxm>0.5: ddxm-=1.0
                    elif ddxm<-0.5: ddxm+=1.0
                    ddym=pmyv-mcy[j]
                    r2=ddxm*ddxm+ddym*ddym
                    fall=np.exp(-r2*mlow_inv2s2)
                    rr=np.sqrt(r2)+1e-4
                    amp=mlow_wind_amp*fall
                    # cyclonic: counter-clockwise tangential + inward radial -> converges & carries blobs
                    vx+=amp*((-ddym/rr)*mlow_tang+(-ddxm/rr)*mlow_inflow)
                    vy+=amp*(( ddxm/rr)*mlow_tang+(-ddym/rr)*mlow_inflow)
            ewx[i]=vx; ewy[i]=vy
            ews[i]=np.sqrt(vx*vx+vy*vy)
        for i in range(NC):
            temp=T[i]+AIR[i]
            if temp<0.0: temp=0.0
            elif temp>1.0: temp=1.0
            bm=base_m[i]
            if bm<0.0: bm=0.0
            elif bm>1.0: bm=1.0
            cap=cap_base+cap_temp*temp-cap_elev*elev[i]
            if cap<0.12: cap=0.12
            elif cap>1.2: cap=1.2
            on_water=_is_water(terrain[i])
            is_lake=(terrain[i]==18)
            wx=ewx[i]; wy=ewy[i]; wl2=wx*wx+wy*wy
            if wl2<0.0001:
                wdx=1.0; wdy=0.0
            else:
                inv=1.0/np.sqrt(wl2); wdx=wx*inv; wdy=wy*inv
            wspd=ews[i]
            wind_mag=wspd/1.2
            if wind_mag<0.0: wind_mag=0.0
            elif wind_mag>1.0: wind_mag=1.0
            # ---- upstream chain (semi-Lagrangian) ----
            up=_aligned(i,-wdx,-wdy,px,py,NB,hex_size) if advect_steps>0 else -1
            nchain=0
            if up>=0:
                chain_idx[0]=up; chain_w[0]=1.0; nchain=1; cur=up; wd=0.7
                for st in range(1,advect_steps):
                    nx=_aligned(cur,-wdx,-wdy,px,py,NB,hex_size)
                    if nx<0: break
                    chain_idx[nchain]=nx; chain_w[nchain]=wd; nchain+=1; cur=nx; wd*=0.7
            if nchain>0:
                sv=0.0; sc=0.0; sw=0.0
                for k in range(nchain):
                    ww=chain_w[k]; ci=chain_idx[k]
                    sv+=vapor[ci]*ww; sc+=cw[ci]*ww; sw+=ww
                v_up=sv/sw; cw_up=sc/sw
            else:
                v_up=vapor[i]; cw_up=cw[i]
            # advection blend (wind-scaled)
            aw=advect_vapor*(0.55+0.45*wind_mag)
            if aw>0.97: aw=0.97
            awc=advect_cw*(0.55+0.45*wind_mag)
            if awc>0.98: awc=0.98
            v_a=vapor[i]*(1.0-aw)+v_up*aw
            cw_a=cw[i]*(1.0-awc)+cw_up*awc
            # neighbor diffusion (numeric smoothing)
            s=vapor[i]; n=1; scw=cw[i]
            for d2 in range(6):
                nb=NB[i,d2]
                if nb<0: continue
                s+=vapor[nb]; scw+=cw[nb]; n+=1
            v_a+=(s/n - v_a)*diffusion
            cw_a+=(scw/n - cw_a)*diffusion
            # ---- ocean anomaly (for evap modulation only) ----
            if on_water:
                ocean_an=TA[i]
            else:
                so=0.0; nw=0
                for d2 in range(6):
                    nb=NB[i,d2]
                    if nb<0: continue
                    if _is_water(terrain[nb]):
                        so+=TA[nb]; nw+=1
                ocean_an=so/nw if nw>0 else 0.0
            hriv=(not is_lake) and (has_river[i]!=0) and (not on_water)
            rflow=0.0
            if hriv:
                rflow=river_q30[i]
                if rflow<0.0: rflow=0.0
                elif rflow>1.0: rflow=1.0
            eff_an=ocean_an
            if is_lake: eff_an=0.20
            # ---- evaporation source -> vapor (mass IN) ----
            E=_surface_src(i,temp,bm,wind_mag,eff_an,on_water,is_lake,hriv,rflow,
                           terrain,veg,soil,vita,sea_ice,ocean_evap_gain,land_evap_gain,lake_evap_scale)
            v1=v_a+E
            if v1<0.0: v1=0.0
            # ---- orographic lift (from upstream elev diff) ----
            lift=0.0
            if up>=0:
                diff=elev[i]-elev[up]
                if diff>0.02:
                    lift=diff*2.2
                    if lift>1.0: lift=1.0
                elif diff<-0.02:
                    lift=diff*1.6
                    if lift<-1.0: lift=-1.0
            lift_pos=lift if lift>0.0 else 0.0
            # ---- convergence from wind field ----
            sx=px[i]; sy=py[i]; incoming=0.0; checked=0
            for d2 in range(6):
                nb=NB[i,d2]
                if nb<0: continue
                ddx=sx-px[nb]; ddy=sy-py[nb]; dl2=ddx*ddx+ddy*ddy
                if dl2<=0.0001: continue
                nwx=ewx[nb]; nwy=ewy[nb]; nwl2=nwx*nwx+nwy*nwy
                if nwl2<=0.0001: continue
                invd=1.0/np.sqrt(dl2); invw=1.0/np.sqrt(nwl2)
                cosin=(ddx*nwx+ddy*nwy)*(invd*invw)
                if cosin<0.0: cosin=0.0
                nsp=np.sqrt(nwl2)
                spw=nsp/1.2
                if spw<0.20: spw=0.20
                elif spw>1.25: spw=1.25
                incoming+=cosin*spw; checked+=1
            convergence=incoming/checked if checked>0 else 0.0
            if convergence<0.0: convergence=0.0
            elif convergence>1.0: convergence=1.0
            # (mobile lows now enter via the effective wind field -> convergence & advection)
            # ---- condensation: vapor -> cloud_water (mass conserved) ----
            rh=v1/(cap if cap>0.001 else 0.001)
            if rh<0.0: rh=0.0
            sup=rh-rh_cond
            if sup<0.0: sup=0.0
            cond_force=sup*sup_w+lift_pos*lift_cond+convergence*conv_cond
            if cond_force<0.0: cond_force=0.0
            elif cond_force>1.0: cond_force=1.0
            condensation=v1*cond_force*cond_rate
            if lift<0.0:  # downslope foehn: suppress condensation, dry out
                fac=1.0+lift*rain_shadow
                if fac<0.0: fac=0.0
                condensation*=fac
            if condensation>v1*0.92: condensation=v1*0.92
            if condensation<0.0: condensation=0.0
            v2=v1-condensation
            cw1=cw_a+condensation
            if cw1<0.0: cw1=0.0
            # ---- precipitation: autoconversion consumes cloud_water ----
            instab=(temp-0.48)*1.05+rh*0.30+convergence*0.55+lift_pos*1.2
            if instab<0.0: instab=0.0
            elif instab>1.0: instab=1.0
            trig=autoconv*(base_frac+lift_pos*trig_lift+convergence*trig_conv+instab*instab_gain)
            trig*=(1.0+lift_pos*oro_precip_gain)
            if trig<0.0: trig=0.0
            elif trig>0.95: trig=0.95
            P=cw1*trig
            if lift<0.0:
                shadow=(-lift)*rain_shadow
                if shadow>0.85: shadow=0.85
                P*=(1.0-shadow)
            if on_water:  # mild convective suppression over open water
                odrive=convergence
                if instab>odrive: odrive=instab
                P*=ocean_keep+(1.0-ocean_keep)*odrive
            if P>cw1: P=cw1
            if P<0.0: P=0.0
            cw2=cw1-P
            # ---- cloud re-evaporation in dry air: cw -> vapor ----
            reevap=cw2*cw_reevap*(1.0-rh)
            if reevap<0.0: reevap=0.0
            if reevap>cw2: reevap=cw2
            cw3=cw2-reevap
            v3=v2+reevap
            # ---- precip stability: terrain damp + soft cap + inertia ----
            out=P
            fac=_terr_damp(terrain[i])
            if fac>0.0 and out>0.08:
                damp=lake_precip_damp if terrain[i]==18 else wet_terrain_damp
                if damp<0.0: damp=0.0
                elif damp>1.0: damp=1.0
                out-=(out-0.08)*damp*fac
            if soft_cap>0.0 and out>soft_cap:
                out=soft_cap+(out-soft_cap)*softness
            if out<0.0: out=0.0
            elif out>1.0: out=1.0
            pr=precip[i]+(out-precip[i])*precip_inertia
            if pr<0.003: pr=0.0
            # ---- store ----
            if v3<0.0: v3=0.0
            elif v3>1.3: v3=1.3
            if cw3<0.0: cw3=0.0
            elif cw3>1.0: cw3=1.0
            cloud=cw3*1.05+condensation*0.4
            if cloud>1.0: cloud=1.0
            nv[i]=v3; ncw[i]=cw3; npre[i]=pr; ncld[i]=cloud
        for i in range(NC):
            vapor[i]=nv[i]; cw[i]=ncw[i]; precip[i]=npre[i]
        out_precip[d]=precip; out_cw[d]=cw; out_cloud[d]=ncld; out_vapor[d]=vapor


# ---------------- metrics ----------------
def metrics(precip, px, py, warm=40, wet_th=0.02):
    ND,NC=precip.shape
    P=precip[warm:]
    wet=(P>wet_th).mean(0)
    perma_rain=float((wet>0.80).mean())
    perma_dry=float((wet<0.05).mean())
    extreme=float(((wet<0.1)|(wet>0.9)).mean())
    js=[]
    for d in range(1,P.shape[0]):
        a=P[d-1]>wet_th; b=P[d]>wet_th
        u=(a|b).sum()
        if u>0: js.append((a&b).sum()/u)
    jacc=float(np.mean(js)) if js else 1.0
    LB=24
    pn=(px-px.min())/max(px.max()-px.min(),1e-9)
    lonb=np.clip((pn*LB).astype(int),0,LB-1)
    hov=np.zeros((P.shape[0],LB))
    for b in range(LB):
        m=lonb==b
        if m.any(): hov[:,b]=P[:,m].mean(1)
    tvar=hov.var(0).mean(); lvar=hov.var(1).mean()
    return dict(perma_rain=perma_rain,perma_dry=perma_dry,extreme_bins=extreme,jaccard=jacc,
                hov_time_over_lon=float(tvar/max(lvar,1e-9)),
                mean_wet_ratio=float(wet.mean()),mean_precip=float(P.mean()))

def hovm(P,px,warm=40,LB=24):
    Pw=P[warm:]
    pn=(px-px.min())/max(px.max()-px.min(),1e-9)
    lonb=np.clip((pn*LB).astype(int),0,LB-1)
    H=np.zeros((Pw.shape[0],LB))
    for b in range(LB):
        m=lonb==b
        if m.any(): H[:,b]=Pw[:,m].mean(1)
    return H


if __name__=='__main__':
    z=np.load(NPZ,allow_pickle=True)
    ND=int(z['ND']); NC=int(z['NC']); NB=z['NB']
    px=z['px'].astype(np.float64); py=z['py'].astype(np.float64)
    hex_size=float(z['hex_size'])
    pxn=(px-px.min())/max(px.max()-px.min(),1e-9)
    pyn=(py-py.min())/max(py.max()-py.min(),1e-9)
    g=lambda k: np.nan_to_num(z['st_'+k].astype(np.float64))
    terrain=z['st_terrain_arr'].astype(np.int64)
    elev=g('elevation_arr'); base_m=g('moisture_arr'); veg=z['st_vegetation_arr'].astype(np.int64)
    soil=g('soil_moisture_arr'); vita=g('vegetation_vitality_arr')
    has_river=z['st_has_river_arr'].astype(np.int64); river_q30=g('river_discharge_30d_arr')
    sea_ice=g('sea_ice_frac_arr')
    d=lambda k: np.nan_to_num(z['dy_'+k].astype(np.float64))
    dy_temp=d('temp_arr'); dy_air=np.zeros_like(dy_temp); dy_TA=d('temperature_transport_anomaly_arr')
    dy_wx=d('wind_x_arr'); dy_wy=d('wind_y_arr'); dy_wspd=d('wind_speed_arr')
    ref_precip=d('weather_precip_arr')
    print(f'[CSV ref量级] vapor={d("weather_vapor_arr")[40:].mean():.3f} cw={d("weather_cloud_water_arr")[40:].mean():.4f} precip={ref_precip[40:].mean():.4f}')
    init_vapor=d('weather_vapor_arr')[0].copy(); init_cw=d('weather_cloud_water_arr')[0].copy()
    init_precip=d('weather_precip_arr')[0].copy()
    advect_steps=4

    # ---- advective knobs (initial guess; to be calibrated) ----
    # [平流式湿团 v2] 移动低压改造为"移动的气旋式辐合风场": 平流(搬运云水)+辐合(触发降水)都用合成风.
    K=dict(ocean_evap_gain=1.30,land_evap_gain=1.00,lake_evap_scale=0.45,
           advect_vapor=0.82,advect_cw=0.94,diffusion=0.05,
           cap_base=0.20,cap_temp=0.80,cap_elev=0.20,
           rh_cond=0.55,sup_w=1.00,cond_rate=0.45,lift_cond=0.80,conv_cond=1.00,rain_shadow=0.50,
           autoconv=0.12,base_frac=0.20,trig_lift=0.25,trig_conv=1.80,oro_precip_gain=0.10,instab_gain=0.30,
           ocean_keep=0.65,cw_reevap=0.06,precip_inertia=0.40,
           wet_terrain_damp=0.45,lake_precip_damp=0.55,soft_cap=0.18,softness=0.35,
           mlow_count=6,mlow_sigma=0.16,mlow_period=20.0,mlow_wind_amp=1.60,mlow_tang=1.00,mlow_inflow=0.60,world_seed=10086)
    order=['ocean_evap_gain','land_evap_gain','lake_evap_scale',
           'advect_vapor','advect_cw','diffusion',
           'cap_base','cap_temp','cap_elev',
           'rh_cond','sup_w','cond_rate','lift_cond','conv_cond','rain_shadow',
           'autoconv','base_frac','trig_lift','trig_conv','oro_precip_gain','instab_gain',
           'ocean_keep','cw_reevap','precip_inertia',
           'wet_terrain_damp','lake_precip_damp','soft_cap','softness',
           'mlow_count','mlow_sigma','mlow_period','mlow_wind_amp','mlow_tang','mlow_inflow','world_seed']

    west_wx=np.ones((ND,NC)); west_wy=np.zeros((ND,NC)); west_wspd=np.full((ND,NC),1.2)

    def run(wind,**ov):
        k=dict(K); k.update(ov)
        args=[k[n] for n in order]
        wx,wy,ws=(dy_wx,dy_wy,dy_wspd) if wind=='csv' else (west_wx,west_wy,west_wspd)
        op=np.zeros((ND,NC)); oc=np.zeros((ND,NC)); ocl=np.zeros((ND,NC)); ov_=np.zeros((ND,NC))
        simulate_advect(ND,NC,NB,px,py,pxn,pyn,hex_size,advect_steps,
                        terrain,elev,base_m,veg,soil,vita,has_river,river_q30,sea_ice,
                        dy_temp,dy_air,dy_TA,wx,wy,ws,
                        init_vapor,init_cw,init_precip,*args,
                        op,oc,ocl,ov_)
        return op,oc,ocl,ov_

    t0=time.time()
    csv=run('csv')
    csv0=run('csv',mlow_wind_amp=0.0)   # 纯平流式湿团, 不合成气旋环流, 只吃CSV真实风
    west=run('westerly')
    print(f'[advect sim x3] {time.time()-t0:.1f}s')

    def conserv(tag,res):
        op,oc,ocl,ov=res
        vmean=ov[40:].mean(); cmean=oc[40:].mean()
        v0=ov[40:60].mean(); v1=ov[-20:].mean()
        c0=oc[40:60].mean(); c1=oc[-20:].mean()
        print(f'  {tag:10s} vapor mean={vmean:.3f}(start{v0:.3f}->end{v1:.3f})  cw mean={cmean:.3f}(start{c0:.3f}->end{c1:.3f})  precip mean={op[40:].mean():.4f}')

    print('mass balance (枯竭<->爆炸 check):')
    conserv('csv',csv); conserv('west',west)

    rows=[('CSV_recorded',metrics(ref_precip,px,py)),
          ('advect_csv',metrics(csv[0],px,py)),
          ('advect_csv_noMlow',metrics(csv0[0],px,py)),
          ('advect_west',metrics(west[0],px,py))]
    keys=['perma_rain','perma_dry','extreme_bins','jaccard','hov_time_over_lon','mean_wet_ratio','mean_precip']
    print(f"\n{'experiment':14s} "+" ".join(f"{x[:11]:>11s}" for x in keys))
    for name,mm in rows:
        print(f"{name:14s} "+" ".join(f"{mm[x]:11.3f}" for x in keys))

    # ---- plot ----
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    fig=plt.figure(figsize=(16,10))
    Hw=hovm(west[0],px); Hc=hovm(csv[0],px)
    vmax=max(np.percentile(Hw[Hw>0],95) if (Hw>0).any() else 0.05,
             np.percentile(Hc[Hc>0],95) if (Hc>0).any() else 0.05)
    ax=fig.add_subplot(2,2,1); im=ax.imshow(Hw,aspect='auto',origin='lower',cmap='viridis',vmax=vmax,extent=[0,24,0,Hw.shape[0]])
    ax.set_title('(1) STEADY WEST WIND + ADVECTIVE blobs + mobile lows\nDIAGONAL stripes = rain systems MOVE east',fontsize=10)
    ax.set_xlabel('lon band (west->east)'); ax.set_ylabel('day'); plt.colorbar(im,ax=ax)
    ax=fig.add_subplot(2,2,2); im=ax.imshow(Hc,aspect='auto',origin='lower',cmap='viridis',vmax=vmax,extent=[0,24,0,Hc.shape[0]])
    ax.set_title('(2) CSV wind + ADVECTIVE blobs',fontsize=10)
    ax.set_xlabel('lon band (west->east)'); ax.set_ylabel('day'); plt.colorbar(im,ax=ax)
    ax=fig.add_subplot(2,2,3)
    wr_ref=(ref_precip[40:]>0.02).mean(0); wr_c=(csv[0][40:]>0.02).mean(0)
    ax.hist(wr_ref,bins=20,alpha=0.5,label='CSV recorded',color='tab:gray')
    ax.hist(wr_c,bins=20,alpha=0.6,label='advective (csv wind)',color='tab:green')
    ax.set_title('(3) per-cell rain frequency\nless piled at 0/1 = fewer perma-rain/perma-dry',fontsize=10)
    ax.set_xlabel('wet-day ratio'); ax.set_ylabel('cells'); ax.legend()
    ax=fig.add_subplot(2,2,4)
    names=[r[0] for r in rows]; jac=[r[1]['jaccard'] for r in rows]; ext=[r[1]['extreme_bins'] for r in rows]
    xx=np.arange(len(names)); ax.bar(xx-0.2,jac,0.4,label='adjacent-day Jaccard (low=moving)',color='tab:orange')
    ax.bar(xx+0.2,ext,0.4,label='extreme bins frac (low=less perma)',color='tab:purple')
    ax.set_xticks(xx); ax.set_xticklabels(names,rotation=20,ha='right',fontsize=8); ax.legend(fontsize=8)
    ax.axhline(0.80,color='gray',ls='--',lw=0.6); ax.set_title('(4) movement & polarization',fontsize=10)
    plt.tight_layout(); plt.savefig(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_advect_0621.png',dpi=110)
    print('saved _wx_advect_0621.png')
