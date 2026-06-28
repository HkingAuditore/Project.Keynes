import csv, json, sys
from collections import defaultdict

sys.stdout = open(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wx_koppen_report.txt","w",encoding="utf-8")

PATH = r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260628_222157.csv"
NB = 12  # months

VEG = {0:"NONE",1:"POLAR_DESERT",2:"TUNDRA",3:"ALPINE_TUNDRA",4:"ALPINE_MEADOW",5:"TAIGA",
6:"BOREAL_SHRUB",7:"TEMP_DECIDUOUS",8:"TEMP_CONIFER",9:"TEMP_GRASSLAND",10:"TEMP_STEPPE",
11:"MEDIT_SHRUB",12:"SUBTROP_FOREST",13:"SAVANNA",14:"TROP_RAINFOREST",15:"TROP_DRY_FOREST",
16:"DESERT_SCRUB",17:"XERIC_DESERT",18:"OASIS",19:"MANGROVE",20:"SWAMP",21:"MARSH",
22:"KELP",23:"CORAL",24:"CLOUD_FOREST",25:"MONSOON_FOREST",26:"SEAGRASS",27:"PEAT_BOG"}

def f(x):
    try: return float(x)
    except: return 0.0
def ii(x):
    try: return int(float(x))
    except: return 0

# per land cell accumulators
T=defaultdict(lambda:[0.0]*NB)
P=defaultdict(lambda:[0.0]*NB)
N=defaultdict(lambda:[0]*NB)
meta={}   # cell -> [sum_moist, sum_lat, n, last_veg, last_elev, sum_x, sum_y]

rows=0
with open(PATH,"r",newline="") as fh:
    rdr=csv.reader(fh); h=next(rdr); ix={n:k for k,n in enumerate(h)}
    iC=ix["cell_index"]; iSP=ix["phys_daily_wind_season_phase"]; iW=ix["is_water_arr"]
    iT=ix["temp_arr"]; iP=ix["weather_precip_arr"]; iM=ix["moisture_arr"]
    iLat=ix["cell_lat_norm_arr"]; iV=ix["vegetation_arr"]; iE=ix["elevation_arr"]
    iX=ix["cell_pos_x_arr"]; iY=ix["cell_pos_y_arr"]
    for row in rdr:
        rows+=1
        if ii(row[iW])==1: continue  # land only
        sp=f(row[iSP])
        if sp<=0.0: continue
        c=ii(row[iC]); b=min(NB-1,int((sp%4.0)/4.0*NB))
        T[c][b]+=f(row[iT]); P[c][b]+=f(row[iP]); N[c][b]+=1
        m=meta.get(c)
        if m is None:
            meta[c]=[f(row[iM]),f(row[iLat]),1,ii(row[iV]),f(row[iE]),f(row[iX]),f(row[iY])]
        else:
            m[0]+=f(row[iM]); m[1]+=f(row[iLat]); m[2]+=1
            m[3]=ii(row[iV]); m[5]+=f(row[iX]); m[6]+=f(row[iY])

# ---- compute per-cell climate features ----
feats={}
for c in T:
    n=meta[c][2]
    tb=[T[c][b]/max(1,N[c][b]) for b in range(NB)]
    pb=[P[c][b]/max(1,N[c][b]) for b in range(NB)]
    Tmean=sum(tb)/NB; Twarm=max(tb); Tcold=min(tb); swing=Twarm-Tcold
    Ptot=sum(pb); Pmean=Ptot/NB
    med=sorted(tb)[NB//2]
    Pwarm=sum(pb[b] for b in range(NB) if tb[b]>=med)
    Pcold=Ptot-Pwarm
    summer_wet=Pwarm/Ptot if Ptot>1e-9 else 0.5
    Pdry=min(pb); Pwet=max(pb)
    moist=meta[c][0]/n; lat=meta[c][1]/n; veg=meta[c][3]; elev=meta[c][4]
    x=meta[c][5]/n; y=meta[c][6]/n
    feats[c]=dict(Tmean=Tmean,Twarm=Twarm,Tcold=Tcold,swing=swing,Ptot=Ptot,
        summer_wet=summer_wet,Pdry=Pdry,Pwet=Pwet,moist=moist,lat=lat,veg=veg,elev=elev,x=x,y=y)

# ---- percentile reference for calibrating cutoffs ----
def pct(vals,p):
    s=sorted(vals); return s[min(len(s)-1,int(p*len(s)))]
allT=[v["Tmean"] for v in feats.values()]
allP=[v["Ptot"] for v in feats.values()]
allM=[v["moist"] for v in feats.values()]
allSw=[v["swing"] for v in feats.values()]
print("LAND cells=%d" % len(feats))
print("Tmean   p10=%.3f p50=%.3f p90=%.3f"%(pct(allT,.1),pct(allT,.5),pct(allT,.9)))
print("Ptot    p10=%.4f p50=%.4f p90=%.4f"%(pct(allP,.1),pct(allP,.5),pct(allP,.9)))
print("moist   p10=%.3f p50=%.3f p90=%.3f"%(pct(allM,.1),pct(allM,.5),pct(allM,.9)))
print("swing   p10=%.3f p50=%.3f p90=%.3f"%(pct(allSw,.1),pct(allSw,.5),pct(allSw,.9)))

# aridity reference (relative): dry if Ptot below p33 AND moist below p40
P33=pct(allP,.33); M40=pct(allM,.40); M20=pct(allM,.20); P15=pct(allP,.15)

def classify(v):
    Tc=v["Tcold"]; Tw=v["Twarm"]; Tm=v["Tmean"]; sw=v["swing"]
    P=v["Ptot"]; swet=v["summer_wet"]; moist=v["moist"]; elev=v["elev"]
    # 0) highland override
    if elev>0.62 and Tm<0.45:
        return "高地/高山气候(H)"
    # 1) polar / subpolar by warm-season temp
    if Tw<0.12: return "冰原气候(EF)"
    if Tw<0.28: return "苔原气候(ET)"
    # 2) arid (relative)
    arid = (P<P33 and moist<M40)
    if arid:
        very = (P<P15 and moist<M20)
        if Tm>=0.45: return "热带沙漠(BWh)" if very else "热带草原性半干旱(BSh)"
        else:        return "温带沙漠(BWk)" if very else "温带草原性半干旱(BSk)"
    # 3) tropical (warm all year)
    if Tc>=0.48:
        if swet>=0.62 and v["Pdry"]<0.30*v["Pwet"]:
            return "热带季风/草原(Aw/Am)"
        return "热带雨林(Af)"
    # 4) warm-temperate / subtropical (mild winter, Tc>=0.30)
    #    Köppen 用「夏季温度」区分海洋性 Cfb 与亚热带湿润 Cfa（Cfb 夏凉、Cfa 夏热），
    #    而非用冬温：温和冬季 + 凉夏 + 低年较差 + 全年湿润 = 温带海洋性(Cfb)。
    if Tc>=0.30:
        if swet<=0.40: return "地中海气候(Csa)"            # 夏旱
        if swet>=0.62: return "亚热带季风/湿润(Cwa/Cfa)"   # 冬旱/夏雨
        if Tw<0.58 and sw<0.26: return "温带海洋性(Cfb)"   # 凉夏海洋性
        return "亚热带湿润(Cfa)"                            # 夏热湿润亚热带
    # 5) temperate (mild winter, Tc in [0.16,0.30))
    if Tc>=0.16 and Tw>=0.38:
        if swet<=0.40: return "地中海气候(Csb)"
        if swet>=0.60: return "温带季风(Dwa/Cwa)"
        if sw<0.26: return "温带海洋性(Cfb)"               # 凉夏海洋性
        return "温带大陆性湿润(Dfb)"
    # 6) cold / boreal (very cold winter, mild summer)
    if Tw>=0.34:
        if swet>=0.58: return "亚寒带季风(Dwc/Dwb)"
        return "亚寒带大陆性/泰加(Dfc)"
    return "苔原气候(ET)"

dist=defaultdict(int)
biome_x=defaultdict(lambda:defaultdict(int))
agg=defaultdict(lambda:[0,0.0,0.0,0.0,0.0,0.0,1e9,-1e9])  # type->[n,Tmean,swing,Ptot,swet,moist,latmin,latmax]
for c,v in feats.items():
    k=classify(v); dist[k]+=1
    biome_x[k][VEG.get(v["veg"],str(v["veg"]))]+=1
    g=agg[k]; g[0]+=1; g[1]+=v["Tmean"]; g[2]+=v["swing"]; g[3]+=v["Ptot"]
    g[4]+=v["summer_wet"]; g[5]+=v["moist"]; g[6]=min(g[6],v["lat"]); g[7]=max(g[7],v["lat"])

nland=len(feats)
print("\n=== KÖPPEN-LITE CLIMATE DISTRIBUTION (land cells) ===")
print(" type                          cells   %%land  Tmean swing Ptot   sum_wet moist  lat_range   topbiome")
for k in sorted(dist,key=lambda k:-dist[k]):
    g=agg[k]; n=g[0]
    tb=sorted(biome_x[k].items(),key=lambda kv:-kv[1])[:2]
    tbs=",".join("%s(%d)"%(bn,bc) for bn,bc in tb)
    print("  %-26s %5d  %5.1f%%  %.3f %.3f %.4f %.2f   %.3f  %.2f-%.2f  %s"%(
        k,n,100.0*n/nland,g[1]/n,g[2]/n,g[3]/n,g[4]/n,g[5]/n,g[6],g[7],tbs))

# ---- families + earth analogs + latitude-band composition (compact summary) ----
FAM = {
 "热带雨林(Af)":"tropical","热带季风/草原(Aw/Am)":"tropical",
 "热带草原性半干旱(BSh)":"arid","温带草原性半干旱(BSk)":"arid",
 "热带沙漠(BWh)":"arid","温带沙漠(BWk)":"arid",
 "亚热带季风/湿润(Cwa/Cfa)":"subtropical","亚热带湿润(Cfa)":"subtropical","地中海气候(Csa)":"subtropical",
 "温带海洋性(Cfb)":"temperate","温带季风(Dwa/Cwa)":"temperate","温带大陆性湿润(Dfb)":"temperate","地中海气候(Csb)":"temperate",
 "亚寒带大陆性/泰加(Dfc)":"boreal","亚寒带季风(Dwc/Dwb)":"boreal",
 "苔原气候(ET)":"polar","冰原气候(EF)":"polar","高地/高山气候(H)":"highland",
}
EARTH = {
 "热带雨林(Af)":"亚马逊/刚果/东南亚","热带季风/草原(Aw/Am)":"印度/非洲萨王纳/巴西高原",
 "热带草原性半干旱(BSh)":"萨赫勒/印度西北","温带草原性半干旱(BSk)":"中亚/北美大平原",
 "热带沙漠(BWh)":"撒哈拉/阿拉伯","温带沙漠(BWk)":"戈壁/大盆地",
 "亚热带季风/湿润(Cwa/Cfa)":"华南/美国东南/巴西南","亚热带湿润(Cfa)":"长江流域/美东南",
 "地中海气候(Csa)":"地中海沿岸/加州","地中海气候(Csb)":"葡萄牙/智利中部",
 "温带海洋性(Cfb)":"西欧/新西兰/太平洋西北","温带季风(Dwa/Cwa)":"华北/东北/朝鲜",
 "温带大陆性湿润(Dfb)":"东欧/美国中西部","亚寒带大陆性/泰加(Dfc)":"西伯利亚/加拿大",
 "亚寒带季风(Dwc/Dwb)":"东西伯利亚","苔原气候(ET)":"北极沿岸/冰岛",
 "冰原气候(EF)":"格陵兰/南极内陆","高地/高山气候(H)":"青藏高原/安第斯",
}
NLB=10
latband=[defaultdict(int) for _ in range(NLB)]  # band -> famkey -> count
for c,v in feats.items():
    fam=FAM.get(classify(v),"temperate")
    bi=min(NLB-1,int(v["lat"]*NLB)); latband[bi][fam]+=1

types_out=[]
for k in sorted(dist,key=lambda k:-dist[k]):
    g=agg[k]; n=g[0]
    types_out.append(dict(name=k,fam=FAM.get(k,"temperate"),earth=EARTH.get(k,""),
        count=n,pct=round(100.0*n/nland,1),tmean=round(g[1]/n,3),swing=round(g[2]/n,3),
        ptot=round(g[3]/n,4),swet=round(g[4]/n,2),moist=round(g[5]/n,3),
        latlo=round(g[6],2),lathi=round(g[7],2)))

# global land biome histogram (validate biome assignment)
bh=defaultdict(int)
for c,v in feats.items(): bh[VEG.get(v["veg"],str(v["veg"]))]+=1
print("\n=== GLOBAL LAND BIOME HISTOGRAM (game vegetation_arr) ===")
for bn,bc in sorted(bh.items(),key=lambda kv:-kv[1]):
    print("  %-18s %5d  %5.1f%%"%(bn,bc,100.0*bc/nland))

# compact summary for canvas
biomes_out=[dict(name=bn,count=bc,pct=round(100.0*bc/nland,1))
            for bn,bc in sorted(bh.items(),key=lambda kv:-kv[1])[:12]]
latband_out=[]
for bi in range(NLB):
    d2=dict(latband[bi]); tot=sum(d2.values())
    latband_out.append(dict(lo=round(bi/NLB,1),hi=round((bi+1)/NLB,1),total=tot,fam=d2))
summ=dict(
    nland=nland, n_types=len(dist),
    cfb=dist.get("温带海洋性(Cfb)",0),
    medit_biome_pct=round(100.0*bh.get("MEDIT_SHRUB",0)/nland,1),
    rainforest_biome_pct=round(100.0*bh.get("TROP_RAINFOREST",0)/nland,1),
    summer_wet_median=round(sorted(v["summer_wet"] for v in feats.values())[len(feats)//2],2),
)
summary_json=dict(types=types_out,biomes=biomes_out,latbands=latband_out,summary=summ)
with open(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wx_koppen_summary.json","w",encoding="utf-8") as fo:
    json.dump(summary_json,fo,ensure_ascii=False,indent=1)
print("\nexported summary -> tmp/wx_koppen_summary.json (types=%d biomes=%d latbands=%d)"%(
    len(types_out),len(biomes_out),len(latband_out)))
