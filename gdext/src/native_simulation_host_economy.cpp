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

void NativeSimulationHost::publish_economy_reference(
        int64_t day, uint64_t generation, uint64_t state_hash) noexcept {
    _economy_reference_day.store(day, std::memory_order_release);
    _economy_reference_generation.store(generation, std::memory_order_release);
    _economy_reference_hash.store(state_hash, std::memory_order_release);
}

void NativeSimulationHost::publish_economy_stage_reference(
        uint32_t stage, int64_t day, uint64_t generation, uint64_t state_hash,
        uint64_t work_units) noexcept {
    if (stage >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) return;
    _economy_stage_reference_hash[stage].store(state_hash,
                                               std::memory_order_release);
    _economy_stage_reference_work[stage].store(work_units,
                                               std::memory_order_release);
    _economy_stage_reference_present[stage].store(1, std::memory_order_release);
    if (stage == static_cast<uint32_t>(RuntimeEconomyGraphStage::BUILDING_PLAN)) {
        publish_economy_reference(day, generation, state_hash);
    }
}

void NativeSimulationHost::attach_economy_stage_ops(
        std::unique_ptr<EconomyGraphStageOps> ops) noexcept {
    _economy_stage_ops = std::move(ops);
    _economy_pod_authority.attach_stage_ops(_economy_stage_ops.get());
}

void NativeSimulationHost::set_economy_execution_mode(
        EconomyExecutionMode mode) noexcept {
    _economy_execution_mode.store(static_cast<uint32_t>(mode),
                                  std::memory_order_release);
    // ACTIVE_WITH_PARITY is the only mode that runs SHADOW StageOps.
    // ACTIVE_ONLY / LEGACY_ONLY keep probe work at zero.
    const bool parity =
        mode == EconomyExecutionMode::ACTIVE_WITH_PARITY;
    _economy_shadow_probe_enabled.store(parity, std::memory_order_release);
    if (!parity) {
        _economy_shadow_cache_valid = false;
        _economy_shadow_cache_day = -1;
        _economy_shadow_cache_input_generation = 0;
        _economy_shadow_cache_country_generation = 0;
        _economy_shadow_cache_catalog_hash = 0;
    }
    if (mode == EconomyExecutionMode::LEGACY_ONLY) {
        // Detach production runner so main-thread sync remains the writer.
        attach_economy_production_runtime(nullptr);
    }
}

