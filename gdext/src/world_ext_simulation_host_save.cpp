#include "world_ext.h"
#include "runtime_climate_weather_input.h"
#include "native_simulation_host.h"
#include "native_parallel_executor.h"
#include "runtime_domain_pod.h"
#include "runtime_country_pod.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "runtime_protocol_guard.h"
#include "runtime_ideology_pod.h"
#include "runtime_economy_pod.h"
#include "economy_graph_kernels.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "metric_mask_tests.h"
#include "runtime_switch_registry.h"
#include "world_ext_simulation_host_internal.h"
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace pk {

using namespace godot;

Dictionary DCWorldExt::capture_runtime_inputs(const Dictionary &inputs) {
    SimTraceWriteGuard sim_trace_guard{this, "capture_runtime_inputs"};
    // 捕获边界计时：调用方（内联日）用它在同一帧里把"捕获 + 12 域 +
    // 其余 GDScript"拆开。RAII 保证所有 return 分支都记上。
    const auto capture_started = std::chrono::steady_clock::now();
    struct CaptureTimer {
        std::chrono::steady_clock::time_point started;
        double &slot;
        ~CaptureTimer() {
            slot = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - started).count();
        }
    } capture_timer{capture_started, _inline_capture_ms};
    Dictionary out;
    _climate_physics_capture_ready = false;
    if (!_runtime_host) {
        // Capture is intentionally legal before start: generation bootstrap
        // freezes the native input boundary, then STARTING consumes it.
        _runtime_host = std::make_unique<NativeSimulationHost>();
    }
    RuntimeEnvironmentSnapshot snapshot;
    const auto read_i64 = [&inputs](const char *key, int64_t fallback,
                                    int64_t &value) -> bool {
        if (!inputs.has(key)) {
            value = fallback;
            return true;
        }
        const Variant raw = inputs[key];
        if (raw.get_type() != Variant::INT) return false;
        value = static_cast<int64_t>(raw);
        return true;
    };
    const auto read_f64 = [&inputs](const char *key, double fallback,
                                    double &value) -> bool {
        if (!inputs.has(key)) {
            value = fallback;
            return true;
        }
        const Variant raw = inputs[key];
        if (raw.get_type() != Variant::INT && raw.get_type() != Variant::FLOAT)
            return false;
        value = static_cast<double>(raw);
        return true;
    };
    const auto read_bool = [&inputs](const char *key, bool fallback,
                                     bool &value) -> bool {
        if (!inputs.has(key)) {
            value = fallback;
            return true;
        }
        const Variant raw = inputs[key];
        if (raw.get_type() != Variant::BOOL) return false;
        value = static_cast<bool>(raw);
        return true;
    };
    int64_t generation = 0;
    int64_t day = 0;
    int64_t vision_revision = 0;
    int64_t topology_generation = 0;
    int64_t climate_catalog_abi = RUNTIME_DOMAIN_POD_ABI_VERSION;
    int64_t climate_catalog_hash = 0;
    int64_t climate_map_width = 0;
    int64_t climate_map_height = 0;
    double dt_days = 1.0;
    if (inputs.has("generation") && inputs["generation"].get_type() != Variant::INT) {
        out["ok"] = false;
        out["code"] = "invalid_runtime_input_generation";
        return out;
    }
    if (!read_i64("generation", 0, generation) ||
        !read_i64("day", 0, day) ||
        !read_i64("vision_revision", 0, vision_revision) ||
        !read_i64("topology_generation", 0, topology_generation) ||
        !read_i64("climate_catalog_abi_version", RUNTIME_DOMAIN_POD_ABI_VERSION, climate_catalog_abi) ||
        !read_i64("climate_catalog_hash", 0, climate_catalog_hash) ||
        !read_i64("climate_map_width", 0, climate_map_width) ||
        !read_i64("climate_map_height", 0, climate_map_height) ||
        !read_f64("dt_days", 1.0, dt_days) ||
        !read_f64("season_phase", 0.0, snapshot.season_phase) ||
        !read_f64("climate_anomaly", 0.0, snapshot.climate_anomaly) ||
        !read_bool("fog_solved", false, snapshot.fog_solved) ||
        generation < 0 || day < 0 || vision_revision < 0 || topology_generation < 0 ||
        climate_catalog_abi < 0 || climate_catalog_hash < 0 ||
        climate_map_width < 0 || climate_map_height < 0 ||
        climate_catalog_abi > std::numeric_limits<uint32_t>::max() ||
        climate_catalog_hash > std::numeric_limits<uint64_t>::max() ||
        climate_map_width > std::numeric_limits<uint32_t>::max() ||
        climate_map_height > std::numeric_limits<uint32_t>::max() ||
        !std::isfinite(dt_days) || dt_days <= 0.0 || dt_days > 365.0) {
        out["ok"] = false;
        out["code"] = "invalid_runtime_input_value";
        return out;
    }
    snapshot.generation = static_cast<uint64_t>(generation);
    snapshot.day = day;
    snapshot.vision_revision = static_cast<uint64_t>(vision_revision);
    snapshot.topology_generation = static_cast<uint64_t>(topology_generation);
    snapshot.climate_catalog_abi_version = static_cast<uint32_t>(climate_catalog_abi);
    snapshot.climate_catalog_hash = static_cast<uint64_t>(climate_catalog_hash);
    snapshot.climate_map_width = static_cast<uint32_t>(climate_map_width);
    snapshot.climate_map_height = static_cast<uint32_t>(climate_map_height);
    snapshot.dt_days = static_cast<float>(dt_days);
    if (!read_bool("climate_input_complete", false,
                   snapshot.climate_input_complete)) {
        out["ok"] = false;
        out["code"] = "invalid_runtime_input_value";
        return out;
    }
    if (!std::isfinite(snapshot.season_phase) || !std::isfinite(snapshot.climate_anomaly) ||
        snapshot.day < 0) {
        out["ok"] = false;
        out["code"] = "invalid_runtime_input_value";
        return out;
    }
    auto copy_f32 = [&](const char *key, std::vector<float> &dst) -> bool {
        if (!inputs.has(key)) { dst.clear(); return true; }
        const Variant raw = inputs[key];
        if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) return false;
        const PackedFloat32Array values = raw;
        dst.clear();
        if (values.size() > 0) dst.assign(values.ptr(), values.ptr() + values.size());
        for (float value : dst) if (!std::isfinite(value)) return false;
        return true;
    };
    auto copy_i32 = [&](const char *key, std::vector<int32_t> &dst) -> bool {
        if (!inputs.has(key)) { dst.clear(); return true; }
        const Variant raw = inputs[key];
        if (raw.get_type() != Variant::PACKED_INT32_ARRAY) return false;
        const PackedInt32Array values = raw;
        dst.clear();
        if (values.size() > 0) dst.assign(values.ptr(), values.ptr() + values.size());
        return true;
    };
    auto copy_u8 = [&](const char *key, std::vector<uint8_t> &dst) -> bool {
        if (!inputs.has(key)) { dst.clear(); return true; }
        const Variant raw = inputs[key];
        if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) return false;
        const PackedByteArray values = raw;
        dst.clear();
        if (values.size() > 0) dst.assign(values.ptr(), values.ptr() + values.size());
        return true;
    };
    if (!copy_f32("cell_temp", snapshot.cell_temp) ||
        !copy_f32("cell_temp_30d", snapshot.cell_temp_30d) ||
        !copy_f32("cell_temp_365d", snapshot.cell_temp_365d) ||
        !copy_f32("cell_temp_baseline_year", snapshot.cell_temp_baseline_year) ||
        !copy_f32("cell_base_moisture", snapshot.cell_base_moisture) ||
        !copy_f32("cell_moisture", snapshot.cell_moisture) ||
        !copy_f32("cell_plant_available_water", snapshot.cell_plant_available_water) ||
        !copy_f32("cell_soil_moisture", snapshot.cell_soil_moisture) ||
        !copy_f32("cell_water_balance_30d", snapshot.cell_water_balance_30d) ||
        !copy_f32("cell_weather_precip", snapshot.cell_weather_precip) ||
        !copy_f32("cell_snow_cover", snapshot.cell_snow_cover) ||
        !copy_f32("cell_weather_intensity", snapshot.cell_weather_intensity) ||
        !copy_f32("cell_weather_vapor", snapshot.cell_weather_vapor) ||
        !copy_f32("cell_weather_cloud_water", snapshot.cell_weather_cloud_water) ||
        !copy_f32("cell_weather_cloud", snapshot.cell_weather_cloud) ||
        !copy_u8("cell_weather_type", snapshot.cell_weather_type) ||
        !copy_u8("cell_weather_transition", snapshot.cell_weather_transition) ||
        !copy_f32("cell_sea_ice_frac_prev", snapshot.cell_sea_ice_frac_prev) ||
        !copy_f32("cell_river_discharge_30d", snapshot.cell_river_discharge_30d) ||
        !copy_f32("cell_vegetation_vitality", snapshot.cell_vegetation_vitality) ||
        !copy_f32("cell_insolation_dev", snapshot.cell_insolation_dev) ||
        !copy_f32("cell_heat_input", snapshot.cell_heat_input) ||
        !copy_f32("cell_wind_x", snapshot.cell_wind_x) ||
        !copy_f32("cell_wind_y", snapshot.cell_wind_y) ||
        !copy_f32("cell_wind_speed", snapshot.cell_wind_speed) ||
        // weather field 的平流与邻域几何要用格子平面坐标。environment 里原先没有
        // 这两条 —— 生产是从交织的 cell_pos 里解出来的，capture 侧取不到。
        !copy_f32("cell_pos_x", snapshot.cell_pos_x) ||
        !copy_f32("cell_pos_y", snapshot.cell_pos_y) ||
        !copy_f32("cell_ocean_current_x", snapshot.cell_ocean_current_x) ||
        !copy_f32("cell_ocean_current_y", snapshot.cell_ocean_current_y) ||
        !copy_f32("cell_air_mass_temp_anomaly", snapshot.cell_air_mass_temp_anomaly) ||
        !copy_f32("cell_ocean_thermal_anomaly", snapshot.cell_ocean_thermal_anomaly) ||
        !copy_f32("cell_local_thermal_anomaly", snapshot.cell_local_thermal_anomaly) ||
        !copy_f32("cell_temperature_transport_anomaly", snapshot.cell_temperature_transport_anomaly) ||
        !copy_u8("cell_ema_initialized", snapshot.cell_ema_initialized) ||
        !copy_f32("cell_elevation", snapshot.cell_elevation) ||
        !copy_f32("cell_lat_norm", snapshot.cell_lat_norm) ||
        !copy_f32("cell_geometry_area", snapshot.cell_geometry_area) ||
        !copy_f32("cell_wind_band", snapshot.cell_wind_band) ||
        !copy_f32("cell_ocean_heat_capacity", snapshot.cell_ocean_heat_capacity) ||
        !copy_i32("neighbor_offsets", snapshot.neighbor_offsets) ||
        !copy_i32("neighbor_indices", snapshot.neighbor_indices) ||
        !copy_i32("hydro_parent", snapshot.hydro_parent) ||
        !copy_i32("province_ids", snapshot.province_ids) ||
        !copy_u8("terrain", snapshot.terrain) ||
        !copy_u8("landform", snapshot.landform) ||
        !copy_u8("vegetation", snapshot.vegetation) ||
        !copy_u8("military_base_landform", snapshot.military_base_landform) ||
        !copy_u8("military_settlement_tier", snapshot.military_settlement_tier) ||
        !copy_u8("cover", snapshot.cover) ||
        !copy_u8("is_water", snapshot.is_water) ||
        !copy_u8("has_river", snapshot.has_river) ||
        !copy_u8("canal_edge_mask", snapshot.canal_edge_mask) ||
        !copy_f32("canal_water", snapshot.canal_water) ||
        !copy_u8("trade_passable_lut", snapshot.trade_passable_lut) ||
        !copy_i32("trade_move_cost_lut", snapshot.trade_move_cost_lut) ||
        !copy_u8("visible", snapshot.visible) ||
        !copy_f32("building_resource_reserve", snapshot.building_resource_reserve) ||
        !copy_f32("building_resource_extra", snapshot.building_resource_extra)) {
        out["ok"] = false;
        out["code"] = "invalid_runtime_input_type_or_value";
        return out;
    }
    size_t cells = snapshot.terrain.size();
    if (cells == 0 && snapshot.neighbor_offsets.size() > 1u) {
        cells = snapshot.neighbor_offsets.size() - 1u;
    }
    if (cells == 0 && !snapshot.neighbor_indices.empty()) {
        if (snapshot.neighbor_indices.size() % 6u != 0) {
            out["ok"] = false;
            out["code"] = "runtime_input_shape_mismatch";
            return out;
        }
        cells = snapshot.neighbor_indices.size() / 6u;
    }
    if (cells == 0) {
        const auto infer_cells = [&cells](size_t size) {
            if (cells == 0 && size > 0) cells = size;
        };
        infer_cells(snapshot.cell_temp.size());
        infer_cells(snapshot.cell_temp_30d.size());
        infer_cells(snapshot.cell_temp_365d.size());
        infer_cells(snapshot.cell_temp_baseline_year.size());
        infer_cells(snapshot.cell_base_moisture.size());
        infer_cells(snapshot.cell_moisture.size());
        infer_cells(snapshot.cell_plant_available_water.size());
        infer_cells(snapshot.cell_soil_moisture.size());
        infer_cells(snapshot.cell_water_balance_30d.size());
        infer_cells(snapshot.cell_weather_precip.size());
        infer_cells(snapshot.cell_snow_cover.size());
        infer_cells(snapshot.cell_weather_intensity.size());
        infer_cells(snapshot.cell_weather_vapor.size());
        infer_cells(snapshot.cell_weather_cloud_water.size());
        infer_cells(snapshot.cell_weather_cloud.size());
        infer_cells(snapshot.cell_weather_type.size());
        infer_cells(snapshot.cell_weather_transition.size());
        infer_cells(snapshot.cell_sea_ice_frac_prev.size());
        infer_cells(snapshot.cell_river_discharge_30d.size());
        infer_cells(snapshot.cell_vegetation_vitality.size());
        infer_cells(snapshot.cell_insolation_dev.size());
        infer_cells(snapshot.cell_heat_input.size());
        infer_cells(snapshot.cell_wind_x.size());
        infer_cells(snapshot.cell_wind_y.size());
        infer_cells(snapshot.cell_wind_speed.size());
        infer_cells(snapshot.cell_ocean_current_x.size());
        infer_cells(snapshot.cell_ocean_current_y.size());
        infer_cells(snapshot.cell_air_mass_temp_anomaly.size());
        infer_cells(snapshot.cell_ocean_thermal_anomaly.size());
        infer_cells(snapshot.cell_local_thermal_anomaly.size());
        infer_cells(snapshot.cell_temperature_transport_anomaly.size());
        infer_cells(snapshot.cell_ema_initialized.size());
        infer_cells(snapshot.cell_elevation.size());
        infer_cells(snapshot.cell_lat_norm.size());
        infer_cells(snapshot.canal_water.size());
        infer_cells(snapshot.visible.size());
        infer_cells(snapshot.building_resource_reserve.size());
        infer_cells(snapshot.building_resource_extra.size());
    }
    const auto cell_size_ok = [cells](const std::vector<float> &values) {
        return values.empty() || values.size() == cells;
    };
    const auto cell_size_ok_u8 = [cells](const std::vector<uint8_t> &values) {
        return values.empty() || values.size() == cells;
    };
    if ((cells > 0 && snapshot.neighbor_offsets.empty() &&
            !snapshot.neighbor_indices.empty() &&
            snapshot.neighbor_indices.size() != cells * 6u) ||
        !cell_size_ok(snapshot.cell_temp) || !cell_size_ok(snapshot.cell_temp_30d) ||
        !cell_size_ok(snapshot.cell_temp_365d) ||
        !cell_size_ok(snapshot.cell_temp_baseline_year) ||
        !cell_size_ok(snapshot.cell_base_moisture) ||
        !cell_size_ok(snapshot.cell_moisture) || !cell_size_ok(snapshot.cell_plant_available_water) ||
        !cell_size_ok(snapshot.cell_soil_moisture) ||
        !cell_size_ok(snapshot.cell_water_balance_30d) ||
        !cell_size_ok(snapshot.cell_weather_precip) || !cell_size_ok(snapshot.cell_snow_cover) ||
        !cell_size_ok(snapshot.cell_weather_intensity) || !cell_size_ok(snapshot.cell_elevation) ||
        !cell_size_ok(snapshot.cell_weather_vapor) ||
        !cell_size_ok(snapshot.cell_weather_cloud_water) ||
        !cell_size_ok(snapshot.cell_weather_cloud) ||
        !cell_size_ok_u8(snapshot.cell_weather_type) ||
        !cell_size_ok_u8(snapshot.cell_weather_transition) ||
        !cell_size_ok(snapshot.cell_sea_ice_frac_prev) ||
        !cell_size_ok(snapshot.cell_river_discharge_30d) ||
        !cell_size_ok(snapshot.cell_vegetation_vitality) ||
        !cell_size_ok(snapshot.cell_insolation_dev) ||
        !cell_size_ok(snapshot.cell_heat_input) ||
        !cell_size_ok(snapshot.cell_wind_x) ||
        !cell_size_ok(snapshot.cell_wind_y) ||
        !cell_size_ok(snapshot.cell_wind_speed) ||
        !cell_size_ok(snapshot.cell_ocean_current_x) ||
        !cell_size_ok(snapshot.cell_ocean_current_y) ||
        !cell_size_ok(snapshot.cell_air_mass_temp_anomaly) ||
        !cell_size_ok(snapshot.cell_ocean_thermal_anomaly) ||
        !cell_size_ok(snapshot.cell_local_thermal_anomaly) ||
        !cell_size_ok(snapshot.cell_temperature_transport_anomaly) ||
        !cell_size_ok_u8(snapshot.cell_ema_initialized) ||
        !cell_size_ok(snapshot.cell_lat_norm) || !cell_size_ok(snapshot.canal_water) ||
        !cell_size_ok(snapshot.cell_geometry_area) || !cell_size_ok(snapshot.cell_wind_band) ||
        !cell_size_ok(snapshot.cell_ocean_heat_capacity) ||
        (!snapshot.province_ids.empty() && snapshot.province_ids.size() != cells) ||
        !cell_size_ok(snapshot.building_resource_reserve) ||
        !cell_size_ok(snapshot.building_resource_extra) ||
        !cell_size_ok_u8(snapshot.terrain) || !cell_size_ok_u8(snapshot.landform) ||
        !cell_size_ok_u8(snapshot.vegetation) || !cell_size_ok_u8(snapshot.cover) ||
        !cell_size_ok_u8(snapshot.is_water) || !cell_size_ok_u8(snapshot.has_river) ||
        !cell_size_ok_u8(snapshot.canal_edge_mask) ||
        !cell_size_ok_u8(snapshot.visible) ||
        !cell_size_ok_u8(snapshot.military_base_landform) ||
        !cell_size_ok_u8(snapshot.military_settlement_tier) ||
        ((!snapshot.trade_passable_lut.empty() ||
          !snapshot.trade_move_cost_lut.empty()) &&
            (snapshot.trade_passable_lut.size() != 256u ||
             snapshot.trade_move_cost_lut.size() != 256u))) {
        out["ok"] = false;
        out["code"] = "runtime_input_shape_mismatch";
        return out;
    }
    if (cells > static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
        out["ok"] = false;
        out["code"] = "runtime_input_shape_mismatch";
        return out;
    }
    // B8 P2：traj / monsoon 住在 DCWorldExt 的物理求解状态里，不是 input dict 的
    // PackedArray，所以在形状校验之后直接从成员导出。traj 走与生产消费端完全相同的
    // 资格 + 指纹校验；返回 false 就保持空，让 worker 与生产一起走 hopping 回退，
    // 而不是拿一张过期表插值。monsoon 允许为零（物理求解还没产出）。
    if (cells > 0) {
        snapshot.cell_monsoon_thermal = _phys_monsoon_thermal;
        if (snapshot.cell_monsoon_thermal.size() != cells) {
            snapshot.cell_monsoon_thermal.clear();
        }
        if (!runtime_weather_traj_snapshot(static_cast<int>(cells),
                                           snapshot.cell_wind_traj_idx,
                                           snapshot.cell_wind_traj_w)) {
            snapshot.cell_wind_traj_idx.clear();
            snapshot.cell_wind_traj_w.clear();
        }
    }
    for (const int32_t neighbor : snapshot.neighbor_indices) {
        if (neighbor < -1 || (neighbor >= 0 &&
                static_cast<size_t>(neighbor) >= cells)) {
            out["ok"] = false;
            out["code"] = "runtime_input_topology_invalid";
            return out;
        }
    }
    for (const int32_t move_cost : snapshot.trade_move_cost_lut) {
        if (move_cost < 0) {
            out["ok"] = false;
            out["code"] = "runtime_input_value_invalid";
            return out;
        }
    }
    snapshot.cell_count = static_cast<uint32_t>(std::min<size_t>(
        cells, std::numeric_limits<uint32_t>::max()));

    // ── ACTIVE 下 worker 要自己补的那几项 ────────────────────────────────
    // 这两个标志的语义见 RuntimeEnvironmentSnapshot 里各自的注释。两者都不能默认
    // 成 true：SHADOW 下 round scalars 与 season refresh 的真值来自 reference
    // publish，无条件补偿会让 parity 立刻分叉。
    if (inputs.has("climate_capture_cursors")) {
        const PackedFloat64Array cursors = inputs["climate_capture_cursors"];
        if (cursors.size() == 11) snapshot.climate_capture_cursors.assign(cursors.ptr(), cursors.ptr() + cursors.size());
    }
    if (!read_bool("climate_worker_authoritative", false,
                   snapshot.climate_worker_authoritative) ||
        !read_bool("climate_season_refresh_ran", false,
                   snapshot.climate_season_refresh_ran)) {
        out["ok"] = false;
        out["code"] = "invalid_runtime_input_value";
        return out;
    }
    // 生产 Climate round 的输入缓冲。ACTIVE 下这个字典还带着全套 round scalars
    // （GDScript 的 _build_runtime_climate_round_scalar_knobs），因为生产各 pass 的
    // record_production_round_scalars 在抑制门后不再被调到。fill_climate_round_input
    // 本来就解析那些键，所以两种模式共用这一条通道。
    //
    // prefer_slot_lanes=true：per-cell lane 从 _slots 取而不是从 MapData 镜像取。
    // 生产 pass_a 读的就是 _slots，而镜像只在部分 pass 末尾 flush，同一日起点未必
    // 相等 —— 那种差异会以"同一份内核算出不同结果"的形式出现在对拍里。
    snapshot.climate_round_input = pk_async_climate::ClimateInputBuf{};
    if (inputs.has("climate_round_input") &&
        inputs["climate_round_input"].get_type() == Variant::DICTIONARY) {
        const Dictionary round_input = inputs["climate_round_input"];
        fill_climate_round_input(round_input, static_cast<int>(cells),
                                 snapshot.climate_round_input, true);
        // sea_ice_frac 这条 lane 在 SHADOW 下由生产 pass_b 的消费点记录填充，ACTIVE 下
        // 那个记录点在抑制门后没有写者，而缺键时 fill 给的是 assign(n, 0) —— 长度恰好
        // 合规，于是 sea_ice 内核每天都从零冰起算（起始冰量优先取这条），一个
        // si_daily_delta_cap 就是全部结果。它也是 ocean_water 的必需 lane，不能清空，
        // 所以直接对齐到同一天的 slot 快照：ACTIVE 下 pass_b 与 sea_ice 读的就是它。
        if (snapshot.climate_worker_authoritative) {
            snapshot.climate_round_input.sea_ice_frac =
                snapshot.climate_round_input.sea_ice_frac_inout;
        }
    }
    // round 不变量。只在 bind_map_data 之后变一次，所以与 per-day 输入分开走。
    // 缺 albedo_table 会让 stage 8 静默跳过（而 albedo 是 temp 的日内最后写者）；
    // 缺 water_terrain_ids 会让 sea_ice 撞守卫跳过 —— 实测的 starved=0x40 就是它。
    if (inputs.has("climate_round_static_knobs") &&
        inputs["climate_round_static_knobs"].get_type() == Variant::DICTIONARY) {
        const Dictionary sk = inputs["climate_round_static_knobs"];
        auto &dst = snapshot.climate_round_static_knobs;
        dst.n_cells = static_cast<int>(cells);
        // 这条 lane 的契约是定长 6N（见 ClimateRoundStaticKnobs 的注释），而
        // environment 的拓扑还允许 CSR 形式（neighbor_offsets 非空时 indices 是变长
        // 的）。CSR 那份直接赋过去会让内核按 i*6+k 越界读 —— 不是错值而是崩溃。
        if (snapshot.neighbor_indices.size() == cells * 6u) {
            dst.neighbor_indices = snapshot.neighbor_indices;
        } else {
            dst.neighbor_indices.clear();
        }
        const auto read_vec_f32 = [&sk](const char *key,
                                        std::vector<float> &out_vec) {
            if (!sk.has(key)) return;
            const Variant raw = sk[key];
            if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) return;
            const PackedFloat32Array values = raw;
            out_vec.assign(values.ptr(), values.ptr() + values.size());
        };
        read_vec_f32("donor_table", dst.donor_table);
        read_vec_f32("foliage_table", dst.foliage_table);
        read_vec_f32("albedo_table", dst.albedo_table);
        if (sk.has("water_terrain_ids") &&
            sk["water_terrain_ids"].get_type() == Variant::PACKED_BYTE_ARRAY) {
            const PackedByteArray ids = sk["water_terrain_ids"];
            dst.water_terrain_ids.assign(ids.ptr(), ids.ptr() + ids.size());
        }
    }
