#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

RuntimeThreadReport NativeSimulationHost::report() const {
    RuntimeThreadReport out;
    const ControlState control = control_state();
    out.worker_time_us = _worker_timing.snapshot();
    out.state = control.state;
    out.mode = control.mode;
    out.inline_daily = _inline_daily_mode.load(std::memory_order_acquire);
    out.graph_coverage_complete = _graph_coverage_complete.load(std::memory_order_acquire);
    out.authority_ready = control.authority_ready;
    out.required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    out.implemented_domain_mask = implemented_domain_mask();
    out.missing_domain_mask = out.required_domain_mask & ~out.implemented_domain_mask;
    out.completion_gate_missing_domain_mask = _completion_gate_missing_domain_mask.load(std::memory_order_acquire);
    out.active_gate_blocked = _active_gate_blocked.load(std::memory_order_acquire);
    out.requested_authority_mask =
        _requested_authority_mask.load(std::memory_order_acquire);
    out.authoritative_domain_mask = control.authoritative_domain_mask;
    out.active_evidence_mask =
        _active_evidence_mask.load(std::memory_order_acquire);
    const char *coverage = out.authority_ready ? "complete" : "partial";
    size_t coverage_index = 0;
    for (; coverage_index + 1 < sizeof(out.graph_coverage_state) &&
            coverage[coverage_index] != '\0'; ++coverage_index) {
        out.graph_coverage_state[coverage_index] = coverage[coverage_index];
    }
    out.graph_coverage_state[coverage_index] = '\0';
    const char *blocker = out.authority_ready ? "" :
        (out.missing_domain_mask != 0 ? "missing_native_domain_handlers" :
            "runtime_graph_not_ready");
    size_t blocker_index = 0;
    for (; blocker_index + 1 < sizeof(out.coverage_blocker) &&
            blocker[blocker_index] != '\0'; ++blocker_index) {
        out.coverage_blocker[blocker_index] = blocker[blocker_index];
    }
    out.coverage_blocker[blocker_index] = '\0';
    out.interactive = control.interactive;
    out.paused = _paused.load(std::memory_order_acquire);
    out.speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    out.committed_day = control.committed_day;
    out.generation = _generation.load(std::memory_order_acquire);
    out.command_queue_capacity_exceeded = _command_queue_capacity_exceeded.load(std::memory_order_relaxed);
    out.receipt_queue_capacity_exceeded = _receipt_queue_capacity_exceeded.load(std::memory_order_relaxed);
    out.input_capture_count = _input_capture_count.load(std::memory_order_acquire);
    out.input_capture_reused = _input_capture_reused.load(std::memory_order_acquire);
    out.input_capture_generation = _input_capture_generation.load(std::memory_order_acquire);
    out.input_capture_day = _input_capture_day.load(std::memory_order_acquire);
    out.input_capture_hash = _input_capture_hash.load(std::memory_order_acquire);
    out.gameplay_effect_generation = _gameplay_effect_generation.load(std::memory_order_acquire);
    out.gameplay_effect_pending = _gameplay_effect_pending.load(std::memory_order_acquire);
    out.gameplay_effect_terminal = _gameplay_effect_terminal.load(std::memory_order_acquire);
    out.gameplay_effect_state_hash = _gameplay_effect_state_hash.load(std::memory_order_acquire);
    out.visual_intent_generation = _visual_intent_generation.load(std::memory_order_acquire);
    out.visual_intent_count = _visual_intent_count.load(std::memory_order_acquire);
    out.visual_full_refresh = _visual_full_refresh.load(std::memory_order_acquire);
    out.snapshot_publish_drop_count = _snapshots.publish_drop_count();
    out.snapshot_publish_throttled_count =
        _snapshot_publish_throttled_count.load(std::memory_order_relaxed);
    out.worker_fault_count = _worker_fault_count.load(std::memory_order_relaxed);
    out.completed_days = _completed_days.load(std::memory_order_relaxed);
    out.day_stage_count = _last_day_stage_count.load(std::memory_order_acquire);
    out.day_completed_stage_count = _last_day_completed_stages.load(
        std::memory_order_acquire);
    out.day_work_units = _last_day_work_units.load(std::memory_order_acquire);
    out.pod_completed_domain_mask = _pod_completed_domain_mask.load(std::memory_order_acquire);
    out.pod_completed_stage_count = _pod_completed_stage_count.load(std::memory_order_acquire);
    out.pod_work_units = _pod_work_units.load(std::memory_order_acquire);
    out.pod_intent_count = _pod_intent_count.load(std::memory_order_acquire);
    out.pod_fallback_count = _pod_fallback_count.load(std::memory_order_acquire);
    out.economy_pod_ready = _economy_pod_ready.load(std::memory_order_acquire);
    out.economy_pod_committed = _economy_pod_committed.load(std::memory_order_acquire);
    out.economy_pod_authority_ready = _economy_pod_authority_ready.load(std::memory_order_acquire);
    out.economy_pod_committed_day = _economy_pod_committed_day.load(std::memory_order_acquire);
    out.economy_pod_epoch_sample_day = _economy_pod_epoch_sample_day.load(std::memory_order_acquire);
    out.economy_pod_generation = _economy_pod_generation.load(std::memory_order_acquire);
    out.economy_pod_state_hash = _economy_pod_state_hash.load(std::memory_order_acquire);
    out.economy_pod_input_generation = _economy_pod_input_generation.load(std::memory_order_acquire);
    out.economy_pod_country_generation = _economy_pod_country_generation.load(std::memory_order_acquire);
    out.economy_pod_completed_stage_mask = _economy_pod_completed_stage_mask.load(std::memory_order_acquire);
    out.economy_pod_pending_outbox = _economy_pod_pending_outbox.load(std::memory_order_acquire);
    out.economy_pod_pending_inbox = _economy_pod_pending_inbox.load(std::memory_order_acquire);
    out.economy_pod_operation_gate_mask = _economy_pod_operation_gate_mask.load(std::memory_order_acquire);
    out.economy_pod_parity_ready_mask = _economy_pod_parity_ready_mask.load(std::memory_order_acquire);
    out.economy_pod_mirror_feature_mask = _economy_pod_authority.mirror_feature_mask();
    out.economy_pod_committed_ledger_abi =
        _economy_pod_authority.committed_ledger_abi();
    out.economy_pod_active_ready = _economy_pod_authority.pod_active_ready();
    out.economy_authority_switch_count = _economy_authority_switch_count.load(std::memory_order_acquire);
    out.economy_authority_switch_before_hash = _economy_authority_switch_before_hash.load(std::memory_order_acquire);
    out.economy_authority_switch_after_hash = _economy_authority_switch_after_hash.load(std::memory_order_acquire);
    out.economy_authority_switch_latency_us = _economy_authority_switch_latency_us.load(std::memory_order_acquire);
    out.economy_authority_switch_latency_p95_us =
        _economy_authority_switch_latency_p95_us.load(std::memory_order_acquire);
    out.economy_authority_switch_latency_max_us =
        _economy_authority_switch_latency_max_us.load(std::memory_order_acquire);
    out.economy_authority_switch_command_latency_us =
        _economy_authority_switch_command_latency_us.load(std::memory_order_acquire);
    out.economy_authority_switch_command_latency_p95_us =
        _economy_authority_switch_command_latency_p95_us.load(
            std::memory_order_acquire);
    out.economy_authority_switch_command_latency_max_us =
        _economy_authority_switch_command_latency_max_us.load(
            std::memory_order_acquire);
    out.economy_authority_switch_latency_sample_count =
        _economy_authority_switch_latency_sample_count.load(
            std::memory_order_acquire);
    // Derive bounded p95/max from the ring at report time. A concurrent switch
    // may add one newer sample after the cursor is read; that sample appears in
    // the next report and cannot corrupt the current aggregate.
    {
        const uint64_t write_cursor =
            _economy_authority_switch_latency_sample_write.load(
                std::memory_order_acquire);
        const uint64_t sample_count = std::min<uint64_t>(
            write_cursor, ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY);
        if (sample_count != 0u) {
            std::vector<uint64_t> switch_samples;
            std::vector<uint64_t> command_samples;
            switch_samples.reserve(static_cast<size_t>(sample_count));
            command_samples.reserve(static_cast<size_t>(sample_count));
            const uint64_t first = write_cursor - sample_count;
            for (uint64_t sequence = first; sequence < write_cursor;
                 ++sequence) {
                const size_t slot = static_cast<size_t>(
                    sequence % ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY);
                switch_samples.push_back(
                    _economy_authority_switch_latency_samples[slot].load(
                        std::memory_order_relaxed));
                command_samples.push_back(
                    _economy_authority_switch_command_latency_samples[slot].load(
                        std::memory_order_relaxed));
            }
            std::sort(switch_samples.begin(), switch_samples.end());
            std::sort(command_samples.begin(), command_samples.end());
            const size_t p95_index = static_cast<size_t>(
                (sample_count * 95u + 99u) / 100u - 1u);
            out.economy_authority_switch_latency_p95_us =
                switch_samples[std::min(p95_index, switch_samples.size() - 1u)];
            out.economy_authority_switch_latency_max_us =
                switch_samples.back();
            out.economy_authority_switch_command_latency_p95_us =
                command_samples[std::min(p95_index, command_samples.size() - 1u)];
            out.economy_authority_switch_command_latency_max_us =
                command_samples.back();
            out.economy_authority_switch_latency_sample_count = sample_count;
        }
    }
    out.economy_authority_switch_rejected = _economy_authority_switch_rejected.load(std::memory_order_acquire);
    out.economy_authority_switch_audit_sequence =
        _economy_authority_switch_audit_sequence.load(std::memory_order_acquire);
    out.economy_authority_switch_audit_hash =
        _economy_authority_switch_audit_hash.load(std::memory_order_acquire);
    out.economy_authority_switch_before_generation = _economy_authority_switch_before_generation.load(std::memory_order_acquire);
    out.economy_authority_switch_after_generation = _economy_authority_switch_after_generation.load(std::memory_order_acquire);
    out.economy_authority_fault_paused = _economy_authority_fault_paused.load(std::memory_order_acquire);
    out.economy_authority_last_committed_generation = _economy_authority_last_committed_generation.load(std::memory_order_acquire);
    out.economy_authority_last_committed_hash = _economy_authority_last_committed_hash.load(std::memory_order_acquire);
    out.economy_inflight_mutations =
        _economy_inflight_mutations.load(std::memory_order_acquire);
    out.worker_day_inflight =
        _worker_day_inflight.load(std::memory_order_acquire);
    out.economy_pending_command_count =
        _economy_pending_command_count.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.economy_authority_switch_reason); ++i) {
        out.economy_authority_switch_reason[i] = _economy_authority_switch_reason[i].load(std::memory_order_relaxed);
        out.economy_authority_switch_blocker[i] = _economy_authority_switch_blocker[i].load(std::memory_order_relaxed);
    }
    out.economy_authority_switch_reason[sizeof(out.economy_authority_switch_reason) - 1] = '\0';
    out.economy_authority_switch_blocker[sizeof(out.economy_authority_switch_blocker) - 1] = '\0';
    for (size_t i = 0; i + 1 < sizeof(out.economy_authority_switch_audit_before); ++i) {
        out.economy_authority_switch_audit_before[i] = _economy_authority_switch_audit_before[i].load(std::memory_order_relaxed);
        out.economy_authority_switch_audit_after[i] = _economy_authority_switch_audit_after[i].load(std::memory_order_relaxed);
    }
    out.economy_authority_switch_audit_before[sizeof(out.economy_authority_switch_audit_before) - 1] = '\0';
    out.economy_authority_switch_audit_after[sizeof(out.economy_authority_switch_audit_after) - 1] = '\0';
    out.economy_execution_mode =
        _economy_execution_mode.load(std::memory_order_acquire);
    out.economy_shadow_probe_enabled =
        _economy_shadow_probe_enabled.load(std::memory_order_acquire);
    out.economy_shadow_stage_invocations =
        _economy_shadow_stage_invocations.load(std::memory_order_acquire);
    out.economy_shadow_stage_cache_hits =
        _economy_shadow_stage_cache_hits.load(std::memory_order_acquire);
    out.economy_stage_ops_mutate =
        _economy_stage_ops_mutate.load(std::memory_order_acquire);
    out.economy_auto_pod_active =
        _economy_auto_pod_active.load(std::memory_order_acquire);
    out.economy_pod_command_recapture_count =
        _economy_pod_command_recapture_count.load(std::memory_order_acquire);
    out.economy_pod_command_verify_count =
        _economy_pod_command_verify_count.load(std::memory_order_acquire);
    {
        const char *backing = "ner_local";
        if (_economy_production_runtime != nullptr)
            backing = _economy_production_runtime->formula_backing_tag();
        std::snprintf(out.economy_formula_backing,
                      sizeof(out.economy_formula_backing), "%s", backing);
    }
    {
        const EconomyProductionWriter requested =
            economy_production_writer_requested();
        const EconomyProductionWriter effective =
            economy_production_writer_effective();
        std::snprintf(out.economy_production_writer,
                      sizeof(out.economy_production_writer), "%s",
                      economy_production_writer_name(effective));
        std::snprintf(out.economy_production_writer_requested,
                      sizeof(out.economy_production_writer_requested), "%s",
                      economy_production_writer_name(requested));
        std::snprintf(out.economy_production_writer_effective,
                      sizeof(out.economy_production_writer_effective), "%s",
                      economy_production_writer_name(effective));
    }
    // Phase-2.4.4.3: PRELUDE|COMMIT_DRAINS|BOUNDED_KERNELS|HOST_LOOP = 0xF.
    // Production writer still refused for soak gate (see start_runtime_worker).
    out.economy_stage_ops_readiness_mask =
        ECONOMY_STAGE_OPS_READY_PRELUDE | ECONOMY_STAGE_OPS_READY_COMMIT_DRAINS |
        ECONOMY_STAGE_OPS_READY_BOUNDED_KERNELS |
        ECONOMY_STAGE_OPS_READY_HOST_LOOP;
    out.economy_stage_ops_prelude_ready =
        _economy_production_runtime != nullptr &&
        _economy_production_runtime->stage_ops_epoch_open_ready();
    out.economy_stage_ops_soak_experiment =
        _economy_stage_ops_soak_experiment.load(std::memory_order_acquire);
    out.economy_stage_ops_soak_parity_ok =
        _economy_stage_ops_soak_parity_ok.load(std::memory_order_acquire);
    out.economy_replay_completed_stage_mask = _economy_replay_completed_stage_mask.load(std::memory_order_acquire);
    out.economy_replay_stage_cursor = _economy_replay_stage_cursor.load(std::memory_order_acquire);
    out.economy_replay_input_hash = _economy_replay_input_hash.load(std::memory_order_acquire);
    out.economy_replay_base_hash = _economy_replay_base_hash.load(std::memory_order_acquire);
    out.economy_replay_next_hash = _economy_replay_next_hash.load(std::memory_order_acquire);
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        out.economy_replay_stage_hash[i] = _economy_replay_stage_hash[i].load(std::memory_order_acquire);
        out.economy_replay_stage_work[i] = _economy_replay_stage_work[i].load(std::memory_order_acquire);
        out.economy_replay_stage_ms[i] = _economy_replay_stage_ms[i].load(std::memory_order_acquire);
    }
    out.economy_replay_input_captured = _economy_replay_input_captured.load(std::memory_order_acquire);
    out.economy_replay_committed = _economy_replay_committed.load(std::memory_order_acquire);
    out.economy_replay_parity_ready = _economy_replay_parity_ready.load(std::memory_order_acquire);
    for (size_t i = 0; i < _economy_replay_fallback_reason.size(); ++i) {
        out.economy_replay_fallback_reason[i] = _economy_replay_fallback_reason[i].load(std::memory_order_acquire);
        if (out.economy_replay_fallback_reason[i] == '\0') break;
    }
    out.domain_authority_planned_mask =
        _domain_authority_planned_mask.load(std::memory_order_acquire);
    out.domain_authority_committed_mask =
        _domain_authority_committed_mask.load(std::memory_order_acquire);
    out.domain_authority_ack_count =
        _domain_authority_ack_count.load(std::memory_order_acquire);
    out.domain_authority_input_hash =
        _domain_authority_input_hash.load(std::memory_order_acquire);
    out.domain_authority_state_hash =
        _domain_authority_state_hash.load(std::memory_order_acquire);
    out.domain_authority_plan_ms =
        _domain_authority_plan_ms.load(std::memory_order_acquire);
    out.domain_authority_replay_ms =
        _domain_authority_replay_ms.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.domain_authority_fallback_reason); ++i) {
        const char value = _domain_authority_fallback_reason[i].load(
            std::memory_order_acquire);
        out.domain_authority_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.domain_authority_fallback_reason[
        sizeof(out.domain_authority_fallback_reason) - 1] = '\0';
    out.domain_stage_fallback_count = _domain_stage_fallback_count.load(
        std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.domain_stage_fallback_reason); ++i) {
        const char value = _domain_stage_fallback_reason[i].load(
            std::memory_order_acquire);
        out.domain_stage_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.domain_stage_fallback_reason[
        sizeof(out.domain_stage_fallback_reason) - 1] = '\0';
    out.climate_pod_ready = _climate_pod_ready.load(std::memory_order_acquire);
    out.climate_pod_plan_ms = _climate_pod_plan_ms.load(std::memory_order_acquire);
    out.climate_pod_replay_ms = _climate_pod_replay_ms.load(std::memory_order_acquire);
    out.climate_pod_work_units = _climate_pod_work_units.load(std::memory_order_acquire);
    out.climate_pod_changed_cells = _climate_pod_changed_cells.load(std::memory_order_acquire);
    for (size_t i = 0; i < out.climate_stage_ms.size(); ++i) {
        out.climate_stage_ms[i] = _climate_stage_ms[i].load(std::memory_order_relaxed);
        out.climate_stage_work[i] = _climate_stage_work[i].load(std::memory_order_relaxed);
    }
    out.climate_pod_state_hash = _climate_pod_state_hash.load(std::memory_order_acquire);
    out.climate_pod_reference_hash = _climate_pod_reference_hash.load(std::memory_order_acquire);
    out.climate_pod_parity_compared = _climate_pod_parity_compared.load(std::memory_order_acquire);
    out.climate_pod_parity_matched = _climate_pod_parity_matched.load(std::memory_order_acquire);
    out.climate_pod_parity_mismatch_count = _climate_pod_parity_mismatch_count.load(std::memory_order_acquire);
    out.climate_parity_day = _climate_parity_day.load(std::memory_order_acquire);
    out.climate_parity_stage = _climate_parity_stage.load(std::memory_order_acquire);
    out.climate_parity_cell = _climate_parity_cell.load(std::memory_order_acquire);
    out.climate_parity_input_generation = _climate_parity_input_generation.load(std::memory_order_acquire);
    out.climate_parity_base_generation = _climate_parity_base_generation.load(std::memory_order_acquire);
    out.climate_parity_trace_hash = _climate_parity_trace_hash.load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_parity_field.size(); ++i) out.climate_parity_field[i] = _climate_parity_field[i].load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_parity_reference_bits.size(); ++i) out.climate_parity_reference_bits[i] = _climate_parity_reference_bits[i].load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_parity_worker_bits.size(); ++i) out.climate_parity_worker_bits[i] = _climate_parity_worker_bits[i].load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
        out.climate_pod_parity_reason[i] =
            _climate_pod_parity_reason[i].load(std::memory_order_acquire);
        if (out.climate_pod_parity_reason[i] == '\0') break;
    }
    for (size_t i = 0; i + 1 < sizeof(out.climate_pod_fallback_reason); ++i) {
        const char value = _climate_pod_fallback_reason[i].load(std::memory_order_acquire);
        out.climate_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.climate_pod_fallback_reason[sizeof(out.climate_pod_fallback_reason) - 1] = '\0';
    out.climate_production_stage_mask =
        _climate_production_stage_mask.load(std::memory_order_acquire);
    out.climate_worker_stage_mask =
        _climate_worker_stage_mask.load(std::memory_order_acquire);
    // B8-2：worker 自持 cyclone 的当日事实（只用于报告，不参与仿真）。
    out.climate_cyclone_alive =
        _climate_cyclone_alive.load(std::memory_order_relaxed);
    out.climate_cyclone_injected =
        _climate_cyclone_injected.load(std::memory_order_relaxed);
    out.climate_cyclone_replaced =
        _climate_cyclone_replaced.load(std::memory_order_relaxed);
    out.climate_cyclone_decayed =
        _climate_cyclone_decayed.load(std::memory_order_relaxed);
    out.climate_cyclone_touched =
        _climate_cyclone_touched.load(std::memory_order_relaxed);
    // B8 P0：交付游标。诊断表允许 relaxed 读；这些计数只用于报告与等待判定，
    // 不参与任何仿真状态。
    out.climate_committed_day =
        _climate_committed_day.load(std::memory_order_acquire);
    out.climate_consumed_generation =
        _climate_consumed_generation.load(std::memory_order_acquire);
    out.environment_published_days =
        _environment_published_days.load(std::memory_order_relaxed);
    out.environment_consumed_days =
        _environment_consumed_days.load(std::memory_order_relaxed);
    out.environment_superseded_days =
        _environment_superseded_days.load(std::memory_order_relaxed);
    out.environment_dropped_days =
        _environment_dropped_days.load(std::memory_order_relaxed);
    out.environment_ring_pending =
        static_cast<uint64_t>(_environment_ring.size());
    out.day_stall_reason_mask = day_stall_reason_mask();
    out.day_stall_day = _day_stall_day.load(std::memory_order_acquire);
    out.day_wait_day = _day_wait_day.load(std::memory_order_acquire);
    out.day_wait_missing_mask = _day_wait_missing_mask.load(std::memory_order_acquire);
    out.day_wait_env_day = _day_wait_env_day.load(std::memory_order_acquire);
    out.day_wait_ring = _day_wait_ring.load(std::memory_order_acquire);
    out.country_peer_resolved_in_worker =
        _country_peer_resolved_in_worker.load(std::memory_order_acquire);
    out.country_peer_resolved_by_main =
        _country_peer_resolved_by_main.load(std::memory_order_acquire);
    out.country_deferred_peer_count =
        _country_deferred_peer_count.load(std::memory_order_acquire);
    out.day_park_domain_mask = _day_park_domain_mask.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.day_park_reason); ++i) {
        out.day_park_reason[i] = _day_park_reason[i].load(std::memory_order_acquire);
    }
    out.day_park_reason[sizeof(out.day_park_reason) - 1] = '\0';
    out.effect_instance_rejected_count =
        _effect_instance_rejected_count.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.effect_instance_reject_detail); ++i) {
        out.effect_instance_reject_detail[i] =
            _effect_instance_reject_detail[i].load(std::memory_order_acquire);
    }
    out.effect_instance_reject_detail[
        sizeof(out.effect_instance_reject_detail) - 1] = '\0';
    {
        const uint64_t since =
            _day_stall_peer_since_us.load(std::memory_order_acquire);
        out.day_stall_peer_ms =
            since == 0u ? 0u : (now_us() - since) / 1000u;
    }
    out.climate_wait_total_ms =
        _climate_wait_total_ms.load(std::memory_order_relaxed);
    out.climate_wait_last_ms =
        _climate_wait_last_ms.load(std::memory_order_relaxed);
    out.climate_wait_max_ms =
        _climate_wait_max_ms.load(std::memory_order_relaxed);
    const uint64_t command_write = _command_enqueue_pos.load(std::memory_order_acquire);
    const uint64_t command_read = _command_dequeue_pos.load(std::memory_order_acquire);
    const uint64_t receipt_write = _receipt_write.load(std::memory_order_acquire);
    const uint64_t receipt_read = _receipt_read.load(std::memory_order_acquire);
    out.command_queue_depth = static_cast<uint32_t>(std::min<uint64_t>(
        command_write - command_read, RUNTIME_COMMAND_QUEUE_CAPACITY));
    out.receipt_queue_depth = static_cast<uint32_t>(std::min<uint64_t>(
        receipt_write - receipt_read, RUNTIME_RECEIPT_QUEUE_CAPACITY));
    out.time_debt_days = _time_debt_days.load(std::memory_order_relaxed);
    out.climate_trace_depth = _climate_trace.depth();
    int64_t trace_front_day = -1;
    if (_climate_trace.front_day(trace_front_day)) {
        out.climate_trace_front_day = trace_front_day;
        const int64_t committed = out.committed_day;
        out.climate_trace_lag_days = committed >= trace_front_day
            ? committed - trace_front_day : 0;
    }
    out.climate_trace_latest_hash = _climate_trace_latest_hash.load(
        std::memory_order_acquire);
    out.climate_trace_capacity_exceeded = _climate_trace.capacity_exceeded();
    out.climate_trace_consumed = _climate_trace_consumed.load(std::memory_order_acquire);
    out.climate_trace_missing = _climate_trace_missing.load(std::memory_order_acquire);
    out.climate_trace_captured = _climate_trace.captured_depth();
    out.climate_trace_reference_ready = _climate_trace.reference_ready_depth();
    out.climate_trace_consumable = _climate_trace.consumable_depth();
    out.climate_trace_reference_rejected = _climate_trace.reference_rejected();
    out.climate_trace_reference_pending = _climate_trace.reference_pending();
    out.state_hash = _state_hash.load(std::memory_order_acquire);
    out.last_commit_produced_at_us = _last_commit_produced_at_us.load(
        std::memory_order_acquire);
    out.last_visual_publish_at_us = _last_visual_publish_us.load(
        std::memory_order_acquire);
    if (out.last_visual_publish_at_us != 0) {
        const uint64_t now = now_us();
        out.snapshot_staleness_ms = now >= out.last_visual_publish_at_us
            ? static_cast<double>(now - out.last_visual_publish_at_us) / 1000.0
            : 0.0;
    }
    out.ui_input_to_feedback_ms = _ui_input_to_feedback_ms.load(
        std::memory_order_acquire);
    out.visual_apply_ms = _visual_apply_ms.load(std::memory_order_acquire);
    out.gpu_upload_ms = _gpu_upload_ms.load(std::memory_order_acquire);
    out.main_wait_on_sim_us = 0;
    out.executor_workers = NativeParallelExecutor::instance().report().active_worker_limit;
    const RuntimeCountryPodDiagnostics country_diag = country_pod_diagnostics();
    out.country_pod_snapshot_generation = country_diag.snapshot_generation;
    out.country_pod_state_hash = country_diag.state_hash;
    out.country_pod_work_units = country_diag.work_units;
    out.country_pod_active_country_count = country_diag.active_country_count;
    out.country_pod_active_index_count = country_diag.active_index_count;
    out.country_pod_pending_checks = country_diag.pending_checks;
    out.country_pod_ack_pending = country_diag.ack_pending != 0;
    runtime_copy_text(out.country_pod_blocker, country_diag.blocker);
    const CountryWorkerProtocolStatus country_worker =
        country_worker_protocol_status();
    out.country_worker_configured = country_worker.configured;
    out.country_worker_plan_active = country_worker.plan_active;
    out.country_worker_waiting_for_peer = country_worker.waiting_for_peer;
    out.country_worker_pending_intents = country_worker.pending_intents;
    out.country_worker_queued_intents = country_worker.queued_intents;
    out.country_worker_result_count = country_worker.result_count;
    out.country_worker_rejected_results = country_worker.rejected_results;
    out.country_worker_session_epoch = country_worker.session_epoch;
    out.country_worker_country_generation = country_worker.country_generation;
    out.country_worker_day = country_worker.day;
    out.country_worker_continuation_index = country_worker.continuation_index;
    out.country_worker_boundary_id = country_worker.boundary_id;
    out.country_worker_last_admitted_submit_order =
        country_worker.last_admitted_submit_order;
    out.country_worker_expected_base_generation =
        country_worker.expected_base_generation;
    out.country_worker_catalog_hash = country_worker.catalog_hash;
    out.country_worker_authoritative =
        (out.authoritative_domain_mask & runtime_domain_mask(
            RuntimeDomainId::COUNTRY)) != 0u;
    runtime_copy_text(out.country_worker_last_reason,
                      country_worker.last_reason);
    out.country_parity_compared = _country_parity_compared.load(
        std::memory_order_acquire);
    out.country_parity_matched = _country_parity_matched.load(
        std::memory_order_acquire);
    out.country_parity_compared_count = _country_parity_compared_count.load(
        std::memory_order_acquire);
    out.country_parity_matched_count = _country_parity_matched_count.load(
        std::memory_order_acquire);
    out.country_parity_first_mismatch_day = _country_parity_first_mismatch_day.load(
        std::memory_order_acquire);
    out.country_parity_reference_hash = _country_parity_reference_hash.load(
        std::memory_order_acquire);
    out.country_parity_worker_hash = _country_parity_worker_hash.load(
        std::memory_order_acquire);
    out.country_parity_index = _country_parity_index.load(
        std::memory_order_acquire);
    load_atomic_chars(_country_parity_status, out.country_parity_status,
                      sizeof(out.country_parity_status));
    load_atomic_chars48(_country_parity_field, out.country_parity_field,
                        sizeof(out.country_parity_field));
    const IdeologyParityReport ideology_parity = ideology_parity_report();
    out.ideology_parity_compared = ideology_parity.compared;
    out.ideology_parity_matched = ideology_parity.matched;
    out.ideology_parity_compared_count = ideology_parity.compared_count;
    out.ideology_parity_matched_count = ideology_parity.matched_count;
    out.ideology_parity_reference_hash = ideology_parity.reference_hash;
    out.ideology_parity_worker_hash = ideology_parity.worker_hash;
    out.ideology_parity_first_mismatch_day = ideology_parity.first_mismatch_day;
    out.ideology_parity_uncompared_day_offset =
        ideology_parity.uncompared_day_offset;
    std::memcpy(out.ideology_parity_field, ideology_parity.field,
                sizeof(out.ideology_parity_field));
    if (ideology_parity.points_diff_valid) {
        out.ideology_parity_points_diff_valid = true;
        out.ideology_parity_points_diff_day = ideology_parity.points_diff_day;
        out.ideology_parity_points_diff_slot = ideology_parity.points_diff_slot;
        out.ideology_parity_points_diff_reference_countries =
            ideology_parity.points_diff_reference_countries;
        out.ideology_parity_points_diff_worker_countries =
            ideology_parity.points_diff_worker_countries;
        out.ideology_parity_points_diff_handle = ideology_parity.points_diff_handle;
        out.ideology_parity_points_diff_reference_handle =
            ideology_parity.points_diff_reference_handle;
        out.ideology_parity_points_diff_worker_handle =
            ideology_parity.points_diff_worker_handle;
        out.ideology_parity_points_diff_reference_points_q16 =
            ideology_parity.points_diff_reference_points_q16;
        out.ideology_parity_points_diff_worker_points_q16 =
            ideology_parity.points_diff_worker_points_q16;
        out.ideology_parity_points_diff_reference_lifetime_q16 =
            ideology_parity.points_diff_reference_lifetime_q16;
        out.ideology_parity_points_diff_worker_lifetime_q16 =
            ideology_parity.points_diff_worker_lifetime_q16;
        out.ideology_parity_points_diff_reference_revision =
            ideology_parity.points_diff_reference_revision;
        out.ideology_parity_points_diff_worker_revision =
            ideology_parity.points_diff_worker_revision;
        out.ideology_parity_points_diff_reference_baseline_ready =
            ideology_parity.points_diff_reference_baseline_ready;
        out.ideology_parity_points_diff_worker_baseline_ready =
            ideology_parity.points_diff_worker_baseline_ready;
        out.ideology_parity_points_diff_reference_baseline_population =
            ideology_parity.points_diff_reference_baseline_population;
        out.ideology_parity_points_diff_worker_baseline_population =
            ideology_parity.points_diff_worker_baseline_population;
        out.ideology_parity_points_diff_reference_baseline_buildings =
            ideology_parity.points_diff_reference_baseline_buildings;
        out.ideology_parity_points_diff_worker_baseline_buildings =
            ideology_parity.points_diff_worker_baseline_buildings;
        out.ideology_parity_points_diff_reference_history_count =
            ideology_parity.points_diff_reference_history_count;
        out.ideology_parity_points_diff_worker_history_count =
            ideology_parity.points_diff_worker_history_count;
        out.ideology_parity_points_diff_reference_history_head =
            ideology_parity.points_diff_reference_history_head;
        out.ideology_parity_points_diff_worker_history_head =
            ideology_parity.points_diff_worker_history_head;
        out.ideology_parity_points_diff_reference_history_q16 =
            ideology_parity.points_diff_reference_history_q16;
        out.ideology_parity_points_diff_worker_history_q16 =
            ideology_parity.points_diff_worker_history_q16;
        out.ideology_parity_points_diff_reference_last_day =
            ideology_parity.points_diff_reference_last_day;
        out.ideology_parity_points_diff_worker_round_day =
            ideology_parity.points_diff_worker_round_day;
        out.ideology_parity_points_diff_worker_committed_day =
            ideology_parity.points_diff_worker_committed_day;
        out.ideology_parity_points_diff_reference_catalog_hash =
            ideology_parity.points_diff_reference_catalog_hash;
        out.ideology_parity_points_diff_worker_catalog_hash =
            ideology_parity.points_diff_worker_catalog_hash;
    }
    // Reference ledger: unconditional, because a healthy parity run has no
    // points diff at all -- that is the whole point of asking whether a usable
    // reference was ever handed over.
    out.ideology_parity_reference_publish_count =
        ideology_parity.reference_publish_count;
    out.ideology_parity_reference_published_day =
        ideology_parity.reference_published_day;
    out.ideology_parity_reference_published_countries =
        ideology_parity.reference_published_countries;
    out.ideology_parity_reference_published_with_points_revision =
        ideology_parity.reference_published_with_points_revision;
    out.ideology_parity_reference_skipped_count =
        ideology_parity.reference_skipped_count;
    std::memcpy(out.ideology_parity_reference_skip_reason,
                ideology_parity.reference_skip_reason,
                sizeof(out.ideology_parity_reference_skip_reason));
    out.ideology_parity_catalog_mismatch_count =
        ideology_parity.catalog_mismatch_count;
    out.ideology_parity_last_reference_catalog_hash =
        ideology_parity.last_reference_catalog_hash;
    out.ideology_parity_last_worker_catalog_hash =
        ideology_parity.last_worker_catalog_hash;
    out.ideology_parity_worker_opinion_revision =
        ideology_parity.worker_opinion_revision;
    out.ideology_parity_worker_opinion_period_index =
        ideology_parity.worker_opinion_period_index;
    out.ideology_parity_worker_opinion_committed_day =
        ideology_parity.worker_opinion_committed_day;
    out.ideology_parity_worker_committed_day =
        ideology_parity.worker_committed_ideology_day;
    out.ideology_parity_paired_reference_day =
        ideology_parity.paired_reference_day;
    out.ideology_parity_paired_worker_day = ideology_parity.paired_worker_day;
    out.ideology_parity_row_mismatch_slot = ideology_parity.row_mismatch_slot;
    out.ideology_parity_row_mismatch_reference_handle =
        ideology_parity.row_mismatch_reference_handle;
    out.ideology_parity_row_mismatch_worker_handle =
        ideology_parity.row_mismatch_worker_handle;
    out.ideology_parity_row_mismatch_reference_points =
        ideology_parity.row_mismatch_reference_points;
    out.ideology_parity_row_mismatch_worker_points =
        ideology_parity.row_mismatch_worker_points;
    const RuntimeTriggerPodDiagnostics trigger_diag = trigger_pod_diagnostics();
    out.trigger_parity_day = trigger_diag.day;
    out.trigger_reference_day = trigger_diag.reference_day;
    out.trigger_input_hash = trigger_diag.input_hash;
    out.trigger_reference_input_hash = trigger_diag.reference_input_hash;
    out.trigger_reference_state_hash = trigger_diag.reference_state_hash;
    out.trigger_worker_state_hash = trigger_diag.worker_state_hash;
    out.trigger_reference_effect_hash = trigger_diag.reference_effect_hash;
    out.trigger_worker_effect_hash = trigger_diag.worker_effect_hash;
    out.trigger_required_ack_count = trigger_diag.required_ack_count;
    out.trigger_received_ack_count = trigger_diag.received_ack_count;
    out.trigger_pending_ack_count = trigger_diag.pending_ack_count;
    out.trigger_generation = trigger_diag.generation;
    out.trigger_committed_day = trigger_diag.committed_day;
    out.trigger_acked_effect_id = trigger_diag.acked_effect_id;
    out.trigger_pending_command_count = trigger_diag.pending_command_count;
    out.trigger_parity_compared = trigger_diag.parity_compared;
    out.trigger_parity_matched = trigger_diag.parity_matched;
    out.trigger_first_divergence_index = trigger_diag.first_divergence_index;
    std::memcpy(out.trigger_first_divergence_kind,
                trigger_diag.first_divergence_kind,
                sizeof(out.trigger_first_divergence_kind));
    runtime_copy_text(out.trigger_blocker, trigger_diag.blocker);
    out.trigger_pod_ready = _trigger_pod_ready.load(std::memory_order_acquire);
    out.trigger_pod_plan_ms = _trigger_pod_plan_ms.load(std::memory_order_acquire);
    out.trigger_pod_replay_ms = _trigger_pod_replay_ms.load(std::memory_order_acquire);
    out.trigger_pod_state_hash = _trigger_pod_state_hash.load(std::memory_order_acquire);
    out.trigger_pod_snapshot_generation = _trigger_pod_snapshot_generation.load(
        std::memory_order_acquire);
    out.trigger_pod_intent_count = _trigger_pod_intent_count.load(
        std::memory_order_acquire);
    out.trigger_pod_ack_count = _trigger_pod_ack_count.load(
        std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.trigger_pod_fallback_reason); ++i) {
        const char value = _trigger_pod_fallback_reason[i].load(
            std::memory_order_acquire);
        out.trigger_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.trigger_pod_fallback_reason[
        sizeof(out.trigger_pod_fallback_reason) - 1] = '\0';
    out.modifier_pod_ready = _modifier_pod_ready.load(std::memory_order_acquire);
    out.modifier_pod_plan_ms = _modifier_pod_plan_ms.load(std::memory_order_acquire);
    out.modifier_pod_replay_ms = _modifier_pod_replay_ms.load(std::memory_order_acquire);
    out.modifier_pod_work_units = _modifier_pod_work_units.load(std::memory_order_acquire);
    out.modifier_pod_state_hash = _modifier_pod_state_hash.load(std::memory_order_acquire);
    out.modifier_pod_snapshot_generation = _modifier_pod_snapshot_generation.load(
        std::memory_order_acquire);
    out.modifier_pod_ack_count = _modifier_pod_ack_count.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.modifier_pod_fallback_reason); ++i) {
        const char value = _modifier_pod_fallback_reason[i].load(
            std::memory_order_acquire);
        out.modifier_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.modifier_pod_fallback_reason[
        sizeof(out.modifier_pod_fallback_reason) - 1] = '\0';
    out.effect_pod_ready = _effect_pod_ready.load(std::memory_order_acquire);
    out.effect_pod_plan_ms = _effect_pod_plan_ms.load(std::memory_order_acquire);
    out.effect_pod_replay_ms = _effect_pod_replay_ms.load(std::memory_order_acquire);
    out.effect_pod_state_hash = _effect_pod_state_hash.load(std::memory_order_acquire);
    out.effect_pod_snapshot_generation = _effect_pod_snapshot_generation.load(
        std::memory_order_acquire);
    out.effect_pod_ack_count = _effect_pod_ack_count.load(std::memory_order_acquire);
    out.effect_pod_intent_count = _effect_pod_intent_count.load(
        std::memory_order_acquire);
    out.effect_pod_managed_intent_count =
        _effect_pod_managed_intent_count.load(std::memory_order_acquire);
    out.effect_pod_unmanaged_intent_count =
        _effect_pod_unmanaged_intent_count.load(std::memory_order_acquire);
    out.effect_pod_program_intent_count =
        _effect_pod_program_intent_count.load(std::memory_order_acquire);
    for (size_t i = 0; i < out.effect_pod_intent_program_ids.size(); ++i) {
        out.effect_pod_intent_program_ids[i] =
            _effect_pod_intent_program_ids[i].load(std::memory_order_relaxed);
    }
    out.effect_pod_transaction_count =
        _effect_pod_transaction_count.load(std::memory_order_acquire);
    out.effect_retire_absent_count = _effect_retire_absent_count.load(
        std::memory_order_acquire);
    out.effect_retire_stale_count = _effect_retire_stale_count.load(
        std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.effect_pod_fallback_reason); ++i) {
        const char value = _effect_pod_fallback_reason[i].load(
            std::memory_order_acquire);
        out.effect_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.effect_pod_fallback_reason[
        sizeof(out.effect_pod_fallback_reason) - 1] = '\0';
    out.ideology_pod_ready = _ideology_pod_ready.load(std::memory_order_acquire);
    out.ideology_pod_plan_ms = _ideology_pod_plan_ms.load(std::memory_order_acquire);
    out.ideology_pod_replay_ms = _ideology_pod_replay_ms.load(std::memory_order_acquire);
    out.ideology_pod_state_hash = _ideology_pod_state_hash.load(std::memory_order_acquire);
    out.ideology_pod_snapshot_generation = _ideology_pod_snapshot_generation.load(
        std::memory_order_acquire);
    out.ideology_pod_pending_transition_count =
        _ideology_pod_pending_transition_count.load(std::memory_order_acquire);
    out.ideology_pod_intent_count = _ideology_pod_intent_count.load(
        std::memory_order_acquire);
    out.ideology_pod_committed_day = _ideology_pod_committed_day.load(
        std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.ideology_pod_fallback_reason); ++i) {
        const char value = _ideology_pod_fallback_reason[i].load(
            std::memory_order_acquire);
        out.ideology_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.ideology_pod_fallback_reason[
        sizeof(out.ideology_pod_fallback_reason) - 1] = '\0';
    out.events_probe_enabled = _events_probe_enabled.load(std::memory_order_acquire);
    out.events_pod_ready = _events_pod_ready.load(std::memory_order_acquire);
    out.events_pod_plan_ms = _events_pod_plan_ms.load(std::memory_order_acquire);
    out.events_pod_replay_ms = _events_pod_replay_ms.load(std::memory_order_acquire);
    out.events_pod_state_hash = _events_pod_state_hash.load(std::memory_order_acquire);
    out.events_pod_snapshot_generation = _events_pod_snapshot_generation.load(
        std::memory_order_acquire);
    out.events_pod_event_count = _events_pod_event_count.load(std::memory_order_acquire);
    out.events_pod_ack_count = _events_pod_ack_count.load(std::memory_order_acquire);
    out.events_pod_drop_count = _events_pod_drop_count.load(std::memory_order_acquire);
    out.events_pod_rejected_count =
        _events_pod_rejected_count.load(std::memory_order_relaxed);
    out.events_failed_day = _events_failed_day.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.events_pod_fallback_reason); ++i) {
        const char value = _events_pod_fallback_reason[i].load(
            std::memory_order_acquire);
        out.events_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.events_pod_fallback_reason[sizeof(out.events_pod_fallback_reason) - 1] = '\0';
    out.environment_generation = _environment_generation.load(std::memory_order_acquire);
    out.environment_day = _environment_day.load(std::memory_order_acquire);
    out.environment_cell_count = _environment_cell_count.load(std::memory_order_acquire);
    out.environment_topology_validated = _environment_topology_validated.load(
        std::memory_order_acquire);
    out.invalid_environment_rejected = _invalid_environment_rejected.load(
        std::memory_order_relaxed);
    out.stale_environment_rejected = _stale_environment_rejected.load(std::memory_order_relaxed);
    for (size_t i = 0; i < sizeof(out.fault_code); ++i) {
        out.fault_code[i] = _fault_code[i].load(std::memory_order_relaxed);
    }
    for (size_t i = 0; i < sizeof(out.economy_yield_reason); ++i)
        out.economy_yield_reason[i] = _economy_yield_reason[i].load(std::memory_order_relaxed);
    out.economy_yield_reason[sizeof(out.economy_yield_reason) - 1] = '\0';
    for (size_t i = 0; i < sizeof(out.economy_stage_name); ++i)
        out.economy_stage_name[i] = _economy_stage_name[i].load(std::memory_order_relaxed);
    out.economy_stage_name[sizeof(out.economy_stage_name) - 1] = '\0';
    for (size_t i = 0; i < sizeof(out.economy_substage_name); ++i)
        out.economy_substage_name[i] = _economy_substage_name[i].load(std::memory_order_relaxed);
    out.economy_substage_name[sizeof(out.economy_substage_name) - 1] = '\0';
    out.economy_epoch_fiscal_ms = _economy_epoch_fiscal_ms.load(std::memory_order_relaxed);
    out.economy_fiscal_settlement_ms =
        _economy_fiscal_settlement_ms.load(std::memory_order_relaxed);
    out.economy_income_subsidy_ms =
        _economy_income_subsidy_ms.load(std::memory_order_relaxed);
    out.economy_negative_tax_mask =
        _economy_negative_tax_mask.load(std::memory_order_relaxed);
    out.economy_active_tax_mask =
        _economy_active_tax_mask.load(std::memory_order_relaxed);
    out.economy_attempt_slices =
        _economy_attempt_slices.load(std::memory_order_relaxed);
    out.fault_injection_armed = _fault_injection_armed.load(std::memory_order_acquire);
    out.fault_injection_trip_count =
        _fault_injection_trip_count.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.fault_injection_point); ++i) {
        out.fault_injection_point[i] = _fault_injection_point[i].load(
            std::memory_order_relaxed);
    }
    out.fault_injection_point[sizeof(out.fault_injection_point) - 1] = '\0';
    return out;
}

} // namespace pk
