#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import pickle, numpy as np
d = pickle.load(open('d:/Godot/ProjectKeynes/Project.Keynes/tmp/_agg.pkl','rb'))

def line(t=""): print(t)

ticks = d['ticks']
line("="*72)
line(f"数据规模: {d['n_rows']} 行 | {len(ticks)} ticks | 范围 {ticks[0]}~{ticks[-1]}")
line(f"估计 cell 数 ≈ {d['n_rows']//len(ticks)}")
line("="*72)

# ---------- 1. 温度时间平滑性 ----------
line("\n【1. 温度时间平滑性（同cell temp vs prev）】")
line(f"  跳变次数 (|Δ|>0.1): {d['jump_count']}  占比≈{d['jump_count']/d['n_rows']*100:.3f}%")
line(f"  最大单步跳变: {d['max_jump']:.4f}")
if d['max_jump'] > 0.3:
    line("  [警告] 仍存在大跳变 (>0.3)，时间不够平滑")
elif d['max_jump'] > 0.15:
    line("  [注意] 存在中等跳变 (>0.15)")
else:
    line("  [OK] 温度变化平滑")

# ---------- 2. 南北半球季节反相 + 太阳轨迹 ----------
line("\n【2. 太阳轨迹 / 南北半球季节反相】")
ta = d['tick_agg']
tk_sorted = sorted(ta.keys())
def series(key):
    return np.array([np.nanmean(ta[tk][key]) for tk in tk_sorted])
n_temp = series('n_temp'); s_temp = series('s_temp'); eq_temp = series('eq_temp')
insol_n = series('insol_n'); insol_s = series('insol_s')
daylen_n = series('daylen_n'); daylen_s = series('daylen_s')
soff_n = series('season_off_n'); soff_s = series('season_off_s')

# 季节反相检验：北/南半球温度的相关性应为负
corr_ns = np.corrcoef(n_temp, s_temp)[0,1]
line(f"  北半球温度范围: [{n_temp.min():.3f}, {n_temp.max():.3f}] 振幅={n_temp.max()-n_temp.min():.3f}")
line(f"  南半球温度范围: [{s_temp.min():.3f}, {s_temp.max():.3f}] 振幅={s_temp.max()-s_temp.min():.3f}")
line(f"  赤道温度范围:   [{eq_temp.min():.3f}, {eq_temp.max():.3f}] 振幅={eq_temp.max()-eq_temp.min():.3f}")
line(f"  南北半球温度相关系数: {corr_ns:.3f}  (理想<0 表示季节反相)")
if corr_ns < -0.3:
    line("  [OK] 南北半球季节明显反相 -> 太阳直射点南北移动正确")
elif corr_ns < 0.1:
    line("  [注意] 反相较弱")
else:
    line("  [警告] 南北半球温度同相，季节系统可能未驱动半球差异")

# 季节偏移反相
corr_soff = np.corrcoef(soff_n, soff_s)[0,1]
line(f"  季节偏移 N vs S 相关: {corr_soff:.3f} (理想<0)")
line(f"  insolation N范围[{insol_n.min():.3f},{insol_n.max():.3f}] S范围[{insol_s.min():.3f},{insol_s.max():.3f}]")
line(f"  day_length N范围[{daylen_n.min():.3f},{daylen_n.max():.3f}] S范围[{daylen_s.min():.3f},{daylen_s.max():.3f}]")
corr_daylen = np.corrcoef(daylen_n, daylen_s)[0,1]
line(f"  day_length N vs S 相关: {corr_daylen:.3f} (理想<0: 北半球白昼长时南半球短)")

# 估计季节周期（用北半球温度自相关找周期）
nt = n_temp - n_temp.mean()
ac = np.correlate(nt, nt, 'full')[len(nt)-1:]
ac = ac/ac[0]
# 找第一个峰
peak = None
for i in range(5, len(ac)-1):
    if ac[i]>ac[i-1] and ac[i]>ac[i+1] and ac[i]>0.2:
        peak=i; break
line(f"  季节周期估计(自相关首峰): {peak} ticks" if peak else "  季节周期: 未检出明显周期")

# ---------- 3. 气温-纬度分布 ----------
line("\n【3. 气温-纬度分布（赤道热/两极冷）】")
lt = np.array(d['lat_temp'], dtype=float)  # lat, temp, is_water, elev
lat=lt[:,0]; tmp=lt[:,1]
# 分纬度带平均温度
bins = np.linspace(0,1,11)
line("  纬度带 -> 平均温度:")
for i in range(10):
    m=(lat>=bins[i])&(lat<bins[i+1])
    if m.sum()>0:
        line(f"    lat[{bins[i]:.1f},{bins[i+1]:.1f}) n={m.sum():4d}  T̄={tmp[m].mean():.3f}")
