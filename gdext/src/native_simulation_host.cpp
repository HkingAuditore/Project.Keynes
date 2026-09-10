#include "native_simulation_host.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cmath>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace pk {

namespace {
template <typename T>
bool read_modifier_payload(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    if (data == nullptr || cursor > size || size - cursor < sizeof(T)) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(T);
    value = static_cast<T>(bits);
    return true;
}

bool decode_modifier_packet(const RuntimeCommandPacket &packet,
                            RuntimeModifierPodCommand &command) {
    const auto &envelope = packet.envelope;
    if (envelope.domain != static_cast<uint16_t>(RuntimeDomainId::MODIFIER) ||
        envelope.payload_offset > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD - envelope.payload_offset ||
        envelope.payload_size != RUNTIME_MODIFIER_POD_WIRE_SIZE) {
        return false;
    }
    size_t cursor = envelope.payload_offset;
    const size_t end = cursor + envelope.payload_size;
    uint32_t abi = 0;
    if (!read_modifier_payload(packet.payload.data(), end, cursor, abi) ||
        abi != RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION) return false;
    command = RuntimeModifierPodCommand{};
    command.request_id = envelope.request_id;
    command.producer_id = envelope.producer_id;
    command.sequence = envelope.sequence;
    command.requested_day = envelope.requested_day;
    command.effective_day = envelope.effective_day;
    command.opcode = envelope.opcode;
    uint16_t scope = 0;
    if (!read_modifier_payload(packet.payload.data(), end, cursor, command.domain) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, scope) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.definition_id) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.entity_handle) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.group_handle) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.source_type) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.source_id) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.duration_days) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.stacks) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.magnitude_q16) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.modifier_handle) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.target_generation) ||
        !read_modifier_payload(packet.payload.data(), end, cursor, command.input_generation) ||
        cursor != end) return false;
    command.scope = static_cast<int32_t>(scope);
    return true;
}

bool modifier_packet_shape_valid(const RuntimeModifierPodCommand &command) {
    return command.opcode >= static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY) &&
        command.opcode <= static_cast<uint16_t>(RuntimeModifierPodOpcode::SET_MAGNITUDE) &&
        command.domain < 4u && command.scope >= 0 && command.scope < 3 &&
        command.effective_day >= 0;
}

bool map_country_peer_intent(const RuntimeDomainIntent &intent,
                             CountryPeerIntentCode &opcode,
                             std::string &error) {
    error.clear();
    if (intent.source_domain !=
            static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
        error = "country_worker_peer_intent_source_domain_invalid";
        return false;
    }

    const uint16_t effect_domain =
        static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    const uint16_t modifier_domain =
        static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    const uint16_t economy_domain =
        static_cast<uint16_t>(RuntimeDomainId::ECONOMY);
    opcode = static_cast<CountryPeerIntentCode>(intent.opcode);
    switch (opcode) {
    case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
    case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
    case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
        if (intent.target_domain != effect_domain) {
            error = "country_worker_peer_intent_target_domain_mismatch";
            return false;
        }
        return true;
    case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
        if (intent.target_domain != modifier_domain) {
            error = "country_worker_peer_intent_target_domain_mismatch";
            return false;
        }
        return true;
    case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
        if (intent.target_domain != economy_domain) {
            error = "country_worker_peer_intent_target_domain_mismatch";
            return false;
        }
        return true;
    default:
        error = "country_worker_peer_intent_opcode_invalid";
        return false;
    }
}

bool economy_asset_operation_valid(RuntimeEconomyAssetOperation operation) {
    switch (operation) {
    case RuntimeEconomyAssetOperation::RESEARCH_PURCHASE:
    case RuntimeEconomyAssetOperation::FISCAL_RESERVE:
    case RuntimeEconomyAssetOperation::FISCAL_RETURN:
    case RuntimeEconomyAssetOperation::FISCAL_COLLECT:
    case RuntimeEconomyAssetOperation::CASH_TO_COHORT:
    case RuntimeEconomyAssetOperation::CASH_FROM_COHORT:
    case RuntimeEconomyAssetOperation::GOOD_TO_MARKET:
    case RuntimeEconomyAssetOperation::GOOD_FROM_MARKET:
    case RuntimeEconomyAssetOperation::TREASURY_SPEND:
        return true;
    default:
        return false;
    }
}

bool economy_asset_state_valid(RuntimeEconomyAssetState state) {
    switch (state) {
    case RuntimeEconomyAssetState::CREATED:
    case RuntimeEconomyAssetState::COUNTRY_PREPARED:
    case RuntimeEconomyAssetState::PEER_PREPARED:
    case RuntimeEconomyAssetState::COMMIT_DECIDED:
    case RuntimeEconomyAssetState::COUNTRY_APPLIED:
    case RuntimeEconomyAssetState::PEER_APPLIED:
    case RuntimeEconomyAssetState::COMPLETED:
    case RuntimeEconomyAssetState::REJECTED:
    case RuntimeEconomyAssetState::AWAITING_PEER_PREPARED:
    case RuntimeEconomyAssetState::AWAITING_PEER_APPLIED:
    case RuntimeEconomyAssetState::FAULTED:
        return true;
    default:
        return false;
    }
}

bool economy_asset_result_terminal(const RuntimeEconomyAssetResult &result) {
    return result.code == RuntimeEconomyAssetResultCode::COMPLETED ||
        result.code == RuntimeEconomyAssetResultCode::REJECTED ||
        result.code == RuntimeEconomyAssetResultCode::FAULTED ||
        result.state == RuntimeEconomyAssetState::COMPLETED ||
        result.state == RuntimeEconomyAssetState::REJECTED ||
        result.state == RuntimeEconomyAssetState::FAULTED;
}

int economy_asset_state_rank(RuntimeEconomyAssetState state) {
    switch (state) {
    case RuntimeEconomyAssetState::CREATED: return 0;
    case RuntimeEconomyAssetState::COUNTRY_PREPARED: return 1;
    case RuntimeEconomyAssetState::AWAITING_PEER_PREPARED: return 2;
    case RuntimeEconomyAssetState::PEER_PREPARED: return 3;
    case RuntimeEconomyAssetState::COMMIT_DECIDED: return 4;
    case RuntimeEconomyAssetState::AWAITING_PEER_APPLIED: return 5;
    case RuntimeEconomyAssetState::COUNTRY_APPLIED: return 6;
    case RuntimeEconomyAssetState::PEER_APPLIED: return 7;
    case RuntimeEconomyAssetState::COMPLETED: return 8;
    case RuntimeEconomyAssetState::REJECTED:
    case RuntimeEconomyAssetState::FAULTED: return 9;
    default: return -1;
    }
}

bool economy_asset_result_code_state_valid(
        const RuntimeEconomyAssetResult &result) {
    switch (result.code) {
    case RuntimeEconomyAssetResultCode::ACCEPTED:
        return result.state == RuntimeEconomyAssetState::CREATED ||
            result.state == RuntimeEconomyAssetState::COUNTRY_PREPARED;
    case RuntimeEconomyAssetResultCode::PENDING:
        return result.state == RuntimeEconomyAssetState::COUNTRY_PREPARED ||
            result.state == RuntimeEconomyAssetState::AWAITING_PEER_PREPARED ||
            result.state == RuntimeEconomyAssetState::COMMIT_DECIDED ||
            result.state == RuntimeEconomyAssetState::AWAITING_PEER_APPLIED ||
            result.state == RuntimeEconomyAssetState::COUNTRY_APPLIED;
    case RuntimeEconomyAssetResultCode::PEER_PREPARED:
        return result.state == RuntimeEconomyAssetState::PEER_PREPARED;
    case RuntimeEconomyAssetResultCode::COMMIT_DECIDED:
        return result.state == RuntimeEconomyAssetState::COMMIT_DECIDED;
    case RuntimeEconomyAssetResultCode::PEER_APPLIED:
        return result.state == RuntimeEconomyAssetState::PEER_APPLIED;
    case RuntimeEconomyAssetResultCode::COMPLETED:
        return result.state == RuntimeEconomyAssetState::COMPLETED;
    case RuntimeEconomyAssetResultCode::REJECTED:
        return result.state == RuntimeEconomyAssetState::REJECTED;
    case RuntimeEconomyAssetResultCode::FAULTED:
        return result.state == RuntimeEconomyAssetState::FAULTED;
    default:
        return false;
    }
}

bool economy_asset_request_equal(const RuntimeEconomyAssetRequest &lhs,
                                 const RuntimeEconomyAssetRequest &rhs) {
    return lhs.protocol_version == rhs.protocol_version &&
        lhs.operation == rhs.operation && lhs.state == rhs.state &&
        lhs.all_or_nothing == rhs.all_or_nothing &&
        lhs.reserved0 == rhs.reserved0 && lhs.reserved1 == rhs.reserved1 &&
        lhs.session_epoch == rhs.session_epoch &&
        lhs.transaction_id == rhs.transaction_id &&
        lhs.request_id == rhs.request_id &&
        lhs.origin_domain == rhs.origin_domain &&
        lhs.origin_epoch == rhs.origin_epoch &&
        lhs.origin_stage == rhs.origin_stage &&
        lhs.continuation_index == rhs.continuation_index &&
        lhs.day == rhs.day &&
        lhs.operation_sequence == rhs.operation_sequence &&
        lhs.country_generation == rhs.country_generation &&
        lhs.peer_generation == rhs.peer_generation &&
        lhs.country_handle == rhs.country_handle &&
        lhs.country_slot == rhs.country_slot &&
        lhs.target_slot == rhs.target_slot &&
        lhs.target_handle == rhs.target_handle &&
        lhs.good_id == rhs.good_id && lhs.good_count == rhs.good_count &&
        lhs.good_ids == rhs.good_ids &&
        lhs.good_quantities == rhs.good_quantities &&
        lhs.requested_quantity == rhs.requested_quantity &&
        lhs.prepared_quantity == rhs.prepared_quantity &&
        lhs.requested_cash == rhs.requested_cash &&
        lhs.reserved_cash == rhs.reserved_cash &&
        lhs.requested_goods_total == rhs.requested_goods_total &&
        lhs.reserved_goods_total == rhs.reserved_goods_total;
}

bool economy_asset_result_equal(const RuntimeEconomyAssetResult &lhs,
                                const RuntimeEconomyAssetResult &rhs) {
    return lhs.protocol_version == rhs.protocol_version &&
        lhs.code == rhs.code && lhs.state == rhs.state &&
        lhs.accepted == rhs.accepted && lhs.reserved0 == rhs.reserved0 &&
        lhs.reserved1 == rhs.reserved1 &&
        lhs.session_epoch == rhs.session_epoch &&
        lhs.transaction_id == rhs.transaction_id &&
        lhs.request_id == rhs.request_id && lhs.operation == rhs.operation &&
        lhs.continuation_index == rhs.continuation_index &&
        lhs.day == rhs.day &&
        lhs.country_generation == rhs.country_generation &&
        lhs.peer_generation == rhs.peer_generation &&
        lhs.committed_peer_generation == rhs.committed_peer_generation &&
        lhs.country_slot == rhs.country_slot &&
        lhs.target_slot == rhs.target_slot &&
        lhs.committed_quantity == rhs.committed_quantity &&
        lhs.committed_cash == rhs.committed_cash &&
        lhs.committed_goods_total == rhs.committed_goods_total &&
        lhs.reason == rhs.reason;
}

bool economy_asset_request_shape_valid(
        const RuntimeEconomyAssetRequest &request, std::string &error) {
    error.clear();
    if (request.protocol_version != RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION) {
        error = "country_economy_asset_request_protocol_mismatch";
        return false;
    }
    if (request.request_id == 0 || request.transaction_id == 0) {
        error = "country_economy_asset_request_identity_invalid";
        return false;
    }
    if (!economy_asset_operation_valid(request.operation) ||
        !economy_asset_state_valid(request.state) ||
        (request.state != RuntimeEconomyAssetState::CREATED &&
         request.state != RuntimeEconomyAssetState::COUNTRY_PREPARED)) {
        error = "country_economy_asset_request_state_invalid";
        return false;
    }
    if (request.day < 0 || request.good_count > RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY) {
        error = "country_economy_asset_request_shape_invalid";
        return false;
    }
    if (request.country_slot < -1 || request.target_slot < -1 ||
        request.good_id < -1 || request.origin_domain !=
            static_cast<uint32_t>(RuntimeDomainId::COUNTRY)) {
        error = "country_economy_asset_request_reference_invalid";
        return false;
    }
    const size_t count = static_cast<size_t>(request.good_count);
    for (size_t i = 0; i < count; ++i) {
        if (request.good_ids[i] < 0 || request.good_quantities[i] < 0) {
            error = "country_economy_asset_request_goods_invalid";
            return false;
        }
    }
    if (request.requested_quantity < 0 || request.prepared_quantity < 0 ||
        request.requested_cash < 0 || request.reserved_cash < 0 ||
        request.requested_goods_total < 0 || request.reserved_goods_total < 0) {
        error = "country_economy_asset_request_amount_invalid";
        return false;
    }
    if (request.prepared_quantity > request.requested_quantity &&
        request.requested_quantity != 0) {
        error = "country_economy_asset_request_prepared_quantity_invalid";
        return false;
    }
    if (request.reserved_cash > request.requested_cash &&
        request.requested_cash != 0) {
        error = "country_economy_asset_request_reserved_cash_invalid";
        return false;
    }
    if (request.reserved_goods_total > request.requested_goods_total &&
        request.requested_goods_total != 0) {
        error = "country_economy_asset_request_reserved_goods_invalid";
        return false;
    }
    return true;
}
}

