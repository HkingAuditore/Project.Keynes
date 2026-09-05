#include "world_ext.h"
#include "native_simulation_host.h"
#include "native_parallel_executor.h"
#include "runtime_domain_pod.h"
#include "runtime_country_pod.h"
#include "runtime_protocol_guard.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace pk {

using namespace godot;

static String runtime_state_name(RuntimeWorkerState state) {
    switch (state) {
        case RuntimeWorkerState::STOPPED: return "STOPPED";
        case RuntimeWorkerState::STARTING: return "STARTING";
        case RuntimeWorkerState::RUNNING: return "RUNNING";
        case RuntimeWorkerState::PAUSED: return "PAUSED";
        case RuntimeWorkerState::SAVE_PENDING: return "SAVE_PENDING";
        case RuntimeWorkerState::STOPPING: return "STOPPING";
        case RuntimeWorkerState::FAULTED: return "FAULTED";
    }
    return "UNKNOWN";
}

static String runtime_mode_name(RuntimeSimulationMode mode) {
    switch (mode) {
        case RuntimeSimulationMode::OFF: return "OFF";
        case RuntimeSimulationMode::SHADOW: return "SHADOW";
        case RuntimeSimulationMode::ACTIVE: return "ACTIVE";
    }
    return "OFF";
}

static bool parse_runtime_mode(const Dictionary &config,
                               RuntimeSimulationMode &mode,
                               String &error) {
    const StringName mode_key("simulation_thread_mode");
    const StringName alias_key("mode");
    Variant raw = config.has(mode_key) ? config[mode_key]
        : (config.has(alias_key) ? config[alias_key] : Variant("ACTIVE"));
    if (raw.get_type() == Variant::INT) {
        const int64_t value = static_cast<int64_t>(raw);
        if (value < static_cast<int64_t>(RuntimeSimulationMode::OFF) ||
            value > static_cast<int64_t>(RuntimeSimulationMode::ACTIVE)) {
            error = "runtime_thread_mode_invalid";
            return false;
        }
        mode = static_cast<RuntimeSimulationMode>(value);
        return true;
    }
    if (raw.get_type() != Variant::STRING) {
        error = "runtime_thread_mode_invalid";
        return false;
    }
    const String value = static_cast<String>(raw).to_upper();
    if (value == "OFF") mode = RuntimeSimulationMode::OFF;
    else if (value == "SHADOW") mode = RuntimeSimulationMode::SHADOW;
    else if (value == "ACTIVE") mode = RuntimeSimulationMode::ACTIVE;
    else {
        error = "runtime_thread_mode_invalid";
        return false;
    }
    return true;
}