bool NativeSimulationHost::switch_economy_authority(
        RuntimeEconomyAuthorityMode mode, std::string &error) noexcept {
    // Hold the boundary lock for the complete check + mode mutation + audit.
    // The worker takes the same lock around execute_day_plan/publish_day, so
    // an observed idle boundary cannot be invalidated by the next day starting
    // between the check and the actual authority change.
    //
    // CRITICAL: never block the Godot main thread on this lock. The worker may
    // hold it while parked on Country peer / environment input that only the
    // main thread can service. A blocking lock here deadlocks the whole game
    // with no fault/output (main stuck, worker stuck).
    std::unique_lock<std::mutex> boundary_lock(
        _economy_authority_boundary_mutex, std::try_to_lock);
    const uint64_t switch_started_us = now_us();
    error.clear();
    auto remember_blocker = [&](const char *reason) noexcept {
        const char *value = reason ? reason : "unknown";
        size_t i = 0;
        for (; i + 1 < _economy_authority_switch_blocker.size() && value[i] != '\0'; ++i)
            _economy_authority_switch_blocker[i].store(value[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_blocker.size(); ++i)
            _economy_authority_switch_blocker[i].store('\0', std::memory_order_relaxed);
    };
    auto remember_reason = [&](const char *reason) noexcept {
        const char *value = reason ? reason : "unknown";
        size_t i = 0;
        for (; i + 1 < _economy_authority_switch_reason.size() && value[i] != '\0'; ++i)
            _economy_authority_switch_reason[i].store(value[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_reason.size(); ++i)
            _economy_authority_switch_reason[i].store('\0', std::memory_order_relaxed);
    };
    if (!boundary_lock.owns_lock()) {
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        remember_blocker("worker_day_lock_busy");
        error = "economy_authority_switch_requires_epoch_boundary";
        remember_reason(error.c_str());
        return false;
    }
    if (try_fault_injection("authority.switch.before")) {
        error = "economy_authority_switch_fault_injected_before";
        return false;
    }
    const RuntimeEconomyAuthorityMode current = _economy_pod_authority.authority_mode();
    const RuntimeWorkerState worker_state = state();
    if (worker_state == RuntimeWorkerState::FAULTED) {
        // A faulted worker must remain parked on its last committed snapshot;
        // authority cannot move while an unsafe partial mutation may exist.
        _economy_authority_fault_paused.store(true, std::memory_order_release);
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        remember_blocker("worker_fault_paused_committed_snapshot");
        error = "economy_authority_switch_worker_fault_paused";
        remember_reason(error.c_str());
        return false;
    }
    if (worker_state == RuntimeWorkerState::STOPPING ||
        worker_state == RuntimeWorkerState::SAVE_PENDING) {
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        remember_blocker("worker_lifecycle_not_at_boundary");
        error = "economy_authority_switch_requires_epoch_boundary";
        remember_reason(error.c_str());
        return false;
    }
    const bool command_queue_pending =
        _command_enqueue_pos.load(std::memory_order_acquire) !=
        _command_dequeue_pos.load(std::memory_order_acquire);
    const uint32_t worker_day_inflight =
        _worker_day_inflight.load(std::memory_order_acquire);
    const uint32_t economy_inflight =
        _economy_inflight_mutations.load(std::memory_order_acquire);
    const uint32_t worker_pending =
        _economy_pending_command_count.load(std::memory_order_acquire);
    if (static_cast<StageOpsDayPhase>(_stage_ops_day_phase_atomic.load(
            std::memory_order_acquire)) != StageOpsDayPhase::Done ||
        _economy_pod_pending_outbox.load(std::memory_order_acquire) != 0 ||
        _economy_pod_pending_inbox.load(std::memory_order_acquire) != 0 ||
        command_queue_pending || worker_day_inflight != 0 ||
        economy_inflight != 0 || worker_pending != 0) {
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        const char *blocker = command_queue_pending
            ? "pending_command_queue"
            : (worker_pending != 0 ? "pending_worker_command"
               : (economy_inflight != 0 ? "economy_mutation_inflight"
                  : (worker_day_inflight != 0 ? "worker_day_inflight"
                     : "pending_epoch_mutation")));
        remember_blocker(blocker);
        error = "economy_authority_switch_requires_epoch_boundary";
        remember_reason(error.c_str());
        return false;
    }
    // Idempotent requests are safe once the worker is healthy and idle; keep
    // the fault/lifecycle/pending-work checks authoritative even for same-mode
    // calls.
    if (current == mode) return true;
    const uint64_t before_hash = _economy_pod_authority.state_hash();
    const uint64_t before_generation =
        _economy_pod_authority.committed_ledger_state().generation;
    const auto record_switch = [&]() noexcept {
        const uint64_t after_hash = _economy_pod_authority.state_hash();
        const uint64_t after_generation =
            _economy_pod_authority.committed_ledger_state().generation;
        _economy_authority_switch_count.fetch_add(1, std::memory_order_relaxed);
        _economy_authority_switch_audit_sequence.fetch_add(
            1u, std::memory_order_acq_rel);
        _economy_authority_switch_before_hash.store(before_hash, std::memory_order_release);
        _economy_authority_switch_after_hash.store(after_hash, std::memory_order_release);
        _economy_authority_switch_before_generation.store(before_generation, std::memory_order_release);
        _economy_authority_switch_after_generation.store(after_generation, std::memory_order_release);
        _economy_authority_last_committed_generation.store(after_generation, std::memory_order_release);
        _economy_authority_last_committed_hash.store(after_hash, std::memory_order_release);
        const char *reason = "epoch_boundary_authority_switch";
        size_t i = 0;
        remember_reason(reason);
        char audit[128];
        std::snprintf(audit, sizeof(audit), "mode=%u generation=%llu hash=%llu",
                      static_cast<unsigned>(current),
                      static_cast<unsigned long long>(before_generation),
                      static_cast<unsigned long long>(before_hash));
        i = 0;
        for (; i + 1 < _economy_authority_switch_audit_before.size() && audit[i] != '\0'; ++i)
            _economy_authority_switch_audit_before[i].store(audit[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_audit_before.size(); ++i)
            _economy_authority_switch_audit_before[i].store('\0', std::memory_order_relaxed);
        std::snprintf(audit, sizeof(audit), "mode=%u generation=%llu hash=%llu",
                      static_cast<unsigned>(mode),
                      static_cast<unsigned long long>(after_generation),
                      static_cast<unsigned long long>(after_hash));
        i = 0;
        for (; i + 1 < _economy_authority_switch_audit_after.size() && audit[i] != '\0'; ++i)
            _economy_authority_switch_audit_after[i].store(audit[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_audit_after.size(); ++i)
            _economy_authority_switch_audit_after[i].store('\0', std::memory_order_relaxed);
        remember_blocker("");
        const uint64_t completed_at = now_us();
        const uint64_t switch_latency = completed_at >= switch_started_us
            ? completed_at - switch_started_us : 0u;
        const uint64_t admitted_at =
            _last_command_admitted_us.load(std::memory_order_acquire);
        const uint64_t command_latency =
            admitted_at != 0 && completed_at >= admitted_at
                ? completed_at - admitted_at : 0u;
        _economy_authority_switch_latency_us.store(
            switch_latency, std::memory_order_release);
        _economy_authority_switch_command_latency_us.store(
            command_latency, std::memory_order_release);
        uint64_t audit_hash = mix_hash(before_hash, after_hash);
        audit_hash = mix_hash(audit_hash, before_generation);
        audit_hash = mix_hash(audit_hash, after_generation);
        audit_hash = mix_hash(audit_hash, static_cast<uint64_t>(current));
        audit_hash = mix_hash(audit_hash, static_cast<uint64_t>(mode));
        audit_hash = mix_hash(audit_hash, switch_latency);
        _economy_authority_switch_audit_hash.store(
            audit_hash, std::memory_order_release);
        // Keep a bounded sample history for p95/max reporting. The write
        // cursor is advanced only after both slots are visible, so a report
        // observing the new count can never include an uninitialised sample.
        const uint64_t sample_sequence =
            _economy_authority_switch_latency_sample_write.load(
                std::memory_order_relaxed);
        const size_t sample_slot = static_cast<size_t>(
            sample_sequence % ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY);
        _economy_authority_switch_latency_samples[sample_slot].store(
            switch_latency, std::memory_order_relaxed);
        _economy_authority_switch_command_latency_samples[sample_slot].store(
            command_latency, std::memory_order_relaxed);
        _economy_authority_switch_latency_sample_write.store(
            sample_sequence + 1u, std::memory_order_release);
        const uint64_t sample_count = std::min<uint64_t>(
            sample_sequence + 1u,
            ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY);
        _economy_authority_switch_latency_sample_count.store(
            sample_count, std::memory_order_release);
    };
    switch (mode) {
    case RuntimeEconomyAuthorityMode::LEGACY_SYNC:
        if (_economy_production_runtime != nullptr &&
            _economy_production_runtime->formula_owned_bound()) {
            _economy_production_runtime->unbind_formula_owned_state();
        }
        _economy_pod_authority.set_authority_mode(mode);
        record_switch();
        if (try_fault_injection("authority.switch.after")) {
            error = "economy_authority_switch_fault_injected_after";
            return false;
        }
        return true;
    case RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY:
        // Parity soak may run against the committed cohort/market mirror.
        // Production mutations stay on NativeEconomyRuntime; POD mirrors them.
        _economy_pod_authority.set_authority_mode(mode);
        record_switch();
        if (try_fault_injection("authority.switch.after")) {
            error = "economy_authority_switch_fault_injected_after";
            return false;
        }
        return true;
    case RuntimeEconomyAuthorityMode::POD_ACTIVE:
        // Phase-2.3.3 completes the committed mirror feature mask (ECP ABI9).
        // Still refuse until a live capture has set every REQUIRED_FOR_ACTIVE
        // bit. Phase-5 A+Y: bind NER population/market to OwnedState so
        // StageOps formulas mutate the sole SoA instance.
        if (!_economy_pod_authority.pod_active_ready()) {
            error = "economy_pod_active_incomplete_ledger_mirror";
            remember_blocker("economy_pod_active_incomplete_ledger_mirror");
            remember_reason(error.c_str());
            return false;
        }
        if (_economy_production_runtime != nullptr &&
            !_economy_production_runtime->formula_owned_bound()) {
                if (!_economy_production_runtime->bind_formula_owned_state(
                    _economy_pod_authority.state(), error)) {
                remember_blocker(error.c_str());
                remember_reason(error.c_str());
                return false;
            }
        }
        _economy_pod_authority.set_authority_mode(mode);
        record_switch();
        if (try_fault_injection("authority.switch.after")) {
            error = "economy_authority_switch_fault_injected_after";
            return false;
        }
        return true;
    }
    error = "economy_authority_mode_invalid";
    return false;
}

bool NativeSimulationHost::economy_authority_fault_gate_self_test(
        std::string &error) const noexcept {
    error.clear();
    if (!EconomyInvariantProbe::run(error)) return false;
    // 遗留 AI 包的终态可供收尾/保存查询，但不能污染玩家回执流。
    const auto receipt_probe = std::make_unique<NativeSimulationHost>();
    RuntimeCountryCommand old_ai;
    old_ai.request_id = 1;
    old_ai.producer_id = COUNTRY_AI_PRODUCER_ID;
    old_ai.sequence = 131072;
    old_ai.effective_day = 2;
    receipt_probe->publish_country_command_terminals({old_ai},
        CountryCommandReceiptCode::COMMITTED, 3, nullptr);
    if (!receipt_probe->_country_command_terminals.empty()) {
        error = "worker_ai_internal_commands_became_player_terminals";
        return false;
    }
    for (int repeat = 0; repeat < 2; ++repeat)
        receipt_probe->publish_country_command_terminals({old_ai},
            CountryCommandReceiptCode::REJECTED_AT_EXECUTION, 10838,
            "country_ai_superseded_by_worker", true);
    CountryCommandReceipt terminal;
    std::vector<CountryCommandReceipt> player_receipts;
    if (!receipt_probe->try_country_command_terminal(1, terminal) ||
        terminal.code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
        terminal.reason != "country_ai_superseded_by_worker" ||
        receipt_probe->_country_command_terminals.size() != 1u ||
        !receipt_probe->poll_country_command_receipts(0, 8, player_receipts) ||
        !player_receipts.empty()) {
        error = "superseded_ai_terminal_not_idempotent_or_leaked";
        return false;
    }
    RuntimeCountryCommand player = old_ai;
    player.request_id = 2;
    player.producer_id = 0;
    receipt_probe->publish_country_command_terminals({player},
        CountryCommandReceiptCode::COMMITTED, 10839, nullptr);
    if (!receipt_probe->poll_country_command_receipts(0, 8, player_receipts) ||
        player_receipts.size() != 1u || player_receipts[0].request_id != 2) {
        error = "superseded_ai_terminal_filter_hid_player_receipt";
        return false;
    }
    // Unlike worker-local AI, a synchronous AI mirror owns an admitted Host
    // packet. Its terminal must retire that packet without entering the UI
    // receipt stream; otherwise the old enqueue repeats on every worker day.
    RuntimeCountryCommand mirrored_ai = old_ai;
    mirrored_ai.request_id = 3;
    CountryCommandReceipt admitted_ai;
    admitted_ai.request_id = mirrored_ai.request_id;
    admitted_ai.producer_id = COUNTRY_AI_PRODUCER_ID;
    admitted_ai.code = CountryCommandReceiptCode::ACCEPTED;
    receipt_probe->_country_command_states.emplace(3, admitted_ai);
    for (int repeat = 0; repeat < 2; ++repeat)
        receipt_probe->publish_country_command_terminals({mirrored_ai},
            CountryCommandReceiptCode::COMMITTED, 10840, nullptr);
    if (!receipt_probe->try_country_command_terminal(3, terminal) ||
        terminal.code != CountryCommandReceiptCode::COMMITTED ||
        receipt_probe->_country_command_terminals.size() != 3u ||
        !receipt_probe->poll_country_command_receipts(0, 8, player_receipts) ||
        player_receipts.size() != 1u || player_receipts[0].request_id != 2) {
        error = "mirrored_ai_terminal_not_retired_or_leaked";
        return false;
    }
    // First exercise the epoch-boundary half on a worker-shaped host without
    // starting a thread.  The switch must observe the explicit in-flight
    // counters even when the command ring itself is empty.
    const auto boundary_probe = std::make_unique<NativeSimulationHost>();
    boundary_probe->_state.store(RuntimeWorkerState::RUNNING,
                                  std::memory_order_release);
    boundary_probe->_worker_day_inflight.store(1u, std::memory_order_release);
    std::string boundary_error;
    if (boundary_probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            boundary_error) ||
        boundary_error != "economy_authority_switch_requires_epoch_boundary") {
        error = "economy_authority_inflight_switch_not_rejected";
        return false;
    }
    boundary_probe->_worker_day_inflight.store(0u, std::memory_order_release);
    boundary_probe->_economy_pending_command_count.store(1u, std::memory_order_release);
    if (boundary_probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            boundary_error)) {
        error = "economy_authority_pending_command_gate_weakened";
        return false;
    }
    boundary_probe->_economy_pending_command_count.store(0u, std::memory_order_release);
    boundary_probe->_state.store(RuntimeWorkerState::PAUSED,
                                  std::memory_order_release);
    boundary_error.clear();
    if (!boundary_probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            boundary_error) ||
        boundary_probe->_economy_authority_switch_audit_sequence.load(
            std::memory_order_acquire) != 1u) {
        error = "economy_authority_idle_switch_not_audited";
        return false;
    }
    // Keep this probe isolated: constructing a temporary host does not start a
    // thread, and the live host (if any) remains untouched.
    const auto probe = std::make_unique<NativeSimulationHost>();
    probe->_authority_control.begin_lifetime();
    probe->_mode.store(RuntimeSimulationMode::ACTIVE, std::memory_order_release);
    probe->_state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
    probe->_committed_day.store(7, std::memory_order_release);
    probe->publish_authority_grant(runtime_domain_mask(RuntimeDomainId::CLIMATE));
    auto control = probe->control_state();
    if (control.authority_ready || control.committed_day != 7 ||
        control.authoritative_domain_mask != runtime_domain_mask(RuntimeDomainId::CLIMATE)) {
        error = "runtime_control_partial_grant_not_visible";
        return false;
    }
    probe->request_stop();
    if (probe->control_state().authoritative_domain_mask != 0u) {
        error = "runtime_control_stop_did_not_revoke";
        return false;
    }
    // Model a commit tail that runs after stop has already revoked the grant.
    probe->publish_authority_grant(probe->lifetime_granted_mask());
    probe->_authority_control.mark_graph_ready();
    if (probe->control_state().authoritative_domain_mask != 0u ||
        probe->control_state().authority_ready) {
        error = "runtime_control_late_commit_reopened_stopped_lifetime";
        return false;
    }
    probe->_authority_control.begin_lifetime();
    probe->_state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
    probe->publish_authority_grant(probe->lifetime_granted_mask());
    if (probe->control_state().authoritative_domain_mask !=
            runtime_domain_mask(RuntimeDomainId::CLIMATE)) {
        error = "runtime_control_restart_grant_not_visible";
        return false;
    }
    probe->set_fault("self_test_worker_fault");
    probe->request_stop();
    probe->publish_authority_grant(probe->lifetime_granted_mask());
    probe->_authority_control.mark_graph_ready();
    if (probe->state() != RuntimeWorkerState::FAULTED ||
        probe->control_state().state != RuntimeWorkerState::FAULTED ||
        probe->control_state().authoritative_domain_mask != 0u ||
        probe->control_state().authority_ready ||
        probe->control_state().committed_day != 7 ||
        !probe->_economy_authority_fault_paused.load(std::memory_order_acquire)) {
        error = "economy_authority_fault_pause_not_armed";
        return false;
    }
    std::string switch_error;
    if (probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            switch_error) ||
        switch_error != "economy_authority_switch_worker_fault_paused") {
        error = "economy_authority_fault_switch_not_rejected";
        return false;
    }
    const uint64_t committed_generation =
        probe->_economy_authority_last_committed_generation.load(
            std::memory_order_acquire);
    const uint64_t committed_hash =
        probe->_economy_authority_last_committed_hash.load(
            std::memory_order_acquire);
    if (committed_generation !=
            probe->_economy_pod_authority.committed_ledger_state().generation ||
        committed_hash != probe->_economy_pod_authority.state_hash()) {
        error = "economy_authority_fault_snapshot_not_retained";
        return false;
    }
    return true;
}

