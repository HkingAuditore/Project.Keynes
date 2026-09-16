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

#include <algorithm>
#include <chrono>
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
    out["completion_gate_missing_domain_mask"] = static_cast<int64_t>(report.completion_gate_missing_domain_mask);
    out["active_gate_blocked"] = report.active_gate_blocked;
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
    out["input_capture_count"] = static_cast<int64_t>(report.input_capture_count);
    out["input_capture_reused"] = static_cast<int64_t>(report.input_capture_reused);
    out["input_capture_generation"] = static_cast<int64_t>(report.input_capture_generation);
    out["input_capture_day"] = report.input_capture_day;
    out["input_capture_hash"] = static_cast<int64_t>(report.input_capture_hash);
    out["gameplay_effect_generation"] = static_cast<int64_t>(report.gameplay_effect_generation);
    out["gameplay_effect_pending"] = static_cast<int>(report.gameplay_effect_pending);
    out["gameplay_effect_terminal"] = static_cast<int>(report.gameplay_effect_terminal);
    out["gameplay_effect_state_hash"] = static_cast<int64_t>(report.gameplay_effect_state_hash);
    out["visual_intent_generation"] = static_cast<int64_t>(report.visual_intent_generation);
    out["visual_intent_count"] = static_cast<int>(report.visual_intent_count);
    out["visual_full_refresh"] = report.visual_full_refresh != 0;
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
    out["economy_pod_ready"] = report.economy_pod_ready;
    out["economy_pod_committed"] = report.economy_pod_committed;
    out["economy_pod_authority_ready"] = report.economy_pod_authority_ready;
    out["economy_pod_committed_day"] = report.economy_pod_committed_day;
    out["economy_pod_epoch_sample_day"] = report.economy_pod_epoch_sample_day;
    out["economy_pod_generation"] = static_cast<int64_t>(report.economy_pod_generation);
    out["economy_pod_state_hash"] = static_cast<int64_t>(report.economy_pod_state_hash);
    out["economy_pod_input_generation"] = static_cast<int64_t>(report.economy_pod_input_generation);
    out["economy_pod_country_generation"] = static_cast<int64_t>(report.economy_pod_country_generation);
    out["economy_pod_completed_stage_mask"] = static_cast<int64_t>(report.economy_pod_completed_stage_mask);
    out["economy_pod_pending_outbox"] = static_cast<int>(report.economy_pod_pending_outbox);
    out["economy_pod_pending_inbox"] = static_cast<int>(report.economy_pod_pending_inbox);
    out["economy_pod_operation_gate_mask"] = static_cast<int>(report.economy_pod_operation_gate_mask);
    out["economy_pod_parity_ready_mask"] = static_cast<int>(report.economy_pod_parity_ready_mask);
    out["economy_pod_mirror_feature_mask"] =
        static_cast<int>(report.economy_pod_mirror_feature_mask);
    out["economy_pod_committed_ledger_abi"] =
        static_cast<int>(report.economy_pod_committed_ledger_abi);
    out["economy_pod_active_ready"] = report.economy_pod_active_ready;
    out["economy_authority_switch_count"] = report.economy_authority_switch_count;
    out["economy_authority_switch_before_hash"] = report.economy_authority_switch_before_hash;
    out["economy_authority_switch_after_hash"] = report.economy_authority_switch_after_hash;
    out["economy_authority_switch_latency_us"] = report.economy_authority_switch_latency_us;
    out["economy_authority_switch_latency_p95_us"] =
        report.economy_authority_switch_latency_p95_us;
    out["economy_authority_switch_latency_max_us"] =
        report.economy_authority_switch_latency_max_us;
    out["economy_authority_switch_command_latency_us"] =
        report.economy_authority_switch_command_latency_us;
    out["economy_authority_switch_command_latency_p95_us"] =
        report.economy_authority_switch_command_latency_p95_us;
    out["economy_authority_switch_command_latency_max_us"] =
        report.economy_authority_switch_command_latency_max_us;
    out["economy_authority_switch_latency_sample_count"] =
        report.economy_authority_switch_latency_sample_count;
    out["economy_authority_switch_rejected"] = report.economy_authority_switch_rejected;
    out["economy_authority_switch_audit_sequence"] =
        report.economy_authority_switch_audit_sequence;
    out["economy_authority_switch_before_generation"] = static_cast<int64_t>(report.economy_authority_switch_before_generation);
    out["economy_authority_switch_after_generation"] = static_cast<int64_t>(report.economy_authority_switch_after_generation);
    out["economy_authority_fault_paused"] = report.economy_authority_fault_paused;
    out["economy_authority_last_committed_generation"] = static_cast<int64_t>(report.economy_authority_last_committed_generation);
    out["economy_authority_last_committed_hash"] = static_cast<int64_t>(report.economy_authority_last_committed_hash);
    out["economy_inflight_mutations"] = static_cast<int>(report.economy_inflight_mutations);
    out["worker_day_inflight"] = static_cast<int>(report.worker_day_inflight);
    out["economy_pending_command_count"] = static_cast<int>(report.economy_pending_command_count);
    out["economy_authority_switch_reason"] = String(report.economy_authority_switch_reason);
    out["economy_authority_switch_blocker"] = String(report.economy_authority_switch_blocker);
    out["economy_authority_switch_audit_before"] = String(report.economy_authority_switch_audit_before);
    out["economy_authority_switch_audit_after"] = String(report.economy_authority_switch_audit_after);
    out["economy_execution_mode"] = static_cast<int>(report.economy_execution_mode);
    out["economy_execution_mode_name"] = String(
        pk::economy_execution_mode_name(
            static_cast<pk::EconomyExecutionMode>(report.economy_execution_mode)));
    out["economy_shadow_probe_enabled"] = report.economy_shadow_probe_enabled;
    out["economy_shadow_stage_invocations"] =
        static_cast<int64_t>(report.economy_shadow_stage_invocations);
    out["economy_shadow_stage_cache_hits"] =
        static_cast<int64_t>(report.economy_shadow_stage_cache_hits);
    out["economy_stage_ops_mutate"] = report.economy_stage_ops_mutate;
    out["economy_auto_pod_active"] = report.economy_auto_pod_active;
    out["economy_pod_command_recapture_count"] =
        static_cast<int64_t>(report.economy_pod_command_recapture_count);
    out["economy_pod_command_verify_count"] =
        static_cast<int64_t>(report.economy_pod_command_verify_count);
    out["economy_formula_backing"] = String(report.economy_formula_backing);
    out["economy_production_writer"] = String(report.economy_production_writer);
    out["economy_production_writer_requested"] =
        String(report.economy_production_writer_requested);
    out["economy_production_writer_effective"] =
        String(report.economy_production_writer_effective);
    out["economy_stage_ops_readiness_mask"] =
        static_cast<int64_t>(report.economy_stage_ops_readiness_mask);
    out["economy_stage_ops_prelude_ready"] =
        report.economy_stage_ops_prelude_ready;
    out["economy_stage_ops_soak_experiment"] =
        report.economy_stage_ops_soak_experiment;
    out["economy_stage_ops_soak_parity_ok"] =
        report.economy_stage_ops_soak_parity_ok;
    out["economy_replay_completed_stage_mask"] = static_cast<int64_t>(report.economy_replay_completed_stage_mask);
    out["economy_replay_stage_cursor"] = static_cast<int>(report.economy_replay_stage_cursor);
    out["economy_replay_input_hash"] = static_cast<int64_t>(report.economy_replay_input_hash);
    out["economy_replay_base_hash"] = static_cast<int64_t>(report.economy_replay_base_hash);
    out["economy_replay_next_hash"] = static_cast<int64_t>(report.economy_replay_next_hash);
    out["economy_replay_input_captured"] = report.economy_replay_input_captured;
    out["economy_replay_committed"] = report.economy_replay_committed;
    out["economy_replay_parity_ready"] = report.economy_replay_parity_ready;
    out["economy_replay_fallback_reason"] = String(report.economy_replay_fallback_reason);
    PackedInt64Array replay_hashes;
    PackedInt64Array replay_work;
    PackedFloat64Array replay_ms;
    replay_hashes.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    replay_work.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    replay_ms.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    for (int i = 0; i < static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT); ++i) {
        replay_hashes.set(i, static_cast<int64_t>(report.economy_replay_stage_hash[i]));
        replay_work.set(i, static_cast<int64_t>(report.economy_replay_stage_work[i]));
        replay_ms.set(i, report.economy_replay_stage_ms[i]);
    }
    out["economy_replay_stage_hash"] = replay_hashes;
    out["economy_replay_stage_work"] = replay_work;
    out["economy_replay_stage_ms"] = replay_ms;
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
    out["country_worker_configured"] = report.country_worker_configured;
    out["country_worker_plan_active"] = report.country_worker_plan_active;
    out["country_worker_waiting_for_peer"] = report.country_worker_waiting_for_peer;
    out["country_worker_pending_intents"] = static_cast<int64_t>(
        report.country_worker_pending_intents);
    out["country_worker_queued_intents"] = static_cast<int64_t>(
        report.country_worker_queued_intents);
    out["country_worker_result_count"] = static_cast<int64_t>(
        report.country_worker_result_count);
    out["country_worker_rejected_results"] = static_cast<int64_t>(
        report.country_worker_rejected_results);
    out["country_worker_session_epoch"] = static_cast<int64_t>(
        report.country_worker_session_epoch);
    out["country_worker_country_generation"] = static_cast<int64_t>(
        report.country_worker_country_generation);
    out["country_worker_day"] = report.country_worker_day;
    out["country_worker_continuation_index"] = static_cast<int64_t>(
        report.country_worker_continuation_index);
    out["country_worker_boundary_id"] = static_cast<int64_t>(
        report.country_worker_boundary_id);
    out["country_worker_last_admitted_submit_order"] = static_cast<int64_t>(
        report.country_worker_last_admitted_submit_order);
    out["country_worker_expected_base_generation"] = static_cast<int64_t>(
        report.country_worker_expected_base_generation);
    out["country_worker_catalog_hash"] = static_cast<int64_t>(
        report.country_worker_catalog_hash);
    out["country_worker_last_reason"] = String(report.country_worker_last_reason);
    out["country_worker_authoritative"] = report.country_worker_authoritative;
    out["country_parity_compared"] = report.country_parity_compared != 0;
    out["country_parity_matched"] = report.country_parity_matched != 0;
    out["country_parity_compared_count"] = static_cast<int64_t>(
        report.country_parity_compared_count);
    out["country_parity_matched_count"] = static_cast<int64_t>(
        report.country_parity_matched_count);
    out["country_parity_status"] = String(report.country_parity_status);
    out["country_parity_first_mismatch_day"] = report.country_parity_first_mismatch_day;
    out["country_parity_reference_hash"] = static_cast<int64_t>(
        report.country_parity_reference_hash);
    out["country_parity_worker_hash"] = static_cast<int64_t>(
        report.country_parity_worker_hash);
    out["country_parity_field"] = String(report.country_parity_field);
    out["country_parity_index"] = report.country_parity_index;
    out["trigger_parity_day"] = report.trigger_parity_day;
    out["trigger_reference_day"] = report.trigger_reference_day;
    out["trigger_input_hash"] = static_cast<int64_t>(report.trigger_input_hash);
    out["trigger_reference_input_hash"] = static_cast<int64_t>(report.trigger_reference_input_hash);
    out["trigger_reference_state_hash"] = static_cast<int64_t>(report.trigger_reference_state_hash);
    out["trigger_worker_state_hash"] = static_cast<int64_t>(report.trigger_worker_state_hash);
    out["trigger_reference_effect_hash"] = static_cast<int64_t>(report.trigger_reference_effect_hash);
    out["trigger_worker_effect_hash"] = static_cast<int64_t>(report.trigger_worker_effect_hash);
    out["trigger_required_ack_count"] = static_cast<int>(report.trigger_required_ack_count);
    out["trigger_received_ack_count"] = static_cast<int>(report.trigger_received_ack_count);
    out["trigger_pending_ack_count"] = static_cast<int>(report.trigger_pending_ack_count);
    out["trigger_generation"] = static_cast<int64_t>(report.trigger_generation);
    out["trigger_committed_day"] = report.trigger_committed_day;
    out["trigger_acked_effect_id"] = report.trigger_acked_effect_id;
    out["trigger_pending_command_count"] = static_cast<int>(report.trigger_pending_command_count);
    out["trigger_parity_compared"] = report.trigger_parity_compared != 0;
    out["trigger_parity_matched"] = report.trigger_parity_matched != 0;
    out["trigger_first_divergence_index"] = report.trigger_first_divergence_index;
    out["trigger_first_divergence_kind"] = String(report.trigger_first_divergence_kind);
    out["trigger_blocker"] = String(report.trigger_blocker);
    out["trigger_pod_ready"] = report.trigger_pod_ready;
    out["trigger_pod_plan_ms"] = report.trigger_pod_plan_ms;
    out["trigger_pod_replay_ms"] = report.trigger_pod_replay_ms;
    out["trigger_pod_state_hash"] = static_cast<int64_t>(report.trigger_pod_state_hash);
    out["trigger_pod_snapshot_generation"] = static_cast<int64_t>(
        report.trigger_pod_snapshot_generation);
    out["trigger_pod_intent_count"] = static_cast<int>(report.trigger_pod_intent_count);
    out["trigger_pod_ack_count"] = static_cast<int>(report.trigger_pod_ack_count);
    out["trigger_pod_fallback_reason"] = String(report.trigger_pod_fallback_reason);
    out["modifier_pod_ready"] = report.modifier_pod_ready;
    out["modifier_pod_plan_ms"] = report.modifier_pod_plan_ms;
    out["modifier_pod_replay_ms"] = report.modifier_pod_replay_ms;
    out["modifier_pod_work_units"] = static_cast<int64_t>(report.modifier_pod_work_units);
    out["modifier_pod_state_hash"] = static_cast<int64_t>(report.modifier_pod_state_hash);
    out["modifier_pod_snapshot_generation"] = static_cast<int64_t>(
        report.modifier_pod_snapshot_generation);
    out["modifier_pod_ack_count"] = static_cast<int>(report.modifier_pod_ack_count);
    out["modifier_pod_fallback_reason"] = String(report.modifier_pod_fallback_reason);
    out["effect_pod_ready"] = report.effect_pod_ready;
    out["effect_pod_plan_ms"] = report.effect_pod_plan_ms;
    out["effect_pod_replay_ms"] = report.effect_pod_replay_ms;
    out["effect_pod_state_hash"] = static_cast<int64_t>(report.effect_pod_state_hash);
    out["effect_pod_snapshot_generation"] = static_cast<int64_t>(
        report.effect_pod_snapshot_generation);
    out["effect_pod_ack_count"] = static_cast<int>(report.effect_pod_ack_count);
    out["effect_pod_intent_count"] = static_cast<int>(report.effect_pod_intent_count);
    out["effect_pod_fallback_reason"] = String(report.effect_pod_fallback_reason);
    out["ideology_pod_ready"] = report.ideology_pod_ready;
    out["ideology_pod_plan_ms"] = report.ideology_pod_plan_ms;
    out["ideology_pod_replay_ms"] = report.ideology_pod_replay_ms;
    out["ideology_pod_state_hash"] = static_cast<int64_t>(report.ideology_pod_state_hash);
    out["ideology_pod_snapshot_generation"] = static_cast<int64_t>(
        report.ideology_pod_snapshot_generation);
    out["ideology_pod_pending_transition_count"] = static_cast<int>(
        report.ideology_pod_pending_transition_count);
    out["ideology_pod_intent_count"] = static_cast<int>(report.ideology_pod_intent_count);
    out["ideology_pod_fallback_reason"] = String(report.ideology_pod_fallback_reason);
    out["events_probe_enabled"] = report.events_probe_enabled;
    out["events_pod_ready"] = report.events_pod_ready;
    out["events_pod_plan_ms"] = report.events_pod_plan_ms;
    out["events_pod_replay_ms"] = report.events_pod_replay_ms;
    out["events_pod_state_hash"] = static_cast<int64_t>(report.events_pod_state_hash);
    out["events_pod_snapshot_generation"] = static_cast<int64_t>(
        report.events_pod_snapshot_generation);
    out["events_pod_event_count"] = static_cast<int>(report.events_pod_event_count);
    out["events_pod_ack_count"] = static_cast<int>(report.events_pod_ack_count);
    out["events_pod_drop_count"] = static_cast<int64_t>(report.events_pod_drop_count);
    out["events_pod_fallback_reason"] = String(report.events_pod_fallback_reason);
    out["fault_code"] = String(report.fault_code);
    return out;
}

