# -*- coding: utf-8 -*-
"""把生产 run_climate_pass_b 的内联主循环换成 pk_async_climate::climate_pass_b_pure
调用，只留 knobs/lanes 装配与 flush。
"""
import io

SRC = 'gdext/src/world_ext_climate.cpp'
lines = io.open(SRC, encoding='utf-8').read().split('\n')

start = next(i for i, l in enumerate(lines)
             if l.strip().startswith('// LandformType.LF: LOWLAND=5') and i > 1350)
end = next(i for i, l in enumerate(lines)
           if i > start and '_flush_slot_to_map(sid_lanom)' in l)
# end 指向 flush 行；把它前面的 §11.2 注释保留
while lines[end - 1].strip().startswith('//'):
    end -= 1

repl = '''    // S3 P3：主循环已提取为 pk_async_climate::climate_pass_b_pure，worker 侧吃同一份。
    pk_async_climate::ClimatePassBKnobs pbk;
    pbk.n_cells                = n_cells;
    pbk.winter_boost           = winter_boost;
    pbk.snow_cool              = snow_cool;
    pbk.veg_cool               = veg_cool;
    pbk.diurnal_amp            = diurnal_amp;
    pbk.evap_gain              = evap_gain;
    pbk.rs_threshold           = rs_threshold;
    pbk.rs_factor              = rs_factor;
    pbk.rs_lookback            = rs_lookback;
    pbk.wrap_period_x          = wrap_period_x;
    pbk.t_freeze               = t_freeze;
    pbk.coupling_gain          = coupling_gain;
    pbk.coast_leak             = coast_leak;
    pbk.sea_ice_albedo_cooling = sea_ice_albedo_cooling;
    pbk.season_phase           = season_phase;
    pbk.snowpack_cover_low     = snowpack_cover_low;
    pbk.snowpack_cover_full    = snowpack_cover_full;
    pbk.foliage_size           = foliage_size;

    pk_async_climate::ClimatePassBLanes pbl;
    pbl.temp_snapshot           = TS;
    pbl.snowpack                = SNOWPACK;
    pbl.elevation               = ELEV;
    pbl.lat_norm                = LAT;
    pbl.pos_x                   = POSX;
    pbl.pos_y                   = POSY;
    pbl.insolation_dev          = INSOL_DEV;
    pbl.temp_transport_anomaly  = TTA;
    pbl.is_water                = IW;
    pbl.landform                = LF;
    pbl.vegetation              = VG;
    pbl.sea_ice_frac            = SIF_PB;
    pbl.neighbor_indices        = NB;
    pbl.foliage_table           = FOL;
    pbl.local_thermal_anomaly   = LANOM;
    pbl.moisture                = M;

    pk_async_climate::climate_pass_b_pure(pbk, pbl);
'''.split('\n')

out = lines[:start] + repl + lines[end:]
io.open(SRC, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
print('rewired production run_climate_pass_b: replaced lines %d-%d' % (start + 1, end))
