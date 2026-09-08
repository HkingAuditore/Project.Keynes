#!/usr/bin/env python
"""Replace the inline weather-distribute computation with knob/lane assembly
plus a call into pk_async_climate::weather_distribute_pure."""
import io

SRC = 'gdext/src/world_ext_weather.cpp'
src = io.open(SRC, encoding='utf-8').read()

# ── 1. scalar knob pulls -> WeatherDistributeKnobs ───────────────────────────
B = '    const int   n_cells              = int(knobs["n_cells"]);'
E = '''    PackedInt32Array  acc_snow_days  = knobs["accumulated_snow_days"];
    PackedInt32Array  pre_snow_cover = knobs["pre_snow_cover"];
    PackedFloat32Array temp_delta_arr   = knobs["temp_delta_arr"];
    PackedFloat32Array moist_delta_arr  = knobs["moisture_delta_arr"];
    PackedByteArray   cfs_arr         = knobs["can_form_snow_arr"];
    PackedByteArray   cff_arr         = knobs["can_form_flood_arr"];
'''
b = src.index(B)
e = src.index(E) + len(E)

KNOBS = '''    // 标量收进 POD 结构体。span / band 的下限保护不在这里做 ——
    // weather_distribute_pure 自己按 cover_low/full 与 band 推，避免两份公式。
    pk_async_climate::WeatherDistributeKnobs wdk;
    const int n_cells = int(knobs["n_cells"]);
    wdk.n_cells = n_cells;
    wdk.snow_min_intensity = float(knobs["snow_min_intensity"]);
    wdk.snow_freeze_t = float(knobs["snow_freeze_t"]);
    wdk.snow_melt_t = float(knobs["snow_melt_t"]);
    wdk.snow_intensity_snow = float(knobs["snow_intensity_for_snowing"]);
    wdk.snow_accum_days_req = int(knobs["snow_accum_days_req"]);
    wdk.flood_heavy_int = float(knobs["flood_heavy_intensity"]);
    wdk.flood_heavy_pre = float(knobs["flood_heavy_precip"]);
    wdk.flood_low_int = float(knobs["flood_lowland_intensity"]);
    wdk.flood_low_elev = float(knobs["flood_lowland_elev"]);
    wdk.flood_low_moist = float(knobs["flood_lowland_moisture"]);
    wdk.wt_clear = int(knobs["wt_clear"]);
    wdk.cv_snow = int(knobs["cv_snow"]);
    wdk.cv_none = int(knobs["cv_none"]);
    wdk.cv_flooding = int(knobs["cv_flooding"]);
    wdk.snowpack_accum_gain = knobs.has("snowpack_accum_gain")
        ? float(knobs["snowpack_accum_gain"]) : 0.10f;
    wdk.snowpack_melt_temp_gain = knobs.has("snowpack_melt_temp_gain")
        ? float(knobs["snowpack_melt_temp_gain"]) : 0.22f;
    wdk.snowpack_melt_sun_gain = knobs.has("snowpack_melt_sun_gain")
        ? float(knobs["snowpack_melt_sun_gain"]) : 0.12f;
    wdk.snowpack_cover_low = knobs.has("snowpack_cover_low")
        ? float(knobs["snowpack_cover_low"]) : 0.05f;
    wdk.snowpack_cover_full = knobs.has("snowpack_cover_full")
        ? float(knobs["snowpack_cover_full"]) : 0.32f;
    wdk.snowline_temp_threshold = knobs.has("snowline_temp_threshold")
        ? float(knobs["snowline_temp_threshold"]) : 0.24f;
    wdk.snowline_band = knobs.has("snowline_band") ? float(knobs["snowline_band"]) : 0.22f;
    float weather_temp_anomaly_cap = knobs.has("weather_temp_anomaly_cap")
        ? float(knobs["weather_temp_anomaly_cap"]) : 0.025f;
    if (weather_temp_anomaly_cap < 0.0f) weather_temp_anomaly_cap = 0.0f;
    else if (weather_temp_anomaly_cap > 0.10f) weather_temp_anomaly_cap = 0.10f;
    wdk.weather_temp_anomaly_cap = weather_temp_anomaly_cap;
    const bool direct_moisture_enabled =
        bool(knobs.get("weather_direct_moisture_enabled", false));
    wdk.direct_moisture_enabled = direct_moisture_enabled;

    PackedInt32Array  acc_snow_days  = knobs["accumulated_snow_days"];
    PackedInt32Array  pre_snow_cover = knobs["pre_snow_cover"];
    PackedFloat32Array temp_delta_arr   = knobs["temp_delta_arr"];
    PackedFloat32Array moist_delta_arr  = knobs["moisture_delta_arr"];
    PackedByteArray   cfs_arr         = knobs["can_form_snow_arr"];
    PackedByteArray   cff_arr         = knobs["can_form_flood_arr"];
'''
src = src[:b] + KNOBS + src[e:]

