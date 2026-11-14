#include "world_ext.h"
#include "runtime_climate_passes.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace pk {

using namespace godot;

// Production climate inputs are captured at their real sync pass boundaries.
// This TU owns only those member definitions; async task state and workers remain
// solely in world_ext_climate_async.cpp.

void DCWorldExt::record_production_feedback_input(
        const pk_async_climate::ClimateFeedbackKnobs &knobs, int n_cells,
        const uint8_t *is_water, const uint8_t *weather_type,
        const float *weather_intensity, const uint8_t *weather_field_init,
        const float *temp_transport_anomaly, const float *base_moisture,
        const float *soil_moisture) {
    if (n_cells <= 0 || is_water == nullptr || weather_type == nullptr ||
        weather_intensity == nullptr || weather_field_init == nullptr ||
        temp_transport_anomaly == nullptr || base_moisture == nullptr ||
        soil_moisture == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::ClimateFeedbackInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    const size_t n = size_t(n_cells);
    const auto copy_f32 = [n](std::vector<float> &dst, const float *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto copy_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    copy_u8(rec->is_water, is_water);
    copy_u8(rec->weather_type, weather_type);
    copy_f32(rec->weather_intensity, weather_intensity);
    copy_u8(rec->weather_field_init, weather_field_init);
    copy_f32(rec->temp_transport_anomaly, temp_transport_anomaly);
    // base_moisture / soil_moisture 是 in/out：这里必须在 kernel 跑之前调用，记的是
    // 生产读到的初值。调用点就在 apply 之前一行。
    copy_f32(rec->base_moisture, base_moisture);
    copy_f32(rec->soil_moisture, soil_moisture);
    _production_feedback = std::move(rec);
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK;
}

void DCWorldExt::record_production_vegetation_input(
        const pk_async_climate::VegetationDynamicsKnobs &knobs,
        const pk_async_climate::VegetationDynamicsTables &tables,
        const pk_async_climate::VegetationDynamicsLanes &lanes,
        int n_cells) {
    if (n_cells <= 0 || knobs.n_veg <= 0 || knobs.n_wt <= 0) return;
    if (tables.ideal_temp == nullptr || tables.ideal_moist == nullptr ||
        tables.temp_tol == nullptr || tables.moist_tol == nullptr ||
        tables.weather_penalty == nullptr || tables.resistance == nullptr ||
        tables.next_up == nullptr || tables.next_down == nullptr) {
        return;
    }
    if (lanes.is_water == nullptr || lanes.terrain == nullptr ||
        lanes.landform == nullptr || lanes.vegetation == nullptr ||
        lanes.temp_30d == nullptr || lanes.moisture == nullptr ||
        lanes.water_balance_30d == nullptr || lanes.weather_type == nullptr ||
        lanes.weather_intensity == nullptr || lanes.weather_field_init == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::VegetationDynamicsInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    const size_t n = size_t(n_cells);
    const auto copy_f32 = [](std::vector<float> &dst, const float *src, size_t count) {
        dst.resize(count);
        if (count > 0) std::memcpy(dst.data(), src, count * sizeof(float));
    };
    const auto copy_u8 = [](std::vector<uint8_t> &dst, const uint8_t *src, size_t count) {
        dst.resize(count);
        if (count > 0) std::memcpy(dst.data(), src, count);
    };
    const size_t nv = size_t(knobs.n_veg);
    copy_f32(rec->ideal_temp, tables.ideal_temp, nv);
    copy_f32(rec->ideal_moist, tables.ideal_moist, nv);
    copy_f32(rec->temp_tol, tables.temp_tol, nv);
    copy_f32(rec->moist_tol, tables.moist_tol, nv);
    copy_f32(rec->weather_penalty, tables.weather_penalty, size_t(std::max(knobs.wt_pen_size, 0)));
    copy_f32(rec->resistance, tables.resistance, nv * size_t(knobs.n_wt));
    copy_u8(rec->next_up, tables.next_up, nv);
    copy_u8(rec->next_down, tables.next_down, nv);
    copy_u8(rec->is_water, lanes.is_water, n);
    copy_u8(rec->terrain, lanes.terrain, n);
    copy_u8(rec->landform, lanes.landform, n);
    copy_u8(rec->vegetation, lanes.vegetation, n);
    copy_f32(rec->temp_30d, lanes.temp_30d, n);
    copy_f32(rec->moisture, lanes.moisture, n);
    copy_f32(rec->water_balance_30d, lanes.water_balance_30d, n);
    copy_u8(rec->weather_type, lanes.weather_type, n);
    copy_f32(rec->weather_intensity, lanes.weather_intensity, n);
    copy_u8(rec->weather_field_init, lanes.weather_field_init, n);
    // soil_moisture 与 regen_score 都不是 worker store 的成员：记生产读到的初值，
    // worker 侧用 scratch 承接，输出丢弃（与 feedback 的 soil_moisture 同处理）。
    rec->has_soil_moisture = lanes.soil_moisture != nullptr;
    if (rec->has_soil_moisture) copy_f32(rec->soil_moisture, lanes.soil_moisture, n);
    if (lanes.regen_score != nullptr) copy_f32(rec->regen_score, lanes.regen_score, n);
    rec->has_growth_pressure = lanes.vegetation_growth_pressure != nullptr;
    _production_vegetation = std::move(rec);
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;
}

void DCWorldExt::record_production_weather_input(
        const pk_async_climate::WeatherFieldKnobs &knobs,
        const pk_async_climate::SynopticAdvanceKnobs &synoptic,
        bool synoptic_enabled,
        const pk_async_climate::WeatherFieldLanes &lanes,
        const pk_async_climate::WeatherFieldState &state,
        int n_cells,
        const uint8_t *field_init) {
    if (n_cells <= 0) return;
    // 必需 lane 缺任何一条就不记：半份记录会让 worker 侧的长度校验静默跳过整个
    // stage，而那在分叉矩阵里和"生产这天没跑 weather"长得一样。
    if (lanes.temp_read == nullptr || lanes.moisture_read == nullptr ||
        lanes.air_anomaly == nullptr || lanes.wind_x == nullptr ||
        lanes.wind_y == nullptr || lanes.wind_speed == nullptr ||
        lanes.terrain == nullptr || lanes.has_river == nullptr ||
        lanes.elevation == nullptr || lanes.vegetation == nullptr ||
        lanes.pos_x == nullptr || lanes.pos_y == nullptr ||
        lanes.temp_transport_anomaly == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::WeatherFieldInput>();
    rec->knobs = knobs;
    rec->synoptic = synoptic;
    rec->synoptic_enabled = synoptic_enabled;
    rec->n_cells = n_cells;
    rec->ran = true;
    const size_t n = size_t(n_cells);
    const auto cp_f32 = [n](std::vector<float> &dst, const float *src) {
        if (src == nullptr) { dst.clear(); return; }
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto cp_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        if (src == nullptr) { dst.clear(); return; }
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    cp_f32(rec->temp_read, lanes.temp_read);
    cp_f32(rec->moisture_read, lanes.moisture_read);
    cp_f32(rec->air_anomaly, lanes.air_anomaly);
    cp_f32(rec->wind_x, lanes.wind_x);
    cp_f32(rec->wind_y, lanes.wind_y);
    cp_f32(rec->wind_speed, lanes.wind_speed);
    cp_u8(rec->terrain, lanes.terrain);
    cp_u8(rec->has_river, lanes.has_river);
    cp_f32(rec->river_q30, lanes.river_q30);
    cp_f32(rec->elevation, lanes.elevation);
    cp_u8(rec->vegetation, lanes.vegetation);
    cp_f32(rec->soil_moisture, lanes.soil_moisture);
    cp_f32(rec->vitality, lanes.vitality);
    cp_f32(rec->sea_ice, lanes.sea_ice);
    cp_f32(rec->pos_x, lanes.pos_x);
    cp_f32(rec->pos_y, lanes.pos_y);
    cp_f32(rec->temp_anomaly, lanes.temp_anomaly);
    cp_f32(rec->snow_cover, lanes.snow_cover);
    cp_f32(rec->temp_transport_anomaly, lanes.temp_transport_anomaly);

    // 跨 tick 状态：这里记的是生产这一轮【读到的】初值，所以调用点必须在 solve
    // 之前 —— conv_inhib 与 ψ 都是 in/out。
    cp_f32(rec->conv_inhib, state.conv_inhib);
    if (synoptic_enabled) rec->psi = _wx_synoptic;
    if (state.cyclone_tag != nullptr &&
        state.cyclone_tag_count == n_cells) {
        rec->cyclone_tag.resize(n);
        std::memcpy(rec->cyclone_tag.data(), state.cyclone_tag,
                    n * sizeof(uint32_t));
        rec->cyclone_generation = state.cyclone_generation;
        cp_f32(rec->cyclone_lift, state.cyclone_lift);
        cp_f32(rec->cyclone_x, state.cyclone_x);
        cp_f32(rec->cyclone_y, state.cyclone_y);
    }
    if (state.monsoon_thermal != nullptr &&
        state.monsoon_thermal_count == n_cells) {
        cp_f32(rec->monsoon_thermal, state.monsoon_thermal);
    }
    if (state.traj_idx != nullptr && state.traj_w != nullptr) {
        rec->traj_idx.resize(n * 3);
        rec->traj_w.resize(n * 3);
        std::memcpy(rec->traj_idx.data(), state.traj_idx, n * 3 * sizeof(int32_t));
        std::memcpy(rec->traj_w.data(), state.traj_w, n * 3 * sizeof(float));
    }
    if (field_init != nullptr) {
        rec->field_init.resize(n);
        std::memcpy(rec->field_init.data(), field_init, n);
    }
    _production_weather = std::move(rec);
    // stage bit 由 solve pass 自己置位（它在 sliced 路径上可能被多次调用，而记录只
    // 在 start_idx == 0 那次做）。
}

void DCWorldExt::record_production_weather_distribute_input(
        const pk_async_climate::WeatherDistributeKnobs &knobs,
        const pk_async_climate::WeatherDistributeLanes &lanes,
        const pk_async_climate::WeatherDistributeState &state,
        int n_cells) {
    if (n_cells <= 0) return;
    if (lanes.heat == nullptr || lanes.elevation == nullptr ||
        lanes.landform == nullptr || lanes.terrain == nullptr ||
        lanes.weather_intensity == nullptr || lanes.weather_precip == nullptr ||
        lanes.weather_type == nullptr || lanes.weather_field_init == nullptr ||
        lanes.cover == nullptr || lanes.soil_moisture == nullptr ||
        state.accumulated_snow_days == nullptr ||
        state.pre_snow_cover == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::WeatherDistributeInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    rec->ran = true;
    const size_t n = size_t(n_cells);
    const auto cp_f32 = [n](std::vector<float> &dst, const float *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto cp_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    const auto cp_i32 = [n](std::vector<int32_t> &dst, const int32_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(int32_t));
    };
    cp_f32(rec->heat, lanes.heat);
    cp_f32(rec->elevation, lanes.elevation);
    cp_u8(rec->landform, lanes.landform);
    cp_u8(rec->terrain, lanes.terrain);
    cp_f32(rec->weather_intensity, lanes.weather_intensity);
    cp_f32(rec->weather_precip, lanes.weather_precip);
    cp_u8(rec->weather_type, lanes.weather_type);
    cp_u8(rec->weather_field_init, lanes.weather_field_init);
    cp_u8(rec->cover, lanes.cover);
    cp_f32(rec->soil_moisture, lanes.soil_moisture);
    cp_i32(rec->accumulated_snow_days, state.accumulated_snow_days);
    cp_i32(rec->pre_snow_cover, state.pre_snow_cover);
    _production_weather_distribute = std::move(rec);
    // stage bit 由 WEATHER 那一位代表：distribute 与 field solve 同属 stage 11，
    // 分开置位会让分叉矩阵多出一个没有对应字段的 stage。
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
}

void DCWorldExt::record_production_hydrology_input(
        const pk_async_climate::HydrologyKnobs &knobs,
        const pk_async_climate::HydrologyLanes &lanes,
        bool has_neighbors, uint64_t canal_topology_generation,
        int n_cells) {
    if (n_cells <= 0) return;
    if (lanes.has_river == nullptr || lanes.terrain == nullptr ||
        lanes.landform == nullptr || lanes.vegetation == nullptr ||
        lanes.cover == nullptr || lanes.elevation == nullptr ||
        lanes.precip == nullptr || lanes.intensity == nullptr ||
        lanes.weather_type == nullptr || lanes.temp == nullptr ||
        lanes.heat == nullptr || lanes.snowpack == nullptr ||
        lanes.base_moisture == nullptr || lanes.is_water == nullptr ||
        lanes.vitality == nullptr || lanes.canal_mask == nullptr ||
        lanes.soil_moisture == nullptr || lanes.discharge_30d == nullptr) {
        return;
    }
    auto rec = std::make_shared<pk_async_climate::HydrologyInput>();
    rec->knobs = knobs;
    rec->n_cells = n_cells;
    rec->ran = true;
    rec->has_neighbors = has_neighbors;
    rec->canal_topology_generation = canal_topology_generation;
    const size_t n = size_t(n_cells);
    const auto cp_f32 = [n](std::vector<float> &dst, const float *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n * sizeof(float));
    };
    const auto cp_u8 = [n](std::vector<uint8_t> &dst, const uint8_t *src) {
        dst.resize(n);
        std::memcpy(dst.data(), src, n);
    };
    cp_u8(rec->has_river, lanes.has_river);
    cp_u8(rec->terrain, lanes.terrain);
    cp_u8(rec->landform, lanes.landform);
    cp_u8(rec->vegetation, lanes.vegetation);
    cp_u8(rec->cover, lanes.cover);
    cp_f32(rec->elevation, lanes.elevation);
    cp_f32(rec->precip, lanes.precip);
    cp_f32(rec->intensity, lanes.intensity);
    cp_u8(rec->weather_type, lanes.weather_type);
    cp_f32(rec->temp, lanes.temp);
    cp_f32(rec->heat, lanes.heat);
    cp_f32(rec->snowpack, lanes.snowpack);
    cp_f32(rec->base_moisture, lanes.base_moisture);
    cp_u8(rec->is_water, lanes.is_water);
    cp_f32(rec->vitality, lanes.vitality);
    cp_u8(rec->canal_mask, lanes.canal_mask);
    cp_f32(rec->soil_moisture, lanes.soil_moisture);
    cp_f32(rec->discharge_30d, lanes.discharge_30d);
    if (lanes.canal_water != nullptr) cp_f32(rec->canal_water, lanes.canal_water);
    // hydro_parent 不在这里记：它只在地图生成/regen 时重建，属于 round static
    // knobs 的范畴，每天再抄一份 int32 全图纯属浪费。
    _production_hydrology = std::move(rec);
}

// 生产 pass_b 用的海冰浓度 lane。三个变体（scalar / simd / thread）都调这里，最后
// 一个覆盖前面的，内容相同所以结果一致。SIF 为空（cp 没配 sea_ice_albedo_cooling
// 或 knobs 没带 sea_ice_frac）时也要如实记一个空的 —— 留着上一天那份会让 worker
// 在生产本来跳过尾循环的那一天照跑。
void DCWorldExt::record_production_pass_b_input(int n_cells, const float *sea_ice_frac,
                                               const float *temp_transport_anomaly) {
    if (n_cells <= 0) return;
    auto in = std::make_shared<pk_async_climate::ClimatePassBInput>();
    in->n_cells = n_cells;
    if (sea_ice_frac != nullptr) {
        in->sea_ice_frac.assign(sea_ice_frac, sea_ice_frac + n_cells);
    }
    if (temp_transport_anomaly != nullptr) {
        in->temp_transport_anomaly.assign(temp_transport_anomaly,
                                          temp_transport_anomaly + n_cells);
    }
    _production_pass_b = std::move(in);
}

// 生产 sea_ice 用的温度 lane。scalar / thread 两个变体都调这里。
void DCWorldExt::record_production_sea_ice_input(
        const pk_async_climate::SeaIceLanes &lanes, int n_cells) {
    if (n_cells <= 0) return;
    auto in = std::make_shared<pk_async_climate::SeaIceInput>();
    in->n_cells = n_cells;
    const auto cp_f32 = [n_cells](std::vector<float> &dst, const float *src) {
        if (src == nullptr) return;
        dst.assign(src, src + n_cells);
    };
    const auto cp_u8 = [n_cells](std::vector<uint8_t> &dst, const uint8_t *src) {
        if (src == nullptr) return;
        dst.assign(src, src + n_cells);
    };
    cp_f32(in->cell_temperature, lanes.cell_temperature);
    cp_f32(in->upwelling_strength, lanes.upwelling_strength);
    cp_f32(in->insolation_now, lanes.insolation_now);
    cp_f32(in->ocean_thermal_anomaly, lanes.ocean_thermal_anomaly);
    cp_f32(in->temp_transport_anomaly, lanes.temp_transport_anomaly);
    cp_u8(in->terrain, lanes.terrain);
    cp_u8(in->base_terrain, lanes.base_terrain);
    cp_f32(in->sea_ice_frac, lanes.sea_ice_frac);
    if (lanes.water_terrain_ids != nullptr && lanes.water_terrain_ids_size > 0) {
        in->water_terrain_ids.assign(
            lanes.water_terrain_ids,
            lanes.water_terrain_ids + lanes.water_terrain_ids_size);
    }
    _production_sea_ice = std::move(in);
}

// 生产 wind_surface 读到的 oanom。空记录会让 worker 退回自己 pass_a 的清零，
// 而不是错吃上一天的值，所以守住 nullptr 而不是记一个空的。
// 生产 ocean_water 用的 baseline / temp_before。两条都不是 slot，只在这个调用点
// 才抽得到真值 —— 见 pk_async_climate::OceanWaterInput 的注释。
void DCWorldExt::record_production_ocean_water_input(int n_cells, const float *baseline,
                                                    const float *temp_before) {
    if (n_cells <= 0) return;
    auto in = std::make_shared<pk_async_climate::OceanWaterInput>();
    in->n_cells = n_cells;
    if (baseline != nullptr) in->baseline.assign(baseline, baseline + n_cells);
    if (temp_before != nullptr) in->temp_before.assign(temp_before, temp_before + n_cells);
    _production_ocean_water = std::move(in);
}

void DCWorldExt::record_production_wind_surface_input(int n_cells, const float *ocean_anomaly) {
    if (n_cells <= 0 || ocean_anomaly == nullptr) return;
    auto in = std::make_shared<pk_async_climate::WindSurfaceInput>();
    in->n_cells = n_cells;
    in->ocean_anomaly.assign(ocean_anomaly, ocean_anomaly + n_cells);
    _production_wind_surface = std::move(in);
}

void DCWorldExt::record_production_pass_a_scalars(
        const pk_async_climate::ClimateRoundScalars &src) {
    _production_round_scalar_mask |= 0x01;
    _production_stage_mask |= pk_async_climate::CLIMATE_STAGE_BIT_PASS_A;
    pk_async_climate::ClimateRoundScalars &s = _production_round_scalars;
    s.season_phase = src.season_phase;
    s.axial_tilt_deg = src.axial_tilt_deg;
    s.day_length_gain = src.day_length_gain;
    s.solar_gain = src.solar_gain;
    s.insol_amp = src.insol_amp;
    s.insol_gain = src.insol_gain;
    s.insol_dev_min = src.insol_dev_min;
    s.insol_dev_max = src.insol_dev_max;
    s.thermal_inertia_land = src.thermal_inertia_land;
    s.thermal_inertia_water = src.thermal_inertia_water;
    s.thermal_inertia_snow = src.thermal_inertia_snow;
    s.thermal_inertia_high_mountain = src.thermal_inertia_high_mountain;
    s.thermal_daily_delta_cap = src.thermal_daily_delta_cap;
    s.thermal_dt_days = src.thermal_dt_days;
    s.runtime_moisture_base_relax_rate = src.runtime_moisture_base_relax_rate;
    s.runtime_moisture_weather_vapor_weight = src.runtime_moisture_weather_vapor_weight;
    s.runtime_moisture_precip_weight = src.runtime_moisture_precip_weight;
    s.runtime_moisture_soil_weight = src.runtime_moisture_soil_weight;
    s.runtime_moisture_soil_dry_weight = src.runtime_moisture_soil_dry_weight;
    s.runtime_moisture_water_balance_weight = src.runtime_moisture_water_balance_weight;
    s.runtime_moisture_water_balance_dry_weight = src.runtime_moisture_water_balance_dry_weight;
    s.snowpack_cover_low = src.snowpack_cover_low;
    s.maritime_season_damp = src.maritime_season_damp;
    s.sea_level = src.sea_level;
    s.days_per_year = src.days_per_year;
}

void DCWorldExt::record_production_round_scalars(int pass_bit,
                                                 const Dictionary &knobs) {
    using namespace pk_async_climate;
    // pass_bit 与 RuntimeClimateStage 的低八位同源（见 CLIMATE_STAGE_BIT_PASS_A 处
    // 的注释）。每个生产 round pass 都会调到这里，所以这一句就是低八位 stage 掩码的
    // 唯一记录点；漏了它，分叉矩阵会把"生产跑了但没记"误报成"生产没跑"。
    _production_stage_mask |= pass_bit;
    ClimateRoundScalars &s = _production_round_scalars;
    // wrap_period_x 的兜底必须是 _native_wrap_period_x（生产各 pass 缺这个键时用
    // 的就是它），而不是结构默认 0。GDScript 的 wind/ocean knobs 里根本不带这个
    // 键，所以按结构默认记等于告诉 worker"域宽是 0"——所有 advect 类 pass 的接缝
    // 折叠因此在两边不一致。
    const auto f = [&knobs](const char *key, float fallback) {
        return knobs.has(key) ? float(knobs[key]) : fallback;
    };
    const auto d = [&knobs](const char *key, double fallback) {
        return knobs.has(key) ? double(knobs[key]) : fallback;
    };
    const auto i32 = [&knobs](const char *key, int fallback) {
        return knobs.has(key) ? int(knobs[key]) : fallback;
    };
    const auto b = [&knobs](const char *key, bool fallback) {
        return knobs.has(key) ? bool(knobs[key]) : fallback;
    };
    switch (pass_bit) {
    case 0x02:  // pass_b
        s.pb_winter_boost = f("winter_boost", s.pb_winter_boost);
        s.pb_snow_cool = f("snow_cool", s.pb_snow_cool);
        s.pb_veg_cool = f("veg_cool", s.pb_veg_cool);
        s.pb_diurnal_amp = f("diurnal_amp", s.pb_diurnal_amp);
        s.pb_evap_gain = f("evap_gain", s.pb_evap_gain);
        s.pb_rs_threshold = f("rs_threshold", s.pb_rs_threshold);
        s.pb_rs_factor = f("rs_factor", s.pb_rs_factor);
        s.pb_rs_lookback = i32("rs_lookback", s.pb_rs_lookback);
        s.pb_t_freeze = f("t_freeze", s.pb_t_freeze);
        s.pb_coupling_gain = f("coupling_gain", s.pb_coupling_gain);
        s.pb_coast_leak = f("coast_leak", s.pb_coast_leak);
        s.pb_sea_ice_albedo_cooling =
            f("sea_ice_albedo_cooling", s.pb_sea_ice_albedo_cooling);
        // snowpack_cover_* 与 wrap_period_x 是 pass_a/pass_b 共用的，pass_b 的 knobs
        // 里带的是生产 pass_b 实际用的那一份，照抄。
        s.snowpack_cover_low = d("snowpack_cover_low", s.snowpack_cover_low);
        s.snowpack_cover_full = d("snowpack_cover_full", s.snowpack_cover_full);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x04:  // ocean_water
        s.ow_advect_steps = i32("advect_steps", s.ow_advect_steps);
        s.ow_heat_mix = f("heat_mix", s.ow_heat_mix);
        s.ow_tta_source_cap = f("tta_source_cap", s.ow_tta_source_cap);
        s.ow_tta_blend_rate = f("tta_blend_rate", s.ow_tta_blend_rate);
        s.ow_tta_zero_current_decay =
            f("tta_zero_current_decay", s.ow_tta_zero_current_decay);
        s.ow_cold_transport_form =
            f("cold_transport_form_threshold", s.ow_cold_transport_form);
        s.ow_cold_transport_melt =
            f("cold_transport_melt_threshold", s.ow_cold_transport_melt);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x08:  // ocean_land
        s.ol_effective_leak = f("effective_leak", s.ol_effective_leak);
        s.ol_tta_source_cap = f("tta_source_cap", s.ol_tta_source_cap);
        s.ol_tta_blend_rate = f("tta_blend_rate", s.ol_tta_blend_rate);
        s.ol_tta_decay_rate = f("tta_decay_rate", s.ol_tta_decay_rate);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x10:  // wind_air（生产入口是 run_wind_air_mass_pass）
        s.wa_advect_steps = i32("advect_steps", s.wa_advect_steps);
        s.wa_heat_mix = f("heat_mix", s.wa_heat_mix);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x20:  // wind_surface
        s.ws_air_leak = f("air_leak", s.ws_air_leak);
        s.ws_cold_transport_form =
            f("cold_transport_form_threshold", s.ws_cold_transport_form);
        s.ws_cold_transport_melt =
            f("cold_transport_melt_threshold", s.ws_cold_transport_melt);
        s.wrap_period_x = f("wrap_period_x", float(_native_wrap_period_x));
        break;
    case 0x40:  // sea_ice
        s.si_k_freeze = f("k_freeze", s.si_k_freeze);
        s.si_k_melt = f("k_melt", s.si_k_melt);
        s.si_t_form = f("t_form", s.si_t_form);
        s.si_t_melt = f("t_melt", s.si_t_melt);
        s.si_contagion = f("contagion", s.si_contagion);
        s.si_threshold = f("threshold", s.si_threshold);
        s.si_hysteresis = f("hysteresis", s.si_hysteresis);
        s.si_ice_delay = f("ice_delay", s.si_ice_delay);
        s.si_enable_oht = b("enable_ocean_heat_transport", s.si_enable_oht);
        s.si_solar_gate_enabled = b("solar_gate_enabled", s.si_solar_gate_enabled);
        s.si_freeze_insol_low = f("freeze_insol_low", s.si_freeze_insol_low);
        s.si_freeze_insol_high = f("freeze_insol_high", s.si_freeze_insol_high);
        s.si_solar_melt_start = f("solar_melt_start", s.si_solar_melt_start);
        s.si_solar_melt_gain = f("solar_melt_gain", s.si_solar_melt_gain);
        s.si_min_thick_ice_solar_exposure =
            f("min_thick_ice_solar_exposure", s.si_min_thick_ice_solar_exposure);
        s.si_daily_delta_cap = f("daily_delta_cap", s.si_daily_delta_cap);
        s.si_edge_mix_rate = f("edge_mix_rate", s.si_edge_mix_rate);
        s.si_dt_days = f("dt_days", s.si_dt_days);
        s.si_terrain_lake_id = i32("terrain_lake_id", s.si_terrain_lake_id);
        s.si_terrain_sea_ice_id = i32("terrain_sea_ice_id", s.si_terrain_sea_ice_id);
        s.si_terrain_ocean_id = i32("terrain_ocean_id", s.si_terrain_ocean_id);
        break;
    default:
        return;
    }
    _production_round_scalar_mask |= pass_bit;
}

} // namespace pk
