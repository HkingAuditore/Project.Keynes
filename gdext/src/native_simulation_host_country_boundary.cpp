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

bool NativeSimulationHost::publish_country_snapshot(
        const RuntimeCountryPodSnapshot &snapshot) {
    std::string error;
    if (!RuntimeCountryPodAdapter::validate_snapshot(snapshot, error)) return false;
    auto copy = std::make_shared<RuntimeCountryPodSnapshot>(snapshot);
    std::shared_ptr<const RuntimeCountryPodSnapshot> view = copy;
    std::atomic_store_explicit(&_country_snapshot, view, std::memory_order_release);
    std::atomic_store_explicit(&_country_economy_audit_snapshot, view,
                               std::memory_order_release);
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        const std::shared_ptr<const RuntimeCountryPodSnapshot> previous =
            _country_committed_snapshot;
        const bool same_cell_shape = previous != nullptr &&
            previous->cell_country_slot.size() == snapshot.cell_country_slot.size();
        bool territory_changed = !same_cell_shape;
        _country_committed_snapshot = copy;
        _country_read_view_generation = snapshot.generation;
        _country_read_view_patch_base_generation = previous != nullptr
            ? previous->generation : 0;
        _country_read_view_dirty_families = RUNTIME_DIRTY_COUNTRY_STATE |
            RUNTIME_DIRTY_COUNTRY_VISUAL_ERA;
        _country_read_view_changed_cells.clear();
        _country_read_view_changed_owners.clear();
        _country_read_view_changed_cells.reserve(snapshot.cell_country_slot.size());
        _country_read_view_changed_owners.reserve(snapshot.cell_country_slot.size());
        for (size_t cell = 0; cell < snapshot.cell_country_slot.size(); ++cell) {
            if (same_cell_shape &&
                previous->cell_country_slot[cell] == snapshot.cell_country_slot[cell]) {
                continue;
            }
            territory_changed = true;
            _country_read_view_changed_cells.push_back(static_cast<int32_t>(cell));
            _country_read_view_changed_owners.push_back(snapshot.cell_country_slot[cell]);
        }
        if (!_country_read_view_changed_cells.empty())
            _country_read_view_territory_generation = _country_read_view_generation;
        if (territory_changed) {
            _country_read_view_dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY;
        }
    }
    return true;
}

