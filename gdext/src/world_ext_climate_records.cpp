#include "world_ext.h"
#include "runtime_climate_weather_input.h"
#include "runtime_climate_passes.h"
#include "world_ext_internal.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <chrono>
#include <cmath>
#include <limits>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace pk {

using namespace godot;

// Production climate inputs are captured at their real sync pass boundaries.
// Async task state and workers are owned by world_ext_climate_async.cpp.

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


// ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）─────────────────────
//
// dist：_distribute_weather_field_to_cells C++ 化（任务 4 实装）
// summary：_build_field_summary_fronts C++ 化（任务 7 实装）
//
// 本段（任务 2）只搭骨架：
//   - 注册函数名与签名稳定，让 GDScript 端 has_method + 签名 arg-count
//     检测能识别新方法；
//   - elapsed_ms 返回 -1.0 → caller 永远走 GDScript fallback；
//   - 持久化状态容器先 lazy alloc 占位（任务 7 实装时填）。
// ───────────────────────────────────────────────────────────────────────────

// 内部持久化状态结构（仅 .cpp 可见）已在文件顶部 pk 命名空间声明
// （PrevSummarySeed / WeatherSummaryState）；本匿名 namespace 仅提供 helper。
namespace {

// 取/创建 opaque state（lazy alloc）。caller 不持有所有权。
inline WeatherSummaryState *get_or_create_summary_state(void *&opaque) {
    if (opaque == nullptr) {
        opaque = new WeatherSummaryState();
    }
    return static_cast<WeatherSummaryState *>(opaque);
}

inline void destroy_summary_state(void *&opaque) {
    if (opaque != nullptr) {
        delete static_cast<WeatherSummaryState *>(opaque);
        opaque = nullptr;
    }
}

} // namespace