NativeSimulationHost::NativeSimulationHost() {
    _pod_visual_intents.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
    _pod_receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    for (auto &sequence : _producer_sequences) {
        sequence.store(0, std::memory_order_relaxed);
    }
    for (uint64_t i = 0; i < RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
        _command_slots[i].sequence.store(i, std::memory_order_relaxed);
    }
    for (auto &generation : _dirty_family_generations) {
        generation.store(0, std::memory_order_relaxed);
    }
    for (auto &character : _fault_code) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    for (auto &character : _modifier_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _ideology_pod_ready.store(false, std::memory_order_release);
    _ideology_pod_plan_ms.store(0.0, std::memory_order_release);
    _ideology_pod_replay_ms.store(0.0, std::memory_order_release);
    _ideology_pod_state_hash.store(0, std::memory_order_release);
    _ideology_pod_snapshot_generation.store(0, std::memory_order_release);
    _ideology_pod_pending_transition_count.store(0, std::memory_order_release);
    _ideology_pod_intent_count.store(0, std::memory_order_release);
    for (auto &character : _ideology_pod_fallback_reason)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _events_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    for (auto &character : _ideology_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _country_pod_ready.store(false, std::memory_order_relaxed);
    for (auto &character : _country_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    // Keep the PKSR contract uniform even before the main-thread Effect
    // catalog is loaded. An empty catalog is a valid cold-start POD authority;
    // configure_effects() replaces it before any Effect instance can run.
    std::string effect_config_error;
    if (_effect_pod_authority.configure(_effect_pod_catalog,
                                        effect_config_error)) {
        _effect_pod_catalog.catalog_hash = _effect_pod_authority.catalog_hash();
        _effect_pod_configured = true;
    }
}

NativeSimulationHost::~NativeSimulationHost() {
    request_stop();
    join_for_destruction();
}

bool NativeSimulationHost::reap_completed_worker_nonblocking() {
    if (!_worker.joinable()) return true;

    // Do not move a joinable std::thread into a lambda capture directly: if
    // the std::thread constructor throws, destruction of that capture would
    // call std::terminate. A shared holder lets the failure path move the
    // handle back into this object without blocking the caller.
    auto holder = std::make_shared<std::thread>(std::move(_worker));
    _reaper_count.fetch_add(1, std::memory_order_acq_rel);
    try {
        std::thread([this, holder]() {
            if (holder->joinable()) holder->join();
            if (_reaper_count.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                std::lock_guard<std::mutex> lock(_control_mutex);
                _control_cv.notify_all();
            }
        }).detach();
    } catch (...) {
        _worker = std::move(*holder);
        _reaper_count.fetch_sub(1, std::memory_order_acq_rel);
        return false;
    }
    return true;
}

uint64_t NativeSimulationHost::now_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

uint64_t NativeSimulationHost::mix_hash(uint64_t value, uint64_t input) {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6) + (value >> 2);
    value *= 1099511628211ull;
    return value;
}

bool NativeSimulationHost::start(RuntimeSimulationMode mode,
                                  bool graph_coverage_complete,
                                  int64_t initial_day,
                                  double speed_days_per_second,
                                  bool paused,
                                  uint32_t requested_authority_mask) {
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
    if (mode == RuntimeSimulationMode::OFF) {
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _authority_ready.store(false, std::memory_order_release);
        _requested_authority_mask.store(0, std::memory_order_release);
        _authoritative_domain_mask.store(0, std::memory_order_release);
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
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (!graph_coverage_complete || wanted == 0u || ungranted != 0u)) {
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _authority_ready.store(false, std::memory_order_release);
        _requested_authority_mask.store(0, std::memory_order_release);
        _authoritative_domain_mask.store(0, std::memory_order_release);
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
    const int64_t start_day = restore_pending
        ? _pending_restore_bundle.committed_day : initial_day;
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
    _authority_ready.store(false, std::memory_order_release);
    // The request is recorded now; the grant is published only after a barrier
    // proves the worker actually ran those domains (see publish_day).
    _requested_authority_mask.store(wanted, std::memory_order_release);
    _authoritative_domain_mask.store(0, std::memory_order_release);
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
    _events_authority.reset();
    _events_snapshots.reset();
    _events_last_processed_day = -1;
    _events_pod_ready.store(false, std::memory_order_release);
    _events_pod_plan_ms.store(0.0, std::memory_order_release);
    _events_pod_replay_ms.store(0.0, std::memory_order_release);
    _events_pod_state_hash.store(0, std::memory_order_release);
    _events_pod_snapshot_generation.store(0, std::memory_order_release);
    _events_pod_event_count.store(0, std::memory_order_release);
    _events_pod_ack_count.store(0, std::memory_order_release);
    _events_pod_drop_count.store(0, std::memory_order_release);
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
            country_candidate_ready = country_candidate.bootstrap(
                *country_snapshot, _country_pod_catalog, country_config_error);
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
        _country_economy_asset_request_queue.clear();
        _country_economy_asset_requests.clear();
        _country_economy_asset_results.clear();
        _country_economy_asset_terminal_results.clear();
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
    _has_pending_restore = false;
    _pending_restore_bundle = RuntimeSaveBundle{};
    for (auto &character : _fault_code) character.store('\0', std::memory_order_relaxed);
    try {
        _worker = std::thread(&NativeSimulationHost::worker_main, this);
    } catch (...) {
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
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    return true;
}

void NativeSimulationHost::request_stop() {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED) return;
    // Revoke before the worker has actually wound down. The main-thread
    // schedule gate suppresses a promoted domain for as long as this mask names
    // it, so a domain must stop being worker-owned the instant a stop is asked
    // for. Leaving it set until the thread exits would drop the days in
    // between: nobody computes climate while the worker is on its way out.
    _authoritative_domain_mask.store(0, std::memory_order_release);
    _stop_requested.store(true, std::memory_order_release);
    if (current != RuntimeWorkerState::FAULTED) {
        _state.store(RuntimeWorkerState::STOPPING, std::memory_order_release);
    }
    _control_cv.notify_all();
}

void NativeSimulationHost::join_for_destruction() {
    if (_worker.joinable()) _worker.join();
    if (_reaper_count.load(std::memory_order_acquire) != 0) {
        std::unique_lock<std::mutex> lock(_control_mutex);
        _control_cv.wait(lock, [this]() {
            return _reaper_count.load(std::memory_order_acquire) == 0;
        });
    }
    _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
}

void NativeSimulationHost::set_clock(bool paused, double speed_days_per_second) {
    _paused.store(paused, std::memory_order_release);
    _speed_days_per_second.store(std::max(0.0, speed_days_per_second),
                                 std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::set_interactive(bool interactive) {
    _interactive.store(interactive, std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::record_visual_timings(
        double ui_input_to_feedback_ms,
        double visual_apply_ms,
        double gpu_upload_ms) {
    // Clamp and ignore NaN/Inf at the boundary so a broken renderer probe can
    // never poison the diagnostic stream or make a CSV parser fail.
    const auto sanitize = [](double value) {
        return std::isfinite(value) ? std::max(0.0, value) : 0.0;
    };
    _ui_input_to_feedback_ms.store(sanitize(ui_input_to_feedback_ms),
                                   std::memory_order_release);
    _visual_apply_ms.store(sanitize(visual_apply_ms), std::memory_order_release);
    _gpu_upload_ms.store(sanitize(gpu_upload_ms), std::memory_order_release);
}

bool NativeSimulationHost::publish_environment(
        const RuntimeEnvironmentSnapshot &snapshot, std::string &error) {
    error.clear();
    std::string validation_error;
    if (!validate_runtime_environment_snapshot(snapshot, validation_error)) {
        _invalid_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = validation_error;
        return false;
    }
    const auto previous = environment_snapshot();
    // Generation is the immutable publication sequence, not merely a day
    // label. Rejecting equality as well as rollback prevents duplicate trace
    // frames after restore or a repeated capture at the same day.
    if (previous != nullptr && snapshot.generation <= previous->generation) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_stale";
        return false;
    }
    // Under Climate authority the environment is Climate's only input, and
    // Climate's progress — not the worker clock's — is what makes a capture
    // stale. The worker clock advances off its own speed/debt accounting and
    // routinely runs ahead of the main thread; comparing against it rejected
    // every publish after the clock overtook the tick loop, which froze the
    // environment and silently stopped Climate. `sus_tick_daily` does not
    // inspect the capture result, so the rejection was invisible.
    const bool climate_authoritative_watermark =
        (_authoritative_domain_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    const int64_t stale_watermark = climate_authoritative_watermark
        ? _climate_committed_day.load(std::memory_order_acquire)
        : _committed_day.load(std::memory_order_acquire);
    if (snapshot.day < stale_watermark) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_before_committed_day";
        return false;
    }
    // The trace is the replay boundary, not a best-effort diagnostic side
    // channel. Reject the capture before publishing the live convenience
    // snapshot when its bounded storage is full; this preserves the invariant
    // that every accepted input has a corresponding OFF reference release.
    //
    // Skipped once Climate is worker-authoritative: production no longer runs,
    // so no reference will ever be released for these frames and nothing
    // consumes them. Pushing anyway would fill the bounded trace and then start
    // rejecting every environment publish with capacity_exceeded, which is the
    // one input ACTIVE Climate depends on.
    const bool climate_authoritative =
        (_authoritative_domain_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    if (!climate_authoritative && !_climate_trace.push(snapshot)) {
        error = "climate_trace_capacity_exceeded";
        return false;
    }
    auto copy = std::make_shared<RuntimeEnvironmentSnapshot>(snapshot);
    std::atomic_store_explicit(&_environment_snapshot,
        std::shared_ptr<const RuntimeEnvironmentSnapshot>(std::move(copy)),
        std::memory_order_release);
    _environment_generation.store(snapshot.generation, std::memory_order_release);
    _environment_day.store(snapshot.day, std::memory_order_release);
    _environment_cell_count.store(snapshot.cell_count, std::memory_order_release);
    _environment_topology_validated.store(snapshot.topology_validated,
                                           std::memory_order_release);
    // Under ACTIVE authority a fresh environment is the only thing that can
    // release a worker parked on a failed input barrier, so it has to wake it.
    _control_cv.notify_all();
    return true;
}

namespace {
// Copies text into an atomic char buffer one character at a time. The reader
// loads the same way, so a partially written value can be observed as a
// truncated string but never as a torn one.
template <size_t N>
void store_atomic_text(std::array<std::atomic<char>, N> &destination,
                       const char *source) {
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < N && source[index] != '\0'; ++index)
            destination[index].store(source[index], std::memory_order_relaxed);
    }
    for (; index < N; ++index)
        destination[index].store('\0', std::memory_order_relaxed);
}
} // namespace

void NativeSimulationHost::publish_climate_parity_divergence(
        const RuntimeClimateParityReport &diff) {
    _climate_parity_stage.store(diff.stage, std::memory_order_release);
    _climate_parity_cell.store(diff.cell, std::memory_order_release);
    store_atomic_text(_climate_parity_field, diff.field);
    store_atomic_text(_climate_parity_reference_bits, diff.reference_bits);
    store_atomic_text(_climate_parity_worker_bits, diff.worker_bits);
}

void NativeSimulationHost::clear_climate_parity_divergence() {
    _climate_parity_stage.store(0, std::memory_order_release);
    _climate_parity_cell.store(0, std::memory_order_release);
    store_atomic_text(_climate_parity_field, "");
    store_atomic_text(_climate_parity_reference_bits, "");
    store_atomic_text(_climate_parity_worker_bits, "");
}

void NativeSimulationHost::accumulate_climate_parity_fields(
        int64_t day, const RuntimeClimateStore &reference,
        const RuntimeClimateStore &worker) {
    const size_t field_count = runtime_climate_parity_field_count();
    if (field_count > RUNTIME_CLIMATE_PARITY_MAX_FIELDS) return;
    // Reused across days so a 1000-day run does not allocate per day.
    static thread_local std::vector<RuntimeClimateParityFieldDiff> diffs;
    diffs.resize(RUNTIME_CLIMATE_PARITY_MAX_FIELDS);
    runtime_climate_parity_field_divergence(reference, worker, diffs.data(),
                                           diffs.size());
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < field_count; ++i) {
        ClimateParityFieldAccumulator &slot = _climate_parity_field_stats[i];
        if (table[i].comparability !=
            RuntimeClimateParityComparability::COMPARABLE) {
            continue;
        }
        const RuntimeClimateParityFieldDiff &diff = diffs[i];
        slot.compared_days.fetch_add(1, std::memory_order_relaxed);
        slot.last_diverged_cells.store(diff.diverged_cells,
                                       std::memory_order_relaxed);
        slot.last_out_of_band_cells.store(diff.out_of_band_cells,
                                          std::memory_order_relaxed);
        if (diff.out_of_band_cells != 0) {
            slot.out_of_band_days.fetch_add(1, std::memory_order_relaxed);
            slot.out_of_band_cells.fetch_add(diff.out_of_band_cells,
                                             std::memory_order_relaxed);
            double previous_band = slot.max_out_of_band_delta.load(std::memory_order_relaxed);
            while (diff.max_abs_delta > previous_band &&
                   !slot.max_out_of_band_delta.compare_exchange_weak(
                       previous_band, diff.max_abs_delta,
                       std::memory_order_relaxed, std::memory_order_relaxed)) {
            }
            if (slot.first_out_of_band_day.load(std::memory_order_relaxed) < 0) {
                slot.first_out_of_band_day.store(day, std::memory_order_release);
            }
        }
        if (diff.diverged_cells == 0) continue;
        slot.diverged_days.fetch_add(1, std::memory_order_relaxed);
        slot.diverged_cells.fetch_add(diff.diverged_cells,
                                      std::memory_order_relaxed);
        double previous_delta = slot.max_abs_delta.load(std::memory_order_relaxed);
        while (diff.max_abs_delta > previous_delta &&
               !slot.max_abs_delta.compare_exchange_weak(
                   previous_delta, diff.max_abs_delta,
                   std::memory_order_relaxed, std::memory_order_relaxed)) {
        }
        // Only the first divergence carries diagnostic value: later days are
        // already downstream of it, so do not overwrite the evidence.
        if (slot.first_diverged_day.load(std::memory_order_relaxed) >= 0) continue;
        slot.first_cell.store(diff.first_cell, std::memory_order_relaxed);
        store_atomic_text(slot.first_reference_bits, diff.reference_bits);
        store_atomic_text(slot.first_worker_bits, diff.worker_bits);
        slot.first_diverged_day.store(day, std::memory_order_release);
    }
}

void NativeSimulationHost::reset_climate_parity_fields() {
    _climate_parity_forced_days.store(0, std::memory_order_release);
    for (ClimateParityFieldAccumulator &slot : _climate_parity_field_stats) {
        slot.diverged_days.store(0, std::memory_order_relaxed);
        slot.compared_days.store(0, std::memory_order_relaxed);
        slot.diverged_cells.store(0, std::memory_order_relaxed);
        slot.out_of_band_cells.store(0, std::memory_order_relaxed);
        slot.out_of_band_days.store(0, std::memory_order_relaxed);
        slot.first_out_of_band_day.store(-1, std::memory_order_relaxed);
        slot.first_cell.store(0, std::memory_order_relaxed);
        slot.last_diverged_cells.store(0, std::memory_order_relaxed);
        slot.last_out_of_band_cells.store(0, std::memory_order_relaxed);
        slot.max_abs_delta.store(0.0, std::memory_order_relaxed);
        slot.max_out_of_band_delta.store(0.0, std::memory_order_relaxed);
        store_atomic_text(slot.first_reference_bits, "");
        store_atomic_text(slot.first_worker_bits, "");
        slot.first_diverged_day.store(-1, std::memory_order_release);
    }
}

NativeSimulationHost::ClimateParityFieldStatus
NativeSimulationHost::climate_parity_field_status(size_t index) const {
    ClimateParityFieldStatus out;
    if (index >= _climate_parity_field_stats.size()) return out;
    const ClimateParityFieldAccumulator &slot = _climate_parity_field_stats[index];
    out.diverged_days = slot.diverged_days.load(std::memory_order_acquire);
    out.compared_days = slot.compared_days.load(std::memory_order_acquire);
    out.diverged_cells = slot.diverged_cells.load(std::memory_order_acquire);
    out.out_of_band_cells = slot.out_of_band_cells.load(std::memory_order_acquire);
    out.out_of_band_days = slot.out_of_band_days.load(std::memory_order_acquire);
    out.first_diverged_day = slot.first_diverged_day.load(std::memory_order_acquire);
    out.first_out_of_band_day =
        slot.first_out_of_band_day.load(std::memory_order_acquire);
    out.first_cell = slot.first_cell.load(std::memory_order_acquire);
    out.last_diverged_cells = slot.last_diverged_cells.load(std::memory_order_acquire);
    out.last_out_of_band_cells =
        slot.last_out_of_band_cells.load(std::memory_order_acquire);
    out.max_abs_delta = slot.max_abs_delta.load(std::memory_order_acquire);
    out.max_out_of_band_delta =
        slot.max_out_of_band_delta.load(std::memory_order_acquire);
    for (size_t i = 0; i < slot.first_reference_bits.size(); ++i) {
        out.first_reference_bits[i] =
            slot.first_reference_bits[i].load(std::memory_order_relaxed);
    }
    for (size_t i = 0; i < slot.first_worker_bits.size(); ++i) {
        out.first_worker_bits[i] =
            slot.first_worker_bits[i].load(std::memory_order_relaxed);
    }
    out.first_reference_bits[sizeof(out.first_reference_bits) - 1u] = '\0';
    out.first_worker_bits[sizeof(out.first_worker_bits) - 1u] = '\0';
    return out;
}

bool NativeSimulationHost::publish_climate_reference(
        int64_t day, uint64_t reference_state_hash,
        std::string &error,
        RuntimeClimateReferencePublish publish) {
    if (day < 0 || reference_state_hash == 0) {
        error = "climate_trace_reference_invalid";
        return false;
    }
    // A state whose own reduction disagrees with the published hash would make
    // every later comparison meaningless, so reject the pair rather than
    // storing an inconsistent frame.
    if (publish.reference_store != nullptr &&
        publish.reference_store->parity_hash() != reference_state_hash) {
        error = "climate_trace_reference_state_hash_inconsistent";
        return false;
    }
    uint64_t input_hash = 0;
    if (!_climate_trace.input_hash_for_day(day, input_hash)) {
        error = "climate_trace_reference_frame_missing";
        return false;
    }
    if (!_climate_trace.mark_reference_ready(
            day, input_hash, reference_state_hash, error, std::move(publish))) {
        return false;
    }
    const bool ready = _climate_trace.mark_consumable(day, error);
    if (ready) {
        _climate_trace_signal.fetch_add(1, std::memory_order_acq_rel);
        _control_cv.notify_all();
    }
    return ready;
}

bool NativeSimulationHost::publish_country_snapshot(
        const RuntimeCountryPodSnapshot &snapshot) {
    std::string error;
    if (!RuntimeCountryPodAdapter::validate_snapshot(snapshot, error)) return false;
    auto copy = std::make_shared<RuntimeCountryPodSnapshot>(snapshot);
    std::atomic_store_explicit(&_country_snapshot,
        std::shared_ptr<const RuntimeCountryPodSnapshot>(copy),
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
    auto committed_copy = std::make_shared<RuntimeCountryPodSnapshot>(
        std::move(snapshot));
    _country_committed_snapshot = committed_copy;
    std::shared_ptr<const RuntimeCountryPodSnapshot> committed_view =
        committed_copy;
    std::atomic_store_explicit(&_country_snapshot, committed_view,
                               std::memory_order_release);
    _country_worker_country_generation = committed_copy->generation;
    _country_worker_day = committed_copy->committed_day;
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
    _country_economy_asset_request_queue.clear();
    _country_economy_asset_requests.clear();
    _country_economy_asset_results.clear();
    _country_economy_asset_terminal_results.clear();
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

void NativeSimulationHost::set_country_economy_asset_protocol_error_locked(
        RuntimeEconomyAssetProtocolError code, uint64_t transaction_id,
        uint64_t request_id, const char *reason) noexcept {
    _country_economy_asset_protocol.last_error = code;
    _country_economy_asset_protocol.last_transaction_id = transaction_id;
    _country_economy_asset_protocol.last_request_id = request_id;
    country_peer_copy_reason(_country_economy_asset_protocol.last_reason,
                             reason == nullptr ? "" : reason);
}

bool NativeSimulationHost::publish_country_economy_asset_requests(
        const std::vector<RuntimeEconomyAssetRequest> &requests,
        std::string &error) {
    error.clear();
    if (requests.empty()) return true;

    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    std::unordered_set<uint64_t> batch_ids;
    batch_ids.reserve(requests.size());
    size_t queue_additions = 0;
    const auto queued = [this](uint64_t request_id) {
        return std::find(_country_economy_asset_request_queue.begin(),
                         _country_economy_asset_request_queue.end(),
                         request_id) != _country_economy_asset_request_queue.end();
    };

    // Validate the complete vector before publishing any element.  A worker
    // plan is a semantic batch; transport capacity or one malformed request
    // must never leave a partially visible Economy batch behind.
    for (const RuntimeEconomyAssetRequest &request : requests) {
        std::string shape_error;
        if (!economy_asset_request_shape_valid(request, shape_error)) {
            error = shape_error.empty()
                ? "country_economy_asset_request_invalid" : shape_error;
            set_country_economy_asset_protocol_error_locked(
                request.protocol_version == RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION
                    ? RuntimeEconomyAssetProtocolError::REQUEST_INVALID
                    : RuntimeEconomyAssetProtocolError::PROTOCOL_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        if (request.session_epoch != _country_worker_session_epoch) {
            error = "country_economy_asset_request_session_mismatch";
            set_country_economy_asset_protocol_error_locked(
                RuntimeEconomyAssetProtocolError::SESSION_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        if (!batch_ids.insert(request.request_id).second) {
            error = "country_economy_asset_request_duplicate_mismatch";
            set_country_economy_asset_protocol_error_locked(
                RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        const auto existing = _country_economy_asset_requests.find(
            request.request_id);
        if (existing != _country_economy_asset_requests.end()) {
            if (!economy_asset_request_equal(existing->second, request)) {
                error = "country_economy_asset_request_duplicate_mismatch";
                set_country_economy_asset_protocol_error_locked(
                    RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                    request.transaction_id, request.request_id, error.c_str());
                return false;
            }
            if (_country_economy_asset_terminal_results.find(request.request_id) ==
                    _country_economy_asset_terminal_results.end() &&
                !queued(request.request_id)) {
                ++queue_additions;
            }
            continue;
        }
        if (_country_economy_asset_terminal_results.find(request.request_id) !=
                _country_economy_asset_terminal_results.end()) {
            error = "country_economy_asset_request_duplicate_mismatch";
            set_country_economy_asset_protocol_error_locked(
                RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                request.transaction_id, request.request_id, error.c_str());
            return false;
        }
        ++queue_additions;
    }
    if (_country_economy_asset_request_queue.size() + queue_additions >
            RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
        error = "country_economy_asset_request_capacity_exceeded";
        set_country_economy_asset_protocol_error_locked(
            RuntimeEconomyAssetProtocolError::CAPACITY_EXCEEDED, 0, 0,
            error.c_str());
        return false;
    }

    for (const RuntimeEconomyAssetRequest &request : requests) {
        auto existing = _country_economy_asset_requests.find(
            request.request_id);
        if (existing == _country_economy_asset_requests.end()) {
            _country_economy_asset_requests.emplace(request.request_id, request);
            ++_country_economy_asset_protocol.pending_requests;
            existing = _country_economy_asset_requests.find(request.request_id);
        }
        if (_country_economy_asset_terminal_results.find(request.request_id) ==
                _country_economy_asset_terminal_results.end() &&
            !queued(request.request_id)) {
            _country_economy_asset_request_queue.push_back(request.request_id);
        }
        _country_economy_asset_protocol.last_transaction_id =
            request.transaction_id;
        _country_economy_asset_protocol.last_request_id = request.request_id;
    }
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    _country_economy_asset_protocol.last_error =
        RuntimeEconomyAssetProtocolError::NONE;
    country_peer_copy_reason(_country_economy_asset_protocol.last_reason, "");
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

void NativeSimulationHost::discard_country_economy_asset_requests(
        const std::vector<uint64_t> &request_ids) noexcept {
    if (request_ids.empty()) return;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    for (const uint64_t request_id : request_ids) {
        _country_economy_asset_request_queue.erase(
            std::remove(_country_economy_asset_request_queue.begin(),
                        _country_economy_asset_request_queue.end(), request_id),
            _country_economy_asset_request_queue.end());
        const auto request = _country_economy_asset_requests.find(request_id);
        if (request == _country_economy_asset_requests.end()) continue;
        _country_economy_asset_requests.erase(request);
        _country_economy_asset_results.erase(request_id);
        _country_economy_asset_terminal_results.erase(request_id);
        if (_country_economy_asset_protocol.pending_requests > 0)
            --_country_economy_asset_protocol.pending_requests;
    }
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    _country_economy_asset_protocol.terminal_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_terminal_results.size(),
                         std::numeric_limits<uint32_t>::max()));
}

bool NativeSimulationHost::poll_country_economy_asset_request(
        RuntimeEconomyAssetRequest &out) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    while (!_country_economy_asset_request_queue.empty()) {
        const uint64_t request_id =
            _country_economy_asset_request_queue.front();
        _country_economy_asset_request_queue.pop_front();
        const auto it = _country_economy_asset_requests.find(request_id);
        if (it == _country_economy_asset_requests.end()) continue;
        out = it->second;
        _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
            std::min<size_t>(_country_economy_asset_request_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
        _country_economy_asset_protocol.last_transaction_id =
            out.transaction_id;
        _country_economy_asset_protocol.last_request_id = out.request_id;
        return true;
    }
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    return false;
}

bool NativeSimulationHost::submit_country_economy_asset_result(
        const RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto reject = [&](RuntimeEconomyAssetProtocolError code,
                            const char *reason) {
        error = reason == nullptr ? "country_economy_asset_result_rejected" : reason;
        set_country_economy_asset_protocol_error_locked(
            code, result.transaction_id, result.request_id, error.c_str());
        return false;
    };
    if (result.protocol_version != RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION)
        return reject(RuntimeEconomyAssetProtocolError::PROTOCOL_MISMATCH,
                      "country_economy_asset_result_protocol_mismatch");
    if (result.request_id == 0 || result.transaction_id == 0)
        return reject(RuntimeEconomyAssetProtocolError::REQUEST_INVALID,
                      "country_economy_asset_result_identity_invalid");

    const auto request = _country_economy_asset_requests.find(result.request_id);
    if (request == _country_economy_asset_requests.end()) {
        const auto terminal = _country_economy_asset_terminal_results.find(
            result.request_id);
        if (terminal != _country_economy_asset_terminal_results.end() &&
            economy_asset_result_equal(terminal->second, result)) {
            return true;
        }
        return reject(RuntimeEconomyAssetProtocolError::REQUEST_UNKNOWN,
                      terminal == _country_economy_asset_terminal_results.end()
                          ? "country_economy_asset_result_request_unknown"
                          : "country_economy_asset_result_duplicate_mismatch");
    }
    const RuntimeEconomyAssetRequest &expected = request->second;
    if (expected.session_epoch != _country_worker_session_epoch ||
        result.session_epoch != expected.session_epoch)
        return reject(RuntimeEconomyAssetProtocolError::SESSION_MISMATCH,
                      "country_economy_asset_result_session_mismatch");
    if (result.transaction_id != expected.transaction_id ||
        result.operation != expected.operation ||
        result.continuation_index != expected.continuation_index ||
        result.day != expected.day ||
        result.country_slot != expected.country_slot ||
        result.target_slot != expected.target_slot)
        return reject(RuntimeEconomyAssetProtocolError::RESULT_IDENTITY_MISMATCH,
                      "country_economy_asset_result_identity_mismatch");
    if (result.country_generation != expected.country_generation ||
        result.peer_generation != expected.peer_generation ||
        result.committed_peer_generation < result.peer_generation)
        return reject(RuntimeEconomyAssetProtocolError::GENERATION_MISMATCH,
                      "country_economy_asset_result_generation_mismatch");
    if (!economy_asset_operation_valid(result.operation) ||
        !economy_asset_state_valid(result.state) ||
        !economy_asset_result_code_state_valid(result))
        return reject(RuntimeEconomyAssetProtocolError::RESULT_STATE_INVALID,
                      "country_economy_asset_result_state_invalid");
    if (result.committed_quantity < 0 || result.committed_cash < 0 ||
        result.committed_goods_total < 0 ||
        (expected.requested_quantity != 0 &&
         result.committed_quantity > expected.requested_quantity) ||
        (expected.requested_cash != 0 &&
         result.committed_cash > expected.requested_cash) ||
        (expected.requested_goods_total != 0 &&
         result.committed_goods_total > expected.requested_goods_total))
        return reject(RuntimeEconomyAssetProtocolError::RESULT_STATE_INVALID,
                      "country_economy_asset_result_amount_invalid");

    const auto existing = _country_economy_asset_results.find(
        result.request_id);
    if (existing != _country_economy_asset_results.end()) {
        if (economy_asset_result_equal(existing->second, result)) return true;
        if (economy_asset_result_terminal(existing->second) ||
            economy_asset_state_rank(result.state) <=
                economy_asset_state_rank(existing->second.state)) {
            return reject(RuntimeEconomyAssetProtocolError::RESULT_DUPLICATE_MISMATCH,
                          "country_economy_asset_result_duplicate_mismatch");
        }
    }

    const bool was_terminal = existing != _country_economy_asset_results.end() &&
        economy_asset_result_terminal(existing->second);
    _country_economy_asset_results[result.request_id] = result;
    if (economy_asset_result_terminal(result)) {
        _country_economy_asset_terminal_results[result.request_id] = result;
        if (!was_terminal && _country_economy_asset_protocol.pending_requests > 0)
            --_country_economy_asset_protocol.pending_requests;
        _country_economy_asset_protocol.terminal_requests = static_cast<uint32_t>(
            std::min<size_t>(_country_economy_asset_terminal_results.size(),
                             std::numeric_limits<uint32_t>::max()));
        if (result.code == RuntimeEconomyAssetResultCode::REJECTED)
            ++_country_economy_asset_protocol.rejected_results;
    }
    _country_economy_asset_protocol.last_transaction_id = result.transaction_id;
    _country_economy_asset_protocol.last_request_id = result.request_id;
    _country_economy_asset_protocol.last_error =
        RuntimeEconomyAssetProtocolError::NONE;
    country_peer_copy_reason(_country_economy_asset_protocol.last_reason, "");
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

RuntimeEconomyAssetProtocolStatus
NativeSimulationHost::country_economy_asset_protocol_status() const {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    RuntimeEconomyAssetProtocolStatus out = _country_economy_asset_protocol;
    out.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    size_t pending = 0;
    for (const auto &entry : _country_economy_asset_requests) {
        if (_country_economy_asset_terminal_results.find(entry.first) ==
                _country_economy_asset_terminal_results.end()) {
            ++pending;
        }
    }
    out.pending_requests = static_cast<uint32_t>(
        std::min<size_t>(pending, std::numeric_limits<uint32_t>::max()));
    out.terminal_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_terminal_results.size(),
                         std::numeric_limits<uint32_t>::max()));
    out.session_epoch = _country_worker_session_epoch;
    return out;
}

bool NativeSimulationHost::country_economy_asset_protocol_self_test(
        std::string &error) const {
    error.clear();
    NativeSimulationHost probe;
    probe._country_worker_session_epoch = 41;

    RuntimeEconomyAssetRequest request;
    request.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
    request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    request.session_epoch = 41;
    request.transaction_id = 7001;
    request.request_id = 7101;
    request.origin_epoch = 2;
    request.origin_stage = 9;
    request.continuation_index = 3;
    request.day = 12;
    request.operation_sequence = 99;
    request.country_generation = 5;
    request.peer_generation = 9;
    request.country_handle = 0x100000001ULL;
    request.country_slot = 0;
    request.target_slot = 2;
    request.good_count = 1;
    request.good_ids[0] = 4;
    request.good_quantities[0] = 7;
    request.requested_cash = 10;
    request.reserved_cash = 10;
    std::string publish_error;
    if (!probe.publish_country_economy_asset_requests({request}, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_publish_failed" : publish_error;
        return false;
    }
    RuntimeEconomyAssetRequest polled;
    if (!probe.poll_country_economy_asset_request(polled) ||
        !economy_asset_request_equal(polled, request)) {
        error = "country_economy_asset_self_test_poll_mismatch";
        return false;
    }
    RuntimeEconomyAssetRequest mismatch = request;
    mismatch.requested_cash = 11;
    if (probe.publish_country_economy_asset_requests({mismatch}, publish_error) ||
        publish_error != "country_economy_asset_request_duplicate_mismatch") {
        error = "country_economy_asset_self_test_duplicate_admission_failed";
        return false;
    }

    RuntimeEconomyAssetResult prepared;
    prepared.code = RuntimeEconomyAssetResultCode::PEER_PREPARED;
    prepared.state = RuntimeEconomyAssetState::PEER_PREPARED;
    prepared.accepted = 1;
    prepared.session_epoch = request.session_epoch;
    prepared.transaction_id = request.transaction_id;
    prepared.request_id = request.request_id;
    prepared.operation = request.operation;
    prepared.continuation_index = request.continuation_index;
    prepared.day = request.day;
    prepared.country_generation = request.country_generation;
    prepared.peer_generation = request.peer_generation;
    prepared.committed_peer_generation = 10;
    prepared.country_slot = request.country_slot;
    prepared.target_slot = request.target_slot;
    std::string result_error;
    if (!probe.submit_country_economy_asset_result(prepared, result_error) ||
        !probe.submit_country_economy_asset_result(prepared, result_error)) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_prepare_failed" : result_error;
        return false;
    }
    RuntimeEconomyAssetResult bad_generation = prepared;
    bad_generation.committed_peer_generation = 8;
    if (probe.submit_country_economy_asset_result(
            bad_generation, result_error) ||
        result_error != "country_economy_asset_result_generation_mismatch") {
        error = "country_economy_asset_self_test_generation_guard_failed";
        return false;
    }

    RuntimeEconomyAssetResult completed = prepared;
    completed.code = RuntimeEconomyAssetResultCode::COMPLETED;
    completed.state = RuntimeEconomyAssetState::COMPLETED;
    completed.committed_cash = 10;
    completed.committed_goods_total = 7;
    if (!probe.submit_country_economy_asset_result(completed, result_error) ||
        !probe.submit_country_economy_asset_result(completed, result_error)) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_complete_failed" : result_error;
        return false;
    }
    RuntimeEconomyAssetResult mismatched_terminal = completed;
    mismatched_terminal.reason[0] = 'x';
    if (probe.submit_country_economy_asset_result(
            mismatched_terminal, result_error) ||
        result_error != "country_economy_asset_result_duplicate_mismatch") {
        error = "country_economy_asset_self_test_terminal_guard_failed";
        return false;
    }
    const RuntimeEconomyAssetProtocolStatus status =
        probe.country_economy_asset_protocol_status();
    if (status.queued_requests != 0 || status.pending_requests != 0 ||
        status.terminal_requests != 1 || status.rejected_results != 0) {
        error = "country_economy_asset_self_test_status_mismatch";
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
    out.full_snapshot_required = out.available &&
        after_generation != 0 &&
        after_generation != out.patch_base_generation;
    return out;
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

bool NativeSimulationHost::configure_trigger_pod(
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    return _domain_authority_runner.configure_trigger_pod(catalog, error);
}

bool NativeSimulationHost::queue_trigger_pod_command(
        const RuntimeTriggerCommand &command, std::string &error) {
    return _domain_authority_runner.queue_trigger_command(command, error);
}

RuntimeTriggerPodDiagnostics NativeSimulationHost::trigger_pod_diagnostics() const {
    return _domain_authority_runner.trigger_pod_diagnostics();
}

bool NativeSimulationHost::set_trigger_reference_frame(
        int64_t day, uint64_t input_hash, uint64_t state_hash,
        uint64_t effect_hash, std::string &error) {
    return _domain_authority_runner.set_trigger_reference_frame(
        day, input_hash, state_hash, effect_hash, error);
}

const RuntimeTriggerPodCatalog &NativeSimulationHost::trigger_pod_catalog() const {
    return _domain_authority_runner.trigger_catalog();
}

bool NativeSimulationHost::encode_trigger_pod_save(std::vector<uint8_t> &bytes,
                                                   std::string &error) const {
    RuntimeTriggerPodSaveSection section;
    if (!_domain_authority_runner.encode_trigger_save(section, error)) return false;
    bytes = std::move(section.payload);
    return true;
}

bool NativeSimulationHost::restore_trigger_pod_save(const uint8_t *bytes,
                                                    size_t size,
                                                    std::string &error) {
    // TPD1 has a fixed header through state_hash plus the four bounded
    // capacity scalars: 80 bytes before any vector payload is decoded.
    if (bytes == nullptr || size < 80u) {
        error = "trigger_save_truncated";
        return false;
    }
    RuntimeTriggerPodSaveSection section;
    section.descriptor.domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    section.descriptor.version = RUNTIME_TRIGGER_POD_ABI_VERSION;
    section.descriptor.payload_size = static_cast<uint32_t>(size);
    section.payload.assign(bytes, bytes + size);
    const auto read_u64 = [bytes, size](size_t offset) {
        uint64_t value = 0;
        if (offset + sizeof(value) > size) return value;
        for (size_t i = 0; i < sizeof(value); ++i)
            value |= static_cast<uint64_t>(bytes[offset + i]) << (i * 8u);
        return value;
    };
    const auto read_i64 = [&read_u64](size_t offset) {
        const uint64_t bits = read_u64(offset);
        int64_t value = 0;
        std::memcpy(&value, &bits, sizeof(value));
        return value;
    };
    section.catalog_hash = read_u64(12u);
    section.generation = read_u64(20u);
    section.committed_day = read_i64(28u);
    section.state_hash = read_u64(36u);
    section.descriptor.checksum = 1469598103934665603ull;
    for (const uint8_t byte : section.payload) {
        section.descriptor.checksum ^= static_cast<uint64_t>(byte);
        section.descriptor.checksum *= 1099511628211ull;
    }
    const auto &catalog = _domain_authority_runner.trigger_catalog();
    return _domain_authority_runner.restore_trigger_save(section, catalog, error);
}

bool NativeSimulationHost::configure_modifier_pod(
        const RuntimeModifierPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "modifier_pod_configure_while_running";
        return false;
    }
    if (!_modifier_pod_authority.configure(catalog, error)) {
        _modifier_pod_configured = false;
        return false;
    }
    _modifier_pod_catalog = catalog;
    _modifier_pod_catalog.catalog_hash = _modifier_pod_authority.catalog_hash();
    _modifier_pod_configured = true;
    return true;
}

bool NativeSimulationHost::configure_effect_pod(
        const RuntimeEffectPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "effect_pod_configure_while_running";
        return false;
    }
    RuntimeEffectPodAuthority candidate;
    if (!candidate.configure(catalog, error)) {
        return false;
    }
    _effect_pod_authority = std::move(candidate);
    _effect_pod_catalog = catalog;
    _effect_pod_catalog.catalog_hash = _effect_pod_authority.catalog_hash();
    _effect_pod_configured = true;
    return true;
}

bool NativeSimulationHost::encode_effect_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    _effect_pod_authority.serialize(bytes);
    if (bytes.empty()) {
        error = "effect_pod_save_encode_failed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::restore_effect_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    RuntimeEffectPodAuthority candidate;
    if (!candidate.configure(_effect_pod_catalog, error)) return false;
    if (!candidate.restore(bytes, size, error)) return false;
    _effect_pod_authority = std::move(candidate);
    return true;
}

bool NativeSimulationHost::effect_pod_self_test(std::string *out_error) const {
    std::string error;
    const bool ok = RuntimeEffectPodAuthority::self_test(error);
    if (!ok && out_error != nullptr) *out_error = error;
    return ok;
}

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
    _ideology_commands.clear();
    _ideology_intents.clear();
    _ideology_acks.clear();
    return true;
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
    auto copy = std::make_shared<RuntimeIdeologyOpinionSnapshot>(snapshot);
    std::atomic_store_explicit(&_ideology_opinion_snapshot,
        std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>(std::move(copy)),
        std::memory_order_release);
    return true;
}

bool NativeSimulationHost::queue_ideology_pod_command(
        const RuntimeIdeologyPodCommand &command, std::string &error) {
    if (!_ideology_pod_configured) { error = "ideology_pod_not_configured"; return false; }
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    if (_ideology_commands.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "ideology_command_capacity_exceeded";
        return false;
    }
    _ideology_commands.push_back(command);
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
    _ideology_pod_authority.serialize(bytes);
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
    return true;
}

bool NativeSimulationHost::ideology_pod_self_test(std::string *out_error) const {
    std::string error;
    const bool ok = RuntimeIdeologyPodAuthority::self_test(error);
    if (!ok && out_error != nullptr) *out_error = error;
    return ok;
}

bool NativeSimulationHost::encode_modifier_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_modifier_pod_configured) { error = "modifier_pod_not_configured"; return false; }
    _modifier_pod_authority.serialize(bytes);
    return !bytes.empty();
}

bool NativeSimulationHost::restore_modifier_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_modifier_pod_configured) { error = "modifier_pod_not_configured"; return false; }
    return _modifier_pod_authority.restore(bytes, size, error);
}

bool NativeSimulationHost::try_acquire_modifier_snapshot(
        uint64_t after_generation, uint32_t &slot) {
    if (!_modifier_snapshots.try_acquire_latest(after_generation, slot)) return false;
    const RuntimeModifierPodSnapshot &snapshot =
        _modifier_snapshots.read_buffer(slot);
    bool valid = _modifier_pod_configured &&
        snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _modifier_pod_catalog.catalog_hash;
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        valid = valid && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        valid = valid && bucket.domain < 4 && bucket.scope < 3;
    if (!valid) {
        _modifier_snapshots.release(slot);
        return false;
    }
    return true;
}

const RuntimeModifierPodSnapshot &NativeSimulationHost::modifier_snapshot_buffer(
        uint32_t slot) const { return _modifier_snapshots.read_buffer(slot); }

void NativeSimulationHost::release_modifier_snapshot(uint32_t slot) {
    _modifier_snapshots.release(slot);
}

bool NativeSimulationHost::modifier_pod_self_test(std::string *out_error) const {
    const auto fail = [out_error](const char *reason) {
        if (out_error != nullptr) *out_error = reason;
        return false;
    };
    std::string authority_error;
    if (!RuntimeModifierPodAuthority::self_test(authority_error)) {
        if (out_error != nullptr) *out_error = authority_error;
        return false;
    }
    if (!RuntimeModifierSnapshotRing::self_test())
        return fail("modifier_pod_snapshot_ring_self_test_failed");
    RuntimeCommandPacket packet;
    packet.envelope.request_id = 11;
    packet.envelope.producer_id = 7;
    packet.envelope.sequence = 9;
    packet.envelope.requested_day = 3;
    packet.envelope.effective_day = 4;
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    packet.envelope.opcode = static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY);
    packet.envelope.payload_size = RUNTIME_MODIFIER_POD_WIRE_SIZE;
    // Keep the protocol self-test coupled to the fixed little-endian payload ABI.
    size_t cursor = 0;
    const auto append = [&packet, &cursor](auto value) {
        using T = decltype(value);
        using U = std::make_unsigned_t<T>;
        U bits = static_cast<U>(value);
        for (size_t i = 0; i < sizeof(T); ++i) {
            packet.payload[cursor++] = static_cast<uint8_t>(bits & static_cast<U>(0xffu));
            bits >>= 8u;
        }
    };
    append(static_cast<uint32_t>(RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION));
    append(static_cast<uint16_t>(2));
    append(static_cast<uint16_t>(2));
    append(static_cast<int32_t>(5));
    append(static_cast<uint64_t>(0x0000000300000004ull));
    append(static_cast<uint64_t>(6));
    append(static_cast<uint64_t>(7));
    append(static_cast<uint64_t>(8));
    append(static_cast<int32_t>(10));
    append(static_cast<int32_t>(2));
    append(static_cast<int32_t>(32768));
    append(static_cast<uint64_t>(0));
    append(static_cast<uint32_t>(3));
    append(static_cast<uint64_t>(12));
    RuntimeModifierPodCommand decoded;
    if (cursor != RUNTIME_MODIFIER_POD_WIRE_SIZE ||
        !decode_modifier_packet(packet, decoded) ||
        !modifier_packet_shape_valid(decoded) || decoded.request_id != 11 ||
        decoded.domain != 2 || decoded.scope != 2 || decoded.definition_id != 5 ||
        decoded.target_generation != 3 || decoded.input_generation != 12)
        return fail("modifier_pod_wire_decode_self_test_failed");
    RuntimeCommandPacket malformed = packet;
    --malformed.envelope.payload_size;
    if (decode_modifier_packet(malformed, decoded))
        return fail("modifier_pod_wire_size_self_test_failed");
    malformed = packet;
    malformed.payload[0] ^= 0xffu;
    if (decode_modifier_packet(malformed, decoded))
        return fail("modifier_pod_wire_abi_self_test_failed");
    malformed = packet;
    malformed.envelope.opcode = 0;
    if (!decode_modifier_packet(malformed, decoded) ||
        modifier_packet_shape_valid(decoded))
        return fail("modifier_pod_wire_opcode_self_test_failed");
    malformed = packet;
    malformed.payload[4] = 4;
    malformed.payload[5] = 0;
    if (!decode_modifier_packet(malformed, decoded) ||
        modifier_packet_shape_valid(decoded))
        return fail("modifier_pod_wire_domain_self_test_failed");
    if (out_error != nullptr) out_error->clear();
    return true;
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
NativeSimulationHost::environment_snapshot() const {
    return std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire);
}

bool NativeSimulationHost::enqueue(RuntimeCommandPacket packet) {
    std::vector<RuntimeCommandPacket> packets;
    packets.reserve(1);
    packets.push_back(std::move(packet));
    return enqueue_batch(std::move(packets));
}

bool NativeSimulationHost::enqueue_batch(
        std::vector<RuntimeCommandPacket> packets) {
    if (packets.empty()) return false;
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED ||
        current == RuntimeWorkerState::STOPPING ||
        current == RuntimeWorkerState::FAULTED) return false;

    // Serialise producers for the batch path. The consumer remains lock-free
    // and may advance dequeue_pos while this lock is held.
    std::lock_guard<std::mutex> lock(_command_enqueue_mutex);
    const uint64_t write = _command_enqueue_pos.load(std::memory_order_relaxed);
    const uint64_t read = _command_dequeue_pos.load(std::memory_order_acquire);
    if (packets.size() > RUNTIME_COMMAND_QUEUE_CAPACITY ||
        write - read > RUNTIME_COMMAND_QUEUE_CAPACITY - packets.size()) {
        _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    for (size_t index = 0; index < packets.size(); ++index) {
        const uint64_t position = write + static_cast<uint64_t>(index);
        CommandQueueSlot &slot = _command_slots[
            position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
        if (sequence != position) {
            _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
    }
    for (size_t index = 0; index < packets.size(); ++index) {
        RuntimeCommandPacket &packet = packets[index];
        if (packet.submit_order == 0) {
            packet.submit_order = _command_submit_order.fetch_add(
                1u, std::memory_order_relaxed) + 1u;
        }
        const uint64_t position = write + static_cast<uint64_t>(index);
        CommandQueueSlot &slot = _command_slots[
            position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        slot.packet = packet;
        slot.sequence.store(position + 1, std::memory_order_release);
    }
    // Country's typed lifecycle begins at Host admission. Keep this state
    // under the same transport mutex used by terminal publication so a save
    // boundary cannot observe a pending packet without its Accepted record.
    {
        std::lock_guard<std::mutex> country_lock(_country_transport_mutex);
        for (const RuntimeCommandPacket &packet : packets) {
            if (packet.envelope.domain !=
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
                packet.envelope.request_id == 0) {
                continue;
            }
            if (_country_command_states.find(packet.envelope.request_id) !=
                    _country_command_states.end()) {
                continue;
            }
            CountryCommandReceipt receipt;
            receipt.request_id = packet.envelope.request_id;
            receipt.producer_id = packet.envelope.producer_id;
            receipt.sequence = packet.envelope.sequence;
            receipt.effective_day = packet.envelope.effective_day;
            receipt.generation = _generation.load(std::memory_order_acquire);
            receipt.code = CountryCommandReceiptCode::ACCEPTED;
            _country_command_states.emplace(receipt.request_id,
                                             std::move(receipt));
        }
    }
    _command_enqueue_pos.store(write + packets.size(),
                               std::memory_order_release);
    _control_cv.notify_one();
    return true;
}

uint64_t NativeSimulationHost::allocate_command_request_id() {
    uint64_t value = _command_request_id.fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (value == 0) {
        value = _command_request_id.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    return value;
}

bool NativeSimulationHost::enqueue_modifier_shadow(RuntimeCommandPacket packet) {
    if (packet.envelope.domain !=
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) return false;
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current != RuntimeWorkerState::STOPPED) {
        if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::SHADOW)
            return false;
        return enqueue(std::move(packet));
    }
    if (packet.submit_order == 0) {
        packet.submit_order = _command_submit_order.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    std::lock_guard<std::mutex> lock(_control_mutex);
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::SHADOW)
            return false;
        return enqueue(std::move(packet));
    }
    if (_prestart_modifier_commands.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _prestart_modifier_commands.push_back(std::move(packet));
    return true;
}

uint64_t NativeSimulationHost::allocate_producer_sequence(uint32_t producer_id) {
    if (producer_id < _producer_sequences.size()) {
        return _producer_sequences[producer_id].fetch_add(1, std::memory_order_relaxed) + 1;
    }
    return _fallback_producer_sequence.fetch_add(1, std::memory_order_relaxed) + 1;
}

bool NativeSimulationHost::pop_command(RuntimeCommandPacket &out) {
    uint64_t position = _command_dequeue_pos.load(std::memory_order_relaxed);
    CommandQueueSlot *slot = nullptr;
    for (;;) {
        slot = &_command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        const uint64_t sequence = slot->sequence.load(std::memory_order_acquire);
        const int64_t difference = static_cast<int64_t>(sequence - (position + 1));
        if (difference == 0) {
            if (_command_dequeue_pos.compare_exchange_weak(
                    position, position + 1, std::memory_order_relaxed,
                    std::memory_order_relaxed)) {
                break;
            }
        } else if (difference < 0) {
            return false;
        } else {
            position = _command_dequeue_pos.load(std::memory_order_relaxed);
        }
    }
    out = slot->packet;
    slot->sequence.store(position + RUNTIME_COMMAND_QUEUE_CAPACITY,
                         std::memory_order_release);
    return true;
}

bool NativeSimulationHost::next_command(RuntimeCommandPacket &out) const {
    const uint64_t position = _command_dequeue_pos.load(std::memory_order_relaxed);
    const CommandQueueSlot &slot = _command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
    const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
    if (sequence != position + 1) return false;
    out = slot.packet;
    return true;
}

bool NativeSimulationHost::push_receipt(const RuntimeCommandReceipt &receipt) {
    const uint64_t write = _receipt_write.load(std::memory_order_relaxed);
    const uint64_t read = _receipt_read.load(std::memory_order_acquire);
    if (write - read >= RUNTIME_RECEIPT_QUEUE_CAPACITY) {
        _receipt_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _receipts[write % RUNTIME_RECEIPT_QUEUE_CAPACITY] = receipt;
    _receipt_write.store(write + 1, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::poll_receipt(RuntimeCommandReceipt &out) {
    const uint64_t read = _receipt_read.load(std::memory_order_relaxed);
    const uint64_t write = _receipt_write.load(std::memory_order_acquire);
    if (read == write) return false;
    out = _receipts[read % RUNTIME_RECEIPT_QUEUE_CAPACITY];
    _receipt_read.store(read + 1, std::memory_order_release);
    return true;
}

void NativeSimulationHost::publish_country_command_terminals(
        const std::vector<RuntimeCountryCommand> &commands,
        CountryCommandReceiptCode code, uint64_t generation,
        const char *reason) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    for (const RuntimeCountryCommand &command : commands) {
        if (command.request_id == 0 ||
            _country_command_terminals.find(command.request_id) !=
                _country_command_terminals.end()) {
            continue;
        }
        CountryCommandReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.producer_id = command.producer_id;
        receipt.sequence = command.sequence;
        receipt.effective_day = command.effective_day;
        receipt.generation = generation;
        receipt.code = code;
        if (reason != nullptr) receipt.reason = reason;
        _country_command_states[receipt.request_id] = receipt;
        _country_command_terminals.emplace(receipt.request_id,
                                           std::move(receipt));
    }
}

bool NativeSimulationHost::poll_country_command_receipts(
        uint64_t after_request_id, uint32_t limit,
        std::vector<CountryCommandReceipt> &out) {
    out.clear();
    const uint32_t bounded_limit = std::min<uint32_t>(limit, 4096u);
    if (bounded_limit == 0) return true;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    auto it = _country_command_terminals.upper_bound(after_request_id);
    for (; it != _country_command_terminals.end() &&
           out.size() < bounded_limit; ++it) {
        out.push_back(it->second);
    }
    return true;
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
    valid_command.requested_day = snapshot->committed_day;
    valid_command.effective_day = snapshot->committed_day + 1;
    valid_command.opcode = 5; // SET_RESEARCH_WEIGHTS
    // The command is intentionally queue-admission-valid but execution-invalid
    // for this protocol-only fixture. The second malformed packet must reject
    // the whole semantic batch and remove this first packet from POD pending.
    valid_command.target_handle = 0;

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
    malformed_packet.envelope.requested_day = snapshot->committed_day;
    malformed_packet.envelope.effective_day = snapshot->committed_day + 1;
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

bool NativeSimulationHost::poll_commit(uint64_t after_generation, RuntimeCommit &out) {
    const uint64_t latest_generation = _generation.load(std::memory_order_acquire);
    uint32_t index = 0;
    if (_snapshots.try_acquire_latest(after_generation, index)) {
        RuntimeCommit candidate = _snapshots.read_buffer(index);
        _snapshots.release(index);
        // Visual publication is intentionally throttled.  A READY buffer may
        // therefore describe an older generation than the authoritative scalar
        // header. Never move the facade backwards just because the newest
        // visual buffer is still within the 20 Hz window; return the scalar
        // boundary below and let visual patch consumption remain generation
        // aware.
        if (candidate.header.generation >= latest_generation) {
            out = std::move(candidate);
            return true;
        }
    }
    // The visual ring is allowed to drop intents under backpressure, but a
    // dropped buffer must not erase the authoritative commit boundary.
    const uint64_t generation = _generation.load(std::memory_order_acquire);
    // A throttled visual publication still advances the authoritative
    // generation. Return the scalar header even when no READY buffer exists;
    // the caller can then observe progress while visual patch consumption
    // remains generation-aware and may legitimately report no intents.
    if (generation == 0 || generation <= after_generation) return false;
    out = RuntimeCommit{};
    out.header.generation = generation;
    out.header.from_day = _latest_from_day.load(std::memory_order_acquire);
    out.header.committed_day = _latest_committed_day.load(std::memory_order_acquire);
    out.header.produced_at_us = _latest_produced_at_us.load(std::memory_order_acquire);
    out.header.dirty_families = _latest_dirty_families.load(std::memory_order_acquire);
    out.header.state_hash = _state_hash.load(std::memory_order_acquire);
    out.header.command_receipt_count = _latest_receipt_count.load(std::memory_order_acquire);
    for (size_t family_index = 0; family_index < RUNTIME_DIRTY_FAMILY_COUNT; ++family_index) {
        out.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    return true;
}

bool NativeSimulationHost::poll_commit_generation(uint64_t generation, RuntimeCommit &out) {
    uint32_t index = 0;
    if (_snapshots.try_acquire_generation(generation, index)) {
        out = _snapshots.read_buffer(index);
        _snapshots.release(index);
        return true;
    }
    // Exact lookup is only reconstructible for the newest scalar header. A
    // throttled generation has no visual buffer, but the current generation
    // is still a valid authoritative commit boundary.
    if (generation == 0 ||
        generation != _generation.load(std::memory_order_acquire)) return false;
    out = RuntimeCommit{};
    out.header.generation = generation;
    out.header.from_day = _latest_from_day.load(std::memory_order_acquire);
    out.header.committed_day = _latest_committed_day.load(std::memory_order_acquire);
    out.header.produced_at_us = _latest_produced_at_us.load(std::memory_order_acquire);
    out.header.dirty_families = _latest_dirty_families.load(std::memory_order_acquire);
    out.header.state_hash = _state_hash.load(std::memory_order_acquire);
    out.header.command_receipt_count = _latest_receipt_count.load(std::memory_order_acquire);
    for (size_t family_index = 0; family_index < RUNTIME_DIRTY_FAMILY_COUNT; ++family_index) {
        out.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    return true;
}

RuntimeDayPlan NativeSimulationHost::build_day_plan(
        int64_t day, double speed_scale,
        const RuntimeEnvironmentSnapshot *environment) const {
    RuntimeDayPlan plan;
    plan.context.day = day;
    plan.context.season_phase = environment != nullptr
        ? environment->season_phase : 0.0;
    plan.context.speed_scale = speed_scale;
    plan.context.input_generation = environment != nullptr
        ? environment->generation : 0;
    plan.context.environment = environment;

    constexpr auto order = runtime_domain_stage_order();
    for (uint32_t i = 0; i < plan.stage_count; ++i)
        plan.stages[i].domain = order[i];
    return plan;
}

bool NativeSimulationHost::execute_country_worker_stage(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeCommandPacket> &day_commands,
        RuntimeDayCommit &commit, std::string &error,
        uint64_t admitted_submit_order) {
    error.clear();
    if (!_country_pod_configured) return true;

    // Convert the sealed Country packet set once for terminal reporting. The
    // worker may reject the whole semantic batch before a POD plan exists, so
    // terminal receipts cannot depend only on RuntimeCountryPodPlan.commands.
    // A malformed packet still gets an execution rejection identified by its
    // transport envelope; it is never silently lost after admission.
    std::vector<RuntimeCountryCommand> sealed_country_commands;
    sealed_country_commands.reserve(day_commands.size());
    for (const RuntimeCommandPacket &packet : day_commands) {
        if (packet.envelope.domain !=
                static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
            continue;
        }
        RuntimeCountryCommand command;
        std::string command_error;
        if (!RuntimeCountryPodAdapter::decode_command(
                packet, command, command_error)) {
            command.request_id = packet.envelope.request_id;
            command.producer_id = packet.envelope.producer_id;
            command.sequence = packet.envelope.sequence;
            command.requested_day = packet.envelope.requested_day;
            command.effective_day = packet.envelope.effective_day;
            command.opcode = packet.envelope.opcode;
            command.submit_order = packet.submit_order;
        }
        sealed_country_commands.push_back(command);
    }
    std::vector<uint64_t> sealed_request_ids;
    sealed_request_ids.reserve(sealed_country_commands.size());
    for (const RuntimeCountryCommand &command : sealed_country_commands) {
        if (command.request_id != 0) sealed_request_ids.push_back(command.request_id);
    }

    if (!_country_pod_plan_active) {
        for (const RuntimeCommandPacket &packet : day_commands) {
            if (packet.envelope.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY))
                continue;
            RuntimeCountryCommand command;
            std::string command_error;
            if (!RuntimeCountryPodAdapter::decode_command(
                    packet, command, command_error) ||
                !_country_pod_authority.queue_command(command, command_error)) {
                error = command_error.empty()
                    ? "country_worker_command_rejected" : command_error;
                _country_pod_authority.remove_pending_commands(sealed_request_ids);
                publish_country_command_terminals(
                    sealed_country_commands,
                    CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                    _country_pod_authority.generation(), error.c_str());
                return false;
            }
        }
        if (!_country_pod_authority.plan_day(
                day, input_generation, _country_pod_plan, error)) {
            if (error.empty()) error = "country_worker_plan_failed";
            _country_pod_authority.remove_pending_commands(sealed_request_ids);
            publish_country_command_terminals(
                sealed_country_commands,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                _country_pod_authority.generation(), error.c_str());
            return false;
        }
        _country_pod_plan_active = true;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            ++_country_worker_seal.boundary_id;
            if (_country_worker_seal.boundary_id == 0)
                _country_worker_seal.boundary_id = 1;
            _country_worker_seal.session_epoch = _country_worker_session_epoch;
            _country_worker_seal.day = day;
            _country_worker_seal.last_admitted_submit_order = admitted_submit_order;
            _country_worker_seal.expected_base_generation =
                _country_pod_plan.header.base_generation;
            _country_worker_seal.catalog_hash = _country_pod_catalog.catalog_hash;
            _country_worker_country_generation =
                _country_pod_plan.header.base_generation;
            _country_worker_day = day;
            _country_worker_continuation_index = 0;
            for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                CountryPeerIntentCode peer_opcode;
                std::string peer_opcode_error;
                if (!map_country_peer_intent(intent, peer_opcode,
                                              peer_opcode_error)) {
                    error = peer_opcode_error.empty()
                        ? "country_worker_peer_intent_invalid"
                        : peer_opcode_error;
                    break;
                }
                CountryPeerIntent peer;
                peer.opcode = peer_opcode;
                peer.request_id = intent.request_id != 0
                    ? intent.request_id : intent.source_id;
                peer.session_epoch = _country_worker_session_epoch;
                peer.country_generation = _country_pod_plan.header.base_generation;
                peer.peer_generation = 0;
                peer.day = intent.effective_day;
                peer.continuation_index = _country_worker_continuation_index;
                peer.country_slot = static_cast<int32_t>(
                    intent.target_handle & 0xffffffffULL);
                peer.technology = intent.payload[0] >= 0
                    ? static_cast<int32_t>(intent.payload[0]) : -1;
                peer.target_handle = intent.target_handle;
                peer.effect_instance_id = peer.request_id;
                peer.effect_generation = intent.target_generation;
                peer.idempotency_key = intent.idempotency_key != 0
                    ? intent.idempotency_key : peer.request_id;
                if (peer.request_id == 0) {
                    error = "country_worker_peer_intent_identity_invalid";
                    break;
                }
                if (_country_worker_intents.find(peer.request_id) !=
                    _country_worker_intents.end()) {
                    error = "country_worker_peer_intent_duplicate";
                    break;
                }
                if (_country_worker_intent_queue.size() >=
                    RUNTIME_DOMAIN_INTENT_CAPACITY) {
                    error = "country_worker_intent_capacity_exceeded";
                    break;
                }
                _country_worker_intents[peer.request_id] = peer;
                _country_worker_intent_queue.push_back(peer.request_id);
                ++_country_worker_continuation_index;
            }
            if (error.empty()) {
                _country_worker_protocol.pending_intents = static_cast<uint32_t>(
                    std::min<size_t>(_country_worker_intents.size(),
                                     std::numeric_limits<uint32_t>::max()));
                _country_worker_protocol.queued_intents = static_cast<uint32_t>(
                    std::min<size_t>(_country_worker_intent_queue.size(),
                                     std::numeric_limits<uint32_t>::max()));
                _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
            }
        }
        if (!error.empty()) {
            _country_pod_authority.discard_plan();
            _country_pod_authority.remove_pending_commands(sealed_request_ids);
            _country_pod_plan_active.store(false, std::memory_order_release);
            publish_country_command_terminals(
                _country_pod_plan.commands,
                CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
                _country_pod_authority.generation(), error.c_str());
            return false;
        }
    }

    std::vector<RuntimeDomainAck> acks;
    acks.reserve(_country_pod_plan.intents.size());
    bool waiting = false;
    bool rejected = false;
    std::string rejection_reason;
    uint64_t rejected_request_id = 0;
    CountryPeerIntentCode rejected_opcode =
        CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
            const uint64_t request_id = intent.request_id != 0
                ? intent.request_id : intent.source_id;
            const auto result_it = _country_worker_results.find(request_id);
            if (result_it == _country_worker_results.end() ||
                result_it->second.code == CountryPeerResultCode::PENDING) {
                waiting = true;
                continue;
            }
            const CountryPeerResult &result = result_it->second;
            RuntimeDomainAck ack;
            ack.request_id = request_id;
            ack.transaction_id = request_id;
            ack.target_handle = intent.target_handle;
            ack.target_generation = intent.target_generation;
            ack.domain = intent.target_domain;
            ack.effective_day = intent.effective_day;
            ack.producer_id = intent.producer_id;
            ack.sequence = intent.sequence;
            ack.technology_flags = result.technology_flags;
            if (result.code == CountryPeerResultCode::READY ||
                result.code == CountryPeerResultCode::APPLIED) {
                ack.code = RuntimeDomainAckCode::OK;
            } else {
                ack.code = result.code == CountryPeerResultCode::STALE
                    ? RuntimeDomainAckCode::STALE_GENERATION
                    : RuntimeDomainAckCode::REJECTED;
                rejected = true;
                rejection_reason = result.reason.data();
                if (rejected_request_id == 0) {
                    rejected_request_id = request_id;
                    rejected_opcode = static_cast<CountryPeerIntentCode>(
                        intent.opcode);
                }
            }
            acks.push_back(ack);
        }
        _country_worker_protocol.pending_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intents.size(),
                             std::numeric_limits<uint32_t>::max()));
        _country_worker_protocol.queued_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intent_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
    }
    if (waiting) {
        error = "country_worker_peer_results_pending";
        commit.preflight_ok = 0;
        return false;
    }
    if (rejected) {
        // A peer rejection closes the Country semantic boundary. Country-side
        // commands, research consumption and pending activation remain
        // committed, while the peer operation is retained as a next-day retry
        // barrier. This is deliberately different from discard_plan():
        // discarding would replay the same research spend on the next day.
        if (!_country_pod_authority.commit_rejected_day(
                _country_pod_plan, error)) {
            _country_pod_authority.discard_plan();
            _country_pod_plan_active.store(false, std::memory_order_release);
            set_fault(error.empty() ? "country_worker_rejection_commit_failed" :
                      error.c_str());
            if (error.empty()) error = "country_worker_rejection_commit_failed";
            commit.preflight_ok = 0;
            return false;
        }
        publish_country_command_terminals(
            _country_pod_plan.commands, CountryCommandReceiptCode::COMMITTED,
            _country_pod_authority.generation(), nullptr);
        _country_pod_plan_active.store(false, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            _country_worker_protocol.has_unreported_rejection = 1;
            _country_worker_protocol.rejected_intents = std::max<uint32_t>(
                1u, _country_worker_protocol.rejected_intents);
            _country_worker_protocol.retry_day = day < INT64_MAX ? day + 1 : day;
            _country_worker_protocol.rejected_request_id = rejected_request_id;
            _country_worker_protocol.rejected_opcode = rejected_opcode;
            country_peer_copy_reason(_country_worker_protocol.rejection_reason,
                                     rejection_reason.c_str());
            for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                const uint64_t request_id = intent.request_id != 0
                    ? intent.request_id : intent.source_id;
                _country_worker_intents.erase(request_id);
                _country_worker_results.erase(request_id);
            }
            _country_worker_intent_queue.erase(
                std::remove_if(_country_worker_intent_queue.begin(),
                               _country_worker_intent_queue.end(),
                    [&](uint64_t request_id) {
                        return _country_worker_intents.find(request_id) ==
                            _country_worker_intents.end();
                    }), _country_worker_intent_queue.end());
            _country_worker_protocol.pending_intents = 0;
            _country_worker_protocol.queued_intents = static_cast<uint32_t>(
                std::min<size_t>(_country_worker_intent_queue.size(),
                                 std::numeric_limits<uint32_t>::max()));
        }
        std::string snapshot_error;
        if (!publish_country_worker_snapshot(
                _country_pod_plan.header.dirty_families, snapshot_error)) {
            error = snapshot_error.empty() ? "country_worker_snapshot_failed" :
                snapshot_error;
            commit.preflight_ok = 0;
            return false;
        }
        commit.completed_domain_mask |= runtime_domain_mask(
            RuntimeDomainId::COUNTRY);
        commit.dirty_families |= _country_pod_plan.header.dirty_families;
        commit.work_units += _country_pod_plan.header.work_units;
        ++commit.completed_stage_count;
        error.clear();
        return true;
    }
    if (!_country_pod_authority.commit_day(_country_pod_plan, acks, error)) {
        _country_pod_authority.discard_plan();
        _country_pod_plan_active.store(false, std::memory_order_release);
        set_fault(error.empty() ? "country_worker_commit_failed" : error.c_str());
        if (error.empty()) error = "country_worker_commit_failed";
        publish_country_command_terminals(
            _country_pod_plan.commands,
            CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
            _country_pod_authority.generation(), error.c_str());
        commit.preflight_ok = 0;
        return false;
    }
    publish_country_command_terminals(
        _country_pod_plan.commands, CountryCommandReceiptCode::COMMITTED,
        _country_pod_authority.generation(), nullptr);
    _country_pod_plan_active.store(false, std::memory_order_release);
    RuntimeCountryPodSnapshot committed_snapshot;
    std::string snapshot_error;
    if (!_country_pod_authority.snapshot(committed_snapshot, snapshot_error)) {
        error = snapshot_error.empty() ? "country_worker_snapshot_failed" :
            snapshot_error;
        commit.preflight_ok = 0;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        const std::shared_ptr<const RuntimeCountryPodSnapshot> previous =
            _country_committed_snapshot;
        _country_read_view_generation = committed_snapshot.generation;
        _country_read_view_patch_base_generation = previous != nullptr
            ? previous->generation : 0;
        _country_read_view_dirty_families = _country_pod_plan.header.dirty_families;
        _country_read_view_changed_cells.clear();
        _country_read_view_changed_owners.clear();
        const bool same_cell_shape = previous != nullptr &&
            previous->cell_country_slot.size() ==
                committed_snapshot.cell_country_slot.size();
        for (size_t cell = 0; cell < committed_snapshot.cell_country_slot.size();
             ++cell) {
            if (same_cell_shape &&
                previous->cell_country_slot[cell] ==
                    committed_snapshot.cell_country_slot[cell]) {
                continue;
            }
            _country_read_view_changed_cells.push_back(static_cast<int32_t>(cell));
            _country_read_view_changed_owners.push_back(
                committed_snapshot.cell_country_slot[cell]);
        }
        auto committed_copy = std::make_shared<RuntimeCountryPodSnapshot>(
            std::move(committed_snapshot));
        _country_committed_snapshot = committed_copy;
        _country_worker_country_generation = committed_copy->generation;
        _country_worker_day = committed_copy->committed_day;
        std::shared_ptr<const RuntimeCountryPodSnapshot> committed_view =
            committed_copy;
        std::atomic_store_explicit(&_country_snapshot, committed_view,
                                   std::memory_order_release);
        for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
            const uint64_t request_id = intent.request_id != 0
                ? intent.request_id : intent.source_id;
            _country_worker_intents.erase(request_id);
            _country_worker_results.erase(request_id);
        }
        _country_worker_protocol.pending_intents = 0;
        _country_worker_protocol.queued_intents = static_cast<uint32_t>(
            std::min<size_t>(_country_worker_intent_queue.size(),
                             std::numeric_limits<uint32_t>::max()));
        _country_worker_protocol.retry_day = -1;
        _country_worker_protocol.rejected_intents = 0;
        _country_worker_protocol.has_unreported_rejection = 0;
        _country_worker_protocol.rejected_request_id = 0;
        country_peer_copy_reason(_country_worker_protocol.rejection_reason, "");
        const uint64_t boundary_id = _country_worker_seal.boundary_id;
        _country_worker_seal = CountryBoundarySeal{};
        _country_worker_seal.boundary_id = boundary_id;
    }
    commit.completed_domain_mask |= runtime_domain_mask(RuntimeDomainId::COUNTRY);
    commit.dirty_families |= _country_pod_plan.header.dirty_families;
    commit.work_units += _country_pod_plan.header.work_units;
    ++commit.completed_stage_count;
    (void)committed_snapshot;
    return true;
}

bool NativeSimulationHost::execute_ideology_worker_stage(
        int64_t day, RuntimeDayCommit &commit, std::string &error) {
    (void)commit;
    error.clear();
    if (!_ideology_pod_configured) {
        error = "ideology_pod_not_configured";
        return false;
    }
    const auto country = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    const auto opinion = std::atomic_load_explicit(
        &_ideology_opinion_snapshot, std::memory_order_acquire);
    if (country == nullptr || opinion == nullptr) {
        error = country == nullptr ? "ideology_country_snapshot_missing" :
            "ideology_opinion_snapshot_missing";
        return false;
    }
    if (_ideology_pod_authority.snapshot().countries.empty()) {
        if (!_ideology_pod_authority.bootstrap(*country, *opinion, error))
            return false;
    }
    std::deque<RuntimeIdeologyPodCommand> commands;
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        commands.swap(_ideology_commands);
        acks.assign(_ideology_acks.begin(), _ideology_acks.end());
        _ideology_acks.clear();
    }
    while (!commands.empty()) {
        const RuntimeIdeologyPodCommand command = commands.front();
        commands.pop_front();
        if (!_ideology_pod_authority.queue_command(command, error)) {
            std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
            _ideology_commands.push_front(command);
            while (!commands.empty()) {
                _ideology_commands.push_front(commands.back());
                commands.pop_back();
            }
            return false;
        }
    }

    const auto plan_started = std::chrono::steady_clock::now();
    double replay_ms = 0.0;
    uint32_t emitted = 0;
    RuntimeIdeologyPodPlan plan;
    bool first_slice = true;
    for (uint32_t slice = 0; slice < RUNTIME_IDEOLOGY_POD_MAX_COMMANDS; ++slice) {
        static const std::vector<RuntimeDomainAck> empty_acks;
        const auto &effective_acks = first_slice ? acks : empty_acks;
        first_slice = false;
        if (!_ideology_pod_authority.plan_day(
                day, *country, *opinion, effective_acks, plan, error)) {
            _ideology_pod_authority.discard_plan();
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
            for (const RuntimeDomainIntent &intent : plan.intents) {
                if (_ideology_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                    _ideology_pod_authority.discard_plan();
                    error = "ideology_intent_capacity_exceeded";
                    return false;
                }
                _ideology_intents.push_back(intent);
                ++emitted;
            }
        }
        const auto replay_started = std::chrono::steady_clock::now();
        if (!_ideology_pod_authority.commit_day(plan, error)) return false;
        replay_ms += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - replay_started).count();
        if (plan.completed_day != 0) break;
        if (slice + 1u == RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) {
            error = "ideology_same_day_continuation_limit_exceeded";
            return false;
        }
    }
    const RuntimeIdeologyPodSnapshot &snapshot =
        _ideology_pod_authority.snapshot();
    auto copy = std::make_shared<RuntimeIdeologyPodSnapshot>(snapshot);
    std::atomic_store_explicit(&_ideology_snapshot,
        std::shared_ptr<const RuntimeIdeologyPodSnapshot>(std::move(copy)),
        std::memory_order_release);
    _ideology_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _ideology_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _ideology_pod_state_hash.store(snapshot.state_hash, std::memory_order_release);
    _ideology_pod_snapshot_generation.store(snapshot.generation,
                                            std::memory_order_release);
    _ideology_pod_pending_transition_count.store(
        static_cast<uint32_t>(snapshot.pending_transitions.size()),
        std::memory_order_release);
    _ideology_pod_intent_count.store(emitted, std::memory_order_release);
    return true;
}