static Dictionary runtime_report_to_dictionary(const RuntimeThreadReport &report) {
    Dictionary out;
    out["domain_abi_version"] = static_cast<int>(report.domain_abi_version);
    out["pod_domain_abi_version"] = static_cast<int>(report.pod_domain_abi_version);
    // Keep the explicit protocol name as a stable diagnostic alias.
    out["runtime_domain_abi_version"] = static_cast<int>(report.domain_abi_version);
    out["state"] = runtime_state_name(report.state);
    out["state_id"] = static_cast<int>(report.state);
    out["requested_simulation_thread_mode"] = runtime_mode_name(report.mode);
    out["simulation_thread_mode"] = runtime_mode_name(report.mode);
    out["graph_coverage_complete"] = report.graph_coverage_complete;
    out["authority_ready"] = report.authority_ready;
    out["required_domain_mask"] = static_cast<int64_t>(report.required_domain_mask);
    out["implemented_domain_mask"] = static_cast<int64_t>(report.implemented_domain_mask);
    out["missing_domain_mask"] = static_cast<int64_t>(report.missing_domain_mask);
    out["graph_coverage_state"] = String(report.graph_coverage_state);
    out["coverage_blocker"] = String(report.coverage_blocker);
    out["simulation_worker_blocker"] = String(report.coverage_blocker);
    out["interactive"] = report.interactive;
    out["paused"] = report.paused;
    out["speed_days_per_second"] = report.speed_days_per_second;
    out["committed_day"] = report.committed_day;
    out["generation"] = static_cast<int64_t>(report.generation);
    out["state_hash"] = static_cast<int64_t>(report.state_hash);
    out["last_commit_produced_at_us"] = static_cast<int64_t>(report.last_commit_produced_at_us);
    out["last_visual_publish_at_us"] = static_cast<int64_t>(report.last_visual_publish_at_us);
    out["snapshot_staleness_ms"] = report.snapshot_staleness_ms;
    out["ui_input_to_feedback_ms"] = report.ui_input_to_feedback_ms;
    out["visual_apply_ms"] = report.visual_apply_ms;
    out["gpu_upload_ms"] = report.gpu_upload_ms;
    out["main_wait_on_sim_us"] = static_cast<int64_t>(report.main_wait_on_sim_us);
    out["environment_generation"] = static_cast<int64_t>(report.environment_generation);
    out["environment_day"] = report.environment_day;
    out["environment_cell_count"] = static_cast<int>(report.environment_cell_count);
    out["environment_topology_validated"] = report.environment_topology_validated;
    out["invalid_environment_rejected"] = static_cast<int64_t>(report.invalid_environment_rejected);
    out["stale_environment_rejected"] = static_cast<int64_t>(report.stale_environment_rejected);
    out["command_queue_capacity_exceeded"] = static_cast<int64_t>(report.command_queue_capacity_exceeded);
    out["receipt_queue_capacity_exceeded"] = static_cast<int64_t>(report.receipt_queue_capacity_exceeded);
    out["snapshot_publish_drop_count"] = static_cast<int64_t>(report.snapshot_publish_drop_count);
    out["snapshot_publish_throttled_count"] = static_cast<int64_t>(report.snapshot_publish_throttled_count);
    out["worker_fault_count"] = static_cast<int64_t>(report.worker_fault_count);
    out["completed_days"] = static_cast<int64_t>(report.completed_days);
    out["day_stage_count"] = static_cast<int>(report.day_stage_count);
    out["day_completed_stage_count"] = static_cast<int>(report.day_completed_stage_count);
    out["day_work_units"] = static_cast<int64_t>(report.day_work_units);
    out["pod_completed_domain_mask"] = static_cast<int64_t>(report.pod_completed_domain_mask);
    out["pod_completed_stage_count"] = static_cast<int>(report.pod_completed_stage_count);
    out["pod_work_units"] = static_cast<int64_t>(report.pod_work_units);
    out["pod_intent_count"] = static_cast<int>(report.pod_intent_count);
    out["pod_fallback_count"] = static_cast<int>(report.pod_fallback_count);
    out["domain_authority_planned_mask"] = static_cast<int64_t>(
        report.domain_authority_planned_mask);
    out["domain_authority_committed_mask"] = static_cast<int64_t>(
        report.domain_authority_committed_mask);
    out["domain_authority_ack_count"] = static_cast<int>(
        report.domain_authority_ack_count);
    out["domain_authority_input_hash"] = static_cast<int64_t>(
        report.domain_authority_input_hash);
    out["domain_authority_state_hash"] = static_cast<int64_t>(
        report.domain_authority_state_hash);
    out["domain_authority_plan_ms"] = report.domain_authority_plan_ms;
    out["domain_authority_replay_ms"] = report.domain_authority_replay_ms;
    out["domain_authority_fallback_reason"] = String(
        report.domain_authority_fallback_reason);
    out["domain_stage_fallback_count"] = static_cast<int>(
        report.domain_stage_fallback_count);
    out["domain_stage_fallback_reason"] = String(
        report.domain_stage_fallback_reason);
    out["climate_pod_ready"] = report.climate_pod_ready;
    out["climate_pod_plan_ms"] = report.climate_pod_plan_ms;
    out["climate_pod_replay_ms"] = report.climate_pod_replay_ms;
    out["climate_pod_work_units"] = static_cast<int64_t>(report.climate_pod_work_units);
    out["climate_pod_changed_cells"] = static_cast<int>(report.climate_pod_changed_cells);
    out["climate_pod_state_hash"] = static_cast<int64_t>(report.climate_pod_state_hash);
    out["climate_pod_reference_hash"] = static_cast<int64_t>(report.climate_pod_reference_hash);
    out["climate_pod_parity_compared"] = report.climate_pod_parity_compared;
    out["climate_pod_parity_matched"] = report.climate_pod_parity_matched;
    out["climate_pod_parity_mismatch_count"] = static_cast<int64_t>(report.climate_pod_parity_mismatch_count);
    out["climate_pod_parity_reason"] = String(report.climate_pod_parity_reason);
    out["climate_parity_day"] = report.climate_parity_day;
    out["climate_parity_stage"] = static_cast<int>(report.climate_parity_stage);
    out["climate_parity_cell"] = static_cast<int>(report.climate_parity_cell);
    out["climate_parity_input_generation"] = static_cast<int64_t>(report.climate_parity_input_generation);
    out["climate_parity_base_generation"] = static_cast<int64_t>(report.climate_parity_base_generation);
    out["climate_parity_trace_hash"] = static_cast<int64_t>(report.climate_parity_trace_hash);
    out["climate_parity_field"] = String(report.climate_parity_field);
    out["climate_parity_reference_bits"] = String(report.climate_parity_reference_bits);
    out["climate_parity_worker_bits"] = String(report.climate_parity_worker_bits);
    out["climate_pod_fallback_reason"] = String(report.climate_pod_fallback_reason);
    out["command_queue_depth"] = static_cast<int>(report.command_queue_depth);
    out["receipt_queue_depth"] = static_cast<int>(report.receipt_queue_depth);
    out["time_debt_days"] = report.time_debt_days;
    out["climate_trace_depth"] = static_cast<int>(report.climate_trace_depth);
    out["climate_trace_front_day"] = report.climate_trace_front_day;
    out["climate_trace_lag_days"] = report.climate_trace_lag_days;
    out["climate_trace_latest_hash"] = static_cast<int64_t>(
        report.climate_trace_latest_hash);
    out["climate_trace_capacity_exceeded"] = static_cast<int64_t>(report.climate_trace_capacity_exceeded);
    out["climate_trace_consumed"] = static_cast<int64_t>(report.climate_trace_consumed);
    out["climate_trace_missing"] = static_cast<int64_t>(report.climate_trace_missing);
    out["climate_trace_captured"] = static_cast<int>(report.climate_trace_captured);
    out["climate_trace_reference_ready"] = static_cast<int>(report.climate_trace_reference_ready);
    out["climate_trace_consumable"] = static_cast<int>(report.climate_trace_consumable);
    out["climate_trace_reference_rejected"] = static_cast<int64_t>(report.climate_trace_reference_rejected);
    out["climate_trace_reference_pending"] = static_cast<int64_t>(report.climate_trace_reference_pending);
    out["executor_workers"] = static_cast<int>(report.executor_workers);
    out["country_pod_snapshot_generation"] = static_cast<int64_t>(report.country_pod_snapshot_generation);
    out["country_pod_state_hash"] = static_cast<int64_t>(report.country_pod_state_hash);
    out["country_pod_work_units"] = static_cast<int64_t>(report.country_pod_work_units);
    out["country_pod_active_country_count"] = static_cast<int>(report.country_pod_active_country_count);
    out["country_pod_active_index_count"] = static_cast<int>(report.country_pod_active_index_count);
    out["country_pod_pending_checks"] = static_cast<int>(report.country_pod_pending_checks);
    out["country_pod_ack_pending"] = report.country_pod_ack_pending;
    out["country_pod_blocker"] = String(report.country_pod_blocker);
    out["fault_code"] = String(report.fault_code);
    return out;
}

