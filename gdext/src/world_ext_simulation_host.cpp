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
    // per-domain 权威：调用方点名它要 worker 拥有哪些域，缺省才是整图。
    //
    // 准入门必须跟着这个掩码走，而不是恒查 implemented_domain_mask ==
    // RUNTIME_ALL_DOMAIN_MASK —— 那条整图门意味着 Climate 要等全部 12 个域都有 POD
    // handler 才能转 ACTIVE，而 Climate 自己早就齐了。掩码里没点到的域仍在主线程，
    // 它们有没有 handler 与这次授权无关。
    //
    // COMMIT 是 barrier 域本身，host 侧也会补上；这里一并纳入判定，否则调用方只写
    // CLIMATE 时会被自己没请求的域挡下。
    const uint32_t all_mask = static_cast<uint32_t>(RUNTIME_ALL_DOMAIN_MASK);
    uint32_t requested_authority_mask = all_mask;
    if (config.has("authoritative_domain_mask")) {
        const Variant raw = config["authoritative_domain_mask"];
        if (raw.get_type() != Variant::INT) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "authoritative_domain_mask_not_int";
            out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
            return out;
        }
        const int64_t value = static_cast<int64_t>(raw);
        if (value <= 0 || (static_cast<uint32_t>(value) & ~all_mask) != 0u) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "authoritative_domain_mask_out_of_range";
            out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
            return out;
        }
        requested_authority_mask =
            static_cast<uint32_t>(value) |
            runtime_domain_mask(RuntimeDomainId::COMMIT);
    }
    const uint32_t missing_requested =
        requested_authority_mask &
        ~static_cast<uint32_t>(NativeSimulationHost::implemented_domain_mask());
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (!complete || missing_requested != 0u)) {
        out["ok"] = false;
        out["pending"] = false;
        const bool domains_missing = complete && missing_requested != 0u;
        out["code"] = domains_missing
            ? "runtime_native_domains_incomplete"
            : "runtime_graph_not_thread_safe";
        out["message"] = domains_missing
            ? "native_domain_pod_handlers_incomplete"
            : "runtime_graph_contains_godot_bridge";
        out["requested_authority_mask"] =
            static_cast<int64_t>(requested_authority_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(missing_requested);
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    if (!_runtime_host->start(mode, complete, day, speed, paused,
                              requested_authority_mask)) {
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
    }

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

namespace {

// 把生产侧交来的 MapData 数组还原成一份 RuntimeClimateStore。
//
// 键名就是 parity 表的 canonical name（RuntimeClimateParityField::name 的注释里
// 写明了它同时是这个绑定接受的字典键），所以这里不存在第二套名字映射 —— 表是
// 唯一的真相，加一个 parity 字段不需要动这个函数。
//
// 缺席的字段留在 reset 后的零值上，并不报错：生产某一天没跑某个 stage 时那条数组
// 本来就不该出现，而把它当成错误会让整天的 reference 无法发布。
bool build_climate_store_from_fields(const Dictionary &fields,
                                     RuntimeClimateStore &store,
                                     String &error) {
    int cell_count = static_cast<int>(fields.get("cell_count", 0));
    if (cell_count <= 0) {
        // 没给 cell_count 时从任一条数组推断，长度不一致由下面逐条的 size 检查兜住。
        const size_t count = runtime_climate_parity_field_count();
        const RuntimeClimateParityField *table = runtime_climate_parity_fields();
        for (size_t i = 0; i < count && cell_count <= 0; ++i) {
            if (!fields.has(table[i].name)) continue;
            const Variant raw = fields[table[i].name];
            switch (raw.get_type()) {
            case Variant::PACKED_FLOAT32_ARRAY:
                cell_count = PackedFloat32Array(raw).size();
                break;
            case Variant::PACKED_INT32_ARRAY:
                cell_count = PackedInt32Array(raw).size();
                break;
            case Variant::PACKED_BYTE_ARRAY:
                cell_count = PackedByteArray(raw).size();
                break;
            default:
                break;
            }
        }
    }
    if (cell_count <= 0) {
        error = String("climate_reference_cell_count_missing");
        return false;
    }
    store.reset(static_cast<uint32_t>(cell_count));
    store.climate_anomaly =
        static_cast<float>(static_cast<double>(fields.get("climate_anomaly", 0.0)));
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const RuntimeClimateParityField &f = table[i];
        if (!fields.has(f.name)) continue;
        const Variant raw = fields[f.name];
        switch (f.kind) {
        case RuntimeClimateParityKind::F32: {
            if (f.f32 == nullptr) break;
            if (raw.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                error = String(f.name) + String("(dtype)");
                return false;
            }
            const PackedFloat32Array values = raw;
            if (values.size() != cell_count) {
                error = String(f.name) + String("(size)");
                return false;
            }
            auto &dst = store.*(f.f32);
            dst.assign(values.ptr(), values.ptr() + values.size());
            break;
        }
        case RuntimeClimateParityKind::I32: {
            if (f.i32 == nullptr) break;
            if (raw.get_type() != Variant::PACKED_INT32_ARRAY) {
                error = String(f.name) + String("(dtype)");
                return false;
            }
            const PackedInt32Array values = raw;
            if (values.size() != cell_count) {
                error = String(f.name) + String("(size)");
                return false;
            }
            auto &dst = store.*(f.i32);
            dst.assign(values.ptr(), values.ptr() + values.size());
            break;
        }
        case RuntimeClimateParityKind::U8: {
            if (f.u8 == nullptr) break;
            if (raw.get_type() != Variant::PACKED_BYTE_ARRAY) {
                error = String(f.name) + String("(dtype)");
                return false;
            }
            const PackedByteArray values = raw;
            if (values.size() != cell_count) {
                error = String(f.name) + String("(size)");
                return false;
            }
            auto &dst = store.*(f.u8);
            dst.assign(values.ptr(), values.ptr() + values.size());
            break;
        }
        }
    }
    return true;
}

} // namespace

void append_climate_stage_cadence(Dictionary &out,
                                  const RuntimeThreadReport &report) {
    PackedFloat64Array stage_ms;
    PackedInt64Array stage_work;
    PackedStringArray stage_names;
    const size_t count = report.climate_stage_ms.size();
    stage_ms.resize(static_cast<int>(count));
    stage_work.resize(static_cast<int>(count));
    stage_names.resize(static_cast<int>(count));
    for (size_t i = 0; i < count; ++i) {
        stage_ms.set(static_cast<int>(i), report.climate_stage_ms[i]);
        stage_work.set(static_cast<int>(i),
                       static_cast<int64_t>(report.climate_stage_work[i]));
        stage_names.set(static_cast<int>(i),
                        String(runtime_climate_stage_name(
                            static_cast<RuntimeClimateStage>(i))));
    }
    out["climate_stage_ms"] = stage_ms;
    out["climate_stage_work"] = stage_work;
    out["climate_stage_names"] = stage_names;
}

bool DCWorldExt::climate_worker_authoritative() const {
    // 直接读 host，不经任何 GDScript 注入的镜像：抑制门每 tick 都要问这个，而一个
    // 落后一帧的 false 会让主线程在 worker 已经在产出同一天时再跑一遍 Climate。
    if (!_runtime_host) return false;
    return _runtime_host->domain_is_worker_authoritative(
        RuntimeDomainId::CLIMATE);
}

Dictionary DCWorldExt::set_runtime_climate_parity_forcing(bool enabled) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_climate_parity_forcing(enabled);
    out["ok"] = true;
    out["code"] = "ok";
    out["enabled"] = _runtime_host->climate_parity_forcing();
    out["forced_days"] =
        static_cast<int64_t>(_runtime_host->climate_parity_forced_days());
    return out;
}