#include "world_ext_simulation_host_save_section_climate_stage_capture.inc"
#include "world_ext_simulation_host_save_section_physical_circulation_capture.inc"

    // 新图／legacy 冷启动种子；接管以后不再持续运输主线程物理解。
    if (_map_data && snapshot.climate_physics_knobs.ready &&
        (!_climate_physics_committed || !_climate_physics_committed->initialized ||
         _climate_physics_map_id != _map_data->get_instance_id())) {
        const auto seed = [&](const char *name, std::vector<float> &dst) {
            const Variant value = _map_data->get(StringName(name));
            if (value.get_type() != Variant::PACKED_FLOAT32_ARRAY) return;
            const PackedFloat32Array lane = value;
            if (lane.size() > 0) dst.assign(lane.ptr(), lane.ptr() + lane.size());
        };
        seed("slp_arr", snapshot.climate_physics_seed_slp);
        seed("ocean_psi_arr", snapshot.climate_physics_seed_psi);
        seed("upwelling_strength_arr", snapshot.climate_physics_seed_upwelling);
    }
    std::string physics_ready_error;
    const bool physics_capture_ready = runtime_climate_physics_inputs_ready(snapshot, cells, physics_ready_error);
    out["physics_ready"] = false;
    out["physics_missing_key"] = String(snapshot.climate_physics_knobs.missing_key);

    snapshot.topology_validated = cells > 0 &&
        ((!snapshot.neighbor_offsets.empty() &&
          snapshot.neighbor_offsets.size() == cells + 1u) ||
         (snapshot.neighbor_offsets.empty() &&
          snapshot.neighbor_indices.size() == cells * 6u));
    std::string publish_error;
    // economy_input is a main-thread copy of the geographic/climate slots that
    // the ACTIVE economy worker consumes for its day input. It is NOT part of
    // RuntimeClimateKernel::input_hash and is not persisted, so capturing it
    // cannot change parity hashes or save data -- only whether the worker has
    // anything to read.
    //
    // Save restore calls capture_runtime_inputs_for_worker() in Phase A, BEFORE
    // start_runtime_worker() attaches _economy_production_runtime and writes
    // _requested_authority_mask. economy_worker_owns_execution() is therefore
    // false for that first frame, so the old condition silently published an
    // environment snapshot with an empty economy_input lane. The worker then
    // has no day input, never asks for a same-day recapture
    // (_economy_input_requested_day stays -1), and the economy day never
    // commits -- the clock pins on the restored day. New games hide this
    // because their later per-day snapshots (published after worker start)
    // quickly displace the lane-less first frame.
    //
    // Decouple capture from worker lifetime: whenever the economy runtime is
    // configured and the execution mode is not LEGACY_ONLY (the synchronous
    // path does not read this lane), fill it. Consumers decide whether to use
    // it; an unused lane costs one cold-path copy per capture.
    const bool economy_input_lane_needed =
        _economy_runtime != nullptr &&
        (!_runtime_host || _runtime_host->economy_worker_production_allowed());
