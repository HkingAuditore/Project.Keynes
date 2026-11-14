#include "world_ext.h"
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
        !copy_u8("terrain", snapshot.terrain) ||
        !copy_u8("landform", snapshot.landform) ||
        !copy_u8("vegetation", snapshot.vegetation) ||
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
        !cell_size_ok(snapshot.building_resource_reserve) ||
        !cell_size_ok(snapshot.building_resource_extra) ||
        !cell_size_ok_u8(snapshot.terrain) || !cell_size_ok_u8(snapshot.landform) ||
        !cell_size_ok_u8(snapshot.vegetation) || !cell_size_ok_u8(snapshot.cover) ||
        !cell_size_ok_u8(snapshot.is_water) || !cell_size_ok_u8(snapshot.has_river) ||
        !cell_size_ok_u8(snapshot.canal_edge_mask) ||
        !cell_size_ok_u8(snapshot.visible) ||
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
        _captured_climate_round_input = snapshot.climate_round_input;
        _captured_climate_round_input_valid = true;
        _captured_climate_round_input_day = snapshot.day;
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
    // ── climate_stage_knobs：ACTIVE 下 worker 自己到不了的那几个 stage ─────
    //
    // 这些 stage 不在 climate round 里 —— 它们跑在 native daily graph 的 stage_b 段、
    // 各有自己的 stride，输入也不全在 environment 快照里（catalog 查表、跨 tick 缓存、
    // 生产 builder 里的硬编码阈值）。SHADOW 下它们的输入来自生产的 reference publish，
    // 所以 GDScript 只在 worker 权威时才填这个字典（见
    // map_generator.gd::_build_runtime_climate_stage_knobs）；字典非空本身就等于
    // "今天 weather 轮到期"。
    if (inputs.has("climate_stage_knobs") &&
        inputs["climate_stage_knobs"].get_type() == Variant::DICTIONARY) {
        const Dictionary stage_knobs = inputs["climate_stage_knobs"];
        // stage 11 后半段 weather distribute —— snow_cover / snowpack /
        // water_balance_30d 的当日最后一个写者。缺了它这三条恒为 0，而 sea_ice 与
        // albedo 都读 snow_cover，缺口会一路往下游传。
        //
        // 键名口径必须与生产 run_weather_distribute_pass（world_ext_weather.cpp）
        // 逐一对应：GDScript 那侧的 build_distribute_knobs_for_worker 是生产同一个
        // builder 的薄包装，两边对同一个键取不同值就是一次静默分叉。默认值同理，
        // 那几个 snowpack / snowline 阈值在生产侧也是 has() 三元的形式。
        if (stage_knobs.has("stage_distribute") &&
            stage_knobs["stage_distribute"].get_type() == Variant::DICTIONARY) {
            const Dictionary d = stage_knobs["stage_distribute"];
            auto wd = std::make_shared<pk_async_climate::WeatherDistributeInput>();
            wd->n_cells = static_cast<int>(cells);
            wd->ran = true;
            // 两条积雪计数在 ACTIVE 下由 worker 跨天自持：它们是 HexCell 的 AoS
            // 字段、没有 SoA 镜像，既不在快照里也不经回灌回到 MapData，而生产
            // distribute 正是被抑制的那一方 —— 每天拿它那份不再推进的缓存播种会让
            // snow_accum_days_req 永远攒不满，snow_cover 于是恒为 0。
            wd->own_snow_state = true;
            const auto kf = [&d](const char *key, float fallback) {
                return d.has(key) ? float(d[key]) : fallback;
            };
            const auto ki = [&d](const char *key, int fallback) {
                return d.has(key) ? int(d[key]) : fallback;
            };
            auto &k = wd->knobs;
            k.n_cells = static_cast<int>(cells);
            k.snow_min_intensity = kf("snow_min_intensity", 0.0f);
            k.snow_freeze_t = kf("snow_freeze_t", 0.0f);
            k.snow_melt_t = kf("snow_melt_t", 0.0f);
            k.snow_intensity_snow = kf("snow_intensity_for_snowing", 0.0f);
            k.snow_accum_days_req = ki("snow_accum_days_req", 0);
            k.flood_heavy_int = kf("flood_heavy_intensity", 0.0f);
            k.flood_heavy_pre = kf("flood_heavy_precip", 0.0f);
            k.flood_low_int = kf("flood_lowland_intensity", 0.0f);
            k.flood_low_elev = kf("flood_lowland_elev", 0.0f);
            k.flood_low_moist = kf("flood_lowland_moisture", 0.0f);
            k.wt_clear = ki("wt_clear", 0);
            k.cv_snow = ki("cv_snow", 0);
            k.cv_none = ki("cv_none", 0);
            k.cv_flooding = ki("cv_flooding", 0);
            k.snowpack_accum_gain = kf("snowpack_accum_gain", 0.10f);
            k.snowpack_melt_temp_gain = kf("snowpack_melt_temp_gain", 0.22f);
            k.snowpack_melt_sun_gain = kf("snowpack_melt_sun_gain", 0.12f);
            k.snowpack_cover_low = kf("snowpack_cover_low", 0.05f);
            k.snowpack_cover_full = kf("snowpack_cover_full", 0.32f);
            k.snowline_temp_threshold = kf("snowline_temp_threshold", 0.24f);
            k.snowline_band = kf("snowline_band", 0.22f);
            float anomaly_cap = kf("weather_temp_anomaly_cap", 0.025f);
            if (anomaly_cap < 0.0f) anomaly_cap = 0.0f;
            else if (anomaly_cap > 0.10f) anomaly_cap = 0.10f;
            k.weather_temp_anomaly_cap = anomaly_cap;
            k.direct_moisture_enabled =
                bool(d.get("weather_direct_moisture_enabled", false));
            // 四张 WeatherType 剖面表都是定长 8。长度不对就整份不发：内核对它们
            // 只按 wt id 索引、不做范围检查。
            bool tables_ok = true;
            const auto table_f32 = [&d, &tables_ok](const char *key, float *out_tab) {
                const Variant raw = d.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedFloat32Array v = raw;
                if (v.size() != 8) {
                    tables_ok = false;
                    return;
                }
                std::memcpy(out_tab, v.ptr(), 8 * sizeof(float));
            };
            const auto table_u8 = [&d, &tables_ok](const char *key, uint8_t *out_tab) {
                const Variant raw = d.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedByteArray v = raw;
                if (v.size() != 8) {
                    tables_ok = false;
                    return;
                }
                std::memcpy(out_tab, v.ptr(), 8);
            };
            table_f32("temp_delta_arr", k.temp_delta);
            table_f32("moisture_delta_arr", k.moist_delta);
            table_u8("can_form_snow_arr", k.can_form_snow);
            table_u8("can_form_flood_arr", k.can_form_flood);
            // 读 lane 走 environment 快照（与生产读 _slots 同一份数据）。temp /
            // moisture / snow_cover / snowpack / water_balance_30d 与 weather 四条
            // 不在这里：内核用 worker 自己 store 那一份，见 runtime_climate_kernel.cpp
            // 里 shared_distribute_ran 那一段。守卫仍要求它们齐长，所以照填。
            wd->heat = snapshot.cell_heat_input;
            wd->elevation = snapshot.cell_elevation;
            wd->landform = snapshot.landform;
            wd->terrain = snapshot.terrain;
            wd->weather_intensity = snapshot.cell_weather_intensity;
            wd->weather_precip = snapshot.cell_weather_precip;
            wd->weather_type = snapshot.cell_weather_type;
            wd->cover = snapshot.cover;
            wd->soil_moisture = snapshot.cell_soil_moisture;
            // weather_field_init 没有快照 lane。worker 侧的 field solve 总走 direct
            // 语义（一定写 field_init=1），内核也用自己的 scratch 覆盖它 —— 这里
            // 只是把守卫喂饱。
            wd->weather_field_init.assign(cells, 1u);
            const auto lane_i32 = [&d, cells](const char *key,
                                              std::vector<int32_t> &out_vec) {
                const Variant raw = d.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_INT32_ARRAY) return;
                const PackedInt32Array v = raw;
                if (static_cast<size_t>(v.size()) != cells) return;
                out_vec.assign(v.ptr(), v.ptr() + v.size());
            };
            lane_i32("accumulated_snow_days", wd->accumulated_snow_days);
            lane_i32("pre_snow_cover", wd->pre_snow_cover);
            // own_snow_state 下这两条只用于首日播种，缺席时从零起算即可 —— 但长度
            // 必须齐，否则整个 stage 撞守卫静默跳过。
            if (wd->accumulated_snow_days.size() != cells) {
                wd->accumulated_snow_days.assign(cells, 0);
            }
            if (wd->pre_snow_cover.size() != cells) {
                wd->pre_snow_cover.assign(cells, 0);
            }
                if (tables_ok) {
                    snapshot.climate_weather_distribute = wd;
                }
            }

            // ── stage 11 前半段 weather field solve ──────────────────────
            //
            // vapor / cloud_water / precip 这条降水循环的驱动。缺了它 moisture 只
            // 被 distribute 的 moist_delta 和 feedback 零散推一下，表现是跳变而不是
            // 连续演化 —— 而且 distribute 读的 weather 四条也就一直是 field solve
            // 没写过的值。
            //
            // 键名口径对生产 run_weather_field_solve_pass（world_ext_weather.cpp:299
            // 起解析、:792 起收进 wfk）。默认值与 clamp 都要照抄：ClimateProfile 给
            // 越界值时只有 clamp 能让两侧落在同一个数上，而少一次 clamp 不会有任何
            // 人报错。
        if (stage_knobs.has("stage_weather") &&
            stage_knobs["stage_weather"].get_type() == Variant::DICTIONARY) {
                const Dictionary d = stage_knobs["stage_weather"];
                auto wx = std::make_shared<pk_async_climate::WeatherFieldInput>();
                wx->n_cells = static_cast<int>(cells);
                wx->ran = true;
                // conv_inhib / field_init 跨天由 worker 自持：ACTIVE 下生产的对流
                // 抑制不再推进，每天拿它那份重置等于把这条记忆抹平，对流会一直从
                // "无抑制"起步；field_init 被覆盖则水汽循环整场起不来（见
                // runtime_climate_kernel.cpp:1048 起的两段注释）。
                wx->own_field_state = true;

                const auto kf = [&d](const char *key, float fallback) {
                    return d.has(key) ? float(d[key]) : fallback;
                };
                const auto ki = [&d](const char *key, int fallback) {
                    return d.has(key) ? int(d[key]) : fallback;
                };
                const auto kb = [&d](const char *key, bool fallback) {
                    return d.has(key) ? bool(d[key]) : fallback;
                };
                const auto lo = [](float v, float min_v) {
                    return v < min_v ? min_v : v;
                };
                const auto clamp_f = [](float v, float min_v, float max_v) {
                    return v < min_v ? min_v : (v > max_v ? max_v : v);
                };

                auto &k = wx->knobs;
                k.n_cells = static_cast<int>(cells);
                k.climate_anomaly = kf("climate_anomaly", 0.0f);
                k.refresh_convergence = kb("refresh_convergence", false);
                k.apply_convergence_boost = kb("apply_convergence_boost", true);
                // staged 语义：内核把 prev_* 复制到独立缓冲后再解算（kernel:1042），
                // 与生产 staged 路径一致。
                k.use_next_outputs = true;
                k.field_advect_steps = ki("field_advect_steps", 3);
                k.field_diffusion = kf("field_diffusion", 0.04f);
                k.field_ocean_evap_gain = kf("field_ocean_evap_gain", 0.55f);
                k.field_precip_inertia =
                    clamp_f(kf("field_precip_inertia", 0.40f), 0.05f, 1.0f);
                k.field_precip_spatial_smooth =
                    clamp_f(kf("field_precip_spatial_smooth", 0.30f), 0.0f, 0.8f);
                k.field_cloud_inertia =
                    clamp_f(kf("field_cloud_inertia", 0.74f), 0.05f, 1.0f);
                k.field_wet_terrain_precip_damping = clamp_f(
                    kf("field_wet_terrain_precip_damping", 0.60f), 0.0f, 1.0f);
                k.field_lake_precip_damping =
                    clamp_f(kf("field_lake_precip_damping", 0.65f), 0.0f, 1.0f);
                k.field_lake_evap_scale =
                    clamp_f(kf("field_lake_evap_scale", 0.35f), 0.0f, 1.0f);
                k.field_extreme_precip_soft_cap =
                    clamp_f(kf("field_extreme_precip_soft_cap", 0.16f), 0.0f, 1.0f);
                k.field_extreme_precip_softness =
                    clamp_f(kf("field_extreme_precip_softness", 0.20f), 0.0f, 1.0f);
                k.field_land_evapotranspiration_gain =
                    lo(kf("field_land_evapotranspiration_gain", 0.85f), 0.0f);
                k.field_ocean_precip_suppression = clamp_f(
                    kf("field_ocean_precip_suppression", 0.95f), 0.0f, 1.0f);
                k.field_frontogenesis_gain =
                    lo(kf("field_frontogenesis_gain", 0.42f), 0.0f);
                k.field_rain_shadow_drying =
                    clamp_f(kf("field_rain_shadow_drying", 0.35f), 0.0f, 1.0f);
                k.field_advect_vapor = kf("field_advect_vapor", 0.95f);
                k.field_advect_cloud = kf("field_advect_cloud", 0.94f);
                k.field_rh_condense = kf("field_rh_condense", 0.55f);
                k.field_static_cond_w = kf("field_static_cond_w", 1.00f);
                k.field_condense_rate = kf("field_condense_rate", 0.45f);
                k.field_lift_cond_gain = kf("field_lift_cond_gain", 0.80f);
                k.field_conv_cond_gain = kf("field_conv_cond_gain", 1.00f);
                k.field_thermal_conv_cond = kf("field_thermal_conv_cond", 1.15f);
                k.field_thermal_conv_precip =
                    kf("field_thermal_conv_precip", 0.30f);
                k.field_autoconversion = kf("field_autoconversion", 0.16f);
                k.field_precip_base_frac = kf("field_precip_base_frac", 0.08f);
                k.field_lift_precip_gain = kf("field_lift_precip_gain", 0.45f);
                k.field_conv_precip_gain = kf("field_conv_precip_gain", 1.95f);
                k.field_oro_precip_gain = kf("field_oro_precip_gain", 0.30f);
                k.field_stratiform_gain = kf("field_stratiform_gain", 1.0f);
                k.field_cool_season_vapor_floor =
                    kf("field_cool_season_vapor_floor", 0.0f);
                k.field_cloud_reevap = kf("field_cloud_reevap", 0.28f);
                float pos_scale = kf("weather_cell_pos_scale", 1.0f);
                if (pos_scale <= 0.001f) pos_scale = 1.0f;
                k.weather_cell_pos_scale = pos_scale;
                k.weather_wrap_width_x =
                    lo(kf("weather_wrap_width_x", 0.0f), 0.0f);
                k.cold_precip_as_blizzard = kb("cold_precip_as_blizzard", true);
                k.snow_classification_margin =
                    clamp_f(kf("snow_classification_margin", 0.03f), 0.0f, 0.12f);
                k.weather_lat_te_norm = kf("weather_lat_te_norm", 0.5f);
                // 键名例外：struct 叫 omega_ascent_gain，字典键带 field_ 前缀。
                k.omega_ascent_gain = kf("field_omega_ascent_gain", 0.40f);
                k.world_bounds_pos_y = kf("world_bounds_pos_y", 0.0f);
                k.world_bounds_size_y = kf("world_bounds_size_y", 0.0f);
                // 五个 syn_* 的字典键是 weather_synoptic_* —— 这五条是 ψ 的耦合
                // 强度（不是 ψ 的演化参数，那些在 SynopticAdvanceKnobs 里）。
                k.syn_supp = kf("weather_synoptic_supp", 0.75f);
                k.syn_enh = kf("weather_synoptic_enh", 0.45f);
                k.syn_front_force = kf("weather_synoptic_front_force", 0.55f);
                k.syn_front_enh = kf("weather_synoptic_front_enh", 0.70f);
                k.syn_base_lift = kf("weather_synoptic_base_lift", 1.55f);
                k.weather_transition_enabled =
                    kb("weather_transition_enabled", false);
                k.weather_transition_alpha_rate =
                    clamp_f(kf("weather_transition_alpha_rate", 1.0f), 0.0f, 1.0f);
                k.weather_transition_dt_days =
                    clamp_f(kf("weather_transition_dt_days", 1.0f), 0.0f, 30.0f);
                k.thermal_monsoon_enabled = kb("thermal_monsoon_enabled", false);
                int storm_id = ki("cyclone_storm_type_id", 2);
                if (storm_id < 0) storm_id = 0;
                else if (storm_id > 255) storm_id = 255;
                k.cyclone_storm_type_id = static_cast<uint8_t>(storm_id);

                // ψ 的演化参数。synoptic_enabled 的生产默认是 true。
                wx->synoptic_enabled = kb("weather_synoptic_enabled", true);
                auto &s = wx->synoptic;
                s.baroclinic = kf("weather_synoptic_baroclinic", 0.40f);
                s.damp = kf("weather_synoptic_damp", 0.90f);
                s.diffuse = kf("weather_synoptic_diffuse", 0.05f);
                s.seed_rate = kf("weather_synoptic_seed_rate", 0.015f);
                s.seed_amp = kf("weather_synoptic_seed_amp", 0.42f);
                s.adv_cells = ki("weather_synoptic_adv_cells", 3);
                s.tick = ki("weather_solve_tick", 0);
                s.cell_pos_scale = pos_scale;
                s.wrap_width_x = k.weather_wrap_width_x;

                // 守卫要求齐长的 13 条 lane（kernel:993 起）。少一条整段静默跳过，
                // 而它与 distribute 共用 stage 11 的 bit，所以 stage-days 上看不出来。
                wx->temp_read = snapshot.cell_temp;
                wx->moisture_read = snapshot.cell_moisture;
                wx->air_anomaly = snapshot.cell_air_mass_temp_anomaly;
                wx->wind_x = snapshot.cell_wind_x;
                wx->wind_y = snapshot.cell_wind_y;
                wx->wind_speed = snapshot.cell_wind_speed;
                // B8 P2：把 weather field solve 的另外两条直接输入接上。
                // traj 已通过生产的指纹/资格校验（capture 直接调用同一个 accessor），
                // 为空就是"这一次不该消费"，worker 走 hopping。monsoon 是主线程
                // 物理求解的派生量，求解器迁走之前它仍是输入而不是 worker 的状态。
                wx->traj_idx = snapshot.cell_wind_traj_idx;
                wx->traj_w = snapshot.cell_wind_traj_w;
                wx->monsoon_thermal = snapshot.cell_monsoon_thermal;
                // B8-2：cyclone 冷启动种子 + 推进参数。genesis 仍在主线程，所以
                // 这里搬的是"当前活跃条目"，worker 接管后自行推进/衰减/stamp。
                snapshot.cyclone_seed_blob = runtime_cyclone_state_blob();
                snapshot.cyclone_enabled =
                    kb("native_tropical_cyclone_enabled", false);
                snapshot.cyclone_dt_days = kf("weather_transition_dt_days", 1.0f);
                snapshot.cyclone_max_radius_cells =
                    ki("tropical_cyclone_max_radius_cells", 5);
                snapshot.cyclone_world_bounds_pos_y =
                    kf("world_bounds_pos_y", 0.0f);
                snapshot.cyclone_world_bounds_size_y =
                    kf("world_bounds_size_y", 1.0f);
                snapshot.cyclone_wrap_width_x =
                    kf("weather_wrap_width_x", 0.0f);
                snapshot.cyclone_storm_type_id = ki("cyclone_storm_type_id", -1);
                snapshot.cyclone_capacity =
                    ki("tropical_cyclone_capacity", 24);
                snapshot.cyclone_births_per_commit =
                    ki("tropical_cyclone_births_per_commit", 2);
                snapshot.cyclone_min_temp =
                    kf("tropical_cyclone_min_temp", 0.58f);
                snapshot.cyclone_min_instability =
                    kf("tropical_cyclone_min_instability", 0.40f);
                snapshot.cyclone_max_shear =
                    kf("tropical_cyclone_max_shear", 0.42f);
                snapshot.cyclone_min_lat =
                    kf("tropical_cyclone_min_lat", 0.06f);
                snapshot.cyclone_max_lat =
                    kf("tropical_cyclone_max_lat", 0.40f);
                snapshot.cyclone_wake_days =
                    kf("cyclone_wake_days", 32.0f);
                wx->elevation = snapshot.cell_elevation;
                wx->pos_x = snapshot.cell_pos_x;
                wx->pos_y = snapshot.cell_pos_y;
                wx->temp_transport_anomaly =
                    snapshot.cell_temperature_transport_anomaly;
                wx->terrain = snapshot.terrain;
                wx->has_river = snapshot.has_river;
                wx->vegetation = snapshot.vegetation;
                // 可选 lane：内核对它们各有无值分支。
                wx->river_q30 = snapshot.cell_river_discharge_30d;
                wx->soil_moisture = snapshot.cell_soil_moisture;
                wx->vitality = snapshot.cell_vegetation_vitality;
                wx->sea_ice = snapshot.cell_sea_ice_frac_prev;
                wx->snow_cover = snapshot.cell_snow_cover;
                // B8-2：synoptic ψ 现在由 worker 自持。这里只把生产当天 solve 读到
                // 的 ψ 作为**冷启动种子**传过去（worker 第一次见到该 lane 时播种，
                // 之后自己推进）。风场仍是输入：物理环流求解器还在主线程（P2），
                // 所以这不是"worker 缺状态"，而是"worker 用当天风场推进自己的 ψ"。
                //
                // cyclone / monsoon / traj 仍留空：cyclone 的跨天扰动表在生产成员
                // 里，monsoon/traj 的写者还没迁；它们的待办见台账
                // tools/runtime/climate_field_ownership.json 的 extra_policy_fields。
                if (wx->synoptic_enabled && _wx_synoptic.size() == cells) {
                    wx->psi = _wx_synoptic;
                    if (_wx_synoptic_prev.size() == cells) {
                        wx->psi_prev = _wx_synoptic_prev;
                    }
                } else {
                    wx->psi.clear();
                    wx->psi_prev.clear();
                }

                snapshot.climate_weather = wx;

                // 邻居表：weather 与 feedback 的守卫都读 static knobs 那一份，而它在
                // environment 走 CSR 形式时会被上面的长度守卫清空。字典这份是生产
                // 校验过的定长 6N，正好补上。
                if (snapshot.climate_round_static_knobs.neighbor_indices.size() !=
                        cells * 6u) {
                    const Variant raw = d.get("neighbor_indices", Variant());
                    if (raw.get_type() == Variant::PACKED_INT32_ARRAY) {
                        const PackedInt32Array nb = raw;
                        if (static_cast<size_t>(nb.size()) == cells * 6u) {
                            snapshot.climate_round_static_knobs.neighbor_indices
                                .assign(nb.ptr(), nb.ptr() + nb.size());
                        }
                    }
                }
            }

        // stage_b 段的三个 stage（albedo / vegetation_dynamics / climate_feedback）
        // 共用一份 knobs 字典 —— 生产那侧就是 run_stage_b_pass(knobs) 一次吃三段，
        // 各自由 run_* 标志按自己的 stride 开合。GDScript 侧复用了生产同一个
        // builder（_build_native_daily_stage_b_knobs），所以这里的键名与
        // run_stage_b_pass 逐一对应。
        const Dictionary stage_b =
            (stage_knobs.has("stage_b") &&
             stage_knobs["stage_b"].get_type() == Variant::DICTIONARY)
                ? Dictionary(stage_knobs["stage_b"]) : Dictionary();

        // stage 8 albedo —— temp 的日内最后一个写者。它是内联结构而不是 shared_ptr：
        // 只有五个标量，albedo_table 本身是 round 不变量、走 static knobs。
        // run_albedo 为假就是"这个 stride 今天没到期"，ran 留 false 让 worker 也不跑。
        if (bool(stage_b.get("run_albedo", false))) {
            auto &alb = snapshot.climate_albedo;
            alb.ran = true;
            alb.reference_albedo = stage_b.has("reference_albedo")
                ? float(stage_b["reference_albedo"]) : 0.0f;
            alb.temp_gain = stage_b.has("albedo_temp_gain")
                ? float(stage_b["albedo_temp_gain"]) : 0.0f;
            alb.snow_cover_albedo = stage_b.has("snow_cover_albedo")
                ? float(stage_b["snow_cover_albedo"]) : 0.75f;
            alb.cover_snow_id =
                static_cast<uint8_t>(int(stage_b.get("cover_snow_id", 1)));
            alb.cover_glacier_id =
                static_cast<uint8_t>(int(stage_b.get("cover_glacier_id", 2)));
        }

        // stage 10 climate_feedback —— vegetation_growth_pressure 的写者之一。它还
        // 写 base_moisture 与 soil_moisture，但那两条没有 worker store 成员，内核用
        // scratch 承接初值后丢弃，所以这里记的是生产口径的初值。
        //
        // 六个 weather 枚举 id 在生产侧是必填（缺一个就整段拒跑），这里同样：没被
        // 记录时 knobs 默认的 -1 与任何真实 weather_type 都不相等，效果是这段白跑。
        if (bool(stage_b.get("run_feedback", false))) {
            auto fb = std::make_shared<pk_async_climate::ClimateFeedbackInput>();
            fb->n_cells = static_cast<int>(cells);
            auto &k = fb->knobs;
            k.ran = true;
            const auto bf = [&stage_b](const char *key, float fallback) {
                return stage_b.has(key) ? float(stage_b[key]) : fallback;
            };
            const auto bi = [&stage_b](const char *key, int fallback) {
                return stage_b.has(key) ? int(stage_b[key]) : fallback;
            };
            k.soil_gain = bf("soil_gain", 0.0f);
            k.veg_gain = bf("veg_gain", 0.0f);
            k.scale = bf("scale", 1.0f);
            k.per_day_clamp = bf("per_day_clamp", 0.0f);
            k.ocean_drift_gain = bf("ocean_drift_gain", 0.0f);
            k.base_moisture_gain = bf("weather_to_base_moisture_gain", 0.0f);
            k.write_weather_veg_pressure =
                bool(stage_b.get("write_weather_veg_pressure", true));
            k.wt_rain_id = bi("wt_rain_id", -1);
            k.wt_storm_id = bi("wt_storm_id", -1);
            k.wt_monsoon_id = bi("wt_monsoon_id", -1);
            k.wt_blizzard_id = bi("wt_blizzard_id", -1);
            k.wt_drought_id = bi("wt_drought_id", -1);
            k.wt_heatwave_id = bi("wt_heatwave_id", -1);

            fb->is_water = snapshot.is_water;
            fb->weather_type = snapshot.cell_weather_type;
            fb->weather_intensity = snapshot.cell_weather_intensity;
            fb->temp_transport_anomaly =
                snapshot.cell_temperature_transport_anomaly;
            fb->base_moisture = snapshot.cell_base_moisture;
            fb->soil_moisture = snapshot.cell_soil_moisture;
            // 与 distribute 同一条：weather_field_init 没有快照 lane，而 worker 侧
            // field solve 总走 direct 语义（一定写 1）。
            fb->weather_field_init.assign(cells, 1u);
            snapshot.climate_feedback = fb;
        }

        // stage 9 vegetation_dynamics —— vegetation_growth_pressure 的另一个写者，
        // 也是 plant_available_water / vitality / 两条 streak 的写者。它要的八张查表
        // 来自 GDScript 的 vegetation catalog，worker 侧没有任何获取途径，只能整份
        // 随字典过来（好在它们是 round 不变量，builder 每次给的是同一份）。
        if (bool(stage_b.get("run_veg_dyn", false))) {
            auto vd = std::make_shared<pk_async_climate::VegetationDynamicsInput>();
            vd->n_cells = static_cast<int>(cells);
            auto &k = vd->knobs;
            k.ran = true;
            const auto bf = [&stage_b](const char *key, float fallback) {
                return stage_b.has(key) ? float(stage_b[key]) : fallback;
            };
            const auto bi = [&stage_b](const char *key, int fallback) {
                return stage_b.has(key) ? int(stage_b[key]) : fallback;
            };
            // day_scale 先过 max(1.0) 再存，与生产同一口径。
            const float day_scale_raw = bf("day_scale", 1.0f);
            k.scale = day_scale_raw < 1.0f ? 1.0f : day_scale_raw;
            k.streak_days = bi("streak_days", 0);
            k.vitality_change_rate = bf("vitality_change_rate", 0.0f);
            k.compat_harshness = bf("compat_harshness", 1.0f);
            k.low_threshold = bf("low_threshold", 0.0f);
            k.high_threshold = bf("high_threshold", 1.0f);
            k.succession_degrade_days = bi("succession_degrade_days", 0);
            k.succession_upgrade_days = bi("succession_upgrade_days", 0);
            k.n_wt = bi("n_wt", 0);
            k.wt_clear_id = bi("wt_clear_id", 0);
            k.veg_none_id = static_cast<uint8_t>(bi("veg_none_id", 0));
            k.weather_penalty_scale = bf("weather_penalty_scale", 1.0f);
            k.plant_water_balance_weight = bf("plant_water_balance_weight", 0.0f);
            k.plant_soil_buffer_weight = bf("plant_soil_buffer_weight", 0.0f);
            k.plant_drought_penalty = bf("plant_drought_penalty", 0.0f);
            k.succession_min_compat_gain = bf("succession_min_compat_gain", 0.0f);
            k.low_vitality_damping_threshold =
                bf("vegetation_low_vitality_damping_threshold", 0.40f);
            k.succession_cooldown_days =
                bi("vegetation_succession_cooldown_days", 30);
            k.degrade_reset_target =
                bf("vegetation_degrade_reset_target", 0.75f);
            k.stress_enabled = bool(stage_b.get("vegetation_stress_enabled", false));
            // stress_blend 生产侧算好再存，两侧各做一次除法会差 ULP。
            float memory_days = bf("vegetation_stress_memory_days", 30.0f);
            if (memory_days < 1.0f) memory_days = 1.0f;
            float blend = k.scale / memory_days;
            if (blend < 0.0f) blend = 0.0f;
            else if (blend > 1.0f) blend = 1.0f;
            k.stress_blend = blend;
            k.wt_blizzard_id = bi("wt_blizzard_id", 3);
            k.wt_drought_id = bi("wt_drought_id", 4);
            k.wt_heatwave_id = bi("wt_heatwave_id", 6);

            bool tables_ok = k.n_wt > 0;
            const auto table_f32 = [&stage_b, &tables_ok](
                    const char *key, std::vector<float> &out_vec) {
                const Variant raw = stage_b.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedFloat32Array v = raw;
                if (v.size() <= 0) {
                    tables_ok = false;
                    return;
                }
                out_vec.assign(v.ptr(), v.ptr() + v.size());
            };
            const auto table_u8 = [&stage_b, &tables_ok](
                    const char *key, std::vector<uint8_t> &out_vec) {
                const Variant raw = stage_b.get(key, Variant());
                if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) {
                    tables_ok = false;
                    return;
                }
                const PackedByteArray v = raw;
                if (v.size() <= 0) {
                    tables_ok = false;
                    return;
                }
                out_vec.assign(v.ptr(), v.ptr() + v.size());
            };
            table_f32("ideal_temp_table", vd->ideal_temp);
            table_f32("ideal_moist_table", vd->ideal_moist);
            table_f32("temp_tol_table", vd->temp_tol);
            table_f32("moist_tol_table", vd->moist_tol);
            table_f32("weather_penalty_table", vd->weather_penalty);
            table_f32("resistance_table", vd->resistance);
            table_u8("next_up_table", vd->next_up);
            table_u8("next_down_table", vd->next_down);
            // 表维度由表长决定（生产也是这么推的）：n_veg 看 ideal_temp，
            // wt_pen_size 可以大于 n_wt。
            k.n_veg = static_cast<int32_t>(vd->ideal_temp.size());
            k.wt_pen_size = static_cast<int32_t>(vd->weather_penalty.size());
            if (k.n_veg <= 0 ||
                static_cast<size_t>(k.n_veg) * static_cast<size_t>(k.n_wt) >
                    vd->resistance.size()) {
                tables_ok = false;
            }

            vd->is_water = snapshot.is_water;
            vd->terrain = snapshot.terrain;
            vd->landform = snapshot.landform;
            vd->vegetation = snapshot.vegetation;
            vd->temp_30d = snapshot.cell_temp_30d;
            vd->moisture = snapshot.cell_moisture;
            vd->water_balance_30d = snapshot.cell_water_balance_30d;
            vd->soil_moisture = snapshot.cell_soil_moisture;
            vd->has_soil_moisture = vd->soil_moisture.size() == cells;
            vd->weather_type = snapshot.cell_weather_type;
            vd->weather_intensity = snapshot.cell_weather_intensity;
            vd->weather_field_init.assign(cells, 1u);
            vd->has_growth_pressure = true;
            // regen_score 没有 store 成员也没有快照 lane，内核用 scratch 承接初值后
            // 丢弃。stress_enabled 时守卫要求它齐长，所以从零起算 —— 与生产读到的
            // 初值有一次性差异，但这条量不参与任何跨天累积。
            if (k.stress_enabled) {
                vd->regen_score.assign(cells, 0.0f);
            }

            if (tables_ok) {
                snapshot.climate_vegetation = vd;
            }
        }
    }

            // ── B8 P2：物理环流 prepass 的标量 ────────────────────────────────
            // 由 MapBaker::runtime_physics_knobs() 投影出的 profile 常量；worker 用
            // 自己的 lane，因此这里只要标量。缺 slp/wind 任一子字典就不置 ready，
            // 并把第一个缺席的键名留给诊断（worker 不跑物理，不静默算错）。
            // 注意：这张 dict 在这个作用域里重新取一次（上面那份 stage_knobs 在更内层
            // 的作用域里）。capture 每帧一次，成本可忽略。
            const Dictionary stage_knobs_phys =
                inputs.has("climate_stage_knobs") &&
                inputs["climate_stage_knobs"].get_type() == Variant::DICTIONARY
                    ? Dictionary(inputs["climate_stage_knobs"]) : Dictionary();
            if (stage_knobs_phys.has("physics_knobs") &&
                stage_knobs_phys["physics_knobs"].get_type() == Variant::DICTIONARY) {
                const Dictionary phys = stage_knobs_phys["physics_knobs"];
                const bool has_slp = phys.has("slp") &&
                    phys["slp"].get_type() == Variant::DICTIONARY;
                const bool has_wind = phys.has("wind") &&
                    phys["wind"].get_type() == Variant::DICTIONARY;
                if (has_slp && has_wind && phys.has("psi") && phys.has("upwelling") &&
                    phys["psi"].get_type() == Variant::DICTIONARY &&
                    phys["upwelling"].get_type() == Variant::DICTIONARY) {
                    const Dictionary slp = phys["slp"];
                    const Dictionary wind = phys["wind"];
                    const Dictionary psi = phys["psi"];
                    const Dictionary up = phys["upwelling"];
                    std::string phys_error;
                    auto bad = [&](const char *key) { if (phys_error.empty()) phys_error = key; };
                    auto pf = [&](const Dictionary &dict, const char *key, double fallback) -> double {
                        if (!dict.has(key)) { bad(key); return fallback; }
                        const Variant v = dict[key];
                        if ((v.get_type() != Variant::FLOAT && v.get_type() != Variant::INT) ||
                            !std::isfinite(double(v))) { bad(key); return fallback; }
                        return double(v);
                    };
                    auto pi = [&](const Dictionary &dict, const char *key, int fallback) -> int {
                        if (!dict.has(key)) { bad(key); return fallback; }
                        const Variant v = dict[key];
                        if (v.get_type() != Variant::INT || int64_t(v) < INT32_MIN || int64_t(v) > INT32_MAX) {
                            bad(key); return fallback;
                        }
                        return int(v);
                    };
                    auto pb = [&](const Dictionary &dict, const char *key, bool fallback) -> bool {
                        if (!dict.has(key) || dict[key].get_type() != Variant::BOOL) { bad(key); return fallback; }
                        return bool(dict[key]);
                    };
                    auto &pk_k = snapshot.climate_physics_knobs;
                    pk_k.slp_lat_amp = pf(slp, "slp_lat_amp", pk_k.slp_lat_amp);
                    pk_k.slp_land_amp = pf(slp, "slp_land_amp", pk_k.slp_land_amp);
                    pk_k.slp_water_damp = pf(slp, "slp_water_damp", pk_k.slp_water_damp);
                    pk_k.slp_interior_boost =
                        pf(slp, "slp_interior_boost", pk_k.slp_interior_boost);
                    pk_k.slp_coast_damp = pf(slp, "slp_coast_damp", pk_k.slp_coast_damp);
                    pk_k.slp_thermal_weight =
                        pf(slp, "wind_thermal_slp_weight", pk_k.slp_thermal_weight);
                    pk_k.slp_ice_high_weight =
                        pf(slp, "slp_ice_high_weight", pk_k.slp_ice_high_weight);
                    pk_k.slp_snow_high_weight =
                        pf(slp, "slp_snow_high_weight", pk_k.slp_snow_high_weight);
                    pk_k.slp_moist_low_weight =
                        pf(slp, "slp_moist_low_weight", pk_k.slp_moist_low_weight);
                    pk_k.slp_response_rate =
                        pf(slp, "slp_response_rate", pk_k.slp_response_rate);
                    pk_k.slp_synoptic_amp =
                        pf(slp, "slp_synoptic_amp", pk_k.slp_synoptic_amp);
                    pk_k.slp_target_p95 =
                        pf(slp, "slp_target_p95", pk_k.slp_target_p95);
                    pk_k.slp_mobile_low_count =
                        pi(slp, "slp_mobile_low_count", pk_k.slp_mobile_low_count);
                    pk_k.slp_mobile_low_amp =
                        pf(slp, "slp_mobile_low_amp", pk_k.slp_mobile_low_amp);
                    pk_k.slp_mobile_low_sigma =
                        pf(slp, "slp_mobile_low_sigma", pk_k.slp_mobile_low_sigma);
                    pk_k.slp_mobile_low_period_days = pf(
                        slp, "slp_mobile_low_period_days",
                        pk_k.slp_mobile_low_period_days);
                    pk_k.slp_smooth_passes =
                        pi(slp, "smooth_passes", pk_k.slp_smooth_passes);
                    pk_k.slp_recenter =
                        pb(slp, "slp_recenter", pk_k.slp_recenter != 0) ? 1 : 0;
                    pk_k.wind_response_rate =
                        pf(wind, "wind_response_rate", pk_k.wind_response_rate);
                    pk_k.wind_max_turn_deg_per_day = pf(
                        wind, "wind_max_turn_deg_per_day",
                        pk_k.wind_max_turn_deg_per_day);
                    pk_k.wind_min_flux_for_dir_update = pf(
                        wind, "wind_min_flux_for_dir_update",
                        pk_k.wind_min_flux_for_dir_update);
                    pk_k.wind_synoptic_amp =
                        pf(wind, "wind_synoptic_amp", pk_k.wind_synoptic_amp);
                    pk_k.wind_synoptic_period_days = pf(
                        wind, "wind_synoptic_period_days",
                        pk_k.wind_synoptic_period_days);
                    pk_k.wind_terrain_aware =
                        pi(wind, "terrain_aware", pk_k.wind_terrain_aware);
                    pk_k.wind_belt_only_debug = pb(
                        wind, "wind_belt_only_debug",
                        pk_k.wind_belt_only_debug != 0) ? 1 : 0;
                    pk_k.wind_momentum_advect_w = pf(
                        wind, "wind_momentum_advect_w", pk_k.wind_momentum_advect_w);
                    pk_k.wind_momentum_diffuse_w_daily = pf(
                        wind, "wind_momentum_diffuse_w_daily",
                        pk_k.wind_momentum_diffuse_w_daily);
                    pk_k.wind_traj_table_enabled = pb(
                        wind, "wind_traj_table_enabled",
                        pk_k.wind_traj_table_enabled != 0) ? 1 : 0;
                    pk_k.wind_traj_pos_scale = pf(
                        wind, "wind_traj_pos_scale", pk_k.wind_traj_pos_scale);
                    pk_k.wind_traj_dt_days = pf(
                        wind, "wind_traj_dt_days", pk_k.wind_traj_dt_days);
                    pk_k.wind_traj_weather_share = pb(
                        wind, "wind_traj_weather_share",
                        pk_k.wind_traj_weather_share != 0) ? 1 : 0;
                    pk_k.wind_div_damp_alpha = pf(
                        wind, "wind_div_damp_alpha", pk_k.wind_div_damp_alpha);
                    pk_k.thermal_monsoon_enabled = pb(
                        wind, "thermal_monsoon_enabled",
                        pk_k.thermal_monsoon_enabled != 0) ? 1 : 0;
                    pk_k.thermal_monsoon_lat_limit = pf(
                        wind, "thermal_monsoon_lat_limit",
                        pk_k.thermal_monsoon_lat_limit);
                    pk_k.thermal_monsoon_deadband = pf(
                        wind, "thermal_monsoon_deadband",
                        pk_k.thermal_monsoon_deadband);
                    pk_k.thermal_monsoon_full_contrast = pf(
                        wind, "thermal_monsoon_full_contrast",
                        pk_k.thermal_monsoon_full_contrast);
                    pk_k.thermal_monsoon_gain = pf(
                        wind, "thermal_monsoon_gain", pk_k.thermal_monsoon_gain);
                    pk_k.thermal_monsoon_breeze_floor = pf(
                        wind, "thermal_monsoon_breeze_floor",
                        pk_k.thermal_monsoon_breeze_floor);
                    pk_k.days_per_year =
                        pi(slp, "days_per_year", pk_k.days_per_year);
                    pk_k.axial_tilt_deg =
                        pf(slp, "axial_tilt_deg", pk_k.axial_tilt_deg);
                    pk_k.insolation_daylen_amp = pf(
                        slp, "insolation_daylen_amp", pk_k.insolation_daylen_amp);
                    pk_k.lat_lut_bins =
                        pi(slp, "slp_lat_lut_bins", pk_k.lat_lut_bins);
                    pk_k.land_lf_mountain =
                        pi(wind, "land_lf_mountain", pk_k.land_lf_mountain);
                    pk_k.land_lf_peak =
                        pi(wind, "land_lf_peak", pk_k.land_lf_peak);
                    pk_k.land_lf_hill =
                        pi(wind, "land_lf_hill", pk_k.land_lf_hill);
                    pk_k.enabled = pb(phys, "enabled", false);
                    pk_k.daily_split = pb(phys, "daily_split", false);
                    pk_k.daily_period_days = pi(phys, "daily_period_days", 1);
                    pk_k.ocean_period_days = pi(phys, "ocean_period_days", 30);
                    pk_k.world_seed = pi(phys, "world_seed", 0);
                    pk_k.wrap_origin_x = pf(slp, "wrap_origin_x", 0.0);
                    pk_k.wrap_period_x = pf(slp, "wrap_period_x", 0.0);
                    if (!phys.has("water_terrain_ids") || phys["water_terrain_ids"].get_type() != Variant::PACKED_BYTE_ARRAY) {
                        bad("water_terrain_ids");
                    } else {
                        const PackedByteArray ids = phys["water_terrain_ids"];
                        if (ids.size() != 4) bad("water_terrain_ids");
                        else {
                            pk_k.water_id_count = 4;
                            std::copy_n(ids.ptr(), 4, pk_k.water_terrain_ids.begin());
                        }
                    }
                    auto &p = pk_k.psi;
                    p.total_iters = pi(psi, "psi_total_iters", p.total_iters);
                    p.omega = pf(psi, "psi_sor_omega", p.omega);
                    p.r_base = pf(psi, "psi_r_base", p.r_base);
                    p.beta_floor = pf(psi, "psi_beta_floor", p.beta_floor);
                    p.source_scale = pf(psi, "psi_source_scale", p.source_scale);
                    p.oc_scale = pf(psi, "ocean_current_scale", p.oc_scale);
                    p.oc_max_mag = pf(psi, "ocean_current_max_magnitude", p.oc_max_mag);
                    p.thermohaline_weight = pf(psi, "thermohaline_weight", p.thermohaline_weight);
                    p.upwelling_highlat_abs = pf(psi, "upwelling_highlat_abs", p.upwelling_highlat_abs);
                    p.cold_sink_temp = pf(psi, "cold_sink_temp", p.cold_sink_temp);
                    p.response_rate = pf(psi, "ocean_current_response_rate", p.response_rate);
                    p.thermal_current_weight = pf(psi, "ocean_thermal_current_weight", p.thermal_current_weight);
                    p.density_cold_weight = pf(psi, "ocean_density_cold_weight", p.density_cold_weight);
                    p.density_ice_weight = pf(psi, "ocean_density_ice_weight", p.density_ice_weight);
                    p.depth_curl_damp = pf(psi, "ocean_depth_curl_damp", p.depth_curl_damp);
                    p.sea_level = pf(psi, "sea_level", p.sea_level);
                    p.depth_ref = pf(psi, "ocean_depth_ref", p.depth_ref);
                    p.topo_steer_w = pf(psi, "ocean_topo_steer_w", p.topo_steer_w);
                    pk_k.psi_warm_start = pb(psi, "psi_warm_start", true);
                    String mode;
                    if (!psi.has("psi_early_exit_mode") || psi["psi_early_exit_mode"].get_type() != Variant::STRING)
                        bad("psi_early_exit_mode");
                    else mode = psi["psi_early_exit_mode"];
                    p.early_exit = mode == "balanced" || mode == "perf";
                    if (!p.early_exit && mode != "off") bad("psi_early_exit_mode");
                    p.min_iters = mode == "balanced" ? 8 : (mode == "perf" ? 6 : p.total_iters);
                    p.residual_epsilon = mode == "balanced" ? 0.00035f : (mode == "perf" ? 0.00075f : 0.0f);
                    if (p.early_exit && !pk_k.psi_warm_start) p.min_iters += 4;
                    p.min_iters = std::max(1, std::min(p.total_iters, p.min_iters));
                    p.check_every = 2;
                    pk_k.upwelling.ekman_gain = pf(up, "upwelling_ekman_gain", 0.6);
                    pk_k.upwelling.cold_sink_gain = pf(up, "upwelling_cold_sink_gain", 0.15);
                    pk_k.upwelling.highlat_abs = pf(up, "upwelling_highlat_abs", 0.75);
                    pk_k.upwelling.cold_sink_temp = pf(up, "cold_sink_temp", -0.05);
                    std::string bounds_error;
                    if (!pk_k.validate(bounds_error) && phys_error.empty()) phys_error = bounds_error;
                    pk_k.ready = phys_error.empty() ? 1 : 0;
                    std::snprintf(pk_k.missing_key, sizeof(pk_k.missing_key), "%s", phys_error.c_str());
                } else {
                    std::snprintf(
                        snapshot.climate_physics_knobs.missing_key,
                        sizeof(snapshot.climate_physics_knobs.missing_key),
                        "%s", has_slp ? "physics_knobs.wind" : "physics_knobs.slp");
                }
            } else {
                std::snprintf(
                    snapshot.climate_physics_knobs.missing_key,
                    sizeof(snapshot.climate_physics_knobs.missing_key),
                    "physics_knobs");
            }

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
    std::string validation_error;
    if (!validate_runtime_environment_snapshot(snapshot, validation_error)) {
        out["ok"] = false;
        out["code"] = String(validation_error.c_str());
        return out;
    }
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
    if (economy_input_lane_needed) {
        auto economy_input = std::make_shared<RuntimeEconomyDayInput>();
        economy_input->day = snapshot.day;
        economy_input->cell_count = static_cast<uint32_t>(cells);
        const char *fields[] = {"cell_temp", "cell_temp_30d", "cell_moisture",
            "cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
            "cell_weather_intensity", "cell_elevation", "cell_temp_365d"};
        auto copy_slot_f32 = [&](const char *name, std::vector<float> &dest) {
            const int sid = component_id(StringName(name));
            if (sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32 &&
                static_cast<size_t>(_slots[sid].arr_f32.size()) == cells) {
                const auto &array = _slots[sid].arr_f32;
                dest.assign(array.ptr(), array.ptr() + array.size());
            }
        };
        for (size_t i = 0; i < economy_input->fields.size(); ++i)
            copy_slot_f32(fields[i], economy_input->fields[i]);
        const char *climate_u8[] = {"cell_weather_type", "cell_cover"};
        for (size_t i = 0; i < economy_input->climate_u8.size(); ++i) {
            const int sid = component_id(StringName(climate_u8[i]));
            if (sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::U8 &&
                static_cast<size_t>(_slots[sid].arr_u8.size()) == cells) {
                const auto &array = _slots[sid].arr_u8;
                economy_input->climate_u8[i].assign(
                    array.ptr(), array.ptr() + array.size());
            }
        }
        const char *geography[] = {"cell_terrain", "cell_landform", "cell_vegetation",
            "cell_is_water", "cell_has_river"};
        for (size_t i = 0; i < 5; ++i) {
            const int sid = component_id(StringName(geography[i]));
            if (sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::U8 &&
                static_cast<size_t>(_slots[sid].arr_u8.size()) == cells) {
                const auto &array = _slots[sid].arr_u8;
                economy_input->geography[i].assign(array.ptr(), array.ptr() + array.size());
            }
        }
        // [neighbor-csr-to-dense 2026-11-02] 环境快照现在可能走 CSR 拓扑
        // (neighbor_offsets = cells+1, neighbor_indices = 总邻居数)，而经济 worker 的
        // 输入契约要求**稠密** cells*6 布局（消费方按 neighbors[cell*6+k] 取值），
        // 且 capture_worker_day_input() 直接用 `neighbors.size() != cells*6` 判失败
        // → world_clock.pause(true)，真机表现就是"日期停在 day 0"。
        // 这里在喂给经济输入时把 CSR 展开成稠密表，缺邻居填 -1（沿用稠密表的哨兵值）。
        economy_input->neighbors = snapshot.neighbor_indices;
        if (economy_input->neighbors.size() != static_cast<size_t>(cells) * 6u &&
            snapshot.neighbor_offsets.size() == static_cast<size_t>(cells) + 1u) {
            std::vector<int32_t> dense(static_cast<size_t>(cells) * 6u, -1);
            for (size_t c = 0; c < static_cast<size_t>(cells); ++c) {
                const int32_t begin = snapshot.neighbor_offsets[c];
                const int32_t end = snapshot.neighbor_offsets[c + 1];
                if (begin < 0 || end < begin) continue;
                size_t slot = 0;
                for (int32_t k = begin; k < end && slot < 6u; ++k, ++slot) {
                    if (static_cast<size_t>(k) >= snapshot.neighbor_indices.size()) break;
                    dense[c * 6u + slot] = snapshot.neighbor_indices[static_cast<size_t>(k)];
                }
            }
            economy_input->neighbors = std::move(dense);
        }
        economy_input->fog_solved = snapshot.fog_solved;
        economy_input->geography[5] = snapshot.visible;
        const auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
        const auto &reserve_slots = economy->building_resource_reserve_slots();
        const auto &extra_slots = economy->building_resource_extra_slots();
        economy_input->reserves.resize(reserve_slots.size());
        economy_input->changes.resize(extra_slots.size());
        for (size_t r = 0; r < reserve_slots.size(); ++r)
            copy_slot_f32(reserve_slots[r].c_str(), economy_input->reserves[r]);
        for (size_t r = 0; r < extra_slots.size(); ++r)
            copy_slot_f32(extra_slots[r].c_str(), economy_input->changes[r]);
        const int habitat_sid = component_id(StringName("cell_resource_habitat_mask"));
        if (habitat_sid >= 0 && habitat_sid < _slots.size() &&
            _slots[habitat_sid].dtype == SlotDType::U8 &&
            static_cast<size_t>(_slots[habitat_sid].arr_u8.size()) == cells) {
            const auto &array = _slots[habitat_sid].arr_u8;
            economy_input->resource_habitat.assign(array.ptr(), array.ptr() + array.size());
        }
        snapshot.economy_input = std::move(economy_input);
    }
    if (!_runtime_host->publish_environment(snapshot, publish_error)) {
        out["ok"] = false;
        out["code"] = String(publish_error.empty()
            ? "runtime_input_publish_failed" : publish_error.c_str());
        out["generation"] = static_cast<int64_t>(snapshot.generation);
        out["day"] = snapshot.day;
        out["expected_day"] = _runtime_host->next_environment_day();
        return out;
    }
    _climate_physics_capture_ready = physics_capture_ready;
    out["physics_ready"] = physics_capture_ready;
    out["ok"] = true;
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["day"] = snapshot.day;
    out["dt_days"] = snapshot.dt_days;
    out["climate_input_complete"] = snapshot.climate_input_complete;
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