Array DCWorldExt::get_runtime_climate_parity_fields() const {
    Array out;
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const RuntimeClimateParityField &f = table[i];
        Dictionary row;
        row["name"] = String(f.name);
        row["map_data_array"] = String(f.map_data_array);
        row["kind"] = static_cast<int>(f.kind);
        row["comparability"] = static_cast<int>(f.comparability);
        row["tolerance"] = static_cast<int>(f.tolerance);
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(f.tolerance);
        row["stage"] = static_cast<int>(f.stage);
        row["stage_name"] = String(runtime_climate_stage_name(f.stage));
        row["note"] = String(f.note != nullptr ? f.note : "");
        out.push_back(row);
    }
    return out;
}

Dictionary DCWorldExt::apply_runtime_climate_writeback(
        int64_t after_generation) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (!_map_data) {
        out["ok"] = false;
        out["code"] = "runtime_writeback_map_unavailable";
        return out;
    }
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_climate_writeback(
            after_generation < 0 ? 0u : static_cast<uint64_t>(after_generation),
            slot)) {
        // 不是错误：worker 还没提交更新的一天。ok=true / applied=false 让调用方的
        // 游标保持不动，而不是把"这一帧没有新数据"当成失败去重试。
        out["ok"] = true;
        out["applied"] = false;
        out["code"] = "ok";
        out["generation"] = after_generation;
        out["drops"] =
            static_cast<int64_t>(_runtime_host->climate_writeback_drop_count());
        return out;
    }
    const RuntimeClimateSnapshot &snapshot =
        _runtime_host->climate_writeback_buffer(slot);
    const RuntimeClimateStore &store = snapshot.payload;
    const int cell_count = static_cast<int>(store.cell_count);
    if (cell_count <= 0) {
        _runtime_host->release_climate_writeback(slot);
        out["ok"] = false;
        out["applied"] = false;
        out["code"] = "runtime_writeback_empty_store";
        return out;
    }

    PackedStringArray touched_slots;
    PackedStringArray skipped;
    int applied_fields = 0;

    // 走 parity 字段表而不是另列一张回灌清单：那张表已经是"哪些场属于 Climate 权威"
    // 的唯一定义（对拍用的就是它），另开一张清单等于让回灌和对拍可以各说各话 ——
    // 漏掉的场会一边在 parity 里显示对齐、一边在 MapData 里冻结。
    const size_t field_count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < field_count; ++i) {
        const RuntimeClimateParityField &field = table[i];
        const char *slot_name = _slot_name_for_property(field.map_data_array);
        if (slot_name == nullptr) {
            skipped.push_back(String(field.name) + String("(unbound)"));
            continue;
        }
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) {
            skipped.push_back(String(field.name) + String("(no_slot)"));
            continue;
        }
        Slot &s = _slots.write[sid];
        switch (field.kind) {
            case RuntimeClimateParityKind::F32: {
                if (field.f32 == nullptr) {
                    skipped.push_back(String(field.name) + String("(no_member)"));
                    continue;
                }
                const std::vector<float> &source = store.*(field.f32);
                if (static_cast<int>(source.size()) != cell_count) {
                    skipped.push_back(String(field.name));
                    continue;
                }
                // slot.h 的两条约束：dtype 决定哪条数组是活的（写错的那条会静默丢
                // 弃），external_ref 的 slot 不能 resize —— 那会脱开与 GDScript 那侧
                // 的别名，于是回灌写进一块没人读的内存。
                if (s.dtype != SlotDType::F32) {
                    skipped.push_back(String(field.name) + String("(dtype)"));
                    continue;
                }
                if (s.arr_f32.size() != cell_count) {
                    if (s.external_ref) {
                        skipped.push_back(String(field.name) + String("(extern_size)"));
                        continue;
                    }
                    s.arr_f32.resize(cell_count);
                }
                std::memcpy(s.arr_f32.ptrw(), source.data(),
                            static_cast<size_t>(cell_count) * sizeof(float));
                break;
            }
            case RuntimeClimateParityKind::I32: {
                if (field.i32 == nullptr) {
                    skipped.push_back(String(field.name) + String("(no_member)"));
                    continue;
                }
                const std::vector<int32_t> &source = store.*(field.i32);
                if (static_cast<int>(source.size()) != cell_count) {
                    skipped.push_back(String(field.name));
                    continue;
                }
                if (s.dtype != SlotDType::I32) {
                    skipped.push_back(String(field.name) + String("(dtype)"));
                    continue;
                }
                if (s.arr_i32.size() != cell_count) {
                    if (s.external_ref) {
                        skipped.push_back(String(field.name) + String("(extern_size)"));
                        continue;
                    }
                    s.arr_i32.resize(cell_count);
                }
                std::memcpy(s.arr_i32.ptrw(), source.data(),
                            static_cast<size_t>(cell_count) * sizeof(int32_t));
                break;
            }
            case RuntimeClimateParityKind::U8: {
                const std::vector<uint8_t> &source = store.*(field.u8);
                if (static_cast<int>(source.size()) != cell_count) {
                    skipped.push_back(String(field.name));
                    continue;
                }
                if (s.arr_u8.size() != cell_count) {
                    if (s.external_ref) {
                        skipped.push_back(String(field.name) + String("(extern_size)"));
                        continue;
                    }
                    s.arr_u8.resize(cell_count);
                }
                std::memcpy(s.arr_u8.ptrw(), source.data(),
                            static_cast<size_t>(cell_count));
                break;
            }
        }
        touched_slots.push_back(String(slot_name));
        ++applied_fields;
    }

    // 下面这几条走不了上面那张表：表是按 RuntimeClimateStore 的成员指针索引的，而
    // 它们没有 store 成员（理由见 RuntimeClimateSnapshot::soil_moisture）。共同点是
    // ACTIVE 下主线程那个写者被抑制门关掉了，worker 这份是它们唯一的日频写者 ——
    // 不回灌就等于这条场没有写者，MapData 会停在世界生成时的值。
    //
    // 空 vector = 这一天产出它的 stage 没跑（distribute 按 weather 轮的节拍，不是每
    // 天），此时保持 MapData 原值，不记 skipped：那不是缺陷，是节拍。
    const auto apply_extra = [&](const char *field_name, const char *slot_name,
                                 const std::vector<float> &source) {
        if (source.empty()) return;
        if (static_cast<int>(source.size()) != cell_count) {
            skipped.push_back(String(field_name));
            return;
        }
        const int sid = component_id(StringName(slot_name));
        if (sid < 0 || sid >= _slots.size()) {
            skipped.push_back(String(field_name));
            return;
        }
        Slot &s = _slots.write[sid];
        if (s.dtype != SlotDType::F32) {
            skipped.push_back(String(field_name) + String("(dtype)"));
            return;
        }
        if (s.arr_f32.size() != cell_count && s.external_ref) {
            skipped.push_back(String(field_name) + String("(extern_size)"));
            return;
        }
        if (s.arr_f32.size() != cell_count) s.arr_f32.resize(cell_count);
        std::memcpy(s.arr_f32.ptrw(), source.data(),
                    static_cast<size_t>(cell_count) * sizeof(float));
        touched_slots.push_back(String(slot_name));
        ++applied_fields;
    };
    apply_extra("soil_moisture", "cell_soil_moisture", snapshot.soil_moisture);
    // pass_a 的日照/热量输出。worker 内部算得对（round 内 pass_a→pass_b 走 out 缓冲，
    // 不经 MapData），坏的是外部读者：渲染、tile 录制、UI 面板读的都是 MapData。
    apply_extra("insolation_now", "cell_insolation_now", snapshot.insolation_now);
    apply_extra("insolation_dev", "cell_insolation_dev", snapshot.insolation_dev);
    apply_extra("day_length", "cell_day_length", snapshot.day_length);
    apply_extra("heat_input", "cell_heat_input", snapshot.heat_input);
    apply_extra("temp_season_offset", "cell_temp_season_offset",
                snapshot.temp_season_offset);

    const int64_t applied_day = snapshot.committed_day;
    const uint64_t applied_generation = snapshot.generation;
    const uint64_t applied_state_hash = snapshot.state_hash;
    // Release before flushing: the flush writes MapData, which the worker never
    // touches, so there is no reason to keep a ring slot occupied across it.
    _runtime_host->release_climate_writeback(slot);

    flush_slots_to_map_keys(touched_slots);

    out["ok"] = true;
    // applied 只在真的写进了字段时为真。曾经这里无条件报 true，于是"回灌假活跃"
    // 让一次全空的写回看起来和成功一模一样。
    out["applied"] = applied_fields > 0;
    out["code"] = "ok";
    out["day"] = applied_day;
    out["generation"] = static_cast<int64_t>(applied_generation);
    out["state_hash"] = static_cast<int64_t>(applied_state_hash);
    out["cell_count"] = static_cast<int64_t>(cell_count);
    // 键名由 GDScript 侧决定（world_runtime_host._apply_runtime_climate_writeback
    // 读的就是这两个）。被 slot 守卫拒掉的字段是"worker 拥有但从不发布"的字段，
    // MapData 会静默停在转权威那天的值 —— 所以拒绝清单必须出得来，不能只报计数。
    out["applied_fields"] = applied_fields;
    out["skipped_fields"] = skipped;
    out["drops"] =
        static_cast<int64_t>(_runtime_host->climate_writeback_drop_count());
    return out;
}