Dictionary DCWorldExt::start_runtime_worker(const Dictionary &config) {
    if (!_runtime_host || _runtime_host->state() == RuntimeWorkerState::STOPPED)
        _climate_physics_committed.reset();
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)
            ->attach_simulation_host(_runtime_host.get());
    }
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
    const bool events_probe_enabled = static_cast<bool>(
        config.get("events_probe_enabled", false));
    EconomyExecutionMode economy_execution_mode =
        EconomyExecutionMode::ACTIVE_ONLY;
    bool economy_stage_ops_mutate = true;
    // M6: authority handoff is explicit; this flag is retained only as a
    // compatibility/report field and no longer triggers a worker-side switch.
    bool economy_auto_pod_active = false;
    bool economy_ecp2_dual_write = true;
    bool economy_ecp2_mid_epoch_save = false;
    bool economy_ecp2_authority = false;
    bool economy_stage_ops_soak_experiment = false;
    EconomyProductionWriter economy_production_writer =
        EconomyProductionWriter::STAGE_OPS;
    const bool economy_production_writer_explicit =
        config.has("economy_production_writer");
    if (config.has("economy_stage_ops_mutate")) {
        economy_stage_ops_mutate =
            static_cast<bool>(config.get("economy_stage_ops_mutate", true));
    }
    if (config.has("economy_auto_pod_active")) {
        economy_auto_pod_active =
            static_cast<bool>(config.get("economy_auto_pod_active", false));
    }
    if (config.has("economy_ecp2_dual_write")) {
        economy_ecp2_dual_write =
            static_cast<bool>(config.get("economy_ecp2_dual_write", true));
    }
    if (config.has("economy_ecp2_mid_epoch_save")) {
        economy_ecp2_mid_epoch_save =
            static_cast<bool>(config.get("economy_ecp2_mid_epoch_save", false));
    }
    if (config.has("economy_ecp2_authority")) {
        economy_ecp2_authority =
            static_cast<bool>(config.get("economy_ecp2_authority", false));
    }
    if (config.has("economy_stage_ops_soak_experiment")) {
        economy_stage_ops_soak_experiment = static_cast<bool>(
            config.get("economy_stage_ops_soak_experiment", false));
    }
    if (config.has("economy_production_writer")) {
        const Variant writer_var =
            config.get("economy_production_writer", "compact_slice");
        if (writer_var.get_type() == Variant::INT ||
            writer_var.get_type() == Variant::FLOAT) {
            const int64_t ordinal = static_cast<int64_t>(writer_var);
            if (ordinal < 0 || ordinal > 1) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_production_writer_out_of_range";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report());
                return out;
            }
            economy_production_writer =
                static_cast<EconomyProductionWriter>(
                    static_cast<uint32_t>(ordinal));
        } else {
            const String writer_text = String(writer_var);
            CharString utf8 = writer_text.utf8();
            if (!parse_economy_production_writer(utf8.get_data(),
                                                 economy_production_writer)) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_production_writer_invalid";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report());
                return out;
            }
        }
    }
    if (config.has("economy_execution_mode")) {
        const Variant mode_var = config.get("economy_execution_mode", "ACTIVE_ONLY");
        if (mode_var.get_type() == Variant::INT ||
            mode_var.get_type() == Variant::FLOAT) {
            const int64_t ordinal = static_cast<int64_t>(mode_var);
            if (ordinal < 0 || ordinal > 2) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_execution_mode_out_of_range";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report());
                return out;
            }
            economy_execution_mode =
                static_cast<EconomyExecutionMode>(static_cast<uint32_t>(ordinal));
        } else {
            const String mode_text = String(mode_var);
            CharString utf8 = mode_text.utf8();
            if (!parse_economy_execution_mode(utf8.get_data(),
                                              economy_execution_mode)) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_execution_mode_invalid";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report());
                return out;
            }
        }
    }
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
        out["completion_gate_missing_domain_mask"] =
            static_cast<int64_t>(missing_requested);
        out["active_gate_blocked"] = true;
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return out;
    }
    _runtime_host->set_events_probe_enabled(events_probe_enabled);
    _runtime_host->set_economy_execution_mode(economy_execution_mode);
    if (economy_execution_mode == EconomyExecutionMode::LEGACY_ONLY) {
        // Keep sync ECONOMY_GRAPH as the sole writer; do not grant worker ECONOMY.
        requested_authority_mask &=
            ~runtime_domain_mask(RuntimeDomainId::ECONOMY);
        requested_authority_mask |=
            runtime_domain_mask(RuntimeDomainId::COMMIT);
    }
    // ACTIVE_WITH_PARITY needs compact production + read-only SHADOW StageOps.
    // Default writer is stage_ops; coerce unless the caller explicitly asked
    // for stage_ops (that remains a hard conflict).
    if (economy_execution_mode == EconomyExecutionMode::ACTIVE_WITH_PARITY) {
        economy_stage_ops_mutate = false;
        if (economy_production_writer == EconomyProductionWriter::STAGE_OPS &&
            !economy_production_writer_explicit) {
            economy_production_writer =
                EconomyProductionWriter::COMPACT_SLICE;
        }
    }
    // Phase-2.4.2 fail-closed gates for STAGE_OPS production writer.
    if (economy_production_writer == EconomyProductionWriter::STAGE_OPS) {
        if (economy_execution_mode ==
            EconomyExecutionMode::ACTIVE_WITH_PARITY) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "economy_production_writer_parity_conflict";
            out["thread_report"] =
                runtime_report_to_dictionary(_runtime_host->report());
            return out;
        }
        if (!economy_stage_ops_mutate) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "economy_production_writer_requires_mutate";
            out["thread_report"] =
                runtime_report_to_dictionary(_runtime_host->report());
            return out;
        }
        // Phase-2.4.5: StageOps writer is production-ready after dual-path soak
        // handoff. Keep parity / mutate fail-closed gates above.
        const uint32_t readiness = ECONOMY_STAGE_OPS_READY_PRELUDE |
                                   ECONOMY_STAGE_OPS_READY_COMMIT_DRAINS |
                                   ECONOMY_STAGE_OPS_READY_BOUNDED_KERNELS |
                                   ECONOMY_STAGE_OPS_READY_HOST_LOOP;
        const uint32_t missing =
            ECONOMY_STAGE_OPS_READY_REQUIRED_FOR_WRITER & ~readiness;
        if (missing != 0u) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "economy_production_writer_stage_ops_not_ready";
            out["economy_stage_ops_readiness_mask"] =
                static_cast<int64_t>(readiness);
            out["economy_stage_ops_readiness_missing"] =
                static_cast<int64_t>(missing);
            out["thread_report"] =
                runtime_report_to_dictionary(_runtime_host->report());
            return out;
        }
    }
    _runtime_host->set_economy_stage_ops_soak_experiment(
        economy_stage_ops_soak_experiment);
    _runtime_host->set_economy_production_writer(economy_production_writer);
    _runtime_host->set_economy_stage_ops_mutate(economy_stage_ops_mutate);
    _runtime_host->set_economy_auto_pod_active(economy_auto_pod_active);
    _runtime_host->set_economy_ecp2_dual_write(economy_ecp2_dual_write);
    _runtime_host->set_economy_ecp2_mid_epoch_save(economy_ecp2_mid_epoch_save);
    _runtime_host->set_economy_ecp2_authority(economy_ecp2_authority);
    if (_economy_runtime != nullptr) {
        auto *economy =
            static_cast<NativeEconomyRuntime *>(_economy_runtime);
        economy->attach_simulation_host(_runtime_host.get());
        // Phase-2.4.5: StageOps mutate is the default production writer.
        // ACTIVE_WITH_PARITY keeps StageOps read-only so the SHADOW probe
        // cannot double-write beside worker_run_compact_slice.
        _runtime_host->attach_economy_stage_ops(
            economy->make_graph_stage_ops(/*mutate=*/economy_stage_ops_mutate));
        if (economy_execution_mode != EconomyExecutionMode::LEGACY_ONLY) {
            _runtime_host->attach_economy_production_runtime(economy);
        } else {
            _runtime_host->attach_economy_production_runtime(nullptr);
        }
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
    out["economy_execution_mode"] =
        String(economy_execution_mode_name(economy_execution_mode));
    out["economy_stage_ops_mutate"] = economy_stage_ops_mutate;
    out["economy_auto_pod_active"] = economy_auto_pod_active;
    out["economy_stage_ops_soak_experiment"] =
        economy_stage_ops_soak_experiment;
    out["economy_stage_ops_soak_parity_ok"] =
        _runtime_host->economy_stage_ops_soak_parity_ok();
    out["economy_production_writer"] = String(
        economy_production_writer_name(
            _runtime_host->economy_production_writer_requested()));
    out["economy_production_writer_requested"] = String(
        economy_production_writer_name(
            _runtime_host->economy_production_writer_requested()));
    out["economy_production_writer_effective"] = String(
        economy_production_writer_name(
            _runtime_host->economy_production_writer_effective()));
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
    if (!_runtime_host->publish_environment(snapshot, publish_error)) {
        out["ok"] = false;
        out["code"] = String(publish_error.empty()
            ? "runtime_input_publish_failed" : publish_error.c_str());
        out["generation"] = static_cast<int64_t>(snapshot.generation);
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
    if (_country_runtime != nullptr) {
        CountryCoreCheckpoint checkpoint;
        std::string country_error;
        if (!static_cast<NativeCountryRuntime *>(_country_runtime)
                 ->capture_core_checkpoint(checkpoint, country_error) ||
            !_runtime_host->publish_country_checkpoint(checkpoint,
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
    _climate_physics_committed.reset();
    _climate_physics_capture_ready = false;
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
    _climate_physics_committed.reset();
    _climate_physics_capture_ready = false;
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = true;
        out["pending"] = false;
        out["state"] = "STOPPED";
        return out;
    }
    const RuntimeWorkerState before = _runtime_host->state();
    _runtime_host->attach_economy_production_runtime(nullptr);
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
    const bool ok = RuntimeCountryPodAuthority::self_test(error);
    if (!ok && !error.empty())
        godot::UtilityFunctions::printerr(
            godot::String("runtime_country_pod_self_test: ") +
            godot::String(error.c_str()));
    return ok;
}

bool DCWorldExt::runtime_protocol_guard_self_test() const {
    std::string error;
    return RuntimeProtocolGuard::self_test(error);
}

bool DCWorldExt::runtime_trigger_pod_self_test() const {
    std::string error;
    return RuntimeTriggerPodAuthority::self_test(error);
}

bool DCWorldExt::runtime_effect_pod_self_test() const {
    std::string error;
    const bool ok = RuntimeEffectPodAuthority::self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_effect_pod_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_effect_host_stage_self_test() {
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    std::string error;
    const bool ok = _runtime_host->effect_pod_host_stage_self_test(&error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_effect_host_stage_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_ideology_pod_self_test() const {
    std::string error;
    const bool ok = RuntimeIdeologyPodAuthority::self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_ideology_pod_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_events_authority_self_test() const {
    std::string error;
    const bool ok = RuntimeEventsAuthority::self_test(error) &&
        RuntimeEventsSnapshotRing::self_test();
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_events_authority_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_economy_pod_self_test() const {
    std::string error;
    const bool ok = RuntimeEconomyPodAuthority::self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_economy_pod_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

Dictionary DCWorldExt::switch_economy_authority(const String &mode) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeEconomyAuthorityMode parsed =
        RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    const CharString utf8 = mode.utf8();
    const char *text = utf8.get_data();
    if (text == nullptr || text[0] == '\0' ||
        std::strcmp(text, "LEGACY_SYNC") == 0) {
        parsed = RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    } else if (std::strcmp(text, "POD_ACTIVE_WITH_LEGACY_PARITY") == 0) {
        parsed = RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY;
    } else if (std::strcmp(text, "POD_ACTIVE") == 0) {
        parsed = RuntimeEconomyAuthorityMode::POD_ACTIVE;
    } else {
        out["ok"] = false;
        out["code"] = "economy_authority_mode_invalid";
        return out;
    }
    std::string error;
    const bool ok = _runtime_host->switch_economy_authority(parsed, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    out["economy_worker_is_authoritative"] =
        _runtime_host->economy_worker_is_authoritative();
    out["economy_legacy_fallback_enabled"] =
        _runtime_host->economy_legacy_fallback_enabled();
    out["authority_mode"] = static_cast<int>(
        _runtime_host->economy_authority_mode());
    const RuntimeThreadReport audit = _runtime_host->report();
    out["economy_authority_switch_count"] = static_cast<int64_t>(
        audit.economy_authority_switch_count);
    out["economy_authority_switch_audit_sequence"] = static_cast<int64_t>(
        audit.economy_authority_switch_audit_sequence);
    out["economy_authority_switch_before_hash"] = static_cast<int64_t>(
        audit.economy_authority_switch_before_hash);
    out["economy_authority_switch_after_hash"] = static_cast<int64_t>(
        audit.economy_authority_switch_after_hash);
    out["economy_authority_switch_before_generation"] = static_cast<int64_t>(
        audit.economy_authority_switch_before_generation);
    out["economy_authority_switch_after_generation"] = static_cast<int64_t>(
        audit.economy_authority_switch_after_generation);
    out["economy_authority_switch_latency_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_us);
    out["economy_authority_switch_latency_p95_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_p95_us);
    out["economy_authority_switch_latency_max_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_max_us);
    out["economy_authority_switch_command_latency_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_command_latency_us);
    out["economy_authority_switch_command_latency_p95_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_command_latency_p95_us);
    out["economy_authority_switch_command_latency_max_us"] = static_cast<int64_t>(
        audit.economy_authority_switch_command_latency_max_us);
    out["economy_authority_switch_latency_sample_count"] = static_cast<int64_t>(
        audit.economy_authority_switch_latency_sample_count);
    out["economy_authority_switch_rejected"] = static_cast<int64_t>(
        audit.economy_authority_switch_rejected);
    out["economy_authority_switch_reason"] = String(
        audit.economy_authority_switch_reason);
    out["economy_authority_switch_blocker"] = String(
        audit.economy_authority_switch_blocker);
    out["economy_authority_switch_audit_before"] = String(
        audit.economy_authority_switch_audit_before);
    out["economy_authority_switch_audit_after"] = String(
        audit.economy_authority_switch_audit_after);
    return out;
}

bool DCWorldExt::runtime_economy_authority_fault_gate_self_test() const {
    auto probe = std::make_unique<NativeSimulationHost>();
    std::string error;
    const bool ok = probe->economy_authority_fault_gate_self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_economy_authority_fault_gate_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

godot::Dictionary DCWorldExt::runtime_economy_stage_order_contract_test() const {
    godot::Dictionary out;
    std::string error;
    const bool ok = economy_graph_kernels_self_test(error);
    out["ok"] = ok;
    out["stage_count"] = static_cast<int64_t>(RUNTIME_ECONOMY_GRAPH_STAGE_COUNT);
    out["all_stage_mask"] = static_cast<int64_t>(RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK);
    godot::PackedStringArray names;
    names.resize(static_cast<int64_t>(RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        names.set(static_cast<int64_t>(i), godot::String(
            runtime_economy_graph_stage_name(
                static_cast<RuntimeEconomyGraphStage>(i))));
    }
    out["stage_names"] = names;
    if (!ok) out["error"] = godot::String(error.c_str());
    return out;
}

namespace {

// 把生产侧交来的 MapData 数组还原成一份 RuntimeClimateStore。
//
// 键名就是 parity 表的 canonical name（RuntimeClimateParityField::name 的注释里
// 写明了它同时是这个绑定接受的字典键），所以这里不存在第二套名字映射 —— 表是
// 唯一的真相，加一个 parity 字段不需要动这个函数。
//
// 缺一条 comparable 字段就整份拒绝，`missing_fields` 带回是哪几条。**不能**把缺席
// 的字段当成零值继续哈希：那样归约照样出一个数，而两侧的零位置不同，日后会以
// "Climate 算法分叉"的形式浮出来 —— 一个本来在边界上就能一句话说清的问题，变成
// 要从分叉矩阵反推的谜题。cell_count 同理不从数组长度推断：推断出来的值一旦不对，
// 逐条 size 检查会把每条字段都报成长度错，掩盖真正缺失的那一条。
bool build_climate_store_from_fields(const Dictionary &fields,
                                     RuntimeClimateStore &store,
                                     String &error,
                                     Array *missing_fields = nullptr) {
    const int cell_count = static_cast<int>(fields.get("cell_count", 0));
    if (cell_count <= 0) {
        error = String("climate_reference_cell_count_missing");
        return false;
    }
    store.reset(static_cast<uint32_t>(cell_count));
    store.climate_anomaly =
        static_cast<float>(static_cast<double>(fields.get("climate_anomaly", 0.0)));
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    Array missing;
    for (size_t i = 0; i < count; ++i) {
        const RuntimeClimateParityField &f = table[i];
        // 非 comparable 的两类字段本来就不该出现：no_reference 是生产侧没有对应的
        // MapData 数组，type_mismatch 是两侧元素类型无法逐位比 —— 归约也不含它们。
        if (!fields.has(f.name)) {
            if (f.comparability ==
                    RuntimeClimateParityComparability::COMPARABLE) {
                missing.push_back(String(f.name));
            }
            continue;
        }
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
    if (!missing.is_empty()) {
        error = String("climate_parity_fields_missing");
        if (missing_fields != nullptr) *missing_fields = missing;
        return false;
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

bool DCWorldExt::climate_physics_authoritative() const {
    if (!climate_worker_authoritative() || !_climate_physics_capture_ready || !_map_data ||
        _climate_physics_map_id != _map_data->get_instance_id() || !_climate_physics_committed ||
        !_climate_physics_committed->ready || !_climate_physics_committed->initialized) return false;
    const auto input = _runtime_host->environment_snapshot();
    return input && input->cell_count == static_cast<uint32_t>(_climate_physics_committed->cell_count) &&
        input->climate_physics_knobs.ready && input->climate_physics_knobs.enabled;
}

Dictionary DCWorldExt::get_climate_physics_read_view() const {
    Dictionary out;
    const auto committed = _climate_physics_committed;
    const bool ready = climate_physics_authoritative();
    out["ready"] = ready;
    out["authoritative"] = ready;
    out["ok"] = ready;
    out["code"] = ready ? "ok" : "physics_not_committed_or_not_granted";
    if (!ready) return out;
    const auto &s = *committed;
    out["committed_day"] = s.committed_day;
    out["input_generation"] = static_cast<int64_t>(s.input_generation);
    out["generation"] = static_cast<int64_t>(s.generation);
    out["state_hash"] = static_cast<int64_t>(s.state_hash());
    out["cell_count"] = s.cell_count;
    out["last_slp_day"] = s.last_slp_day;
    out["last_wind_day"] = s.last_wind_day;
    out["last_ocean_day"] = s.last_ocean_day;
    auto lane = [&](const char *name, const std::vector<float> &v) {
        PackedFloat32Array a;
        a.resize(static_cast<int>(v.size()));
        if (!v.empty()) std::memcpy(a.ptrw(), v.data(), v.size() * sizeof(float));
        out[name] = a;
    };
    lane("slp", s.slp); lane("wind_x", s.wind_x); lane("wind_y", s.wind_y);
    lane("wind_speed", s.wind_speed); lane("ocean_current_x", s.ocean_current_x);
    lane("ocean_current_y", s.ocean_current_y); lane("ocean_psi", s.ocean_psi);
    lane("upwelling", s.upwelling); lane("wind_stress_curl", s.wind_stress_curl);
    lane("ocean_thermal_anomaly", s.ocean_thermal_anomaly);
    lane("monsoon_thermal", s.monsoon_thermal); lane("synoptic_psi", s.synoptic_psi);
    return out;
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

// 这三条枚举跨边界时给的是字符串而不是序号：GDScript 侧一律用 String() 包装它们
// （map_generator.gd:2434 的 != "comparable"、runtime_climate_parity_test 的
// in ["f32","i32","u8"]），而 Godot 4 的 String() 构造不接受 int —— 给序号会在那一行
// 抛 "Nonexistent 'String' constructor"，把 _collect_runtime_climate_parity_fields
// 整个打断，于是 reference publish 永远 pending、SHADOW 对拍一天都比不上。
static const char *pk_parity_kind_name(RuntimeClimateParityKind kind) {
    switch (kind) {
        case RuntimeClimateParityKind::F32: return "f32";
        case RuntimeClimateParityKind::I32: return "i32";
        case RuntimeClimateParityKind::U8:  return "u8";
    }
    return "f32";
}

static const char *pk_parity_comparability_name(
        RuntimeClimateParityComparability c) {
    switch (c) {
        case RuntimeClimateParityComparability::COMPARABLE: return "comparable";
        case RuntimeClimateParityComparability::TYPE_MISMATCH:
            return "type_mismatch";
        case RuntimeClimateParityComparability::NO_REFERENCE:
            return "no_reference";
    }
    return "no_reference";
}

static const char *pk_parity_tolerance_name(RuntimeClimateParityTolerance t) {
    switch (t) {
        case RuntimeClimateParityTolerance::BITWISE: return "bitwise";
        case RuntimeClimateParityTolerance::SLICED:  return "sliced";
        case RuntimeClimateParityTolerance::CHAINED: return "chained";
    }
    return "bitwise";
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
        row["kind"] = String(pk_parity_kind_name(f.kind));
        row["comparability"] = String(pk_parity_comparability_name(f.comparability));
        row["tolerance"] = String(pk_parity_tolerance_name(f.tolerance));
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(f.tolerance);
        row["stage"] = static_cast<int>(f.stage);
        row["stage_name"] = String(runtime_climate_stage_name(f.stage));
        row["note"] = String(f.note != nullptr ? f.note : "");
        out.push_back(row);
    }
    return out;
}

Dictionary DCWorldExt::wait_climate_consumed(
        int64_t after_environment_generation, int64_t timeout_ms) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        // 契约：等待接口永远报告消费游标，即使 worker 从未启动 —— 调用方据此
        // 保持自己的游标不动，而不是把缺失键当成 0。
        out["consumed_generation"] = 0;
        out["after_environment_generation"] = after_environment_generation;
        out["waited_ms"] = 0.0;
        return out;
    }
    if (after_environment_generation < 0) {
        const RuntimeThreadReport snapshot = _runtime_host->report();
        out["ok"] = false;
        out["code"] = "climate_wait_generation_invalid";
        out["consumed_generation"] =
            static_cast<int64_t>(snapshot.climate_consumed_generation);
        return out;
    }
    const auto started = std::chrono::steady_clock::now();
    uint64_t consumed = 0;
    std::string error;
    const bool ok = _runtime_host->wait_climate_consumed(
        static_cast<uint64_t>(after_environment_generation), timeout_ms,
        consumed, error);
    const double waited_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out["ok"] = ok;
    out["code"] = ok ? String("ok") : String(error.c_str());
    out["waited_ms"] = waited_ms;
    out["after_environment_generation"] = after_environment_generation;
    out["consumed_generation"] = static_cast<int64_t>(consumed);
    out["worker_state"] = static_cast<int>(_runtime_host->state());
    const RuntimeThreadReport snapshot = _runtime_host->report();
    out["climate_committed_day"] = snapshot.climate_committed_day;
    out["environment_published_days"] =
        static_cast<int64_t>(snapshot.environment_published_days);
    out["environment_consumed_days"] =
        static_cast<int64_t>(snapshot.environment_consumed_days);
    out["environment_superseded_days"] =
        static_cast<int64_t>(snapshot.environment_superseded_days);
    return out;
}

Dictionary DCWorldExt::apply_runtime_climate_writeback(
        int64_t after_generation) {
    Dictionary out;
    const auto writeback_start = std::chrono::steady_clock::now();
    out["committed_day"] = _climate_physics_committed ? _climate_physics_committed->committed_day : -1;
    out["input_generation"] = _climate_physics_committed
        ? static_cast<int64_t>(_climate_physics_committed->input_generation) : int64_t(0);
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

    using PhysicsState = pk_async_physics::RuntimeClimatePhysicsState;
    std::shared_ptr<PhysicsState> physics;
    if (!store.physics_state.empty()) {
        physics = std::make_shared<PhysicsState>();
        std::string error;
        if (!pk_async_physics::restore_physics_state(store.physics_state.data(), store.physics_state.size(), *physics, error) ||
            physics->cell_count != cell_count || physics->committed_day != snapshot.committed_day ||
            physics->input_generation != snapshot.input_generation) {
            _runtime_host->release_climate_writeback(slot);
            _climate_physics_committed.reset();
            out["ok"] = false; out["applied"] = false;
            out["code"] = error.empty() ? String("physics_commit_mismatch") : String(error.c_str());
            return out;
        }
    }
    const bool apply_physics = physics && physics->initialized && physics->ready && climate_worker_authoritative();
    // 物理 family 全部预检通过后才写；任何缺槽都不能宣称 grant。
    if (apply_physics) {
        for (const char *name : {"cell_slp", "cell_wind_x", "cell_wind_y", "cell_wind_speed",
                "cell_ocean_current_x", "cell_ocean_current_y", "cell_ocean_psi",
                "cell_upwelling_strength", "cell_wind_stress_curl", "cell_ocean_thermal_anomaly"}) {
            const int sid = component_id(StringName(name));
            if (sid < 0 || sid >= _slots.size() || _slots[sid].dtype != SlotDType::F32 ||
                (_slots[sid].external_ref && _slots[sid].arr_f32.size() != cell_count)) {
                _runtime_host->release_climate_writeback(slot);
                _climate_physics_committed.reset();
                out["ok"] = false; out["applied"] = false;
                out["code"] = String("physics_writeback_slot_invalid:") + name;
                return out;
            }
        }
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
    if (apply_physics) {
        apply_extra("slp", "cell_slp", physics->slp);
        apply_extra("wind_x", "cell_wind_x", physics->wind_x);
        apply_extra("wind_y", "cell_wind_y", physics->wind_y);
        apply_extra("wind_speed", "cell_wind_speed", physics->wind_speed);
        apply_extra("ocean_current_x", "cell_ocean_current_x", physics->ocean_current_x);
        apply_extra("ocean_current_y", "cell_ocean_current_y", physics->ocean_current_y);
        apply_extra("ocean_psi", "cell_ocean_psi", physics->ocean_psi);
        apply_extra("upwelling", "cell_upwelling_strength", physics->upwelling);
        apply_extra("wind_stress_curl", "cell_wind_stress_curl", physics->wind_stress_curl);
        apply_extra("ocean_thermal_anomaly", "cell_ocean_thermal_anomaly", physics->ocean_thermal_anomaly);
        _phys_slp_buf = physics->slp;
        _phys_monsoon_thermal = physics->monsoon_thermal;
        // traj 是派生缓存，使用本次提交风场重建，绝不携带 worker 裸指针。
        const auto env = _runtime_host->environment_snapshot();
        _phys_wind_traj_valid = false;
        if (env && env->cell_pos_x.size() == size_t(cell_count) && env->cell_pos_y.size() == size_t(cell_count) &&
            env->neighbor_indices.size() == size_t(cell_count) * 6 && env->generation == snapshot.input_generation &&
            physics->wind_traj_generation > 0) {
            const auto &k = env->climate_physics_knobs;
            _phys_build_wind_traj(cell_count, env->cell_pos_x.data(), env->cell_pos_y.data(),
                env->neighbor_indices.data(), physics->wind_x.data(), physics->wind_y.data(), physics->wind_speed.data(),
                k.wrap_period_x, k.wind_traj_pos_scale, k.wind_traj_dt_days);
            _phys_wind_traj_consume_enabled = k.wind_traj_weather_share != 0;
        }
    }
    apply_extra("soil_moisture", "cell_soil_moisture", snapshot.soil_moisture);
    // pass_a 的日照/热量输出。worker 内部算得对（round 内 pass_a→pass_b 走 out 缓冲，
    // 不经 MapData），坏的是外部读者：渲染、tile 录制、UI 面板读的都是 MapData。
    apply_extra("insolation_now", "cell_insolation_now", snapshot.insolation_now);
    apply_extra("insolation_dev", "cell_insolation_dev", snapshot.insolation_dev);
    apply_extra("day_length", "cell_day_length", snapshot.day_length);
    apply_extra("heat_input", "cell_heat_input", snapshot.heat_input);
    apply_extra("temp_season_offset", "cell_temp_season_offset",
                snapshot.temp_season_offset);

    const auto apply_extra_u8 = [&](const char *field_name, const char *slot_name,
                                    const std::vector<uint8_t> &source) {
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
        if (s.dtype != SlotDType::U8) {
            skipped.push_back(String(field_name) + String("(dtype)"));
            return;
        }
        if (s.arr_u8.size() != cell_count && s.external_ref) {
            skipped.push_back(String(field_name) + String("(extern_size)"));
            return;
        }
        if (s.arr_u8.size() != cell_count) s.arr_u8.resize(cell_count);
        std::memcpy(s.arr_u8.ptrw(), source.data(),
                    static_cast<size_t>(cell_count) * sizeof(uint8_t));
        touched_slots.push_back(String(slot_name));
        ++applied_fields;
    };
    apply_extra_u8("weather_field_init", "cell_weather_field_init",
                   snapshot.weather_field_init);

    const int64_t applied_day = snapshot.committed_day;
    const uint64_t applied_generation = snapshot.generation;
    const uint64_t applied_state_hash = snapshot.state_hash;
    const uint64_t applied_input_generation = snapshot.input_generation;
    const float applied_vapor_first = store.vapor.empty() ? 0.0f : store.vapor[0];
    // B8 P0：把"回灌慢"拆成 memcpy（worker 快照 → slot）与 flush（slot → MapData）
    // 两段。二者混在一个 total 里时，无法判断瓶颈是拷贝量还是 MapData 的写回路径，
    // 而这两条要采取的措施完全不同。
    const auto copy_done = std::chrono::steady_clock::now();
    // Release before flushing: the flush writes MapData, which the worker never
    // touches, so there is no reason to keep a ring slot occupied across it.
    _runtime_host->release_climate_writeback(slot);

    flush_slots_to_map_keys(touched_slots);
    _climate_physics_committed = apply_physics ? std::move(physics) : nullptr;
    _climate_physics_map_id = _map_data->get_instance_id();
    // B8 诊断（一次性）：确认天气场在 writeback 之后是否真的进了 MapData。用它
    // 区分"flush 没写进去"与"写进去之后被同 tick 的主线程写者覆盖"。
    {
        static std::atomic<int> s_weather_wb_reports_left{4};
        if (s_weather_wb_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            const Variant map_vapor = _map_data->get(StringName("weather_vapor_arr"));
            float map_first = 0.0f;
            float store_first = 0.0f;
            if (map_vapor.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
                const PackedFloat32Array arr = map_vapor;
                if (arr.size() > 0) map_first = arr[0];
            }
            store_first = applied_vapor_first;
            std::fprintf(stderr,
                "[climate/writeback][b8] day=%lld vapor store0=%.6g map0=%.6g "
                "dirty_fields=%d applied=%d\n",
                static_cast<long long>(applied_day), store_first, map_first,
                static_cast<int>(touched_slots.size()), applied_fields);
            std::fflush(stderr);
        }
    }
    const auto flush_done = std::chrono::steady_clock::now();
    const double copy_ms = std::chrono::duration<double, std::milli>(
        copy_done - writeback_start).count();
    const double flush_ms = std::chrono::duration<double, std::milli>(
        flush_done - copy_done).count();
    const double total_ms = std::chrono::duration<double, std::milli>(
        flush_done - writeback_start).count();

    out["ok"] = true;
    // applied 只在真的写进了字段时为真。曾经这里无条件报 true，于是"回灌假活跃"
    // 让一次全空的写回看起来和成功一模一样。
    out["applied"] = applied_fields > 0;
    out["code"] = "ok";
    out["day"] = applied_day;
    out["committed_day"] = applied_day;
    out["input_generation"] = static_cast<int64_t>(applied_input_generation);
    out["physics_applied"] = apply_physics;
    out["physics_authoritative"] = climate_physics_authoritative();
    if (_runtime_host) {
        _runtime_host->note_climate_writeback_input_generation(
            applied_input_generation);
    }
    out["generation"] = static_cast<int64_t>(applied_generation);
    out["state_hash"] = static_cast<int64_t>(applied_state_hash);
    out["cell_count"] = static_cast<int64_t>(cell_count);
    // 键名由 GDScript 侧决定（world_runtime_host._apply_runtime_climate_writeback
    // 读的就是这两个）。被 slot 守卫拒掉的字段是"worker 拥有但从不发布"的字段，
    // MapData 会静默停在转权威那天的值 —— 所以拒绝清单必须出得来，不能只报计数。
    out["applied_fields"] = applied_fields;
    out["dirty_fields"] = touched_slots.size();
    out["skipped_fields"] = skipped;
    out["memcpy_ms"] = copy_ms;
    out["flush_map_ms"] = flush_ms;
    out["total_ms"] = total_ms;
    out["drops"] =
        static_cast<int64_t>(_runtime_host->climate_writeback_drop_count());
    return out;
}

Dictionary DCWorldExt::compute_runtime_climate_parity_hash(
        const Dictionary &fields) {
    Dictionary out;
    RuntimeClimateStore store;
    String error;
    Array missing;
    if (!build_climate_store_from_fields(fields, store, error, &missing)) {
        out["ok"] = false;
        // 缺字段与"字段有问题"是两种不同的 code：前者调用方能直接读出缺哪几条，
        // 后者要看 field 里的 name(dtype|size)。
        out["code"] = missing.is_empty()
            ? String("climate_reference_fields_invalid") : error;
        out["field"] = error;
        out["missing_fields"] = missing;
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["cell_count"] = static_cast<int64_t>(store.cell_count);
    // 用与 worker 完全相同的那一个归约函数。两侧"按约定各算一遍"是这条对拍最早的
    // 失效方式，所以这里刻意不复制哈希逻辑。
    out["parity_hash"] =
        static_cast<int64_t>(runtime_climate_parity_hash(store));
    out["parity_version"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_VERSION);
    out["fields_hashed"] =
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
    Array missing;
    if (!build_climate_store_from_fields(fields, *store, error, &missing)) {
        out["ok"] = false;
        out["code"] = missing.is_empty()
            ? String("climate_reference_fields_invalid") : error;
        out["field"] = error;
        out["missing_fields"] = missing;
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
        out["parity_hash"] = static_cast<int64_t>(state_hash);
        return out;
    }
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    out["day"] = day;
    // 键名是 parity_hash：调用方（map_generator.gd:2548）按它取值，取到 0 会判成
    // "归约什么都没算出来"并把这一天整个作废。
    out["parity_hash"] = static_cast<int64_t>(state_hash);
    out["cell_count"] = static_cast<int64_t>(store->cell_count);
    return out;
}

bool DCWorldExt::runtime_climate_writeback_self_test() const {
    std::string error;
    return RuntimeClimateWritebackRing::self_test(error) &&
           RuntimeEnvironmentInputRing::self_test(error);
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
    out["fields_total"] =
        static_cast<int64_t>(runtime_climate_parity_field_count());
    out["fields_comparable"] =
        static_cast<int64_t>(runtime_climate_parity_comparable_count());
    out["fields_max"] =
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
        // 与 get_runtime_climate_parity_fields 同一口径：字符串而不是枚举序号。
        row["tolerance"] = String(pk_parity_tolerance_name(table[i].tolerance));
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(table[i].tolerance);
        row["comparability"] =
            String(pk_parity_comparability_name(table[i].comparability));
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