RuntimeDayCommit NativeSimulationHost::execute_day_plan(
        RuntimeDayPlan &plan,
        const std::vector<RuntimeCommandPacket> &day_commands,
        std::vector<RuntimeCommandReceipt> &day_receipts,
        uint64_t admitted_submit_order) {
    RuntimeDayCommit commit;
    const auto run_events_probe = [&](int64_t event_day) {
        if (!_events_probe_enabled.load(std::memory_order_acquire) ||
            _events_last_processed_day >= event_day) {
            return;
        }
        RuntimeEventsSnapshot events_snapshot;
        RuntimeEventsReport events_report;
        std::string events_error;
        // RuntimeEventsAuthority owns its receipt vector. Keep that vector
        // separate from the host's ordinary command receipts: plan_day()
        // intentionally clears its output before replaying Events commands.
        std::vector<RuntimeCommandReceipt> event_receipts;
        const auto events_plan_started = std::chrono::steady_clock::now();
        bool events_ok = _events_authority.plan_day(
            event_day, day_commands, events_snapshot, event_receipts,
            events_report, events_error);
        const double events_plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - events_plan_started).count();
        double events_replay_ms = 0.0;
        if (events_ok) {
            const auto events_replay_started = std::chrono::steady_clock::now();
            events_ok = _events_authority.commit_day(events_snapshot, events_error);
            events_replay_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - events_replay_started).count();
        } else {
            _events_authority.discard_plan();
        }
        // Mark the attempt even on a rejected payload. Events is probe-only and
        // must not be replayed by a Climate barrier retry for the same day.
        _events_last_processed_day = event_day;
        _events_pod_ready.store(events_ok, std::memory_order_release);
        _events_pod_plan_ms.store(events_plan_ms, std::memory_order_release);
        _events_pod_replay_ms.store(events_replay_ms, std::memory_order_release);
        _events_pod_state_hash.store(_events_authority.snapshot().state_hash,
                                     std::memory_order_release);
        _events_pod_snapshot_generation.store(
            _events_authority.snapshot().generation, std::memory_order_release);
        _events_pod_event_count.store(events_report.appended_events,
                                      std::memory_order_release);
        _events_pod_ack_count.store(events_report.acknowledged_consumers,
                                    std::memory_order_release);
        _events_pod_drop_count.store(_events_authority.snapshot().dropped_event_count,
                                     std::memory_order_release);
        for (size_t i = 0; i < _events_pod_fallback_reason.size(); ++i) {
            _events_pod_fallback_reason[i].store(
                events_report.fallback_reason[i], std::memory_order_release);
            if (events_report.fallback_reason[i] == '\0') break;
        }
        if (!events_ok) return;
        uint32_t events_slot = 0;
        if (_events_snapshots.try_begin_write(events_slot)) {
            _events_snapshots.write_buffer(events_slot) = _events_authority.snapshot();
            _events_snapshots.publish(events_slot);
        } else {
            _events_pod_ready.store(false, std::memory_order_release);
        }
    };
    // SHADOW runs the worker-safe POD pipeline for measurement and parity
    // diagnostics. The legacy synchronous graph remains authoritative until
    // every domain has a verified state/ACK adapter, so ACTIVE stays gated.
    if (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW) {
        const auto country_snapshot = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        RuntimeClimateVerticalReport climate_report;
        bool climate_ok = false;
        RuntimeClimateReferenceFrame trace_frame;
        const RuntimeClimateTracePopResult trace_result =
            _climate_trace.pop_for_day(plan.context.day, trace_frame);
        if (trace_result == RuntimeClimateTracePopResult::CONSUMED) {
            _climate_trace_consumed.fetch_add(1, std::memory_order_relaxed);
            _climate_trace_latest_hash.store(trace_frame.trace_hash,
                                             std::memory_order_release);
        } else {
            _climate_trace_missing.fetch_add(1, std::memory_order_relaxed);
        }
        // A SHADOW Climate day is valid only when the OFF reference has
        // released the matching trace frame. Never silently substitute the
        // latest live environment: doing so would make parity non-replayable.
        const RuntimeEnvironmentSnapshot *climate_environment =
            trace_result == RuntimeClimateTracePopResult::CONSUMED &&
                trace_frame.environment != nullptr
                ? trace_frame.environment.get() : nullptr;
        // 冷启动引导：worker 的 store 是全零，而它拿到的第一帧 reference 已经带着
        // 整个世界生成期的 Climate 结果。这一天比的不是算法，而是"worker 没见过
        // 世界生成"，必然红，且红在每一个字段上——把它当对拍数据会污染整张分叉矩阵。
        //
        // 所以第一帧只做一件事：把生产状态整体收作 worker 的起点，不计入对拍。
        // 之后每一天 worker 才真的从与生产同一个基线往前推。
        const bool climate_cold_start =
            climate_environment != nullptr &&
            _climate_authority.store().committed_day < 0 &&
            trace_frame.reference_store != nullptr;
        // S3 冷启动边界诊断：cold start 落在哪一天、采纳的 reference 是哪个哈希，
        // 以及紧随其后的几天 worker 究竟跑了哪些 stage。day 2 的一次性分叉只可能
        // 出在这两者之一，靠分叉矩阵反推不出来。
        static std::atomic<int> s_climate_boundary_reports_left{8};
        if (climate_cold_start) {
            std::memset(&climate_report, 0, sizeof(climate_report));
            if (_climate_authority.adopt_reference_baseline(
                    plan.context.day, *trace_frame.reference_store,
                    *climate_environment, climate_report)) {
                runtime_copy_text(climate_report.parity_reason,
                                  "climate_cold_start_baseline");
                climate_ok = true;
            } else {
                if (climate_report.error[0] == '\0') {
                    runtime_copy_text(climate_report.error,
                                      "climate_cold_start_baseline_failed");
                }
                climate_ok = false;
            }
            if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                             "[climate][boundary] cold-start day=%lld ok=%d "
                             "ref_hash=%llu adopted_parity=%llu round_ran=%d\n",
                             static_cast<long long>(plan.context.day), climate_ok ? 1 : 0,
                             static_cast<unsigned long long>(trace_frame.reference_state_hash),
                             static_cast<unsigned long long>(
                                 _climate_authority.store().parity_hash()),
                             climate_environment->climate_round_ran ? 1 : 0);
                std::fflush(stderr);
            }
            _climate_pod_parity_compared.store(false, std::memory_order_release);
            _climate_pod_parity_matched.store(false, std::memory_order_release);
            _climate_parity_day.store(plan.context.day, std::memory_order_release);
            for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
                _climate_pod_parity_reason[i].store(
                    climate_report.parity_reason[i], std::memory_order_release);
                if (climate_report.parity_reason[i] == '\0') break;
            }
        } else if (climate_environment != nullptr) {
            const bool climate_planned = _climate_authority.plan_day(
                plan.context.day, *climate_environment, climate_report);
            // plan_day resets the report, so attach the trace metadata only
            // after the authority has filled its execution diagnostics.
            climate_report.reference_state_hash = trace_frame.reference_state_hash;
            climate_report.parity_compared = climate_planned &&
                trace_frame.reference_state_hash != 0;
            // Compare the canonical parity reduction, not state_hash. The
            // latter mixes in worker-only bookkeeping (generation, rng_state,
            // history cursor) that no production reference can reproduce, so
            // comparing it could never succeed.
            climate_report.parity_matched = climate_report.parity_compared &&
                climate_report.parity_hash == trace_frame.reference_state_hash;
            if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                             "[climate][boundary] day=%lld planned=%d compared=%d matched=%d "
                             "worker_parity=%llu ref=%llu stage_ran=0x%X prod_stage=0x%X "
                             "round_ran=%d alb=%d veg=%d fb=%d err=%s\n",
                             static_cast<long long>(plan.context.day), climate_planned ? 1 : 0,
                             climate_report.parity_compared ? 1 : 0,
                             climate_report.parity_matched ? 1 : 0,
                             static_cast<unsigned long long>(climate_report.parity_hash),
                             static_cast<unsigned long long>(trace_frame.reference_state_hash),
                             climate_report.worker_stage_mask,
                             climate_report.production_stage_mask,
                             climate_environment->climate_round_ran ? 1 : 0,
                             climate_environment->climate_albedo.ran ? 1 : 0,
                             climate_environment->climate_vegetation != nullptr &&
                                 climate_environment->climate_vegetation->knobs.ran ? 1 : 0,
                             climate_environment->climate_feedback != nullptr &&
                                 climate_environment->climate_feedback->knobs.ran ? 1 : 0,
                             climate_report.error);
                std::fflush(stderr);
            }
            if (!climate_planned) {
                // Preserve the authority's first execution/preflight error;
                // a failed plan is not a parity comparison and must not be
                // relabeled as a hash mismatch.
                climate_report.parity_reason[0] = '\0';
                if (climate_report.error[0] == '\0') {
                    runtime_copy_text(climate_report.error,
                                      "climate_execution_failed");
                }
                climate_ok = false;
            } else if (!climate_report.parity_compared) {
                // The trace ring normally refuses to expose a frame before
                // a non-zero reference hash is recorded. Treat a malformed
                // or incomplete frame as a hard input barrier anyway; never
                // let a non-compared day look ready.
                climate_report.parity_reason[0] = '\0';
                _climate_authority.discard_plan();
                climate_report.completed = 0;
                climate_ok = false;
                climate_report.preflight_ok = 0;
                runtime_copy_text(climate_report.error,
                                  "climate_reference_hash_missing");
            } else if (!climate_report.parity_matched) {
                // Two unequal hashes say nothing about which stage diverged.
                // When the frame carries the production state, locate the
                // first differing field and cell; that is what turns a red
                // light into a work item.
                if (trace_frame.reference_store != nullptr) {
                    RuntimeClimateParityReport diff;
                    diff.day = plan.context.day;
                    // The full per-field fold is what the divergence matrix is
                    // built from; the first difference alone would only ever
                    // name the earliest field in table order.
                    accumulate_climate_parity_fields(
                        plan.context.day, *trace_frame.reference_store,
                        _climate_authority.planned_store());
                    if (runtime_climate_parity_first_difference(
                            *trace_frame.reference_store,
                            _climate_authority.planned_store(), diff)) {
                        const RuntimeClimateParityField *field =
                            runtime_climate_parity_field(diff.field);
                        if (field != nullptr) {
                            diff.stage = static_cast<uint16_t>(field->stage);
                        }
                        publish_climate_parity_divergence(diff);
                        if (s_climate_boundary_reports_left.load(std::memory_order_relaxed) > -8) {
                            std::fprintf(stderr,
                                         "[climate][boundary] day=%lld first_diff=%s[%u] "
                                         "ref=%s worker=%s\n",
                                         static_cast<long long>(plan.context.day), diff.field,
                                         diff.cell, diff.reference_bits, diff.worker_bits);
                            std::fflush(stderr);
                        }
                        runtime_copy_text(climate_report.parity_reason,
                                          "climate_reference_field_mismatch");
                    } else {
                        // The fields agree but the hashes do not, which means
                        // the two sides disagree about the framing rather than
                        // about the physics.
                        clear_climate_parity_divergence();
                        runtime_copy_text(climate_report.parity_reason,
                                          "climate_reference_framing_mismatch");
                    }
                } else {
                    clear_climate_parity_divergence();
                    runtime_copy_text(climate_report.parity_reason,
                                      "climate_reference_hash_mismatch");
                }
                if (_climate_parity_forcing.load(std::memory_order_acquire) &&
                    trace_frame.reference_store != nullptr) {
                    // Measurement mode. Retrying the same day forever would
                    // pin the whole run to its first divergence, so adopt the
                    // production state and let the next day be measured on its
                    // own. parity_matched stays false either way.
                    climate_ok = _climate_authority.commit_day_forced(
                        plan.context.day, *trace_frame.reference_store,
                        climate_report);
                    _climate_parity_forced_days.fetch_add(1,
                                                          std::memory_order_relaxed);
                    if (!climate_ok && climate_report.error[0] == '\0') {
                        runtime_copy_text(climate_report.error,
                                          "climate_forced_commit_failed");
                    }
                    runtime_copy_text(climate_report.parity_reason,
                                      "climate_reference_mismatch_forced");
                } else {
                    // Abort before commit so a failed deterministic comparison
                    // cannot advance the worker-owned Climate generation/day.
                    _climate_authority.discard_plan();
                    climate_report.completed = 0;
                    climate_ok = false;
                    climate_report.preflight_ok = 0;
                    runtime_copy_text(climate_report.error,
                                      climate_report.parity_reason);
                }
            } else {
                // Record the agreeing day too, so a field's divergence rate is
                // out of the days it was actually compared rather than out of
                // the days it happened to fail.
                if (trace_frame.reference_store != nullptr) {
                    accumulate_climate_parity_fields(
                        plan.context.day, *trace_frame.reference_store,
                        _climate_authority.planned_store());
                }
                // Only a matching next-state hash may cross the commit
                // boundary. The kernel's plan hash is identical to the
                // committed hash because commit only swaps the two lanes.
                climate_ok = _climate_authority.commit_day(
                    plan.context.day, climate_report);
                if (!climate_ok) {
                    climate_report.parity_reason[0] = '\0';
                    if (climate_report.error[0] == '\0') {
                        runtime_copy_text(climate_report.error,
                                          "climate_commit_failed");
                    }
                } else {
                    // Drop any divergence recorded for an earlier day so a
                    // stale field name cannot be read as today's result.
                    clear_climate_parity_divergence();
                    runtime_copy_text(climate_report.parity_reason, "ok");
                }
            }
            for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
                _climate_pod_parity_reason[i].store(climate_report.parity_reason[i],
                                                    std::memory_order_release);
                if (climate_report.parity_reason[i] == '\0') break;
            }
            _climate_pod_reference_hash.store(trace_frame.reference_state_hash,
                                               std::memory_order_release);
            _climate_parity_day.store(plan.context.day, std::memory_order_release);
            _climate_parity_input_generation.store(climate_report.input_generation, std::memory_order_release);
            _climate_parity_base_generation.store(_climate_authority.store().generation, std::memory_order_release);
            _climate_parity_trace_hash.store(trace_frame.trace_hash, std::memory_order_release);
            _climate_pod_parity_compared.store(climate_report.parity_compared != 0,
                                                std::memory_order_release);
            _climate_pod_parity_matched.store(climate_report.parity_matched != 0,
                                               std::memory_order_release);
            if (climate_report.parity_compared && !climate_report.parity_matched) {
                _climate_pod_parity_mismatch_count.fetch_add(1,
                                                              std::memory_order_relaxed);
            }
        } else {
            std::memset(&climate_report, 0, sizeof(climate_report));
            const char *reason = "climate_trace_reference_pending";
            if (trace_result == RuntimeClimateTracePopResult::EMPTY) {
                reason = "climate_trace_missing";
            } else if (trace_result == RuntimeClimateTracePopResult::FUTURE_FRAME) {
                reason = "climate_trace_future_frame";
            }
            runtime_copy_text(climate_report.error, reason);
            climate_report.preflight_ok = 0;
        }
        _climate_pod_ready.store(climate_ok, std::memory_order_release);
        _climate_pod_plan_ms.store(climate_report.plan_ms, std::memory_order_release);
        _climate_pod_replay_ms.store(climate_report.replay_ms, std::memory_order_release);
        _climate_pod_work_units.store(climate_report.work_units, std::memory_order_release);
        _climate_pod_changed_cells.store(climate_report.changed_cells, std::memory_order_release);
        for (size_t i = 0; i < _climate_stage_ms.size() &&
                           i < climate_report.stage_ms.size(); ++i) {
            _climate_stage_ms[i].store(climate_report.stage_ms[i],
                                       std::memory_order_relaxed);
            _climate_stage_work[i].store(climate_report.stage_work[i],
                                         std::memory_order_relaxed);
        }
        _climate_pod_state_hash.store(climate_report.state_hash, std::memory_order_release);
        for (size_t i = 0; i < _climate_pod_fallback_reason.size(); ++i) {
            _climate_pod_fallback_reason[i].store(climate_report.error[i],
                                                  std::memory_order_release);
            if (climate_report.error[i] == '\0') break;
        }
        _climate_production_stage_mask.store(climate_report.production_stage_mask,
                                            std::memory_order_release);
        _climate_worker_stage_mask.store(climate_report.worker_stage_mask,
                                        std::memory_order_release);

        RuntimeDayContext diagnostic_context = plan.context;
        diagnostic_context.input_generation = climate_environment != nullptr
            ? climate_environment->generation : 0;

        // K2-A vertical slice: when a Country capture/catalog pair was
        // published before this worker started, the worker owns a persistent
        // Country POD plan. A missing peer result parks this whole semantic
        // boundary; it must not fall through to the old per-call diagnostic
        // adapter or advance the worker clock.
        if (climate_ok && _country_pod_configured) {
            std::string country_error;
            if (!execute_country_worker_stage(
                    plan.context.day, diagnostic_context.input_generation,
                    day_commands, commit, country_error,
                    admitted_submit_order)) {
                _country_pod_ready.store(false, std::memory_order_release);
                const char *reason = country_error.empty()
                    ? "country_worker_stage_pending" : country_error.c_str();
                for (size_t i = 0; i + 1 < _country_pod_fallback_reason.size(); ++i) {
                    _country_pod_fallback_reason[i].store(reason[i],
                                                         std::memory_order_release);
                    if (reason[i] == '\0') break;
                }
                _country_pod_fallback_reason[_country_pod_fallback_reason.size() - 1]
                    .store('\0', std::memory_order_release);
                commit.preflight_ok = 0;
                return commit;
            }
            _country_pod_ready.store(true, std::memory_order_release);
        }

        // G7 SHADOW stage. It consumes the Country snapshot committed above
        // and the previous main-thread Economy opinion publication. Failure
        // is diagnostic only and never stalls Climate or promotes IDEOLOGY.
        std::string ideology_error;
        const bool ideology_ok = climate_ok && execute_ideology_worker_stage(
            plan.context.day, commit, ideology_error);
        _ideology_pod_ready.store(ideology_ok, std::memory_order_release);
        const char *ideology_reason = ideology_ok
            ? (_ideology_pod_pending_transition_count.load(
                    std::memory_order_acquire) > 0
                ? "ideology_effect_ack_pending" : "")
            : (ideology_error.empty() ? "ideology_pod_plan_failed" :
                                      ideology_error.c_str());
        size_t ideology_reason_index = 0;
        for (; ideology_reason_index + 1 < _ideology_pod_fallback_reason.size() &&
               ideology_reason[ideology_reason_index] != '\0';
             ++ideology_reason_index) {
            _ideology_pod_fallback_reason[ideology_reason_index].store(
                ideology_reason[ideology_reason_index], std::memory_order_release);
        }
        for (; ideology_reason_index < _ideology_pod_fallback_reason.size();
             ++ideology_reason_index) {
            _ideology_pod_fallback_reason[ideology_reason_index].store(
                '\0', std::memory_order_release);
        }

        // Run the consolidated worker-only domain transaction after the
        // Climate trace barrier. This is deliberately a SHADOW diagnostic:
        // it owns an isolated aggregate and never contributes to the
        // authoritative clock, MapData, or implemented-domain mask.
        RuntimeDomainAuthorityPlan authority_plan;
        std::string authority_error;
        bool authority_ok = false;
        double authority_plan_ms = 0.0;
        double authority_replay_ms = 0.0;
        if (climate_ok && climate_environment != nullptr) {
            const auto &authority_stores = _domain_authority_runner.stores();
            const uint32_t country_count = country_snapshot != nullptr
                ? country_snapshot->country_count : authority_stores.country.country_count;
            if (authority_stores.climate.cell_count !=
                    climate_environment->cell_count ||
                authority_stores.country.country_count != country_count ||
                authority_stores.country.cell_count !=
                    climate_environment->cell_count) {
                _domain_authority_runner.reset(
                    climate_environment->cell_count, country_count);
            }
            RuntimeDayContext authority_context = diagnostic_context;
            authority_context.environment = climate_environment;
            const auto plan_started = std::chrono::steady_clock::now();
            authority_ok = _domain_authority_runner.plan_day(
                authority_context, climate_environment,
                country_snapshot.get(), authority_plan, authority_error);
            authority_plan_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - plan_started).count();
            if (authority_ok) {
                std::vector<RuntimeModifierPodCommand> modifier_commands;
                modifier_commands.reserve(day_commands.size());
                for (const RuntimeCommandPacket &packet : day_commands) {
                    RuntimeModifierPodCommand command;
                    if (decode_modifier_packet(packet, command))
                        modifier_commands.push_back(command);
                }
                std::vector<RuntimeModifierPodCommand> modifier_intents;
                modifier_intents.reserve(authority_plan.intents.size());
                for (const RuntimeDomainIntent &intent : authority_plan.intents) {
                    if (intent.target_domain != static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) continue;
                    RuntimeModifierPodCommand command;
                    command.request_id = intent.request_id != 0 ? intent.request_id : intent.source_id;
                    command.producer_id = intent.producer_id;
                    command.sequence = intent.sequence;
                    command.effective_day = intent.effective_day;
                    command.requested_day = intent.effective_day;
                    command.opcode = intent.opcode;
                    command.domain = intent.payload[1] >= 0 && intent.payload[1] < 4
                        ? static_cast<uint16_t>(intent.payload[1]) : 0;
                    command.definition_id = intent.payload[0] >= 0
                        ? static_cast<int32_t>(intent.payload[0]) : 0;
                    command.scope = intent.payload[2] >= 0 && intent.payload[2] <= 2
                        ? static_cast<int32_t>(intent.payload[2]) : 2;
                    command.entity_handle = intent.target_handle;
                    command.target_generation = intent.target_generation;
                    command.group_handle = intent.group_handle;
                    command.modifier_handle = intent.modifier_handle;
                    command.duration_days = intent.duration_days;
                    command.stacks = intent.stacks;
                    command.magnitude_q16 = intent.magnitude_q16;
                    command.source_type = static_cast<uint64_t>(RuntimeDomainId::EFFECT);
                    command.source_id = intent.source_id;
                    command.input_generation = diagnostic_context.input_generation;
                    modifier_intents.push_back(command);
                }
                bool modifier_ok = true;
                std::string modifier_error;
                RuntimeModifierPodSnapshot modifier_snapshot;
                RuntimeModifierPodReport modifier_report;
                std::vector<RuntimeDomainAck> modifier_acks;
                double modifier_plan_ms = 0.0;
                double modifier_replay_ms = 0.0;
                if (_modifier_pod_configured) {
                    const auto modifier_plan_started = std::chrono::steady_clock::now();
                    modifier_ok = _modifier_pod_authority.plan_day(
                        plan.context.day, diagnostic_context.input_generation,
                        modifier_commands, modifier_intents, modifier_snapshot,
                        modifier_acks, modifier_report, modifier_error);
                    modifier_plan_ms = std::chrono::duration<double, std::milli>(
                        std::chrono::steady_clock::now() - modifier_plan_started).count();
                    if (!modifier_ok) {
                        _modifier_pod_authority.discard_plan();
                    }
                } else if (!modifier_commands.empty() || !modifier_intents.empty()) {
                    modifier_ok = false;
                    modifier_error = "modifier_pod_not_configured";
                }
                if (modifier_ok) {
                    modifier_ok = _domain_authority_runner.accept_modifier_acks(
                        authority_plan, modifier_acks, modifier_error);
                }
                uint32_t modifier_slot = 0;
                bool modifier_slot_reserved = false;
                if (modifier_ok && _modifier_pod_configured) {
                    if (!_modifier_snapshots.try_begin_write(modifier_slot)) {
                        modifier_ok = false;
                        modifier_error = "modifier_snapshot_ring_full";
                    } else {
                        _modifier_snapshots.write_buffer(modifier_slot) = modifier_snapshot;
                        modifier_slot_reserved = true;
                    }
                }
                const auto replay_started = std::chrono::steady_clock::now();
                if (modifier_ok) {
                    modifier_ok = !_modifier_pod_configured ||
                        _modifier_pod_authority.commit_day(
                            modifier_snapshot, modifier_error);
                    if (modifier_ok) {
                        authority_ok = _domain_authority_runner.commit_day(
                            authority_plan, authority_error);
                    }
                    if (modifier_ok && authority_ok && modifier_slot_reserved) {
                        _modifier_snapshots.publish(modifier_slot);
                        modifier_slot_reserved = false;
                        _modifier_pod_snapshot_generation.store(
                            modifier_snapshot.generation, std::memory_order_release);
                    }
                } else {
                    authority_ok = false;
                    _modifier_pod_authority.discard_plan();
                    _domain_authority_runner.discard_plan();
                    if (authority_error.empty()) authority_error = modifier_error;
                }
                if ((!modifier_ok || !authority_ok) && modifier_slot_reserved)
                    _modifier_snapshots.release(modifier_slot);
                authority_replay_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - replay_started).count();
                modifier_replay_ms = authority_replay_ms;
                const bool modifier_committed = modifier_ok && authority_ok &&
                    _modifier_pod_configured;
                _modifier_pod_ready.store(modifier_committed,
                                          std::memory_order_release);
                _modifier_pod_plan_ms.store(modifier_plan_ms, std::memory_order_release);
                _modifier_pod_replay_ms.store(modifier_replay_ms, std::memory_order_release);
                _modifier_pod_work_units.store(modifier_report.work_units, std::memory_order_release);
                _modifier_pod_state_hash.store(modifier_committed
                    ? modifier_snapshot.state_hash
                    : _modifier_pod_authority.snapshot().state_hash,
                    std::memory_order_release);
                _modifier_pod_ack_count.store(modifier_committed
                    ? static_cast<uint32_t>(modifier_acks.size()) : 0u,
                    std::memory_order_release);
                const char *modifier_reason = modifier_committed ? "" :
                    (!_modifier_pod_configured && modifier_error.empty()
                        ? "modifier_pod_not_configured"
                        : (modifier_error.empty() ? "modifier_pod_plan_failed" :
                           modifier_error.c_str()));
                size_t modifier_reason_index = 0;
                for (; modifier_reason_index + 1 < _modifier_pod_fallback_reason.size() &&
                        modifier_reason[modifier_reason_index] != '\0';
                     ++modifier_reason_index) {
                    _modifier_pod_fallback_reason[modifier_reason_index].store(
                        modifier_reason[modifier_reason_index], std::memory_order_release);
                }
                for (; modifier_reason_index < _modifier_pod_fallback_reason.size();
                     ++modifier_reason_index) {
                    _modifier_pod_fallback_reason[modifier_reason_index].store(
                        '\0', std::memory_order_release);
                }
            } else {
                _domain_authority_runner.discard_plan();
            }
        } else {
            authority_error = climate_report.error[0] != '\0'
                ? climate_report.error : "climate_reference_barrier_pending";
            _domain_authority_runner.discard_plan();
        }
        if (authority_ok) {
            const RuntimeDomainAuthorityReport &authority_report =
                _domain_authority_runner.report();
            _domain_authority_planned_mask.store(
                authority_report.diagnostic_planned_mask,
                std::memory_order_release);
            _domain_authority_committed_mask.store(
                authority_report.diagnostic_committed_mask,
                std::memory_order_release);
            _domain_authority_ack_count.store(authority_report.ack_count,
                                              std::memory_order_release);
            _domain_authority_input_hash.store(authority_report.input_hash,
                                               std::memory_order_release);
            _domain_authority_state_hash.store(authority_report.state_hash,
                                               std::memory_order_release);
            _domain_authority_plan_ms.store(authority_plan_ms,
                                            std::memory_order_release);
            _domain_authority_replay_ms.store(authority_replay_ms,
                                              std::memory_order_release);
            for (size_t i = 0; i < _domain_authority_fallback_reason.size(); ++i) {
                _domain_authority_fallback_reason[i].store('\0',
                                                          std::memory_order_release);
            }
        } else {
            _domain_authority_planned_mask.store(0, std::memory_order_release);
            _domain_authority_committed_mask.store(0, std::memory_order_release);
            _domain_authority_ack_count.store(0, std::memory_order_release);
            _domain_authority_input_hash.store(0, std::memory_order_release);
            _domain_authority_state_hash.store(0, std::memory_order_release);
            _domain_authority_plan_ms.store(authority_plan_ms,
                                            std::memory_order_release);
            _domain_authority_replay_ms.store(authority_replay_ms,
                                              std::memory_order_release);
            const char *reason = authority_error.empty()
                ? "domain_authority_plan_failed" : authority_error.c_str();
            size_t i = 0;
            for (; i + 1 < _domain_authority_fallback_reason.size() &&
                    reason[i] != '\0'; ++i) {
                _domain_authority_fallback_reason[i].store(
                    reason[i], std::memory_order_release);
            }
            for (; i < _domain_authority_fallback_reason.size(); ++i) {
                _domain_authority_fallback_reason[i].store(
                    '\0', std::memory_order_release);
            }
        }
        uint32_t stage_fallback_count = 0;
        char first_stage_fallback[64]{};
        for (const RuntimeDomainId domain : runtime_domain_stage_order()) {
            if (domain == RuntimeDomainId::COMMIT) continue;
            const RuntimeDomainReport stage_report =
                _authoritative_domains.stage_preflight(
                    domain, diagnostic_context, climate_environment);
            if (stage_report.fallback != 0 || stage_report.preflight_ok == 0) {
                ++stage_fallback_count;
                if (first_stage_fallback[0] == '\0') {
                    runtime_copy_text(first_stage_fallback,
                                      stage_report.fallback_reason);
                }
            }
        }
        _domain_stage_fallback_count.store(stage_fallback_count,
                                           std::memory_order_release);
        for (size_t i = 0; i < _domain_stage_fallback_reason.size(); ++i) {
            _domain_stage_fallback_reason[i].store(first_stage_fallback[i],
                                                   std::memory_order_release);
            if (first_stage_fallback[i] == '\0') break;
        }
        _pod_visual_intents.clear();
        _pod_receipts.clear();
        const bool pipeline_ok = _pod_pipeline.execute_day(
            diagnostic_context, climate_environment, country_snapshot.get(),
            commit, _pod_visual_intents, _pod_receipts);
        const RuntimeDomainPipelineReport &pipeline_report = _pod_pipeline.report();
        _pod_completed_domain_mask.store(pipeline_report.completed_domain_mask,
                                         std::memory_order_release);
        _pod_completed_stage_count.store(
            pipeline_ok ? RUNTIME_DOMAIN_STAGE_COUNT : 0u,
            std::memory_order_release);
        _pod_work_units.store(pipeline_report.work_units, std::memory_order_release);
        _pod_intent_count.store(pipeline_report.intent_count, std::memory_order_release);
        _pod_fallback_count.store(pipeline_report.fallback_count, std::memory_order_release);
        // Do not leak shadow intents into the visual ring. They are only
        // consumed by parity tooling until the ACTIVE ownership gate clears.
        commit.completed_stage_count = 1;
        commit.completed_domain_mask = runtime_domain_mask(RuntimeDomainId::COMMIT);
        commit.dirty_families = RUNTIME_DIRTY_CLOCK;
        commit.work_units = std::max<uint64_t>(1, pipeline_report.work_units);
        commit.preflight_ok = climate_ok ? 1u : 0u;
        run_events_probe(plan.context.day);
        return commit;
    }
    // Phase B boundary: the clock commit is the only complete handler until
    // the existing Country/Economy/Effect/Modifier/Climate/Trigger stores have
    // native POD adapters. Keeping the remaining stages uncompleted makes the
    // coverage gap observable instead of accidentally claiming ACTIVE.
    // ACTIVE Climate. Distinct from the SHADOW branch above in the one way that
    // matters: there is no production reference to wait for, because production
    // is suppressed. SHADOW deliberately refuses to substitute the live
    // environment for a missing trace frame — doing so would make parity
    // non-replayable — but under authority the live snapshot *is* the input.
    //
    // Reaching this point requires the per-domain gate to have granted CLIMATE,
    // so this cannot run while the main thread is still computing Climate.
    const bool climate_authority_requested =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    bool active_climate_ok = false;
    if (climate_authority_requested) {
        const auto environment = environment_snapshot();
        RuntimeClimateVerticalReport climate_report{};
        // The environment day, not plan.context.day. Under authority the
        // published environment is Climate's only input and arrives one per
        // main-thread tick, whereas plan.context.day is `_committed_day + 1`
        // off this worker's own clock. Those two advance independently, and
        // `_committed_day` only moves when the day succeeds — so a single
        // mismatch used to be terminal: the worker stayed pinned on its day
        // while the environment ran ahead, and `environment.day != day` held
        // forever after. Climate then silently stopped computing while the
        // write-back kept publishing the stale store.
        const int64_t climate_day = environment != nullptr ? environment->day : -1;
        const int64_t climate_committed = _climate_authority.store().committed_day;
        // Whether this day actually ran the kernel. The worker retries the next
        // day immediately after a successful one and parks on the missing
        // environment, so an unconditional diagnostic store would overwrite the
        // day that computed with the empty report of the park that followed it —
        // which is why stage_work/state_hash/stage_mask all read as zero while
        // the kernel was demonstrably running.
        bool climate_day_computed = false;
        if (environment == nullptr) {
            runtime_copy_text(climate_report.error, "climate_environment_missing");
        } else if (plan.context.day > climate_day) {
            // The worker clock has outrun the main thread. Park the day instead
            // of committing it: letting the clock run ahead is what desynced
            // the two sides in the first place, and every day committed past
            // the last published environment is a day Climate cannot compute.
            runtime_copy_text(climate_report.error,
                              "climate_environment_not_published");
        } else if (climate_day <= climate_committed) {
            // No new input this day. Not a failure: the worker clock is free to
            // run ahead of the main thread, and Climate simply has nothing to
            // advance until the next publish. Reporting it as a preflight
            // failure would stall the whole worker on a condition only the main
            // thread can clear, which is the deadlock described above.
            active_climate_ok = true;
            runtime_copy_text(climate_report.parity_reason,
                              "climate_environment_day_not_new");
        } else if (_climate_authority.plan_day(climate_day, *environment,
                                               climate_report)) {
            climate_day_computed = true;
            active_climate_ok = _climate_authority.commit_day(climate_day,
                                                              climate_report);
            if (active_climate_ok) {
                _climate_committed_day.store(climate_day,
                                             std::memory_order_release);
            } else {
                _climate_authority.discard_plan();
            }
        } else {
            climate_day_computed = true;
            _climate_authority.discard_plan();
        }
        if (climate_day_computed) {
            _climate_pod_ready.store(active_climate_ok, std::memory_order_release);
            _climate_pod_plan_ms.store(climate_report.plan_ms,
                                       std::memory_order_release);
            _climate_pod_replay_ms.store(climate_report.replay_ms,
                                         std::memory_order_release);
            _climate_pod_work_units.store(climate_report.work_units,
                                          std::memory_order_release);
            _climate_pod_changed_cells.store(climate_report.changed_cells,
                                             std::memory_order_release);
            _climate_pod_state_hash.store(climate_report.state_hash,
                                          std::memory_order_release);
            for (size_t s = 0; s < _climate_stage_ms.size() &&
                               s < climate_report.stage_ms.size(); ++s) {
                _climate_stage_ms[s].store(climate_report.stage_ms[s],
                                           std::memory_order_relaxed);
                _climate_stage_work[s].store(climate_report.stage_work[s],
                                             std::memory_order_relaxed);
            }
            _climate_worker_stage_mask.store(climate_report.worker_stage_mask,
                                            std::memory_order_release);
        }
        // Nothing to compare against under authority; keep the parity slots
        // explicitly empty rather than leaving the last SHADOW day's verdict
        // sitting in the report as if it still applied.
        _climate_production_stage_mask.store(0, std::memory_order_release);
        _climate_pod_parity_compared.store(false, std::memory_order_release);
        _climate_pod_parity_matched.store(false, std::memory_order_release);
        // Parking on an unpublished environment is the steady state between two
        // main-thread ticks, not a fault. Reporting it here would bury the last
        // real kernel error under a reason that is present on almost every day.
        if (climate_day_computed) {
            for (size_t s = 0; s < _climate_pod_fallback_reason.size(); ++s) {
                _climate_pod_fallback_reason[s].store(climate_report.error[s],
                                                      std::memory_order_release);
                if (climate_report.error[s] == '\0') break;
            }
        }
    }

    for (uint32_t i = 0; i < plan.stage_count; ++i) {
        RuntimeDomainPlan &stage = plan.stages[i];
        if (stage.domain == RuntimeDomainId::CLIMATE && active_climate_ok) {
            stage.dirty_families = RUNTIME_DIRTY_CLIMATE_FIELDS | RUNTIME_DIRTY_WEATHER;
            stage.work_units = _climate_pod_work_units.load(std::memory_order_relaxed);
            stage.completed = 1;
            commit.dirty_families |= stage.dirty_families;
            commit.work_units += stage.work_units;
            commit.completed_domain_mask |= runtime_domain_mask(stage.domain);
            ++commit.completed_stage_count;
            continue;
        }
        if (stage.domain == RuntimeDomainId::COUNTRY &&
            (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW ||
             (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
              (_requested_authority_mask.load(std::memory_order_acquire) &
               runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u))) {
            if (_country_pod_configured) {
                const uint32_t dirty_before = commit.dirty_families;
                const uint64_t work_before = commit.work_units;
                std::string country_error;
                if (execute_country_worker_stage(
                        plan.context.day, plan.context.input_generation,
                        day_commands, commit, country_error,
                        admitted_submit_order)) {
                    stage.dirty_families = (commit.dirty_families |
                        dirty_before) &
                        (RUNTIME_DIRTY_COUNTRY_STATE |
                         RUNTIME_DIRTY_COUNTRY_TERRITORY |
                         RUNTIME_DIRTY_COUNTRY_VISUAL_ERA);
                    stage.work_units = commit.work_units >= work_before
                        ? commit.work_units - work_before : 0;
                    stage.completed = (commit.completed_domain_mask &
                        runtime_domain_mask(RuntimeDomainId::COUNTRY)) != 0u;
                } else {
                    if (country_error == "country_worker_peer_results_pending" ||
                        country_error == "country_peer_results_pending") {
                        stage.completed = 0;
                    }
                    commit.preflight_ok = 0;
                }
                continue;
            }
            RuntimeCountryDayContext country_context;
            country_context.day = plan.context.day;
            country_context.speed_scale = plan.context.speed_scale;
            country_context.input_generation = plan.context.input_generation;
            RuntimeCountryDayCommit country_commit;
            RuntimeCountryPodDiagnostics diagnostics;
            const auto country_snapshot = std::atomic_load_explicit(
                &_country_snapshot, std::memory_order_acquire);
            if (country_snapshot && RuntimeCountryPodAdapter::execute_day(
                    *country_snapshot, country_context, country_commit, diagnostics)) {
                std::atomic_store_explicit(&_country_pod_diagnostics,
                    std::make_shared<const RuntimeCountryPodDiagnostics>(diagnostics),
                    std::memory_order_release);
                stage.dirty_families = country_commit.dirty_families;
                stage.work_units = country_commit.research_work_units;
                stage.completed = country_commit.completed;
                commit.dirty_families |= stage.dirty_families;
                commit.work_units += stage.work_units;
                // ACK is intentionally not counted as a complete domain. The
                // adapter is a SHADOW probe until peer domains are POD-safe.
            } else {
                std::atomic_store_explicit(&_country_pod_diagnostics,
                    std::make_shared<const RuntimeCountryPodDiagnostics>(diagnostics),
                    std::memory_order_release);
            }
            continue;
        }
        if (stage.domain != RuntimeDomainId::COMMIT) continue;
        stage.dirty_families = RUNTIME_DIRTY_CLOCK;
        stage.work_units = 1;
        stage.completed = 1;
        commit.dirty_families |= stage.dirty_families;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |= runtime_domain_mask(stage.domain);
        ++commit.completed_stage_count;
    }
    run_events_probe(plan.context.day);
    // A failed authoritative Climate day must not advance the clock. The main
    // thread is suppressed, so advancing anyway would silently drop that day:
    // nobody computed it and nothing would ever go back for it. Zero here parks
    // the worker on the same day until the input barrier clears.
    if (climate_authority_requested && !active_climate_ok) {
        commit.preflight_ok = 0;
    }
    return commit;
}