Dictionary DCWorldExt::compute_runtime_climate_parity_hash(
        const Dictionary &fields) {
    Dictionary out;
    RuntimeClimateStore store;
    String error;
    if (!build_climate_store_from_fields(fields, store, error)) {
        out["ok"] = false;
        out["code"] = "climate_reference_fields_invalid";
        out["field"] = error;
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["cell_count"] = static_cast<int64_t>(store.cell_count);
    // 用与 worker 完全相同的那一个归约函数。两侧"按约定各算一遍"是这条对拍最早的
    // 失效方式，所以这里刻意不复制哈希逻辑。
    out["state_hash"] =
        static_cast<int64_t>(runtime_climate_parity_hash(store));
    out["parity_version"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_VERSION);
    out["comparable_fields"] =
        static_cast<int64_t>(runtime_climate_parity_comparable_count());
    return out;
}

Dictionary DCWorldExt::publish_runtime_climate_reference_state(
        int64_t day, const Dictionary &fields) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (day < 0) {
        out["ok"] = false;
        out["code"] = "climate_trace_reference_invalid";
        return out;
    }
    auto store = std::make_shared<RuntimeClimateStore>();
    String error;
    if (!build_climate_store_from_fields(fields, *store, error)) {
        out["ok"] = false;
        out["code"] = "climate_reference_fields_invalid";
        out["field"] = error;
        return out;
    }
    // 哈希在这里从 state 派生，所以两者不可能互相矛盾 —— 这正是这个绑定存在的理由
    // （另一个只收哈希的版本做不到按字段/格子定位分叉）。
    const uint64_t state_hash = runtime_climate_parity_hash(*store);

    RuntimeClimateReferencePublish publish;
    publish.reference_store = store;
    publish.round_input = _production_round_input;
    publish.round_ran = static_cast<bool>(_production_round_input);
    publish.round_scalars = &_production_round_scalars;
    publish.round_scalar_mask = _production_round_scalar_mask;
    publish.pass_b = _production_pass_b;
    publish.sea_ice = _production_sea_ice;
    publish.wind_surface = _production_wind_surface;
    publish.ocean_water = _production_ocean_water;
    publish.wind_air = _production_wind_air;
    publish.albedo = _production_albedo;
    publish.vegetation = _production_vegetation;
    publish.feedback = _production_feedback;
    publish.weather = _production_weather;
    publish.hydrology = _production_hydrology;
    publish.weather_distribute = _production_weather_distribute;
    publish.production_stage_mask = _production_stage_mask;
    publish.seasonal_feedback_ran = _production_seasonal_feedback_ran;
    publish.seasonal_feedback_decay = _production_seasonal_feedback_decay;
    publish.season_refresh_ran = _production_season_refresh_ran;

    std::string host_error;
    const bool ok = _runtime_host->publish_climate_reference(
        day, state_hash, host_error, publish);

    // 节拍诊断：配错一天会表现成"算法分叉"，所以前若干天照实把 round_ran 与 stage
    // mask 打出来。这比从分叉矩阵反推直接得多。
    if (_publish_cadence_reports_left > 0) {
        --_publish_cadence_reports_left;
        UtilityFunctions::print(vformat(
            "[climate][publish] day=%d round_ran=%d prod_stage=0x%x "
            "scalar_mask=0x%x alb=%d veg=%d fb=%d weather=%d sr=%d ok=%d",
            static_cast<int64_t>(day), publish.round_ran ? 1 : 0,
            publish.production_stage_mask, publish.round_scalar_mask,
            publish.albedo.ran ? 1 : 0,
            static_cast<bool>(publish.vegetation) ? 1 : 0,
            static_cast<bool>(publish.feedback) ? 1 : 0,
            static_cast<bool>(publish.weather) ? 1 : 0,
            publish.season_refresh_ran ? 1 : 0, ok ? 1 : 0));
    }

    // 全部 per-day 记录在这里复位。少了这一步，"生产这一天没跑某个 stage"会继承上
    // 一天的记录，而那正是这些字段用来区分的两种情况之一。
    _last_published_climate_reference = store;
    _production_round_input.reset();
    _production_round_scalar_mask = 0;
    _production_pass_b.reset();
    _production_sea_ice.reset();
    _production_wind_surface.reset();
    _production_ocean_water.reset();
    _production_wind_air.reset();
    _production_albedo = pk_async_climate::ClimateAlbedoKnobs{};
    _production_vegetation.reset();
    _production_feedback.reset();
    _production_weather.reset();
    _production_hydrology.reset();
    _production_weather_distribute.reset();
    _production_stage_mask = 0;
    _production_seasonal_feedback_ran = false;
    _production_seasonal_feedback_decay = 1.0f;
    _production_season_refresh_ran = false;

    if (!ok) {
        out["ok"] = false;
        out["code"] = String(host_error.c_str());
        out["day"] = day;
        out["state_hash"] = static_cast<int64_t>(state_hash);
        return out;
    }
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    out["day"] = day;
    out["state_hash"] = static_cast<int64_t>(state_hash);
    out["cell_count"] = static_cast<int64_t>(store->cell_count);
    return out;
}

