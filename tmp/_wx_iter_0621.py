import numpy as np, time, sys, json
from numba import njit

NPZ=r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_fields_0621.npz'

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

@njit(cache=True)
def simulate(ND,NC,NB,px,py,hex_size,advect_steps,
             terrain,elev,base_m,veg,soil,vita,has_river,river_q30,sea_ice,
             dy_temp,dy_air,dy_TA,dy_wx,dy_wy,dy_wspd,
             init_vapor,init_cw,init_precip,init_cnv,
             ocean_evap_gain,land_evap_gain,lake_evap_scale,vapor_transport_gain,
             vapor_anchor,diffusion,condensation_gain,oro_lift_gain,oro_lift_cap,
             convergence_gain,frontogenesis_gain,rain_shadow_drying,rh_threshold,
             ocean_precip_suppression,vapor_precip_sink,precip_inertia,vapor_relax_rate,
             wet_terrain_damp,lake_precip_damp,extreme_soft_cap,extreme_softness,
             cw_retain,cw_local_src,cw_advect_k,cw_humid,cw_lift,
             mlow_count,mlow_amp,mlow_sigma,mlow_period,mlow_gain,world_seed,
             pxn,pyn,
             out_precip,out_cw,out_cloud,out_vapor):
    vapor=init_vapor.copy(); cw=init_cw.copy(); precip=init_precip.copy(); cnv=init_cnv.copy()
    nv=np.empty(NC); ncw=np.empty(NC); npre=np.empty(NC); ncnv=np.empty(NC); ncld=np.empty(NC)
    mlow_inv2s2=1.0/(2.0*mlow_sigma*mlow_sigma)
    mcx=np.empty(8); mcy=np.empty(8)
    for d in range(ND):
        T=dy_temp[d]; AIR=dy_air[d]; TA=dy_TA[d]; WX=dy_wx[d]; WY=dy_wy[d]; WSPD=dy_wspd[d]
        # mobile low centers for this day (synthetic convergence forcing, optional)
        nml=0
        if mlow_gain>0.0 and mlow_amp>0.0:
            nml=int(mlow_count)
            if nml>8: nml=8
            for j in range(nml):
                h=(np.uint32(world_seed)*np.uint32(2654435761)+np.uint32(j)*np.uint32(40503)+np.uint32(1013904223))
                h=h^(h>>np.uint32(16)); h=h*np.uint32(2246822519); h=h^(h>>np.uint32(13))
                hx=float(h & np.uint32(0xFFFF))/65535.0
                hy=float((h>>np.uint32(16)) & np.uint32(0xFFFF))/65535.0
                cx=hx+float(d)/mlow_period
                cx=cx-np.floor(cx)
                base_y=0.22+0.56*hy
                wob=0.05*np.sin(float(d)*0.045+float(j)*1.7)
                cy=base_y+wob
                if cy<0.04: cy=0.04
                elif cy>0.96: cy=0.96
                mcx[j]=cx; mcy[j]=cy
        # ---- per cell ----
        for i in range(NC):
            temp=T[i]+AIR[i]
            if temp<0.0: temp=0.0
            elif temp>1.0: temp=1.0
            bm=base_m[i]
            if bm<0.0: bm=0.0
            elif bm>1.0: bm=1.0
            cap=0.18+0.82*temp-0.18*elev[i]
            if cap<0.14: cap=0.14
            elif cap>1.0: cap=1.0
            # ocean_an
            if _is_water(terrain[i]):
                ocean_an=TA[i]
            else:
                s=0.0; nw=0
                for d2 in range(6):
                    nb=NB[i,d2]
                    if nb<0: continue
                    if _is_water(terrain[nb]):
                        s+=TA[nb]; nw+=1
                ocean_an=s/nw if nw>0 else 0.0
            on_water=_is_water(terrain[i])
            wx=WX[i]; wy=WY[i]
            wl2=wx*wx+wy*wy
            if wl2<0.0001:
                wdx=1.0; wdy=0.0
            else:
                inv=1.0/np.sqrt(wl2); wdx=wx*inv; wdy=wy*inv
            wspd=WSPD[i]
            if wspd<=0.0001:
                wind_len=np.sqrt(wl2) if wl2>0.0001 else 0.0
            else:
                wind_len=wspd
            up=_aligned(i,-wdx,-wdy,px,py,NB,hex_size) if advect_steps>0 else -1
            # advected vapor chain
            if up<0 or advect_steps<=0:
                advected=vapor[i]
            else:
                sv=vapor[up]; w=1.0; wd=0.75; cur=up
                for st in range(1,advect_steps):
                    nx=_aligned(cur,-wdx,-wdy,px,py,NB,hex_size)
                    if nx<0: break
                    sv+=vapor[nx]*wd; w+=wd; wd*=0.75; cur=nx
                advected=sv/w
            # neighbor avg vapor
            s=vapor[i]; n=1
            for d2 in range(6):
                nb=NB[i,d2]
                if nb<0: continue
                s+=vapor[nb]; n+=1
            neighbor_vapor=s/n
            wind_mag=wind_len/1.2
            if wind_mag<0.0: wind_mag=0.0
            elif wind_mag>1.0: wind_mag=1.0
            advect_w=0.65+wind_mag*0.30
            if advect_w<0.65: advect_w=0.65
            elif advect_w>0.95: advect_w=0.95
            is_lake=(terrain[i]==18)
            hriv=(not is_lake) and (has_river[i]!=0) and (not on_water)
            rflow=0.0
            if hriv:
                rflow=river_q30[i]
                if rflow<0.0: rflow=0.0
                elif rflow>1.0: rflow=1.0
            river_evap_floor=0.0
            if hriv:
                river_evap_floor=0.08 if 0.08>rflow*0.22 else rflow*0.22
            if is_lake:
                advect_w*=0.5
                if advect_w<0.20: advect_w=0.20
                elif advect_w>0.50: advect_w=0.50
            elif hriv:
                advect_w*=(0.88-rflow*0.10)
                if advect_w<0.55: advect_w=0.55
                elif advect_w>0.85: advect_w=0.85
            eff_an=ocean_an
            if is_lake: eff_an=0.20
            elif hriv:
                eff_an=ocean_an if ocean_an>river_evap_floor else river_evap_floor
            src_local=_surface_src(i,temp,bm,wind_mag,eff_an,on_water,is_lake,hriv,rflow,
                                   terrain,veg,soil,vita,sea_ice,ocean_evap_gain,land_evap_gain,lake_evap_scale)
            src_up=src_local
            if up>=0:
                ut=T[up]+AIR[up]
                if ut<0.0: ut=0.0
                elif ut>1.0: ut=1.0
                ubm=base_m[up]
                if ubm<0.0: ubm=0.0
                elif ubm>1.0: ubm=1.0
                u_on=_is_water(terrain[up]); u_lake=(terrain[up]==18)
                u_riv=(not u_lake) and (has_river[up]!=0) and (not u_on)
                urq=0.0
                if u_riv:
                    urq=river_q30[up]
                    if urq<0.0: urq=0.0
                    elif urq>1.0: urq=1.0
                u_an=TA[up] if u_on else eff_an
                src_up=_surface_src(up,ut,ubm,wind_mag,u_an,u_on,u_lake,u_riv,urq,
                                    terrain,veg,soil,vita,sea_ice,ocean_evap_gain,land_evap_gain,lake_evap_scale)
            vapor_memory=vapor[i]+(bm-vapor[i])*vapor_anchor
            transport_target=advected+src_up*(0.60+wind_mag*0.65)
            base_part=vapor_memory+src_local*0.35
            vp=base_part+(transport_target-base_part)*(advect_w*vapor_transport_gain)
            vp=vp+(neighbor_vapor-vp)*diffusion
            satdef=(cap-vp)/(cap if cap>0.001 else 0.001)
            if satdef<0.0: satdef=0.0
            elif satdef>1.0: satdef=1.0
            vp+=src_local*(0.30+satdef*0.70)
            if vp<0.0: vp=0.0
            elif vp>cap: vp=cap
            # orographic lift
            lift=0.0
            if up>=0:
                diff=elev[i]-elev[up]
                if diff>0.02:
                    lift=diff*2.2
                    if lift>1.0: lift=1.0
                elif diff<-0.02:
                    lift=diff*1.6
                    if lift<-1.0: lift=-1.0
            # convergence (refresh each day from wind)
            sx=px[i]; sy=py[i]; incoming=0.0; checked=0
            for d2 in range(6):
                nb=NB[i,d2]
                if nb<0: continue
                ddx=sx-px[nb]; ddy=sy-py[nb]; dl2=ddx*ddx+ddy*ddy
                if dl2<=0.0001: continue
                nwx=WX[nb]; nwy=WY[nb]; nwl2=nwx*nwx+nwy*nwy
                if nwl2<=0.0001: continue
                invd=1.0/np.sqrt(dl2); invw=1.0/np.sqrt(nwl2)
                cosin=(ddx*nwx+ddy*nwy)*(invd*invw)
                if cosin<0.0: cosin=0.0
                nsp=WSPD[nb]
                if nsp<=0.0001: nsp=np.sqrt(nwl2)
                spw=nsp/1.2
                if spw<0.20: spw=0.20
                elif spw>1.25: spw=1.25
                incoming+=cosin*spw; checked+=1
            convergence=incoming/checked if checked>0 else 0.0
            if convergence<0.0: convergence=0.0
            elif convergence>1.0: convergence=1.0
            # synthetic mobile-low convergence forcing (experiment C)
            if nml>0:
                boost=0.0
                pm=pxn[i]; pmy=pyn[i]
                for j in range(nml):
                    dxm=pm-mcx[j]
                    if dxm>0.5: dxm-=1.0
                    elif dxm<-0.5: dxm+=1.0
                    dym=pmy-mcy[j]
                    r2=dxm*dxm+dym*dym
                    boost+=np.exp(-r2*mlow_inv2s2)
                if boost>1.0: boost=1.0
                convergence+=mlow_gain*boost
                if convergence>1.0: convergence=1.0
            if lift<0.0:
                vp+=lift*rain_shadow_drying*0.42
                if vp<0.0: vp=0.0
                elif vp>cap: vp=cap
            # temp gradient
            tmin=temp; tmax=temp
            for d2 in range(6):
                nb=NB[i,d2]
                if nb<0: continue
                nt=T[nb]+AIR[nb]
                if nt<0.0: nt=0.0
                elif nt>1.0: nt=1.0
                if nt<tmin: tmin=nt
                if nt>tmax: tmax=nt
            tgrad=tmax-tmin
            fronto=convergence*_smoothstep(0.05,0.24,tgrad)*frontogenesis_gain
            if fronto<0.0: fronto=0.0
            elif fronto>1.0: fronto=1.0
            rh=vp/(cap if cap>0.001 else 0.001)
            if rh<0.0: rh=0.0
            elif rh>1.0: rh=1.0
            rh_hi=rh_threshold+0.18
            if rh_hi>0.99: rh_hi=0.99
            condense_gate=_smoothstep(rh_threshold,rh_hi,rh)
            humid_excess=rh-rh_threshold
            if humid_excess<0.0: humid_excess=0.0
            lift_pos=lift if lift>0.0 else 0.0
            lift_gate=(rh-0.45)/0.45
            if lift_gate<0.0: lift_gate=0.0
            elif lift_gate>1.0: lift_gate=1.0
            lift_supply=lift_pos*lift_gate
            if lift_supply>oro_lift_cap: lift_supply=oro_lift_cap
            eoa=eff_an if eff_an>0.0 else 0.0
            cloud_source=condense_gate*condensation_gain+lift_supply*oro_lift_gain+convergence*convergence_gain*0.55+fronto+eoa*0.05
            if cloud_source<0.0: cloud_source=0.0
            elif cloud_source>1.0: cloud_source=1.0
            cwv=cw[i]
            if up>=0:
                cwv=cwv+(cw[up]-cwv)*(wind_mag*cw_advect_k)
            cwv=cwv*cw_retain+cloud_source*cw_local_src+humid_excess*cw_humid+lift_supply*cw_lift
            if cwv<0.0: cwv=0.0
            elif cwv>1.0: cwv=1.0
            cloud=cloud_source*0.62+cwv*0.70
            if cloud<0.0: cloud=0.0
            elif cloud>1.0: cloud=1.0
            cfw=cwv*0.75
            if cloud<cfw: cloud=cfw
            if cloud>1.0: cloud=1.0
            instab=(temp-0.48)*1.05+rh*0.38+cloud*0.35+convergence*convergence_gain*0.75+lift_supply*oro_lift_gain+fronto*0.45+eoa*0.18
            if instab<0.0: instab=0.0
            elif instab>1.0: instab=1.0
            trig=condense_gate
            lt=lift_supply*1.6
            if trig<lt: trig=lt
            if trig<fronto: trig=fronto
            rain_focus=trig*rh
            if rain_focus<0.0: rain_focus=0.0
            elif rain_focus>1.0: rain_focus=1.0
            precip_raw=(cwv*(0.18+instab*0.42)+lift_supply*0.20+fronto*0.12)*rain_focus
            if lift<0.0:
                shadow=(-lift)*rain_shadow_drying
                if shadow>0.85: shadow=0.85
                precip_raw*=(1.0-shadow)
            cwr=0.0
            if rain_focus>0.08 and instab>0.08:
                cwr=cwv*rain_focus*(0.08+instab*0.12)
            ptgt=precip_raw if precip_raw>cwr else cwr
            if ptgt<0.0: ptgt=0.0
            elif ptgt>1.0: ptgt=1.0
            if on_water:
                da=ocean_an/0.16
                if da<0.0: da=0.0
                elif da>1.0: da=1.0
                din=(instab-0.90)/0.10
                if din<0.0: din=0.0
                elif din>1.0: din=1.0
                dcv=(convergence-0.38)/0.16
                if dcv<0.0: dcv=0.0
                elif dcv>1.0: dcv=1.0
                dfr=fronto/0.16
                if dfr<0.0: dfr=0.0
                elif dfr>1.0: dfr=1.0
                odrive=da
                if din>odrive: odrive=din
                if dcv>odrive: odrive=dcv
                if dfr>odrive: odrive=dfr
                supp=ocean_precip_suppression
                if is_lake and supp>0.78: supp=0.78
                olo=1.0-supp
                ptgt*=olo+(1.0-olo)*odrive
            # precip stability (terrain damp + soft cap)
            out=ptgt
            if out<0.0: out=0.0
            elif out>1.0: out=1.0
            fac=_terr_damp(terrain[i])
            if fac>0.0 and out>0.08:
                damp=lake_precip_damp if terrain[i]==18 else wet_terrain_damp
                if damp<0.0: damp=0.0
                elif damp>1.0: damp=1.0
                out-=(out-0.08)*damp*fac
            if extreme_soft_cap>0.0 and out>extreme_soft_cap:
                out=extreme_soft_cap+(out-extreme_soft_cap)*extreme_softness
            if out<0.0: out=0.0
            elif out>1.0: out=1.0
            ptgt=out
            pr=precip[i]+(ptgt-precip[i])*precip_inertia
            if pr<0.003: pr=0.0
            cwv-=pr*0.22
            if cwv<0.0: cwv=0.0
            vap_after=vp-pr*vapor_precip_sink
            if vap_after<0.0: vap_after=0.0
            if pr<0.005 and cloud<0.12 and vapor_relax_rate>0.0:
                vap_after=vap_after+(bm-vap_after)*vapor_relax_rate
            nv[i]=vap_after; ncw[i]=cwv; npre[i]=pr; ncnv[i]=convergence; ncld[i]=cloud
        for i in range(NC):
            vapor[i]=nv[i]; cw[i]=ncw[i]; precip[i]=npre[i]; cnv[i]=ncnv[i]
        out_precip[d]=precip; out_cw[d]=cw; out_cloud[d]=ncld; out_vapor[d]=vapor


