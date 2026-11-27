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

#include "native_simulation_host_ideology_section_parity.inc"

bool NativeSimulationHost::configure_ideology_pod(
        const RuntimeIdeologyPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "ideology_pod_configure_while_running";
        return false;
    }
    RuntimeIdeologyPodAuthority candidate;
    if (!candidate.configure(catalog, error)) return false;
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    _ideology_pod_authority = std::move(candidate);
    _ideology_pod_catalog = catalog;
    _ideology_pod_catalog.catalog_hash = _ideology_pod_authority.catalog_hash();
    _ideology_pod_configured = true;
    _ideology_reference_opinions.clear();
    _ideology_commands.clear();
    _ideology_intents.clear();
    _ideology_acks.clear();
    _ideology_modifier_inflight.clear();
    _ideology_loose_modifier_rows.clear();
    _ideology_day_modifier_batches.clear();
    return true;
}

void NativeSimulationHost::record_ideology_worker_opinion_use(
        int64_t plan_day, const RuntimeIdeologyOpinionSnapshot &opinion,
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> owner,
        uint64_t ideology_generation) {
    // Publish the day and the opinion as ONE record (R9-1). Three separate
    // atomics let a reader pair day N with the opinion of day N-1, which is the
    // intermittency this replaces: the reader then binds the main thread to an
    // input the worker never used.
    IdeologyWorkerOpinionUse use;
    use.plan_day = plan_day;
    use.committed_day = opinion.committed_day;
    use.period_index = opinion.period_index;
    use.revision = opinion.revision;
    use.ideology_generation = ideology_generation;
    use.opinion = std::move(owner);
    std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
    _ideology_worker_opinion_ring[
        _ideology_worker_opinion_count % IDEOLOGY_WORKER_OPINION_RING] =
        std::move(use);
    ++_ideology_worker_opinion_count;
}

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::worker_opinion_snapshot_for_ideology_generation(
        uint64_t generation) const {
    if (generation == 0) return nullptr;
    std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
    const size_t filled = std::min<size_t>(_ideology_worker_opinion_count,
                                           IDEOLOGY_WORKER_OPINION_RING);
    for (size_t i = 0; i < filled; ++i) {
        const size_t slot = (_ideology_worker_opinion_count - 1u - i) %
                            IDEOLOGY_WORKER_OPINION_RING;
        const IdeologyWorkerOpinionUse &use = _ideology_worker_opinion_ring[slot];
        if (use.ideology_generation != generation || use.opinion == nullptr)
            continue;
        return use.opinion;
    }
    return nullptr;
}

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::worker_opinion_snapshot_for_day(int64_t day) const {
    // The opinion the worker consumed when it planned THIS day (R9-1).
    //
    // A single record lookup under the mutex, so the day and the opinion can
    // never come from different plans. Returning null means "the worker never
    // planned this day", and the caller must then not publish a reference for it
    // rather than re-deriving an opinion: a re-derived input is exactly what made
    // the two sides diverge depending on thread scheduling.
    //
    // NOTE (05 §2.7): this reader is correct and unit-verifiable, but nothing calls
    // it yet. The join between the worker's plan day and the day the main thread is
    // asked to run is not the same coordinate, so wiring it is still open.
    std::lock_guard<std::mutex> lock(_ideology_worker_opinion_mutex);
    const size_t filled = std::min<size_t>(_ideology_worker_opinion_count,
                                           IDEOLOGY_WORKER_OPINION_RING);
    for (size_t i = 0; i < filled; ++i) {
        const size_t slot = (_ideology_worker_opinion_count - 1u - i) %
                            IDEOLOGY_WORKER_OPINION_RING;
        const IdeologyWorkerOpinionUse &use = _ideology_worker_opinion_ring[slot];
        if (use.plan_day != day || use.opinion == nullptr) continue;
        return use.opinion;
    }
    return nullptr;
}

std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
NativeSimulationHost::pin_ideology_reference_opinion(int64_t day,
        const RuntimeIdeologyOpinionSnapshot &snapshot) {
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    const auto found = _ideology_reference_opinions.find(day);
    if (found != _ideology_reference_opinions.end()) return found->second;
    auto copy = std::make_shared<const RuntimeIdeologyOpinionSnapshot>(snapshot);
    _ideology_reference_opinions.emplace(day, copy);
    // Retain only inputs either side can still need. This is consumer-driven
    // retirement, without a time/count cap or a "latest" fallback.
    const int64_t worker_day = _committed_day.load(
        std::memory_order_acquire);
    const int64_t through = std::min(day, worker_day);
    while (!_ideology_reference_opinions.empty() &&
        _ideology_reference_opinions.begin()->first < through)
        _ideology_reference_opinions.erase(_ideology_reference_opinions.begin());
    return copy;
}

