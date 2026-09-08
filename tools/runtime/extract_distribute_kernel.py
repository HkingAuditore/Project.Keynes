#!/usr/bin/env python
"""Transplant the weather-distribute loop from world_ext_weather.cpp into
runtime_climate_passes.cpp as pk_async_climate::weather_distribute_pure.

Body moves verbatim; the prologue re-binds every name it uses.
"""
import io
import sys

SRC = 'gdext/src/world_ext_weather.cpp'
DST = 'gdext/src/runtime_climate_passes.cpp'

src = io.open(SRC, encoding='utf-8').read()

# helper lambdas + the loop, taken as one block so the lambdas stay next to
# their only caller.
HELPERS_BEGIN = '''    auto clamp01 = [](float v) -> float {
        if (v < 0.0f) return 0.0f;
        if (v > 1.0f) return 1.0f;
        return v;
    };'''
LOOP_END = '''            if (CV[i] == cv_flooding && moist_now < 0.50f && precip < 0.04f) {
                CV[i] = uint8_t(cv_none);
                changed_cells.append(i);
                cover_dirty = true;
            }
        }
    }
'''
b = src.index(HELPERS_BEGIN)
e = src.index(LOOP_END) + len(LOOP_END)
body = src[b:e]

# The declaration of changed_cells/cover_dirty sits inside the block; swap the
# Godot array for the emit vector.
body = body.replace('    PackedInt32Array changed_cells;\n    bool cover_dirty = false;\n',
                    '    std::vector<int32_t> &changed_cells = emit.changed_cells;\n'
                    '    bool cover_dirty = false;\n')
body = body.replace('changed_cells.append(i);', 'changed_cells.push_back(i);')
assert 'PackedInt32Array' not in body, 'Godot array left in body'
assert '.append(' not in body, 'Godot append left in body'
assert 'knobs' not in body, 'Dictionary access left in body'
assert '_slots' not in body, 'slot access left in body'

PROLOGUE = '''// weather distribute。计算体从 DCWorldExt::run_weather_distribute_pass 原样搬来，
// 连那几个局部 lambda 一起 —— 它们本来就不碰 Godot，跟着走比重写一遍安全。
void weather_distribute_pure(const WeatherDistributeKnobs &k,
                             const WeatherDistributeLanes &lanes,
                             const WeatherDistributeState &state,
                             WeatherDistributeEmit &emit) {
    const int n_cells = k.n_cells;
    if (n_cells <= 0) return;
    if (lanes.temp == nullptr || lanes.moisture == nullptr ||
        lanes.snow_cover == nullptr || lanes.snowpack == nullptr ||
        lanes.water_balance_30d == nullptr || lanes.soil_moisture == nullptr ||
        lanes.cover == nullptr || lanes.heat == nullptr ||
        lanes.elevation == nullptr || lanes.landform == nullptr ||
        lanes.terrain == nullptr || lanes.weather_intensity == nullptr ||
        lanes.weather_precip == nullptr || lanes.weather_type == nullptr ||
        lanes.weather_field_init == nullptr ||
        state.accumulated_snow_days == nullptr ||
        state.pre_snow_cover == nullptr) {
        return;
    }

    const float snow_min_intensity = k.snow_min_intensity;
    const float snow_freeze_t = k.snow_freeze_t;
    const float snow_melt_t = k.snow_melt_t;
    const float snow_intensity_snow = k.snow_intensity_snow;
    const int   snow_accum_days_req = k.snow_accum_days_req;
    const float flood_heavy_int = k.flood_heavy_int;
    const float flood_heavy_pre = k.flood_heavy_pre;
    const float flood_low_int = k.flood_low_int;
    const float flood_low_elev = k.flood_low_elev;
    const float flood_low_moist = k.flood_low_moist;
    const int   wt_clear = k.wt_clear;
    const int   cv_snow = k.cv_snow;
    const int   cv_none = k.cv_none;
    const int   cv_flooding = k.cv_flooding;
    const float snowpack_accum_gain = k.snowpack_accum_gain;
    const float snowpack_melt_temp_gain = k.snowpack_melt_temp_gain;
    const float snowpack_melt_sun_gain = k.snowpack_melt_sun_gain;
    const float snowpack_cover_low = k.snowpack_cover_low;
    const float snowpack_cover_full = k.snowpack_cover_full;
    // 与生产同式：span/band 的下限保护在这里做，不在调用方。
    const float snowpack_cover_span = (snowpack_cover_full - snowpack_cover_low) > 0.001f
        ? (snowpack_cover_full - snowpack_cover_low) : 0.001f;
    const float snowline_temp_threshold = k.snowline_temp_threshold;
    const float snowline_band_safe = k.snowline_band > 0.001f ? k.snowline_band : 0.001f;
    const float weather_temp_anomaly_cap = k.weather_temp_anomaly_cap;
    const bool  direct_moisture_enabled = k.direct_moisture_enabled;

    float * const __restrict T = lanes.temp;
    float * const __restrict M = lanes.moisture;
    float * const __restrict SC = lanes.snow_cover;
    float * const __restrict SP = lanes.snowpack;
    float * const __restrict WB = lanes.water_balance_30d;
    float * const __restrict SOIL = lanes.soil_moisture;
    uint8_t * const __restrict CV = lanes.cover;
    const uint8_t * const __restrict LF = lanes.landform;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const float * const __restrict EL = lanes.elevation;
    const float * const __restrict HEAT = lanes.heat;
    const float * const __restrict WI = lanes.weather_intensity;
    const float * const __restrict WP = lanes.weather_precip;
    const uint8_t * const __restrict WT_ = lanes.weather_type;
    const uint8_t * const __restrict WFI = lanes.weather_field_init;
    int32_t * const __restrict ACC = state.accumulated_snow_days;
    int32_t * const __restrict PRE = state.pre_snow_cover;
    const float * const __restrict TD = k.temp_delta;
    const float * const __restrict MD = k.moist_delta;
    const uint8_t * const __restrict CFS = k.can_form_snow;
    const uint8_t * const __restrict CFF = k.can_form_flood;

'''

EPILOGUE = '''
    emit.cover_dirty = cover_dirty;
}

'''

dst = io.open(DST, encoding='utf-8').read()
if 'weather_distribute_pure' in dst:
    sys.exit('weather_distribute_pure already present -- refusing to inject twice')
MARKER = '// stage 12 RUNTIME_HYDROLOGY。计算体从 DCWorldExt::run_runtime_hydrology_pass'
assert dst.count(MARKER) == 1, dst.count(MARKER)
dst = dst.replace(MARKER, PROLOGUE + body + EPILOGUE + MARKER)
io.open(DST, 'w', encoding='utf-8', newline='').write(dst)
print('injected weather_distribute_pure, body lines =', body.count('\n'))