def load():
    z=np.load(NPZ,allow_pickle=True)
    return z

def metrics(precip, px, py, iw, warm=40, wet_th=0.02):
    ND,NC=precip.shape
    P=precip[warm:]
    wet=(P>wet_th).mean(0)
    perma_rain=(wet>0.80).mean()
    perma_dry=(wet<0.05).mean()
    # U-shape: fraction in extreme bins
    extreme=((wet<0.1)|(wet>0.9)).mean()
    # adjacent-day jaccard
    js=[]
    for d in range(1,P.shape[0]):
        a=P[d-1]>wet_th; b=P[d]>wet_th
        u=(a|b).sum()
        if u>0: js.append((a&b).sum()/u)
    jacc=float(np.mean(js)) if js else 1.0
    # hovmoller time/lon var
    LB=24
    pxn=(px-px.min())/max(px.max()-px.min(),1e-9)
    lonb=np.clip((pxn*LB).astype(int),0,LB-1)
    hov=np.zeros((P.shape[0],LB))
    for b in range(LB):
        m=lonb==b
        if m.any(): hov[:,b]=P[:,m].mean(1)
    tvar=hov.var(0).mean(); lvar=hov.var(1).mean()
    return dict(perma_rain=float(perma_rain),perma_dry=float(perma_dry),extreme_bins=float(extreme),
                jaccard=jacc,hov_time_over_lon=float(tvar/max(lvar,1e-9)),
                mean_wet_ratio=float(wet.mean()),mean_precip=float(P.mean()))