// Opens the D7 asset gates the current Country/Economy grant requires. Only
// ever widens the mask. Attach and every worker ECONOMY visit both call it: a
// new game is promoted to worker authority after attach, and ACTIVE never runs
// the main-thread runtime-graph pulse that would otherwise mirror the grant,
// so without the per-day refresh expedition procurement stays gate-closed.
void open_granted_economy_d7_gates(
        const NativeSimulationHost &host, NativeEconomyRuntime &rt) noexcept {
    if (host.domain_is_worker_authoritative(RuntimeDomainId::ECONOMY)) {
        rt.open_all_d7_operation_gates();
    } else if (host.domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) ||
               host.country_authority_owner_is_worker()) {
        rt.open_research_purchase_d7_gate();
        rt.open_country_market_purchase_d7_gates();
    } else {
        rt.open_research_purchase_d7_gate();
    }
}

void NativeSimulationHost::attach_economy_production_runtime(
        NativeEconomyRuntime *rt) noexcept {
    if (rt != nullptr &&
        economy_execution_mode() == EconomyExecutionMode::LEGACY_ONLY) {
        // LEGACY_ONLY forbids worker production attach; keep sync authority.
        rt = nullptr;
    }
    _economy_production_runtime = rt;
    if (rt != nullptr) {
        // Production may run on the worker before the first main-thread
        // sync_runtime_domain_ownership pulse. Open research (and full D7 when
        // Economy is ACTIVE) here so government procurement is not soft-gated
        // for the entire early game.
        open_granted_economy_d7_gates(*this, *rt);
        class NativeEconomyPodCommandExecutor final
            : public EconomyPodCommandExecutor {
        public:
            NativeEconomyPodCommandExecutor(
                NativeEconomyRuntime *runtime,
                RuntimeEconomyPodAuthority *authority)
                : _runtime(runtime), _authority(authority) {}
            bool apply(const RuntimeEconomyPodCommand &command,
                       std::string &error) override {
                if (_runtime == nullptr) {
                    error = "economy_pod_executor_runtime_null";
                    return false;
                }
                // Phase-3: under POD_ACTIVE, opcodes 1–23 mutate OwnedState
                // first, then pull into NativeEconomyRuntime.
                if (_authority != nullptr &&
                    _authority->authority_mode() ==
                        RuntimeEconomyAuthorityMode::POD_ACTIVE &&
                    RuntimeEconomyPodAuthority::is_owned_command_opcode(
                        command.opcode) &&
                    _authority->state_initialized()) {
                    int64_t settled = 0;
                    if (!_authority->try_apply_owned_core_command(
                            command, error, settled)) {
                        return false;
                    }
                    if (!_runtime->pull_owned_command_result(
                            _authority->state(), command, settled, error)) {
                        return false;
                    }
                    return true;
                }
                return _runtime->apply_pod_command(command, error);
            }

        private:
            NativeEconomyRuntime *_runtime = nullptr;
            RuntimeEconomyPodAuthority *_authority = nullptr;
        };
        _economy_pod_command_executor =
            std::make_unique<NativeEconomyPodCommandExecutor>(
                rt, &_economy_pod_authority);
        _economy_pod_authority.attach_command_executor(
            _economy_pod_command_executor.get());
        _economy_pod_authority.sync_identity(
            1u, rt->committed_generation());
    } else {
        _economy_pod_authority.attach_command_executor(nullptr);
        _economy_pod_command_executor.reset();
    }
}