Dictionary DCWorldExt::start_runtime_worker(const Dictionary &config) {
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    RuntimeSimulationMode mode = RuntimeSimulationMode::ACTIVE;
    String mode_error;
    Dictionary out;
    if (!parse_runtime_mode(config, mode, mode_error)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = mode_error;
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    const bool complete = static_cast<bool>(config.get("graph_coverage_complete", false));
    const int64_t day = static_cast<int64_t>(config.get("day", 0));
    const double requested_speed = static_cast<double>(config.get("speed_days_per_second", 1.0));
    const double speed = std::isfinite(requested_speed) ? std::max(0.0, requested_speed) : 0.0;
    const bool paused = static_cast<bool>(config.get("paused", false));
    if (day < 0 || !std::isfinite(requested_speed)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_config_invalid";
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    const RuntimeWorkerState before = _runtime_host->state();
    if (before != RuntimeWorkerState::STOPPED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_thread_mode_hot_switch_forbidden";
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (!complete || NativeSimulationHost::implemented_domain_mask() !=
            RUNTIME_ALL_DOMAIN_MASK)) {
        out["ok"] = false;
        out["pending"] = false;
        const bool domains_missing = complete &&
            NativeSimulationHost::implemented_domain_mask() != RUNTIME_ALL_DOMAIN_MASK;
        out["code"] = domains_missing
            ? "runtime_native_domains_incomplete"
            : "runtime_graph_not_thread_safe";
        out["message"] = domains_missing
            ? "native_domain_pod_handlers_incomplete"
            : "runtime_graph_contains_godot_bridge";
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    if (!_runtime_host->start(mode, complete, day, speed, paused)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_start_failed";
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    // A DCWorldExt instance may be reused for a second world after the prior
    // worker has stopped.  Do not let the new run expose the previous world's
    // commit or visual intents through the main-thread cache.
    _runtime_commit_cache = RuntimeCommit{};
    _runtime_commit_cache_generation = 0;
    _runtime_commit_cache_valid = false;
    out["ok"] = true;
    out["pending"] = mode != RuntimeSimulationMode::OFF;
    out["code"] = "ok";
    out["requested_simulation_thread_mode"] = runtime_mode_name(mode);
    out["state"] = runtime_state_name(_runtime_host->state());
    out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
    return out;
}

Dictionary DCWorldExt::record_runtime_visual_timings(
        double ui_input_to_feedback_ms,
        double visual_apply_ms,
        double gpu_upload_ms) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->record_visual_timings(ui_input_to_feedback_ms,
                                         visual_apply_ms,
                                         gpu_upload_ms);
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::set_runtime_clock(bool paused, double speed_days_per_second) {
    Dictionary out;
    if (!std::isfinite(speed_days_per_second) || speed_days_per_second < 0.0) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_clock_invalid";
        return out;
    }
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED ||
        _runtime_host->state() == RuntimeWorkerState::STOPPING ||
        _runtime_host->state() == RuntimeWorkerState::FAULTED) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_clock(paused, speed_days_per_second);
    out["ok"] = true;
    out["pending"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::set_runtime_qos_threaded(bool interactive) {
    Dictionary out;
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED ||
        _runtime_host->state() == RuntimeWorkerState::STOPPING ||
        _runtime_host->state() == RuntimeWorkerState::FAULTED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    // QoS is a release/acquire hint only. The facade never waits for the
    // coordinator or executor, so input handling remains independent of the
    // simulation worker even while a large day is being computed.
    _runtime_host->set_interactive(interactive);
    NativeParallelExecutor::instance().set_interactive(interactive);
    out["ok"] = true;
    out["pending"] = true;
    out["interactive"] = interactive;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::capture_runtime_inputs(const Dictionary &inputs) {
    Dictionary out;
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
    if (!_runtime_host->publish_environment(snapshot, publish_error)) {
        out["ok"] = false;
        out["code"] = String(publish_error.empty()
            ? "runtime_input_publish_failed" : publish_error.c_str());
        out["generation"] = static_cast<int64_t>(snapshot.generation);
        return out;
    }
    out["ok"] = true;
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["day"] = snapshot.day;
    out["dt_days"] = snapshot.dt_days;
    out["climate_input_complete"] = snapshot.climate_input_complete;
    out["cell_count"] = static_cast<int64_t>(cells);
    return out;
}

Dictionary DCWorldExt::publish_runtime_climate_reference(
        int64_t day, int64_t state_hash) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (day < 0 || state_hash <= 0) {
        out["ok"] = false;
        out["code"] = "climate_trace_reference_invalid";
        return out;
    }
    std::string error;
    if (!_runtime_host->publish_climate_reference(
            day, static_cast<uint64_t>(state_hash), error)) {
        out["ok"] = false;
        out["code"] = String(error.c_str());
        return out;
    }
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    out["day"] = day;
    out["state_hash"] = state_hash;
    return out;
}

Dictionary DCWorldExt::submit_runtime_command(const Dictionary &command) {
    Dictionary out;
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (_runtime_host->state() == RuntimeWorkerState::FAULTED) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "worker_faulted";
        return out;
    }
    if (_runtime_host->state() == RuntimeWorkerState::STOPPING) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_stopping";
        return out;
    }
    RuntimeCommandPacket packet;
    const auto read_i64 = [&command](const char *key, int64_t fallback,
                                     int64_t &value) -> bool {
        if (!command.has(key)) { value = fallback; return true; }
        const Variant raw = command[key];
        if (raw.get_type() != Variant::INT) return false;
        value = static_cast<int64_t>(raw);
        return true;
    };
    int64_t request_id = 0;
    int64_t producer_id = 0;
    int64_t sequence = 0;
    int64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t domain = 0;
    int64_t opcode = 0;
    if (!read_i64("request_id", 0, request_id) ||
        !read_i64("producer_id", 0, producer_id) ||
        !read_i64("sequence", 0, sequence) ||
        !read_i64("observed_generation", 0, observed_generation) ||
        !read_i64("requested_day", 0, requested_day) ||
        !read_i64("domain", 0, domain) ||
        !read_i64("opcode", 0, opcode) ||
        request_id <= 0 || producer_id < 0 || sequence < 0 ||
        observed_generation < 0 || requested_day < 0 ||
        domain < 0 || domain > 65535 || opcode < 0 || opcode > 65535) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "invalid_command_value";
        return out;
    }
    packet.envelope.request_id = static_cast<uint64_t>(request_id);
    packet.envelope.producer_id = static_cast<uint32_t>(producer_id);
    packet.envelope.sequence = static_cast<uint64_t>(sequence);
    if (packet.envelope.sequence == 0) {
        packet.envelope.sequence = _runtime_host->allocate_producer_sequence(
            packet.envelope.producer_id);
    }
    packet.envelope.observed_generation = static_cast<uint64_t>(observed_generation);
    packet.envelope.requested_day = requested_day;
    packet.envelope.domain = static_cast<uint16_t>(domain);
    packet.envelope.opcode = static_cast<uint16_t>(opcode);
    const RuntimeThreadReport report = _runtime_host->report();
    packet.envelope.effective_day = std::max<int64_t>(
        packet.envelope.requested_day, report.committed_day + 1);
    PackedByteArray payload;
    if (command.has("payload")) {
        const Variant payload_value = command["payload"];
        if (payload_value.get_type() != Variant::PACKED_BYTE_ARRAY) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "invalid_command_payload";
            return out;
        }
        payload = payload_value;
    }
    if (payload.size() > RUNTIME_MAX_COMMAND_PAYLOAD) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "invalid_command_payload";
        return out;
    }
    packet.envelope.payload_offset = 0;
    packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    if (!payload.is_empty()) std::memcpy(packet.payload.data(), payload.ptr(), payload.size());
    if (!_runtime_host->enqueue(packet)) {
        out["ok"] = false;
        out["pending"] = false;
        const RuntimeWorkerState state = _runtime_host->state();
        out["code"] = state == RuntimeWorkerState::FAULTED
            ? "worker_faulted" : "command_queue_capacity_exceeded";
        out["request_id"] = static_cast<int64_t>(packet.envelope.request_id);
        return out;
    }
    out["ok"] = true;
    out["pending"] = true;
    out["request_id"] = static_cast<int64_t>(packet.envelope.request_id);
    out["producer_id"] = static_cast<int>(packet.envelope.producer_id);
    out["sequence"] = static_cast<int64_t>(packet.envelope.sequence);
    out["effective_day"] = packet.envelope.effective_day;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::poll_runtime_receipts(int max_items) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    Array receipts;
    const int limit = std::clamp(max_items, 0, 8192);
    for (int i = 0; i < limit; ++i) {
        RuntimeCommandReceipt receipt;
        if (!_runtime_host->poll_receipt(receipt)) break;
        Dictionary item;
        item["request_id"] = static_cast<int64_t>(receipt.request_id);
        item["producer_id"] = static_cast<int>(receipt.producer_id);
        item["sequence"] = static_cast<int64_t>(receipt.sequence);
        item["effective_day"] = receipt.effective_day;
        item["generation"] = static_cast<int64_t>(receipt.generation);
        item["code"] = static_cast<int>(receipt.code);
        receipts.push_back(item);
    }
    out["ok"] = true;
    out["receipts"] = receipts;
    out["count"] = receipts.size();
    return out;
}

