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
    // Economy may be parked on a cross-domain colonization SETTLE while it
    // waits for this territory snapshot to expose the preceding CLAIM. The
    // worker retry predicate watches _country_peer_signal; publishing the
    // snapshot without advancing that signal leaves the worker asleep until
    // an unrelated later command happens to wake it.
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
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
    // Territory readers must only observe sealed owners. Installing a
    // pending claim here would also hide it from the final owner diff.
    if ((_country_pod_plan.header.dirty_families &
         RUNTIME_DIRTY_COUNTRY_TERRITORY) != 0) {
        error = "country_plan_preview_territory_pending";
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
    if ((current != RuntimeWorkerState::STOPPED &&
         current != RuntimeWorkerState::FAULTED) || !execution_has_stopped()) {
        error = "country_catalog_publish_while_running";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    // Recapturing an unchanged catalog is not a new world or a new protocol.
    // Keep accepted requests, unclaimed terminals, and the committed snapshot.
    if (_country_pod_catalog.catalog_hash == catalog.catalog_hash) return true;
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
    _country_command_publications.clear();
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

#include "native_simulation_host_country_boundary_section_shadow_parity.inc"

#include "native_simulation_host_country_boundary_section_handoff.inc"

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
    out.territory_watermark = _country_read_view_territory_generation;
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

#include "native_simulation_host_country_boundary_section_command_and_peer_tests.inc"

} // namespace pk