#include "world_ext_simulation_host_save_section_economy_capture.inc"
    const float captured_dt_days = snapshot.dt_days;
    const bool complete = snapshot.climate_input_complete;
    const bool accepted = inputs.has("world_environment_config")
        ? _runtime_host->initialize_world_environment(std::move(snapshot),
              Dictionary(inputs["world_environment_config"]), publish_error)
        : _runtime_host->publish_environment(std::move(snapshot), publish_error);
    if (!accepted) {
        out["ok"] = false;
        out["code"] = String(publish_error.empty()
            ? "runtime_input_publish_failed" : publish_error.c_str());
        out["generation"] = generation;
        out["day"] = day;
        out["expected_day"] = _runtime_host->next_environment_day();
        return out;
    }
    _climate_physics_capture_ready = physics_capture_ready;
    out["physics_ready"] = physics_capture_ready;
    out["ok"] = true;
    out["generation"] = generation;
    out["day"] = day;
    out["dt_days"] = captured_dt_days;
    out["climate_input_complete"] = complete;
    out["cell_count"] = static_cast<int64_t>(cells);
    return out;
}

Dictionary DCWorldExt::request_runtime_save(int64_t request_id) {
    Dictionary out;
    out["request_id"] = request_id;
    if (!_runtime_host) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (request_id <= 0) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "invalid_save_request_id";
        return out;
    }
    if (_country_runtime != nullptr) {
        CountryCoreCheckpoint checkpoint;
        std::string country_error;
        // Save authority and the compatibility input replica separately.
        NativeCountryRuntime *country_source = country_query_runtime();
        const bool worker_owns_country =
            country_source != static_cast<NativeCountryRuntime *>(_country_runtime);
        CountryCoreCheckpoint compatibility;
        if (worker_owns_country &&
            !static_cast<NativeCountryRuntime *>(_country_runtime)->capture_worker_committed_checkpoint(
                compatibility, country_error)) {
            out["ok"] = false; out["code"] = String(country_error.c_str()); return out;
        }
        const bool captured = country_source != nullptr && (worker_owns_country
                ? country_source->capture_worker_committed_checkpoint(
                      checkpoint, country_error)
                : country_source->capture_core_checkpoint(
                      checkpoint, country_error));
        checkpoint.compatibility_pkcn = std::move(compatibility.canonical_pkcn);
        if (worker_owns_country)
            checkpoint.effect_adapter =
                static_cast<NativeCountryRuntime *>(_country_runtime)->capture_effect_adapter();
        if (!captured || !_runtime_host->publish_country_checkpoint(checkpoint,
                                                       country_error)) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = String(country_error.empty()
                ? "country_checkpoint_capture_failed"
                : country_error.c_str());
            return out;
        }
    }
    const NativeSimulationHost::CountryWorkerProtocolStatus country_protocol =
        _runtime_host->country_worker_protocol_status();
    if (country_protocol.configured &&
        (country_protocol.plan_active || country_protocol.pending_intents != 0 ||
         country_protocol.result_count != 0 ||
         country_protocol.rejected_intents != 0 ||
         country_protocol.has_unreported_rejection)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "country_worker_save_barrier";
        return out;
    }
    if (!_runtime_host->request_save(static_cast<uint64_t>(request_id))) {
        out["ok"] = false;
        out["pending"] = false;
        const RuntimeWorkerState state = _runtime_host->state();
        out["code"] = state == RuntimeWorkerState::FAULTED
            ? "worker_faulted"
            : (_runtime_host->stop_requested() || state == RuntimeWorkerState::STOPPING
                ? "runtime_worker_stopping" : "save_request_busy");
        return out;
    }
    out["ok"] = true;
    out["pending"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::poll_runtime_save(int64_t request_id) {
    Dictionary out;
    out["request_id"] = request_id;
    if (!_runtime_host) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const auto bundle = _runtime_host->poll_save(
        static_cast<uint64_t>(std::max<int64_t>(0, request_id)));
    if (bundle == nullptr &&
        _runtime_host->save_failed(
            static_cast<uint64_t>(std::max<int64_t>(0, request_id)))) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_save_failed";
        out["reason"] = String(_runtime_host->save_failure_reason().c_str());
        return out;
    }
    if (bundle == nullptr) {
        out["ok"] = true;
        out["pending"] = true;
        out["code"] = "save_pending";
        return out;
    }
    if (bundle->bytes.size() < sizeof(uint64_t)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "save_bundle_checksum_failed";
        return out;
    }
    uint64_t computed_checksum = 1469598103934665603ull;
    for (size_t i = 0; i + sizeof(uint64_t) < bundle->bytes.size(); ++i) {
        computed_checksum ^= static_cast<uint64_t>(bundle->bytes[i]);
        computed_checksum *= 1099511628211ull;
    }
    uint64_t encoded_checksum = 0;
    for (uint32_t i = 0; i < sizeof(uint64_t); ++i) {
        encoded_checksum |= static_cast<uint64_t>(
            bundle->bytes[bundle->bytes.size() - sizeof(uint64_t) + i]) << (i * 8u);
    }
    if (computed_checksum != bundle->checksum || encoded_checksum != bundle->checksum) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "save_bundle_checksum_failed";
        return out;
    }
    PackedByteArray bytes;
    bytes.resize(static_cast<int>(bundle->bytes.size()));
    if (!bundle->bytes.empty()) std::memcpy(bytes.ptrw(), bundle->bytes.data(), bundle->bytes.size());
    PackedByteArray country_pkcn;
    country_pkcn.resize(static_cast<int64_t>(bundle->country_pkcn_bytes.size()));
    if (!bundle->country_pkcn_bytes.empty()) {
        std::memcpy(country_pkcn.ptrw(), bundle->country_pkcn_bytes.data(),
                    bundle->country_pkcn_bytes.size());
    }
    // Both PKSR and the PKSV provider share this immutable boundary capture.
    // Export the existing wire bytes instead of recapturing the economy on UI.
    PackedByteArray economy_ecp2;
    economy_ecp2.resize(static_cast<int64_t>(bundle->economy_ecp2_bytes.size()));
    if (!bundle->economy_ecp2_bytes.empty()) {
        std::memcpy(economy_ecp2.ptrw(), bundle->economy_ecp2_bytes.data(),
                    bundle->economy_ecp2_bytes.size());
    }
    out["ok"] = true;
    out["pending"] = false;
    out["ready"] = true;
    out["code"] = "ok";
    out["request_id"] = static_cast<int64_t>(bundle->request_id);
    out["committed_day"] = bundle->committed_day;
    out["paused"] = bundle->paused;
    out["speed_days_per_second"] = bundle->speed_days_per_second;
    out["generation"] = static_cast<int64_t>(bundle->generation);
    out["state_hash"] = static_cast<int64_t>(bundle->state_hash);
    out["environment_generation"] = static_cast<int64_t>(bundle->environment_generation);
    out["environment_day"] = bundle->environment_day;
    out["climate_anomaly"] = bundle->climate_anomaly;
    out["time_debt_days"] = bundle->time_debt_days;
    out["bundle_version"] = static_cast<int>(bundle->bundle_version);
    out["runtime_domain_abi_version"] = static_cast<int>(
        bundle->runtime_domain_abi_version);
    out["section_mask"] = static_cast<int64_t>(bundle->section_mask);
    out["pending_command_count"] = static_cast<int>(bundle->pending_commands.size());
    out["domain_pod_bytes"] = static_cast<int64_t>(bundle->domain_pod_bytes.size());
    out["climate_bytes"] = static_cast<int64_t>(bundle->climate_bytes.size());
    out["country_bytes"] = static_cast<int64_t>(bundle->country_bytes.size());
    out["trigger_bytes"] = static_cast<int64_t>(bundle->trigger_bytes.size());
    out["modifier_bytes"] = static_cast<int64_t>(bundle->modifier_bytes.size());
    out["events_bytes"] = static_cast<int64_t>(bundle->events_bytes.size());
    out["modifier_bytes"] = static_cast<int64_t>(bundle->modifier_bytes.size());
    out["effect_bytes"] = static_cast<int64_t>(bundle->effect_bytes.size());
    out["gameplay_effect_bytes"] = static_cast<int64_t>(
        bundle->gameplay_effect_bytes.size());
    out["ideology_bytes"] = static_cast<int64_t>(bundle->ideology_bytes.size());
    out["country_pkcn"] = country_pkcn;
    const auto packed = [](const std::vector<uint8_t> &source) {
        PackedByteArray bytes;
        bytes.resize(static_cast<int64_t>(source.size()));
        if (!source.empty()) std::copy(source.begin(), source.end(), bytes.ptrw());
        return bytes;
    };
    out["pkmi"] = packed(bundle->military_bytes);
    out["pknr"] = packed(bundle->narrative_bytes);
    out["economy_ecp2"] = economy_ecp2;
    out["checksum"] = static_cast<int64_t>(bundle->checksum);
    out["bytes"] = bytes;
    return out;
}