void NativeSimulationHost::publish_day(
        int64_t from_day, int64_t day,
        const RuntimeDayCommit &day_commit,
        const std::vector<RuntimeCommandReceipt> &day_receipts) {
    const uint64_t next_hash = mix_hash(
        _state_hash.load(std::memory_order_relaxed), static_cast<uint64_t>(day));
    _state_hash.store(next_hash, std::memory_order_release);
    // Publish scalar header fields before the generation release store. A
    // non-blocking reader that observes this generation therefore cannot see
    // metadata from the preceding day even when the visual ring is saturated.
    const uint64_t generation = _generation.load(std::memory_order_relaxed) + 1;
    constexpr std::array<uint32_t, RUNTIME_DIRTY_FAMILY_COUNT> FAMILY_BITS{
        RUNTIME_DIRTY_CLOCK,
        RUNTIME_DIRTY_COUNTRY_STATE,
        RUNTIME_DIRTY_COUNTRY_TERRITORY,
        RUNTIME_DIRTY_COUNTRY_VISUAL_ERA,
        RUNTIME_DIRTY_CLIMATE_FIELDS,
        RUNTIME_DIRTY_WEATHER,
        RUNTIME_DIRTY_ECONOMY_UI,
        RUNTIME_DIRTY_EVENTS,
        RUNTIME_DIRTY_OVERLAY,
    };
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        if ((day_commit.dirty_families & FAMILY_BITS[family_index]) != 0) {
            _dirty_family_generations[family_index].store(
                generation, std::memory_order_relaxed);
        }
    }
    _latest_from_day.store(from_day, std::memory_order_relaxed);
    _latest_committed_day.store(day, std::memory_order_relaxed);
    _latest_dirty_families.store(day_commit.dirty_families, std::memory_order_relaxed);
    _latest_receipt_count.store(static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max())),
        std::memory_order_relaxed);
    const uint64_t produced_at_us = now_us();
    _latest_produced_at_us.store(produced_at_us, std::memory_order_release);
    _generation.store(generation, std::memory_order_release);
    _last_commit_produced_at_us.store(produced_at_us, std::memory_order_release);
    const uint64_t last_visual = _last_visual_publish_us.load(std::memory_order_relaxed);
    // Visual state is capped at 20 Hz. Commands and non-clock dirty families
    // bypass the cap so a user action or major event is visible immediately.
    const bool force_visual = !day_receipts.empty() ||
        (day_commit.dirty_families & ~RUNTIME_DIRTY_CLOCK) != 0;
    if (!force_visual && last_visual != 0 && produced_at_us - last_visual < 50000u) {
        _snapshot_publish_throttled_count.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    uint32_t index = 0;
    if (!_snapshots.try_begin_write(index)) return;
    RuntimeCommit &commit = _snapshots.write_buffer(index);
    commit.header = RuntimeCommitHeader{};
    commit.header.generation = generation;
    commit.header.from_day = from_day;
    commit.header.committed_day = day;
    commit.header.produced_at_us = produced_at_us;
    commit.header.dirty_families = day_commit.dirty_families;
    commit.header.state_hash = _state_hash.load(std::memory_order_acquire);
    commit.header.command_receipt_count = static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max()));
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        commit.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    commit.visual_intents.clear();
    commit.receipts.clear();
    commit.receipts.reserve(day_receipts.size());
    for (const RuntimeCommandReceipt &receipt : day_receipts) {
        commit.receipts.push_back(receipt);
    }
    _snapshots.publish(index);
    _last_visual_publish_us.store(produced_at_us, std::memory_order_release);
    _last_commit_produced_at_us.store(commit.header.produced_at_us,
                                      std::memory_order_release);
}