Dictionary DCWorldExt::run_weather_distribute_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["cover_dirty"] = false;
    out["changed_cells"] = PackedInt32Array();

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_distribute_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return out; }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── SoA slot resolve（一次性查 component_id）────────────────────────
    const int sid_temp        = component_id(StringName("cell_temp"));
    const int sid_moisture    = component_id(StringName("cell_moisture"));
    const int sid_snow_cover  = component_id(StringName("cell_snow_cover"));
    const int sid_snowpack    = component_id(StringName("cell_snowpack"));
    const int sid_water_bal   = component_id(StringName("cell_water_balance_30d"));
    const int sid_soil_moist  = component_id(StringName("cell_soil_moisture"));
    const int sid_heat_input  = component_id(StringName("cell_heat_input"));
    const int sid_cover       = component_id(StringName("cell_cover"));
    const int sid_landform    = component_id(StringName("cell_landform"));
    const int sid_terrain     = component_id(StringName("cell_terrain"));
    const int sid_elevation   = component_id(StringName("cell_elevation"));
    const int sid_w_intens    = component_id(StringName("cell_weather_intensity"));
    const int sid_w_precip    = component_id(StringName("cell_weather_precip"));
    const int sid_w_type      = component_id(StringName("cell_weather_type"));
    const int sid_w_finit     = component_id(StringName("cell_weather_field_init"));
    if (sid_temp     < 0 || sid_moisture  < 0 || sid_snow_cover < 0 ||
        sid_snowpack < 0 || sid_water_bal < 0 || sid_soil_moist < 0 ||
        sid_heat_input < 0 || sid_cover   < 0 ||
        sid_landform < 0 || sid_terrain  < 0 || sid_elevation < 0 || sid_w_intens  < 0 ||
        sid_w_precip < 0 || sid_w_type    < 0 || sid_w_finit   < 0) {
        diag("missing slot id (some weather/cover/landform component not bound)");
        return out;
    }

    // ─── knobs 校验 + 拉取 ──────────────────────────────────────────────
    static const char * const required_keys[] = {
        "n_cells", "snow_min_intensity",
        "snow_freeze_t", "snow_melt_t", "snow_intensity_for_snowing",
        "snow_accum_days_req",
        "flood_heavy_intensity", "flood_heavy_precip",
        "flood_lowland_intensity", "flood_lowland_elev", "flood_lowland_moisture",
        "wt_clear", "cv_snow", "cv_none", "cv_flooding",
        "accumulated_snow_days", "pre_snow_cover",
        "temp_delta_arr", "moisture_delta_arr",
        "can_form_snow_arr", "can_form_flood_arr",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_distribute_pass: missing key '", k, "'");
            return out;
        }
    }

    // 标量收进 POD 结构体。span / band 的下限保护不在这里做 ——
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

    if (n_cells <= 0) { diag("n_cells <= 0"); return out; }
    if (acc_snow_days.size() != n_cells || pre_snow_cover.size() != n_cells) {
        diag("acc_snow_days / pre_snow_cover size != n_cells");
        return out;
    }
    if (temp_delta_arr.size() != 8 || moist_delta_arr.size() != 8 ||
        cfs_arr.size() != 8 || cff_arr.size() != 8) {
        diag("WeatherType profile arrays must be length 8");
        return out;
    }

    // ─── SoA 直接走 _slots[id].arr_f32/arr_u8.ptrw（避免 local copy 触发 CoW
    // detach 把本地数据脱离 _slots）。读端用 ptr() 同样直接走 _slots。
    // 写端最后调 _flush_slot_to_map(sid) 把 CoW-detach 后的新 buffer 推回
    // GDScript MapData property（与 F.1 / F.2 / F.3 等同模式）。──────────────
    Slot &s_temp     = _slots.write[sid_temp];
    Slot &s_moist    = _slots.write[sid_moisture];
    Slot &s_snow_cov = _slots.write[sid_snow_cover];
    Slot &s_snowpack = _slots.write[sid_snowpack];
    Slot &s_waterbal = _slots.write[sid_water_bal];
    Slot &s_soil     = _slots.write[sid_soil_moist];
    const Slot &s_heat = _slots[sid_heat_input];
    Slot &s_cover    = _slots.write[sid_cover];
    const Slot &s_lf       = _slots[sid_landform];
    const Slot &s_terrain  = _slots[sid_terrain];
    const Slot &s_elev     = _slots[sid_elevation];
    const Slot &s_w_int    = _slots[sid_w_intens];
    const Slot &s_w_pre    = _slots[sid_w_precip];
    const Slot &s_w_typ    = _slots[sid_w_type];
    const Slot &s_w_fin    = _slots[sid_w_finit];

    if (s_temp.arr_f32.size() < n_cells || s_moist.arr_f32.size() < n_cells ||
        s_snow_cov.arr_f32.size() < n_cells || s_snowpack.arr_f32.size() < n_cells ||
        s_waterbal.arr_f32.size() < n_cells || s_soil.arr_f32.size() < n_cells ||
        s_heat.arr_f32.size() < n_cells ||
        s_cover.arr_u8.size() < n_cells || s_lf.arr_u8.size() < n_cells ||
        s_terrain.arr_u8.size() < n_cells ||
        s_elev.arr_f32.size() < n_cells || s_w_int.arr_f32.size() < n_cells ||
        s_w_pre.arr_f32.size() < n_cells || s_w_typ.arr_u8.size() < n_cells ||
        s_w_fin.arr_u8.size() < n_cells) {
        diag("SoA size < n_cells");
        return out;
    }

    // ─── ptrw / ptr ────────────────────────────────────────────────────
    // 四张剖面表拷进 knobs：它们是 8 项定长表，进 POD 结构体后 worker 不必再持有
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

    // 数值核心已抽成共享纯内核 pk_async_climate::weather_distribute_pure，那几个
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

    // ─── §11.2 flush：把 CoW-detach 后的 temp/moisture/cover 推回 GDScript
    // MapData property（与 F.1 / F.2 等同模式）。──────────────────────────
    _flush_slot_to_map(sid_temp);
    if (direct_moisture_enabled && !bool(knobs.get("defer_visible_publish", false))) {
        _flush_slot_to_map(sid_moisture);
    }
    _flush_slot_to_map(sid_snow_cover);
    _flush_slot_to_map(sid_snowpack);
    _flush_slot_to_map(sid_water_bal);
    _flush_slot_to_map(sid_soil_moist);
    _flush_slot_to_map(sid_cover);
    out["moisture_written"] = direct_moisture_enabled;

    // ─── 把改写后的 PackedInt32Array 通过 out Dictionary 返回（PackedArray ptrw
    // 触发 CoW 后会重新分配 buffer，本地 acc_snow_days / pre_snow_cover 持有新
    // buffer；knobs Dictionary 里仍是旧 buffer ref。所以必须放进 out 让 caller 取）─
    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed;
    out["cover_dirty"] = cover_dirty;
    out["changed_cells"] = changed_cells;
    out["accumulated_snow_days"] = acc_snow_days;
    out["pre_snow_cover"] = pre_snow_cover;
    return out;
}