bool NativeSimulationHost::publish_ideology_opinion_snapshot(
        const RuntimeIdeologyOpinionSnapshot &snapshot, std::string &error) {
    if (snapshot.revision == 0 || snapshot.class_hash == 0 ||
        snapshot.country_count == 0 || snapshot.class_count == 0) {
        error = "ideology_opinion_snapshot_invalid";
        return false;
    }
    const size_t lanes = static_cast<size_t>(snapshot.country_count) *
        snapshot.class_count;
    if (snapshot.country_handles.size() != snapshot.country_count ||
        snapshot.country_generations.size() != snapshot.country_count ||
        snapshot.population.size() != lanes || snapshot.funds.size() != lanes ||
        snapshot.owner_employed.size() != lanes ||
        snapshot.satisfaction_weighted.size() != lanes ||
        snapshot.satisfaction_q16.size() != lanes) {
        error = "ideology_opinion_snapshot_shape_invalid";
        return false;
    }
    // Incidence table: absent (channel count 0) or exactly one measured flag per
    // country plus one share row per (country, class). A partial table would let
    // the worker read a neighbour row's shares, which presents as a business
    // divergence rather than a shape error.
    if (snapshot.incidence_channel_count < 0) {
        error = "ideology_opinion_snapshot_shape_invalid";
        return false;
    }
    if (snapshot.incidence_channel_count == 0) {
        if (!snapshot.class_incidence_q16.empty() ||
            (!snapshot.incidence_measured.empty() &&
             snapshot.incidence_measured.size() != snapshot.country_count)) {
            error = "ideology_opinion_snapshot_shape_invalid";
            return false;
        }
    } else if (snapshot.incidence_measured.size() != snapshot.country_count ||
               snapshot.class_incidence_q16.size() !=
                   lanes * static_cast<size_t>(snapshot.incidence_channel_count)) {
        error = "ideology_opinion_snapshot_shape_invalid";
        return false;
    }
    auto copy = std::make_shared<RuntimeIdeologyOpinionSnapshot>(snapshot);
    // The ordinary worker path reads the latest committed input. SHADOW parity
    // separately pins the input at the reference's actual daily entry; it never
    // infers the simulation day from Economy's committed_day or period index.
    std::atomic_store_explicit(&_ideology_opinion_snapshot,
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>(std::move(copy)),
        std::memory_order_release);
    return true;
}

void NativeSimulationHost::set_ideology_cell_tags(
        int32_t words, const std::vector<uint64_t> &bits) {
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    _ideology_pod_authority.set_cell_tags(words, bits);
}

bool NativeSimulationHost::queue_ideology_pod_command(
        const RuntimeIdeologyPodCommand &command, std::string &error) {
    return queue_ideology_pod_commands({command}, error);
}

bool NativeSimulationHost::queue_ideology_pod_commands(
        const std::vector<RuntimeIdeologyPodCommand> &commands,
        std::string &error) {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    // The Effect adapter stages this vector as one semantic batch. Validate
    // every row before publishing any of them, otherwise a reject on row N
    // leaves rows 0..N-1 in the transport and the caller reports failure while
    // the worker still applies a partial grant.
    for (const RuntimeIdeologyPodCommand &command : commands) {
        const int32_t opcode = static_cast<int32_t>(command.opcode);
        if (command.request_id == 0 || command.producer_id == 0 ||
                command.country_handle == 0 ||
                command.requested_day < 0 || command.effective_day < 0 ||
                command.effective_day < command.requested_day ||
                opcode < static_cast<int32_t>(
                    RuntimeIdeologyPodOpcode::DISCOVER) ||
                opcode > static_cast<int32_t>(
                    RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW)) {
            error = "ideology_command_invalid";
            return false;
        }
        if (command.opcode == RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW &&
                (command.value_q16 <= 0 || command.value_q16 > 65535 ||
                 command.ideology_id != -1)) {
            error = "ideology_free_draw_invalid";
            return false;
        }
    }
    if (commands.size() > RUNTIME_COMMAND_QUEUE_CAPACITY -
            _ideology_commands.size()) {
        error = "ideology_command_capacity_exceeded";
        return false;
    }
    _ideology_commands.insert(_ideology_commands.end(),
                              commands.begin(), commands.end());
    return true;
}

