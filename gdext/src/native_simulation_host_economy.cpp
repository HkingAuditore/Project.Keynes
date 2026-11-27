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

#include "native_simulation_host_economy_section_authority_switch.inc"

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
