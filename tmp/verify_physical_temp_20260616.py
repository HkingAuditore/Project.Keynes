# -*- coding: utf-8 -*-
"""数值校验：海陆/极地温度物理化（2026-06-16）。

镜像 climate_math.gd / world_ext.cpp 的公式，跑一年季节循环（热惯性 + dt），
对比 旧模型(POLAR_SEASON_DAMP=0.30) vs 新模型(吸收短波因子+冰反照率反馈)：
  1) 极地夏季峰值温度（应下降，且为反照率驱动）
  2) 中纬陆地季节振幅（应基本不变，factor≈1.0）
  3) 海陆季节振幅对比（陆 > 海，体现大陆性）
"""
import sys, math
sys.stdout.reconfigure(encoding="utf-8")

TILT = 23.5
DAYLEN_AMP = 0.35
INSOL_AMP_GAIN = 1.8 * 0.32           # insolation_season_gain * season_temp_amp = 0.576
LAT_EXP = 1.6
# 新反照率常量（SAME_SOURCE）
ALB_OCEAN, ALB_LAND, ALB_ICE = 0.08, 0.20, 0.62
T_ICE_LO, T_ICE_HI = 0.12, 0.30
ABSORB_REF = 1.0 - ALB_LAND
# 热惯性
ALPHA_LAND = 0.35
ALPHA_WATER_OLD = 0.07
ALPHA_WATER_NEW = 0.008
DELTA_CAP = 0.15


def clamp(x, lo, hi):
    return lo if x < lo else (hi if x > hi else x)