bool NativeSimulationHost::poll_ideology_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    if (_ideology_intents.empty()) return false;
    intent = _ideology_intents.front();
    _ideology_intents.pop_front();
    return true;
}

bool NativeSimulationHost::submit_ideology_pod_ack(
        const RuntimeDomainAck &ack, std::string &error) {
    if (ack.domain != static_cast<uint16_t>(RuntimeDomainId::EFFECT) ||
        (ack.transaction_id == 0 && ack.request_id == 0)) {
        error = "ideology_ack_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    if (_ideology_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "ideology_ack_capacity_exceeded";
        return false;
    }
    _ideology_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
}

std::shared_ptr<const RuntimeIdeologyPodSnapshot>
NativeSimulationHost::ideology_pod_snapshot() const {
    return std::atomic_load_explicit(&_ideology_snapshot,
                                     std::memory_order_acquire);
}

bool NativeSimulationHost::encode_ideology_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        if (_ideology_commands.empty()) {
            _ideology_pod_authority.serialize(bytes);
        } else {
            auto candidate = _ideology_pod_authority;
            for (const auto &command : _ideology_commands)
                if (!candidate.queue_command(command, error)) return false;
            candidate.serialize(bytes);
        }
    }
    if (bytes.empty()) { error = "ideology_pod_save_encode_failed"; return false; }
    return true;
}