if __name__=='__main__':
    z=load()
    ND=int(z['ND']); NC=int(z['NC']); NB=z['NB']; px=z['px'].astype(np.float64); py=z['py'].astype(np.float64)
    hex_size=float(z['hex_size'])
    g=lambda k: np.nan_to_num(z['st_'+k].astype(np.float64))
    terrain=z['st_terrain_arr'].astype(np.int64)
    elev=g('elevation_arr'); base_m=g('moisture_arr'); veg=z['st_vegetation_arr'].astype(np.int64)
    soil=g('soil_moisture_arr'); vita=g('vegetation_vitality_arr')
    has_river=z['st_has_river_arr'].astype(np.int64); river_q30=g('river_discharge_30d_arr')
    sea_ice=g('sea_ice_frac_arr'); iw=z['st_is_water_arr'].astype(np.int64)
    d=lambda k: np.nan_to_num(z['dy_'+k].astype(np.float64))
    # temp_arr 是合成后的最终 cell_temp(已含 air_anom)，作为 weather 看到的温度；air 置 0 避免重复计入。
    dy_temp=d('temp_arr'); dy_air=np.zeros_like(dy_temp); dy_TA=d('temperature_transport_anomaly_arr')
    dy_wx=d('wind_x_arr'); dy_wy=d('wind_y_arr'); dy_wspd=d('wind_speed_arr')
    ref_precip=d('weather_precip_arr')
    init_vapor=d('weather_vapor_arr')[0].copy(); init_cw=d('weather_cloud_water_arr')[0].copy()
    init_precip=d('weather_precip_arr')[0].copy(); init_cnv=d('weather_convergence_arr')[0].copy()
    pxn=(px-px.min())/max(px.max()-px.min(),1e-9)
    advect_steps=4

    # ---- knob sets ----
    OLD=dict(ocean_evap_gain=0.45,land_evap_gain=0.85,lake_evap_scale=0.35,vapor_transport_gain=0.75,
             vapor_anchor=0.18,diffusion=0.04,condensation_gain=0.30,oro_lift_gain=0.22,oro_lift_cap=0.35,
             convergence_gain=0.18,frontogenesis_gain=0.42,rain_shadow_drying=0.35,rh_threshold=0.70,
             ocean_precip_suppression=0.95,vapor_precip_sink=0.85,precip_inertia=0.30,vapor_relax_rate=0.08,
             wet_terrain_damp=0.60,lake_precip_damp=0.65,extreme_soft_cap=0.16,extreme_softness=0.20,
             cw_retain=0.62,cw_local_src=0.48,cw_advect_k=0.70,cw_humid=0.22,cw_lift=0.14,
             mlow_count=3,mlow_amp=0.0,mlow_sigma=0.16,mlow_period=38.0,mlow_gain=0.0,world_seed=10086)
    # A: cloud-water 平流主导(保留久/平流强/本地再生弱)
    A=dict(cw_retain=0.86,cw_local_src=0.20,cw_advect_k=0.95,cw_humid=0.14,cw_lift=0.10)
    # B: 解锚 vapor + 配套强化海洋源/平流(避免 19a 单独去锚变干)
    B=dict(vapor_anchor=0.06,vapor_transport_gain=0.90,ocean_evap_gain=0.62,land_evap_gain=0.95,
           rh_threshold=0.66,vapor_relax_rate=0.05)
    # C: 移动低压合成辐合强迫(已修正为二维高斯,带纬度结构)
    C=dict(mlow_gain=0.30,mlow_amp=0.10)
    # D: 综合方案 = B(解锚+配套源) + A(云水平流主导) + 削弱地形静态强迫 + 强化瞬变(辐合/锋生) + 真正移动的低压
    D=dict(vapor_anchor=0.05,vapor_transport_gain=0.92,ocean_evap_gain=0.62,land_evap_gain=0.95,
           rh_threshold=0.66,vapor_relax_rate=0.04,
           oro_lift_gain=0.12,oro_lift_cap=0.24,rain_shadow_drying=0.24,
           convergence_gain=0.34,frontogenesis_gain=0.50,
           cw_retain=0.85,cw_local_src=0.20,cw_advect_k=0.95,cw_humid=0.14,cw_lift=0.08,
           mlow_count=4,mlow_amp=0.12,mlow_sigma=0.14,mlow_period=30.0,mlow_gain=0.45)

    order=['ocean_evap_gain','land_evap_gain','lake_evap_scale','vapor_transport_gain',
           'vapor_anchor','diffusion','condensation_gain','oro_lift_gain','oro_lift_cap',
           'convergence_gain','frontogenesis_gain','rain_shadow_drying','rh_threshold',
           'ocean_precip_suppression','vapor_precip_sink','precip_inertia','vapor_relax_rate',
           'wet_terrain_damp','lake_precip_damp','extreme_soft_cap','extreme_softness',
           'cw_retain','cw_local_src','cw_advect_k','cw_humid','cw_lift',
           'mlow_count','mlow_amp','mlow_sigma','mlow_period','mlow_gain','world_seed']

    pyn=(py-py.min())/max(py.max()-py.min(),1e-9)
    west_wx=np.ones((ND,NC)); west_wy=np.zeros((ND,NC)); west_wspd=np.full((ND,NC),1.2)

    def run(wind, *overrides):
        k=dict(OLD)
        for o in overrides: k.update(o)
        args=[k[n] for n in order]
        wx,wy,ws=(dy_wx,dy_wy,dy_wspd) if wind=='csv' else (west_wx,west_wy,west_wspd)
        op=np.zeros((ND,NC)); oc=np.zeros((ND,NC)); ocl=np.zeros((ND,NC)); ov=np.zeros((ND,NC))
        simulate(ND,NC,NB,px,py,hex_size,advect_steps,
                 terrain,elev,base_m,veg,soil,vita,has_river,river_q30,sea_ice,
                 dy_temp,dy_air,dy_TA,wx,wy,ws,
                 init_vapor,init_cw,init_precip,init_cnv,
                 *args, pxn,pyn, op,oc,ocl,ov)
        return op,ocl

    def hovm(P,warm=40,LB=24):
        Pw=P[warm:]
        pxnn=(px-px.min())/max(px.max()-px.min(),1e-9)
        lonb=np.clip((pxnn*LB).astype(int),0,LB-1)
        H=np.zeros((Pw.shape[0],LB))
        for b in range(LB):
            m=lonb==b
            if m.any(): H[:,b]=Pw[:,m].mean(1)
        return H

    exps={}
    t0=time.time()
    exps['csv_OLD']=run('csv')
    exps['csv_D']=run('csv',D)
    exps['west_OLD']=run('westerly')
    exps['west_D']=run('westerly',D)
    print(f'[sim x4] {time.time()-t0:.1f}s')

    m_ref=metrics(ref_precip,px,py,iw)
    rows=[('CSV_recorded',m_ref)]
    for k,(P,_) in exps.items():
        rows.append((k,metrics(P,px,py,iw)))
    keys=['perma_rain','perma_dry','extreme_bins','jaccard','hov_time_over_lon','mean_wet_ratio','mean_precip']
    print(f"\n{'experiment':16s} "+" ".join(f"{x[:11]:>11s}" for x in keys))
    for name,mm in rows:
        print(f"{name:16s} "+" ".join(f"{mm[x]:11.3f}" for x in keys))

    # ---- plot ----
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    fig=plt.figure(figsize=(16,10))
    H_wold=hovm(exps['west_OLD'][0]); H_wD=hovm(exps['west_D'][0])
    vmax=max(np.percentile(H_wold[H_wold>0],95) if (H_wold>0).any() else 0.05,
             np.percentile(H_wD[H_wD>0],95) if (H_wD>0).any() else 0.05)
    ax=fig.add_subplot(2,2,1); im=ax.imshow(H_wold,aspect='auto',origin='lower',cmap='viridis',vmax=vmax,extent=[0,24,0,H_wold.shape[0]])
    ax.set_title('(1) STEADY WEST WIND + OLD\nVERTICAL stripes = rain pinned by terrain (no movement)',fontsize=10)
    ax.set_xlabel('lon band (west->east)'); ax.set_ylabel('day'); plt.colorbar(im,ax=ax)
    ax=fig.add_subplot(2,2,2); im=ax.imshow(H_wD,aspect='auto',origin='lower',cmap='viridis',vmax=vmax,extent=[0,24,0,H_wD.shape[0]])
    ax.set_title('(2) STEADY WEST WIND + NEW(D)\nDIAGONAL/drifting bands = rain systems MOVE east',fontsize=10)
    ax.set_xlabel('lon band (west->east)'); ax.set_ylabel('day'); plt.colorbar(im,ax=ax)
    ax=fig.add_subplot(2,2,3)
    wr_old=(exps['csv_OLD'][0][40:]>0.02).mean(0); wr_d=(exps['csv_D'][0][40:]>0.02).mean(0); wr_ref=(ref_precip[40:]>0.02).mean(0)
    ax.hist(wr_ref,bins=20,alpha=0.4,label='CSV recorded',color='tab:gray')
    ax.hist(wr_old,bins=20,alpha=0.5,label='iter OLD',color='tab:red')
    ax.hist(wr_d,bins=20,alpha=0.5,label='iter NEW(D)',color='tab:green')
    ax.set_title('(3) per-cell rain frequency (CSV wind)\nless piled at 0/1 = fewer perma-rain/perma-dry',fontsize=10)
    ax.set_xlabel('wet-day ratio'); ax.set_ylabel('cells'); ax.legend()
    ax=fig.add_subplot(2,2,4)
    names=[r[0] for r in rows]; jac=[r[1]['jaccard'] for r in rows]; ext=[r[1]['extreme_bins'] for r in rows]
    xx=np.arange(len(names)); ax.bar(xx-0.2,jac,0.4,label='adjacent-day Jaccard (low=moving)',color='tab:orange')
    ax.bar(xx+0.2,ext,0.4,label='extreme bins frac (low=less perma)',color='tab:purple')
    ax.set_xticks(xx); ax.set_xticklabels(names,rotation=30,ha='right',fontsize=8); ax.legend(fontsize=8)
    ax.set_title('(4) movement & polarization metrics',fontsize=10)
    plt.tight_layout(); plt.savefig(r'd:/Godot/ProjectKeynes/Project.Keynes/tmp/_wx_compare_0621.png',dpi=110)
    print('saved _wx_compare_0621.png')
