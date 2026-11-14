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
    // native_daily_inline：日屏障由调用线程执行，本 host 没有 worker 线程。
    out["native_daily_inline"] = report.inline_daily;
    out["graph_coverage_complete"] = report.graph_coverage_complete;
    out["authority_ready"] = report.authority_ready;
    out["required_domain_mask"] = static_cast<int64_t>(report.required_domain_mask);
    out["implemented_domain_mask"] = static_cast<int64_t>(report.implemented_domain_mask);
    out["missing_domain_mask"] = static_cast<int64_t>(report.missing_domain_mask);
    out["active_evidence_mask"] = static_cast<int64_t>(report.active_evidence_mask);
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
    const char *timing_names[] = {"execute", "input_wait", "clock_wait", "save_build", "save_pause", "paused", "overhead", "boundary_wait"};
    uint64_t timing_total = 0;
    for (size_t i = 0; i < report.worker_time_us.size(); ++i) {
        out[String("worker_time_") + timing_names[i] + "_us"] = static_cast<int64_t>(report.worker_time_us[i]);
        timing_total += report.worker_time_us[i];
    }
    out["worker_time_total_us"] = static_cast<int64_t>(timing_total);
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
    out["economy_authority_switch_audit_hash"] = static_cast<int64_t>(
        report.economy_authority_switch_audit_hash);
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
    out["effect_pod_managed_intent_count"] = static_cast<int>(
        report.effect_pod_managed_intent_count);
    out["effect_pod_unmanaged_intent_count"] = static_cast<int>(
        report.effect_pod_unmanaged_intent_count);
    out["effect_pod_transaction_count"] = static_cast<int>(
        report.effect_pod_transaction_count);
    PackedInt32Array effect_program_ids;
    effect_program_ids.resize(static_cast<int>(
        report.effect_pod_program_intent_count));
    for (uint32_t i = 0; i < report.effect_pod_program_intent_count; ++i) {
        effect_program_ids.set(static_cast<int>(i),
            report.effect_pod_intent_program_ids[i]);
    }
    out["effect_pod_intent_program_ids"] = effect_program_ids;
    out["effect_retire_absent_count"] = static_cast<int64_t>(
        report.effect_retire_absent_count);
    out["effect_retire_stale_count"] = static_cast<int64_t>(
        report.effect_retire_stale_count);
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
    out["events_pod_rejected_count"] =
        static_cast<int64_t>(report.events_pod_rejected_count);
    out["events_failed_day"] = report.events_failed_day;
    out["events_pod_fallback_reason"] = String(report.events_pod_fallback_reason);
    out["fault_code"] = String(report.fault_code);
    out["fault_injection_armed"] = report.fault_injection_armed;
    out["fault_injection_trip_count"] = static_cast<int64_t>(
        report.fault_injection_trip_count);
    out["fault_injection_point"] = String(report.fault_injection_point);
    return out;
}