bool NativeSimulationHost::restore_ideology_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    RuntimeIdeologyPodAuthority candidate;
    if (!candidate.configure(_ideology_pod_catalog, error) ||
        !candidate.restore(bytes, size, error)) return false;
    _ideology_pod_authority = std::move(candidate);
    _ideology_modifier_inflight.clear();
    _ideology_loose_modifier_rows.clear();
    _ideology_day_modifier_batches.clear();
    _ideology_pod_authority.rearm_pending_transitions();
    const auto &restored = _ideology_pod_authority.snapshot();
    _ideology_pod_state_hash.store(restored.state_hash, std::memory_order_release);
    _ideology_pod_snapshot_generation.store(restored.generation, std::memory_order_release);
    _ideology_pod_committed_day.store(restored.committed_day, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::ideology_pod_self_test(std::string *out_error) const {
    std::string error;
    if (!RuntimeIdeologyPodAuthority::self_test(error)) {
        if (out_error != nullptr) *out_error = error;
        return false;
    }
    if (!runtime_published_view_self_test() || !RuntimeIdeologySnapshotRing::self_test()) {
        if (out_error != nullptr)
            *out_error = "ideology_pod_snapshot_ring_self_test_failed";
        return false;
    }
    // Start the worker with a queued dismissal and a stop already requested.
    // This exercises the shutdown receipt without racing normal service.
    const auto stopping = std::make_unique<NativeSimulationHost>();
    stopping->_state.store(RuntimeWorkerState::PAUSED);
    stopping->_player_confirmation.requests.push_back({
        RuntimePlayerConfirmationRequest::Kind::DISMISS_IDEOLOGY, 1, 0});
    stopping->request_stop();
    stopping->worker_main();
    bool quotes_ready;
    const auto receipts = stopping->take_boundary_command_results(quotes_ready);
    if (receipts.size() != 1 || godot::String(godot::Dictionary(receipts[0]).get("code", "")) !=
            "executor_stopped_before_player_confirmation_service") {
        if (out_error != nullptr) *out_error = "ideology_dismiss_stop_receipt_code_invalid";
        return false;
    }
    return true;
}

#include "native_simulation_host_ideology_section_worker.inc"

bool NativeSimulationHost::ideology_modifier_bridge_active() const {
    const uint32_t requested =
        _requested_authority_mask.load(std::memory_order_acquire);
    return _mode.load(std::memory_order_acquire) ==
               RuntimeSimulationMode::ACTIVE &&
        _modifier_pod_configured &&
        (requested & runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u &&
        (requested & runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u;
}

void NativeSimulationHost::stage_ideology_modifier_commands(
        int64_t day, uint64_t input_generation) {
    _ideology_day_modifier_batches.clear();
    if (_ideology_modifier_inflight.empty() &&
        _ideology_loose_modifier_rows.empty()) return;
    auto resolve = [this](const RuntimeIdeologyPodModifierRow &row) {
        const auto found = _modifier_definition_id_by_key_hash.find(
            row.definition_key_hash);
        return found == _modifier_definition_id_by_key_hash.end()
            ? -1 : found->second;
    };
    auto make_command = [&](const RuntimeIdeologyPodModifierRow &row,
                            int32_t definition_id) {
        RuntimeModifierPodCommand command;
        uint64_t hash = 1469598103934665603ull;
        for (uint64_t value : {row.transition_id, row.source_id,
                               row.definition_key_hash,
                               static_cast<uint64_t>(row.ordinal),
                               static_cast<uint64_t>(row.opcode),
                               _ideology_modifier_sequence}) {
            hash ^= value; hash *= 1099511628211ull;
        }
        command.request_id = hash == 0 ? 1 : hash;
        command.producer_id = 0x49444530u; // IDE0
        command.sequence = _ideology_modifier_sequence++;
        command.requested_day = day;
        command.effective_day = day;
        command.opcode = row.opcode;
        command.domain = row.domain;
        command.definition_id = definition_id;
        command.scope = 2; // ENTITY: the country handle
        command.entity_handle = row.country_handle;
        command.target_generation = row.country_generation;
        command.source_type = RUNTIME_IDEOLOGY_MODIFIER_SOURCE_TYPE;
        command.source_id = row.source_id;
        command.duration_days = -1;
        command.stacks = 1;
        command.magnitude_q16 = row.magnitude_q16;
        command.input_generation = input_generation;
        return command;
    };
    for (auto &inflight : _ideology_modifier_inflight) {
        if (inflight.submitted != 0) continue;
        // Preflight the whole batch: one unresolved row means zero submission.
        bool resolved = true;
        for (const auto &row : inflight.rows)
            if (resolve(row) < 0) { resolved = false; break; }
        inflight.batch_index = -1;
        if (!resolved) {
            // Settled as REJECTED after this day's Modifier stage.
            inflight.submitted = 2;
            continue;
        }
        std::vector<RuntimeModifierPodCommand> batch;
        batch.reserve(inflight.rows.size());
        for (const auto &row : inflight.rows) {
            batch.push_back(make_command(row, resolve(row)));
        }
        inflight.batch_index =
            static_cast<int32_t>(_ideology_day_modifier_batches.size());
        _ideology_day_modifier_batches.push_back(std::move(batch));
        inflight.submitted = 1;
    }
    // Loose synergy rows: each synergy add/remove pair is its own batch.
    for (const auto &row : _ideology_loose_modifier_rows) {
        const int32_t definition_id = resolve(row);
        if (definition_id >= 0)
            _ideology_day_modifier_batches.push_back({make_command(row, definition_id)});
    }
}

void NativeSimulationHost::settle_ideology_modifier_acks(
        const std::vector<uint8_t> &batch_ok, bool committed) {
    // Loose synergy rows stay queued until a Modifier day commits them.
    if (committed) _ideology_loose_modifier_rows.clear();
    std::vector<RuntimeDomainAck> settled;
    for (auto it = _ideology_modifier_inflight.begin();
         it != _ideology_modifier_inflight.end();) {
        auto &inflight = *it;
        if (inflight.submitted == 0) { ++it; continue; }
        RuntimeDomainAckCode code = RuntimeDomainAckCode::OK;
        bool done = false;
        if (inflight.submitted == 2) {
            code = RuntimeDomainAckCode::REJECTED;
            done = true;
        } else if (!committed) {
            // Modifier day failed atomically: resubmit the batch next day.
            inflight.submitted = 0;
            ++it;
            continue;
        } else {
            done = true;
            if (inflight.batch_index < 0 ||
                static_cast<size_t>(inflight.batch_index) >= batch_ok.size() ||
                batch_ok[static_cast<size_t>(inflight.batch_index)] == 0u)
                code = RuntimeDomainAckCode::REJECTED;
        }
        if (!done) { ++it; continue; }
        RuntimeDomainAck ack;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        ack.code = code;
        ack.request_id = inflight.intent.request_id != 0
            ? inflight.intent.request_id : inflight.intent.source_id;
        ack.transaction_id = inflight.intent.source_id;
        ack.target_handle = inflight.intent.target_handle;
        ack.target_generation = inflight.intent.target_generation;
        ack.effective_day = inflight.intent.effective_day;
        ack.producer_id = inflight.intent.producer_id;
        ack.sequence = inflight.intent.sequence;
        settled.push_back(ack);
        it = _ideology_modifier_inflight.erase(it);
    }
    if (settled.empty()) return;
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        for (const auto &ack : settled) _ideology_acks.push_back(ack);
    }
    // Internal Modifier completion uses the same ACK queue as the split-
    // authority transport. Wake the day barrier so the next Ideology poll
    // cannot remain asleep with transition_pending latched forever.
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
}
} // namespace pk