void NativeSimulationHost::set_fault(const char *code) {
    _worker_fault_count.fetch_add(1, std::memory_order_relaxed);
    // A faulted worker owns nothing. Same reason as request_stop: the schedule
    // gate must hand the domain back to the main thread rather than let a dead
    // worker keep it suppressed.
    _authoritative_domain_mask.store(0, std::memory_order_release);
    const char *value = code ? code : "unknown";
    size_t i = 0;
    for (; i + 1 < _fault_code.size() && value[i] != '\0'; ++i) {
        _fault_code[i].store(value[i], std::memory_order_relaxed);
    }
    for (; i < _fault_code.size(); ++i) {
        _fault_code[i].store('\0', std::memory_order_relaxed);
    }
    _state.store(RuntimeWorkerState::FAULTED, std::memory_order_release);
}

bool NativeSimulationHost::request_save(uint64_t request_id) {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (request_id == 0 || current == RuntimeWorkerState::STOPPED ||
        current == RuntimeWorkerState::STOPPING ||
        current == RuntimeWorkerState::FAULTED ||
        _stop_requested.load(std::memory_order_acquire)) {
        return false;
    }
    uint64_t expected_request = 0;
    if (!_save_request_id.compare_exchange_strong(expected_request, request_id,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(), std::memory_order_release);
    // Publish the flag only after the ID.  The worker's acquire exchange then
    // cannot observe a request without its matching identifier.
    _save_requested.store(true, std::memory_order_release);
    _control_cv.notify_all();
    return true;
}

std::shared_ptr<const RuntimeSaveBundle>
NativeSimulationHost::poll_save(uint64_t request_id) const {
    const auto bundle = std::atomic_load_explicit(&_save_bundle, std::memory_order_acquire);
    if (bundle == nullptr ||
        (request_id != 0 && bundle->request_id != request_id)) {
        return nullptr;
    }
    uint64_t expected = 0;
    if (!_save_consumed_request_id.compare_exchange_strong(
            expected, bundle->request_id, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return nullptr;
    }
    return bundle;
}

bool NativeSimulationHost::restore_bundle(const uint8_t *bytes, size_t size,
                                          std::string &error) {
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        error = "runtime_restore_requires_stopped_worker";
        return false;
    }
    // Fixed v2 scalar header (through section_mask) plus the trailing checksum.
    // The command tail is mandatory in v2 because producer cursors are part of
    // the deterministic restore contract.
    constexpr size_t SCALAR_HEADER_SIZE = 89u;
    constexpr size_t MIN_BUNDLE_SIZE = SCALAR_HEADER_SIZE + 4u + 4u +
        (256u * sizeof(uint64_t)) + sizeof(uint64_t) + sizeof(uint64_t);
    if (bytes == nullptr || size < SCALAR_HEADER_SIZE + sizeof(uint64_t)) {
        error = "runtime_bundle_truncated";
        return false;
    }
    if (std::memcmp(bytes, "PKSR", 4) != 0) {
        error = "runtime_bundle_magic_invalid";
        return false;
    }
    const auto read_u32 = [bytes, size](size_t offset, uint32_t &out) {
        if (offset > size || size - offset < 4u) return false;
        out = static_cast<uint32_t>(bytes[offset]) |
            (static_cast<uint32_t>(bytes[offset + 1u]) << 8u) |
            (static_cast<uint32_t>(bytes[offset + 2u]) << 16u) |
            (static_cast<uint32_t>(bytes[offset + 3u]) << 24u);
        return true;
    };
    const auto read_u16 = [bytes, size](size_t offset, uint16_t &out) {
        if (offset > size || size - offset < 2u) return false;
        out = static_cast<uint16_t>(bytes[offset]) |
            static_cast<uint16_t>(static_cast<uint16_t>(bytes[offset + 1u]) << 8u);
        return true;
    };
    const auto read_u64 = [bytes, size](size_t offset, uint64_t &out) {
        if (offset > size || size - offset < 8u) return false;
        out = 0;
        for (uint32_t i = 0; i < 8u; ++i)
            out |= static_cast<uint64_t>(bytes[offset + i]) << (i * 8u);
        return true;
    };
    uint32_t version = 0;
    if (!read_u32(4u, version) || version != RUNTIME_SAVE_BUNDLE_VERSION) {
        error = "runtime_bundle_version_incompatible";
        return false;
    }
    uint64_t encoded_checksum = 0;
    if (!read_u64(size - sizeof(uint64_t), encoded_checksum)) {
        error = "runtime_bundle_checksum_missing";
        return false;
    }
    uint64_t checksum = 1469598103934665603ull;
    for (size_t i = 0; i + sizeof(uint64_t) < size; ++i) {
        checksum ^= static_cast<uint64_t>(bytes[i]);
        checksum *= 1099511628211ull;
    }
    if (checksum != encoded_checksum) {
        error = "runtime_bundle_checksum_failed";
        return false;
    }
    RuntimeSaveBundle parsed;
    parsed.bytes.assign(bytes, bytes + size);
    parsed.checksum = encoded_checksum;
    parsed.bundle_version = version;
    uint64_t committed_day_bits = 0;
    if (!read_u64(8u, parsed.request_id) ||
        !read_u64(16u, committed_day_bits)) {
        error = "runtime_bundle_header_invalid";
        return false;
    }
    // Decode the signed fields through an integer temporary.  Reinterpreting
    // an int64_t object as uint64_t violates strict-aliasing and is not
    // required by the endian-stable wire format.
    std::memcpy(&parsed.committed_day, &committed_day_bits,
                sizeof(parsed.committed_day));
    uint64_t speed_bits = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t environment_generation = 0;
    uint64_t environment_day_bits = 0;
    uint64_t anomaly_bits = 0;
    uint64_t debt_bits = 0;
    uint32_t runtime_domain_abi_version = 0;
    uint32_t section_mask = 0;
    if (!read_u64(24u, speed_bits) || !read_u64(33u, generation) ||
        !read_u64(41u, state_hash) || !read_u64(49u, environment_generation) ||
        !read_u64(57u, environment_day_bits) || !read_u64(65u, anomaly_bits) ||
        !read_u64(73u, debt_bits) || !read_u32(81u, runtime_domain_abi_version) ||
        !read_u32(85u, section_mask)) {
        error = "runtime_bundle_header_invalid";
        return false;
    }
    std::memcpy(&parsed.speed_days_per_second, &speed_bits, sizeof(double));
    parsed.paused = bytes[32u] != 0;
    parsed.generation = generation;
    parsed.state_hash = state_hash;
    parsed.environment_generation = environment_generation;
    parsed.runtime_domain_abi_version = runtime_domain_abi_version;
    parsed.section_mask = section_mask;
    std::memcpy(&parsed.environment_day, &environment_day_bits, sizeof(int64_t));
    std::memcpy(&parsed.climate_anomaly, &anomaly_bits, sizeof(double));
    std::memcpy(&parsed.time_debt_days, &debt_bits, sizeof(double));
    if (parsed.committed_day < 0 || parsed.environment_day < 0 ||
        !std::isfinite(parsed.speed_days_per_second) ||
        parsed.speed_days_per_second < 0.0 ||
        !std::isfinite(parsed.climate_anomaly) ||
        !std::isfinite(parsed.time_debt_days) ||
        parsed.time_debt_days < 0.0 || parsed.time_debt_days > 100.0) {
        error = "runtime_bundle_value_invalid";
        return false;
    }
    if (parsed.runtime_domain_abi_version != RUNTIME_DOMAIN_ABI_VERSION) {
        error = "runtime_bundle_domain_abi_incompatible";
        return false;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE) == 0 ||
        (parsed.section_mask & ~(RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
                                 RUNTIME_SAVE_SECTION_DOMAIN_POD |
                                 RUNTIME_SAVE_SECTION_CLIMATE |
                                 RUNTIME_SAVE_SECTION_COUNTRY |
                                 RUNTIME_SAVE_SECTION_MODIFIER |
                                 RUNTIME_SAVE_SECTION_TRIGGER |
                                 RUNTIME_SAVE_SECTION_EVENTS |
                                 RUNTIME_SAVE_SECTION_EFFECT |
                                 RUNTIME_SAVE_SECTION_IDEOLOGY)) != 0) {
        error = "runtime_bundle_section_mask_invalid";
        return false;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EFFECT) == 0) {
        error = "runtime_bundle_effect_section_missing";
        return false;
    }
    if (size < MIN_BUNDLE_SIZE) {
        error = "runtime_bundle_tail_missing";
        return false;
    }
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    size_t cursor = SCALAR_HEADER_SIZE;
    const size_t payload_end = size - sizeof(uint64_t);
    uint32_t command_count = 0;
    if (!read_u32(cursor, command_count) ||
        command_count > RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "runtime_bundle_command_count_invalid";
        return false;
    }
    cursor += 4u;
    parsed.pending_commands.reserve(command_count);
    for (uint32_t i = 0; i < command_count; ++i) {
        RuntimeCommandPacket packet;
        RuntimeCommandEnvelope &envelope = packet.envelope;
        uint64_t requested_day_bits = 0;
        uint64_t effective_day_bits = 0;
        if (!read_u64(cursor, envelope.request_id) ||
            !read_u32(cursor + 8u, envelope.producer_id) ||
            !read_u64(cursor + 12u, envelope.sequence) ||
            !read_u64(cursor + 20u, envelope.observed_generation) ||
            !read_u64(cursor + 28u, requested_day_bits) ||
            !read_u64(cursor + 36u, effective_day_bits) ||
            !read_u16(cursor + 44u, envelope.domain) ||
            !read_u16(cursor + 46u, envelope.opcode) ||
            !read_u32(cursor + 48u, envelope.payload_size)) {
            error = "runtime_bundle_command_truncated";
            return false;
        }
        std::memcpy(&envelope.requested_day, &requested_day_bits,
                    sizeof(envelope.requested_day));
        std::memcpy(&envelope.effective_day, &effective_day_bits,
                    sizeof(envelope.effective_day));
        envelope.payload_offset = 0;
        cursor += 52u;
        if (envelope.request_id == 0 || envelope.requested_day < 0 ||
            envelope.effective_day < 0 || envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
            envelope.domain > static_cast<uint16_t>(RuntimeDomainId::COMMIT) ||
            envelope.opcode == 0 ||
            cursor > payload_end || envelope.payload_size > payload_end - cursor) {
            error = "runtime_bundle_command_invalid";
            return false;
        }
        if (envelope.payload_size > 0) {
            std::memcpy(packet.payload.data(), bytes + cursor,
                        envelope.payload_size);
        }
        cursor += envelope.payload_size;
        parsed.pending_commands.push_back(std::move(packet));
    }
    uint32_t marker = 0;
    if (!read_u32(cursor, marker) || marker != PRODUCER_CURSOR_MARKER) {
        error = "runtime_bundle_producer_cursor_missing";
        return false;
    }
    cursor += 4u;
    for (uint64_t &sequence : parsed.producer_sequences) {
        if (!read_u64(cursor, sequence)) {
            error = "runtime_bundle_producer_cursor_truncated";
            return false;
        }
        cursor += 8u;
    }
    if (!read_u64(cursor, parsed.fallback_producer_sequence)) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    cursor += 8u;
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_DOMAIN_POD) != 0) {
        constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
        uint32_t marker = 0;
        uint32_t section_size = 0;
        const bool section_header_available = cursor <= payload_end &&
            payload_end - cursor >= 8u;
        if (!section_header_available || !read_u32(cursor, marker) ||
            marker != DOMAIN_SECTION_MARKER ||
            !read_u32(cursor + 4u, section_size) ||
            section_size > 64u * 1024u * 1024u ||
            payload_end - cursor < 16u ||
            section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_domain_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.domain_pod_bytes.assign(bytes + cursor, bytes + cursor + section_size);
        cursor += section_size;
        uint64_t section_checksum = 0;
        if (!read_u64(cursor, section_checksum)) {
            error = "runtime_bundle_domain_section_checksum_missing";
            return false;
        }
        uint64_t computed_section_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.domain_pod_bytes) {
            computed_section_checksum ^= static_cast<uint64_t>(byte);
            computed_section_checksum *= 1099511628211ull;
        }
        if (computed_section_checksum != section_checksum) {
            error = "runtime_bundle_domain_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_CLIMATE) != 0) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // CLM2
        uint32_t climate_marker = 0;
        uint32_t climate_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, climate_marker) ||
            !read_u32(cursor + 4u, climate_size) ||
            climate_marker != CLIMATE_SECTION_MARKER ||
            climate_size > 64u * 1024u * 1024u ||
            climate_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_climate_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.climate_bytes.assign(bytes + cursor, bytes + cursor + climate_size);
        cursor += climate_size;
        uint64_t climate_checksum = 0;
        if (!read_u64(cursor, climate_checksum)) {
            error = "runtime_bundle_climate_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.climate_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != climate_checksum) {
            error = "runtime_bundle_climate_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_COUNTRY) != 0) {
        constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
        uint32_t country_marker = 0;
        uint32_t country_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, country_marker) ||
            !read_u32(cursor + 4u, country_size) ||
            country_marker != COUNTRY_SECTION_MARKER ||
            country_size > 64u * 1024u * 1024u ||
            country_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_country_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.country_bytes.assign(bytes + cursor, bytes + cursor + country_size);
        cursor += country_size;
        uint64_t country_checksum = 0;
        if (!read_u64(cursor, country_checksum)) {
            error = "runtime_bundle_country_section_checksum_missing";
            return false;
        }
        const uint64_t computed = country_checkpoint_checksum(
            parsed.country_bytes.data(), parsed.country_bytes.size());
        if (computed != country_checksum) {
            error = "runtime_bundle_country_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        CountryCoreCheckpoint checkpoint;
        if (!decode_country_core_checkpoint(parsed.country_bytes.data(),
                                            parsed.country_bytes.size(),
                                            checkpoint, error)) {
            error = "runtime_bundle_country_section_invalid:" + error;
            return false;
        }
        std::unordered_map<uint64_t, CountryCommandReceiptCode> country_states;
        country_states.reserve(checkpoint.request_states.size());
        for (const CountryCommandReceipt &receipt : checkpoint.request_states)
            country_states.emplace(receipt.request_id, receipt.code);
        std::unordered_set<uint64_t> country_terminals;
        country_terminals.reserve(checkpoint.terminal_receipts.size());
        for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
            country_terminals.insert(receipt.request_id);
        for (const RuntimeCommandPacket &packet : parsed.pending_commands) {
            if (packet.envelope.domain !=
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY)) {
                continue;
            }
            const auto state = country_states.find(packet.envelope.request_id);
            if (state == country_states.end() ||
                state->second != CountryCommandReceiptCode::ACCEPTED ||
                country_terminals.find(packet.envelope.request_id) !=
                    country_terminals.end()) {
                error = "runtime_bundle_country_pending_receipt_invalid";
                return false;
            }
        }
        parsed.country_pkcn_bytes = checkpoint.canonical_pkcn;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_TRIGGER) != 0) {
        constexpr uint32_t TRIGGER_SECTION_MARKER = 0x31445054u; // TPD1
        uint32_t trigger_marker = 0;
        uint32_t trigger_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, trigger_marker) ||
            !read_u32(cursor + 4u, trigger_size) ||
            trigger_marker != TRIGGER_SECTION_MARKER ||
            trigger_size > 64u * 1024u * 1024u ||
            trigger_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_trigger_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.trigger_bytes.assign(bytes + cursor, bytes + cursor + trigger_size);
        cursor += trigger_size;
        uint64_t trigger_checksum = 0;
        if (!read_u64(cursor, trigger_checksum)) {
            error = "runtime_bundle_trigger_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.trigger_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != trigger_checksum) {
            error = "runtime_bundle_trigger_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_MODIFIER) != 0) {
        constexpr uint32_t MODIFIER_SECTION_MARKER = 0x3246444Du; // MDF2
        uint32_t modifier_marker = 0;
        uint32_t modifier_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, modifier_marker) ||
            !read_u32(cursor + 4u, modifier_size) ||
            modifier_marker != MODIFIER_SECTION_MARKER ||
            modifier_size > 64u * 1024u * 1024u ||
            modifier_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_modifier_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.modifier_bytes.assign(bytes + cursor, bytes + cursor + modifier_size);
        cursor += modifier_size;
        uint64_t modifier_checksum = 0;
        if (!read_u64(cursor, modifier_checksum)) {
            error = "runtime_bundle_modifier_section_checksum_missing";
            return false;
        }
        uint64_t computed_modifier = 1469598103934665603ull;
        for (const uint8_t byte : parsed.modifier_bytes) {
            computed_modifier ^= static_cast<uint64_t>(byte);
            computed_modifier *= 1099511628211ull;
        }
        if (computed_modifier != modifier_checksum) {
            error = "runtime_bundle_modifier_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.modifier_bytes.size() < 4u ||
            std::memcmp(parsed.modifier_bytes.data(), "MDF2", 4u) != 0) {
            error = "runtime_bundle_modifier_section_marker_invalid";
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EVENTS) != 0) {
        constexpr uint32_t EVENTS_SECTION_MARKER = 0x31545645u; // EVT1
        uint32_t events_marker = 0;
        uint32_t events_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, events_marker) ||
            !read_u32(cursor + 4u, events_size) ||
            events_marker != EVENTS_SECTION_MARKER ||
            events_size > 64u * 1024u * 1024u ||
            events_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_events_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.events_bytes.assign(bytes + cursor, bytes + cursor + events_size);
        cursor += events_size;
        uint64_t events_checksum = 0;
        if (!read_u64(cursor, events_checksum)) {
            error = "runtime_bundle_events_section_checksum_missing";
            return false;
        }
        uint64_t computed_events = 1469598103934665603ull;
        for (const uint8_t byte : parsed.events_bytes) {
            computed_events ^= static_cast<uint64_t>(byte);
            computed_events *= 1099511628211ull;
        }
        if (computed_events != events_checksum) {
            error = "runtime_bundle_events_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.events_bytes.size() < 4u ||
            std::memcmp(parsed.events_bytes.data(), "EVT1", 4u) != 0) {
            error = "runtime_bundle_events_section_marker_invalid";
            return false;
        }
        RuntimeEventsAuthority candidate;
        std::string events_restore_error;
        if (!candidate.restore(parsed.events_bytes.data(),
                               parsed.events_bytes.size(), events_restore_error)) {
            error = events_restore_error.empty()
                ? "runtime_bundle_events_restore_invalid" : events_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_EFFECT) != 0) {
        constexpr uint32_t EFFECT_SECTION_MARKER = 0x31504645u; // EFP1
        uint32_t effect_marker = 0;
        uint32_t effect_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, effect_marker) ||
            !read_u32(cursor + 4u, effect_size) ||
            effect_marker != EFFECT_SECTION_MARKER ||
            effect_size > 64u * 1024u * 1024u ||
            effect_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_effect_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.effect_bytes.assign(bytes + cursor, bytes + cursor + effect_size);
        cursor += effect_size;
        uint64_t effect_checksum = 0;
        if (!read_u64(cursor, effect_checksum)) {
            error = "runtime_bundle_effect_section_checksum_missing";
            return false;
        }
        uint64_t computed_effect = 1469598103934665603ull;
        for (const uint8_t byte : parsed.effect_bytes) {
            computed_effect ^= static_cast<uint64_t>(byte);
            computed_effect *= 1099511628211ull;
        }
        if (computed_effect != effect_checksum) {
            error = "runtime_bundle_effect_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.effect_bytes.size() < 4u ||
            std::memcmp(parsed.effect_bytes.data(), "EFP1", 4u) != 0) {
            error = "runtime_bundle_effect_section_marker_invalid";
            return false;
        }
        if (!_effect_pod_configured) {
            error = "runtime_bundle_effect_catalog_missing";
            return false;
        }
        RuntimeEffectPodAuthority candidate;
        std::string effect_restore_error;
        if (!candidate.configure(_effect_pod_catalog, effect_restore_error) ||
            !candidate.restore(parsed.effect_bytes.data(),
                               parsed.effect_bytes.size(), effect_restore_error)) {
            error = effect_restore_error.empty()
                ? "runtime_bundle_effect_restore_invalid" : effect_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_IDEOLOGY) != 0) {
        constexpr uint32_t IDEOLOGY_SECTION_MARKER = 0x31504449u; // IDP1
        uint32_t ideology_marker = 0;
        uint32_t ideology_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, ideology_marker) ||
            !read_u32(cursor + 4u, ideology_size) ||
            ideology_marker != IDEOLOGY_SECTION_MARKER ||
            ideology_size > 64u * 1024u * 1024u ||
            ideology_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_ideology_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.ideology_bytes.assign(bytes + cursor, bytes + cursor + ideology_size);
        cursor += ideology_size;
        uint64_t ideology_checksum = 0;
        if (!read_u64(cursor, ideology_checksum)) {
            error = "runtime_bundle_ideology_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.ideology_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != ideology_checksum) {
            error = "runtime_bundle_ideology_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.ideology_bytes.size() < 4u ||
            std::memcmp(parsed.ideology_bytes.data(), "IDP1", 4u) != 0 ||
            !_ideology_pod_configured) {
            error = !_ideology_pod_configured
                ? "runtime_bundle_ideology_catalog_missing"
                : "runtime_bundle_ideology_section_marker_invalid";
            return false;
        }
        RuntimeIdeologyPodAuthority candidate;
        std::string ideology_restore_error;
        if (!candidate.configure(_ideology_pod_catalog,
                                 ideology_restore_error) ||
            !candidate.restore(parsed.ideology_bytes.data(),
                               parsed.ideology_bytes.size(),
                               ideology_restore_error)) {
            error = ideology_restore_error.empty()
                ? "runtime_bundle_ideology_restore_invalid"
                : ideology_restore_error;
            return false;
        }
    }
    if (cursor != payload_end) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    _pending_restore_bundle = std::move(parsed);
    _has_pending_restore = true;
    return true;
}