bool NativeSimulationHost::publish_country_worker_snapshot(
        uint32_t dirty_families, std::string &error) {
    error.clear();
    RuntimeCountryPodSnapshot snapshot;
    if (!_country_pod_authority.snapshot(snapshot, error)) {
        if (error.empty()) error = "country_worker_snapshot_failed";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const std::shared_ptr<const RuntimeCountryPodSnapshot> previous =
        _country_committed_snapshot;
    const uint64_t previous_view_generation = _country_read_view_generation;
    uint64_t next_view_generation = previous_view_generation + 1u;
    if (next_view_generation == 0) next_view_generation = 1;
    if (next_view_generation < snapshot.generation)
        next_view_generation = snapshot.generation;
    _country_read_view_generation = next_view_generation;
    _country_read_view_patch_base_generation = previous_view_generation;
    _country_read_view_dirty_families = dirty_families;
    _country_read_view_changed_cells.clear();
    _country_read_view_changed_owners.clear();
    // Soft STATE/VISUAL publishes (treasury, tax, research) must not scan the
    // whole owner plane under the transport mutex. Callers that mutate
    // territory are required to include RUNTIME_DIRTY_COUNTRY_TERRITORY.
    if ((dirty_families & RUNTIME_DIRTY_COUNTRY_TERRITORY) != 0) {
        const bool same_cell_shape = previous != nullptr &&
            previous->cell_country_slot.size() == snapshot.cell_country_slot.size();
        for (size_t cell = 0; cell < snapshot.cell_country_slot.size(); ++cell) {
            if (same_cell_shape && previous->cell_country_slot[cell] ==
                    snapshot.cell_country_slot[cell]) {
                continue;
            }
            _country_read_view_changed_cells.push_back(static_cast<int32_t>(cell));
            _country_read_view_changed_owners.push_back(
                snapshot.cell_country_slot[cell]);
        }
        if (!_country_read_view_changed_cells.empty())
            _country_read_view_territory_generation = _country_read_view_generation;
    }
    auto committed_copy = std::make_shared<RuntimeCountryPodSnapshot>(
        std::move(snapshot));
    _country_committed_snapshot = committed_copy;
    std::shared_ptr<const RuntimeCountryPodSnapshot> committed_view =
        committed_copy;
    std::atomic_store_explicit(&_country_snapshot, committed_view,
                               std::memory_order_release);
    std::atomic_store_explicit(&_country_economy_audit_snapshot, committed_view,
                               std::memory_order_release);
    _country_worker_country_generation = committed_copy->generation;
    _country_worker_day = committed_copy->committed_day;
    // A peer-rejected semantic day is still a committed Country state. It
    // follows this helper instead of the ordinary commit path, but must cross
    // the same parity boundary or rejected days silently erase D11 evidence.
    record_country_parity_locked(*committed_copy);
    return true;
}

bool NativeSimulationHost::publish_country_plan_preview_snapshot(
        std::string &error) {
    error.clear();
    if (!_country_pod_plan_active.load(std::memory_order_acquire) ||
        _country_pod_plan.preflight_ok == 0) {
        error = "country_plan_preview_inactive";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const uint64_t previous_view_generation = _country_read_view_generation;
    uint64_t next_view_generation = previous_view_generation + 1u;
    if (next_view_generation == 0) next_view_generation = 1;
    if (next_view_generation < _country_pod_plan.next_state.generation)
        next_view_generation = _country_pod_plan.next_state.generation;
    _country_read_view_generation = next_view_generation;
    _country_read_view_patch_base_generation = previous_view_generation;
    _country_read_view_dirty_families = RUNTIME_DIRTY_COUNTRY_STATE |
        (_country_pod_plan.header.dirty_families &
         (RUNTIME_DIRTY_COUNTRY_STATE | RUNTIME_DIRTY_COUNTRY_VISUAL_ERA));
    _country_read_view_changed_cells.clear();
    _country_read_view_changed_owners.clear();
    auto preview_copy = std::make_shared<const RuntimeCountryPodSnapshot>(
        _country_pod_plan.next_state);
    // UI / read-view only. Leave _country_economy_audit_snapshot on the last
    // sealed authority publish so VERIFY cannot see uncommitted TP spend.
    _country_committed_snapshot = preview_copy;
    std::atomic_store_explicit(&_country_snapshot, preview_copy,
                               std::memory_order_release);
    return true;
}

bool NativeSimulationHost::publish_country_catalog(
        const RuntimeCountryPodCatalog &catalog, std::string &error) {
    error.clear();
    RuntimeCountryPodAuthority validator;
    if (!validator.validate_catalog(catalog, error)) return false;
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current != RuntimeWorkerState::STOPPED &&
        current != RuntimeWorkerState::FAULTED) {
        error = "country_catalog_publish_while_running";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_pod_catalog = catalog;
    _country_pod_configured.store(false, std::memory_order_release);
    _country_pod_plan_active.store(false, std::memory_order_release);
    _country_pod_ready.store(false, std::memory_order_release);
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
    _country_pod_plan = RuntimeCountryPodPlan{};
    _country_worker_protocol = CountryPeerProtocolStatus{};
    _country_worker_protocol.async_mode = 1;
    _country_worker_protocol.retry_day = -1;
    _country_worker_seal = CountryBoundarySeal{};
    for (auto &character : _country_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    return true;
}

bool NativeSimulationHost::publish_country_reference(
        int64_t day, uint64_t reference_state_hash, std::string &error,
        const RuntimeCountryPodSnapshot *snapshot) {
    error.clear();
    if (day < 0 || reference_state_hash == 0) {
        error = "country_reference_invalid";
        return false;
    }
    if (snapshot != nullptr &&
        country_core_hash_business_state(*snapshot) != reference_state_hash) {
        error = "country_reference_state_hash_inconsistent";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    RuntimeCountryPodSnapshot stored;
    if (snapshot != nullptr) stored = *snapshot;
    stored.state_hash = reference_state_hash;
    stored.committed_day = day;
    _country_references[day] = std::move(stored);
    while (_country_references.size() > 128u)
        _country_references.erase(_country_references.begin());
    return true;
}

void NativeSimulationHost::bind_shadow_country_peer_mirrors_locked() {
    for (auto &entry : _country_worker_intents) {
        const CountryPeerIntent &intent = entry.second;
        const auto existing = _country_worker_results.find(intent.request_id);
        if (existing != _country_worker_results.end() &&
            existing->second.code != CountryPeerResultCode::PENDING) {
            continue;
        }
        for (auto it = _country_shadow_peer_mirrors.begin();
             it != _country_shadow_peer_mirrors.end(); ++it) {
            if (it->opcode != intent.opcode ||
                it->country_slot != intent.country_slot ||
                it->technology != intent.technology ||
                it->day != intent.day) {
                continue;
            }
            CountryPeerResult bound = *it;
            bound.request_id = intent.request_id;
            bound.session_epoch = intent.session_epoch;
            bound.country_generation = intent.country_generation;
            bound.peer_generation = intent.peer_generation;
            bound.day = intent.day;
            bound.continuation_index = intent.continuation_index;
            bound.country_slot = intent.country_slot;
            bound.technology = intent.technology;
            bound.target_handle = intent.target_handle;
            bound.opcode = intent.opcode;
            if (bound.committed_peer_generation < bound.peer_generation)
                bound.committed_peer_generation = bound.peer_generation;
            _country_worker_results[intent.request_id] = bound;
            if (bound.code != CountryPeerResultCode::PENDING)
                _country_worker_terminal_results[intent.request_id] = bound;
            _country_shadow_peer_mirrors.erase(it);
            break;
        }
    }
}

void NativeSimulationHost::record_country_parity_locked(
        const RuntimeCountryPodSnapshot &worker) {
    const uint64_t worker_hash = worker.state_hash != 0
        ? worker.state_hash
        : country_core_hash_business_state(worker);
    _country_parity_worker_hash.store(worker_hash, std::memory_order_release);
    const auto found = _country_references.find(worker.committed_day);
    if (found == _country_references.end()) {
        static std::atomic<int> s_country_uncompared_reports_left{8};
        if (s_country_uncompared_reports_left.fetch_sub(
                1, std::memory_order_relaxed) > 0) {
            const int64_t first_reference_day = _country_references.empty()
                ? -1 : _country_references.begin()->first;
            const int64_t last_reference_day = _country_references.empty()
                ? -1 : _country_references.rbegin()->first;
            std::fprintf(stderr,
                         "[country][parity] worker_day=%lld uncompared "
                         "reference_range=%lld..%lld depth=%zu\n",
                         static_cast<long long>(worker.committed_day),
                         static_cast<long long>(first_reference_day),
                         static_cast<long long>(last_reference_day),
                         _country_references.size());
            std::fflush(stderr);
        }
        _country_parity_compared.store(0, std::memory_order_release);
        _country_parity_matched.store(0, std::memory_order_release);
        store_atomic_chars(_country_parity_status, "uncompared");
        store_atomic_chars48(_country_parity_field, "");
        return;
    }
    const uint64_t reference_hash = found->second.state_hash != 0
        ? found->second.state_hash
        : country_core_hash_business_state(found->second);
    _country_parity_compared.store(1, std::memory_order_release);
    _country_parity_compared_count.fetch_add(1, std::memory_order_relaxed);
    _country_parity_reference_hash.store(reference_hash, std::memory_order_release);
    if (reference_hash == worker_hash) {
        _country_parity_matched.store(1, std::memory_order_release);
        _country_parity_matched_count.fetch_add(1, std::memory_order_relaxed);
        store_atomic_chars(_country_parity_status, "comparable");
        store_atomic_chars48(_country_parity_field, "");
        _country_parity_index.store(-1, std::memory_order_release);
        return;
    }
    _country_parity_matched.store(0, std::memory_order_release);
    store_atomic_chars(_country_parity_status, "mismatch");
    int64_t first = _country_parity_first_mismatch_day.load(
        std::memory_order_acquire);
    if (first < 0)
        _country_parity_first_mismatch_day.store(worker.committed_day,
                                                 std::memory_order_release);
    char field[48]{};
    int32_t index = -1;
    if (!found->second.country_cash.empty() ||
        !found->second.cell_country_slot.empty()) {
        country_core_first_business_difference(
            found->second, worker, field, sizeof(field), index);
    } else {
        runtime_copy_text(field, "state_hash");
    }
    store_atomic_chars48(_country_parity_field, field);
    _country_parity_index.store(index, std::memory_order_release);
}

bool NativeSimulationHost::mirror_country_peer_result(
        const CountryPeerResult &result, std::string &error) {
    error.clear();
    if (result.code == CountryPeerResultCode::PENDING) return true;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_shadow_peer_mirrors.push_back(result);
    while (_country_shadow_peer_mirrors.size() > 4096u)
        _country_shadow_peer_mirrors.pop_front();
    bind_shadow_country_peer_mirrors_locked();
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

bool NativeSimulationHost::mirror_sync_country_economy_asset(
        const RuntimeEconomyAssetRequest &request,
        const RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    if (!_country_pod_configured.load(std::memory_order_acquire)) return true;
    if (domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) return true;
    if (request.request_id == 0) {
        error = "country_shadow_economy_mirror_request_invalid";
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        RuntimeEconomyAssetRequest stored = request;
        stored.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
        _country_economy_asset_requests[request.request_id] = stored;
        _country_economy_asset_terminal_results[request.request_id] = result;
        _country_economy_asset_results[request.request_id] = result;
        ++_country_economy_asset_protocol.terminal_requests;
        _country_economy_asset_protocol.last_request_id = request.request_id;
        _country_economy_asset_protocol.last_transaction_id = request.transaction_id;
    }
    return true;
}

bool NativeSimulationHost::country_shadow_parity_self_test(std::string &error) const {
    error.clear();
    const auto snapshot = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (snapshot == nullptr || _country_pod_catalog.catalog_hash == 0) {
        error = "country_parity_self_test_capture_missing";
        return false;
    }
    if (country_core_hash_business_state(*snapshot) != snapshot->state_hash) {
        error = "country_parity_self_test_export_hash_mismatch";
        return false;
    }
    if (snapshot->research_queue_lengths.size() !=
            static_cast<size_t>(snapshot->country_count) *
                RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT ||
        snapshot->research_weights_bp.size() !=
            static_cast<size_t>(snapshot->country_count) *
                RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) {
        error = "country_parity_self_test_research_lane_shape";
        return false;
    }
    {
        // ACTIVE UI reads through this replica. A shape mismatch here is the
        // exact failure that leaves research enqueue stuck on "次日生效".
        NativeCountryRuntime read_replica;
        if (!read_replica.apply_committed_read_snapshot(*snapshot)) {
            error = "country_parity_self_test_read_replica_rejected";
            return false;
        }
    }
    int32_t slot = -1;
    for (uint32_t candidate = 0; candidate < snapshot->country_count; ++candidate) {
        if (snapshot->country_active[candidate] != 0) {
            slot = static_cast<int32_t>(candidate);
            break;
        }
    }
    if (slot < 0) {
        error = "country_parity_self_test_active_country_missing";
        return false;
    }
    NativeSimulationHost probe;
    RuntimeCountryPodSnapshot fixture = *snapshot;
    fixture.country_pending_technologies.assign(
        fixture.country_pending_technologies.size(), 0);
    fixture.research_queue_lengths.assign(
        fixture.research_queue_lengths.size(), 0);
    fixture.country_cash[static_cast<size_t>(slot)] = 0;
    fixture.state_hash = country_core_hash_business_state(fixture);
    probe._country_pod_catalog = _country_pod_catalog;
    std::string bootstrap_error;
    if (!probe._country_pod_authority.bootstrap(
            fixture, probe._country_pod_catalog, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_bootstrap_failed" : bootstrap_error;
        return false;
    }
    probe._country_pod_configured.store(true, std::memory_order_release);
    probe._country_worker_session_epoch = 1;
    probe._mode.store(RuntimeSimulationMode::SHADOW, std::memory_order_release);
    // The synchronous producer leads this worker by a Country boundary. The
    // future receipt must stay queued while today's command/hash is checked.
    RuntimeEconomyAssetRequest future_credit;
    future_credit.operation = RuntimeEconomyAssetOperation::FISCAL_COLLECT;
    future_credit.session_epoch = 1;
    future_credit.transaction_id = 7702;
    future_credit.request_id = 7702;
    future_credit.day = fixture.committed_day + 2;
    future_credit.operation_sequence = 1;
    future_credit.country_slot = slot;
    RuntimeEconomyAssetResult future_result;
    future_result.code = RuntimeEconomyAssetResultCode::COMPLETED;
    future_result.state = RuntimeEconomyAssetState::COMPLETED;
    future_result.committed_cash = 17;
    if (!probe.mirror_sync_country_economy_asset(
            future_credit, future_result, error)) return false;
    RuntimeEconomyAssetRequest future_purchase = future_credit;
    future_purchase.operation = RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    future_purchase.request_id = 7703;
    future_purchase.transaction_id = 7703;
    future_purchase.operation_sequence = 2;
    future_purchase.reserved_cash = 11;
    future_purchase.prepared_quantity = 3;
    RuntimeEconomyAssetResult purchase_result = future_result;
    purchase_result.committed_cash = 11;
    purchase_result.committed_quantity = 3;
    if (!probe.mirror_sync_country_economy_asset(
            future_purchase, purchase_result, error)) return false;
    RuntimeCountryCommand rename;
    rename.request_id = 7701;
    rename.producer_id = 0;
    rename.sequence = 1;
    rename.submit_order = 1;
    rename.requested_day = fixture.committed_day + 1;
    rename.effective_day = fixture.committed_day + 1;
    rename.opcode = 2;
    rename.target_handle =
        (static_cast<uint64_t>(fixture.country_generation[static_cast<size_t>(slot)])
         << 32u) | static_cast<uint32_t>(slot);
    const char *renamed = "ParityRename";
    for (size_t i = 0; i + 1u < rename.display_name.size() && renamed[i] != '\0'; ++i)
        rename.display_name[i] = renamed[i];
    RuntimeCountryPodAuthority core;
    if (!core.bootstrap(fixture, _country_pod_catalog, bootstrap_error) ||
        !core.queue_command(rename, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_core_queue_failed" : bootstrap_error;
        return false;
    }
    RuntimeCountryPodPlan core_plan;
    if (!core.plan_day(rename.effective_day, 1, core_plan, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_core_plan_failed" : bootstrap_error;
        return false;
    }
    std::vector<RuntimeDomainAck> core_acks;
    core_acks.reserve(core_plan.intents.size());
    for (const RuntimeDomainIntent &intent : core_plan.intents) {
        RuntimeDomainAck ack;
        ack.request_id = intent.request_id != 0 ? intent.request_id : intent.source_id;
        ack.transaction_id = intent.source_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = intent.target_domain;
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        core_acks.push_back(ack);
    }
    if (!core.commit_day(core_plan, core_acks, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_core_commit_failed" : bootstrap_error;
        return false;
    }
    RuntimeCountryPodSnapshot core_state;
    if (!core.snapshot(core_state, error)) return false;
    std::string publish_error;
    if (!probe.publish_country_reference(
            rename.effective_day, core_state.state_hash, publish_error, &core_state)) {
        error = publish_error.empty()
            ? "country_parity_self_test_reference_failed" : publish_error;
        return false;
    }
    RuntimeCommandPacket packet;
    packet.envelope.request_id = rename.request_id;
    packet.envelope.producer_id = rename.producer_id;
    packet.envelope.sequence = rename.sequence;
    packet.envelope.requested_day = rename.requested_day;
    packet.envelope.effective_day = rename.effective_day;
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    packet.envelope.opcode = rename.opcode;
    packet.envelope.payload_offset = 0;
    packet.envelope.payload_size = sizeof(RuntimeCountryCommand);
    std::memcpy(packet.payload.data(), &rename, sizeof(rename));
    RuntimeDayCommit commit;
    std::string stage_error;
    auto ack_worker_intents = [&]() {
        CountryPeerIntent intent;
        while (probe.poll_country_worker_intent(intent)) {
            CountryPeerResult result;
            result.protocol_version = intent.protocol_version;
            result.code = CountryPeerResultCode::APPLIED;
            result.opcode = intent.opcode;
            result.request_id = intent.request_id;
            result.session_epoch = intent.session_epoch;
            result.country_generation = intent.country_generation;
            result.peer_generation = intent.peer_generation;
            result.committed_peer_generation = intent.peer_generation;
            result.day = intent.day;
            result.continuation_index = intent.continuation_index;
            result.country_slot = intent.country_slot;
            result.technology = intent.technology;
            result.target_handle = intent.target_handle;
            std::string submit_error;
            if (!probe.submit_country_worker_result(result, submit_error)) {
                error = submit_error.empty()
                    ? "country_parity_self_test_ack_failed" : submit_error;
                return false;
            }
        }
        return true;
    };
    if (!probe.execute_country_worker_stage(
            rename.effective_day, 1, {packet}, commit, stage_error, 1)) {
        if (stage_error != "country_worker_peer_results_pending" ||
            !ack_worker_intents()) {
            if (error.empty()) {
                error = stage_error.empty()
                    ? "country_parity_self_test_worker_failed" : stage_error;
            }
            return false;
        }
        stage_error.clear();
        if (!probe.execute_country_worker_stage(
                rename.effective_day, 1, {packet}, commit, stage_error, 1)) {
            error = stage_error.empty()
                ? "country_parity_self_test_worker_commit_failed" : stage_error;
            return false;
        }
    }
    RuntimeCountryPodSnapshot worker_state;
    if (!probe._country_pod_authority.snapshot(worker_state, error)) return false;
    char field[48]{};
    int32_t index = -1;
    if (country_core_first_business_difference(
            core_state, worker_state, field, sizeof(field), index) ||
        country_core_hash_business_state(worker_state) != core_state.state_hash) {
        error = std::string("country_parity_self_test_field_mismatch:") + field;
        return false;
    }
    if (!probe.flush_country_economy_asset_commits(
            error, 0, false, future_credit.day) ||
        !probe._country_pod_authority.snapshot(worker_state, error)) return false;
    const size_t country = static_cast<size_t>(slot);
    const size_t points = country * fixture.good_count +
        static_cast<size_t>(_country_pod_catalog.technology_points_good_id);
    const int64_t expected_cash = core_state.country_cash[country] + 17 - 11;
    const int64_t expected_points = core_state.country_goods[points] + 3;
    const int64_t expected_purchased = core_state.research_purchased_total[country] + 3;
    if (worker_state.country_cash[country] != expected_cash ||
        worker_state.country_goods[points] != expected_points ||
        worker_state.research_purchased_total[country] != expected_purchased) {
        error = "country_parity_self_test_dated_assets_missing";
        return false;
    }
    if (!probe.mirror_sync_country_economy_asset(
            future_credit, future_result, error) ||
        !probe.mirror_sync_country_economy_asset(
            future_purchase, purchase_result, error) ||
        !probe.flush_country_economy_asset_commits(
            error, 0, false, future_credit.day + 1) ||
        !probe._country_pod_authority.snapshot(worker_state, error)) return false;
    if (worker_state.country_cash[country] != expected_cash ||
        worker_state.country_goods[points] != expected_points ||
        worker_state.research_purchased_total[country] != expected_purchased) {
        error = "country_parity_self_test_dated_assets_reapplied";
        return false;
    }
    return true;
}

bool NativeSimulationHost::country_authority_drain_idle_locked() const {
    if (!_country_worker_intent_queue.empty() ||
        !_country_worker_intents.empty() ||
        !_country_worker_notifications.empty() ||
        !_economy_origin_asset_queue.empty() ||
        !_country_economy_asset_request_queue.empty() ||
        _country_pod_plan_active.load(std::memory_order_acquire)) {
        return false;
    }
    // Accepted Host receipts are still open work. Terminal receipts stay.
    for (const auto &entry : _country_command_states) {
        if (entry.second.code == CountryCommandReceiptCode::ACCEPTED)
            return false;
    }
    // SHADOW sync mirrors leave COUNTRY_PREPARED rows with a terminal result;
    // those are drained. Anything still in-flight (no terminal / non-terminal
    // state) blocks handoff the same way begin_save blocks on asset tx.
    for (const auto &entry : _country_economy_asset_requests) {
        if (entry.second.state == RuntimeEconomyAssetState::COMPLETED ||
            entry.second.state == RuntimeEconomyAssetState::REJECTED ||
            entry.second.state == RuntimeEconomyAssetState::FAULTED) {
            continue;
        }
        const auto terminal =
            _country_economy_asset_terminal_results.find(entry.first);
        if (terminal != _country_economy_asset_terminal_results.end() &&
            economy_asset_result_terminal(terminal->second)) {
            // COMPLETED research / continuation-owned terminals still await
            // Economy settlement flush; do not treat them as handoff-ready.
            if ((entry.second.operation ==
                     RuntimeEconomyAssetOperation::RESEARCH_PURCHASE ||
                 _country_economy_asset_self_settled.count(entry.first) != 0) &&
                terminal->second.code ==
                    RuntimeEconomyAssetResultCode::COMPLETED &&
                _country_economy_asset_committed.find(entry.first) ==
                    _country_economy_asset_committed.end()) {
                return false;
            }
            continue;
        }
        return false;
    }
    return true;
}

bool NativeSimulationHost::prepare_country_authority_handoff(
        CountryAuthorityOwner target, std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    if (!country_authority_drain_idle_locked()) {
        error = "country_authority_handoff_busy";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        _country_authority_prepare_pending = false;
        return false;
    }
    if (target == _country_authority_owner) {
        error = "country_authority_handoff_same_owner";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        _country_authority_prepare_pending = false;
        return false;
    }
    _country_authority_prepared = target;
    _country_authority_prepare_pending = true;
    country_peer_copy_reason(_country_authority_handoff_reason, "");
    return true;
}

bool NativeSimulationHost::abort_country_authority_handoff(std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_authority_prepare_pending = false;
    _country_authority_prepared = _country_authority_owner;
    country_peer_copy_reason(_country_authority_handoff_reason,
                             "country_authority_handoff_aborted");
    return true;
}

bool NativeSimulationHost::install_country_authority_handoff(std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    if (!_country_authority_prepare_pending) {
        error = "country_authority_handoff_not_prepared";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        return false;
    }
    if (!country_authority_drain_idle_locked()) {
        error = "country_authority_handoff_busy";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        _country_authority_prepare_pending = false;
        _country_authority_prepared = _country_authority_owner;
        return false;
    }
    const CountryAuthorityOwner next = _country_authority_prepared;
    // SYNC→WORKER requires a published main-thread checkpoint. Live POD
    // replacement while the worker thread may enter Country stage is unsafe;
    // D10 publishes the immutable capture and advances session epoch. The
    // next worker start / D12 ACTIVE path bootstraps from this snapshot.
    if (next == CountryAuthorityOwner::WORKER) {
        const auto snapshot = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        if (snapshot == nullptr || _country_pod_catalog.catalog_hash == 0) {
            error = "country_authority_handoff_checkpoint_missing";
            country_peer_copy_reason(_country_authority_handoff_reason,
                                     error.c_str());
            _country_authority_prepare_pending = false;
            _country_authority_prepared = _country_authority_owner;
            return false;
        }
        _country_committed_snapshot = snapshot;
        _country_worker_country_generation = snapshot->generation;
        _country_worker_day = snapshot->committed_day;
    } else if (_country_pod_configured.load(std::memory_order_acquire)) {
        // WORKER→SYNC: freeze the last POD business state into the published
        // capture so main-thread restore/verify sees the handoff boundary.
        RuntimeCountryPodSnapshot pod_snapshot;
        std::string snapshot_error;
        if (_country_pod_authority.snapshot(pod_snapshot, snapshot_error)) {
            auto copy = std::make_shared<RuntimeCountryPodSnapshot>(
                std::move(pod_snapshot));
            std::shared_ptr<const RuntimeCountryPodSnapshot> view = copy;
            std::atomic_store_explicit(&_country_snapshot, view,
                                       std::memory_order_release);
            std::atomic_store_explicit(&_country_economy_audit_snapshot, view,
                                       std::memory_order_release);
            _country_committed_snapshot = copy;
            _country_worker_country_generation = copy->generation;
            _country_worker_day = copy->committed_day;
        }
    }
    _country_authority_owner = next;
    _country_authority_prepare_pending = false;
    ++_country_worker_session_epoch;
    if (_country_worker_session_epoch == 0) _country_worker_session_epoch = 1;
    country_peer_copy_reason(_country_authority_handoff_reason, "");
    return true;
}

NativeSimulationHost::CountryAuthorityHandoffStatus
NativeSimulationHost::country_authority_handoff_status() const {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    CountryAuthorityHandoffStatus out;
    out.owner = _country_authority_owner;
    out.prepared_target = _country_authority_prepared;
    out.prepare_pending = _country_authority_prepare_pending;
    out.session_epoch = _country_worker_session_epoch;
    std::memcpy(out.last_reason, _country_authority_handoff_reason.data(),
                sizeof(out.last_reason));
    return out;
}

bool NativeSimulationHost::country_authority_handoff_self_test(
        std::string &error) const {
    error.clear();
    NativeSimulationHost probe;
    probe._country_worker_session_epoch = 7;
    std::string local;
    RuntimeEconomyAssetRequest busy;
    busy.request_id = 1;
    busy.transaction_id = 1;
    busy.session_epoch = 7;
    busy.day = 0;
    if (!probe.enqueue_economy_origin_country_asset(busy, local)) {
        error = "country_handoff_self_test_seed_failed";
        return false;
    }
    if (probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local) ||
        local != "country_authority_handoff_busy") {
        error = "country_handoff_self_test_busy_failed";
        return false;
    }
    if (probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::SYNC) {
        error = "country_handoff_self_test_owner_mutated";
        return false;
    }
    probe._economy_origin_asset_queue.clear();
    probe._country_economy_asset_requests.clear();
    probe._country_economy_asset_protocol = {};
    if (probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local)) {
        // No published checkpoint yet: install must fail closed.
        if (probe.install_country_authority_handoff(local) ||
            local != "country_authority_handoff_checkpoint_missing") {
            error = "country_handoff_self_test_checkpoint_guard_failed";
            return false;
        }
        if (probe.country_authority_handoff_status().owner !=
                CountryAuthorityOwner::SYNC ||
            probe.country_authority_handoff_status().prepare_pending) {
            error = "country_handoff_self_test_checkpoint_owner_mutated";
            return false;
        }
    } else {
        error = local.empty() ? "country_handoff_self_test_prepare_failed" : local;
        return false;
    }
    // Install only requires a published capture pointer + catalog identity.
    // Avoid full POD shape validation here; production capture paths own that.
    auto fixture = std::make_shared<RuntimeCountryPodSnapshot>();
    fixture->bootstrapped = true;
    fixture->generation = 1;
    fixture->committed_day = 0;
    fixture->session_epoch = 7;
    std::atomic_store_explicit(
        &probe._country_snapshot,
        std::shared_ptr<const RuntimeCountryPodSnapshot>(fixture),
        std::memory_order_release);
    probe._country_pod_catalog.catalog_hash = 1;
    if (!probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local)) {
        error = local.empty() ? "country_handoff_self_test_prepare_failed" : local;
        return false;
    }
    if (!probe.abort_country_authority_handoff(local) ||
        probe.country_authority_handoff_status().prepare_pending ||
        probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::SYNC) {
        error = "country_handoff_self_test_abort_failed";
        return false;
    }
    const uint64_t epoch = probe._country_worker_session_epoch;
    if (!probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local)) {
        error = local.empty() ? "country_handoff_self_test_prepare_failed" : local;
        return false;
    }
    if (!probe.install_country_authority_handoff(local) ||
        probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::WORKER ||
        probe.country_authority_handoff_status().session_epoch <= epoch) {
        error = "country_handoff_self_test_install_failed";
        return false;
    }
    const uint64_t worker_epoch =
        probe.country_authority_handoff_status().session_epoch;
    if (!probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::SYNC, local) ||
        !probe.install_country_authority_handoff(local) ||
        probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::SYNC ||
        probe.country_authority_handoff_status().session_epoch <= worker_epoch) {
        error = "country_handoff_self_test_roundtrip_failed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::poll_country_worker_intent(CountryPeerIntent &out) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    while (!_country_worker_intent_queue.empty()) {
        const uint64_t request_id = _country_worker_intent_queue.front();
        _country_worker_intent_queue.pop_front();
        const auto it = _country_worker_intents.find(request_id);
        if (it == _country_worker_intents.end()) continue;
        out = it->second;
        _country_worker_protocol.queued_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intent_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
        return true;
    }
    _country_worker_protocol.queued_intents = static_cast<uint32_t>(
        std::min<size_t>(_country_worker_intent_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    return false;
}

bool NativeSimulationHost::poll_country_worker_notification(
        CountryWorkerNotification &out) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    if (_country_worker_notifications.empty()) return false;
    out = std::move(_country_worker_notifications.front());
    _country_worker_notifications.pop_front();
    return true;
}

void NativeSimulationHost::queue_country_milestone_notifications_locked(
        const std::shared_ptr<const RuntimeCountryPodSnapshot> &snapshot) {
    if (snapshot == nullptr) return;
    for (const RuntimeCountryPodMilestoneActivation &activation :
         _country_pod_plan.activated_milestones) {
        if (activation.slot < 0 ||
            static_cast<size_t>(activation.slot) >=
                snapshot->country_generation.size())
            continue;
        CountryWorkerNotification notification;
        CountryPeerIntent &intent = notification.intent;
        intent.opcode = CountryPeerIntentCode::NOTIFY_ERA_REWARD;
        intent.session_epoch = _country_worker_session_epoch;
        intent.country_generation = snapshot->generation;
        intent.day = _country_pod_plan.header.day;
        intent.country_slot = activation.slot;
        intent.technology = activation.technology;
        intent.target_handle =
            (static_cast<uint64_t>(snapshot->country_generation[
                static_cast<size_t>(activation.slot)]) << 32u) |
            static_cast<uint32_t>(activation.slot);
        intent.request_id = country_peer_request_id(
            intent.session_epoch, intent.country_generation, intent.day, 0u,
            intent.country_slot, intent.technology, intent.opcode);
        intent.idempotency_key = intent.request_id;
        notification.snapshot = snapshot;
        _country_worker_notifications.push_back(std::move(notification));
    }
}

bool NativeSimulationHost::submit_country_worker_result(
        const CountryPeerResult &result, std::string &error) {
    error.clear();
    if (result.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION) {
        error = "country_worker_result_protocol_mismatch";
        return false;
    }
    if (result.request_id == 0 || result.code == CountryPeerResultCode::STALE) {
        error = result.request_id == 0
            ? "country_worker_result_request_invalid"
            : "country_worker_result_stale_terminal_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto intent = _country_worker_intents.find(result.request_id);
    const auto terminal = _country_worker_terminal_results.find(result.request_id);
    if (intent == _country_worker_intents.end()) {
        if (terminal != _country_worker_terminal_results.end()) {
            const CountryPeerResult &previous = terminal->second;
            if (previous.code == result.code &&
                previous.session_epoch == result.session_epoch &&
                previous.country_generation == result.country_generation &&
                previous.peer_generation == result.peer_generation &&
                previous.technology_flags == result.technology_flags) {
                return true;
            }
            error = "country_worker_result_duplicate_mismatch";
            return false;
        }
        error = "country_worker_result_request_unknown";
        return false;
    }
    const CountryPeerIntent &expected = intent->second;
    if (expected.session_epoch != result.session_epoch ||
        expected.country_generation != result.country_generation ||
        expected.peer_generation != result.peer_generation ||
        expected.day != result.day ||
        expected.continuation_index != result.continuation_index ||
        expected.country_slot != result.country_slot ||
        expected.technology != result.technology ||
        expected.target_handle != result.target_handle ||
        expected.opcode != result.opcode) {
        error = "country_worker_result_identity_mismatch";
        return false;
    }
    if (result.committed_peer_generation < result.peer_generation) {
        error = "country_worker_result_generation_invalid";
        return false;
    }
    const auto existing = _country_worker_results.find(result.request_id);
    if (existing != _country_worker_results.end()) {
        const CountryPeerResult &previous = existing->second;
        if (previous.code == result.code &&
            previous.committed_peer_generation == result.committed_peer_generation &&
            previous.technology_flags == result.technology_flags) {
            return true;
        }
        if (previous.code != CountryPeerResultCode::PENDING) {
            error = "country_worker_result_duplicate_mismatch";
            return false;
        }
    }
    _country_worker_results[result.request_id] = result;
    if (result.code != CountryPeerResultCode::PENDING) {
        _country_worker_terminal_results[result.request_id] = result;
    }
    // A PENDING result is deliberately not re-queued. poll_country_worker_intent
    // already removed the id, and pushing it back let the caller's own drain
    // loop re-execute the same Effect probe up to 64 times per pump while
    // holding this mutex — that is what stalled the main thread. The Country
    // stage instead closes the day with the technology still pending and emits
    // a fresh intent next day, so each probe runs at most once per day.
    if (result.code == CountryPeerResultCode::REJECTED) {
        ++_country_worker_protocol.rejected_intents;
        country_peer_copy_reason(_country_worker_protocol.rejection_reason,
                                 result.reason.data());
    }
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

NativeSimulationHost::CountryWorkerProtocolStatus
NativeSimulationHost::country_worker_protocol_status() const {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    CountryWorkerProtocolStatus out;
    out.protocol_version = _country_worker_protocol.protocol_version;
    out.configured = _country_pod_configured;
    out.plan_active = _country_pod_plan_active;
    out.waiting_for_peer = _country_worker_protocol.pending_intents != 0;
    out.pending_intents = _country_worker_protocol.pending_intents;
    out.queued_intents = static_cast<uint32_t>(
        std::min<size_t>(_country_worker_intent_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    out.result_count = static_cast<uint32_t>(
        std::min<size_t>(_country_worker_results.size(),
                         std::numeric_limits<uint32_t>::max()));
    out.rejected_results = _country_worker_protocol.rejected_intents;
    out.rejected_intents = _country_worker_protocol.rejected_intents;
    out.has_unreported_rejection =
        _country_worker_protocol.has_unreported_rejection != 0;
    out.retry_day = _country_worker_protocol.retry_day;
    out.rejected_request_id = _country_worker_protocol.rejected_request_id;
    out.session_epoch = _country_worker_session_epoch;
    out.country_generation = _country_worker_country_generation;
    out.day = _country_worker_day;
    out.continuation_index = _country_worker_continuation_index;
    out.boundary_id = _country_worker_seal.boundary_id;
    out.last_admitted_submit_order =
        _country_worker_seal.last_admitted_submit_order;
    out.expected_base_generation = _country_worker_seal.expected_base_generation;
    out.catalog_hash = _country_worker_seal.catalog_hash;
    runtime_copy_text(out.last_reason,
                      _country_worker_protocol.rejection_reason.data());
    return out;
}

RuntimeCountryReadView NativeSimulationHost::country_worker_read_view(
        uint64_t after_generation) const {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    RuntimeCountryReadView out;
    out.generation = _country_read_view_generation;
    out.patch_base_generation = _country_read_view_patch_base_generation;
    out.dirty_families = _country_read_view_dirty_families;
    out.territory_watermark =
        (_country_read_view_dirty_families & RUNTIME_DIRTY_COUNTRY_TERRITORY) != 0
            ? _country_read_view_generation : 0;
    out.research_watermark =
        (_country_read_view_dirty_families & RUNTIME_DIRTY_COUNTRY_STATE) != 0
            ? _country_read_view_generation : 0;
    out.tax_watermark = 0;
    out.visual_watermark =
        (_country_read_view_dirty_families & RUNTIME_DIRTY_COUNTRY_VISUAL_ERA) != 0
            ? _country_read_view_generation : 0;
    out.changed_cells = _country_read_view_changed_cells;
    out.changed_owners = _country_read_view_changed_owners;
    out.snapshot = _country_committed_snapshot;
    if (out.snapshot != nullptr) {
        out.committed_day = out.snapshot->committed_day;
        out.state_hash = out.snapshot->state_hash;
        out.country_count = out.snapshot->country_count;
        out.cell_count = out.snapshot->cell_count;
    }
    out.available = out.snapshot != nullptr &&
        out.generation > after_generation;
    // A missed patch base only forces a full owner copy when territory changed
    // after the consumer's cursor. Cash, tax, and research publishes advance
    // the view generation without changing cell owners.
    // Host consumers must still advertise the real MapData owner diff on
    // country_committed — never cell_count — so vision/border stay O(changed).
    out.full_snapshot_required = out.available &&
        after_generation != 0 &&
        after_generation != out.patch_base_generation &&
        after_generation < _country_read_view_territory_generation;
    return out;
}

bool NativeSimulationHost::country_checkpoint_identity(
        uint64_t &generation, uint64_t &business_state_hash) const {
    const auto checkpoint = std::atomic_load_explicit(
        &_country_checkpoint, std::memory_order_acquire);
    if (checkpoint == nullptr) return false;
    generation = checkpoint->generation;
    business_state_hash = checkpoint->business_state_hash;
    return true;
}

bool NativeSimulationHost::publish_country_checkpoint(
        const CountryCoreCheckpoint &checkpoint, std::string &error) {
    if (!validate_country_core_checkpoint(checkpoint, error)) return false;
    auto copy = std::make_shared<CountryCoreCheckpoint>(checkpoint);
    std::atomic_store_explicit(&_country_checkpoint,
        std::shared_ptr<const CountryCoreCheckpoint>(std::move(copy)),
        std::memory_order_release);
    return true;
}

bool NativeSimulationHost::pending_country_checkpoint(
        CountryCoreCheckpoint &out, std::string &error) const {
    if (!_has_pending_restore || _pending_restore_bundle.country_bytes.empty()) {
        error = "country_checkpoint_not_pending";
        return false;
    }
    return decode_country_core_checkpoint(
        _pending_restore_bundle.country_bytes.data(),
        _pending_restore_bundle.country_bytes.size(), out, error);
}

RuntimeCountryPodDiagnostics NativeSimulationHost::country_pod_diagnostics() const {
    const auto value = std::atomic_load_explicit(&_country_pod_diagnostics,
        std::memory_order_acquire);
    return value != nullptr ? *value : RuntimeCountryPodDiagnostics{};
}

bool NativeSimulationHost::country_command_receipt_self_test(
        std::string &error) const {
    error.clear();
    const auto snapshot = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (snapshot == nullptr || _country_pod_catalog.catalog_hash == 0) {
        error = "country_receipt_self_test_capture_missing";
        return false;
    }

    // Run the protocol against a temporary Host so this test never mutates a
    // live worker, clock, queue, or peer adapter. It deliberately stops at the
    // Country boundary: the packet was admitted by transport but cannot be
    // decoded by the worker, which must become RejectedAtExecution exactly
    // once and remain queryable by cursor.
    NativeSimulationHost probe;
    probe._country_pod_catalog = _country_pod_catalog;
    std::string bootstrap_error;
    if (!probe._country_pod_authority.bootstrap(
            *snapshot, probe._country_pod_catalog, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_receipt_self_test_bootstrap_failed" : bootstrap_error;
        return false;
    }
    probe._country_pod_configured.store(true, std::memory_order_release);
    probe._country_worker_session_epoch = 1;

    RuntimeCountryCommand valid_command;
    valid_command.request_id = 9901;
    valid_command.producer_id = 0;
    valid_command.sequence = 1;
    valid_command.submit_order = 1;
    const int64_t probe_day = std::max<int64_t>(0, snapshot->committed_day);
    valid_command.requested_day = probe_day;
    valid_command.effective_day = probe_day + 1;
    valid_command.opcode = 5; // SET_RESEARCH_WEIGHTS
    // The command is intentionally queue-admission-valid but execution-invalid
    // for this protocol-only fixture. The second malformed packet must reject
    // the whole semantic batch and remove this first packet from POD pending.
    valid_command.target_handle = 0;
    valid_command.weights_bp = {2500, 2500, 2500, 2500};

    RuntimeCommandPacket valid_packet;
    valid_packet.envelope.request_id = valid_command.request_id;
    valid_packet.envelope.producer_id = valid_command.producer_id;
    valid_packet.envelope.sequence = valid_command.sequence;
    valid_packet.envelope.requested_day = valid_command.requested_day;
    valid_packet.envelope.effective_day = valid_command.effective_day;
    valid_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    valid_packet.envelope.opcode = valid_command.opcode;
    valid_packet.envelope.payload_offset = 0;
    valid_packet.envelope.payload_size = sizeof(RuntimeCountryCommand);
    std::memcpy(valid_packet.payload.data(), &valid_command,
                sizeof(valid_command));

    RuntimeCommandPacket malformed_packet;
    malformed_packet.envelope.request_id = 9902;
    malformed_packet.envelope.producer_id = 0;
    malformed_packet.envelope.sequence = 2;
    malformed_packet.envelope.requested_day = probe_day;
    malformed_packet.envelope.effective_day = probe_day + 1;
    malformed_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    malformed_packet.envelope.opcode = 3;
    malformed_packet.envelope.payload_offset = 0;
    malformed_packet.envelope.payload_size = 0;
    std::vector<RuntimeCommandPacket> commands{valid_packet, malformed_packet};
    RuntimeDayCommit commit;
    std::string stage_error;
    if (probe.execute_country_worker_stage(
            valid_packet.envelope.effective_day, 1, commands, commit,
            stage_error, 1)) {
        error = "country_receipt_self_test_expected_execution_rejection";
        return false;
    }
    std::vector<CountryCommandReceipt> receipts;
    probe.poll_country_command_receipts(0, 8, receipts);
    if (receipts.size() != 2 || receipts[0].request_id != 9901 ||
        receipts[1].request_id != 9902 ||
        receipts[0].code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
        receipts[1].code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
        receipts[0].reason.empty() || receipts[1].reason.empty() ||
        probe._country_pod_authority.pending_command_count() != 0) {
        error = "country_receipt_self_test_terminal_missing:" +
            std::to_string(receipts.size()) + ":" +
            std::to_string(probe._country_pod_authority.pending_command_count());
        return false;
    }
    std::vector<CountryCommandReceipt> continuation;
    probe.poll_country_command_receipts(9901, 8, continuation);
    if (continuation.size() != 1 || continuation[0].request_id != 9902) {
        error = "country_receipt_self_test_cursor_continuation_invalid";
        return false;
    }
    std::vector<CountryCommandReceipt> replay;
    probe.poll_country_command_receipts(9902, 8, replay);
    if (!replay.empty()) {
        error = "country_receipt_self_test_cursor_replayed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::country_peer_rejection_self_test(
        std::string &error) const {
    error.clear();
    const auto captured = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (captured == nullptr || _country_pod_catalog.catalog_hash == 0) {
        error = "country_rejection_self_test_capture_missing";
        return false;
    }

    RuntimeCountryPodSnapshot fixture = *captured;
    int32_t slot = -1;
    for (uint32_t candidate = 0; candidate < fixture.country_count; ++candidate) {
        if (fixture.country_active[candidate] != 0 &&
            fixture.territory_count[candidate] > 0) {
            slot = static_cast<int32_t>(candidate);
            break;
        }
    }
    if (slot < 0) {
        error = "country_rejection_self_test_active_country_missing";
        return false;
    }
    int32_t technology = -1;
    for (uint32_t candidate = 0;
         candidate < _country_pod_catalog.technology_count; ++candidate) {
        if (_country_pod_catalog.technology_effect_required[candidate] != 0) {
            technology = static_cast<int32_t>(candidate);
            break;
        }
    }
    if (technology < 0) {
        error = "country_rejection_self_test_effect_technology_missing";
        return false;
    }
    const size_t word_base = static_cast<size_t>(slot) * fixture.technology_words;
    for (uint32_t candidate = 0;
         candidate < fixture.technology_count; ++candidate) {
        const size_t word = word_base + candidate / 64u;
        const uint64_t bit = uint64_t{1} << (candidate % 64u);
        fixture.country_discovered[word] |= bit;
        fixture.country_pending_technologies[word] &= ~bit;
        if (static_cast<int32_t>(candidate) == technology)
            fixture.country_technologies[word] &= ~bit;
        else
            fixture.country_technologies[word] |= bit;
        fixture.research_progress[static_cast<size_t>(slot) *
            fixture.technology_count + candidate] = 0;
    }
    fixture.country_pending_technologies[word_base + static_cast<size_t>(
        technology / 64)] |= uint64_t{1} << (technology % 64);
    const int32_t domain = _country_pod_catalog.technology_domains[
        static_cast<size_t>(technology)];
    if (domain < 0 || domain >= static_cast<int32_t>(
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT)) {
        error = "country_rejection_self_test_domain_invalid";
        return false;
    }
    const size_t research_base = static_cast<size_t>(slot) *
        RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
    for (uint32_t lane = 0; lane < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++lane)
        fixture.research_weights_bp[research_base + lane] =
            lane == static_cast<uint32_t>(domain) ? 10000 : 0;
    for (uint32_t lane = 0; lane < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++lane) {
        const size_t queue_index = research_base + lane;
        fixture.research_queue_lengths[queue_index] = 0;
        const size_t queue_base = queue_index * 8u;
        for (uint32_t position = 0; position < 8u; ++position)
            fixture.research_queues[queue_base + position] = -1;
    }
    const size_t queue_index = research_base + static_cast<size_t>(domain);
    fixture.research_queue_lengths[queue_index] = 1;
    fixture.research_queues[queue_index * 8u] = technology;
    const size_t stock_index = static_cast<size_t>(slot) * fixture.good_count +
        static_cast<size_t>(_country_pod_catalog.technology_points_good_id);
    fixture.country_goods[stock_index] = 0;
    fixture.research_cost_factor[static_cast<size_t>(slot)] = 1.0;
    for (uint32_t lane = 0; lane < 4u; ++lane)
        fixture.research_efficiency[static_cast<size_t>(slot) * 4u + lane] = 1.0;
    fixture.research_active_index_valid = 1;
    fixture.research_active_country_slots = {slot};

    NativeSimulationHost probe;
    probe._country_pod_catalog = _country_pod_catalog;
    std::string bootstrap_error;
    if (!probe._country_pod_authority.bootstrap(
            fixture, probe._country_pod_catalog, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_rejection_self_test_bootstrap_failed" : bootstrap_error;
        return false;
    }
    probe._country_pod_configured.store(true, std::memory_order_release);
    probe._country_worker_session_epoch = 17;
    const int64_t rejected_day = fixture.committed_day + 1;
    RuntimeDayCommit first_commit;
    std::string stage_error;
    if (probe.execute_country_worker_stage(
            rejected_day, 1, {}, first_commit, stage_error, 1) ||
        probe._country_worker_intents.empty()) {
        error = "country_rejection_self_test_intent_missing";
        return false;
    }
    CountryPeerIntent intent;
    if (!probe.poll_country_worker_intent(intent)) {
        error = "country_rejection_self_test_poll_missing";
        return false;
    }
    CountryPeerResult rejected;
    rejected.code = CountryPeerResultCode::REJECTED;
    rejected.opcode = intent.opcode;
    rejected.request_id = intent.request_id;
    rejected.session_epoch = intent.session_epoch;
    rejected.country_generation = intent.country_generation;
    rejected.committed_peer_generation = intent.peer_generation;
    rejected.peer_generation = intent.peer_generation;
    rejected.day = intent.day;
    rejected.continuation_index = intent.continuation_index;
    rejected.country_slot = intent.country_slot;
    rejected.technology = intent.technology;
    rejected.target_handle = intent.target_handle;
    country_peer_copy_reason(rejected.reason, "self_test_peer_rejected");
    if (!probe.submit_country_worker_result(rejected, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_submit_failed" :
            stage_error;
        return false;
    }
    const uint64_t generation_before = probe._country_pod_authority.generation();
    RuntimeDayCommit rejected_commit;
    if (!probe.execute_country_worker_stage(
            rejected_day, 1, {}, rejected_commit, stage_error, 1) ||
        (rejected_commit.completed_domain_mask &
            runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u) {
        error = stage_error.empty() ? "country_rejection_self_test_not_committed" :
            stage_error;
        return false;
    }
    const CountryWorkerProtocolStatus rejected_status =
        probe.country_worker_protocol_status();
    RuntimeCountryPodSnapshot rejected_snapshot;
    if (!probe._country_pod_authority.snapshot(rejected_snapshot, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_snapshot_failed" :
            stage_error;
        return false;
    }
    const size_t target_bit_word = word_base + static_cast<size_t>(technology / 64);
    const uint64_t target_bit = uint64_t{1} << (technology % 64);
    const int64_t consumed_before_rejection = fixture.research_consumed_total[
        static_cast<size_t>(slot)];
    const int64_t consumed_after_rejection = rejected_snapshot.research_consumed_total[
        static_cast<size_t>(slot)];
    if (rejected_status.rejected_intents != 1 ||
        !rejected_status.has_unreported_rejection ||
        rejected_status.retry_day != rejected_day + 1 ||
        rejected_status.rejected_request_id != intent.request_id ||
        rejected_status.pending_intents != 0 ||
        probe._country_pod_authority.committed_day() != rejected_day ||
        probe._country_pod_authority.generation() != generation_before ||
        (rejected_snapshot.country_pending_technologies[target_bit_word] &
            target_bit) == 0 || consumed_after_rejection !=
            consumed_before_rejection ||
        !(rejected_status.plan_active || rejected_status.pending_intents != 0 ||
          rejected_status.result_count != 0 ||
          rejected_status.rejected_intents != 0 ||
          rejected_status.has_unreported_rejection)) {
        error = "country_rejection_self_test_barrier_state_invalid";
        return false;
    }
    CountryPeerResult duplicate = rejected;
    if (!probe.submit_country_worker_result(duplicate, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_duplicate_not_idempotent" :
            stage_error;
        return false;
    }
    CountryPeerIntent retry;
    RuntimeDayCommit retry_wait;
    if (probe.execute_country_worker_stage(
            rejected_day + 1, 1, {}, retry_wait, stage_error, 1) ||
        !probe.poll_country_worker_intent(retry) ||
        retry.request_id == intent.request_id) {
        error = "country_rejection_self_test_retry_identity_invalid";
        return false;
    }
    CountryPeerResult applied = rejected;
    applied.code = CountryPeerResultCode::APPLIED;
    applied.request_id = retry.request_id;
    applied.opcode = retry.opcode;
    applied.session_epoch = retry.session_epoch;
    applied.country_generation = retry.country_generation;
    applied.day = retry.day;
    applied.continuation_index = retry.continuation_index;
    applied.country_slot = retry.country_slot;
    applied.technology = retry.technology;
    applied.target_handle = retry.target_handle;
    applied.technology_flags = COUNTRY_PEER_EFFECT_FIRE_ACKED;
    if (!probe.submit_country_worker_result(applied, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_retry_submit_failed" :
            stage_error;
        return false;
    }
    RuntimeDayCommit retry_commit;
    if (!probe.execute_country_worker_stage(
            rejected_day + 1, 1, {}, retry_commit, stage_error, 1)) {
        error = stage_error.empty() ? "country_rejection_self_test_retry_commit_failed" :
            stage_error;
        return false;
    }
    RuntimeCountryPodSnapshot final_snapshot;
    if (!probe._country_pod_authority.snapshot(final_snapshot, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_final_snapshot_failed" :
            stage_error;
        return false;
    }
    const CountryWorkerProtocolStatus final_status =
        probe.country_worker_protocol_status();
    if ((final_snapshot.country_technologies[target_bit_word] & target_bit) == 0 ||
        final_snapshot.research_consumed_total[static_cast<size_t>(slot)] !=
            consumed_after_rejection || final_status.plan_active ||
        final_status.pending_intents != 0 || final_status.result_count != 0 ||
        final_status.rejected_intents != 0 ||
        final_status.has_unreported_rejection) {
        error = "country_rejection_self_test_final_state_invalid";
        return false;
    }
    return true;
}

} // namespace pk
