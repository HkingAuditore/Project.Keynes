import math, sys
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass

TILT=23.5; DAYLEN=0.35
AMP_GAIN=0.32*1.8   # season_temp_amp * insolation_season_gain = 0.576
POLAR_DAMP=0.30

def smoothstep(a,b,x):
    if b==a: return 0.0 if x<a else 1.0
    t=max(0.0,min(1.0,(x-a)/(b-a))); return t*t*(3-2*t)
def subsolar(phase): return math.radians(TILT)*math.cos(math.tau*(phase%4.0)/4.0)
def sunset_h(lat,decl):
    if abs(decl)<=1e-6: return math.pi*0.5
    pt=-math.tan(lat)*math.tan(decl)
    if pt<=-1: return math.pi
    if pt>=1: return 0.0
    return math.acos(pt)
def daily_insol(ny,phase):
    lat=(min(1.0,max(0.0,ny))-0.5)*math.pi; sub=subsolar(phase)
    h0=sunset_h(lat,sub)
    if h0<=1e-6: return 0.0
    d=h0*math.sin(lat)*math.sin(sub)+math.cos(lat)*math.cos(sub)*math.sin(h0)
    return max(0.0,min(1.0,d))
def annual_mean(ny):
    return sum(daily_insol(ny,(s+0.5)*0.25) for s in range(16))/16.0

def dev_old(ny,phase):
    now=daily_insol(ny,phase); mean=annual_mean(ny); da=now-mean
    dr=max(-1.0,min(1.0, da/max(mean,0.18)))
    al=abs((min(1.0,max(0.0,ny))-0.5)*2.0); pw=smoothstep(0.55,0.90,al)*0.55
    return max(-1.0,min(1.0, da+(dr-da)*pw))
def dev_new(ny,phase):
    now=daily_insol(ny,phase); mean=annual_mean(ny); da=now-mean
    al=abs((min(1.0,max(0.0,ny))-0.5)*2.0); pd=smoothstep(0.55,0.95,al)*POLAR_DAMP
    return max(-1.0,min(1.0, da*(1.0-pd)))

print("========= 问题2：季节偏移峰值 修复前/后（soff = 0.576*dev）=========")
print(f"{'lat_norm':>9}{'|lat|':>6}{'soff夏峰_old':>13}{'soff夏峰_new':>13}{'降幅%':>7}")
for ny in [0.02,0.05,0.10,0.15,0.25,0.35,0.50,0.85,0.95]:
    so=max(AMP_GAIN*dev_old(ny,p*0.05) for p in range(80))
    sn=max(AMP_GAIN*dev_new(ny,p*0.05) for p in range(80))
    al=abs((ny-0.5)*2.0)
    drop = (1-sn/so)*100 if so>1e-6 else 0.0
    print(f"{ny:>9.2f}{al:>6.2f}{so:>13.3f}{sn:>13.3f}{drop:>7.1f}")
print("注：极地夏季辐射目标 ≈ temp_baseline_year(极地≈0) + soff夏峰；soff 即极地夏季目标上限。")

# ========= 问题1：海冰累积 修复前/后 =========
# 取一个亚极地水体的真实温度年周期（来自 cell#360 时间序列，近似）。
# 一个仿真年内的代表温度序列（按 season_phase 推进，加速档每轮 dt 天）。
temp_year=[0.0,0.0,0.0,0.0,0.04,0.13,0.37,0.46,0.50,0.65,0.73,0.77,
           0.72,0.64,0.56,0.32,0.23,0.08,0.02,0.0]  # 20 段/年
FORM,MELT=0.14,0.22; KF,KM=0.40,1.45; CAP=0.05
def gate(insol): return max(0.0,min(1.0,1.0-smoothstep(0.30,0.55,insol)))
# 简化：用 insol≈0（冷季低日照），freeze_gate≈1；夏季高温段无结冰只融化
def run(dt_days, cap_after):
    frac=0.0; mx=0.0
    for t in temp_year:
        diff_f=max(0.0,FORM-t); diff_m=max(0.0,t-MELT)
        rate=KF*diff_f*1.0 - KM*diff_m
        if cap_after:   # 旧：先*dt 再 cap
            d=rate*dt_days
            d=max(-CAP,min(CAP,d))
        else:           # 新：先 cap 日速率 再*dt
            r=max(-CAP,min(CAP,rate))
            d=r*dt_days
        frac=max(0.0,min(1.0,frac+d)); mx=max(mx,frac)
    return mx
print("\n========= 问题1：亚极地水体一年内海冰frac峰值（翻转阈值=0.68）=========")
print(f"{'dt_days/轮':>10}{'峰值_old(cap后乘)':>18}{'峰值_new(cap前乘)':>18}{'是否翻转(new)':>14}")
for dt in [1.0,3.0,7.0,14.0]:
    mo=run(dt,True); mn=run(dt,False)
    print(f"{dt:>10.0f}{mo:>18.3f}{mn:>18.3f}{('是' if mn>=0.68 else '否'):>14}")
print("注：old 每轮被砍到≤0.05，亚极地短冷窗内永远到不了 0.68；new 加速档下可累积翻转成海冰。")