bool DCWorldExt::runtime_climate_writeback_self_test() const {
    std::string error;
    return RuntimeClimateWritebackRing::self_test(error);
}

Dictionary DCWorldExt::runtime_climate_parity_contract_test() const {
    Dictionary out;
    std::string error;
    const bool ok = runtime_climate_parity_self_test(error);
    out["ok"] = ok;
    // 返回 Dictionary 而不是裸 bool：一次 parity 契约失败必须带上原因才可行动，
    // 而"绿灯下的裸 false"正是早期几个缺口能长期隐身的原因。
    out["code"] = ok ? String("ok") : String(error.c_str());
    out["parity_version"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_VERSION);
    out["field_count"] =
        static_cast<int64_t>(runtime_climate_parity_field_count());
    out["comparable_count"] =
        static_cast<int64_t>(runtime_climate_parity_comparable_count());
    out["max_fields"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_MAX_FIELDS);
    return out;
}

Array DCWorldExt::get_runtime_climate_parity_divergence() const {
    Array out;
    if (!_runtime_host) return out;
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const auto st = _runtime_host->climate_parity_field_status(i);
        // 没比过的字段也要出现在表里：缺行和"零分叉"是两件事，而分叉矩阵是用来
        // 排迁移顺序的，一行的缺席会被读成"这个 stage 已经对齐了"。
        Dictionary row;
        row["name"] = String(table[i].name);
        row["stage"] = static_cast<int>(table[i].stage);
        row["stage_name"] = String(runtime_climate_stage_name(table[i].stage));
        row["tolerance"] = static_cast<int>(table[i].tolerance);
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(table[i].tolerance);
        row["comparability"] = static_cast<int>(table[i].comparability);
        row["compared_days"] = static_cast<int64_t>(st.compared_days);
        row["diverged_days"] = static_cast<int64_t>(st.diverged_days);
        row["diverged_cells"] = static_cast<int64_t>(st.diverged_cells);
        row["out_of_band_days"] = static_cast<int64_t>(st.out_of_band_days);
        row["out_of_band_cells"] = static_cast<int64_t>(st.out_of_band_cells);
        row["first_diverged_day"] = st.first_diverged_day;
        row["first_out_of_band_day"] = st.first_out_of_band_day;
        row["first_cell"] = static_cast<int64_t>(st.first_cell);
        row["last_diverged_cells"] =
            static_cast<int64_t>(st.last_diverged_cells);
        row["last_out_of_band_cells"] =
            static_cast<int64_t>(st.last_out_of_band_cells);
        row["max_abs_delta"] = st.max_abs_delta;
        row["max_out_of_band_delta"] = st.max_out_of_band_delta;
        row["first_reference_bits"] = String(st.first_reference_bits);
        row["first_worker_bits"] = String(st.first_worker_bits);
        out.push_back(row);
    }
    return out;
}

} // namespace pk