Dictionary DCWorldExt::poll_runtime_commit(int64_t after_generation) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeCommit commit;
    const uint64_t after = static_cast<uint64_t>(std::max<int64_t>(0, after_generation));
    if (!_runtime_host->poll_commit(after, commit)) {
        out["ok"] = true;
        out["pending"] = true;
        out["available"] = false;
        return out;
    }
    _runtime_commit_cache = commit;
    _runtime_commit_cache_generation = commit.header.generation;
    _runtime_commit_cache_valid = true;
    const RuntimeCommitHeader &h = commit.header;
    out["ok"] = true;
    out["pending"] = false;
    out["available"] = true;
    out["generation"] = static_cast<int64_t>(h.generation);
    out["from_day"] = h.from_day;
    out["committed_day"] = h.committed_day;
    out["produced_at_us"] = static_cast<int64_t>(h.produced_at_us);
    out["dirty_families"] = static_cast<int64_t>(h.dirty_families);
    out["state_hash"] = static_cast<int64_t>(h.state_hash);
    out["command_receipt_count"] = static_cast<int>(h.command_receipt_count);
    PackedInt64Array dirty_family_generations;
    dirty_family_generations.resize(RUNTIME_DIRTY_FAMILY_COUNT);
    for (size_t i = 0; i < RUNTIME_DIRTY_FAMILY_COUNT; ++i) {
        dirty_family_generations[static_cast<int>(i)] =
            static_cast<int64_t>(h.dirty_family_generations[i]);
    }
    out["dirty_family_generations"] = dirty_family_generations;
    Array receipts;
    for (const RuntimeCommandReceipt &receipt : commit.receipts) {
        Dictionary item;
        item["request_id"] = static_cast<int64_t>(receipt.request_id);
        item["producer_id"] = static_cast<int>(receipt.producer_id);
        item["sequence"] = static_cast<int64_t>(receipt.sequence);
        item["effective_day"] = receipt.effective_day;
        item["generation"] = static_cast<int64_t>(receipt.generation);
        item["code"] = static_cast<int>(receipt.code);
        receipts.push_back(item);
    }
    out["receipts"] = receipts;
    PackedInt32Array cells;
    PackedInt32Array fields;
    PackedInt32Array values_i32;
    PackedFloat32Array values_f32;
    for (const RuntimeVisualIntent &intent : commit.visual_intents) {
        cells.push_back(static_cast<int32_t>(intent.cell_index));
        fields.push_back(static_cast<int32_t>(intent.field_id));
        values_i32.push_back(intent.value_i32);
        values_f32.push_back(intent.value_f32);
    }
    out["visual_cell_indices"] = cells;
    out["visual_field_ids"] = fields;
    out["visual_values_i32"] = values_i32;
    out["visual_values_f32"] = values_f32;
    return out;
}