void NativeSimulationHost::build_save_bundle(
        uint64_t request_id,
        const std::vector<RuntimeCommandPacket> &pending_commands) {
    auto bundle = std::make_shared<RuntimeSaveBundle>();
    bundle->request_id = request_id;
    bundle->bundle_version = RUNTIME_SAVE_BUNDLE_VERSION;
    bundle->runtime_domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    bundle->section_mask = RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
        RUNTIME_SAVE_SECTION_DOMAIN_POD;
    bundle->committed_day = _committed_day.load(std::memory_order_acquire);
    bundle->paused = _paused.load(std::memory_order_acquire);
    bundle->speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    bundle->generation = _generation.load(std::memory_order_acquire);
    bundle->state_hash = _state_hash.load(std::memory_order_acquire);
    bundle->environment_generation = _environment_generation.load(
        std::memory_order_acquire);
    bundle->environment_day = _environment_day.load(std::memory_order_acquire);
    bundle->time_debt_days = _time_debt_days.load(std::memory_order_acquire);
    bundle->pending_commands = pending_commands;
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        bundle->producer_sequences[i] = _producer_sequences[i].load(
            std::memory_order_acquire);
    }
    bundle->fallback_producer_sequence = _fallback_producer_sequence.load(
        std::memory_order_acquire);
    if (const auto environment = environment_snapshot()) {
        bundle->climate_anomaly = environment->climate_anomaly;
    }
    _pod_pipeline.serialize(bundle->domain_pod_bytes);
    const bool include_climate = _climate_authority.store().cell_count != 0;
    if (include_climate) {
        std::string climate_save_error;
        if (!_climate_authority.serialize(bundle->climate_bytes, climate_save_error)) {
            set_fault(climate_save_error.empty() ? "climate_save_encode_failed" :
                      climate_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_CLIMATE;
    }
    const auto country_checkpoint = std::atomic_load_explicit(
        &_country_checkpoint, std::memory_order_acquire);
    if (country_checkpoint != nullptr) {
        // The synchronous checkpoint carries the canonical PKCN business
        // payload. Host protocol state is merged here at the same save
        // boundary, so pending worker packets and terminal receipts cannot
        // drift from the PKCN generation/day/hash they accompany.
        CountryCoreCheckpoint checkpoint = *country_checkpoint;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            std::map<uint64_t, CountryCommandReceipt> states;
            for (const CountryCommandReceipt &receipt : checkpoint.request_states)
                states.emplace(receipt.request_id, receipt);
            std::map<uint64_t, CountryCommandReceipt> terminals;
            for (const CountryCommandReceipt &receipt : checkpoint.terminal_receipts)
                terminals.emplace(receipt.request_id, receipt);

            for (const auto &entry : _country_command_states) {
                const CountryCommandReceipt &receipt = entry.second;
                const auto existing = states.find(receipt.request_id);
                if (existing == states.end()) {
                    states.emplace(receipt.request_id, receipt);
                } else if (existing->second.code != receipt.code ||
                           existing->second.effective_day != receipt.effective_day) {
                    set_fault("country_save_request_state_conflict");
                    return;
                }
            }
            for (const RuntimeCommandPacket &packet : pending_commands) {
                if (packet.envelope.domain !=
                        static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
                    packet.envelope.request_id == 0) {
                    continue;
                }
                const auto existing = states.find(packet.envelope.request_id);
                if (existing == states.end()) {
                    CountryCommandReceipt accepted;
                    accepted.request_id = packet.envelope.request_id;
                    accepted.producer_id = packet.envelope.producer_id;
                    accepted.sequence = packet.envelope.sequence;
                    accepted.effective_day = packet.envelope.effective_day;
                    accepted.generation = checkpoint.generation;
                    accepted.code = CountryCommandReceiptCode::ACCEPTED;
                    states.emplace(accepted.request_id, std::move(accepted));
                } else if (existing->second.code != CountryCommandReceiptCode::ACCEPTED) {
                    set_fault("country_save_pending_receipt_not_accepted");
                    return;
                }
            }
            for (const auto &entry : _country_command_terminals) {
                const CountryCommandReceipt &receipt = entry.second;
                const auto existing = states.find(receipt.request_id);
                if (existing == states.end() || existing->second.code != receipt.code) {
                    set_fault("country_save_terminal_receipt_state_mismatch");
                    return;
                }
                terminals.emplace(receipt.request_id, receipt);
            }
            checkpoint.request_states.clear();
            checkpoint.request_states.reserve(states.size());
            for (const auto &entry : states)
                checkpoint.request_states.push_back(entry.second);
            checkpoint.terminal_receipts.clear();
            checkpoint.terminal_receipts.reserve(terminals.size());
            for (const auto &entry : terminals)
                checkpoint.terminal_receipts.push_back(entry.second);
        }
        std::string country_save_error;
        if (!encode_country_core_checkpoint(checkpoint,
                                            bundle->country_bytes,
                                            country_save_error)) {
            set_fault(country_save_error.empty() ? "country_save_encode_failed" :
                      country_save_error.c_str());
            return;
        }
        bundle->country_pkcn_bytes = checkpoint.canonical_pkcn;
        bundle->section_mask |= RUNTIME_SAVE_SECTION_COUNTRY;
    }
    RuntimeTriggerPodSaveSection trigger_save;
    std::string trigger_save_error;
    if (_domain_authority_runner.encode_trigger_save(trigger_save,
                                                     trigger_save_error)) {
        bundle->trigger_bytes = std::move(trigger_save.payload);
        bundle->section_mask |= RUNTIME_SAVE_SECTION_TRIGGER;
    }
    if (_modifier_pod_configured) {
        std::vector<RuntimeModifierPodCommand> modifier_pending;
        modifier_pending.reserve(pending_commands.size());
        for (const RuntimeCommandPacket &packet : pending_commands) {
            RuntimeModifierPodCommand command;
            if (decode_modifier_packet(packet, command))
                modifier_pending.push_back(command);
        }
        _modifier_pod_authority.set_pending_command_identities(modifier_pending);
        _modifier_pod_authority.serialize(bundle->modifier_bytes);
        if (bundle->modifier_bytes.empty()) {
            set_fault("modifier_save_encode_failed");
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_MODIFIER;
    }
    {
        std::string events_save_error;
        if (!_events_authority.serialize(bundle->events_bytes, events_save_error)) {
            set_fault(events_save_error.empty() ? "events_save_encode_failed" :
                      events_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EVENTS;
    }
    if (_effect_pod_configured) {
        std::string effect_save_error;
        if (!encode_effect_pod_save(bundle->effect_bytes, effect_save_error)) {
            set_fault(effect_save_error.empty() ? "effect_save_encode_failed" :
                      effect_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_EFFECT;
    }
    if (_ideology_pod_configured) {
        std::string ideology_save_error;
        if (!encode_ideology_pod_save(bundle->ideology_bytes,
                                      ideology_save_error)) {
            set_fault(ideology_save_error.empty()
                ? "ideology_save_encode_failed"
                : ideology_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_IDEOLOGY;
    }

    // PKSR v2 is an endian-stable runtime envelope. The fixed scalar header
    // carries an explicit ABI/section mask, followed by a bounded pending
    // command tail and producer cursors. The checksum remains the final eight
    // bytes and the complete tail is mandatory for v2 restores.
    bundle->bytes.reserve(4 + 4 + 8 * 10 + 1 + 4 + 4 +
        bundle->pending_commands.size() * (8 + 4 + 8 + 8 + 8 + 8 + 2 + 2 + 4 +
                                           RUNTIME_MAX_COMMAND_PAYLOAD) +
        bundle->producer_sequences.size() * 8 + 8 + 8);
    const auto append_bytes = [&bundle](const void *data, size_t size) {
        const size_t offset = bundle->bytes.size();
        bundle->bytes.resize(offset + size);
        std::memcpy(bundle->bytes.data() + offset, data, size);
    };
    const auto append_u32_le = [&append_bytes](uint32_t value) {
        const std::array<uint8_t, 4> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
            static_cast<uint8_t>((value >> 16u) & 0xffu),
            static_cast<uint8_t>((value >> 24u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u16_le = [&append_bytes](uint16_t value) {
        const std::array<uint8_t, 2> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u64_le = [&append_bytes](uint64_t value) {
        std::array<uint8_t, 8> bytes{};
        for (uint32_t i = 0; i < bytes.size(); ++i)
            bytes[i] = static_cast<uint8_t>((value >> (i * 8u)) & 0xffu);
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_i64_le = [&append_u64_le](int64_t value) {
        append_u64_le(static_cast<uint64_t>(value));
    };
    const auto append_f64_le = [&append_u64_le](double value) {
        uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        append_u64_le(bits);
    };
    const char magic[4] = {'P', 'K', 'S', 'R'};
    const uint32_t version = RUNTIME_SAVE_BUNDLE_VERSION;
    const uint8_t paused = bundle->paused ? 1u : 0u;
    append_bytes(magic, sizeof(magic));
    append_u32_le(version);
    append_u64_le(bundle->request_id);
    append_i64_le(bundle->committed_day);
    append_f64_le(bundle->speed_days_per_second);
    append_bytes(&paused, sizeof(paused));
    append_u64_le(bundle->generation);
    append_u64_le(bundle->state_hash);
    append_u64_le(bundle->environment_generation);
    append_i64_le(bundle->environment_day);
    append_f64_le(bundle->climate_anomaly);
    append_f64_le(bundle->time_debt_days);
    append_u32_le(RUNTIME_DOMAIN_ABI_VERSION);
    append_u32_le(bundle->section_mask);

    const uint32_t pending_count = static_cast<uint32_t>(std::min<size_t>(
        bundle->pending_commands.size(), RUNTIME_COMMAND_QUEUE_CAPACITY));
    append_u32_le(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        const RuntimeCommandPacket &command = bundle->pending_commands[i];
        const RuntimeCommandEnvelope &envelope = command.envelope;
        append_u64_le(envelope.request_id);
        append_u32_le(envelope.producer_id);
        append_u64_le(envelope.sequence);
        append_u64_le(envelope.observed_generation);
        append_i64_le(envelope.requested_day);
        append_i64_le(envelope.effective_day);
        append_u16_le(envelope.domain);
        append_u16_le(envelope.opcode);
        append_u32_le(envelope.payload_size);
        if (envelope.payload_size > 0) {
            append_bytes(command.payload.data(), envelope.payload_size);
        }
    }
    // A marker separates optional command records from producer cursors. This
    // lets a future PKSR decoder reject a truncated tail instead of treating
    // arbitrary bytes as sequence state.
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    append_u32_le(PRODUCER_CURSOR_MARKER);
    for (uint64_t sequence : bundle->producer_sequences)
        append_u64_le(sequence);
    append_u64_le(bundle->fallback_producer_sequence);
    constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
    append_u32_le(DOMAIN_SECTION_MARKER);
    append_u32_le(static_cast<uint32_t>(std::min<size_t>(
        bundle->domain_pod_bytes.size(), 64u * 1024u * 1024u)));
    const uint32_t domain_section_size = static_cast<uint32_t>(std::min<size_t>(
        bundle->domain_pod_bytes.size(), 64u * 1024u * 1024u));
    if (domain_section_size > 0) {
        append_bytes(bundle->domain_pod_bytes.data(), domain_section_size);
    }
    uint64_t domain_checksum = 1469598103934665603ull;
    for (uint32_t i = 0; i < domain_section_size; ++i) {
        domain_checksum ^= static_cast<uint64_t>(bundle->domain_pod_bytes[i]);
        domain_checksum *= 1099511628211ull;
    }
    append_u64_le(domain_checksum);

    if (include_climate) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // "CLM2"
        append_u32_le(CLIMATE_SECTION_MARKER);
        const uint32_t climate_section_size = static_cast<uint32_t>(std::min<size_t>(
            bundle->climate_bytes.size(), 64u * 1024u * 1024u));
        append_u32_le(climate_section_size);
        if (climate_section_size > 0)
            append_bytes(bundle->climate_bytes.data(), climate_section_size);
        uint64_t climate_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < climate_section_size; ++i) {
            climate_checksum ^= static_cast<uint64_t>(bundle->climate_bytes[i]);
            climate_checksum *= 1099511628211ull;
        }
        append_u64_le(climate_checksum);
    }

    if (country_checkpoint != nullptr) {
        constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
        append_u32_le(COUNTRY_SECTION_MARKER);
        const uint32_t country_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->country_bytes.size(),
                             64u * 1024u * 1024u));
        append_u32_le(country_section_size);
        if (country_section_size > 0)
            append_bytes(bundle->country_bytes.data(), country_section_size);
        append_u64_le(country_checkpoint_checksum(bundle->country_bytes.data(),
                                                   country_section_size));
    }

    if (!bundle->trigger_bytes.empty()) {
        constexpr uint32_t TRIGGER_SECTION_MARKER = 0x31445054u; // TPD1
        append_u32_le(TRIGGER_SECTION_MARKER);
        const uint32_t trigger_section_size = static_cast<uint32_t>(std::min<size_t>(
            bundle->trigger_bytes.size(), 64u * 1024u * 1024u));
        append_u32_le(trigger_section_size);
        append_bytes(bundle->trigger_bytes.data(), trigger_section_size);
        uint64_t trigger_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < trigger_section_size; ++i) {
            trigger_checksum ^= static_cast<uint64_t>(bundle->trigger_bytes[i]);
            trigger_checksum *= 1099511628211ull;
        }
        append_u64_le(trigger_checksum);
    }

    if (!bundle->modifier_bytes.empty()) {
        constexpr uint32_t MODIFIER_SECTION_MARKER = 0x3246444Du; // MDF2
        append_u32_le(MODIFIER_SECTION_MARKER);
        const uint32_t modifier_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->modifier_bytes.size(),
                             64u * 1024u * 1024u));
        append_u32_le(modifier_section_size);
        append_bytes(bundle->modifier_bytes.data(), modifier_section_size);
        uint64_t modifier_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < modifier_section_size; ++i) {
            modifier_checksum ^= static_cast<uint64_t>(bundle->modifier_bytes[i]);
            modifier_checksum *= 1099511628211ull;
        }
        append_u64_le(modifier_checksum);
    }

    if (!bundle->events_bytes.empty()) {
        constexpr uint32_t EVENTS_SECTION_MARKER = 0x31545645u; // EVT1
        append_u32_le(EVENTS_SECTION_MARKER);
        const uint32_t events_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->events_bytes.size(), 64u * 1024u * 1024u));
        append_u32_le(events_section_size);
        append_bytes(bundle->events_bytes.data(), events_section_size);
        uint64_t events_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < events_section_size; ++i) {
            events_checksum ^= static_cast<uint64_t>(bundle->events_bytes[i]);
            events_checksum *= 1099511628211ull;
        }
        append_u64_le(events_checksum);
    }

    if (!bundle->effect_bytes.empty()) {
        constexpr uint32_t EFFECT_SECTION_MARKER = 0x31504645u; // EFP1
        append_u32_le(EFFECT_SECTION_MARKER);
        const uint32_t effect_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->effect_bytes.size(), 64u * 1024u * 1024u));
        append_u32_le(effect_section_size);
        append_bytes(bundle->effect_bytes.data(), effect_section_size);
        uint64_t effect_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < effect_section_size; ++i) {
            effect_checksum ^= static_cast<uint64_t>(bundle->effect_bytes[i]);
            effect_checksum *= 1099511628211ull;
        }
        append_u64_le(effect_checksum);
    }

    if (!bundle->ideology_bytes.empty()) {
        constexpr uint32_t IDEOLOGY_SECTION_MARKER = 0x31504449u; // IDP1
        append_u32_le(IDEOLOGY_SECTION_MARKER);
        const uint32_t ideology_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->ideology_bytes.size(),
                             64u * 1024u * 1024u));
        append_u32_le(ideology_section_size);
        append_bytes(bundle->ideology_bytes.data(), ideology_section_size);
        uint64_t ideology_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < ideology_section_size; ++i) {
            ideology_checksum ^= static_cast<uint64_t>(bundle->ideology_bytes[i]);
            ideology_checksum *= 1099511628211ull;
        }
        append_u64_le(ideology_checksum);
    }

    uint64_t checksum = 1469598103934665603ull;
    for (uint8_t byte : bundle->bytes) {
        checksum ^= static_cast<uint64_t>(byte);
        checksum *= 1099511628211ull;
    }
    bundle->checksum = checksum;
    append_u64_le(bundle->checksum);

    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(std::move(bundle)),
        std::memory_order_release);
}