bool NativeSimulationHost::submit_economy_pod_command(
        const RuntimeEconomyPodCommand &command, std::string &error) {
    return _economy_pod_authority.queue_command(command, error);
}

bool NativeSimulationHost::poll_economy_pod_receipt(
        RuntimeEconomyPodReceipt &out) noexcept {
    return _economy_pod_authority.poll_receipt(out);
}

void NativeSimulationHost::set_economy_sync_writes_forbidden(
        bool forbidden) noexcept {
    _economy_sync_writes_forbidden.store(forbidden, std::memory_order_release);
}

bool NativeSimulationHost::worker_run_stage_ops_slice(
        int64_t day, uint64_t input_generation, std::string &error, bool *done,
        bool *pending_input) {
    error.clear();
    if (done != nullptr) {
        *done = false;
    }
    if (pending_input != nullptr) {
        *pending_input = false;
    }
    if (_economy_production_runtime == nullptr || _economy_stage_ops == nullptr) {
        error = "economy_stage_ops_runtime_missing";
        return false;
    }
    if (!economy_stage_ops_mutate()) {
        error = "economy_stage_ops_mutate_required";
        return false;
    }
    if (day < 0) {
        error = "economy_stage_ops_day_invalid";
        return false;
    }

    // New calendar day resets the StageOps Host continuation machine — unless
    // the previous day's epoch is still open. The ECONOMY stage deliberately
    // soft-completes a day on Country-asset backpressure so Climate keeps
    // draining its input ring, which means a fiscal/research continuation can
    // legitimately cross a day boundary. Resetting to Prelude then sent the
    // next pulse into PlanEpoch against that still-open epoch and faulted the
    // worker with economy_pod_epoch_busy. Keep advancing the open epoch.
    if (_stage_ops_day_index != day ||
        _stage_ops_day_input_generation != input_generation) {
        const bool epoch_still_open =
            _economy_pod_authority.planned_epoch_active() &&
            (_stage_ops_day_phase == StageOpsDayPhase::AdvanceStages ||
             _stage_ops_day_phase == StageOpsDayPhase::CommitEpoch);
        _stage_ops_day_index = day;
        _stage_ops_day_input_generation = input_generation;
        if (!epoch_still_open) {
            _stage_ops_day_phase = StageOpsDayPhase::Prelude;
            _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Prelude), std::memory_order_release);
        }
    }

    switch (_stage_ops_day_phase) {
    case StageOpsDayPhase::Prelude: {
        const auto prelude_started = std::chrono::steady_clock::now();
        int64_t prelude_work = 0;
        bool pending = false;
        bool idle_done = false;
        if (!_economy_production_runtime->run_epoch_open_prelude_drain(
                day, prelude_work, error, &pending, &idle_done)) {
            return false;
        }
        if (day % 100 == 0) std::fprintf(stderr, "[economy-prelude-cost] day=%lld ms=%.3f pending=%d\n", static_cast<long long>(day), std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - prelude_started).count(), pending);
        if (pending) {
            if (pending_input != nullptr) {
                *pending_input = true;
            }
            return true;
        }
        if (idle_done &&
            !_economy_production_runtime->stage_ops_epoch_open_ready()) {
            _stage_ops_day_phase = StageOpsDayPhase::Done;
            _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Done), std::memory_order_release);
            if (done != nullptr) {
                *done = true;
            }
            return true;
        }
        if (!_economy_production_runtime->stage_ops_epoch_open_ready()) {
            error = "economy_stage_ops_prelude_incomplete";
            return false;
        }
        _stage_ops_day_phase = StageOpsDayPhase::PlanEpoch;
        _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::PlanEpoch), std::memory_order_release);
        return true;
    }
    case StageOpsDayPhase::PlanEpoch: {
        if (try_fault_injection("economy.plan.before")) {
            error = "economy_plan_fault_injected_before";
            return false;
        }
        _economy_pod_authority.attach_stage_ops(_economy_stage_ops.get());
        RuntimeEconomyEpochInput input;
        input.sample_day = EconomyAuthorityTransfer::sample_day(*_economy_production_runtime);
        input.stage_hashes_enabled = economy_parity_shadow_enabled();
        input.session_epoch = 1;
        input.economy_generation =
            _economy_production_runtime->committed_generation();
        input.input_generation =
            input_generation != 0
                ? input_generation
                : _economy_production_runtime->committed_generation();
        input.country_generation =
            _economy_production_runtime->committed_generation();
        input.catalog_hash =
            _economy_production_runtime->committed_generation();
        input.policy_hash = input.country_generation;
        input.environment_shape_hash =
            input.catalog_hash ^
            static_cast<uint64_t>(std::max(
                0, _economy_production_runtime->cell_count()));
        input.cell_count = static_cast<uint32_t>(std::max(
            0, _economy_production_runtime->cell_count()));
        input.market_cycle_days = 5;
        input.production_cycle_days = 10;
        input.investment_cycle_days = 20;
        input.valid = input.cell_count > 0 && input.input_generation != 0;
        if (!_economy_pod_authority.plan_epoch(input, error)) {
            return false;
        }
        if (try_fault_injection("economy.plan.after")) {
            error = "economy_plan_fault_injected_after";
            return false;
        }
        _stage_ops_day_phase = StageOpsDayPhase::AdvanceStages;
        _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::AdvanceStages), std::memory_order_release);
        return true;
    }
    case StageOpsDayPhase::AdvanceStages: {
        if (try_fault_injection("economy.reservation.before")) {
            error = "economy_reservation_fault_injected_before";
            return false;
        }
        if (!_economy_pod_authority.advance_stage(error)) {
            // Tax settlement parks on Country-peer return/collect. This is
            // backpressure for Host prepare+retry, not an Economy ledger fatal.
            // Treating it as fatal left production StageOps stuck mid-epoch the
            // moment a non-zero national tax created fiscal collect work.
            if (error == "fiscal_settlement_peer_pending" ||
                error == "fiscal_reserve_peer_results" ||
                error == "country_research_peer_results" ||
                runtime_country_asset_pending_reason(error)) {
                if (pending_input != nullptr) {
                    *pending_input = true;
                }
                return true;
            }
            return false;
        }
        if (try_fault_injection("economy.reservation.after")) {
            error = "economy_reservation_fault_injected_after";
            return false;
        }
        if (_economy_pod_authority.planned_stage_index() >=
            RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) {
            _stage_ops_day_phase = StageOpsDayPhase::CommitEpoch;
            _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::CommitEpoch), std::memory_order_release);
        }
        return true;
    }
    case StageOpsDayPhase::CommitEpoch: {
        if (try_fault_injection("economy.commit.before")) {
            error = "economy_commit_fault_injected_before";
            return false;
        }
        if (!_economy_pod_authority.commit_epoch(error)) {
            return false;
        }
        const auto &replay = _economy_pod_authority.replay_report();
        for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
            _economy_replay_stage_ms[i].store(replay.stage_ms[i], std::memory_order_release);
            _economy_replay_stage_work[i].store(replay.stage_work[i], std::memory_order_release);
            _economy_replay_stage_hash[i].store(replay.stage_hash[i], std::memory_order_release);
        }
        if (try_fault_injection("economy.commit.after")) {
            error = "economy_commit_fault_injected_after";
            return false;
        }
        _stage_ops_day_phase = StageOpsDayPhase::Done;
        _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Done), std::memory_order_release);
        if (done != nullptr) {
            *done = true;
        }
        return true;
    }
    case StageOpsDayPhase::Done:
        if (done != nullptr) {
            *done = true;
        }
        return true;
    }
    error = "economy_stage_ops_day_phase_invalid";
    return false;
}