Dictionary DCWorldExt::start_runtime_worker(const Dictionary &config) {
    // Reject before touching executor selection, parallelism or peer bindings.
    if (_runtime_host && (_runtime_host->state() != RuntimeWorkerState::STOPPED ||
                          !_runtime_host->execution_has_stopped())) {
        Dictionary rejected;
        rejected["ok"] = false;
        rejected["pending"] = false;
        rejected["code"] = "runtime_thread_mode_hot_switch_forbidden";
        rejected["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
        return rejected;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    // native_daily_inline：必须在 start() 之前落到 host 上，start() 读它决定
    // "起不起 worker 线程"。缺省 false —— 桌面端路径逐字节不变。
    const bool native_daily_inline = static_cast<bool>(
        config.get("native_daily_inline", false));
    // Inline uses serial dispatch; PK_INLINE_PARALLEL is the diagnostic override.
    static const bool inline_parallel_override = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_INLINE_PARALLEL);
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
    // [web-parallel 2026-10-31] 浏览器里 Emscripten 的 pthread 池是**固定 16 槽**
    // （导出模板编译期决定，Godot 的 WorkerThreadPool / native daily worker / 音频
    // 已经占掉一部分），而 NativeParallelExecutor 按 `hardware_concurrency()-2`
    // 去 spawn（浏览器报告 8–32 ⇒ 实测要起 8–14 个）。
    //
    // 后果不是"并行慢一点"，而是**负收益**：起不全的 worker 不会去减 `_remaining_tasks`
    // （见上面内联日那段注释），而每一次 `parallel_for_range` 都要付跨 wasm thread 的
    // 派活 / 唤醒延迟。真机实测（RTX 4080 + Chrome，新 side module）：
    //   worker 模式（并行器开着）：单日墙钟 250–370 ms ⇒ 2.70 天/秒
    //   inline 模式（并行器关着）：单日墙钟 46 ms     ⇒ 9.81 天/秒
    // 同一份 12 域日图、同一台机器，串行比"并行"快 5–8 倍 —— 所以 web 上**一律串行**，
    // 与走 inline 还是 worker 无关。桌面（非 wasm）不受影响。
    // A/B 旁路：PK_WEB_PARALLEL=1 时保留线程池。
    static const bool web_parallel_override = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_WEB_PARALLEL);
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
#if defined(__EMSCRIPTEN__)
    const bool web_serial_only = !web_parallel_override;
#else
    const bool web_serial_only = false;
#endif
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
    if (native_daily_inline && mode == RuntimeSimulationMode::SHADOW) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_config_invalid";
        out["message"] = "inline_daily_requires_active";
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
    _climate_physics_committed.reset();
    _climate_writeback_applied_generation = 0;
    _climate_writeback_applied_day = -1;
    _runtime_host->set_inline_daily_mode(native_daily_inline);
    set_parallel_serial_only(
        (native_daily_inline && !inline_parallel_override) || web_serial_only);
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)
            ->attach_simulation_host(_runtime_host.get());
    }
    attach_country_ai_to_host();
    _runtime_host->set_events_probe_enabled(events_probe_enabled);
    _runtime_host->set_economy_execution_mode(economy_execution_mode);
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
    // A restore start is granted immediately; make the main-thread peers see
    // that grant now rather than on a runtime-graph pulse that may not run.
    sync_runtime_domain_ownership();
    // Every worker lifetime numbers its Ideology snapshots from 1 again.
    if (_ideology_runtime != nullptr)
        static_cast<NativeIdeologyRuntime *>(_ideology_runtime)
            ->reset_pod_snapshot_cursor();
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
    // The two mask ledgers, at the moment this lifetime starts. A FRESH start
    // reports requested != 0 with granted == 0 (deferred until the first commit);
    // a RESTART additionally reports the per-host ledger it just re-published, so a
    // caller can tell "the grant carried over" from "the grant is still pending"
    // without waiting for a day to commit.
    out["requested_authority_mask"] =
        static_cast<int64_t>(_runtime_host->report().requested_authority_mask);
    out["authoritative_domain_mask"] =
        static_cast<int64_t>(_runtime_host->authoritative_domain_mask());
    out["lifetime_granted_mask"] =
        static_cast<int64_t>(_runtime_host->lifetime_granted_mask());
    out["native_daily_inline"] = native_daily_inline;
    out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report());
    return out;
}