# ── 2. lane pointers -> WeatherDistributeLanes / State ───────────────────────
B2 = '    float * const __restrict T   = s_temp.arr_f32.ptrw();'
E2 = '''    const uint8_t * const __restrict CFS = cfs_arr.ptr();
    const uint8_t * const __restrict CFF = cff_arr.ptr();
'''
b = src.index(B2)
e = src.index(E2) + len(E2)

LANES = '''    // 四张剖面表拷进 knobs：它们是 8 项定长表，进 POD 结构体后 worker 不必再持有
    // Godot PackedArray。长度已在上面校验过恰好是 8。
    std::memcpy(wdk.temp_delta, temp_delta_arr.ptr(), 8 * sizeof(float));
    std::memcpy(wdk.moist_delta, moist_delta_arr.ptr(), 8 * sizeof(float));
    std::memcpy(wdk.can_form_snow, cfs_arr.ptr(), 8);
    std::memcpy(wdk.can_form_flood, cff_arr.ptr(), 8);

    pk_async_climate::WeatherDistributeLanes wdl;
    wdl.temp = s_temp.arr_f32.ptrw();
    wdl.moisture = s_moist.arr_f32.ptrw();
    wdl.snow_cover = s_snow_cov.arr_f32.ptrw();
    wdl.snowpack = s_snowpack.arr_f32.ptrw();
    wdl.water_balance_30d = s_waterbal.arr_f32.ptrw();
    wdl.soil_moisture = s_soil.arr_f32.ptrw();
    wdl.cover = s_cover.arr_u8.ptrw();
    wdl.landform = s_lf.arr_u8.ptr();
    wdl.terrain = s_terrain.arr_u8.ptr();
    wdl.elevation = s_elev.arr_f32.ptr();
    wdl.heat = s_heat.arr_f32.ptr();
    wdl.weather_intensity = s_w_int.arr_f32.ptr();
    wdl.weather_precip = s_w_pre.arr_f32.ptr();
    wdl.weather_type = s_w_typ.arr_u8.ptr();
    wdl.weather_field_init = s_w_fin.arr_u8.ptr();

    pk_async_climate::WeatherDistributeState wds;
    wds.accumulated_snow_days = acc_snow_days.ptrw();
    wds.pre_snow_cover = pre_snow_cover.ptrw();
'''
src = src[:b] + LANES + src[e:]

# ── 3. helper lambdas + loop -> kernel call ──────────────────────────────────
B3 = '''    auto clamp01 = [](float v) -> float {
        if (v < 0.0f) return 0.0f;
        if (v > 1.0f) return 1.0f;
        return v;
    };'''
E3 = '''            if (CV[i] == cv_flooding && moist_now < 0.50f && precip < 0.04f) {
                CV[i] = uint8_t(cv_none);
                changed_cells.append(i);
                cover_dirty = true;
            }
        }
    }
'''
b = src.index(B3)
e = src.index(E3) + len(E3)

CALL = '''    // 数值核心已抽成共享纯内核 pk_async_climate::weather_distribute_pure，那几个
    // 局部 lambda 也跟着进去了。这里只留 Godot 侧的装配、记录与 flush。
    // 记录必须在内核之前：temp / moisture / snowpack / cover / 两条积雪计数全是
    // in/out，跑完再记就变成记结果。
    record_production_weather_distribute_input(wdk, wdl, wds, n_cells);
    pk_async_climate::WeatherDistributeEmit wde;
    pk_async_climate::weather_distribute_pure(wdk, wdl, wds, wde);
    PackedInt32Array changed_cells;
    if (!wde.changed_cells.empty()) {
        changed_cells.resize(int(wde.changed_cells.size()));
        std::memcpy(changed_cells.ptrw(), wde.changed_cells.data(),
                    wde.changed_cells.size() * sizeof(int32_t));
    }
    const bool cover_dirty = wde.cover_dirty;
'''
src = src[:b] + CALL + src[e:]

io.open(SRC, 'w', encoding='utf-8', newline='').write(src)
print('rewired run_weather_distribute_pass')