Dictionary DCWorldExt::run_weather_summary_fronts_pass(const Dictionary &knobs) {
    using godot::StringName;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    using godot::PackedByteArray;
    using godot::Vector2;

    Dictionary out;
    out["elapsed_ms"] = -1.0;
    out["fronts"] = Array();

    auto diag = [&](const char *why) {
        UtilityFunctions::push_warning(
            "[DCWorldExt] run_weather_summary_fronts_pass: ", why,
            " — fallback to GDScript");
    };

    if (!_bound) { diag("not _bound"); return out; }

    auto t0 = std::chrono::high_resolution_clock::now();

    // ─── knobs ─────────────────────────────────────────────────────────
    static const char * const required_keys[] = {
        "n_cells", "hex_size", "summary_limit",
        "intensity_enter", "intensity_hold",
        "merge_ratio", "merge_max_rounds",
        "radius_base", "radius_scale",
        "wt_clear", "cell_q_arr", "cell_r_arr",
        "neighbor_indices",
    };
    for (const char *k : required_keys) {
        if (!knobs.has(k)) {
            UtilityFunctions::push_warning(
                "[DCWorldExt] run_weather_summary_fronts_pass: missing key '", k, "'");
            return out;
        }
    }

    const int   n_cells          = int(knobs["n_cells"]);
    const float hex_size         = float(knobs["hex_size"]);
    const int   summary_limit    = int(knobs["summary_limit"]);
    const float intensity_enter  = float(knobs["intensity_enter"]);
    const float intensity_hold   = float(knobs["intensity_hold"]);
    const float merge_ratio      = float(knobs["merge_ratio"]);
    const int   merge_max_rounds = int(knobs["merge_max_rounds"]);
    const float radius_base      = float(knobs["radius_base"]);
    const float radius_scale     = float(knobs["radius_scale"]);
    const int   wt_clear         = int(knobs["wt_clear"]);
    PackedInt32Array cell_q = knobs["cell_q_arr"];
    PackedInt32Array cell_r = knobs["cell_r_arr"];

    if (n_cells <= 0) { diag("n_cells <= 0"); return out; }
    if (cell_q.size() != n_cells || cell_r.size() != n_cells) {
        diag("cell_q_arr / cell_r_arr size mismatch");
        return out;
    }

    // ─── SoA slot resolve ──────────────────────────────────────────────
    const int sid_w_intens  = component_id(StringName("cell_weather_intensity"));
    const int sid_w_precip  = component_id(StringName("cell_weather_precip"));
    const int sid_w_type    = component_id(StringName("cell_weather_type"));
    const int sid_w_cloud   = component_id(StringName("cell_weather_cloud"));
    const int sid_w_finit   = component_id(StringName("cell_weather_field_init"));
    const int sid_wind_x    = component_id(StringName("cell_wind_x"));
    const int sid_wind_y    = component_id(StringName("cell_wind_y"));
    const int sid_temp      = component_id(StringName("cell_temp"));
    if (sid_w_intens < 0 || sid_w_precip < 0 || sid_w_type < 0 ||
        sid_w_cloud  < 0 || sid_w_finit  < 0 || sid_wind_x < 0 || sid_wind_y < 0 ||
        sid_temp < 0) {
        diag("missing slot id (weather_*/wind_x/wind_y/cell_temp)");
        return out;
    }
    const Slot &s_w_int   = _slots[sid_w_intens];
    const Slot &s_w_pre   = _slots[sid_w_precip];
    const Slot &s_w_typ   = _slots[sid_w_type];
    const Slot &s_w_cloud = _slots[sid_w_cloud];
    const Slot &s_w_fin   = _slots[sid_w_finit];
    const Slot &s_wind_x  = _slots[sid_wind_x];
    const Slot &s_wind_y  = _slots[sid_wind_y];
    const Slot &s_temp    = _slots[sid_temp];
    if (s_w_int.arr_f32.size()  < n_cells || s_w_pre.arr_f32.size() < n_cells ||
        s_w_typ.arr_u8.size()   < n_cells || s_w_cloud.arr_f32.size() < n_cells ||
        s_w_fin.arr_u8.size()   < n_cells || s_wind_x.arr_f32.size() < n_cells ||
        s_wind_y.arr_f32.size() < n_cells || s_temp.arr_f32.size() < n_cells) {
        diag("SoA size < n_cells");
        return out;
    }
    const float * const __restrict WI    = s_w_int.arr_f32.ptr();
    const float * const __restrict WP    = s_w_pre.arr_f32.ptr();
    const uint8_t * const __restrict WT_ = s_w_typ.arr_u8.ptr();
    const float * const __restrict WCL   = s_w_cloud.arr_f32.ptr();
    const uint8_t * const __restrict WFI = s_w_fin.arr_u8.ptr();
    const float * const __restrict WX    = s_wind_x.arr_f32.ptr();
    const float * const __restrict WY    = s_wind_y.arr_f32.ptr();
    const float * const __restrict T     = s_temp.arr_f32.ptr();

    // ─── neighbor_indices (n_cells*6, -1 = no neighbor) ────────────────
    PackedInt32Array nb_arr = knobs["neighbor_indices"];
    if (nb_arr.size() < n_cells * 6) {
        diag("neighbor_indices size < n_cells*6");
        return out;
    }
    const int32_t * const __restrict NB = nb_arr.ptr();

    // ─── q/r → idx hash (lazy rebuild on size change) ──────────────────
    if (_summary_qr_to_idx_size != n_cells) {
        _summary_qr_to_idx.clear();
        _summary_qr_to_idx.reserve(n_cells * 2);
        for (int i = 0; i < n_cells; ++i) {
            const int64_t key = (int64_t(cell_q[i]) << 32) ^
                                (uint32_t(cell_r[i]) & 0xFFFFFFFFu);
            _summary_qr_to_idx[key] = i;
        }
        _summary_qr_to_idx_size = n_cells;
    }
    auto cube_to_idx = [&](int q, int r) -> int {
        const int64_t key = (int64_t(q) << 32) ^ (uint32_t(r) & 0xFFFFFFFFu);
        auto it = _summary_qr_to_idx.find(key);
        return (it == _summary_qr_to_idx.end()) ? -1 : it->second;
    };
    // Pointy-top hex 屏幕坐标（与 hex_utils.gd 严格同源）
    const double SQRT3 = 1.7320508075688772;
    auto cube_to_world_xy = [&](int q, int r) -> Vector2 {
        const double x = double(hex_size) * SQRT3 * (double(q) + double(r) * 0.5);
        const double y = double(hex_size) * 1.5 * double(r);
        return Vector2(float(x), float(y));
    };
    auto world_to_cube_idx = [&](Vector2 p) -> int {
        const double q_f = (SQRT3 / 3.0 * double(p.x) - 1.0 / 3.0 * double(p.y)) / double(hex_size);
        const double r_f = (2.0 / 3.0 * double(p.y)) / double(hex_size);
        const double s_f = -q_f - r_f;
        // _cube_round
        int rq = int(std::lround(q_f));
        int rr = int(std::lround(r_f));
        int rs = int(std::lround(s_f));
        const double dq = std::abs(double(rq) - q_f);
        const double dr = std::abs(double(rr) - r_f);
        const double ds = std::abs(double(rs) - s_f);
        if (dq > dr && dq > ds) {
            rq = -rr - rs;
        } else if (dr > ds) {
            rr = -rq - rs;
        }
        return cube_to_idx(rq, rr);
    };
    auto neighbor_aligned_idx = [&](int idx, float dir_x, float dir_y) -> int {
        const float len2 = dir_x * dir_x + dir_y * dir_y;
        if (idx < 0 || idx >= n_cells || len2 <= 0.0001f) {
            return -1;
        }
        const float inv_len = 1.0f / std::sqrt(len2);
        const float nx = dir_x * inv_len;
        const float ny = dir_y * inv_len;
        const Vector2 self_wp = cube_to_world_xy(cell_q[idx], cell_r[idx]);
        float best_dot = hex_size * 0.31176915f;
        int best_idx = -1;
        const int32_t *nb_row = NB + idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb = nb_row[d];
            if (nb < 0 || nb >= n_cells) continue;
            const Vector2 nb_wp = cube_to_world_xy(cell_q[nb], cell_r[nb]);
            const Vector2 to_nb = nb_wp - self_wp;
            const float dot = to_nb.x * nx + to_nb.y * ny;
            if (dot > best_dot) {
                best_dot = dot;
                best_idx = nb;
            }
        }
        return best_idx;
    };
    auto front_diag_kind = [](float temp_adv) -> int {
        constexpr float FRONT_TEMP_ADVECTION_THRESHOLD = 0.015f;
        if (temp_adv > FRONT_TEMP_ADVECTION_THRESHOLD) return 1;
        if (temp_adv < -FRONT_TEMP_ADVECTION_THRESHOLD) return 2;
        return 0;
    };

    // ─── opaque state ──────────────────────────────────────────────────
    auto *summary_state = get_or_create_summary_state(_summary_state);
    std::vector<PrevSummarySeed> &prev_seeds = summary_state->prev_seeds;
    std::vector<int32_t> &prev_membership = summary_state->prev_membership;
    if (int(prev_membership.size()) != n_cells) {
        prev_membership.assign(n_cells, -1);
    }

    // ─── 工作结构 ──────────────────────────────────────────────────────
    struct Comp {
        int   type;
        Vector2 sum_pos;       // build 时 / sum_pos*count
        Vector2 sum_axis;
        float sum_cloud;
        float sum_precip;
        float sum_temp_adv;
        float temp_adv_weight;
        float max_intensity;
        float area;            // 用 float 因为 merge 后会聚合权重
        int   inherited_age;   // -1 表示 step 2 新生
        bool  has_inherited_center;
        Vector2 inherited_from_center;
        Vector2 inherited_from_velocity;
    };
    std::vector<Comp> comps;
    comps.reserve(64);

    std::vector<uint8_t> visited(n_cells, 0);
    std::vector<int32_t> new_membership(n_cells, -1);

    auto threshold_for = [&](int idx) -> float {
        return prev_membership[idx] >= 0 ? intensity_hold : intensity_enter;
    };
    auto cell_wt = [&](int idx) -> int {
        return WFI[idx] != 0 ? int(WT_[idx]) : wt_clear;
    };
    auto cell_intensity = [&](int idx) -> float {
        return WFI[idx] != 0 ? WI[idx] : 0.0f;
    };

    // BFS flood-fill：返回新增 component idx，cells 为空则不入。
    std::vector<int32_t> bfs_queue;
    bfs_queue.reserve(256);
    auto flood_fill = [&](int seed, int wt, int cluster_idx) -> bool {
        bfs_queue.clear();
        bfs_queue.push_back(seed);
        visited[seed] = 1;
        Comp comp;
        comp.type = wt;
        comp.sum_pos = Vector2();
        comp.sum_axis = Vector2();
        comp.sum_cloud = 0.0f;
        comp.sum_precip = 0.0f;
        comp.sum_temp_adv = 0.0f;
        comp.temp_adv_weight = 0.0f;
        comp.max_intensity = 0.0f;
        comp.area = 0.0f;
        comp.inherited_age = 0;
        comp.has_inherited_center = false;
        size_t qi = 0;
        while (qi < bfs_queue.size()) {
            int idx = bfs_queue[qi++];
            const int cwt = cell_wt(idx);
            const float ci = cell_intensity(idx);
            const float thresh_self = threshold_for(idx);
            if (cwt != wt || ci < thresh_self) {
                continue;
            }
            // 加入 cluster
            new_membership[idx] = cluster_idx;
            comp.sum_pos += cube_to_world_xy(cell_q[idx], cell_r[idx]);
            comp.sum_axis += Vector2(WX[idx], WY[idx]);
            comp.sum_cloud += WCL[idx];
            comp.sum_precip += WP[idx];
            const float wx = WX[idx];
            const float wy = WY[idx];
            if ((wx * wx + wy * wy) > 0.0001f) {
                const int upstream = neighbor_aligned_idx(idx, -wx, -wy);
                const int downstream = neighbor_aligned_idx(idx, wx, wy);
                if (downstream >= 0) {
                    const float upstream_temp = (upstream >= 0) ? T[upstream] : T[idx];
                    const float local_adv = upstream_temp - T[downstream];
                    comp.sum_temp_adv += local_adv * ci;
                    comp.temp_adv_weight += ci;
                }
            }
            if (ci > comp.max_intensity) comp.max_intensity = ci;
            comp.area += 1.0f;
            // 邻居
            const int32_t *nb_row = NB + idx * 6;
            for (int d = 0; d < 6; ++d) {
                const int32_t nb = nb_row[d];
                if (nb < 0 || visited[nb]) continue;
                const int nwt = cell_wt(nb);
                const float ni = cell_intensity(nb);
                const float thresh_nb = threshold_for(nb);
                if (nwt == wt && ni >= thresh_nb) {
                    visited[nb] = 1;
                    bfs_queue.push_back(nb);
                }
            }
        }
        if (comp.area <= 0.0f) {
            return false;
        }
        comp.sum_pos = comp.sum_pos / comp.area;
        comp.sum_axis = comp.sum_axis / comp.area;
        comp.sum_cloud /= comp.area;
        comp.sum_precip /= comp.area;
        comp.sum_temp_adv /= std::max(comp.temp_adv_weight, 0.001f);
        comps.push_back(comp);
        return true;
    };

    // ─── Step 1：prev seeds 优先（按 area 降序，与 GDScript 一致）──────
    std::vector<size_t> seed_order(prev_seeds.size());
    for (size_t i = 0; i < seed_order.size(); ++i) seed_order[i] = i;
    std::sort(seed_order.begin(), seed_order.end(), [&](size_t a, size_t b) {
        return prev_seeds[a].area > prev_seeds[b].area;
    });
    auto pick_inheritance_seed = [&](int seed_idx, int prev_type) -> int {
        // 1. seed_idx 本身可用？
        if (!visited[seed_idx]) {
            const int swt = cell_wt(seed_idx);
            const float si = cell_intensity(seed_idx);
            const float s_thresh = threshold_for(seed_idx);
            if (swt == prev_type && si >= s_thresh) return seed_idx;
        }
        // 2. 1-ring 邻居
        const int32_t *nb_row = NB + seed_idx * 6;
        for (int d = 0; d < 6; ++d) {
            const int32_t nb = nb_row[d];
            if (nb < 0 || visited[nb]) continue;
            const int nwt = cell_wt(nb);
            const float ni = cell_intensity(nb);
            const float thresh_nb = threshold_for(nb);
            if (nwt == prev_type && ni >= thresh_nb) return nb;
        }
        return -1;
    };
    for (size_t k : seed_order) {
        const PrevSummarySeed &ps = prev_seeds[k];
        const int seed_idx = world_to_cube_idx(Vector2(ps.center_x, ps.center_y));
        if (seed_idx < 0) continue;
        const int picked = pick_inheritance_seed(seed_idx, ps.type);
        if (picked < 0) continue;
        const int cluster_idx = int(comps.size());
        if (flood_fill(picked, ps.type, cluster_idx)) {
            Comp &c = comps.back();
            c.inherited_age = ps.age + 1;
            c.has_inherited_center = true;
            c.inherited_from_center = Vector2(ps.center_x, ps.center_y);
            c.inherited_from_velocity = Vector2(ps.velocity_x, ps.velocity_y);
        }
    }

    // ─── Step 2：剩余 cell 自起新 cluster ─────────────────────────────
    for (int i = 0; i < n_cells; ++i) {
        if (visited[i]) continue;
        const int wt = cell_wt(i);
        const float ci = cell_intensity(i);
        const float thresh = threshold_for(i);
        if (ci < thresh || wt == wt_clear) {
            visited[i] = 1;
            continue;
        }
        const int cluster_idx = int(comps.size());
        if (flood_fill(i, wt, cluster_idx)) {
            comps.back().inherited_age = 0;
        }
    }

    // 跨 tick 状态：在 merge 之前记录 cell→cluster 归属（与 GDScript 一致）。
    prev_membership = new_membership;

    // ─── Step 3：merge_nearby_components ───────────────────────────────
    auto eq_radius = [&](float area) -> float {
        return hex_size * std::sqrt(std::max(area, 1.0f)) * radius_scale;
    };
    bool changed = true;
    int rounds = 0;
    while (changed && rounds < merge_max_rounds) {
        changed = false;
        rounds += 1;
        const int n = int(comps.size());
        std::vector<int32_t> merged_into(n, -1);
        for (int i = 0; i < n; ++i) {
            if (merged_into[i] >= 0) continue;
            float ai = comps[i].area;
            float ri = eq_radius(ai);
            Vector2 ci_center = comps[i].sum_pos;
            const int type_i = comps[i].type;
            for (int j = i + 1; j < n; ++j) {
                if (merged_into[j] >= 0) continue;
                if (comps[j].type != type_i) continue;
                const float aj = comps[j].area;
                const float rj = eq_radius(aj);
                const Vector2 cj_center = comps[j].sum_pos;
                const float dist = ci_center.distance_to(cj_center);
                if (dist > (ri + rj) * merge_ratio) continue;
                // merge j → i
                const float total = ai + aj;
                comps[i].sum_pos = (ci_center * ai + cj_center * aj) / total;
                comps[i].sum_axis = (comps[i].sum_axis * ai + comps[j].sum_axis * aj) / total;
                comps[i].sum_cloud = (comps[i].sum_cloud * ai + comps[j].sum_cloud * aj) / total;
                comps[i].sum_precip = (comps[i].sum_precip * ai + comps[j].sum_precip * aj) / total;
                comps[i].sum_temp_adv = (comps[i].sum_temp_adv * ai + comps[j].sum_temp_adv * aj) / total;
                comps[i].max_intensity = std::max(comps[i].max_intensity, comps[j].max_intensity);
                comps[i].area = total;
                comps[i].inherited_age = std::max(comps[i].inherited_age, comps[j].inherited_age);
                // GDScript 用先合的"老" component 保留 inherited_from_*；这里保持 i 的字段不动
                // （与 GDScript 同：i 在前，j 在后，j 被吸收到 i）。
                ai = total;
                ri = eq_radius(ai);
                ci_center = comps[i].sum_pos;
                merged_into[j] = i;
                changed = true;
            }
        }
        if (changed) {
            std::vector<Comp> next;
            next.reserve(comps.size());
            for (int i = 0; i < n; ++i) {
                if (merged_into[i] < 0) next.push_back(std::move(comps[i]));
            }
            comps = std::move(next);
        }
    }

    // ─── Step 4：score 排序 + top-N + build front Dictionary ──────────
    auto score_of = [](const Comp &c) -> float {
        return c.max_intensity * std::sqrt(std::max(c.area, 1.0f));
    };
    std::sort(comps.begin(), comps.end(), [&](const Comp &a, const Comp &b) {
        return score_of(a) > score_of(b);
    });
    const int limit = std::min(summary_limit, int(comps.size()));
    Array fronts_out;
    fronts_out.resize(limit);
    std::vector<PrevSummarySeed> next_seeds;
    next_seeds.reserve(limit);

    // ─── Phase A.1 fronts zero-copy SoA：与 fronts 数组并存输出 ─────
    // 字段命名严格沿用 scripts/data_core/fronts_schema.gd FRONTS_SCHEMA cpp_name
    // 共 23 列：18 F32 + 4 I32 + 1 U8。所有列长度=limit，按 idx 与 fronts_out[i]
    // 1:1 对齐。GDScript 端 _unpack_summary_soa_to_fronts 走列扫描，跨语言
    // Variant entry 从 ~17*N → ~24 ref（与 N 无关），marshalling ~90% 削减。
    PackedFloat32Array soa_center_x;        soa_center_x.resize(limit);
    PackedFloat32Array soa_center_y;        soa_center_y.resize(limit);
    PackedFloat32Array soa_radius;          soa_radius.resize(limit);
    PackedFloat32Array soa_velocity_x;      soa_velocity_x.resize(limit);
    PackedFloat32Array soa_velocity_y;      soa_velocity_y.resize(limit);
    PackedFloat32Array soa_axis_x;          soa_axis_x.resize(limit);
    PackedFloat32Array soa_axis_y;          soa_axis_y.resize(limit);
    PackedFloat32Array soa_stable_axis_x;   soa_stable_axis_x.resize(limit);
    PackedFloat32Array soa_stable_axis_y;   soa_stable_axis_y.resize(limit);
    PackedFloat32Array soa_major_scale;     soa_major_scale.resize(limit);
    PackedFloat32Array soa_minor_scale;     soa_minor_scale.resize(limit);
    PackedFloat32Array soa_edge_seed;       soa_edge_seed.resize(limit);
    PackedFloat32Array soa_intensity;       soa_intensity.resize(limit);
    PackedFloat32Array soa_decay_per_day;   soa_decay_per_day.resize(limit);
    PackedFloat32Array soa_life_progress;   soa_life_progress.resize(limit);
    PackedFloat32Array soa_cloud_amount;    soa_cloud_amount.resize(limit);
    PackedFloat32Array soa_precip_amount;   soa_precip_amount.resize(limit);
    PackedFloat32Array soa_dissolve_amount; soa_dissolve_amount.resize(limit);
    PackedFloat32Array soa_temp_advection;  soa_temp_advection.resize(limit);
    PackedInt32Array   soa_type;            soa_type.resize(limit);
    PackedInt32Array   soa_ttl_days;        soa_ttl_days.resize(limit);
    PackedInt32Array   soa_age_days;        soa_age_days.resize(limit);
    PackedInt32Array   soa_world_idx;       soa_world_idx.resize(limit);
    PackedInt32Array   soa_diag_kind;       soa_diag_kind.resize(limit);
    PackedByteArray    soa_alive;           soa_alive.resize(limit);
    float *p_center_x = soa_center_x.ptrw();
    float *p_center_y = soa_center_y.ptrw();
    float *p_radius = soa_radius.ptrw();
    float *p_velocity_x = soa_velocity_x.ptrw();
    float *p_velocity_y = soa_velocity_y.ptrw();
    float *p_axis_x = soa_axis_x.ptrw();
    float *p_axis_y = soa_axis_y.ptrw();
    float *p_stable_axis_x = soa_stable_axis_x.ptrw();
    float *p_stable_axis_y = soa_stable_axis_y.ptrw();
    float *p_major_scale = soa_major_scale.ptrw();
    float *p_minor_scale = soa_minor_scale.ptrw();
    float *p_edge_seed = soa_edge_seed.ptrw();
    float *p_intensity = soa_intensity.ptrw();
    float *p_decay_per_day = soa_decay_per_day.ptrw();
    float *p_life_progress = soa_life_progress.ptrw();
    float *p_cloud_amount = soa_cloud_amount.ptrw();
    float *p_precip_amount = soa_precip_amount.ptrw();
    float *p_dissolve_amount = soa_dissolve_amount.ptrw();
    float *p_temp_advection = soa_temp_advection.ptrw();
    int32_t *p_type = soa_type.ptrw();
    int32_t *p_ttl_days = soa_ttl_days.ptrw();
    int32_t *p_age_days = soa_age_days.ptrw();
    int32_t *p_world_idx = soa_world_idx.ptrw();
    int32_t *p_diag_kind = soa_diag_kind.ptrw();
    uint8_t *p_alive = soa_alive.ptrw();

    for (int i = 0; i < limit; ++i) {
        const Comp &c = comps[i];
        Dictionary fd;
        fd["type"] = int(c.type);
        fd["center"] = c.sum_pos;
        const float intensity = std::clamp(c.max_intensity, 0.0f, 1.0f);
        fd["intensity"] = intensity;
        const float area = std::max(c.area, 1.0f);
        const float radius = hex_size * (radius_base + std::sqrt(area) * radius_scale);
        fd["radius"] = radius;
        Vector2 axis_v = c.sum_axis;
        if (axis_v.length_squared() <= 0.0001f) {
            axis_v = Vector2(1.0f, 0.0f);
        }
        const Vector2 axis = axis_v.normalized();
        fd["axis"] = axis;
        fd["stable_axis"] = axis;
        // velocity = (inherited 模式) EMA(prev_velocity, observed_drift, 0.5)
        //            (新生 模式)     axis * radius * 0.4
        Vector2 measured_velocity = axis * radius * 0.4f;
        if (c.has_inherited_center) {
            Vector2 observed_drift = c.sum_pos - c.inherited_from_center;
            const float max_drift = radius * 0.6f;
            if (observed_drift.length() > max_drift) {
                observed_drift = observed_drift.normalized() * max_drift;
            }
            measured_velocity = c.inherited_from_velocity.lerp(observed_drift, 0.5f);
        }
        fd["velocity"] = measured_velocity;
        fd["major_scale"] = 1.30f;
        fd["minor_scale"] = 0.85f;
        const int inherited_age = std::max(c.inherited_age, 0);
        fd["age_days"] = inherited_age;
        const int ttl_days_v = std::max(inherited_age * 3 + 12, 12);
        fd["ttl_days"] = ttl_days_v;
        fd["decay_per_day"] = 0.0f;
        // edge_seed = (i+1)*37 + int(center.x)*3 + int(center.y)*5
        const float edge_seed = float((i + 1) * 37 +
                                       int(c.sum_pos.x) * 3 +
                                       int(c.sum_pos.y) * 5);
        fd["edge_seed"] = edge_seed;
        const float cloud_amount = std::clamp(c.sum_cloud, 0.0f, 1.0f);
        const float precip_amount = std::clamp(c.sum_precip, 0.0f, 1.0f);
        fd["cloud_amount"] = cloud_amount;
        fd["precip_amount"] = precip_amount;
        fd["dissolve_amount"] = 0.0f;
        // life_progress = clamp(0.15 + age*0.08, 0.15, 0.45)
        const float life_progress = std::clamp(0.15f + float(inherited_age) * 0.08f, 0.15f, 0.45f);
        fd["life_progress"] = life_progress;
        const float temp_advection = c.sum_temp_adv;
        const int diag_kind = front_diag_kind(temp_advection);
        fd["front_temperature_advection"] = temp_advection;
        fd["front_diagnostic_kind"] = diag_kind;
        fronts_out[i] = fd;

        // ─── SoA 镜像写入（与 fd 同语义/同步序）──
        // alive 与 WeatherFront::is_alive() 等价：intensity > 0.01 && age_days < ttl_days
        p_center_x[i]        = c.sum_pos.x;
        p_center_y[i]        = c.sum_pos.y;
        p_radius[i]          = radius;
        p_velocity_x[i]      = measured_velocity.x;
        p_velocity_y[i]      = measured_velocity.y;
        p_axis_x[i]          = axis.x;
        p_axis_y[i]          = axis.y;
        p_stable_axis_x[i]   = axis.x;
        p_stable_axis_y[i]   = axis.y;
        p_major_scale[i]     = 1.30f;
        p_minor_scale[i]     = 0.85f;
        p_edge_seed[i]       = edge_seed;
        p_intensity[i]       = intensity;
        p_decay_per_day[i]   = 0.0f;
        p_life_progress[i]   = life_progress;
        p_cloud_amount[i]    = cloud_amount;
        p_precip_amount[i]   = precip_amount;
        p_dissolve_amount[i] = 0.0f;
        p_temp_advection[i]  = temp_advection;
        p_type[i]            = int32_t(c.type);
        p_ttl_days[i]        = int32_t(ttl_days_v);
        p_age_days[i]        = int32_t(inherited_age);
        p_world_idx[i]       = -1;  // 由 sync job 后续填写
        p_diag_kind[i]       = int32_t(diag_kind);
        p_alive[i]           = (intensity > 0.01f && inherited_age < ttl_days_v) ? uint8_t(1) : uint8_t(0);

        // next_seeds
        PrevSummarySeed ns;
        ns.type = c.type;
        ns.center_x = c.sum_pos.x;
        ns.center_y = c.sum_pos.y;
        ns.age = inherited_age;
        ns.area = int(area);
        ns.velocity_x = measured_velocity.x;
        ns.velocity_y = measured_velocity.y;
        next_seeds.push_back(ns);
    }
    prev_seeds = std::move(next_seeds);

    auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["elapsed_ms"] = elapsed;
    out["fronts"] = fronts_out;

    // ─── Phase A.1：填 fronts_soa Dictionary 并挂回 out ─────────
    Dictionary soa;
    soa["n_fronts"] = limit;
    soa["front_center_x"]        = soa_center_x;
    soa["front_center_y"]        = soa_center_y;
    soa["front_radius"]          = soa_radius;
    soa["front_velocity_x"]      = soa_velocity_x;
    soa["front_velocity_y"]      = soa_velocity_y;
    soa["front_axis_x"]          = soa_axis_x;
    soa["front_axis_y"]          = soa_axis_y;
    soa["front_stable_axis_x"]   = soa_stable_axis_x;
    soa["front_stable_axis_y"]   = soa_stable_axis_y;
    soa["front_major_scale"]     = soa_major_scale;
    soa["front_minor_scale"]     = soa_minor_scale;
    soa["front_edge_seed"]       = soa_edge_seed;
    soa["front_intensity"]       = soa_intensity;
    soa["front_decay_per_day"]   = soa_decay_per_day;
    soa["front_life_progress"]   = soa_life_progress;
    soa["front_cloud_amount"]    = soa_cloud_amount;
    soa["front_precip_amount"]   = soa_precip_amount;
    soa["front_dissolve_amount"] = soa_dissolve_amount;
    soa["front_temperature_advection"] = soa_temp_advection;
    soa["front_type"]            = soa_type;
    soa["front_ttl_days"]        = soa_ttl_days;
    soa["front_age_days"]        = soa_age_days;
    soa["front_world_idx"]       = soa_world_idx;
    soa["front_diagnostic_kind"] = soa_diag_kind;
    soa["front_alive"]           = soa_alive;
    out["fronts_soa"] = soa;
    return out;
}

void DCWorldExt::reset_weather_summary_state() {
    if (_summary_state == nullptr) {
        return;
    }
    auto *s = static_cast<WeatherSummaryState *>(_summary_state);
    s->prev_seeds.clear();
    s->prev_membership.clear();
}

void DCWorldExt::snapshot_weather_summary_state() {
    auto *src = get_or_create_summary_state(_summary_state);
    auto *dst = get_or_create_summary_state(_summary_state_snapshot);
    dst->prev_seeds = src->prev_seeds;
    dst->prev_membership = src->prev_membership;
}

void DCWorldExt::restore_weather_summary_state() {
    if (_summary_state_snapshot == nullptr) {
        return;
    }
    auto *src = static_cast<WeatherSummaryState *>(_summary_state_snapshot);
    auto *dst = get_or_create_summary_state(_summary_state);
    dst->prev_seeds = src->prev_seeds;
    dst->prev_membership = src->prev_membership;
}

} // namespace pk