bool NativeSimulationHost::execute_economy_worker_stage(
        int64_t day, uint64_t input_generation, uint32_t cell_count,
        uint64_t country_generation, uint64_t catalog_hash,
        std::string &error) {
    error.clear();
    // Economy POD graph orchestration for SHADOW parity. Production mutations
    // still use worker_run_compact_slice; StageOps mutate may be armed for
    // Phase-2.4 handoff experiments without replacing that loop yet.
    if (!economy_parity_shadow_enabled()) {
        error = "economy_shadow_stage_disabled";
        return false;
    }
    if (cell_count == 0 || input_generation == 0 || day < 0) {
        error = "economy_worker_stage_input_invalid";
        return false;
    }
    // Reuse stage results for the same frozen (day, input_generation) workset.
    if (_economy_shadow_cache_valid &&
        _economy_shadow_cache_day == day &&
        _economy_shadow_cache_input_generation == input_generation &&
        _economy_shadow_cache_country_generation == country_generation &&
        _economy_shadow_cache_catalog_hash == catalog_hash) {
        _economy_shadow_stage_cache_hits.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    _economy_shadow_stage_invocations.fetch_add(1, std::memory_order_relaxed);
    // Phase-2.4.4.1: when StageOps mutate is armed against the live runtime,
    // open the epoch (trade planner / start_epoch) before POD plan_epoch.
    // ACTIVE_WITH_PARITY coerces mutate=false, so this is experimental-only.
    if (economy_stage_ops_mutate() && _economy_production_runtime != nullptr) {
        int64_t prelude_work = 0;
        bool pending_input = false;
        bool idle_done = false;
        if (!_economy_production_runtime->run_epoch_open_prelude_drain(
                day, prelude_work, error, &pending_input, &idle_done)) {
            return false;
        }
        if (pending_input) {
            if (error.empty()) {
                error = "economy_stage_ops_prelude_pending_input";
            }
            return false;
        }
        if (idle_done &&
            !_economy_production_runtime->stage_ops_epoch_open_ready()) {
            // No economy cycle to open; SHADOW probe has nothing to advance.
            return true;
        }
        if (!_economy_production_runtime->stage_ops_epoch_open_ready()) {
            error = "economy_stage_ops_prelude_incomplete";
            return false;
        }
    }
    RuntimeEconomyEpochInput input;
    input.sample_day = day;
    input.session_epoch = 1;
    input.economy_generation =
        _economy_pod_generation.load(std::memory_order_acquire);
    input.input_generation = input_generation;
    input.country_generation = country_generation;
    input.catalog_hash = catalog_hash;
    input.policy_hash = country_generation;
    input.environment_shape_hash = catalog_hash ^ cell_count;
    input.cell_count = cell_count;
    input.market_cycle_days = 5;
    input.production_cycle_days = 10;
    input.investment_cycle_days = 20;
    input.valid = true;

    _economy_pod_authority.reset();
    _economy_pod_authority.attach_stage_ops(_economy_stage_ops.get());
    for (uint32_t stage = 0; stage < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++stage) {
        if (_economy_stage_reference_present[stage].load(
                std::memory_order_acquire) == 0) {
            continue;
        }
        _economy_pod_authority.set_stage_reference(
            static_cast<RuntimeEconomyGraphStage>(stage), day,
            _economy_reference_generation.load(std::memory_order_acquire),
            _economy_stage_reference_hash[stage].load(std::memory_order_acquire),
            _economy_stage_reference_work[stage].load(std::memory_order_acquire));
    }
    if (!_economy_pod_authority.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        if (!_economy_pod_authority.advance_stage(error)) return false;
    }
    if (!_economy_pod_authority.commit_epoch(error)) return false;

    const RuntimeEconomyPodReplayReport &replay =
        _economy_pod_authority.replay_report();
    _economy_replay_completed_stage_mask.store(replay.completed_stage_mask,
                                               std::memory_order_release);
    _economy_replay_stage_cursor.store(replay.stage_cursor,
                                       std::memory_order_release);
    _economy_replay_input_hash.store(replay.input_hash,
                                     std::memory_order_release);
    _economy_replay_base_hash.store(replay.base_hash, std::memory_order_release);
    _economy_replay_next_hash.store(replay.next_hash, std::memory_order_release);
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        _economy_replay_stage_hash[i].store(replay.stage_hash[i],
                                            std::memory_order_release);
        _economy_replay_stage_work[i].store(replay.stage_work[i],
                                            std::memory_order_release);
        _economy_replay_stage_ms[i].store(replay.stage_ms[i],
                                          std::memory_order_release);
    }
    _economy_replay_input_captured.store(replay.input_captured != 0,
                                         std::memory_order_release);
    _economy_replay_committed.store(replay.committed != 0,
                                    std::memory_order_release);
    _economy_replay_parity_ready.store(replay.parity_ready != 0,
                                       std::memory_order_release);
    _economy_pod_parity_ready_mask.store(replay.parity_ready_mask,
                                         std::memory_order_release);

    RuntimeEconomyCommittedSnapshot snap;
    std::string snap_error;
    if (_economy_pod_authority.snapshot(snap, snap_error)) {
        _economy_pod_ready.store(true, std::memory_order_release);
        _economy_pod_committed.store(snap.committed, std::memory_order_release);
        _economy_pod_authority_ready.store(snap.authority_ready,
                                          std::memory_order_release);
        _economy_pod_committed_day.store(snap.committed_day,
                                         std::memory_order_release);
        _economy_pod_epoch_sample_day.store(snap.epoch_sample_day,
                                            std::memory_order_release);
        _economy_pod_generation.store(snap.generation, std::memory_order_release);
        _economy_pod_state_hash.store(snap.state_hash, std::memory_order_release);
        _economy_pod_input_generation.store(snap.input_generation,
                                            std::memory_order_release);
        _economy_pod_country_generation.store(snap.country_generation,
                                              std::memory_order_release);
        _economy_pod_completed_stage_mask.store(snap.completed_stage_mask,
                                                std::memory_order_release);
        _economy_pod_pending_outbox.store(snap.pending_outbox,
                                          std::memory_order_release);
        _economy_pod_pending_inbox.store(snap.pending_inbox,
                                         std::memory_order_release);
        _economy_pod_operation_gate_mask.store(snap.operation_gate_mask,
                                               std::memory_order_release);
        _economy_pod_parity_ready_mask.store(
            _economy_pod_authority.parity_ready_mask(),
            std::memory_order_release);
    }
    _economy_shadow_cache_day = day;
    _economy_shadow_cache_input_generation = input_generation;
    _economy_shadow_cache_country_generation = country_generation;
    _economy_shadow_cache_catalog_hash = catalog_hash;
    _economy_shadow_cache_valid = true;
    return true;
}

} // namespace pk
