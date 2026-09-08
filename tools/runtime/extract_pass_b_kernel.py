# -*- coding: utf-8 -*-
"""把生产 run_climate_pass_b 的主循环 + 海冰尾循环原样搬进 runtime_climate_passes.cpp
的 climate_pass_b_pure，只做机械改名（局部指针 → knobs/lanes 字段）。

对应 plan P3：pass_b 曾有 4 份实现（scalar / simd / thread / worker），逐行比对显示
worker 那份多了个 glacier 钳位。这一步把 scalar 与 worker 合成一份。
"""
import io
import re

SRC = 'gdext/src/world_ext_climate.cpp'
DST = 'gdext/src/runtime_climate_passes.cpp'

src = io.open(SRC, encoding='utf-8').read().split('\n')

# 主循环起点：run_climate_pass_b 内的 `for (int i = 0; i < n_cells; ++i) {`
start = next(i for i, l in enumerate(src)
             if l.strip() == 'for (int i = 0; i < n_cells; ++i) {' and i > 1360)
# 尾巴终点：海冰反照率尾循环闭合之后、_flush_slot_to_map 之前
end = next(i for i, l in enumerate(src)
           if i > start and '_flush_slot_to_map(sid_lanom)' in l)
body = src[start:end]
# 去掉尾部空行与 §11.2 flush 注释
while body and (not body[-1].strip() or body[-1].strip().startswith('//')):
    body.pop()

text = '\n'.join(body)

# ── 机械改名：局部指针/标量 → lanes/knobs 字段 ──
LANES = ['snowpack', 'elevation', 'lat_norm', 'pos_x', 'pos_y', 'insolation_dev',
         'temp_transport_anomaly', 'is_water', 'landform', 'vegetation',
         'sea_ice_frac', 'neighbor_indices', 'foliage_table',
         'local_thermal_anomaly', 'moisture', 'temp_snapshot']
KNOBS = ['winter_boost', 'snow_cool', 'veg_cool', 'diurnal_amp', 'evap_gain',
         'rs_threshold', 'rs_factor', 'rs_lookback', 'wrap_period_x', 't_freeze',
         'coupling_gain', 'coast_leak', 'sea_ice_albedo_cooling', 'season_phase',
         'snowpack_cover_low', 'snowpack_cover_full', 'foliage_size', 'n_cells']

prologue = []
prologue.append('    // ── 前言：把 knobs/lanes 摊回生产里的局部名，主循环得以原样保留 ──')
for name in KNOBS:
    prologue.append('    const auto %s = knobs.%s;' % (name, name))
alias = [
    ('TS', 'temp_snapshot'), ('SNOWPACK', 'snowpack'), ('ELEV', 'elevation'),
    ('LAT', 'lat_norm'), ('POSX', 'pos_x'), ('POSY', 'pos_y'),
    ('INSOL_DEV', 'insolation_dev'), ('TTA', 'temp_transport_anomaly'),
    ('IW', 'is_water'), ('LF', 'landform'), ('VG', 'vegetation'),
    ('SIF_PB', 'sea_ice_frac'), ('NB', 'neighbor_indices'), ('FOL', 'foliage_table'),
    ('LANOM', 'local_thermal_anomaly'), ('M', 'moisture'),
]
for sym, field in alias:
    prologue.append('    const auto %s = lanes.%s;' % (sym, field))

fn = []
fn.append('void climate_pass_b_pure(const ClimatePassBKnobs &knobs,')
fn.append('                         const ClimatePassBLanes &lanes) {')
fn.append('    if (knobs.n_cells <= 0) return;')
fn.extend(prologue)
fn.append('')
fn.append('    // LandformType.LF: LOWLAND=5, HILL=6, MOUNTAIN=7, PEAK=8, DELTA=9,')
fn.append('    //                  SALT_FLAT=11 (per landform_type.gd:9-23)')
fn.append('    constexpr uint8_t LF_LOWLAND   = 5;')
fn.append('    constexpr uint8_t LF_MOUNTAIN  = 7;')
fn.append('    constexpr uint8_t LF_PEAK      = 8;')
fn.append('    constexpr uint8_t LF_DELTA     = 9;')
fn.append('    constexpr uint8_t LF_SALT_FLAT = 11;')
fn.append('')
fn.append(text)
fn.append('}')
fn.append('')

kernel = '\n'.join(fn)

dst = io.open(DST, encoding='utf-8').read()
anchor = 'bool _async_pass_b_kernel_pure('
assert anchor in dst, 'pass_b worker kernel anchor not found'
idx = dst.index(anchor)
# 插在 worker kernel 之前（同一 namespace 内）
dst = dst[:idx] + kernel + '\n' + dst[idx:]
io.open(DST, 'w', encoding='utf-8', newline='\n').write(dst)
print('inserted climate_pass_b_pure, %d lines transplanted (src %d-%d)'
      % (len(body), start + 1, end))