# 赤道(0.5)应最热，两极(0,1)最冷
eq_m=(lat>=0.45)&(lat<=0.55); pole_m=(lat<0.1)|(lat>0.9)
line(f"  赤道带T̄={tmp[eq_m].mean():.3f} vs 极地带T̄={tmp[pole_m].mean():.3f}")
if tmp[eq_m].mean() > tmp[pole_m].mean()+0.1:
    line("  [OK] 赤道明显比极地暖，纬度温度梯度正确")
else:
    line("  [警告] 赤道-极地温差不足")

# ---------- 4. 海冰 ----------
line("\n【4. 海冰物理合理性】")
ir=np.array(d['ice_rows'],dtype=float)  # lat, temp, ice
if len(ir)>0:
    icelat=ir[:,0]; icetemp=ir[:,1]; icefrac=ir[:,2]
    line(f"  海冰覆盖率范围[{icefrac.min():.3f},{icefrac.max():.3f}] 均值{icefrac.mean():.3f}")
    has_ice=icefrac>0.05
    if has_ice.sum()>0:
        line(f"  有海冰格子: {has_ice.sum()} | 其纬度均值={np.abs(icelat[has_ice]-0.5).mean()*2:.3f}(0赤道,1极)")
        line(f"  有海冰格子温度均值={icetemp[has_ice].mean():.3f} (应偏冷)")
        # 海冰与温度负相关
        c=np.corrcoef(icetemp,icefrac)[0,1]
        line(f"  海冰-温度相关: {c:.3f} (理想<0)")
        if c<-0.3: line("  [OK] 海冰随低温形成，分布在高纬")
        else: line("  [注意] 海冰-温度相关弱")
    else:
        line("  [警告] 几乎无海冰")

# ---------- 5. 降水 ----------
line("\n【5. 降水分布】")
pv=np.array(d['precip_vals'])
line(f"  降水范围[{pv.min():.3f},{pv.max():.3f}] 均值{pv.mean():.3f}")
line(f"  无降水格子占比: {(pv<0.02).mean()*100:.1f}%  | 持续高降水(>0.5)占比: {(pv>0.5).mean()*100:.1f}%")
if (pv>0.5).mean() > 0.3:
    line("  [警告] 高降水占比过大，可能降水滞留")
else:
    line("  [OK] 降水分布合理")

# ---------- 6. 植被 ----------
line("\n【6. 植被活力分布】")
vv=np.array(d['veg_vit'])
line(f"  活力范围[{vv.min():.3f},{vv.max():.3f}] 均值{vv.mean():.3f}")
line(f"  低活力(<0.25)占比: {(vv<0.25).mean()*100:.1f}%  | 健康(>0.6)占比: {(vv>0.6).mean()*100:.1f}%")
if (vv<0.25).mean()>0.4:
    line("  [警告] 大量植被濒死")
elif vv.mean()>0.45:
    line("  [OK] 植被整体健康")
else:
    line("  [注意] 植被偏弱")

# ---------- 7. 地形/海拔 -> 雪盖、温度 ----------
line("\n【7. 地形/海拔影响】")
es=np.array(d['elev_snow'],dtype=float)  # elev, snow, temp, lat
elev=es[:,0]; snow=es[:,1]; et=es[:,2]
# 海拔-温度负相关
c_et=np.corrcoef(elev,et)[0,1]
line(f"  海拔-温度相关: {c_et:.3f} (理想<0: 高海拔更冷)")
# 海拔-雪盖正相关
c_es=np.corrcoef(elev,snow)[0,1]
line(f"  海拔-雪盖相关: {c_es:.3f} (理想>0: 高海拔多雪)")
hi=elev>0.7
if hi.sum()>0:
    line(f"  高海拔(>0.7)格子: 平均温度{et[hi].mean():.3f} 平均雪盖{snow[hi].mean():.3f}")
if c_et<-0.2 and c_es>0.2:
    line("  [OK] 地形对温度/雪盖有正确影响")
else:
    line("  [注意] 地形影响偏弱")

# ---------- 8. 风场/洋流 ----------
line("\n【8. 风场 / 洋流强度】")
wm=np.array(d['wind_mag']); om=np.array(d['ocean_mag'])
line(f"  风速量级 范围[{wm.min():.3f},{wm.max():.3f}] 均值{wm.mean():.3f} 非零占比{(wm>1e-4).mean()*100:.1f}%")
line(f"  洋流量级 范围[{om.min():.3f},{om.max():.3f}] 均值{om.mean():.3f} 非零占比{(om>1e-4).mean()*100:.1f}%")
if (wm>1e-4).mean()>0.5: line("  [OK] 风场普遍存在")
else: line("  [警告] 风场大面积为零")
if (om>1e-4).mean()>0.3: line("  [OK] 洋流存在")
else: line("  [注意] 洋流偏弱/局限")

line("\n" + "="*72)
line("分析完成")