Dictionary DCWorldExt::consume_runtime_visual_patch(int64_t generation, int family,
                                                    int cursor, int max_items) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeCommit commit;
    uint64_t requested_generation = static_cast<uint64_t>(std::max<int64_t>(0, generation));
    bool have_commit = requested_generation == 0 && _runtime_commit_cache_valid;
    if (have_commit) {
        commit = _runtime_commit_cache;
        requested_generation = commit.header.generation;
    } else if (_runtime_commit_cache_valid &&
               _runtime_commit_cache_generation == requested_generation) {
        commit = _runtime_commit_cache;
        have_commit = true;
    } else if (_runtime_commit_cache_valid && requested_generation > 0 &&
               _runtime_commit_cache_generation > requested_generation) {
        out["ok"] = true;
        out["available"] = false;
        out["code"] = "runtime_generation_expired";
        return out;
    } else {
        const uint64_t after = requested_generation > 0 ? requested_generation - 1 : 0;
        if (_runtime_host->poll_commit(after, commit) &&
            (requested_generation == 0 || commit.header.generation == requested_generation)) {
            _runtime_commit_cache = commit;
            _runtime_commit_cache_generation = commit.header.generation;
            _runtime_commit_cache_valid = true;
            have_commit = true;
        }
    }
    if (!have_commit) {
        out["ok"] = true;
        out["available"] = false;
        out["code"] = requested_generation > 0 ? "runtime_generation_unavailable" : "runtime_commit_unavailable";
        return out;
    }
    const int total = static_cast<int>(commit.visual_intents.size());
    const int begin = std::clamp(cursor, 0, total);
    const int limit = std::max(0, max_items);
    PackedInt32Array cells;
    PackedInt32Array fields;
    PackedInt32Array values_i32;
    PackedFloat32Array values_f32;
    int emitted = 0;
    int next_cursor = begin;
    for (; next_cursor < total && emitted < limit; ++next_cursor) {
        const RuntimeVisualIntent &intent = commit.visual_intents[static_cast<size_t>(next_cursor)];
        if (family != 0 && static_cast<int>(intent.family) != family) continue;
        cells.push_back(static_cast<int32_t>(intent.cell_index));
        fields.push_back(static_cast<int32_t>(intent.field_id));
        values_i32.push_back(intent.value_i32);
        values_f32.push_back(intent.value_f32);
        ++emitted;
    }
    out["ok"] = true;
    out["available"] = true;
    out["generation"] = static_cast<int64_t>(commit.header.generation);
    out["next_cursor"] = next_cursor;
    out["done"] = next_cursor >= total;
    out["cell_indices"] = cells;
    out["field_ids"] = fields;
    out["values_i32"] = values_i32;
    out["values_f32"] = values_f32;
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
    out["checksum"] = static_cast<int64_t>(bundle->checksum);
    out["bytes"] = bytes;
    return out;
}