void NativeSimulationHost::worker_main() {
#if defined(_WIN32)
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
    _state.store(_paused.load(std::memory_order_acquire)
            ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
            std::memory_order_release);
    auto last = std::chrono::steady_clock::now();
    // Allocate the bounded protocol capacity once when the worker starts.
    // Daily command processing must not grow a vector in the simulation hot
    // loop when a UI burst happens to exceed the usual batch size.
    std::vector<RuntimeCommandPacket> pending_commands;
    pending_commands.reserve(RUNTIME_COMMAND_QUEUE_CAPACITY);
    size_t pending_begin = 0;
    if (!_worker_initial_pending_commands.empty()) {
        pending_commands = std::move(_worker_initial_pending_commands);
    }
    // PKSR v2 predates the explicit live admission watermark. Reconstruct
    // missing values in saved order, while preserving values already assigned
    // by the accepting queue in the current session.
    for (RuntimeCommandPacket &packet : pending_commands) {
        if (packet.submit_order == 0) {
            packet.submit_order = _command_submit_order.fetch_add(
                1u, std::memory_order_relaxed) + 1u;
        } else {
            uint64_t current_order = _command_submit_order.load(
                std::memory_order_relaxed);
            while (current_order < packet.submit_order &&
                   !_command_submit_order.compare_exchange_weak(
                       current_order, packet.submit_order,
                       std::memory_order_relaxed,
                       std::memory_order_relaxed)) {
            }
        }
    }
    std::vector<RuntimeCommandReceipt> day_receipts;
    day_receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    bool pending_commands_dirty = !pending_commands.empty();
    const auto compact_pending_commands = [&](bool force = false) {
        if (pending_begin == 0) return;
        if (pending_begin >= pending_commands.size()) {
            pending_commands.clear();
            pending_begin = 0;
            pending_commands_dirty = false;
            return;
        }
        // Front consumption is the common path. Compact only after a sizeable
        // prefix is dead so daily command handling stays O(1) amortized while
        // a save still receives a contiguous active tail.
        if (!force && pending_begin < 256u && pending_begin * 2u < pending_commands.size()) return;
        const auto active_begin = pending_commands.begin() +
            static_cast<ptrdiff_t>(pending_begin);
        std::move(active_begin, pending_commands.end(), pending_commands.begin());
        pending_commands.resize(pending_commands.size() - pending_begin);
        pending_begin = 0;
    };
    try {
        while (!_stop_requested.load(std::memory_order_acquire)) {
            if (_stop_requested.load(std::memory_order_acquire)) break;

            if (_save_requested.exchange(false, std::memory_order_acq_rel)) {
                const uint64_t request_id = _save_request_id.load(std::memory_order_acquire);
                // Commands in the lock-free ingress queue are already
                // accepted but not yet visible in the worker-local list. Move
                // them across the same boundary before encoding the bundle so
                // SAVE_REQUEST never loses an accepted command.
                RuntimeCommandPacket queued;
                while (pop_command(queued)) {
                    pending_commands.push_back(queued);
                    pending_commands_dirty = true;
                }
                compact_pending_commands(true);
                _state.store(RuntimeWorkerState::SAVE_PENDING, std::memory_order_release);
                build_save_bundle(request_id, pending_commands);
                _save_request_id.store(0, std::memory_order_release);
                _state.store(_paused.load(std::memory_order_acquire)
                        ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
                        std::memory_order_release);
                last = std::chrono::steady_clock::now();
                continue;
            }

            const bool paused = _paused.load(std::memory_order_acquire);
            const double speed = _speed_days_per_second.load(std::memory_order_acquire);
            if (paused || speed <= 0.0 || !std::isfinite(speed)) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                _state.store(RuntimeWorkerState::PAUSED, std::memory_order_release);
                last = std::chrono::steady_clock::now();
                std::unique_lock<std::mutex> lock(_control_mutex);
                _control_cv.wait(lock, [&] {
                    return _stop_requested.load(std::memory_order_acquire) ||
                        _save_requested.load(std::memory_order_acquire) ||
                        !_paused.load(std::memory_order_acquire) ||
                        _speed_days_per_second.load(std::memory_order_acquire) > 0.0;
                });
                continue;
            }
            if (_stop_requested.load(std::memory_order_acquire)) break;
            _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
            RuntimeCommandPacket incoming;
            while (pop_command(incoming)) {
                pending_commands.push_back(incoming);
                pending_commands_dirty = true;
            }
            const auto now = std::chrono::steady_clock::now();
            const double elapsed = std::chrono::duration<double>(now - last).count();
            last = now;
            double debt = std::min(100.0,
                _time_debt_days.load(std::memory_order_relaxed) + elapsed * speed);
            int64_t target_days = static_cast<int64_t>(debt);
            if (target_days <= 0) {
                _time_debt_days.store(debt, std::memory_order_release);
                const double seconds_until_day = std::max(0.001, (1.0 - debt) / speed);
                std::unique_lock<std::mutex> lock(_control_mutex);
                _control_cv.wait_until(lock, std::chrono::steady_clock::now() +
                    std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                        std::chrono::duration<double>(seconds_until_day)));
                continue;
            }
            target_days = std::min<int64_t>(target_days, 8);
            debt -= static_cast<double>(target_days);
            _time_debt_days.store(std::min(100.0, debt), std::memory_order_release);
            for (int64_t step = 0; step < target_days; ++step) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                const int64_t from_day = _committed_day.load(std::memory_order_acquire);
                const int64_t day = from_day + 1;
                day_receipts.clear();
                if (pending_commands_dirty) {
                    std::stable_sort(pending_commands.begin() +
                        static_cast<ptrdiff_t>(pending_begin), pending_commands.end(),
                    [](const RuntimeCommandPacket &lhs, const RuntimeCommandPacket &rhs) {
                        const RuntimeCommandEnvelope &a = lhs.envelope;
                        const RuntimeCommandEnvelope &b = rhs.envelope;
                        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
                        if (a.sequence != b.sequence) return a.sequence < b.sequence;
                        if (lhs.submit_order != rhs.submit_order)
                            return lhs.submit_order < rhs.submit_order;
                        return a.request_id < b.request_id;
                    });
                    pending_commands_dirty = false;
                }
                size_t consumed_commands = pending_begin;
                std::vector<RuntimeCommandPacket> day_commands;
                day_commands.reserve(16u);
                uint64_t admitted_submit_order = 0;
                for (size_t index = pending_begin;
                     index < pending_commands.size(); ++index) {
                    admitted_submit_order = std::max(
                        admitted_submit_order,
                        pending_commands[index].submit_order);
                }
                for (; consumed_commands < pending_commands.size(); ++consumed_commands) {
                    const RuntimeCommandPacket &command = pending_commands[consumed_commands];
                    if (command.envelope.effective_day > day) break;
                    day_commands.push_back(command);
                    RuntimeCommandReceipt receipt;
                    receipt.request_id = command.envelope.request_id;
                    receipt.producer_id = command.envelope.producer_id;
                    receipt.sequence = command.envelope.sequence;
                    receipt.effective_day = std::max(command.envelope.effective_day, day);
                    receipt.generation = _generation.load(std::memory_order_relaxed) + 1;
                    const bool domain_valid =
                        command.envelope.domain >= static_cast<uint16_t>(RuntimeDomainId::COUNTRY) &&
                        command.envelope.domain <= static_cast<uint16_t>(RuntimeDomainId::COMMIT);
                    const bool events_probe = domain_valid &&
                        static_cast<RuntimeDomainId>(command.envelope.domain) ==
                            RuntimeDomainId::EVENTS &&
                        (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW ||
                         _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE) &&
                        _events_probe_enabled.load(std::memory_order_acquire);
                    const bool modifier_shadow = domain_valid &&
                        static_cast<RuntimeDomainId>(command.envelope.domain) ==
                            RuntimeDomainId::MODIFIER &&
                        _mode.load(std::memory_order_acquire) ==
                            RuntimeSimulationMode::SHADOW &&
                        _modifier_pod_configured;
                    const bool domain_implemented = domain_valid &&
                        ((implemented_domain_mask() & runtime_domain_mask(
                            static_cast<RuntimeDomainId>(command.envelope.domain))) != 0u ||
                         events_probe || modifier_shadow);
                    const bool payload_valid =
                        command.envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_offset + command.envelope.payload_size <=
                            RUNTIME_MAX_COMMAND_PAYLOAD;
                    RuntimeModifierPodCommand modifier_command;
                    const bool modifier_payload_valid = !modifier_shadow ||
                        (decode_modifier_packet(command, modifier_command) &&
                         modifier_packet_shape_valid(modifier_command));
                    if (!payload_valid || !modifier_payload_valid) {
                        receipt.code = RuntimeReceiptCode::INVALID_PAYLOAD;
                    } else if (!domain_implemented || command.envelope.opcode == 0) {
                        // Unknown domain/opcode is a deterministic preflight
                        // rejection. It remains a receipt, never a dropped
                        // command, so callers can reconcile their request.
                        receipt.code = RuntimeReceiptCode::PREFLIGHT_REJECTED;
                    } else {
                        receipt.code = RuntimeReceiptCode::OK;
                    }
                    day_receipts.push_back(receipt);
                    push_receipt(receipt);
                }
                if (consumed_commands > 0) {
                    pending_begin = consumed_commands;
                    compact_pending_commands();
                }
                const auto environment = environment_snapshot();
                RuntimeDayPlan day_plan = build_day_plan(
                    day, speed, environment.get());
                const RuntimeDayCommit day_commit = execute_day_plan(
                    day_plan, day_commands, day_receipts,
                    admitted_submit_order);
                if (day_commit.preflight_ok == 0) {
                    if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED) {
                        break;
                    }
                    // An input/reference barrier failure must not advance the
                    // committed clock. Wait for the main thread to publish
                    // the matching reference or for a control message; this
                    // is a condition-variable wait, not a polling sleep.
                    _time_debt_days.store(std::min(100.0,
                        _time_debt_days.load(std::memory_order_relaxed) + 1.0),
                        std::memory_order_release);
                    const uint64_t trace_signal =
                        _climate_trace_signal.load(std::memory_order_acquire);
                    // Under ACTIVE Climate authority there is no trace signal
                    // to wait for: production is suppressed and the only input
                    // that can unblock the day is a fresh environment publish
                    // from the main thread. Waiting on the trace alone would
                    // park the worker forever the first time the environment
                    // is not yet available.
                    const uint64_t environment_signal =
                        _environment_generation.load(std::memory_order_acquire);
                    const uint64_t country_peer_signal =
                        _country_peer_signal.load(std::memory_order_acquire);
                    std::unique_lock<std::mutex> lock(_control_mutex);
                    _control_cv.wait(lock, [&] {
                        return _stop_requested.load(std::memory_order_acquire) ||
                            _save_requested.load(std::memory_order_acquire) ||
                            _paused.load(std::memory_order_acquire) ||
                            _climate_trace_signal.load(std::memory_order_acquire) !=
                                trace_signal ||
                            _environment_generation.load(
                                std::memory_order_acquire) != environment_signal ||
                            _country_peer_signal.load(std::memory_order_acquire) !=
                                country_peer_signal ||
                            _climate_trace.consumable_depth() != 0;
                    });
                    break;
                }
                if (day_commit.completed_stage_count == day_plan.stage_count &&
                    day_plan.stage_count == RUNTIME_DOMAIN_STAGE_COUNT &&
                    day_commit.completed_domain_mask == RUNTIME_ALL_DOMAIN_MASK &&
                    implemented_domain_mask() == RUNTIME_ALL_DOMAIN_MASK) {
                    _graph_coverage_complete.store(true, std::memory_order_release);
                    _authority_ready.store(true, std::memory_order_release);
                }
                // Per-domain grant. A domain is promoted once this day's commit
                // covers it, independently of whether the whole graph is
                // complete. Granting only the requested subset keeps a domain
                // the caller did not ask for on the main thread even when its
                // handler happens to exist.
                if (_mode.load(std::memory_order_acquire) ==
                        RuntimeSimulationMode::ACTIVE) {
                    const uint32_t wanted =
                        _requested_authority_mask.load(std::memory_order_acquire);
                    if (wanted != 0u &&
                        (day_commit.completed_domain_mask & wanted) == wanted) {
                        _authoritative_domain_mask.store(wanted,
                            std::memory_order_release);
                    }
                    // Publish the committed Climate state for main-thread
                    // write-back. Ordered before the authority grant becomes
                    // observable to a reader that has not seen a day yet: the
                    // schedule gate suppresses production the moment the grant
                    // lands, so the first suppressed tick must already have a
                    // snapshot to consume.
                    if ((wanted & runtime_domain_mask(RuntimeDomainId::CLIMATE))
                            != 0u) {
                        // Only a day Climate actually advanced may be
                        // published. The worker clock is free to run ahead of
                        // the main thread, and on those idle days the store is
                        // unchanged; handing the main thread a fresh cursor for
                        // it would make it re-apply the same state every day and
                        // report a healthy write-back cadence while Climate was
                        // in fact standing still. That is exactly how a stalled
                        // Climate stayed invisible behind writeback_days.
                        const int64_t climate_day =
                            _climate_authority.store().committed_day;
                        uint32_t slot = 0;
                        if (climate_day > _climate_writeback_last_day.load(
                                std::memory_order_relaxed) &&
                            _climate_writeback.try_begin_write(slot)) {
                            RuntimeClimateSnapshot &out =
                                _climate_writeback.write_buffer(slot);
                            out = _climate_authority.snapshot();
                            // Own monotonic sequence, not the commit
                            // generation: the commit generation is bumped later
                            // inside publish_day, so reading it here would
                            // hand out a stale cursor and the main thread would
                            // re-apply the same day.
                            out.generation = _climate_writeback_sequence.fetch_add(
                                1, std::memory_order_relaxed) + 1u;
                            // Climate's day, not the worker clock's: this is the
                            // day whose state the buffer carries.
                            out.committed_day = climate_day;
                            out.dirty_families = day_commit.dirty_families;
                            _climate_writeback.publish(slot);
                            _climate_writeback_last_day.store(
                                climate_day, std::memory_order_relaxed);
                        }
                    }
                }
                _last_day_stage_count.store(day_plan.stage_count,
                                            std::memory_order_release);
                _last_day_completed_stages.store(day_commit.completed_stage_count,
                                                 std::memory_order_release);
                _last_day_work_units.store(day_commit.work_units,
                                           std::memory_order_release);
                _committed_day.store(day, std::memory_order_release);
                _completed_days.fetch_add(1, std::memory_order_relaxed);
                publish_day(from_day, day, day_commit, day_receipts);
                // Control messages are intentionally checked at the day
                // barrier as well as the outer loop.  A long catch-up batch
                // must yield promptly to SAVE/PAUSE/STOP instead of spending
                // the whole debt budget before servicing the request.
                if (_save_requested.load(std::memory_order_acquire) ||
                    _paused.load(std::memory_order_acquire) ||
                    _stop_requested.load(std::memory_order_acquire)) {
                    break;
                }
            }
        }
        if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        }
    } catch (...) {
        set_fault("unhandled_worker_exception");
    }
}