def smoothstep(a, b, x):
    if a == b:
        return 0.0 if x < a else 1.0
    t = clamp((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def subsolar(phase):
    frac = (phase % 4.0) / 4.0
    return math.radians(TILT) * math.cos(2.0 * math.pi * frac)


def sunset_hour_angle(lat_rad, decl):
    if abs(decl) <= 1e-6:
        return math.pi * 0.5
    pt = -math.tan(lat_rad) * math.tan(decl)
    if pt <= -1.0:
        return math.pi
    if pt >= 1.0:
        return 0.0
    return math.acos(pt)


def daily_insol(ny, phase):
    lat = (ny - 0.5) * math.pi
    sub = subsolar(phase)
    h0 = sunset_hour_angle(lat, sub)
    if h0 <= 1e-6:
        return 0.0
    daily = h0 * math.sin(lat) * math.sin(sub) + math.cos(lat) * math.cos(sub) * math.sin(h0)
    return clamp(daily, 0.0, 1.0)


def annual_mean(ny, samples=16):
    return sum(daily_insol(ny, (s + 0.5) * (4.0 / samples)) for s in range(samples)) / samples


def lat_bell(ny):
    ls = (ny - 0.5) * 2.0
    return max(math.cos(ls * math.pi * 0.5), 0.0) ** LAT_EXP


def dev_old(ny, now, mean):
    dev_abs = now - mean
    abs_lat = abs((ny - 0.5) * 2.0)
    return dev_abs * (1.0 - smoothstep(0.55, 0.95, abs_lat) * 0.30)


def dev_new(now, mean):
    return now - mean


def absorbed_factor(is_water, temp):
    a_base = ALB_OCEAN if is_water else ALB_LAND
    ice_w = smoothstep(T_ICE_HI, T_ICE_LO, temp)   # 端点反序：冷=1, 暖=0
    a_eff = a_base + (ALB_ICE - a_base) * ice_w
    return (1.0 - a_eff) / ABSORB_REF


def run_year_cycle(ny, is_water, model, years=20, steps=365):
    """跑多年到稳态，返回最后一年 (min, max, peak_phase)。
    新模型：吸收因子用【年均温度 t365】（慢 EMA）作冰封代理，避免夏季融化正反馈失控。"""
    alpha = (ALPHA_WATER_OLD if model == "old" else ALPHA_WATER_NEW) if is_water else ALPHA_LAND
    temp = lat_bell(ny)
    t365 = temp                      # 年均温度 EMA（冰封代理）
    a365 = 1.0 / steps               # ≈ annual_ema_alpha
    dphase = 4.0 / steps
    last_year = []
    mean_i = annual_mean(ny)
    for y in range(years):
        last_year = []
        for s in range(steps):
            phase = (s * dphase) % 4.0
            now_i = daily_insol(ny, phase)
            if model == "old":
                dev = clamp(dev_old(ny, now_i, mean_i), -1.0, 1.0)
                season = INSOL_AMP_GAIN * dev
            else:
                dev = clamp(dev_new(now_i, mean_i), -1.0, 1.0)
                season = INSOL_AMP_GAIN * absorbed_factor(is_water, t365) * dev
            target = clamp(lat_bell(ny) + season, 0.0, 1.0)
            heat_next = temp + (target - temp) * alpha
            d = clamp(heat_next - temp, -DELTA_CAP, DELTA_CAP)
            temp = clamp(temp + d, 0.0, 1.0)
            t365 = t365 + (temp - t365) * a365
            last_year.append((phase, temp))
    temps = [t for _, t in last_year]
    tmax = max(temps); tmin = min(temps)
    peak_phase = max(last_year, key=lambda x: x[1])[0]
    return tmin, tmax, peak_phase


def report(label, ny, is_water):
    o_min, o_max, _ = run_year_cycle(ny, is_water, "old")
    n_min, n_max, _ = run_year_cycle(ny, is_water, "new")
    print(f"  {label}: ny={ny:.2f} {'海' if is_water else '陆'}  "
          f"旧[{o_min:.3f},{o_max:.3f}]振幅{o_max-o_min:.3f}  →  "
          f"新[{n_min:.3f},{n_max:.3f}]振幅{n_max-n_min:.3f}")
    return (o_min, o_max, n_min, n_max)


print("=== 吸收短波因子表（新模型）===")
for w in (False, True):
    s = "海" if w else "陆"
    for t in (0.05, 0.12, 0.20, 0.30, 0.50, 0.80):
        print(f"  {s} temp={t:.2f}  factor={absorbed_factor(w, t):.3f}")

print("\n=== 1) 极地夏季峰值（深极地 ny=0.95）===")
report("深极地海", 0.95, True)
report("深极地陆", 0.95, False)
report("亚极地海", 0.85, True)

print("\n=== 2) 中纬陆地季节振幅（ny=0.75 ≈ 45°，无冰）===")
report("中纬陆", 0.75, False)

print("\n=== 3) 海陆季节振幅对比（同纬 ny=0.72 ≈ 40°）===")
land = report("中纬陆", 0.72, False)
sea = report("中纬海", 0.72, True)
land_amp = land[3] - land[2]
sea_amp = sea[3] - sea[2]
ratio = land_amp / sea_amp if sea_amp > 1e-6 else float("inf")
print(f"  → 新模型 陆/海 振幅比 = {ratio:.2f}（>1 即大陆性对比成立）")


def ocean_cycle_amp(ny, alpha_water):
    temp = lat_bell(ny); t365 = temp; a365 = 1.0 / 365; dphase = 4.0 / 365
    last = []
    for y in range(25):
        last = []
        for s in range(365):
            phase = (s * dphase) % 4.0
            now_i = daily_insol(ny, phase)
            dev = clamp(now_i - annual_mean(ny), -1.0, 1.0)
            season = INSOL_AMP_GAIN * absorbed_factor(True, t365) * dev
            target = clamp(lat_bell(ny) + season, 0.0, 1.0)
            d = clamp((target - temp) * alpha_water, -DELTA_CAP, DELTA_CAP)
            temp = clamp(temp + d, 0.0, 1.0)
            t365 = t365 + (temp - t365) * a365
            last.append(temp)
    return min(last), max(last)


print("\n=== 4) α_water 扫描（ny=0.72，陆地振幅={:.3f}，目标陆/海≈2）===".format(land_amp))
for aw in (0.040, 0.030, 0.020, 0.016, 0.012, 0.010, 0.008):
    omin, omax = ocean_cycle_amp(0.72, aw)
    oamp = omax - omin
    r = land_amp / oamp if oamp > 1e-6 else float("inf")
    print(f"  α_water={aw:.3f}  海振幅={oamp:.3f} 海[{omin:.3f},{omax:.3f}]  陆/海={r:.2f}")