// ===== native_daily_inline：单线程内联日 =====
//
// 调用线程执行同一份十二域计划，并在重试之间服务 Country peer。
// 不等待后台线程；主线程的同步写入口必须随已提交的归属一并更新。
Dictionary DCWorldExt::run_native_daily_inline_day() {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_host_missing";
        out["reason"] = "runtime_host_missing";
        return out;
    }
    if (!_runtime_host->inline_daily_mode()) {
        out["ok"] = false;
        out["code"] = "native_daily_inline_disabled";
        out["reason"] = "native_daily_inline_disabled";
        return out;
    }
    const auto started = std::chrono::steady_clock::now();
    // 一天之内最多重试这么多次。Country 的 peer 集合是"每天有限个 intent"，
    // 一轮泵就完成一批，所以这个上限只防退化，不是性能旋钮。
    constexpr uint32_t kMaxInlineAttempts = 8u;
    constexpr int kPeerIntentsPerPump = 256;
    // 整次调用的墙钟总预算。单次尝试另有 execute_day_plan 里的 stage 间看门狗，
    // 这一道总闸保证"8 次重试 × 每次接近预算"也不会把主线程钉住 —— 浏览器里
    // 一次可上报的失败远好过页面再无心跳。
    const int64_t total_budget_us = NativeSimulationHost::inline_day_budget_us();
    const auto elapsed_us = [&started]() -> int64_t {
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started).count();
    };
    const auto ms_since = [](std::chrono::steady_clock::time_point mark) -> double {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - mark).count();
    };
    NativeSimulationHost::InlineDayOutcome outcome;
    uint32_t attempts = 0;
    uint64_t peer_pumped = 0;
    // 分域耗时按"尝试"求和：一次内联日可能重试同一天，重试会把 Climate/Country
    // 再付一次，所以 stage_ms 是真正烧掉的 CPU，attempt_ms 是每次尝试的总账。
    double stage_ms[RUNTIME_DOMAIN_STAGE_COUNT]{};
    double pre_stage_ms = 0.0;
    double climate_ms = 0.0;
    double plan_build_ms = 0.0;
    double commit_tail_ms = 0.0;
    double peer_ms = 0.0;
    bool budget_exceeded = false;
    // 区分两种掐断：单日看门狗（execute_day_plan 里按 stage 间检查）与本次
    // 调用的总预算（8 次重试加起来）。前者 reason 已由 host 写好，后者要在
    // 这里盖一个自己的原因码，否则浏览器只会看到上一次尝试的 peer 原因。
    bool attempt_budget_tripped = false;
    Array attempt_ms;
    while (attempts < kMaxInlineAttempts) {
        ++attempts;
        const auto attempt_started = std::chrono::steady_clock::now();
        outcome = _runtime_host->run_inline_day();
        attempt_ms.append(ms_since(attempt_started));
        for (uint32_t i = 0; i < RUNTIME_DOMAIN_STAGE_COUNT; ++i)
            stage_ms[i] += outcome.stage_ms[i];
        pre_stage_ms += outcome.pre_stage_ms;
        climate_ms += outcome.climate_ms;
        plan_build_ms += outcome.plan_build_ms;
        commit_tail_ms += outcome.commit_tail_ms;
        if (outcome.budget_exceeded) {
            budget_exceeded = true;
            break;
        }
        if (outcome.committed || !outcome.continuation_pending) break;
        if (total_budget_us > 0 && elapsed_us() >= total_budget_us) {
            budget_exceeded = true;
            attempt_budget_tripped = true;
            break;
        }
        // peer 就在本线程。把 Country peer 适配器推一轮（Effect/Modifier/
        // Economy 的 intent 服务都由它同一线程完成），再重试同一天。
        if (_country_runtime == nullptr) break;
        auto *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        if (!country->peer_async_mode()) country->set_peer_async_mode(true);
        NativeCountryRuntime::PeerAdapterServiceReport peer_report;
        std::string peer_error;
        const auto peer_started = std::chrono::steady_clock::now();
        const bool peer_ok = country->service_peer_intents_main_thread(
            kPeerIntentsPerPump, peer_report, peer_error);
        peer_ms += ms_since(peer_started);
        if (!peer_ok) {
            out["peer_error"] = String(peer_error.empty()
                ? "country_peer_adapter_service_failed" : peer_error.c_str());
            break;
        }
        peer_pumped += peer_report.inspected;
        // 一轮泵什么都没看到，说明卡的不是 peer（例如输入帧/经济输入），
        // 再试同一天只会原样失败。
        if (peer_report.inspected == 0u) break;
    }
    // Inline earns its first grants inside the call. Deliver them before the
    // main-thread save/should_run gates can advance a stale sync facade.
    sync_runtime_domain_ownership();
    const double elapsed_ms = ms_since(started);
    const RuntimeThreadReport report = _runtime_host->report();
    out["ok"] = outcome.committed;
    out["code"] = outcome.committed ? "ok"
        : (attempt_budget_tripped ? String("inline_daily_attempt_budget_exceeded")
                                  : String(outcome.reason));
    out["reason"] = attempt_budget_tripped && !outcome.committed
        ? String("inline_daily_attempt_budget_exceeded")
        : String(outcome.reason);
    out["attempts"] = static_cast<int>(attempts);
    out["peer_pumped"] = static_cast<int64_t>(peer_pumped);
    out["from_day"] = outcome.from_day;
    out["day"] = outcome.day;
    out["environment_day"] = outcome.environment_day;
    out["committed_day"] = report.committed_day;
    out["completed_domain_mask"] =
        static_cast<int64_t>(outcome.completed_domain_mask);
    out["completed_stage_count"] = static_cast<int>(outcome.completed_stage_count);
    out["stage_count"] = static_cast<int>(outcome.stage_count);
    out["work_units"] = static_cast<int64_t>(outcome.work_units);
    out["dirty_families"] = static_cast<int64_t>(outcome.dirty_families);
    out["preflight_ok"] = outcome.committed;
    out["continuation_pending"] = outcome.continuation_pending;
    out["elapsed_ms"] = elapsed_ms;
    // ===== 分域/分阶段耗时（新键，既有键语义完全不变）=====
    //
    // stage_ms：12 域各自累加的毫秒数（键名见 runtime_domain_stage_key）。
    //   stage_ms["climate"] 是 Climate 内核的真实耗时 —— 内核在 12 域循环之前
    //   就跑完，所以它同时是 pre_stage_ms 的一部分。
    // attempt_ms：每次尝试的总毫秒（重试会把同一域再付一次）。
    // peer_ms：Country peer 泵的总毫秒（重试之间在调用线程上跑）。
    // plan_build_ms / commit_tail_ms：build_day_plan / 日尾发布各自的毫秒。
    // budget_exceeded：是否被单日墙钟看门狗掐断（此时 ok=false）。
    // executor_serial_only：本线程是否已把 pk::parallel_for_range 的固定线程池
    //   切成串行（内联日必须为 true，否则浏览器主线程会等一组 wasm pthread）。
    {
        Dictionary stage_dict;
        constexpr auto order = runtime_domain_stage_order();
        for (uint32_t i = 0; i < RUNTIME_DOMAIN_STAGE_COUNT; ++i)
            stage_dict[runtime_domain_stage_key(order[i])] = stage_ms[i];
        out["stage_ms"] = stage_dict;
    }
    out["attempt_ms"] = attempt_ms;
    out["pre_stage_ms"] = pre_stage_ms;
    out["climate_ms"] = climate_ms;
    out["plan_build_ms"] = plan_build_ms;
    out["commit_tail_ms"] = commit_tail_ms;
    out["peer_ms"] = peer_ms;
    // capture_ms：紧接本次调用之前的 capture_runtime_inputs() 花了多少毫秒。
    // 调用方那一帧 = capture_ms + elapsed_ms + 其余 GDScript；三者一比就能
    // 判定浏览器里那 24 秒到底在 C++ 日屏障里还是在捕获/应用侧。
    out["capture_ms"] = _inline_capture_ms;
    out["budget_exceeded"] = budget_exceeded;
    out["budget_ms"] = total_budget_us > 0
        ? static_cast<double>(total_budget_us) / 1000.0 : 0.0;
    out["executor_serial_only"] = parallel_serial_only();
    // 执行器账目：内联日必须"一次真并行 group 都不派"。调用方拿两个累计量的
    // 差值就能验证 —— dispatch 只涨 serial_dispatch 时，浏览器主线程这一帧
    // 从头到尾没碰过 wasm pthread，也就不会在 group barrier 上等一个起不来的
    // worker。
    {
        const NativeParallelExecutor::Report executor =
            NativeParallelExecutor::instance().report();
        out["executor_workers"] = static_cast<int>(executor.worker_threads);
        out["executor_dispatch"] =
            static_cast<int64_t>(executor.dispatch_count);
        out["executor_serial_dispatch"] =
            static_cast<int64_t>(executor.serial_dispatch_count);
        out["executor_tasks"] = static_cast<int64_t>(executor.task_count);
    }
    out["inline_daily"] = true;
    out["simulation_thread_mode"] = runtime_mode_name(report.mode);
    out["simulation_host_state"] = runtime_state_name(report.state);
    out["authoritative_domain_mask"] =
        static_cast<int64_t>(report.authoritative_domain_mask);
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