Dictionary DCWorldExt::restore_runtime_bundle(const PackedByteArray &bytes,
                                              const PackedByteArray &external_ecp2) {
    Dictionary out;
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    if (bytes.is_empty()) {
        out["ok"] = false;
        out["code"] = "runtime_bundle_empty";
        out["state"] = runtime_state_name(_runtime_host->state());
        return out;
    }
    std::string error;
    bool recovered_truncated_ecp2 = false;
    if (!_runtime_host->restore_bundle(bytes.ptr(),
                                       static_cast<size_t>(bytes.size()), error,
                                       external_ecp2.ptr(), static_cast<size_t>(external_ecp2.size()),
                                       &recovered_truncated_ecp2)) {
        out["ok"] = false;
        out["code"] = String(error.c_str());
        out["state"] = runtime_state_name(_runtime_host->state());
        return out;
    }
    _runtime_host->reset_day_tail_for_world_change();
    clear_runtime_map_lut_frame();
    _climate_physics_committed.reset();
    _climate_physics_capture_ready = false;
    _climate_writeback_applied_generation = 0;
    _climate_writeback_applied_day = -1;
    // The bundle is held by the host until the next start() consumes it.  Do
    // not expose or decode the payload here; this call remains a main-thread
    // validation/copy boundary only.
    out["ok"] = true;
    out["pending"] = true;
    out["restored"] = true;
    out["recovered_truncated_ecp2"] = recovered_truncated_ecp2;
    out["code"] = "ok";
    out["state"] = runtime_state_name(_runtime_host->state());
    return out;
}

} // namespace pk

void pk::DCWorldExt::profile_runtime_save_window(bool active) {
    if (_runtime_host) _runtime_host->profile_save_window(active);
}