Dictionary DCWorldExt::restore_runtime_bundle(const PackedByteArray &bytes) {
    Dictionary out;
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    if (bytes.is_empty()) {
        out["ok"] = false;
        out["code"] = "runtime_bundle_empty";
        out["state"] = runtime_state_name(_runtime_host->state());
        return out;
    }
    std::string error;
    if (!_runtime_host->restore_bundle(bytes.ptr(),
                                       static_cast<size_t>(bytes.size()), error)) {
        out["ok"] = false;
        out["code"] = String(error.c_str());
        out["state"] = runtime_state_name(_runtime_host->state());
        return out;
    }
    // The bundle is held by the host until the next start() consumes it.  Do
    // not expose or decode the payload here; this call remains a main-thread
    // validation/copy boundary only.
    out["ok"] = true;
    out["pending"] = true;
    out["restored"] = true;
    out["code"] = "ok";
    out["state"] = runtime_state_name(_runtime_host->state());
    return out;
}

Dictionary DCWorldExt::request_runtime_stop() {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = true;
        out["pending"] = false;
        out["state"] = "STOPPED";
        return out;
    }
    const RuntimeWorkerState before = _runtime_host->state();
    _runtime_host->request_stop();
    out["ok"] = true;
    const RuntimeWorkerState state = _runtime_host->state();
    // The request itself is asynchronous even if the worker exits during this
    // call.  Callers use pending to schedule a later lifecycle poll, while the
    // state field is allowed to already be STOPPED.
    out["pending"] = before != RuntimeWorkerState::STOPPED;
    out["state"] = runtime_state_name(state);
    return out;
}

bool DCWorldExt::runtime_snapshot_ring_self_test() const {
    return RuntimeSnapshotRing::self_test();
}

bool DCWorldExt::runtime_domain_pod_self_test() const {
    std::string error;
    return RuntimeDomainPodPipeline::self_test(error);
}

bool DCWorldExt::runtime_authoritative_domains_self_test() const {
    std::string error;
    return RuntimeAuthoritativeDomainStores::self_test(error) &&
        RuntimeClimateAuthority::self_test(error) &&
        RuntimeCountryPodAuthority::self_test(error) &&
        RuntimeDomainAuthorityRunner::self_test(error);
}

bool DCWorldExt::runtime_climate_authority_self_test() const {
    std::string error;
    return RuntimeClimateAuthority::self_test(error);
}

bool DCWorldExt::runtime_climate_trace_self_test() const {
    std::string error;
    return RuntimeClimateTrace::self_test(error);
}

bool DCWorldExt::runtime_country_pod_authority_self_test() const {
    std::string error;
    return RuntimeCountryPodAuthority::self_test(error);
}

bool DCWorldExt::runtime_protocol_guard_self_test() const {
    std::string error;
    return RuntimeProtocolGuard::self_test(error);
}

} // namespace pk