std::FILE *pk_sim_trace_file();

void DCWorldExt::sim_trace_main_write(const char *tag) {
    std::FILE *trace = pk_sim_trace_file();
    if (trace == nullptr || !_bound) return;
    auto hash_slot = [&](const char *name) -> unsigned long long {
        const int sid = component_id(StringName(name));
        if (sid < 0 || sid >= _slots.size()) return 0ull;
        const Slot &slot = _slots[sid];
        uint64_t hash = 1469598103934665603ull;
        const uint8_t *bytes = nullptr;
        size_t size = 0;
        if (slot.dtype == SlotDType::F32) {
            bytes = reinterpret_cast<const uint8_t *>(slot.arr_f32.ptr());
            size = static_cast<size_t>(slot.arr_f32.size()) * sizeof(float);
        } else if (slot.dtype == SlotDType::U8) {
            bytes = slot.arr_u8.ptr();
            size = static_cast<size_t>(slot.arr_u8.size());
        }
        for (size_t i = 0; i < size; ++i) hash = (hash ^ bytes[i]) * 1099511628211ull;
        return static_cast<unsigned long long>(hash ^ size);
    };
    const long long committed = _runtime_host != nullptr
        ? static_cast<long long>(_runtime_host->report().committed_day) : -1;
    std::fprintf(trace,
        "[main-write] fn=%s committed=%lld base=%llu soil=%llu moist=%llu temp=%llu "
        "wtype=%llu wint=%llu veg=%llu tta=%llu\n",
        tag, committed, hash_slot("cell_base_moisture"), hash_slot("cell_soil_moisture"),
        hash_slot("cell_moisture"), hash_slot("cell_temp"), hash_slot("cell_weather_type"),
        hash_slot("cell_weather_intensity"), hash_slot("cell_vegetation"),
        hash_slot("cell_temperature_transport_anomaly"));
    std::fflush(trace);
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




Dictionary DCWorldExt::request_runtime_stop() {
    _climate_physics_committed.reset();
    _climate_physics_capture_ready = false;
    _climate_writeback_applied_generation = 0;
    _climate_writeback_applied_day = -1;
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = true;
        out["pending"] = false;
        out["state"] = "STOPPED";
        return out;
    }
    const RuntimeWorkerState before = _runtime_host->state();
    // Stop is asynchronous: the worker may still be executing an Economy
    // stage or its command executor. Keep both attached until it has exited;
    // DCWorldExt joins the host before destroying the owned runtimes.
    _runtime_host->request_stop();
    out["ok"] = true;
    const RuntimeWorkerState state = _runtime_host->state();
    // The request itself is asynchronous even if the worker exits during this
    // call.  Callers use pending to schedule a later lifecycle poll, while the
    // state field is allowed to already be STOPPED.
    out["pending"] = before != RuntimeWorkerState::STOPPED ||
        !_runtime_host->execution_has_stopped();
    out["state"] = runtime_state_name(state);
    return out;
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
    out["economy_authority_switch_audit_hash"] = static_cast<int64_t>(
        audit.economy_authority_switch_audit_hash);
    // Compact aliases matching the M6 switch evidence contract.
    out["before_hash"] = out["economy_authority_switch_before_hash"];
    out["after_hash"] = out["economy_authority_switch_after_hash"];
    out["audit_hash"] = out["economy_authority_switch_audit_hash"];
    out["generation"] = out["economy_authority_switch_after_generation"];
    out["latency_us"] = out["economy_authority_switch_latency_us"];
    return out;
}

} // namespace pk