RuntimeThreadReport NativeSimulationHost::report() const {
    RuntimeThreadReport out;
    out.state = _state.load(std::memory_order_acquire);
    out.mode = _mode.load(std::memory_order_acquire);
    out.graph_coverage_complete = _graph_coverage_complete.load(std::memory_order_acquire);
    out.authority_ready = _authority_ready.load(std::memory_order_acquire);
    out.required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    out.implemented_domain_mask = implemented_domain_mask();
    out.missing_domain_mask = out.required_domain_mask & ~out.implemented_domain_mask;
    out.requested_authority_mask =
        _requested_authority_mask.load(std::memory_order_acquire);
    out.authoritative_domain_mask =
        _authoritative_domain_mask.load(std::memory_order_acquire);
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
    out.interactive = _interactive.load(std::memory_order_acquire);
    out.paused = _paused.load(std::memory_order_acquire);
    out.speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    out.committed_day = _committed_day.load(std::memory_order_acquire);
    out.generation = _generation.load(std::memory_order_acquire);
    out.command_queue_capacity_exceeded = _command_queue_capacity_exceeded.load(std::memory_order_relaxed);
    out.receipt_queue_capacity_exceeded = _receipt_queue_capacity_exceeded.load(std::memory_order_relaxed);
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
    return out;
}

} // namespace pk
