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

bool NativeSimulationHost::start(RuntimeSimulationMode mode,
                                  bool graph_coverage_complete,
                                  int64_t initial_day,
                                  double speed_days_per_second,
                                  bool paused,
                                  uint32_t requested_authority_mask) {
    if (!_worker_returned->load(std::memory_order_acquire)) return false;
    RuntimeWorkerState expected = RuntimeWorkerState::STOPPED;
    if (!_state.compare_exchange_strong(expected, RuntimeWorkerState::STARTING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    // A std::thread remains joinable after worker_main publishes STOPPED. Hand
    // that completed handle to a detached reaper instead of making the Godot
    // caller wait in join(). The host remains alive until destruction waits for
    // all reapers, and the old worker performs no access after publishing
    // STOPPED.
    if (!reap_completed_worker_nonblocking()) {
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    // STOPPED proves the previous worker no longer accesses the host; the
    // independent retirement task may still be joining its OS handle. Reset
    // the continuation machine here rather than touching its
    // non-atomic bookkeeping from request_stop while a worker is still live.
    _stage_ops_day_index = -1;
    _stage_ops_day_input_generation = 0;
    _stage_ops_day_phase = StageOpsDayPhase::Done;
    _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Done),
                                      std::memory_order_release);
    if (mode == RuntimeSimulationMode::OFF) {
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _requested_authority_mask.store(0, std::memory_order_release);
        _authority_control.revoke();
        _active_evidence_mask.store(0, std::memory_order_release);
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return true;
    }
    // Per-domain gate. An ACTIVE request names the domains it wants to own; a
    // domain without a POD handler can never be granted, but the domains that
    // do have one no longer wait for the other eleven. COMMIT is the barrier
    // domain itself, so any non-empty request implicitly needs it.
    const uint32_t wanted = mode == RuntimeSimulationMode::ACTIVE
        ? (requested_authority_mask | runtime_domain_mask(RuntimeDomainId::COMMIT))
        : 0u;
    const uint32_t ungranted = wanted & ~implemented_domain_mask();
    _completion_gate_missing_domain_mask.store(ungranted, std::memory_order_release);
    _active_gate_blocked.store(false, std::memory_order_release);
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (!graph_coverage_complete || wanted == 0u || ungranted != 0u)) {
        _active_gate_blocked.store(true, std::memory_order_release);
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _requested_authority_mask.store(0, std::memory_order_release);
        _authority_control.revoke();
        const char *blocker = graph_coverage_complete && ungranted != 0u
            ? "missing_native_domain_handlers"
            : "runtime_graph_not_thread_safe";
        size_t i = 0;
        for (; i + 1 < _fault_code.size() && blocker[i] != '\0'; ++i) {
            _fault_code[i].store(blocker[i], std::memory_order_relaxed);
        }
        for (; i < _fault_code.size(); ++i) {
            _fault_code[i].store('\0', std::memory_order_relaxed);
        }
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    const bool restore_pending = _has_pending_restore;
    // A RESTART resumes on THIS host's calendar, not on the caller's.
    //
    // `initial_day` is the caller's main-thread calendar. It is only meaningful for
    // a fresh host, because a restarted worker's day must be contiguous with the
    // committed day of every POD it drives: `RuntimeCountryPodAuthority::plan_day`
    // refuses anything but `committed_day + 1` (`country_day_not_contiguous`), and
    // Climate/Effect/Ideology/Modifier/Trigger are sequential for the same reason.
    // Adopting the caller's day therefore made the first day after a restart
    // unplannable in every domain: no day ever committed, so the deferred authority
    // grant was never published and the reported mask read 0x000 for the rest of the
    // session while the writer followed the request (measured with a runtime flip
    // at main day 11: `country_day_not_contiguous` at day 12, `granted=0x000`).
    //
    // The previous lifetime's committed day is the last day for which the WHOLE
    // requested mask completed, so every POD is at or after it: PODs at that day
    // accept `+1`, and PODs one day ahead take their existing idempotent
    // `plan.day <= committed` path. The environment FIFO agrees too -- it holds the
    // oldest frame the old worker had not consumed, which is exactly the resumed
    // day, so the restarted worker does not have to wait for a re-publish.
    //
    // `_has_started_once && lifetime_granted_mask() != 0` is the positive proof that
    // this host ran this world's PODs to a committed day. Without it (a fresh host, a
    // fresh world on a reused host) the caller's day is used, exactly as before.
    const int64_t previous_committed = _committed_day.load(std::memory_order_acquire);
    const bool resuming_previous_lifetime =
        _has_started_once.load(std::memory_order_acquire) &&
        lifetime_granted_mask() != 0u;
    const int64_t start_day = restore_pending
        ? _pending_restore_bundle.committed_day
        : (resuming_previous_lifetime ? previous_committed : initial_day);
    const double start_speed = restore_pending
        ? _pending_restore_bundle.speed_days_per_second : speed_days_per_second;
    const bool start_paused = restore_pending
        ? _pending_restore_bundle.paused : paused;
    const uint64_t start_generation = restore_pending
        ? _pending_restore_bundle.generation : 0;
    const uint64_t start_state_hash = restore_pending
        ? _pending_restore_bundle.state_hash : 1469598103934665603ull;
    const double start_time_debt = restore_pending
        ? _pending_restore_bundle.time_debt_days : 0.0;
    const uint64_t restored_environment_generation = restore_pending
        ? _pending_restore_bundle.environment_generation : 0;
    const int64_t restored_environment_day = restore_pending
        ? _pending_restore_bundle.environment_day : start_day;
    if (restore_pending) {
        _worker_initial_pending_commands =
            std::move(_pending_restore_bundle.pending_commands);
    } else {
        _worker_initial_pending_commands.clear();
    }
    {
        std::lock_guard<std::mutex> lock(_control_mutex);
        if (mode == RuntimeSimulationMode::SHADOW) {
            if (_worker_initial_pending_commands.size() +
                    _prestart_modifier_commands.size() >
                RUNTIME_COMMAND_QUEUE_CAPACITY) {
                set_fault("modifier_prestart_queue_capacity_exceeded");
                _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
                return false;
            }
            _worker_initial_pending_commands.insert(
                _worker_initial_pending_commands.end(),
                _prestart_modifier_commands.begin(),
                _prestart_modifier_commands.end());
        }
        _prestart_modifier_commands.clear();
    }
    // The caller's flag is only an eligibility request.  Coverage is proven
    // by the worker after a complete RuntimeDayPlan barrier; accepting an
    // external `true` here must never make the facade report ACTIVE.
    _graph_coverage_complete.store(false, std::memory_order_release);
    _economy_authority_fault_paused.store(false, std::memory_order_release);
    _authority_control.begin_lifetime();
    // The request is recorded now; the grant is published only after a barrier
    // proves the worker actually ran those domains (see publish_day).
    _requested_authority_mask.store(wanted, std::memory_order_release);
    // I8: an ACTIVE EVENTS request owns the Events stage bit, so the POD store
    // must run whether or not the caller also asked for the diagnostic probe.
    // Leaving it off would make the stage soft-complete forever without ever
    // producing a snapshot.
    if ((wanted & runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u) {
        _events_probe_enabled.store(true, std::memory_order_release);
    }
    _mode.store(mode, std::memory_order_release);
    _committed_day.store(start_day, std::memory_order_release);
    _speed_days_per_second.store(std::max(0.0, start_speed),
                                 std::memory_order_release);
    _paused.store(start_paused, std::memory_order_release);
    _stop_requested.store(false, std::memory_order_release);
    _generation.store(start_generation, std::memory_order_release);
    _latest_from_day.store(start_day, std::memory_order_release);
    _latest_committed_day.store(start_day, std::memory_order_release);
    _latest_produced_at_us.store(0, std::memory_order_release);
    _latest_dirty_families.store(0, std::memory_order_release);
    _latest_receipt_count.store(0, std::memory_order_release);
    _last_visual_publish_us.store(0, std::memory_order_release);
    _snapshot_publish_throttled_count.store(0, std::memory_order_release);
    _last_commit_produced_at_us.store(0, std::memory_order_release);
    _worker_day_inflight.store(0, std::memory_order_release);
    _economy_inflight_mutations.store(0, std::memory_order_release);
    _economy_pending_command_count.store(0, std::memory_order_release);
    _last_command_admitted_us.store(0, std::memory_order_release);
    _economy_authority_switch_command_latency_us.store(0,
                                                       std::memory_order_release);
    _economy_authority_switch_latency_us.store(0,
                                                std::memory_order_release);
    _economy_authority_switch_latency_p95_us.store(0,
                                                    std::memory_order_release);
    _economy_authority_switch_latency_max_us.store(0,
                                                    std::memory_order_release);
    _economy_authority_switch_command_latency_p95_us.store(
        0, std::memory_order_release);
    _economy_authority_switch_command_latency_max_us.store(
        0, std::memory_order_release);
    _economy_authority_switch_latency_sample_count.store(
        0, std::memory_order_release);
    _economy_authority_switch_latency_sample_write.store(
        0, std::memory_order_release);
    for (auto &sample : _economy_authority_switch_latency_samples)
        sample.store(0, std::memory_order_release);
    for (auto &sample : _economy_authority_switch_command_latency_samples)
        sample.store(0, std::memory_order_release);
    _economy_authority_switch_audit_sequence.store(0,
        std::memory_order_release);
    _economy_authority_switch_audit_hash.store(0, std::memory_order_release);
    for (auto &family_generation : _dirty_family_generations) {
        family_generation.store(0, std::memory_order_release);
    }
    _ui_input_to_feedback_ms.store(0.0, std::memory_order_release);
    _visual_apply_ms.store(0.0, std::memory_order_release);
    _gpu_upload_ms.store(0.0, std::memory_order_release);
    _completed_days.store(0, std::memory_order_release);
    _last_day_stage_count.store(0, std::memory_order_release);
    _last_day_completed_stages.store(0, std::memory_order_release);
    _last_day_work_units.store(0, std::memory_order_release);
    _pod_completed_domain_mask.store(0, std::memory_order_release);
    _pod_completed_stage_count.store(0, std::memory_order_release);
    _pod_work_units.store(0, std::memory_order_release);
    _pod_intent_count.store(0, std::memory_order_release);
    _pod_fallback_count.store(0, std::memory_order_release);
    _economy_pod_ready.store(false, std::memory_order_release);
    _economy_pod_committed.store(false, std::memory_order_release);
    _economy_pod_authority_ready.store(false, std::memory_order_release);
    _economy_pod_committed_day.store(-1, std::memory_order_release);
    _economy_pod_epoch_sample_day.store(-1, std::memory_order_release);
    _economy_pod_generation.store(0, std::memory_order_release);
    _economy_pod_state_hash.store(0, std::memory_order_release);
    _economy_pod_input_generation.store(0, std::memory_order_release);
    _economy_pod_country_generation.store(0, std::memory_order_release);
    _economy_pod_completed_stage_mask.store(0, std::memory_order_release);
    _economy_pod_pending_outbox.store(0, std::memory_order_release);
    _economy_pod_pending_inbox.store(0, std::memory_order_release);
    _economy_pod_operation_gate_mask.store(0, std::memory_order_release);
    _economy_pod_parity_ready_mask.store(0, std::memory_order_release);
    _economy_sync_writes_forbidden.store(false, std::memory_order_release);
    _economy_input_requested_day.store(-1, std::memory_order_release);
    _main_boundary_service_requested.store(0, std::memory_order_release);
    _economy_input_signal.store(0, std::memory_order_release);
    _economy_shadow_stage_invocations.store(0, std::memory_order_release);
    _economy_shadow_stage_cache_hits.store(0, std::memory_order_release);
    _economy_pod_command_recapture_count.store(0, std::memory_order_release);
    _economy_pod_command_verify_count.store(0, std::memory_order_release);
    _economy_shadow_cache_valid = false;
    _economy_shadow_cache_day = -1;
    _economy_shadow_cache_input_generation = 0;
    _economy_shadow_cache_country_generation = 0;
    _economy_shadow_cache_catalog_hash = 0;
    _economy_replay_completed_stage_mask.store(0, std::memory_order_release);
    _economy_replay_stage_cursor.store(0, std::memory_order_release);
    _economy_replay_input_hash.store(0, std::memory_order_release);
    _economy_replay_base_hash.store(0, std::memory_order_release);
    _economy_replay_next_hash.store(0, std::memory_order_release);
    for (auto &value : _economy_replay_stage_hash)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_replay_stage_work)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_replay_stage_ms)
        value.store(0.0, std::memory_order_release);
    _economy_replay_input_captured.store(false, std::memory_order_release);
    _economy_replay_committed.store(false, std::memory_order_release);
    _economy_replay_parity_ready.store(false, std::memory_order_release);
    for (auto &value : _economy_replay_fallback_reason)
        value.store('\0', std::memory_order_release);
    _economy_reference_day.store(-1, std::memory_order_release);
    _economy_reference_generation.store(0, std::memory_order_release);
    _economy_reference_hash.store(0, std::memory_order_release);
    for (auto &value : _economy_stage_reference_hash)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_stage_reference_work)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_stage_reference_present)
        value.store(0, std::memory_order_release);
    _economy_pod_authority.reset();
    _domain_authority_planned_mask.store(0, std::memory_order_release);
    _domain_authority_committed_mask.store(0, std::memory_order_release);
    _domain_authority_ack_count.store(0, std::memory_order_release);
    _domain_authority_input_hash.store(0, std::memory_order_release);
    _domain_authority_state_hash.store(0, std::memory_order_release);
    _domain_authority_plan_ms.store(0.0, std::memory_order_release);
    _domain_authority_replay_ms.store(0.0, std::memory_order_release);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _domain_stage_fallback_count.store(0, std::memory_order_release);
    for (auto &character : _domain_stage_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _country_pod_ready.store(false, std::memory_order_release);
    for (auto &character : _country_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _country_parity_compared.store(0, std::memory_order_release);
    _country_parity_matched.store(0, std::memory_order_release);
    _country_parity_compared_count.store(0, std::memory_order_release);
    _country_parity_matched_count.store(0, std::memory_order_release);
    _country_parity_first_mismatch_day.store(-1, std::memory_order_release);
    _country_parity_reference_hash.store(0, std::memory_order_release);
    _country_parity_worker_hash.store(0, std::memory_order_release);
    _country_parity_index.store(-1, std::memory_order_release);
    for (auto &character : _country_parity_status)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _country_parity_field)
        character.store('\0', std::memory_order_relaxed);
    _climate_pod_ready.store(false, std::memory_order_release);
    _climate_pod_plan_ms.store(0.0, std::memory_order_release);
    _climate_pod_replay_ms.store(0.0, std::memory_order_release);
    _climate_pod_work_units.store(0, std::memory_order_release);
    _climate_pod_changed_cells.store(0, std::memory_order_release);
    for (size_t i = 0; i < _climate_stage_ms.size(); ++i) {
        _climate_stage_ms[i].store(0.0, std::memory_order_relaxed);
        _climate_stage_work[i].store(0, std::memory_order_relaxed);
    }
    _climate_pod_state_hash.store(0, std::memory_order_release);
    _climate_pod_reference_hash.store(0, std::memory_order_release);
    _climate_pod_parity_compared.store(false, std::memory_order_release);
    _climate_pod_parity_matched.store(false, std::memory_order_release);
    _climate_pod_parity_mismatch_count.store(0, std::memory_order_release);
    for (auto &character : _climate_pod_parity_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _climate_parity_day.store(-1, std::memory_order_release);
    _climate_parity_stage.store(0, std::memory_order_release);
    _climate_parity_cell.store(0, std::memory_order_release);
    _climate_parity_input_generation.store(0, std::memory_order_release);
    _climate_parity_base_generation.store(0, std::memory_order_release);
    _climate_parity_trace_hash.store(0, std::memory_order_release);
    for (auto &character : _climate_parity_field) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_parity_reference_bits) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_parity_worker_bits) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _modifier_pod_ready.store(false, std::memory_order_release);
    _modifier_pod_plan_ms.store(0.0, std::memory_order_release);
    _modifier_pod_replay_ms.store(0.0, std::memory_order_release);
    _modifier_pod_work_units.store(0, std::memory_order_release);
    _modifier_pod_state_hash.store(0, std::memory_order_release);
    _modifier_pod_snapshot_generation.store(0, std::memory_order_release);
    _modifier_pod_ack_count.store(0, std::memory_order_release);
    for (auto &character : _modifier_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _time_debt_days.store(std::clamp(start_time_debt, 0.0, 100.0),
                          std::memory_order_release);
    const auto existing_environment = environment_snapshot();
    if (existing_environment != nullptr) {
        _environment_generation.store(existing_environment->generation, std::memory_order_release);
        _environment_day.store(existing_environment->day, std::memory_order_release);
        _environment_cell_count.store(existing_environment->cell_count,
                                      std::memory_order_release);
        _environment_topology_validated.store(existing_environment->topology_validated,
                                              std::memory_order_release);
    } else {
        _environment_generation.store(0, std::memory_order_release);
        _environment_day.store(restored_environment_day, std::memory_order_release);
        _environment_cell_count.store(0, std::memory_order_release);
        _environment_topology_validated.store(false, std::memory_order_release);
    }
    if (restored_environment_generation >
            _environment_generation.load(std::memory_order_acquire)) {
        _environment_generation.store(restored_environment_generation,
                                      std::memory_order_release);
        _environment_day.store(restored_environment_day,
                               std::memory_order_release);
    }
    _command_enqueue_pos.store(0, std::memory_order_relaxed);
    _command_dequeue_pos.store(0, std::memory_order_relaxed);
    for (uint64_t i = 0; i < RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
        _command_slots[i].sequence.store(i, std::memory_order_relaxed);
    }
    _receipt_write.store(0, std::memory_order_relaxed);
    _receipt_read.store(0, std::memory_order_relaxed);
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        const uint64_t restored_sequence = restore_pending
            ? _pending_restore_bundle.producer_sequences[i] : 0;
        _producer_sequences[i].store(restored_sequence,
                                     std::memory_order_relaxed);
    }
    _fallback_producer_sequence.store(restore_pending
            ? _pending_restore_bundle.fallback_producer_sequence : 0,
        std::memory_order_relaxed);
    _save_requested.store(false, std::memory_order_release);
    _save_request_id.store(0, std::memory_order_release);
    _save_consumed_request_id.store(0, std::memory_order_release);
    _save_failed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(), std::memory_order_release);
    _snapshots.reset();
    // WorldRuntimeHost captures the initial immutable input immediately
    // before starting the worker. Preserve that frame so the OFF reference
    // can release it after the synchronous day boundary. A trace belonging to
    // another start/day is discarded explicitly.
    int64_t trace_front_day = -1;
    if (_climate_trace.front_day(trace_front_day) && trace_front_day != start_day) {
        _climate_trace.reset();
    }
    _climate_trace_consumed.store(0, std::memory_order_release);
    _climate_trace_missing.store(0, std::memory_order_release);
    _climate_trace_latest_hash.store(0, std::memory_order_release);
    _climate_trace_signal.store(0, std::memory_order_release);
    clear_climate_parity_divergence();
    reset_climate_parity_fields();
    _state_hash.store(start_state_hash, std::memory_order_release);
    const auto bootstrap_environment = environment_snapshot();
    const auto bootstrap_country = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    _pod_pipeline.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _authoritative_domains.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _domain_authority_runner.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _modifier_snapshots.reset();
    _effect_snapshots.reset();
    _ideology_snapshots.reset();
    _opinion_view_version = {}; _annual_ideology_view_version = {}; _country_ai_economy_view_version = {}; _annual_country_view_version = {};
    _events_authority.reset();
    _events_snapshots.reset();
    _events_last_processed_day = -1;
    _economy_fact_event_sequence = restore_pending ? _pending_restore_bundle.economy_fact_event_sequence : 0;
    _trigger_forwarded_event_id = restore_pending ? _pending_restore_bundle.trigger_forwarded_event_id : 0;
    _trigger_forward_sequence = restore_pending ? _pending_restore_bundle.trigger_forward_sequence : 0;
    _events_pod_ready.store(false, std::memory_order_release);
    _events_pod_plan_ms.store(0.0, std::memory_order_release);
    _events_pod_replay_ms.store(0.0, std::memory_order_release);
    _events_pod_state_hash.store(0, std::memory_order_release);
    _events_pod_snapshot_generation.store(0, std::memory_order_release);
    _events_pod_event_count.store(0, std::memory_order_release);
    _events_pod_ack_count.store(0, std::memory_order_release);
    _events_pod_drop_count.store(0, std::memory_order_release);
    _events_pod_rejected_count.store(0, std::memory_order_release);
    _events_failed_day.store(-1, std::memory_order_release);
    for (auto &character : _events_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    RuntimeModifierPodAuthority modifier_candidate;
    bool modifier_candidate_ready = false;
    if (_modifier_pod_configured) {
        std::string modifier_config_error;
        if (!modifier_candidate.configure(_modifier_pod_catalog,
                                          modifier_config_error)) {
            set_fault(modifier_config_error.empty() ? "modifier_pod_configure_failed" :
                      modifier_config_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        modifier_candidate_ready = true;
    }
    RuntimeEffectPodAuthority effect_candidate;
    bool effect_candidate_ready = false;
    if (_effect_pod_configured) {
        std::string effect_config_error;
        if (!effect_candidate.configure(_effect_pod_catalog, effect_config_error)) {
            set_fault(effect_config_error.empty() ? "effect_pod_configure_failed" :
                      effect_config_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        effect_candidate_ready = true;
    }
    RuntimeIdeologyPodAuthority ideology_candidate;
    bool ideology_candidate_ready = false;
    if (_ideology_pod_configured) {
        std::string ideology_config_error;
        if (!ideology_candidate.configure(_ideology_pod_catalog,
                                          ideology_config_error)) {
            set_fault(ideology_config_error.empty()
                ? "ideology_pod_configure_failed"
                : ideology_config_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        ideology_candidate_ready = true;
    }
    if (ideology_candidate_ready) {
        const auto ideology_country = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        const auto ideology_opinion = std::atomic_load_explicit(
            &_ideology_opinion_snapshot, std::memory_order_acquire);
        if (ideology_country != nullptr && ideology_opinion != nullptr) {
            std::string ideology_bootstrap_error;
            if (!ideology_candidate.bootstrap(*ideology_country,
                                               *ideology_opinion,
                                               ideology_bootstrap_error)) {
                set_fault(ideology_bootstrap_error.empty()
                    ? "ideology_pod_bootstrap_failed"
                    : ideology_bootstrap_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED,
                             std::memory_order_release);
                return false;
            }
        }
    }
    _climate_authority.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u);
    _climate_writeback.reset();
    // Clear leftover ring slots from a prior worker lifetime, then re-seed the
    // generation-time capture. WorldRuntimeHost publishes environment *before*
    // start(); wiping without reseed leaves report.environment_generation > 0
    // while has_pending_climate_input() is false. ACTIVE serial_wait soak then
    // deadlocks: wait_climate_consumed(gen) never completes, and the first
    // run_daily_tick (which would publish) never runs.
    _environment_ring.reset();
    uint64_t bootstrap_published_days = 0;
    if (bootstrap_environment != nullptr) {
        bool dropped = false;
        if (!_environment_ring.force_push(bootstrap_environment, dropped)) {
            set_fault("climate_environment_bootstrap_reseed_failed");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        bootstrap_published_days = 1;
        std::atomic_store_explicit(&_environment_snapshot,
            bootstrap_environment, std::memory_order_release);
    }
    _climate_writeback_sequence.store(0, std::memory_order_release);
    _climate_writeback_last_day.store(-1, std::memory_order_release);
    _climate_committed_day.store(-1, std::memory_order_release);
    _climate_committed_input_generation.store(0, std::memory_order_release);
    _climate_writeback_input_generation.store(0, std::memory_order_release);
    _climate_bootstrap_day.store(start_day, std::memory_order_release);
    _climate_consumed_generation.store(0, std::memory_order_release);
    _climate_last_counted_generation.store(0, std::memory_order_release);
    _environment_published_days.store(bootstrap_published_days, std::memory_order_release);
    _environment_consumed_days.store(0, std::memory_order_release);
    _environment_superseded_days.store(0, std::memory_order_release);
    _environment_dropped_days.store(0, std::memory_order_release);
    _climate_wait_total_ms.store(0, std::memory_order_release);
    _climate_wait_last_ms.store(0, std::memory_order_release);
    _climate_wait_max_ms.store(0, std::memory_order_release);
    if (restore_pending && !_pending_restore_bundle.modifier_bytes.empty()) {
        std::string modifier_restore_error;
        if (!modifier_candidate_ready ||
            !modifier_candidate.restore(
                _pending_restore_bundle.modifier_bytes.data(),
                _pending_restore_bundle.modifier_bytes.size(),
                modifier_restore_error)) {
            set_fault(modifier_restore_error.empty() ? "modifier_pod_restore_failed" :
                      modifier_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending) {
        if (!_pending_restore_bundle.effect_bytes.empty() && effect_candidate_ready) {
            std::string effect_restore_error;
            if (!effect_candidate.restore(
                    _pending_restore_bundle.effect_bytes.data(),
                    _pending_restore_bundle.effect_bytes.size(),
                    effect_restore_error)) {
                set_fault(effect_restore_error.empty() ? "effect_pod_restore_failed" :
                          effect_restore_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
                return false;
            }
        } else {
            set_fault("effect_pod_section_missing");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending && !_pending_restore_bundle.ideology_bytes.empty()) {
        std::string ideology_restore_error;
        if (!ideology_candidate_ready)
            ideology_restore_error = "ideology_pod_catalog_missing_at_worker_start";
        if (!ideology_candidate_ready || !ideology_candidate.restore(
                _pending_restore_bundle.ideology_bytes.data(),
                _pending_restore_bundle.ideology_bytes.size(),
                ideology_restore_error)) {
            set_fault(ideology_restore_error.empty()
                ? "ideology_pod_restore_failed"
                : ideology_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    const bool has_ecp2 =
        !_pending_restore_bundle.economy_ecp2_bytes.empty();
    const bool has_ecp1 =
        !_pending_restore_bundle.economy_pod_bytes.empty();
    RuntimeEconomyEcp2State restored_ecp2;
    std::string ecp2_apply_error;
    if (restore_pending && (has_ecp2 || has_ecp1)) {
        // Production restore is ECP2-only: bare ECP1 / missing ECP2 is
        // rejected before any live economy mutation.
        if (!has_ecp2) {
            set_fault("economy_restore_rejects_ecp1");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        if (!decode_ecp2(_pending_restore_bundle.economy_ecp2_bytes.data(),
                         _pending_restore_bundle.economy_ecp2_bytes.size(),
                         restored_ecp2, ecp2_apply_error)) {
            set_fault(ecp2_apply_error.empty()
                ? "economy_ecp2_decode_failed"
                : ecp2_apply_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        if (_economy_production_runtime == nullptr) {
            set_fault("economy_ecp2_runtime_unavailable");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        if (!ecp2_has_required_domains(restored_ecp2.authority_domain_mask,
                                       ECP2_DOMAIN_CORE_AUTHORITY)) {
            set_fault("economy_ecp2_core_domains_missing");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        // COUNTRY IS INSTALLED AFTER ECONOMY ON THIS PATH, so the archive's country
        // generation/hash cannot match the live (still bootstrapped) Country runtime
        // yet. Measured: `saved_gen=19 live_gen=1 saved_hash=325166771088284131
        // live_hash=1824313771786949620`, which is why every load of a real save ended
        // in `economy_country_restore_order_or_hash_mismatch` and could not start the
        // worker.
        //
        // Skipping the check entirely would let an archive whose Country bytes and
        // Economy bytes come from DIFFERENT saves through, which is real corruption.
        // So the identity the archive asked for is captured here and verified again
        // below, once Country is actually installed -- the same comparison, just moved
        // to a point where it is meaningful.
        const bool ecp2_applied = EconomyAuthorityTransfer::restore_before_country(
            *_economy_production_runtime, restored_ecp2, ecp2_apply_error);
        if (!ecp2_applied) {
            set_fault(ecp2_apply_error.empty()
                ? "economy_ecp2_apply_failed"
                : ecp2_apply_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED,
                          std::memory_order_release);
            return false;
        }
        if (!_economy_pod_authority.restore_ecp2(
                _pending_restore_bundle.economy_ecp2_bytes.data(),
                _pending_restore_bundle.economy_ecp2_bytes.size(),
                ecp2_apply_error)) {
            set_fault(ecp2_apply_error.empty()
                ? "economy_ecp2_pod_cache_failed"
                : ecp2_apply_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        _economy_pod_ready.store(true, std::memory_order_release);
        _economy_pod_committed.store(true, std::memory_order_release);
    }
    // ECP1 is never an authority restore path after the ECP2-only cutover.
    // Dual-write may still encode ECP1 for migrate tooling, but restore skips it.
    if (restore_pending && !_pending_restore_bundle.domain_pod_bytes.empty()) {
        std::string pod_restore_error;
        if (!_pod_pipeline.restore(_pending_restore_bundle.domain_pod_bytes.data(),
                                   _pending_restore_bundle.domain_pod_bytes.size(),
                                   pod_restore_error)) {
            set_fault(pod_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        if (_pod_pipeline.restored_legacy_modifier() &&
            _pending_restore_bundle.modifier_bytes.empty()) {
            if (!modifier_candidate_ready) {
                set_fault("modifier_pod_catalog_required_for_pdp3");
                _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
                return false;
            }
            const RuntimeModifierPodState &legacy =
                _pod_pipeline.legacy_modifier_state();
            std::vector<std::pair<uint16_t, RuntimeModifierPodEntry>> entries;
            entries.reserve(legacy.entries.size());
            for (const RuntimeModifierPodEntry &entry : legacy.entries) {
                if (entry.definition_id < 0 ||
                    entry.definition_id >= static_cast<int32_t>(
                        _modifier_pod_catalog.definitions.size())) {
                    set_fault("modifier_pdp3_definition_invalid");
                    _state.store(RuntimeWorkerState::STOPPED,
                                 std::memory_order_release);
                    return false;
                }
                const uint16_t domain = static_cast<uint16_t>(
                    _modifier_pod_catalog.definitions[
                        static_cast<size_t>(entry.definition_id)].domain);
                entries.emplace_back(domain, entry);
            }
            std::array<uint64_t, 4> domain_versions{};
            domain_versions.fill(legacy.revision);
            std::string migration_error;
            if (!modifier_candidate.restore_legacy_entries(
                    entries, legacy.generation, 0, start_day,
                    domain_versions, migration_error)) {
                set_fault(migration_error.empty()
                    ? "modifier_pdp3_migration_failed" : migration_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED,
                             std::memory_order_release);
                return false;
            }
        }
    }
    if (restore_pending && !_pending_restore_bundle.climate_bytes.empty()) {
        std::string climate_restore_error;
        if (!_climate_authority.restore(_pending_restore_bundle.climate_bytes.data(),
                                        _pending_restore_bundle.climate_bytes.size(),
                                        climate_restore_error)) {
            set_fault(climate_restore_error.empty() ? "climate_restore_failed" :
                      climate_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending && !_pending_restore_bundle.trigger_bytes.empty()) {
        std::string trigger_restore_error;
        if (!restore_trigger_pod_save(_pending_restore_bundle.trigger_bytes.data(),
                                     _pending_restore_bundle.trigger_bytes.size(),
                                     trigger_restore_error)) {
            set_fault(trigger_restore_error.empty() ? "trigger_restore_failed" :
                      trigger_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending && !_pending_restore_bundle.events_bytes.empty()) {
        std::string events_restore_error;
        if (!_events_authority.restore(_pending_restore_bundle.events_bytes.data(),
                                       _pending_restore_bundle.events_bytes.size(),
                                       events_restore_error)) {
            set_fault(events_restore_error.empty() ? "events_restore_failed" :
                      events_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }

    }
    if (restore_pending && !_pending_restore_bundle.gameplay_effect_bytes.empty()) {
        const std::vector<uint8_t> &gmp =
            _pending_restore_bundle.gameplay_effect_bytes;
        size_t gmp_cursor = 0;
        uint32_t marker = 0;
        uint32_t abi = 0;
        uint64_t generation = 0;
        uint32_t pending = 0;
        uint32_t terminal = 0;
        uint64_t state_hash = 0;
        if (!d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, marker) ||
            !d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, abi) ||
            !d7_read_u64(gmp.data(), gmp.size(), gmp_cursor, generation) ||
            !d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, pending) ||
            !d7_read_u32(gmp.data(), gmp.size(), gmp_cursor, terminal) ||
            !d7_read_u64(gmp.data(), gmp.size(), gmp_cursor, state_hash) ||
            gmp_cursor != gmp.size() || marker != 0x31504d47u || abi != 1u) {
            set_fault("gameplay_effect_gmp1_restore_failed");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        _gameplay_effect_generation.store(generation,
                                          std::memory_order_release);
        _gameplay_effect_pending.store(pending, std::memory_order_release);
        _gameplay_effect_terminal.store(terminal, std::memory_order_release);
        _gameplay_effect_state_hash.store(state_hash,
                                          std::memory_order_release);
    }
    CountryCoreCheckpoint restored_country_checkpoint;
    bool restored_country_checkpoint_valid = false;
    if (restore_pending && !_pending_restore_bundle.country_bytes.empty()) {
        CountryCoreCheckpoint checkpoint;
        std::string country_restore_error;
        if (!decode_country_core_checkpoint(
                _pending_restore_bundle.country_bytes.data(),
                _pending_restore_bundle.country_bytes.size(), checkpoint,
                country_restore_error)) {
            set_fault(country_restore_error.empty()
                ? "country_checkpoint_restore_failed"
                : country_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        auto copy = std::make_shared<CountryCoreCheckpoint>(
            std::move(checkpoint));
        restored_country_checkpoint = *copy;
        restored_country_checkpoint_valid = true;
        std::atomic_store_explicit(&_country_checkpoint,
            std::shared_ptr<const CountryCoreCheckpoint>(std::move(copy)),
            std::memory_order_release);
        // P1-a: verify the country identity the ARCHIVE asked for, now that Country is
        // actually installed.
        //
        // `apply_ecp2_authority` had to skip this comparison (Country was still the
        // freshly bootstrapped one at that point, measured `saved_gen=19 live_gen=1`),
        // and it recorded the expected values instead. Checking here is what keeps the
        // deferred comparison honest: pairing A's Country bytes with B's Economy bytes
        // must fail to start the worker, not load silently.
        if (_economy_production_runtime != nullptr) {
            std::string identity_error;
            if (!EconomyAuthorityTransfer::verify_after_country(
                    *_economy_production_runtime, identity_error)) {
                set_fault(identity_error.empty()
                    ? "economy_country_identity_mismatch"
                    : identity_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED,
                             std::memory_order_release);
                return false;
            }
        }
    }
    if (restore_pending) {
        uint64_t restored_request_id = _command_request_id.load(
            std::memory_order_relaxed);
        for (const RuntimeCommandPacket &packet : _worker_initial_pending_commands)
            restored_request_id = std::max(restored_request_id,
                                           packet.envelope.request_id);
        if (restored_country_checkpoint_valid) {
            for (const CountryCommandReceipt &receipt :
                     restored_country_checkpoint.request_states) {
                restored_request_id = std::max(restored_request_id,
                                               receipt.request_id);
            }
        }
        _command_request_id.store(restored_request_id,
                                  std::memory_order_release);
    }
    // Economy persists terminal peer identities independently of the Host's
    // live transport queues. A quiescent save may have no Host request states
    // while its PKEC journal still owns thousands of request IDs. Seed from
    // both authorities before any new worker or facade request is allocated.
    if (_economy_production_runtime != nullptr)
        reserve_command_request_ids_through(
            _economy_production_runtime->asset_peer_request_high_watermark());
    // Country is initialized from the immutable main-thread capture exactly
    // once per worker lifetime. The worker never calls NativeCountryRuntime;
    // it owns this POD authority and its continuation state after bootstrap.
    RuntimeCountryPodAuthority country_candidate;
    bool country_candidate_ready = false;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        const auto country_snapshot = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        if (country_snapshot != nullptr && _country_pod_catalog.catalog_hash != 0) {
            std::string country_config_error;
            const RuntimeCountryPodSnapshot *bootstrap_snapshot =
                country_snapshot.get();
            RuntimeCountryPodSnapshot cold_start_baseline;
            // A newly generated Country store has committed_day=-1: it is a
            // baseline, not a simulated day. The Host clock starts at day 0,
            // and Climate's first comparable frame is day 1. Without aligning
            // this no-op baseline to the Host start day, Country's first
            // plan_day(1) fails forever with country_day_not_contiguous.
            //
            // Limit the adjustment to the exact one-day cold-start shape for
            // both SHADOW and ACTIVE production boots. Restore and ACTIVE
            // handoff with a real committed day do not match this shape and
            // keep their persisted day verbatim; larger gaps stay visible.
            if (!restore_pending &&
                country_snapshot->committed_day + 1 == start_day) {
                cold_start_baseline = *country_snapshot;
                cold_start_baseline.committed_day = start_day;
                cold_start_baseline.state_hash =
                    country_core_hash_business_state(cold_start_baseline);
                bootstrap_snapshot = &cold_start_baseline;
            }
            country_candidate_ready = country_candidate.bootstrap(
                *bootstrap_snapshot, _country_pod_catalog, country_config_error);
            if (!country_candidate_ready && mode == RuntimeSimulationMode::ACTIVE &&
                (wanted & runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u) {
                set_fault(country_config_error.empty()
                    ? "country_pod_bootstrap_failed" : country_config_error.c_str());
                _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
                return false;
            }
        }
        _country_worker_session_epoch += 1u;
        if (_country_worker_session_epoch == 0) _country_worker_session_epoch = 1u;
        _country_worker_intent_queue.clear();
        _country_worker_intents.clear();
        _country_worker_results.clear();
        _country_worker_terminal_results.clear();
        _country_worker_notifications.clear();
        _country_economy_asset_request_queue.clear();
        _country_economy_asset_requests.clear();
        _country_economy_asset_results.clear();
        _country_economy_asset_terminal_results.clear();
        _country_economy_asset_dispatched.clear();
        _country_economy_asset_committed.clear();
        _country_economy_asset_self_settled.clear();
        _economy_origin_asset_queue.clear();
        _country_economy_asset_protocol = RuntimeEconomyAssetProtocolStatus{};
        _country_command_terminals.clear();
        _country_command_states.clear();
        if (restored_country_checkpoint_valid) {
            for (const CountryCommandReceipt &receipt :
                     restored_country_checkpoint.request_states) {
                _country_command_states.emplace(receipt.request_id, receipt);
            }
            for (const CountryCommandReceipt &receipt :
                     restored_country_checkpoint.terminal_receipts) {
                _country_command_terminals.emplace(receipt.request_id, receipt);
            }
        }
        _country_pod_plan = RuntimeCountryPodPlan{};
        _country_pod_plan_active.store(false, std::memory_order_release);
        _country_worker_protocol = CountryPeerProtocolStatus{};
        _country_worker_protocol.async_mode = 1;
        _country_worker_protocol.retry_day = -1;
        _country_worker_seal = CountryBoundarySeal{};
    }
    if (restore_pending && !_pending_restore_bundle.economy_asset_bytes.empty()) {
        std::string d7_restore_error;
        if (!restore_country_economy_asset_journal(
                _pending_restore_bundle.economy_asset_bytes.data(),
                _pending_restore_bundle.economy_asset_bytes.size(),
                d7_restore_error)) {
            set_fault(d7_restore_error.empty()
                ? "d7_transaction_journal_restore_failed"
                : d7_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (country_candidate_ready) {
        _country_pod_authority = std::move(country_candidate);
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
    }
    _country_pod_configured.store(country_candidate_ready,
                                  std::memory_order_release);
    _country_pod_ready.store(false, std::memory_order_release);
    if (modifier_candidate_ready) {
        _modifier_pod_authority = std::move(modifier_candidate);
        uint32_t initial_slot = 0;
        if (!_modifier_snapshots.try_begin_write(initial_slot)) {
            set_fault("modifier_initial_snapshot_ring_full");
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        _modifier_snapshots.write_buffer(initial_slot) =
            _modifier_pod_authority.snapshot();
        _modifier_snapshots.publish(initial_slot);
        _modifier_pod_snapshot_generation.store(
            _modifier_pod_authority.snapshot().generation,
            std::memory_order_release);
        _modifier_pod_state_hash.store(
            _modifier_pod_authority.snapshot().state_hash,
            std::memory_order_release);
        _modifier_pod_ready.store(true, std::memory_order_release);
    } else {
        _modifier_pod_ready.store(false, std::memory_order_release);
    }
    if (effect_candidate_ready) {
        _effect_pod_authority = std::move(effect_candidate);
    }
    if (ideology_candidate_ready) {
        _ideology_pod_authority = std::move(ideology_candidate);
        _ideology_modifier_inflight.clear();
        _ideology_loose_modifier_rows.clear();
        _ideology_day_modifier_batches.clear();
        const RuntimeIdeologyPodSnapshot &initial =
            _ideology_pod_authority.snapshot();
        if (!initial.countries.empty()) {
            auto copy = std::make_shared<RuntimeIdeologyPodSnapshot>(initial);
            std::atomic_store_explicit(&_ideology_snapshot,
                std::shared_ptr<const RuntimeIdeologyPodSnapshot>(
                    std::move(copy)), std::memory_order_release);
            _ideology_pod_state_hash.store(initial.state_hash,
                                            std::memory_order_release);
            _ideology_pod_snapshot_generation.store(initial.generation,
                                                     std::memory_order_release);
            _ideology_pod_ready.store(true, std::memory_order_release);
        }
    }
    _pod_visual_intents.clear();
    _pod_receipts.clear();
    // A fresh ACTIVE start earns its grant from the first fully committed day.
    // A restore start must not wait for that: every domain's POD state was just
    // installed from the bundle, and until the grant exists Economy's routing
    // (which reads the grant) falls back to the synchronous Country peer — on
    // the worker thread, against the main-thread NativeCountryRuntime. A new
    // game has no cross-domain asset traffic on its first day so the window is
    // harmless there; a loaded game with an active tax settles on that first
    // day, which crashed in commit_economy_asset_transaction and otherwise left
    // the fiscal continuation parked against a Country the worker never saw.
    if (restore_pending && mode == RuntimeSimulationMode::ACTIVE && wanted != 0u &&
        ((wanted & runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u ||
         country_candidate_ready)) {
        publish_authority_grant(wanted & implemented_domain_mask());
        uint32_t restore_slot = 0;
        if (!_pending_restore_bundle.climate_bytes.empty() && _climate_writeback.try_begin_write(restore_slot)) {
            auto &writeback = _climate_writeback.write_buffer(restore_slot);
            _climate_authority.snapshot_into(writeback, true);
            writeback.restored_capture_cursors = _climate_authority.capture_cursors();
            writeback.generation = _climate_writeback_sequence.fetch_add(1) + 1u;
            _climate_writeback.publish(restore_slot);
        }
    }
    // A RESTART re-publishes the grant a previous lifetime of THIS host earned.
    //
    // `request_stop()` and `set_fault()` both clear the live grant, and
    // that revocation is right: the schedule gate has to hand the domain back to the
    // main thread while the old worker winds down, otherwise nobody computes it.
    // What was missing is the other half of the handshake. Nothing re-published the
    // grant when the next worker lifetime started, so a runtime authority flip
    // (stop -> start with a new mask, no world regeneration) left the mask at 0
    // while the REQUEST was already recorded two lines above. The restarted writer
    // then followed the request (the main-thread day is suppressed per requested
    // mask) while every consumer that gates on the reported mask stayed off for the
    // rest of the session -- measured in `ideology_worker_authority_parity_test.gd`
    // as `mask=0x000 state=PAUSED` next to `suppressed=false`, with the ideology
    // instance-refresh pump, the derived-layer pump and the country read-view
    // consumer all silently stopped.
    //
    // The deferred 0x000 is CORRECT for a fresh start and stays untouched: there no
    // day has ever proven the handlers, which is exactly what the first-commit grant
    // below waits for. On a restart the POD state and the handlers are the same ones
    // that already earned the grant, and the domain stores are still aligned to this
    // host's committed day, so the proof carries over. The restore path above grants
    // on the same reasoning.
    //
    // Intersecting with the new `wanted` is deliberate: a domain the previous
    // lifetime never owned (e.g. IDEOLOGY while the mask was 0xFEF) is NOT granted
    // here and keeps the deferred path -- it has not been proven in this session.
    if (!restore_pending && mode == RuntimeSimulationMode::ACTIVE && wanted != 0u) {
        const uint32_t proven = lifetime_granted_mask() & wanted &
            implemented_domain_mask();
        if (proven != 0u) publish_authority_grant(proven);
    }
    // The worker store and ECP2 identity have already been installed and checked.
    // Restore the separate compatibility input before any executor can run.
    std::string compatibility_error;
    if (restored_country_checkpoint_valid && _economy_production_runtime != nullptr &&
        !EconomyAuthorityTransfer::restore_country_replica(*_economy_production_runtime,
            restored_country_checkpoint.compatibility_pkcn, compatibility_error)) {
        set_fault(compatibility_error.c_str());
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    if (restore_pending && has_ecp2 && mode == RuntimeSimulationMode::ACTIVE &&
        (wanted & runtime_domain_mask(RuntimeDomainId::ECONOMY)) != 0u &&
        _economy_auto_pod_active.load(std::memory_order_acquire) &&
        _economy_production_runtime != nullptr &&
        !EconomyAuthorityTransfer::bind_restored_owner(*_economy_production_runtime,
            _economy_pod_authority, compatibility_error)) {
        set_fault(compatibility_error.c_str());
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    _has_pending_restore = false;
    if (restore_pending && !_economy_pod_authority.restore_command_continuation(
            _pending_restore_bundle.economy_command_bytes, ecp2_apply_error)) {
        set_fault(ecp2_apply_error.c_str());
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    if (restore_pending && !restore_trigger_transport(_pending_restore_bundle.trigger_transport_bytes, ecp2_apply_error, true)) {
        set_fault(ecp2_apply_error.c_str()); return false;
    }
    _pending_restore_bundle = RuntimeSaveBundle{};
    for (auto &character : _fault_code) character.store('\0', std::memory_order_relaxed);
    // native_daily_inline：不要 worker 线程。日屏障改由调用线程逐日执行
    // （run_inline_day）。这里必须先把状态发布成 RUNNING —— 命令准入
    // （enqueue_batch）、`domain_grant_pending()` 的主线程抑制窗口、报告里的
    // state 都读它；留在 STOPPED 会让内联模式收不到任何命令、也不抑制主线程。
    //
    // 内联只对 ACTIVE 有意义：SHADOW 的定义就是"worker 侧影子对拍"，没有线程
    // 就没有影子可言。请求 inline+SHADOW 是调用方配置错误，按既有习惯用 fault
    // code 的可观测停止拒绝，而不是把 SHADOW 悄悄升级成 ACTIVE。
    if (inline_daily_mode()) {
        if (mode != RuntimeSimulationMode::ACTIVE) {
            _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
            _graph_coverage_complete.store(false, std::memory_order_release);
            _requested_authority_mask.store(0, std::memory_order_release);
            _authority_control.revoke();
            const char *fault = "inline_daily_requires_active";
            size_t fault_size = 0;
            for (; fault_size + 1 < _fault_code.size() && fault[fault_size] != '\0';
                 ++fault_size) {
                _fault_code[fault_size].store(fault[fault_size],
                                              std::memory_order_relaxed);
            }
            for (; fault_size < _fault_code.size(); ++fault_size)
                _fault_code[fault_size].store('\0', std::memory_order_relaxed);
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
        _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
        // 与 worker_main 入口对齐：计时区间从这里开始，否则 worker_time_* 恒为 0。
        _worker_timing.pause(paused);
        _worker_timing.start();
        _has_started_once.store(true, std::memory_order_release);
        return true;
    }
    try {
        _worker_returned = std::make_shared<std::atomic<bool>>(false);
        const auto returned = _worker_returned;
        _worker = std::thread([this, returned] {
            worker_main();
            // This final signal owns no host reference and performs no further
            // host access. A caller can now release the world, even on fault.
            returned->store(true, std::memory_order_release);
        });
    } catch (...) {
        _worker_returned->store(true, std::memory_order_release);
        // A failed thread creation must leave the host reusable.  Returning
        // false while keeping STARTING would make every later start look like
        // a forbidden hot switch and would strand the caller without a
        // lifecycle completion signal.
        _worker_fault_count.fetch_add(1, std::memory_order_relaxed);
        const char *fault = "worker_thread_create_failed";
        size_t fault_size = 0;
        for (; fault_size + 1 < _fault_code.size() && fault[fault_size] != '\0';
             ++fault_size) {
            _fault_code[fault_size].store(fault[fault_size],
                                          std::memory_order_relaxed);
        }
        for (; fault_size < _fault_code.size(); ++fault_size)
            _fault_code[fault_size].store('\0', std::memory_order_relaxed);
        _stop_requested.store(true, std::memory_order_release);
        _authority_control.revoke();
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    _has_started_once.store(true, std::memory_order_release);
    return true;
}

} // namespace pk
