#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "country_core_apply.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace pk {

namespace {
bool d7_read_u32(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint32_t &out);
bool d7_read_u64(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint64_t &out);

// Stable fault-injection tags for per-domain plan boundaries. Point names are
// "<tag>.plan.before" / "<tag>.plan.after" so soak harnesses can arm one shot
// faults without knowing stage indices.
const char *runtime_domain_fault_tag(RuntimeDomainId domain) noexcept {
    switch (domain) {
    case RuntimeDomainId::INPUT_CAPTURE: return "input_capture";
    case RuntimeDomainId::CLIMATE: return "climate";
    case RuntimeDomainId::COUNTRY: return "country";
    case RuntimeDomainId::TRIGGER_INPUT: return "trigger_input";
    case RuntimeDomainId::IDEOLOGY: return "ideology";
    case RuntimeDomainId::EFFECT: return "effect";
    case RuntimeDomainId::MODIFIER: return "modifier";
    case RuntimeDomainId::GAMEPLAY_EFFECT: return "gameplay_effect";
    case RuntimeDomainId::ECONOMY: return "economy";
    case RuntimeDomainId::EVENTS: return "events";
    case RuntimeDomainId::VISUAL: return "visual";
    case RuntimeDomainId::COMMIT: return "commit";
    }
    return "unknown";
}

// Scope helper for the two authority-boundary counters below.  The worker
// never exposes a partially executed day as an epoch boundary; the counters
// make that fact available to a concurrent switch request without taking a
// mutex in the hot path.
class AtomicCounterScope {
public:
    explicit AtomicCounterScope(std::atomic<uint32_t> &counter) noexcept
        : _counter(counter) {
        _counter.fetch_add(1u, std::memory_order_acq_rel);
    }
    AtomicCounterScope(const AtomicCounterScope &) = delete;
    AtomicCounterScope &operator=(const AtomicCounterScope &) = delete;
    ~AtomicCounterScope() {
        _counter.fetch_sub(1u, std::memory_order_release);
    }

private:
    std::atomic<uint32_t> &_counter;
};

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

bool economy_asset_country_prepare_transition_valid(
        const RuntimeEconomyAssetRequest &stored,
        const RuntimeEconomyAssetRequest &prepared) {
    return stored.origin_domain == static_cast<uint32_t>(RuntimeDomainId::ECONOMY) &&
        prepared.origin_domain == stored.origin_domain &&
        stored.state == RuntimeEconomyAssetState::CREATED &&
        prepared.state == RuntimeEconomyAssetState::COUNTRY_PREPARED &&
        stored.protocol_version == prepared.protocol_version &&
        stored.operation == prepared.operation &&
        stored.all_or_nothing == prepared.all_or_nothing &&
        stored.session_epoch == prepared.session_epoch &&
        stored.transaction_id == prepared.transaction_id &&
        stored.request_id == prepared.request_id &&
        stored.origin_epoch == prepared.origin_epoch &&
        stored.origin_stage == prepared.origin_stage &&
        stored.continuation_index == prepared.continuation_index &&
        stored.day == prepared.day &&
        stored.operation_sequence == prepared.operation_sequence &&
        stored.peer_generation == prepared.peer_generation &&
        stored.country_handle == prepared.country_handle &&
        (stored.country_slot < 0 || stored.country_slot == prepared.country_slot) &&
        stored.target_slot == prepared.target_slot &&
        stored.target_handle == prepared.target_handle &&
        stored.good_id == prepared.good_id &&
        stored.good_count == prepared.good_count &&
        stored.good_ids == prepared.good_ids &&
        stored.good_quantities == prepared.good_quantities &&
        stored.requested_quantity == prepared.requested_quantity &&
        stored.requested_cash == prepared.requested_cash &&
        stored.requested_goods_total == prepared.requested_goods_total;
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
        request.good_id < -1 ||
        (request.origin_domain != static_cast<uint32_t>(RuntimeDomainId::COUNTRY) &&
         request.origin_domain != static_cast<uint32_t>(RuntimeDomainId::ECONOMY))) {
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

bool economy_asset_journal_request_valid(
        const RuntimeEconomyAssetRequest &request, std::string &error) {
    if (!economy_asset_state_valid(request.state)) {
        error = "d7_transaction_journal_request_state_invalid";
        return false;
    }
    RuntimeEconomyAssetRequest admission = request;
    admission.state = request.origin_domain ==
            static_cast<uint32_t>(RuntimeDomainId::ECONOMY)
        ? RuntimeEconomyAssetState::CREATED
        : RuntimeEconomyAssetState::COUNTRY_PREPARED;
    return economy_asset_request_shape_valid(admission, error);
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
    _fault_injection_armed.store(false, std::memory_order_relaxed);
    _fault_injection_trip_count.store(0, std::memory_order_relaxed);
    for (auto &character : _fault_injection_point)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_reason)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_blocker)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_audit_before)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_audit_after)
        character.store('\0', std::memory_order_relaxed);
    for (auto &sample : _economy_authority_switch_latency_samples)
        sample.store(0, std::memory_order_relaxed);
    for (auto &sample : _economy_authority_switch_command_latency_samples)
        sample.store(0, std::memory_order_relaxed);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    for (auto &character : _modifier_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _effect_pod_ready.store(false, std::memory_order_release);
    _effect_pod_plan_ms.store(0.0, std::memory_order_release);
    _effect_pod_replay_ms.store(0.0, std::memory_order_release);
    _effect_pod_state_hash.store(0, std::memory_order_release);
    _effect_pod_snapshot_generation.store(0, std::memory_order_release);
    _effect_pod_ack_count.store(0, std::memory_order_release);
    _effect_pod_intent_count.store(0, std::memory_order_release);
    _effect_day_stage_ok = false;
    _effect_day_modifier_intents.clear();
    _effect_day_intents.clear();
    for (auto &character : _effect_pod_fallback_reason)
        character.store('\0', std::memory_order_relaxed);
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
    // The previous worker is fully reaped here, so reset the continuation
    // machine before publishing STARTING.  This avoids touching its
    // non-atomic bookkeeping from request_stop while a worker is still live.
    _stage_ops_day_index = -1;
    _stage_ops_day_input_generation = 0;
    _stage_ops_day_phase = StageOpsDayPhase::Done;
    _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Done),
                                      std::memory_order_release);
    if (mode == RuntimeSimulationMode::OFF) {
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _authority_ready.store(false, std::memory_order_release);
        _requested_authority_mask.store(0, std::memory_order_release);
        _authoritative_domain_mask.store(0, std::memory_order_release);
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
    _economy_authority_fault_paused.store(false, std::memory_order_release);
    _authority_ready.store(false, std::memory_order_release);
    // The request is recorded now; the grant is published only after a barrier
    // proves the worker actually ran those domains (see publish_day).
    _requested_authority_mask.store(wanted, std::memory_order_release);
    _authoritative_domain_mask.store(0, std::memory_order_release);
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
        if (!_economy_production_runtime->apply_ecp2_authority(
                restored_ecp2, ecp2_apply_error)) {
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
        _country_economy_asset_request_queue.clear();
        _country_economy_asset_requests.clear();
        _country_economy_asset_results.clear();
        _country_economy_asset_terminal_results.clear();
        _country_economy_asset_dispatched.clear();
        _country_economy_asset_committed.clear();
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
        _authoritative_domain_mask.store(wanted & implemented_domain_mask(),
                                         std::memory_order_release);
    }
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
    probe->set_fault("self_test_worker_fault");
    if (probe->state() != RuntimeWorkerState::FAULTED ||
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

void NativeSimulationHost::attach_economy_production_runtime(
        NativeEconomyRuntime *rt) noexcept {
    if (rt != nullptr &&
        economy_execution_mode() == EconomyExecutionMode::LEGACY_ONLY) {
        // LEGACY_ONLY forbids worker production attach; keep sync authority.
        rt = nullptr;
    }
    _economy_production_runtime = rt;
    if (rt != nullptr) {
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
        input.sample_day = day;
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

void NativeSimulationHost::request_stop() {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED) return;
    _stage_ops_day_phase_atomic.store(static_cast<uint8_t>(StageOpsDayPhase::Done), std::memory_order_release);
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
    _worker_timing.pause(paused);
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

bool NativeSimulationHost::has_pending_climate_input() const {
    // 仅 ACTIVE Climate 有"未消费输入 = 有活可干"语义；SHADOW/OFF 恒 false，
    // 否则 begin_save 会在 ring/latest 未清时永久等（save_poll_timeout）。
    if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::ACTIVE ||
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) == 0u) {
        return false;
    }
    return _environment_ring.size() > 0u;
}

bool NativeSimulationHost::environment_ring_full() const {
    return !_environment_ring.has_capacity();
}

size_t NativeSimulationHost::environment_ring_pending() const {
    return _environment_ring.size();
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
    std::lock_guard<std::mutex> publish_lock(_environment_publish_mutex);
    const auto previous = _environment_ring.latest();
    if (previous == nullptr) {
        // Fall back to legacy single-slot pointer for the first publish of a
        // session that restored without going through the ring.
        const auto legacy = std::atomic_load_explicit(
            &_environment_snapshot, std::memory_order_acquire);
        if (legacy != nullptr && snapshot.generation <= legacy->generation) {
            _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
            error = "runtime_input_stale";
            return false;
        }
    } else if (snapshot.generation <= previous->generation) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_stale";
        return false;
    }
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
    const bool climate_authoritative =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    if (!climate_authoritative && !_climate_trace.push(snapshot)) {
        error = "climate_trace_capacity_exceeded";
        return false;
    }
    auto copy = std::make_shared<RuntimeEnvironmentSnapshot>(snapshot);
    bool dropped = false;
    if (climate_authoritative) {
        // ACTIVE：满环拒绝，主线程 wait_climate_consumed(0) 等空位 —— 不静默丢天。
        if (!_environment_ring.has_capacity() || !_environment_ring.try_push(copy)) {
            error = "climate_environment_pending";
            return false;
        }
    } else {
        // SHADOW：允许 force 覆盖最旧未消费输入，计入 dropped（ring 溢出语义）。
        if (!_environment_ring.force_push(copy, dropped)) {
            error = "climate_environment_ring_push_failed";
            return false;
        }
        if (dropped) {
            _environment_dropped_days.fetch_add(1, std::memory_order_relaxed);
            _environment_superseded_days.fetch_add(1, std::memory_order_relaxed);
        }
    }
    std::atomic_store_explicit(&_environment_snapshot,
        std::shared_ptr<const RuntimeEnvironmentSnapshot>(copy),
        std::memory_order_release);
    _environment_published_days.fetch_add(1, std::memory_order_relaxed);
    _environment_generation.store(snapshot.generation, std::memory_order_release);
    _environment_day.store(snapshot.day, std::memory_order_release);
    _environment_cell_count.store(snapshot.cell_count, std::memory_order_release);
    _environment_topology_validated.store(snapshot.topology_validated,
                                           std::memory_order_release);
    _control_cv.notify_all();
    _climate_wait_cv.notify_all();
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

bool NativeSimulationHost::wait_climate_consumed(
        uint64_t after_generation, int64_t timeout_ms,
        uint64_t &consumed_generation, std::string &error) {
    error.clear();
    const uint64_t start_us = now_us();
    const uint64_t budget_us = timeout_ms < 0
        ? 0u : static_cast<uint64_t>(timeout_ms) * 1000u;
    // 每次返回都记等待统计：soak / perf 报告用 last/p95/max 判断背压是否打满
    // 主线程。等待总时长是"worker 没跟上"的直接证据，不是估算。
    const auto finish = [&](bool ok, const char *reason) {
        const uint64_t waited_ms = (now_us() - start_us) / 1000u;
        _climate_wait_last_ms.store(waited_ms, std::memory_order_relaxed);
        _climate_wait_total_ms.fetch_add(waited_ms, std::memory_order_relaxed);
        uint64_t previous_max =
            _climate_wait_max_ms.load(std::memory_order_relaxed);
        while (waited_ms > previous_max &&
               !_climate_wait_max_ms.compare_exchange_weak(
                   previous_max, waited_ms, std::memory_order_relaxed)) {
        }
        if (!ok && reason != nullptr) error = reason;
        return ok;
    };
    std::unique_lock<std::mutex> lock(_control_mutex);
    while (true) {
        consumed_generation =
            _climate_consumed_generation.load(std::memory_order_acquire);
        // after_generation == 0：等 ring 有空位（流水线发布）。
        // after_generation  > 0：等该代次已被 worker 评估（serial_wait / soak）。
        const bool ready = after_generation == 0
            ? _environment_ring.has_capacity()
            : consumed_generation >= after_generation;
        if (ready) {
            return finish(true, nullptr);
        }
        const RuntimeWorkerState state = _state.load(std::memory_order_acquire);
        if (state == RuntimeWorkerState::FAULTED) {
            return finish(false, "climate_wait_worker_faulted");
        }
        if (state == RuntimeWorkerState::STOPPING ||
            state == RuntimeWorkerState::STOPPED) {
            return finish(false, "climate_wait_worker_stopped");
        }
        if (_stop_requested.load(std::memory_order_acquire)) {
            return finish(false, "climate_wait_stop_requested");
        }
        // 撤销 Climate 权威 = 调用方不再要求这个域。grant 之前 mask 仍可能是
        // 0，所以判据是 requested mask，而不是 authoritative mask。
        if ((_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::CLIMATE)) == 0u) {
            return finish(false, "climate_wait_authority_revoked");
        }
        const uint64_t elapsed_us = now_us() - start_us;
        if (timeout_ms >= 0) {
            if (elapsed_us >= budget_us) {
                return finish(false, "climate_wait_timeout_slice");
            }
            const uint64_t remaining_us = budget_us - elapsed_us;
            _climate_wait_cv.wait_for(lock,
                                      std::chrono::microseconds(remaining_us));
        } else {
            // "无限等"用 100ms 长片等待实现：真正唤醒靠 worker 的
            // _climate_wait_cv.notify_all，长片只保证等待方周期性重查
            // FAULTED/STOPPED/撤销这些终止条件 —— 故障路径通知的是 _control_cv，
            // 漏掉一次 notify 就会让主线程永远挂着。10 次/秒唤醒不是忙等。
            _climate_wait_cv.wait_for(lock, std::chrono::milliseconds(100));
        }
    }
}

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
    _country_worker_country_generation = committed_copy->generation;
    _country_worker_day = committed_copy->committed_day;
    // A peer-rejected semantic day is still a committed Country state. It
    // follows this helper instead of the ordinary commit path, but must cross
    // the same parity boundary or rejected days silently erase D11 evidence.
    record_country_parity_locked(*committed_copy);
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
    _country_economy_asset_dispatched.clear();
    _country_economy_asset_committed.clear();
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

namespace {

void store_atomic_chars(std::array<std::atomic<char>, 64> &dst, const char *src) {
    size_t i = 0;
    if (src != nullptr) {
        for (; i + 1u < dst.size() && src[i] != '\0'; ++i)
            dst[i].store(src[i], std::memory_order_relaxed);
    }
    for (; i < dst.size(); ++i)
        dst[i].store('\0', std::memory_order_relaxed);
}

void store_atomic_chars48(std::array<std::atomic<char>, 48> &dst, const char *src) {
    size_t i = 0;
    if (src != nullptr) {
        for (; i + 1u < dst.size() && src[i] != '\0'; ++i)
            dst[i].store(src[i], std::memory_order_relaxed);
    }
    for (; i < dst.size(); ++i)
        dst[i].store('\0', std::memory_order_relaxed);
}

void load_atomic_chars(const std::array<std::atomic<char>, 64> &src, char *dst, size_t cap) {
    size_t i = 0;
    for (; i + 1u < cap && i < src.size(); ++i) {
        dst[i] = src[i].load(std::memory_order_relaxed);
        if (dst[i] == '\0') return;
    }
    if (cap > 0) dst[std::min(i, cap - 1u)] = '\0';
}

void load_atomic_chars48(const std::array<std::atomic<char>, 48> &src, char *dst, size_t cap) {
    size_t i = 0;
    for (; i + 1u < cap && i < src.size(); ++i) {
        dst[i] = src[i].load(std::memory_order_relaxed);
        if (dst[i] == '\0') return;
    }
    if (cap > 0) dst[std::min(i, cap - 1u)] = '\0';
}

} // namespace

namespace {

constexpr uint32_t D7_TRANSACTION_MAGIC = 0x31543744u; // "D7T1"
constexpr uint32_t D7_TRANSACTION_VERSION = 2u;

void d7_append_u8(std::vector<uint8_t> &out, uint8_t value) {
    out.push_back(value);
}

void d7_append_u16(std::vector<uint8_t> &out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8u) & 0xffu));
}

void d7_append_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (uint32_t i = 0; i < 4u; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}

void d7_append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8u; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}

void d7_append_i32(std::vector<uint8_t> &out, int32_t value) {
    d7_append_u32(out, static_cast<uint32_t>(value));
}

void d7_append_i64(std::vector<uint8_t> &out, int64_t value) {
    d7_append_u64(out, static_cast<uint64_t>(value));
}

void d7_append_bytes(std::vector<uint8_t> &out, const void *data, size_t size) {
    const size_t offset = out.size();
    out.resize(offset + size);
    if (size > 0) std::memcpy(out.data() + offset, data, size);
}

bool d7_read_u8(const uint8_t *bytes, size_t size, size_t &cursor,
                uint8_t &out) {
    if (cursor >= size) return false;
    out = bytes[cursor++];
    return true;
}

bool d7_read_u16(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint16_t &out) {
    if (cursor > size || size - cursor < 2u) return false;
    out = static_cast<uint16_t>(bytes[cursor]) |
        static_cast<uint16_t>(static_cast<uint16_t>(bytes[cursor + 1u]) << 8u);
    cursor += 2u;
    return true;
}

bool d7_read_u32(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint32_t &out) {
    if (cursor > size || size - cursor < 4u) return false;
    out = static_cast<uint32_t>(bytes[cursor]) |
        (static_cast<uint32_t>(bytes[cursor + 1u]) << 8u) |
        (static_cast<uint32_t>(bytes[cursor + 2u]) << 16u) |
        (static_cast<uint32_t>(bytes[cursor + 3u]) << 24u);
    cursor += 4u;
    return true;
}

bool d7_read_u64(const uint8_t *bytes, size_t size, size_t &cursor,
                 uint64_t &out) {
    if (cursor > size || size - cursor < 8u) return false;
    out = 0;
    for (uint32_t i = 0; i < 8u; ++i)
        out |= static_cast<uint64_t>(bytes[cursor + i]) << (i * 8u);
    cursor += 8u;
    return true;
}

bool d7_read_i32(const uint8_t *bytes, size_t size, size_t &cursor,
                 int32_t &out) {
    uint32_t raw = 0;
    if (!d7_read_u32(bytes, size, cursor, raw)) return false;
    std::memcpy(&out, &raw, sizeof(out));
    return true;
}

bool d7_read_i64(const uint8_t *bytes, size_t size, size_t &cursor,
                 int64_t &out) {
    uint64_t raw = 0;
    if (!d7_read_u64(bytes, size, cursor, raw)) return false;
    std::memcpy(&out, &raw, sizeof(out));
    return true;
}

bool d7_read_bytes(const uint8_t *bytes, size_t size, size_t &cursor,
                   void *out, size_t count) {
    if (cursor > size || count > size - cursor) return false;
    if (count > 0) std::memcpy(out, bytes + cursor, count);
    cursor += count;
    return true;
}

void d7_append_request(std::vector<uint8_t> &out,
                       const RuntimeEconomyAssetRequest &request) {
    d7_append_u32(out, request.protocol_version);
    d7_append_u16(out, static_cast<uint16_t>(request.operation));
    d7_append_u8(out, static_cast<uint8_t>(request.state));
    d7_append_u8(out, request.all_or_nothing);
    d7_append_u16(out, 0);
    d7_append_u64(out, request.session_epoch);
    d7_append_u64(out, request.transaction_id);
    d7_append_u64(out, request.request_id);
    d7_append_u32(out, request.origin_domain);
    d7_append_i64(out, request.origin_epoch);
    d7_append_i32(out, request.origin_stage);
    d7_append_u32(out, request.continuation_index);
    d7_append_i64(out, request.day);
    d7_append_u64(out, request.operation_sequence);
    d7_append_u64(out, request.country_generation);
    d7_append_u64(out, request.peer_generation);
    d7_append_u64(out, request.country_handle);
    d7_append_i32(out, request.country_slot);
    d7_append_i32(out, request.target_slot);
    d7_append_u64(out, request.target_handle);
    d7_append_i32(out, request.good_id);
    d7_append_u32(out, request.good_count);
    for (int32_t value : request.good_ids) d7_append_i32(out, value);
    for (int64_t value : request.good_quantities) d7_append_i64(out, value);
    d7_append_i64(out, request.requested_quantity);
    d7_append_i64(out, request.prepared_quantity);
    d7_append_i64(out, request.requested_cash);
    d7_append_i64(out, request.reserved_cash);
    d7_append_i64(out, request.requested_goods_total);
    d7_append_i64(out, request.reserved_goods_total);
}

bool d7_read_request(const uint8_t *bytes, size_t size, size_t &cursor,
                     RuntimeEconomyAssetRequest &request) {
    uint16_t operation = 0;
    uint8_t state = 0;
    uint8_t all_or_nothing = 0;
    uint16_t reserved = 0;
    if (!d7_read_u32(bytes, size, cursor, request.protocol_version) ||
        !d7_read_u16(bytes, size, cursor, operation) ||
        !d7_read_u8(bytes, size, cursor, state) ||
        !d7_read_u8(bytes, size, cursor, all_or_nothing) ||
        !d7_read_u16(bytes, size, cursor, reserved) ||
        !d7_read_u64(bytes, size, cursor, request.session_epoch) ||
        !d7_read_u64(bytes, size, cursor, request.transaction_id) ||
        !d7_read_u64(bytes, size, cursor, request.request_id) ||
        !d7_read_u32(bytes, size, cursor, request.origin_domain) ||
        !d7_read_i64(bytes, size, cursor, request.origin_epoch) ||
        !d7_read_i32(bytes, size, cursor, request.origin_stage) ||
        !d7_read_u32(bytes, size, cursor, request.continuation_index) ||
        !d7_read_i64(bytes, size, cursor, request.day) ||
        !d7_read_u64(bytes, size, cursor, request.operation_sequence) ||
        !d7_read_u64(bytes, size, cursor, request.country_generation) ||
        !d7_read_u64(bytes, size, cursor, request.peer_generation) ||
        !d7_read_u64(bytes, size, cursor, request.country_handle) ||
        !d7_read_i32(bytes, size, cursor, request.country_slot) ||
        !d7_read_i32(bytes, size, cursor, request.target_slot) ||
        !d7_read_u64(bytes, size, cursor, request.target_handle) ||
        !d7_read_i32(bytes, size, cursor, request.good_id) ||
        !d7_read_u32(bytes, size, cursor, request.good_count)) return false;
    request.operation = static_cast<RuntimeEconomyAssetOperation>(operation);
    request.state = static_cast<RuntimeEconomyAssetState>(state);
    request.all_or_nothing = all_or_nothing;
    for (int32_t &value : request.good_ids) {
        if (!d7_read_i32(bytes, size, cursor, value)) return false;
    }
    for (int64_t &value : request.good_quantities) {
        if (!d7_read_i64(bytes, size, cursor, value)) return false;
    }
    return d7_read_i64(bytes, size, cursor, request.requested_quantity) &&
        d7_read_i64(bytes, size, cursor, request.prepared_quantity) &&
        d7_read_i64(bytes, size, cursor, request.requested_cash) &&
        d7_read_i64(bytes, size, cursor, request.reserved_cash) &&
        d7_read_i64(bytes, size, cursor, request.requested_goods_total) &&
        d7_read_i64(bytes, size, cursor, request.reserved_goods_total);
}

void d7_append_result(std::vector<uint8_t> &out,
                      const RuntimeEconomyAssetResult &result) {
    d7_append_u32(out, result.protocol_version);
    d7_append_u8(out, static_cast<uint8_t>(result.code));
    d7_append_u8(out, static_cast<uint8_t>(result.state));
    d7_append_u8(out, result.accepted);
    d7_append_u8(out, 0);
    d7_append_u64(out, result.session_epoch);
    d7_append_u64(out, result.transaction_id);
    d7_append_u64(out, result.request_id);
    d7_append_u16(out, static_cast<uint16_t>(result.operation));
    d7_append_u16(out, 0);
    d7_append_u32(out, result.continuation_index);
    d7_append_i64(out, result.day);
    d7_append_u64(out, result.country_generation);
    d7_append_u64(out, result.peer_generation);
    d7_append_u64(out, result.committed_peer_generation);
    d7_append_i32(out, result.country_slot);
    d7_append_i32(out, result.target_slot);
    d7_append_i64(out, result.committed_quantity);
    d7_append_i64(out, result.committed_cash);
    d7_append_i64(out, result.committed_goods_total);
    d7_append_bytes(out, result.reason.data(), result.reason.size());
}

bool d7_read_result(const uint8_t *bytes, size_t size, size_t &cursor,
                    RuntimeEconomyAssetResult &result) {
    uint8_t code = 0;
    uint8_t state = 0;
    uint8_t reserved0 = 0;
    uint8_t reserved1 = 0;
    uint16_t operation = 0;
    uint16_t reserved2 = 0;
    if (!d7_read_u32(bytes, size, cursor, result.protocol_version) ||
        !d7_read_u8(bytes, size, cursor, code) ||
        !d7_read_u8(bytes, size, cursor, state) ||
        !d7_read_u8(bytes, size, cursor, result.accepted) ||
        !d7_read_u8(bytes, size, cursor, reserved0) ||
        !d7_read_u64(bytes, size, cursor, result.session_epoch) ||
        !d7_read_u64(bytes, size, cursor, result.transaction_id) ||
        !d7_read_u64(bytes, size, cursor, result.request_id) ||
        !d7_read_u16(bytes, size, cursor, operation) ||
        !d7_read_u16(bytes, size, cursor, reserved2) ||
        !d7_read_u32(bytes, size, cursor, result.continuation_index) ||
        !d7_read_i64(bytes, size, cursor, result.day) ||
        !d7_read_u64(bytes, size, cursor, result.country_generation) ||
        !d7_read_u64(bytes, size, cursor, result.peer_generation) ||
        !d7_read_u64(bytes, size, cursor, result.committed_peer_generation) ||
        !d7_read_i32(bytes, size, cursor, result.country_slot) ||
        !d7_read_i32(bytes, size, cursor, result.target_slot) ||
        !d7_read_i64(bytes, size, cursor, result.committed_quantity) ||
        !d7_read_i64(bytes, size, cursor, result.committed_cash) ||
        !d7_read_i64(bytes, size, cursor, result.committed_goods_total) ||
        !d7_read_bytes(bytes, size, cursor, result.reason.data(),
                       result.reason.size())) return false;
    result.code = static_cast<RuntimeEconomyAssetResultCode>(code);
    result.state = static_cast<RuntimeEconomyAssetState>(state);
    result.operation = static_cast<RuntimeEconomyAssetOperation>(operation);
    return true;
}

} // namespace

bool NativeSimulationHost::serialize_country_economy_asset_journal(
        std::vector<uint8_t> &out, std::string &error) const {
    out.clear();
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    if (_country_economy_asset_requests.empty() &&
        _country_economy_asset_request_queue.empty() &&
        _economy_origin_asset_queue.empty()) {
        return true;
    }
    if (_country_economy_asset_requests.size() >
            RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY ||
        _country_economy_asset_request_queue.size() >
            RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY ||
        _economy_origin_asset_queue.size() >
            RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
        error = "d7_transaction_journal_capacity_exceeded";
        return false;
    }

    d7_append_u32(out, D7_TRANSACTION_MAGIC);
    d7_append_u32(out, D7_TRANSACTION_VERSION);
    d7_append_u64(out, _country_worker_session_epoch);
    d7_append_u32(out, _country_economy_asset_protocol.queued_requests);
    d7_append_u32(out, _country_economy_asset_protocol.pending_requests);
    d7_append_u32(out, _country_economy_asset_protocol.terminal_requests);
    d7_append_u32(out, _country_economy_asset_protocol.rejected_results);
    d7_append_u32(out, _country_economy_asset_protocol.faulted_transactions);
    d7_append_u32(out, _country_economy_asset_protocol.recovered_transactions);
    d7_append_u32(out, _country_economy_asset_protocol.duplicate_messages);
    d7_append_u64(out, _country_economy_asset_protocol.last_transaction_id);
    d7_append_u64(out, _country_economy_asset_protocol.last_request_id);
    d7_append_u16(out, static_cast<uint16_t>(
        _country_economy_asset_protocol.last_error));
    d7_append_u16(out, 0);
    d7_append_bytes(out, _country_economy_asset_protocol.last_reason.data(),
                    _country_economy_asset_protocol.last_reason.size());

    std::vector<uint64_t> request_ids;
    request_ids.reserve(_country_economy_asset_requests.size());
    for (const auto &entry : _country_economy_asset_requests)
        request_ids.push_back(entry.first);
    std::sort(request_ids.begin(), request_ids.end());
    d7_append_u32(out, static_cast<uint32_t>(request_ids.size()));
    for (const uint64_t request_id : request_ids) {
        const auto request_it = _country_economy_asset_requests.find(request_id);
        if (request_it == _country_economy_asset_requests.end()) {
            error = "d7_transaction_journal_request_missing";
            return false;
        }
        d7_append_u64(out, request_id);
        d7_append_request(out, request_it->second);
        uint8_t flags = 0;
        const auto result_it = _country_economy_asset_results.find(request_id);
        if (result_it != _country_economy_asset_results.end()) flags |= 1u;
        if (_country_economy_asset_terminal_results.find(request_id) !=
                _country_economy_asset_terminal_results.end()) flags |= 2u;
        if (_country_economy_asset_committed.find(request_id) !=
                _country_economy_asset_committed.end()) flags |= 4u;
        if (_country_economy_asset_dispatched.find(request_id) !=
                _country_economy_asset_dispatched.end()) flags |= 32u;
        if (std::find(_country_economy_asset_request_queue.begin(),
                      _country_economy_asset_request_queue.end(), request_id) !=
                _country_economy_asset_request_queue.end()) flags |= 8u;
        if (std::find(_economy_origin_asset_queue.begin(),
                      _economy_origin_asset_queue.end(), request_id) !=
                _economy_origin_asset_queue.end()) flags |= 16u;
        d7_append_u8(out, flags);
        d7_append_u8(out, 0);
        d7_append_u16(out, 0);
        if ((flags & 1u) != 0) d7_append_result(out, result_it->second);
    }

    d7_append_u32(out, static_cast<uint32_t>(
        _country_economy_asset_request_queue.size()));
    for (const uint64_t id : _country_economy_asset_request_queue)
        d7_append_u64(out, id);
    d7_append_u32(out, static_cast<uint32_t>(_economy_origin_asset_queue.size()));
    for (const uint64_t id : _economy_origin_asset_queue)
        d7_append_u64(out, id);

    std::vector<uint64_t> committed_ids(_country_economy_asset_committed.begin(),
                                        _country_economy_asset_committed.end());
    std::sort(committed_ids.begin(), committed_ids.end());
    if (committed_ids.size() > RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
        error = "d7_transaction_journal_committed_capacity_exceeded";
        return false;
    }
    d7_append_u32(out, static_cast<uint32_t>(committed_ids.size()));
    for (const uint64_t id : committed_ids) d7_append_u64(out, id);
    return true;
}

bool NativeSimulationHost::restore_country_economy_asset_journal(
        const uint8_t *bytes, size_t size, std::string &error) {
    error.clear();
    if (bytes == nullptr || size == 0) {
        error = "d7_transaction_journal_empty";
        return false;
    }
    size_t cursor = 0;
    uint32_t magic = 0;
    uint32_t version = 0;
    uint64_t serialized_session = 0;
    if (!d7_read_u32(bytes, size, cursor, magic) ||
        !d7_read_u32(bytes, size, cursor, version) ||
        magic != D7_TRANSACTION_MAGIC || version != D7_TRANSACTION_VERSION ||
        !d7_read_u64(bytes, size, cursor, serialized_session) ||
        serialized_session == 0) {
        error = "d7_transaction_journal_header_invalid";
        return false;
    }
    RuntimeEconomyAssetProtocolStatus protocol;
    uint16_t last_error = 0;
    uint16_t reserved = 0;
    if (!d7_read_u32(bytes, size, cursor, protocol.queued_requests) ||
        !d7_read_u32(bytes, size, cursor, protocol.pending_requests) ||
        !d7_read_u32(bytes, size, cursor, protocol.terminal_requests) ||
        !d7_read_u32(bytes, size, cursor, protocol.rejected_results) ||
        !d7_read_u32(bytes, size, cursor, protocol.faulted_transactions) ||
        !d7_read_u32(bytes, size, cursor, protocol.recovered_transactions) ||
        !d7_read_u32(bytes, size, cursor, protocol.duplicate_messages) ||
        !d7_read_u64(bytes, size, cursor, protocol.last_transaction_id) ||
        !d7_read_u64(bytes, size, cursor, protocol.last_request_id) ||
        !d7_read_u16(bytes, size, cursor, last_error) ||
        !d7_read_u16(bytes, size, cursor, reserved) ||
        !d7_read_bytes(bytes, size, cursor, protocol.last_reason.data(),
                       protocol.last_reason.size())) {
        error = "d7_transaction_journal_status_invalid";
        return false;
    }
    if (reserved != 0 || last_error > static_cast<uint16_t>(
            RuntimeEconomyAssetProtocolError::CAPACITY_EXCEEDED)) {
        error = "d7_transaction_journal_status_invalid";
        return false;
    }
    protocol.last_error = static_cast<RuntimeEconomyAssetProtocolError>(last_error);

    std::unordered_map<uint64_t, RuntimeEconomyAssetRequest> requests;
    std::unordered_map<uint64_t, RuntimeEconomyAssetResult> results;
    std::unordered_map<uint64_t, RuntimeEconomyAssetResult> terminals;
    std::unordered_set<uint64_t> committed;
    std::unordered_set<uint64_t> dispatched;
    std::unordered_set<uint64_t> flagged_request_queue;
    std::unordered_set<uint64_t> flagged_origin_queue;
    std::deque<uint64_t> request_queue;
    std::deque<uint64_t> origin_queue;
    uint32_t entry_count = 0;
    if (!d7_read_u32(bytes, size, cursor, entry_count) ||
        entry_count > RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
        error = "d7_transaction_journal_entry_count_invalid";
        return false;
    }
    requests.reserve(entry_count);
    for (uint32_t i = 0; i < entry_count; ++i) {
        uint64_t request_id = 0;
        RuntimeEconomyAssetRequest request;
        uint8_t flags = 0;
        uint8_t reserved8 = 0;
        uint16_t reserved16 = 0;
        if (!d7_read_u64(bytes, size, cursor, request_id) ||
            !d7_read_request(bytes, size, cursor, request) ||
            !d7_read_u8(bytes, size, cursor, flags) ||
            !d7_read_u8(bytes, size, cursor, reserved8) ||
            !d7_read_u16(bytes, size, cursor, reserved16) ||
            request_id == 0 || request.request_id != request_id ||
            reserved8 != 0 || reserved16 != 0 || (flags & ~uint8_t{63}) != 0 ||
            request.session_epoch != serialized_session ||
            !requests.emplace(request_id, request).second) {
            error = "d7_transaction_journal_request_invalid";
            return false;
        }
        std::string shape_error;
        if (!economy_asset_journal_request_valid(request, shape_error)) {
            error = shape_error.empty() ? "d7_transaction_journal_request_shape_invalid" : shape_error;
            return false;
        }
        if ((flags & 1u) != 0) {
            RuntimeEconomyAssetResult result;
            if (!d7_read_result(bytes, size, cursor, result) ||
                result.request_id != request_id ||
                result.transaction_id != request.transaction_id ||
                result.operation != request.operation ||
                !economy_asset_result_code_state_valid(result)) {
                error = "d7_transaction_journal_result_invalid";
                return false;
            }
            if (result.session_epoch != request.session_epoch ||
                result.continuation_index != request.continuation_index ||
                result.day != request.day ||
                result.country_generation != request.country_generation ||
                result.peer_generation != request.peer_generation ||
                result.country_slot != request.country_slot ||
                result.target_slot != request.target_slot) {
                error = "d7_transaction_journal_result_identity_invalid";
                return false;
            }
            results.emplace(request_id, result);
            if ((flags & 2u) != 0) {
                if (!economy_asset_result_terminal(result)) {
                    error = "d7_transaction_journal_terminal_state_invalid";
                    return false;
                }
                terminals.emplace(request_id, result);
            }
        } else if ((flags & 2u) != 0) {
            error = "d7_transaction_journal_terminal_without_result";
            return false;
        }
        if ((flags & 4u) != 0) committed.insert(request_id);
        if ((flags & 8u) != 0) flagged_request_queue.insert(request_id);
        if ((flags & 16u) != 0) flagged_origin_queue.insert(request_id);
        if ((flags & 32u) != 0) dispatched.insert(request_id);
    }
    auto read_id_queue = [&](std::deque<uint64_t> &queue,
                             const char *invalid_error) {
        uint32_t count = 0;
        if (!d7_read_u32(bytes, size, cursor, count) ||
            count > RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
            error = invalid_error;
            return false;
        }
        for (uint32_t i = 0; i < count; ++i) {
            uint64_t id = 0;
            if (!d7_read_u64(bytes, size, cursor, id) ||
                requests.find(id) == requests.end()) {
                error = invalid_error;
                return false;
            }
            queue.push_back(id);
        }
        return true;
    };
    if (!read_id_queue(request_queue, "d7_transaction_journal_request_queue_invalid") ||
        !read_id_queue(origin_queue, "d7_transaction_journal_origin_queue_invalid"))
        return false;
    std::unordered_set<uint64_t> request_queue_ids;
    std::unordered_set<uint64_t> origin_queue_ids;
    for (const uint64_t id : request_queue) {
        if (!request_queue_ids.insert(id).second ||
            requests.at(id).origin_domain !=
                static_cast<uint32_t>(RuntimeDomainId::COUNTRY)) {
            error = "d7_transaction_journal_request_queue_invalid";
            return false;
        }
    }
    for (const uint64_t id : origin_queue) {
        if (!origin_queue_ids.insert(id).second ||
            requests.at(id).origin_domain !=
                static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
            error = "d7_transaction_journal_origin_queue_invalid";
            return false;
        }
    }
    for (const uint64_t id : request_queue_ids) {
        if (origin_queue_ids.find(id) != origin_queue_ids.end() ||
            dispatched.find(id) != dispatched.end() ||
            terminals.find(id) != terminals.end()) {
            error = "d7_transaction_journal_queue_state_invalid";
            return false;
        }
    }
    for (const uint64_t id : origin_queue_ids) {
        if (terminals.find(id) != terminals.end()) {
            error = "d7_transaction_journal_queue_state_invalid";
            return false;
        }
    }
    if (flagged_request_queue != request_queue_ids ||
        flagged_origin_queue != origin_queue_ids) {
        error = "d7_transaction_journal_queue_flags_invalid";
        return false;
    }
    uint32_t committed_count = 0;
    if (!d7_read_u32(bytes, size, cursor, committed_count) ||
        committed_count > RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
        error = "d7_transaction_journal_committed_invalid";
        return false;
    }
    for (uint32_t i = 0; i < committed_count; ++i) {
        uint64_t id = 0;
        if (!d7_read_u64(bytes, size, cursor, id) ||
            requests.find(id) == requests.end()) {
            error = "d7_transaction_journal_committed_invalid";
            return false;
        }
        committed.insert(id);
    }
    for (const uint64_t id : committed) {
        if (terminals.find(id) == terminals.end()) {
            error = "d7_transaction_journal_committed_without_terminal";
            return false;
        }
    }

    // A dispatched request has crossed the old worker/session boundary, but
    // without a terminal result it is still live work. Rebind it to the new
    // session and put it back on the appropriate deterministic queue. Keeping
    // the old dispatched bit here would strand the transaction permanently:
    // publish/poll deliberately avoids enqueueing ids marked as dispatched.
    for (const auto &entry : requests) {
        const uint64_t request_id = entry.first;
        const RuntimeEconomyAssetRequest &request = entry.second;
        if (terminals.find(request_id) != terminals.end()) continue;
        if (request.origin_domain ==
                static_cast<uint32_t>(RuntimeDomainId::COUNTRY)) {
            if (request_queue_ids.find(request_id) == request_queue_ids.end()) {
                request_queue.push_back(request_id);
                request_queue_ids.insert(request_id);
            }
        } else if (request.origin_domain ==
                   static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
            if (origin_queue_ids.find(request_id) == origin_queue_ids.end()) {
                origin_queue.push_back(request_id);
                origin_queue_ids.insert(request_id);
            }
        } else {
            error = "d7_transaction_journal_origin_domain_invalid";
            return false;
        }
        dispatched.erase(request_id);
    }

    const auto request_order = [&requests](uint64_t lhs, uint64_t rhs) {
        const auto &a = requests.at(lhs);
        const auto &b = requests.at(rhs);
        if (a.day != b.day) return a.day < b.day;
        if (a.operation_sequence != b.operation_sequence)
            return a.operation_sequence < b.operation_sequence;
        if (a.continuation_index != b.continuation_index)
            return a.continuation_index < b.continuation_index;
        return lhs < rhs;
    };
    std::sort(request_queue.begin(), request_queue.end(), request_order);
    std::sort(origin_queue.begin(), origin_queue.end(), request_order);
    flagged_request_queue.clear();
    flagged_origin_queue.clear();
    for (const uint64_t id : request_queue)
        flagged_request_queue.insert(id);
    for (const uint64_t id : origin_queue)
        flagged_origin_queue.insert(id);

    if (cursor != size) {
        error = "d7_transaction_journal_trailing_bytes";
        return false;
    }

    const uint64_t current_session = _country_worker_session_epoch == 0
        ? 1u : _country_worker_session_epoch;
    uint64_t max_request_id = 0;
    for (auto &entry : requests) {
        entry.second.session_epoch = current_session;
        max_request_id = std::max(max_request_id, entry.first);
    }
    for (auto &entry : results) {
        entry.second.session_epoch = current_session;
        max_request_id = std::max(max_request_id, entry.first);
    }
    for (auto &entry : terminals) entry.second.session_epoch = current_session;
    protocol.recovered_transactions = static_cast<uint32_t>(
        std::min<size_t>(requests.size(), std::numeric_limits<uint32_t>::max()));
    protocol.protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    protocol.session_epoch = current_session;
    protocol.queued_requests = static_cast<uint32_t>(request_queue.size());
    protocol.terminal_requests = static_cast<uint32_t>(terminals.size());
    protocol.pending_requests = 0;
    for (const auto &entry : requests) {
        if (terminals.find(entry.first) == terminals.end()) ++protocol.pending_requests;
    }
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        _country_economy_asset_requests = std::move(requests);
        _country_economy_asset_results = std::move(results);
        _country_economy_asset_terminal_results = std::move(terminals);
        _country_economy_asset_dispatched = std::move(dispatched);
        _country_economy_asset_committed = std::move(committed);
        _country_economy_asset_request_queue = std::move(request_queue);
        _economy_origin_asset_queue = std::move(origin_queue);
        _country_economy_asset_protocol = protocol;
    }
    uint64_t observed = _command_request_id.load(std::memory_order_acquire);
    while (observed < max_request_id &&
           !_command_request_id.compare_exchange_weak(
               observed, max_request_id, std::memory_order_acq_rel,
               std::memory_order_acquire)) {}
    (void)serialized_session;
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
    const uint64_t worker_hash = country_core_hash_business_state(worker);
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
            const bool country_prepare_transition =
                economy_asset_country_prepare_transition_valid(
                    existing->second, request);
            if (!economy_asset_request_equal(existing->second, request) &&
                !country_prepare_transition) {
                error = "country_economy_asset_request_duplicate_mismatch";
                set_country_economy_asset_protocol_error_locked(
                    RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH,
                    request.transaction_id, request.request_id, error.c_str());
                return false;
            }
            if (!country_prepare_transition)
                ++_country_economy_asset_protocol.duplicate_messages;
            if (_country_economy_asset_terminal_results.find(request.request_id) ==
                    _country_economy_asset_terminal_results.end() &&
                !queued(request.request_id) &&
                _country_economy_asset_dispatched.find(request.request_id) ==
                    _country_economy_asset_dispatched.end()) {
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
        } else if (economy_asset_country_prepare_transition_valid(
                       existing->second, request)) {
            existing->second = request;
            _country_economy_asset_dispatched.erase(request.request_id);
        }
        if (_country_economy_asset_terminal_results.find(request.request_id) ==
                _country_economy_asset_terminal_results.end() &&
            !queued(request.request_id) &&
            _country_economy_asset_dispatched.find(request.request_id) ==
                _country_economy_asset_dispatched.end()) {
            _country_economy_asset_request_queue.push_back(request.request_id);
        }
        _country_economy_asset_protocol.last_transaction_id =
            request.transaction_id;
        _country_economy_asset_protocol.last_request_id = request.request_id;
    }
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
    std::sort(_country_economy_asset_request_queue.begin(),
              _country_economy_asset_request_queue.end(),
              [this](uint64_t lhs, uint64_t rhs) {
        const auto &a = _country_economy_asset_requests.at(lhs);
        const auto &b = _country_economy_asset_requests.at(rhs);
        if (a.day != b.day) return a.day < b.day;
        if (a.operation_sequence != b.operation_sequence)
            return a.operation_sequence < b.operation_sequence;
        if (a.continuation_index != b.continuation_index)
            return a.continuation_index < b.continuation_index;
        return lhs < rhs;
    });
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
        _country_economy_asset_dispatched.erase(request_id);
        _country_economy_asset_committed.erase(request_id);
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
        _country_economy_asset_dispatched.insert(request_id);
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

bool NativeSimulationHost::country_economy_asset_terminal_result(
        uint64_t request_id, RuntimeEconomyAssetResult &out) const {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto it = _country_economy_asset_terminal_results.find(request_id);
    if (it == _country_economy_asset_terminal_results.end()) return false;
    out = it->second;
    return true;
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
            ++_country_economy_asset_protocol.duplicate_messages;
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

    // The request record is the durable transaction cursor. Keep its state in
    // lockstep with the newest accepted result so a D7T1 restore resumes from
    // the actual continuation boundary rather than from the original prepare.
    request->second.state = result.state;
    request->second.peer_generation = result.peer_generation;

    const auto existing = _country_economy_asset_results.find(
        result.request_id);
    if (existing != _country_economy_asset_results.end()) {
        if (economy_asset_result_equal(existing->second, result)) {
            ++_country_economy_asset_protocol.duplicate_messages;
            return true;
        }
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
        if (result.code == RuntimeEconomyAssetResultCode::FAULTED)
            ++_country_economy_asset_protocol.faulted_transactions;
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

bool NativeSimulationHost::requeue_country_economy_asset_request(
        uint64_t request_id, std::string &error) {
    error.clear();
    if (request_id == 0) {
        error = "country_economy_asset_requeue_identity_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto request = _country_economy_asset_requests.find(request_id);
    if (request == _country_economy_asset_requests.end()) {
        error = "country_economy_asset_requeue_request_unknown";
        return false;
    }
    if (_country_economy_asset_terminal_results.find(request_id) !=
            _country_economy_asset_terminal_results.end())
        return true;
    _country_economy_asset_dispatched.erase(request_id);
    if (std::find(_country_economy_asset_request_queue.begin(),
                  _country_economy_asset_request_queue.end(), request_id) ==
            _country_economy_asset_request_queue.end()) {
        if (_country_economy_asset_request_queue.size() >=
                RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY) {
            error = "country_economy_asset_request_capacity_exceeded";
            return false;
        }
        _country_economy_asset_request_queue.push_back(request_id);
    }
    std::sort(_country_economy_asset_request_queue.begin(),
              _country_economy_asset_request_queue.end(),
              [this](uint64_t lhs, uint64_t rhs) {
        const auto &a = _country_economy_asset_requests.at(lhs);
        const auto &b = _country_economy_asset_requests.at(rhs);
        if (a.day != b.day) return a.day < b.day;
        if (a.operation_sequence != b.operation_sequence)
            return a.operation_sequence < b.operation_sequence;
        if (a.continuation_index != b.continuation_index)
            return a.continuation_index < b.continuation_index;
        return lhs < rhs;
    });
    _country_economy_asset_protocol.queued_requests = static_cast<uint32_t>(
        std::min<size_t>(_country_economy_asset_request_queue.size(),
                         std::numeric_limits<uint32_t>::max()));
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

    RuntimeEconomyAssetRequest off_thread_cash;
    off_thread_cash.operation = RuntimeEconomyAssetOperation::CASH_FROM_COHORT;
    std::string boundary_error;
    if (probe.prepare_worker_cohort_cash(off_thread_cash, boundary_error) ||
        boundary_error != "country_worker_cohort_cash_boundary_invalid" ||
        !probe._country_economy_asset_requests.empty()) {
        error = "country_worker_cohort_cash_wrong_thread_accepted";
        return false;
    }
    // The two rejection classes must stay separated. A contract violation is a
    // caller bug and has to stay fatal; an open Country plan window is
    // backpressure and has to stay retryable. Collapsing them back into one
    // reason is what turned a normal continuation into an economy stop.
    if (runtime_country_asset_pending_reason(
            "country_worker_cohort_cash_boundary_invalid") ||
        !runtime_country_asset_pending_reason(
            "country_economy_asset_country_plan_pending")) {
        error = "country_worker_cohort_cash_reason_class_collapsed";
        return false;
    }
    // Same split for colonization. Under Country worker authority the paired
    // CLAIM commits on the worker's own boundary, so Economy SETTLE can observe
    // the target as still unowned. That is backpressure: classifying it as a
    // lost target sent the settlers home while the claim still landed, leaving
    // the player a cell they owned with nobody living on it.
    if (!runtime_country_asset_pending_reason(
            "country_economy_asset_territory_claim_pending")) {
        error = "country_economy_territory_claim_reason_class_collapsed";
        return false;
    }

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

    // D7T1 must retain all three durable shapes: terminal rows, a Country
    // request that has not yet been polled, and an Economy-origin request
    // waiting for Country prepare. The Country apply marker is included to
    // prove a restored duplicate cannot apply the same asset mutation twice.
    probe._country_economy_asset_committed.insert(request.request_id);
    RuntimeEconomyAssetRequest pending = request;
    pending.operation = RuntimeEconomyAssetOperation::FISCAL_RESERVE;
    pending.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    pending.transaction_id = 7002;
    pending.request_id = 7102;
    pending.day = 13;
    pending.operation_sequence = 100;
    pending.continuation_index = 0;
    pending.peer_generation = 9;
    pending.good_count = 0;
    pending.good_id = -1;
    pending.good_ids = {};
    pending.good_quantities = {};
    pending.requested_quantity = 5;
    pending.prepared_quantity = 5;
    pending.requested_cash = 5;
    pending.reserved_cash = 5;
    pending.requested_goods_total = 0;
    pending.reserved_goods_total = 0;
    if (!probe.publish_country_economy_asset_requests({pending}, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_pending_seed_failed"
            : publish_error;
        return false;
    }
    RuntimeEconomyAssetRequest dispatched_pending;
    if (!probe.poll_country_economy_asset_request(dispatched_pending) ||
        dispatched_pending.request_id != pending.request_id) {
        error = "country_economy_asset_self_test_pending_dispatch_failed";
        return false;
    }
    RuntimeEconomyAssetRequest origin = pending;
    origin.operation = RuntimeEconomyAssetOperation::FISCAL_RETURN;
    origin.state = RuntimeEconomyAssetState::CREATED;
    origin.transaction_id = 7003;
    origin.request_id = 7103;
    origin.operation_sequence = 101;
    origin.prepared_quantity = 0;
    origin.reserved_cash = 0;
    if (!probe.enqueue_economy_origin_country_asset(origin, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_origin_seed_failed"
            : publish_error;
        return false;
    }
    std::vector<uint8_t> journal;
    std::string journal_error;
    if (!probe.serialize_country_economy_asset_journal(journal, journal_error) ||
        journal.size() < 16u) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_journal_encode_failed"
            : journal_error;
        return false;
    }
    auto restored = std::make_unique<NativeSimulationHost>();
    restored->_country_worker_session_epoch = 52;
    if (!restored->restore_country_economy_asset_journal(
            journal.data(), journal.size(), journal_error)) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_journal_restore_failed"
            : journal_error;
        return false;
    }
    const auto restored_terminal =
        restored->_country_economy_asset_terminal_results.find(request.request_id);
    const auto restored_pending =
        restored->_country_economy_asset_requests.find(pending.request_id);
    const auto restored_origin =
        restored->_country_economy_asset_requests.find(origin.request_id);
    if (restored_terminal ==
            restored->_country_economy_asset_terminal_results.end() ||
        restored_pending == restored->_country_economy_asset_requests.end() ||
        restored_origin == restored->_country_economy_asset_requests.end() ||
        restored_pending->second.transaction_id != pending.transaction_id ||
        restored_origin->second.transaction_id != origin.transaction_id ||
        restored_pending->second.session_epoch != 52 ||
        restored_origin->second.session_epoch != 52 ||
        restored->_country_economy_asset_committed.find(request.request_id) ==
            restored->_country_economy_asset_committed.end()) {
        error = "country_economy_asset_self_test_journal_identity_failed";
        return false;
    }
    const RuntimeEconomyAssetProtocolStatus restored_status =
        restored->country_economy_asset_protocol_status();
    if (restored_status.queued_requests != 1 ||
        restored_status.pending_requests != 2 ||
        restored_status.terminal_requests != 1 ||
        restored_status.recovered_transactions != 3) {
        error = "country_economy_asset_self_test_journal_status_failed";
        return false;
    }
    RuntimeEconomyAssetRequest rebound_pending;
    if (!restored->poll_country_economy_asset_request(rebound_pending) ||
        rebound_pending.request_id != pending.request_id ||
        rebound_pending.session_epoch != 52) {
        error = "country_economy_asset_self_test_pending_requeue_failed";
        return false;
    }
    if (restored->_economy_origin_asset_queue.empty() ||
        restored->_economy_origin_asset_queue.front() != origin.request_id) {
        error = "country_economy_asset_self_test_origin_requeue_failed";
        return false;
    }
    RuntimeEconomyAssetResult old_session = completed;
    if (restored->submit_country_economy_asset_result(
            old_session, result_error) ||
        result_error != "country_economy_asset_result_session_mismatch") {
        error = "country_economy_asset_self_test_old_session_guard_failed";
        return false;
    }
    RuntimeEconomyAssetResult rebound = completed;
    rebound.session_epoch = 52;
    if (!restored->submit_country_economy_asset_result(rebound, result_error) ||
        restored->country_economy_asset_protocol_status().duplicate_messages == 0) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_restored_duplicate_failed"
            : result_error;
        return false;
    }
    std::vector<uint8_t> corrupted = journal;
    corrupted[4] ^= 0xffu;
    auto corrupt_probe = std::make_unique<NativeSimulationHost>();
    corrupt_probe->_country_worker_session_epoch = 53;
    if (corrupt_probe->restore_country_economy_asset_journal(
            corrupted.data(), corrupted.size(), journal_error)) {
        error = "country_economy_asset_self_test_corrupt_journal_accepted";
        return false;
    }
    return true;
}

uint32_t NativeSimulationHost::prepare_economy_origin_country_assets(
        std::string &error) {
    error.clear();
    if (!_country_pod_configured.load(std::memory_order_acquire)) return 0u;
    if (!domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        !country_authority_owner_is_worker()) {
        return 0u;
    }

    const auto sort_origin_queue_locked = [this]() {
        std::sort(_economy_origin_asset_queue.begin(),
                  _economy_origin_asset_queue.end(),
                  [this](uint64_t lhs, uint64_t rhs) {
            const auto &a = _country_economy_asset_requests.at(lhs);
            const auto &b = _country_economy_asset_requests.at(rhs);
            if (a.day != b.day) return a.day < b.day;
            if (a.operation_sequence != b.operation_sequence)
                return a.operation_sequence < b.operation_sequence;
            if (a.continuation_index != b.continuation_index)
                return a.continuation_index < b.continuation_index;
            return lhs < rhs;
        });
    };

    // Recover CREATED orphans left after older prepare cleared the origin
    // queue then failed: without this, Economy parks forever, Climate stops
    // consuming, and WorldClock nails climate_input_capacity_day_barrier.
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        bool recovered = false;
        for (const auto &entry : _country_economy_asset_requests) {
            if (entry.second.origin_domain !=
                    static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
                continue;
            }
            if (entry.second.state != RuntimeEconomyAssetState::CREATED)
                continue;
            if (_country_economy_asset_terminal_results.find(entry.first) !=
                    _country_economy_asset_terminal_results.end()) {
                continue;
            }
            if (std::find(_economy_origin_asset_queue.begin(),
                          _economy_origin_asset_queue.end(),
                          entry.first) != _economy_origin_asset_queue.end()) {
                continue;
            }
            _economy_origin_asset_queue.push_back(entry.first);
            recovered = true;
        }
        if (recovered) sort_origin_queue_locked();
    }

    uint32_t prepared = 0u;
    while (true) {
        uint64_t request_id = 0;
        RuntimeEconomyAssetRequest request;
        bool already_prepared = false;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            if (_economy_origin_asset_queue.empty()) break;
            request_id = _economy_origin_asset_queue.front();
            _economy_origin_asset_queue.pop_front();
            const auto it = _country_economy_asset_requests.find(request_id);
            if (it == _country_economy_asset_requests.end()) continue;
            request = it->second;
            already_prepared =
                request.state == RuntimeEconomyAssetState::COUNTRY_PREPARED;
        }
        if (!already_prepared) {
            RuntimeCountryPodSnapshot snapshot;
            std::string snap_error;
            if (!_country_pod_authority.snapshot(snapshot, snap_error) ||
                !country_core_apply_economy_asset_prepare(
                    snapshot, _country_pod_catalog, request, snap_error)) {
                // Soft-reject this wire id so research/fiscal continuations
                // observe a terminal instead of a CREATED orphan.
                RuntimeEconomyAssetResult rejected;
                rejected.code = RuntimeEconomyAssetResultCode::REJECTED;
                rejected.state = RuntimeEconomyAssetState::REJECTED;
                rejected.accepted = 0;
                rejected.session_epoch = request.session_epoch;
                rejected.transaction_id = request.transaction_id;
                rejected.request_id = request.request_id;
                rejected.operation = request.operation;
                rejected.continuation_index = request.continuation_index;
                rejected.day = request.day;
                rejected.country_generation = request.country_generation;
                rejected.peer_generation = request.peer_generation;
                rejected.committed_peer_generation = request.peer_generation;
                rejected.country_slot = request.country_slot;
                rejected.target_slot = request.target_slot;
                const std::string reason = snap_error.empty()
                    ? "country_worker_economy_prepare_failed" : snap_error;
                const size_t n = std::min(reason.size(),
                                          rejected.reason.size() - 1u);
                std::memcpy(rejected.reason.data(), reason.data(), n);
                rejected.reason[n] = '\0';
                std::string submit_error;
                if (!submit_country_economy_asset_result(rejected,
                                                        submit_error)) {
                    std::lock_guard<std::mutex> lock(_country_transport_mutex);
                    _economy_origin_asset_queue.push_front(request_id);
                    sort_origin_queue_locked();
                    error = submit_error.empty() ? reason : submit_error;
                    return prepared;
                }
                continue;
            }
            request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            _country_economy_asset_requests[request_id] = request;
        }
        std::string publish_error;
        if (!publish_country_economy_asset_requests({request}, publish_error)) {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            _economy_origin_asset_queue.push_front(request_id);
            sort_origin_queue_locked();
            error = publish_error.empty()
                ? "country_worker_economy_request_failed" : publish_error;
            return prepared;
        }
        ++prepared;
    }
    if (prepared > 0u) {
        _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
        _control_cv.notify_all();
    }
    return prepared;
}

bool NativeSimulationHost::flush_country_economy_asset_commits(
        std::string &error, uint64_t settle_request_id) {
    error.clear();
    struct PendingCommit {
        uint64_t request_id = 0;
        RuntimeEconomyAssetRequest request;
        RuntimeEconomyAssetResult result;
    };
    std::vector<PendingCommit> pending;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        pending.reserve(_country_economy_asset_terminal_results.size());
        for (const auto &entry : _country_economy_asset_terminal_results) {
            if (_country_economy_asset_committed.find(entry.first) !=
                    _country_economy_asset_committed.end()) {
                continue;
            }
            const auto request = _country_economy_asset_requests.find(entry.first);
            if (request == _country_economy_asset_requests.end()) continue;
            // Country day-start / Economy stage-end flush must not debit
            // treasury for COMPLETED RESEARCH_PURCHASE before Economy phase 4
            // credits merchants in the same conservation window. Early flush
            // left opening cash already reduced while merchant credit landed
            // next epoch → money_conservation_failed / goods_error.
            if (request->second.operation ==
                    RuntimeEconomyAssetOperation::RESEARCH_PURCHASE &&
                entry.second.code ==
                    RuntimeEconomyAssetResultCode::COMPLETED &&
                settle_request_id != entry.first) {
                continue;
            }
            pending.push_back(PendingCommit{
                entry.first, request->second, entry.second});
        }
    }
    const bool plan_active = _country_pod_plan_active.load(std::memory_order_acquire);
    for (const PendingCommit &item : pending) {
        if (plan_active) {
            // Plan next_state must see the debit so commit_day stays consistent.
            if (!country_core_apply_economy_asset_commit(
                    _country_pod_plan.next_state, _country_pod_catalog,
                    item.request, item.result, error)) {
                return false;
            }
            // Also persist onto authority without bumping generation. Otherwise
            // publish_country_worker_snapshot still serves the pre-debit base,
            // Economy credits merchants against a flat treasury view, and a later
            // discard_plan would resurrect cash after the peer side-effect.
            if (!_country_pod_authority.apply_economy_asset_commit_to_authority_state(
                    item.request, item.result, error)) {
                return false;
            }
            _country_pod_plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        } else if (!_country_pod_authority.apply_economy_asset_result(
                       item.request, item.result, error)) {
            return false;
        }
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        _country_economy_asset_committed.insert(item.request_id);
    }
    return true;
}

bool NativeSimulationHost::enqueue_economy_origin_country_asset(
        RuntimeEconomyAssetRequest request, std::string &error) {
    error.clear();
    if (request.request_id == 0)
        request.request_id = allocate_command_request_id();
    if (request.transaction_id == 0)
        request.transaction_id = request.request_id;
    if (request.session_epoch == 0)
        request.session_epoch = _country_worker_session_epoch;
    if (request.operation_sequence == 0)
        request.operation_sequence = request.request_id;
    request.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    request.state = RuntimeEconomyAssetState::CREATED;
    std::string shape_error;
    if (!economy_asset_request_shape_valid(request, shape_error)) {
        error = shape_error.empty()
            ? "country_economy_asset_request_invalid" : shape_error;
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto existing = _country_economy_asset_requests.find(request.request_id);
    if (existing != _country_economy_asset_requests.end()) {
        // A continuation retry repeats the original Economy-origin wire
        // request. Country may already have advanced it to COUNTRY_PREPARED;
        // treat that exact logical retry as idempotent rather than allocating
        // a second Country reservation.
        if (economy_asset_request_equal(existing->second, request) ||
            economy_asset_country_prepare_transition_valid(request,
                                                            existing->second)) {
            ++_country_economy_asset_protocol.duplicate_messages;
            return true;
        }
        error = "country_economy_asset_request_duplicate_mismatch";
        return false;
    }
    _country_economy_asset_requests.emplace(request.request_id, request);
    _economy_origin_asset_queue.push_back(request.request_id);
    std::sort(_economy_origin_asset_queue.begin(),
              _economy_origin_asset_queue.end(),
              [this](uint64_t lhs, uint64_t rhs) {
        const auto &a = _country_economy_asset_requests.at(lhs);
        const auto &b = _country_economy_asset_requests.at(rhs);
        if (a.day != b.day) return a.day < b.day;
        if (a.operation_sequence != b.operation_sequence)
            return a.operation_sequence < b.operation_sequence;
        if (a.continuation_index != b.continuation_index)
            return a.continuation_index < b.continuation_index;
        return lhs < rhs;
    });
    ++_country_economy_asset_protocol.pending_requests;
    _country_economy_asset_protocol.last_request_id = request.request_id;
    _country_economy_asset_protocol.last_transaction_id = request.transaction_id;
    // Wake the Country worker so same-day prepare can drain the origin queue
    // without waiting for the next unrelated peer signal.
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

bool NativeSimulationHost::prepare_worker_cohort_cash(
        RuntimeEconomyAssetRequest &request, std::string &error) {
    error.clear();
    // Contract violations. Wrong thread, Country not worker-authoritative, or
    // an operation outside the M2 cohort-cash pair are caller bugs: no retry
    // can make them valid.
    if (std::this_thread::get_id() != _worker.get_id() ||
        !domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) ||
        (request.operation != RuntimeEconomyAssetOperation::CASH_TO_COHORT &&
         request.operation != RuntimeEconomyAssetOperation::CASH_FROM_COHORT)) {
        error = "country_worker_cohort_cash_boundary_invalid";
        return false;
    }
    // Timing window, not a contract violation. Country's plan for this day is
    // still open (its stage parked on a peer/asset terminal), so the POD
    // snapshot this prepare would read is mid-plan. Nothing has been allocated
    // or published yet, so the caller can safely retry on a later pulse once
    // commit_day closes the window.
    if (_country_pod_plan_active.load(std::memory_order_acquire)) {
        error = "country_economy_asset_country_plan_pending";
        return false;
    }
    request.session_epoch = _country_worker_session_epoch;
    request.request_id = allocate_command_request_id();
    request.transaction_id = request.request_id;
    request.operation_sequence = request.request_id;
    request.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    RuntimeCountryPodSnapshot snapshot;
    if (!_country_pod_authority.snapshot(snapshot, error) ||
        !country_core_apply_economy_asset_prepare(
            snapshot, _country_pod_catalog, request, error)) return false;
    if (request.operation == RuntimeEconomyAssetOperation::CASH_FROM_COHORT &&
        snapshot.country_cash[static_cast<size_t>(request.country_slot)] >
            INT64_MAX - request.requested_cash) {
        error = "country_worker_cohort_cash_treasury_overflow";
        return false;
    }
    // Both owners execute on this thread. Publish directly to the existing
    // peer queue; there is no later Country stage to prepare this same day.
    return publish_country_economy_asset_requests({request}, error);
}

bool NativeSimulationHost::finish_worker_country_asset(
        uint64_t request_id, RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    if (std::this_thread::get_id() != _worker.get_id() ||
        !country_economy_asset_terminal_result(request_id, result)) {
        error = "country_worker_cohort_cash_terminal_missing";
        return false;
    }
    if (result.code != RuntimeEconomyAssetResultCode::COMPLETED) {
        error = result.reason.data();
        if (error.empty()) error = "country_worker_cohort_cash_rejected";
        return false;
    }
    if (!flush_country_economy_asset_commits(error, request_id)) return false;
    return publish_country_worker_snapshot(RUNTIME_DIRTY_COUNTRY_STATE, error);
}

bool NativeSimulationHost::country_authority_drain_idle_locked() const {
    if (!_country_worker_intent_queue.empty() ||
        !_country_worker_intents.empty() ||
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
            // COMPLETED research still awaits Economy settlement flush; do not
            // treat the bare terminal as idle handoff-ready.
            if (entry.second.operation ==
                    RuntimeEconomyAssetOperation::RESEARCH_PURCHASE &&
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
            std::atomic_store_explicit(
                &_country_snapshot,
                std::shared_ptr<const RuntimeCountryPodSnapshot>(copy),
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

bool NativeSimulationHost::configure_trigger_pod(
        const RuntimeTriggerPodCatalog &catalog, std::string &error) {
    return _domain_authority_runner.configure_trigger_pod(catalog, error);
}

bool NativeSimulationHost::queue_trigger_pod_command(
        const RuntimeTriggerCommand &command, std::string &error) {
    return _domain_authority_runner.queue_trigger_command(command, error);
}

bool NativeSimulationHost::try_acquire_trigger_snapshot(uint64_t after_generation,
                                                        uint32_t &slot) {
    return _trigger_snapshots.try_acquire_latest(after_generation, slot);
}

const RuntimeTriggerSnapshot &NativeSimulationHost::trigger_snapshot_buffer(
        uint32_t slot) const {
    return _trigger_snapshots.read_buffer(slot);
}

void NativeSimulationHost::release_trigger_snapshot(uint32_t slot) {
    _trigger_snapshots.release(slot);
}

bool NativeSimulationHost::poll_trigger_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    if (_trigger_intents.empty()) return false;
    const RuntimeTriggerEffectIntent source = _trigger_intents.front();
    _trigger_intents.pop_front();
    intent = RuntimeDomainIntent{};
    // Trigger identifies an effect intent by its own effect id. The ACK barrier
    // matches on (transaction_id, effective_day), so both must survive the
    // round trip through the main thread untouched.
    intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    intent.source_id = static_cast<uint64_t>(source.id);
    intent.request_id = static_cast<uint64_t>(source.id);
    intent.target_domain = static_cast<uint16_t>(source.domain);
    intent.opcode = static_cast<uint16_t>(source.opcode);
    intent.target_handle = source.target_handle;
    intent.target_generation = source.target_generation;
    intent.effective_day = source.effective_day;
    intent.value = source.resolved_value;
    intent.duration_days = source.duration_days;
    intent.stacks = source.stacks;
    intent.payload = source.payload;
    intent.flags = RUNTIME_DOMAIN_INTENT_REQUIRES_ACK;
    return true;
}

bool NativeSimulationHost::submit_trigger_pod_ack(const RuntimeDomainAck &ack,
                                                  std::string &error) {
    error.clear();
    if (ack.transaction_id == 0) {
        error = "trigger_ack_transaction_missing";
        return false;
    }
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    if (_trigger_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "trigger_ack_capacity_exceeded";
        return false;
    }
    _trigger_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
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
    // Key→id binding is installed by the caller after configure; drop any
    // previous catalog's hashes so a half-init cannot resolve to stale ids.
    _modifier_definition_id_by_key_hash.clear();
    return true;
}

void NativeSimulationHost::set_modifier_definition_key_hashes(
        const std::vector<std::pair<uint64_t, int32_t>> &entries) {
    _modifier_definition_id_by_key_hash.clear();
    _modifier_definition_id_by_key_hash.reserve(entries.size());
    for (const auto &entry : entries) {
        if (entry.first == 0 || entry.second < 0) continue;
        _modifier_definition_id_by_key_hash.emplace(entry.first, entry.second);
    }
}

int32_t NativeSimulationHost::resolve_modifier_definition_id_for_effect_intent(
        const RuntimeDomainIntent &intent) const {
    // Preferred: Effect command definition_key_hash → Modifier catalog id.
    if (_effect_pod_configured && intent.request_id != 0) {
        const auto &snapshot = _effect_pod_authority.snapshot();
        for (const auto &transaction : snapshot.transactions) {
            if (static_cast<uint64_t>(transaction.transaction_id) !=
                intent.request_id) {
                continue;
            }
            const uint32_t ordinal =
                static_cast<uint32_t>(intent.sequence & 15u);
            if (ordinal >= transaction.command_count) break;
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= snapshot.command_arena.size()) break;
            const auto &command = snapshot.command_arena[command_index];
            if (command.action != RuntimeEffectPodAction::MODIFIER_COMMAND)
                break;
            if (command.definition_key_hash != 0) {
                const auto found = _modifier_definition_id_by_key_hash.find(
                    command.definition_key_hash);
                if (found != _modifier_definition_id_by_key_hash.end())
                    return found->second;
            }
            break;
        }
    }
    // Legacy: payload[0] already carries a dense Modifier definition_id.
    if (intent.payload[0] > 0 &&
        intent.payload[0] <= static_cast<int64_t>(
            std::numeric_limits<int32_t>::max())) {
        return static_cast<int32_t>(intent.payload[0]);
    }
    return -1;
}

void NativeSimulationHost::reemit_effect_committed_pending_intents(int64_t day) {
    if (!_effect_pod_configured) return;
    const auto &snapshot = _effect_pod_authority.snapshot();
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.status !=
            RuntimeEffectPodTransactionStatus::COMMITTED) {
            continue;
        }
        for (uint32_t ordinal = 0; ordinal < transaction.command_count;
             ++ordinal) {
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= snapshot.command_arena.size()) break;
            const auto &command = snapshot.command_arena[command_index];
            const uint32_t bit =
                RuntimeEffectPodAuthority::adapter_ack_bit(command.action);
            if (bit != 0u &&
                (transaction.received_ack_mask & bit) == bit) {
                continue;
            }
            RuntimeDomainIntent intent;
            intent.source_domain =
                static_cast<uint16_t>(RuntimeDomainId::EFFECT);
            intent.target_domain =
                RuntimeEffectPodAuthority::adapter_domain(command.action);
            intent.opcode = static_cast<uint16_t>(command.opcode);
            intent.effect_action = static_cast<uint16_t>(command.action);
            intent.source_id =
                static_cast<uint64_t>(command.source_instance_id);
            intent.target_handle = command.target_handle;
            intent.target_generation = command.target_generation;
            intent.value = command.value;
            intent.effective_day = command.effective_day >= 0
                ? command.effective_day : day;
            intent.payload = command.payload;
            intent.request_id =
                static_cast<uint64_t>(transaction.transaction_id);
            intent.producer_id =
                static_cast<uint32_t>(RuntimeDomainId::EFFECT);
            intent.sequence =
                transaction.fire_sequence * 16u + ordinal;
            intent.idempotency_key = command.idempotency_key;
            intent.duration_days = command.duration_days;
            intent.stacks = command.stacks;
            intent.magnitude_q16 = command.value != 0
                ? static_cast<int32_t>(command.value) : 65536;
            if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND &&
                intent.payload[1] == 0 && command.domain >= 0 &&
                command.domain < 4) {
                intent.payload[1] = command.domain;
            }
            if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND &&
                intent.payload[0] <= 0 &&
                command.definition_key_hash != 0) {
                const auto found = _modifier_definition_id_by_key_hash.find(
                    command.definition_key_hash);
                if (found != _modifier_definition_id_by_key_hash.end())
                    intent.payload[0] = found->second;
            }
            _effect_day_intents.push_back(intent);
            if (intent.target_domain ==
                static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                _effect_day_modifier_intents.push_back(intent);
            }
        }
    }
}

uint32_t NativeSimulationHost::ack_effect_events_intents_in_worker(
        const std::vector<RuntimeDomainIntent> &intents) {
    if (!_effect_pod_configured || intents.empty()) return 0;
    std::vector<RuntimeDomainAck> acks;
    acks.reserve(intents.size());
    for (const RuntimeDomainIntent &intent : intents) {
        if (intent.target_domain !=
            static_cast<uint16_t>(RuntimeDomainId::EVENTS)) {
            continue;
        }
        RuntimeDomainAck ack;
        ack.request_id =
            intent.request_id != 0 ? intent.request_id : intent.source_id;
        ack.transaction_id = ack.request_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        ack.producer_id = intent.producer_id;
        ack.sequence = intent.sequence;
        acks.push_back(ack);
    }
    if (acks.empty()) return 0;
    std::string error;
    if (!_effect_pod_authority.apply_acks(acks, error)) {
        // Soft: leave Events bit for the main-thread pump / next retry.
        return 0;
    }
    _effect_pod_ack_count.store(
        _effect_pod_ack_count.load(std::memory_order_relaxed) +
            static_cast<uint32_t>(acks.size()),
        std::memory_order_release);
    _effect_pod_state_hash.store(
        _effect_pod_authority.snapshot().deterministic_state_hash,
        std::memory_order_release);
    return static_cast<uint32_t>(acks.size());
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
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        _effect_instance_queue.clear();
        _effect_metric_queue.clear();
        _effect_remove_queue.clear();
        _effect_intents.clear();
        _effect_acks.clear();
    }
    _effect_day_modifier_intents.clear();
    _effect_day_stage_ok = false;
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

bool NativeSimulationHost::effect_pod_host_stage_self_test(std::string *out_error) {
    const auto fail = [out_error](const char *reason) {
        if (out_error != nullptr) *out_error = reason;
        return false;
    };
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        return fail("effect_host_stage_requires_stopped");
    }

    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {RuntimeEffectPodAuthority::hash_text("metric")};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = RuntimeEffectPodAuthority::hash_text("f7.fixture");
    definition.cadence_days = 1;
    definition.max_work = 64;
    definition.instruction_begin = 0;
    definition.instruction_count = 2;
    definition.command_begin = 0;
    definition.command_count = 1;
    catalog.definitions.push_back(definition);
    RuntimeEffectPodCommandDefinition command_definition;
    command_definition.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
    command_definition.domain = 0;
    command_definition.opcode = 1;
    command_definition.target_resolver =
        RuntimeEffectPodTargetResolver::INSTANCE;
    command_definition.value_mode = RuntimeEffectPodValueMode::STACK_TOP;
    command_definition.duration_days = -1;
    command_definition.stacks = 1;
    command_definition.command_key_hash =
        RuntimeEffectPodAuthority::hash_text("f7.modifier");
    command_definition.payload = {0, 0, 2, 0};
    catalog.commands.push_back(command_definition);
    RuntimeEffectPodInstruction constant;
    // Windows headers may define CONST as a macro; avoid the bare enumerator.
    constant.op = static_cast<RuntimeEffectPodInstructionOp>(1); // CONST
    constant.value = 65536;
    catalog.instructions.push_back(constant);
    RuntimeEffectPodInstruction emit;
    emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
    emit.arg0 = 0;
    catalog.instructions.push_back(emit);

    std::string error;
    if (!configure_effect_pod(catalog, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_configure_failed" : error;
        return false;
    }

    RuntimeEffectPodInstanceInput input;
    input.instance_id = 42;
    input.generation = 1;
    input.program_id = 0;
    input.source_handle = 7;
    input.target_handle = 99;
    input.target_generation = 3;
    input.next_due_day = 0;
    input.active = true;
    if (!queue_effect_pod_instance(input, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_queue_failed" : error;
        return false;
    }
    if (!queue_effect_pod_metric(42, 1, 0, 1, 7, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_metric_failed" : error;
        return false;
    }

    RuntimeDayCommit commit;
    if (!execute_effect_worker_stage(0, 1, commit, error) || !_effect_day_stage_ok) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_plan_failed" : error;
        return false;
    }
    if (_effect_day_modifier_intents.empty())
        return fail("effect_host_stage_missing_modifier_intent");
    if (_effect_pod_intent_count.load(std::memory_order_acquire) == 0)
        return fail("effect_host_stage_intent_count_zero");
    if (_effect_pod_snapshot_generation.load(std::memory_order_acquire) == 0)
        return fail("effect_host_stage_generation_unchanged");

    const RuntimeDomainIntent &intent = _effect_day_modifier_intents.front();
    RuntimeDomainAck ack;
    ack.request_id = intent.request_id;
    ack.transaction_id = intent.request_id;
    ack.target_handle = intent.target_handle;
    ack.target_generation = intent.target_generation;
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    ack.code = RuntimeDomainAckCode::OK;
    ack.effective_day = intent.effective_day;
    ack.producer_id = intent.producer_id;
    ack.sequence = intent.sequence;
    if (!_effect_pod_authority.apply_ack(ack, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_ack_failed" : error;
        return false;
    }
    const auto &snapshot = _effect_pod_authority.snapshot();
    if (snapshot.transactions.empty() ||
        snapshot.transactions.front().status !=
        RuntimeEffectPodTransactionStatus::ACKED) {
        return fail("effect_host_stage_not_acked");
    }
    // M3 end-to-end pin: an ACKED Effect transaction must publish one typed
    // event through the same Events authority used by the worker stage. This
    // deliberately exercises the real APPEND_BATCH wire instead of merely
    // checking that the two POD self-tests pass independently.
    {
        RuntimeEventsRecord event;
        event.tick = 0;
        event.phase = 7;
        event.type = 900; // effect transaction publication fixture
        event.source = 1;
        event.entity_handle = static_cast<uint64_t>(
            snapshot.transactions.front().source_instance_id);
        event.payload_schema = 1;
        event.value_i64 = snapshot.transactions.front().transaction_id;
        std::vector<uint8_t> payload;
        const auto put_u32 = [&payload](uint32_t value) {
            for (int i = 0; i < 4; ++i)
                payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
        };
        const auto put_i32 = [&put_u32](int32_t value) {
            put_u32(static_cast<uint32_t>(value));
        };
        const auto put_u64 = [&payload](uint64_t value) {
            for (int i = 0; i < 8; ++i)
                payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
        };
        const auto put_i64 = [&put_u64](int64_t value) {
            put_u64(static_cast<uint64_t>(value));
        };
        put_u32(RUNTIME_EVENTS_ABI_VERSION);
        put_u32(1u);
        put_i64(event.tick);
        put_i32(event.phase);
        put_i32(event.type);
        put_i32(event.source);
        put_i32(event.flags);
        put_u64(event.entity_handle);
        put_i32(event.entity_id);
        put_i32(event.cell_idx);
        put_i32(event.payload_schema);
        put_i64(event.value_i64);
        put_i32(event.payload_i0);
        put_i32(event.payload_i1);
        put_i32(event.payload_i2);
        put_i32(event.payload_i3);
        put_u64(static_cast<uint64_t>(event.value_i64));
        RuntimeCommandPacket event_packet{};
        event_packet.envelope.request_id = 0xEFFE0001u;
        event_packet.envelope.producer_id = 77u;
        event_packet.envelope.sequence = 1u;
        event_packet.envelope.requested_day = 0;
        event_packet.envelope.effective_day = 0;
        event_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        event_packet.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
        event_packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
        std::memcpy(event_packet.payload.data(), payload.data(), payload.size());
        std::vector<RuntimeCommandPacket> event_commands{event_packet};
        RuntimeEventsSnapshot planned_events;
        std::vector<RuntimeCommandReceipt> event_receipts;
        RuntimeEventsReport event_report;
        if (!_events_authority.plan_day(0, event_commands, planned_events,
                                        event_receipts, event_report, error) ||
            !event_report.preflight_ok || event_report.appended_events != 1u ||
            !_events_authority.commit_day(planned_events, error) ||
            _events_authority.snapshot().events.empty() ||
            _events_authority.snapshot().events.back().type != event.type) {
            return fail("effect_host_stage_events_publication_failed");
        }
    }
    // M5 pin: every protocol stage is now represented by the implementation
    // capability mask, including input capture, gameplay effects and visual
    // intent publication.
    if (implemented_domain_mask() != RUNTIME_ALL_DOMAIN_MASK) {
        return fail("effect_host_stage_mask_changed");
    }
    return true;
}

bool NativeSimulationHost::queue_effect_pod_instance(
        const RuntimeEffectPodInstanceInput &input, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    for (const RuntimeEffectPodInstanceInput &queued : _effect_instance_queue) {
        if (queued.instance_id == input.instance_id &&
            queued.generation == input.generation) {
            return true; // already waiting for the Effect stage
        }
    }
    if (_effect_instance_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_instance_capacity_exceeded";
        return false;
    }
    _effect_instance_queue.push_back(input);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_metric(
        int64_t instance_id, uint32_t generation, int32_t metric_id,
        int64_t revision, int64_t value, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_metric_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_metric_capacity_exceeded";
        return false;
    }
    EffectPodMetricQueueItem item;
    item.instance_id = instance_id;
    item.generation = generation;
    item.metric_id = metric_id;
    item.revision = revision;
    item.value = value;
    _effect_metric_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_remove(
        int64_t instance_id, uint32_t generation, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_remove_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_remove_capacity_exceeded";
        return false;
    }
    EffectPodRemoveQueueItem item;
    item.instance_id = instance_id;
    item.generation = generation;
    _effect_remove_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::poll_effect_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_intents.empty()) return false;
    intent = _effect_intents.front();
    _effect_intents.pop_front();
    return true;
}

bool NativeSimulationHost::submit_effect_pod_ack(
        const RuntimeDomainAck &ack, std::string &error) {
    if (ack.transaction_id == 0 && ack.request_id == 0) {
        error = "effect_ack_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "effect_ack_capacity_exceeded";
        return false;
    }
    _effect_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
}

int32_t NativeSimulationHost::effect_pod_program_id_for_key(
        const char *key) const {
    if (!_effect_pod_configured || key == nullptr || key[0] == '\0') return -1;
    const uint64_t hash = RuntimeEffectPodAuthority::hash_text(key);
    for (size_t i = 0; i < _effect_pod_catalog.definitions.size(); ++i) {
        if (_effect_pod_catalog.definitions[i].key_hash == hash)
            return static_cast<int32_t>(i);
    }
    return -1;
}

bool NativeSimulationHost::ensure_effect_pod_technology_instance(
        int64_t instance_id, uint32_t generation, int32_t program_id,
        uint64_t target_handle, uint32_t target_generation, int64_t day,
        std::string &error) {
    error.clear();
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    if (instance_id == 0 || generation == 0 || program_id < 0) {
        error = "effect_pod_technology_instance_invalid";
        return false;
    }
    // Already present in the committed POD snapshot — do not re-queue.
    {
        const auto &snapshot = _effect_pod_authority.snapshot();
        for (const auto &instance : snapshot.instances) {
            if (instance.instance_id == instance_id &&
                instance.generation == generation &&
                instance.active != 0) {
                return true;
            }
        }
    }
    RuntimeEffectPodInstanceInput input;
    input.instance_id = instance_id;
    input.generation = generation;
    input.program_id = program_id;
    input.source_type = 0x54454348; // 'TECH'
    input.source_id = instance_id;
    input.source_handle = target_handle;
    input.target_handle = target_handle;
    input.target_generation = target_generation;
    input.level = 0;
    // Effect often soft-skips the same calendar day Country seals. Schedule
    // the first fire for the next sequential Effect day (committed+1), never
    // the already-closed committed day — otherwise plan_day cannot see the
    // instance until a never-fired cadence retry (technology cadence is 3650).
    const int64_t effect_day = _effect_pod_authority.snapshot().committed_day;
    input.next_due_day = effect_day >= 0 ? effect_day + 1 : day;
    input.active = true;
    // Queue only. The main-thread Country peer adapter must never mutate the
    // Effect POD authority: worker plan_day/commit/ack run concurrently and a
    // same-turn upsert races them (instances stuck fire_seq=0 / never fire).
    // Effect stage drain_effect_transport_queues installs before plan/soft-skip.
    if (!queue_effect_pod_instance(input, error)) return false;
    return true;
}

std::string NativeSimulationHost::describe_effect_pod_technology_state(
        int64_t instance_id, uint32_t generation, int32_t program_id,
        int32_t technology) const {
    char text[512]{};
    if (!_effect_pod_configured) return "effect_pod_not_configured";
    const auto &snapshot = _effect_pod_authority.snapshot();
    const RuntimeEffectPodInstance *found = nullptr;
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id == instance_id) { found = &instance; break; }
    }
    int transactions = 0;
    int last_status = -1;
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.source_instance_id != instance_id) continue;
        ++transactions;
        last_status = static_cast<int>(transaction.status);
    }
    std::snprintf(text, sizeof(text),
        "tech=%d program_id=%d instance=%lld gen=%u "
        "present=%d inst_gen=%u active=%d fire_seq=%llu acked_seq=%llu "
        "next_due=%lld tx=%d last_tx_status=%d pod_gen=%llu pod_day=%lld "
        "instances=%zu queued=%zu",
        technology, program_id, static_cast<long long>(instance_id), generation,
        found != nullptr ? 1 : 0,
        found != nullptr ? found->generation : 0u,
        found != nullptr ? static_cast<int>(found->active) : -1,
        static_cast<unsigned long long>(found != nullptr ? found->fire_sequence : 0),
        static_cast<unsigned long long>(
            found != nullptr ? found->last_acked_fire_sequence : 0),
        static_cast<long long>(found != nullptr ? found->next_due_day : -1),
        transactions, last_status,
        static_cast<unsigned long long>(snapshot.generation),
        static_cast<long long>(snapshot.committed_day),
        snapshot.instances.size(), _effect_instance_queue.size());
    return text;
}

bool NativeSimulationHost::effect_pod_instance_fire_acked(
        int64_t instance_id, uint32_t generation) const {
    if (!_effect_pod_configured || instance_id == 0 || generation == 0)
        return false;
    const auto &snapshot = _effect_pod_authority.snapshot();
    const RuntimeEffectPodInstance *found = nullptr;
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id == instance_id &&
            instance.generation == generation) {
            found = &instance;
            break;
        }
    }
    if (found == nullptr || found->fire_sequence == 0) return false;
    if (found->last_acked_fire_sequence >= found->fire_sequence) return true;
    bool saw_acked = false;
    bool saw_rejected = false;
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.source_instance_id != instance_id ||
            transaction.source_generation != generation) {
            continue;
        }
        if (transaction.status != RuntimeEffectPodTransactionStatus::ACKED &&
            transaction.status != RuntimeEffectPodTransactionStatus::REJECTED) {
            return false;
        }
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            saw_acked = true;
        else
            saw_rejected = true;
    }
    if (saw_acked) return true;
    if (saw_rejected) return false;
    return true;
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
    if (!RuntimeIdeologyPodAuthority::self_test(error)) {
        if (out_error != nullptr) *out_error = error;
        return false;
    }
    if (!RuntimeIdeologySnapshotRing::self_test()) {
        if (out_error != nullptr)
            *out_error = "ideology_pod_snapshot_ring_self_test_failed";
        return false;
    }
    return true;
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

bool NativeSimulationHost::try_acquire_effect_snapshot(
        uint64_t after_generation, uint32_t &slot) {
    if (!_effect_snapshots.try_acquire_latest(after_generation, slot)) return false;
    const RuntimeEffectPodSnapshot &snapshot =
        _effect_snapshots.read_buffer(slot);
    const bool valid = _effect_pod_configured &&
        snapshot.abi_version == RUNTIME_EFFECT_POD_ABI_VERSION &&
        snapshot.catalog_hash == _effect_pod_catalog.catalog_hash;
    if (!valid) {
        _effect_snapshots.release(slot);
        return false;
    }
    return true;
}

const RuntimeEffectPodSnapshot &NativeSimulationHost::effect_snapshot_buffer(
        uint32_t slot) const {
    return _effect_snapshots.read_buffer(slot);
}

void NativeSimulationHost::release_effect_snapshot(uint32_t slot) {
    _effect_snapshots.release(slot);
}

bool NativeSimulationHost::try_acquire_ideology_snapshot(
        uint64_t after_generation, uint32_t &slot) {
    if (!_ideology_snapshots.try_acquire_latest(after_generation, slot))
        return false;
    const RuntimeIdeologyPodSnapshot &snapshot =
        _ideology_snapshots.read_buffer(slot);
    const bool valid = _ideology_pod_configured &&
        snapshot.abi_version == RUNTIME_IDEOLOGY_POD_ABI_VERSION &&
        snapshot.catalog_hash == _ideology_pod_catalog.catalog_hash;
    if (!valid) {
        _ideology_snapshots.release(slot);
        return false;
    }
    return true;
}

const RuntimeIdeologyPodSnapshot &
NativeSimulationHost::ideology_snapshot_buffer(uint32_t slot) const {
    return _ideology_snapshots.read_buffer(slot);
}

void NativeSimulationHost::release_ideology_snapshot(uint32_t slot) {
    _ideology_snapshots.release(slot);
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
    // 诊断 / 物理派生读 latest；worker 日计划必须走 environment_input_for_plan。
    if (auto latest = _environment_ring.latest()) return latest;
    return std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire);
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
NativeSimulationHost::environment_input_for_plan() const {
    if (auto oldest = _environment_ring.peek_oldest()) return oldest;
    return environment_snapshot();
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
    _last_command_admitted_us.store(now_us(), std::memory_order_release);
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
    const auto modifier_enqueue_allowed = [this]() {
        const RuntimeSimulationMode mode =
            _mode.load(std::memory_order_acquire);
        if (mode == RuntimeSimulationMode::SHADOW) return true;
        // E8: ACTIVE Host is the sole Modifier writer once MODIFIER is
        // in the requested authority mask (grant may still be pending).
        if (mode == RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {
            return true;
        }
        return false;
    };
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current != RuntimeWorkerState::STOPPED) {
        if (!modifier_enqueue_allowed()) return false;
        return enqueue(std::move(packet));
    }
    if (packet.submit_order == 0) {
        packet.submit_order = _command_submit_order.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    std::lock_guard<std::mutex> lock(_control_mutex);
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        if (!modifier_enqueue_allowed()) return false;
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

bool NativeSimulationHost::try_country_command_terminal(
        uint64_t request_id, CountryCommandReceipt &out) {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto found = _country_command_terminals.find(request_id);
    if (found == _country_command_terminals.end()) return false;
    out = found->second;
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
    if (!flush_country_economy_asset_commits(error)) {
        commit.preflight_ok = 0;
        return false;
    }

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
            const bool decoded = RuntimeCountryPodAdapter::decode_command(
                packet, command, command_error);
            // The submitter's clock trails this worker's. Reschedule a late
            // intent onto the day being planned instead of refusing it;
            // requested_day still records what the player asked for.
            if (decoded && command.effective_day < day)
                command.effective_day = day;
            if (!decoded ||
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
                // Stable per (country handle, technology), mirroring the sync
                // NativeCountryRuntime::make_peer_intent. Deriving it from the
                // per-day request id minted a brand-new Effect instance every
                // worker day, so the fire ACK could never be observed across
                // days and the technology stayed pending forever.
                peer.effect_instance_id = peer.technology >= 0
                    ? (((peer.target_handle & 0x00007fffffffffffULL) << 16U) |
                       static_cast<uint64_t>(peer.technology + 1))
                    : peer.request_id;
                peer.effect_generation =
                    static_cast<uint32_t>(peer.target_handle >> 32U);
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
                bind_shadow_country_peer_mirrors_locked();
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

    if (!_country_pod_plan.economy_requests.empty()) {
        std::vector<RuntimeEconomyAssetRequest> unpublished;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            unpublished.reserve(_country_pod_plan.economy_requests.size());
            for (const RuntimeEconomyAssetRequest &request :
                    _country_pod_plan.economy_requests) {
                if (_country_economy_asset_requests.find(request.request_id) ==
                        _country_economy_asset_requests.end()) {
                    unpublished.push_back(request);
                }
            }
        }
        std::string asset_error;
        if (!publish_country_economy_asset_requests(unpublished, asset_error)) {
            error = asset_error.empty()
                ? "country_worker_economy_request_failed" : asset_error;
            commit.preflight_ok = 0;
            return false;
        }
    }

    std::string origin_error;
    prepare_economy_origin_country_assets(origin_error);
    if (!origin_error.empty()) {
        error = origin_error;
        commit.preflight_ok = 0;
        return false;
    }

    bool economy_asset_waiting = false;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        for (const auto &entry : _country_economy_asset_requests) {
            const RuntimeEconomyAssetRequest &request = entry.second;
            // Economy-origin fiscal/peer assets are prepared here so Country
            // cash staging is ready, but only the later ECONOMY stage can
            // service+terminal them. Waiting on those rows before ECONOMY
            // runs deadlocks the day the first time tax/settlement parks a
            // continuation (Country preflight forever, Economy never resumes).
            if (request.origin_domain ==
                static_cast<uint32_t>(RuntimeDomainId::ECONOMY)) {
                continue;
            }
            if (request.day > day ||
                _country_economy_asset_terminal_results.find(entry.first) !=
                    _country_economy_asset_terminal_results.end()) {
                continue;
            }
            economy_asset_waiting = true;
            break;
        }
    }
    if (economy_asset_waiting) {
        // Always soft-commit when Country-origin economy assets are still
        // outstanding. Hard-parking here leaves future Climate envs stuck in a
        // full FIFO while Economy never resumes → permanent
        // climate_input_capacity_day_barrier. Soft-commit the Country day and
        // let the next visit / Economy stage retire the asset rows.
        std::string soft_error;
        if (!_country_pod_authority.commit_rejected_day(
                _country_pod_plan, soft_error, /*advance_generation=*/true)) {
            error = soft_error.empty()
                ? "country_economy_asset_soft_commit_failed" : soft_error;
            commit.preflight_ok = 0;
            return false;
        }
        publish_country_command_terminals(
            _country_pod_plan.commands, CountryCommandReceiptCode::COMMITTED,
            _country_pod_authority.generation(), nullptr);
        _country_pod_plan_active.store(false, std::memory_order_release);
        std::string snapshot_error;
        if (!publish_country_worker_snapshot(
                _country_pod_plan.header.dirty_families, snapshot_error)) {
            error = snapshot_error.empty()
                ? "country_worker_snapshot_failed" : snapshot_error;
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
        bind_shadow_country_peer_mirrors_locked();
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
        // Soft-commit after Host inspected (PENDING) or under Climate ring
        // pressure. Never soft-commit+erase before inspect: Effect runs before
        // Country in the day graph, so ENSURE only reaches the Effect queue via
        // the main-thread peer pump. Wiping uninspected intents drops that
        // registration and parks technologies in 待生效 forever while the
        // calendar still advances.
        bool all_intents_inspected = true;
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                const uint64_t request_id = intent.request_id != 0
                    ? intent.request_id : intent.source_id;
                if (_country_worker_results.find(request_id) ==
                    _country_worker_results.end()) {
                    all_intents_inspected = false;
                    break;
                }
            }
        }
        // Soft-commit once half the FIFO is occupied. Waiting until the ring is
        // completely full lets Host arm climate_input_capacity_day_barrier first
        // (common after tax/subsidy fiscal peers under 50x), then both sides
        // park: Host on capacity, Country on peer inspect.
        const size_t ring_size = _environment_ring.size();
        const bool ring_pressure =
            !_environment_ring.has_capacity() ||
            ring_size + 1u >= RuntimeEnvironmentInputRing::SLOT_COUNT ||
            ring_size >= (RuntimeEnvironmentInputRing::SLOT_COUNT + 1u) / 2u;
        if (!all_intents_inspected && !ring_pressure) {
            error = "country_worker_peer_results_pending";
            commit.preflight_ok = 0;
            commit.continuation_pending = 1;
            return false;
        }
        // Inspected PENDING (Effect fire still in flight) or ring pressure
        // with Host lagging: soft-commit like peer rejection — keep research
        // spend + pending activation, close the calendar day, retry tomorrow.
        if (!_country_pod_authority.commit_rejected_day(
                _country_pod_plan, error, /*advance_generation=*/true)) {
            _country_pod_authority.discard_plan();
            _country_pod_plan_active.store(false, std::memory_order_release);
            set_fault(error.empty()
                          ? "country_worker_pending_peer_commit_failed"
                          : error.c_str());
            if (error.empty())
                error = "country_worker_pending_peer_commit_failed";
            commit.preflight_ok = 0;
            return false;
        }
        publish_country_command_terminals(
            _country_pod_plan.commands, CountryCommandReceiptCode::COMMITTED,
            _country_pod_authority.generation(), nullptr);
        _country_pod_plan_active.store(false, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(_country_transport_mutex);
            for (const RuntimeDomainIntent &intent : _country_pod_plan.intents) {
                const uint64_t request_id = intent.request_id != 0
                    ? intent.request_id : intent.source_id;
                // Keep uninspected intents queued so Host can still ENSURE the
                // Effect instance after this soft-commit. Erasing them here is
                // what stranded 燧石辨识-class techs at 100%/待生效.
                if (_country_worker_results.find(request_id) ==
                    _country_worker_results.end()) {
                    continue;
                }
                _country_worker_intents.erase(request_id);
                _country_worker_results.erase(request_id);
                _country_worker_terminal_results.erase(request_id);
            }
            _country_worker_intent_queue.erase(
                std::remove_if(_country_worker_intent_queue.begin(),
                               _country_worker_intent_queue.end(),
                    [&](uint64_t request_id) {
                        return _country_worker_intents.find(request_id) ==
                            _country_worker_intents.end();
                    }), _country_worker_intent_queue.end());
            _country_worker_protocol.pending_intents = static_cast<uint32_t>(
                std::min<size_t>(_country_worker_intents.size(),
                                 std::numeric_limits<uint32_t>::max()));
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
    if (!flush_country_economy_asset_commits(error)) {
        commit.preflight_ok = 0;
        return false;
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
        if (!_country_read_view_changed_cells.empty())
            _country_read_view_territory_generation = _country_read_view_generation;
        auto committed_copy = std::make_shared<RuntimeCountryPodSnapshot>(
            std::move(committed_snapshot));
        _country_committed_snapshot = committed_copy;
        _country_worker_country_generation = committed_copy->generation;
        _country_worker_day = committed_copy->committed_day;
        record_country_parity_locked(*committed_copy);
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

void NativeSimulationHost::publish_trigger_intents_locked(
        const std::vector<RuntimeTriggerEffectIntent> &intents) {
    for (const RuntimeTriggerEffectIntent &intent : intents) {
        if (intent.id <= _trigger_published_intent_id) continue;
        if (_trigger_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) break;
        _trigger_intents.push_back(intent);
        _trigger_published_intent_id = intent.id;
    }
}

uint32_t NativeSimulationHost::ack_trigger_intents_in_worker(int64_t day) {
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    uint32_t acked = 0;
    while (!_trigger_intents.empty()) {
        if (_trigger_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) break;
        const RuntimeTriggerEffectIntent intent = _trigger_intents.front();
        _trigger_intents.pop_front();
        RuntimeDomainAck ack;
        // ack_matches() keys on (transaction_id, effective_day, OK) only; the
        // domain tag is carried for the diagnostics/report side.
        ack.domain = static_cast<uint16_t>(intent.domain);
        ack.code = RuntimeDomainAckCode::OK;
        ack.request_id = static_cast<uint64_t>(intent.id);
        ack.transaction_id = static_cast<uint64_t>(intent.id);
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.effective_day = intent.effective_day;
        _trigger_acks.push_back(ack);
        ++acked;
    }
    (void)day;
    return acked;
}

bool NativeSimulationHost::execute_trigger_worker_stage(
        int64_t day, uint64_t input_generation, RuntimeDayCommit &commit,
        std::string &error) {
    error.clear();
    if (!_domain_authority_runner.trigger_pod_configured()) {
        error = "trigger_pod_not_configured";
        return false;
    }
    // The ACK deque is copied, not drained: an incomplete barrier discards the
    // plan and replays the same intent ids next visit, so an ACK consumed by a
    // failed attempt would be lost forever.
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
        acks.assign(_trigger_acks.begin(), _trigger_acks.end());
    }
    const auto plan_started = std::chrono::steady_clock::now();
    std::vector<RuntimeTriggerEffectIntent> intents;
    RuntimeTriggerSnapshot snapshot;
    uint32_t required_ack_count = 0;
    uint64_t state_hash = 0;
    double replay_ms = 0.0;
    const bool ok = _domain_authority_runner.run_trigger_active_day(
        day, input_generation, acks, intents, snapshot, required_ack_count,
        state_hash, replay_ms, error);
    {
        std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
        // Publish before deciding on success: a plan whose ACK barrier is
        // incomplete is exactly the case that needs its intents delivered.
        publish_trigger_intents_locked(intents);
        if (ok) _trigger_acks.clear();
    }
    _trigger_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _trigger_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _trigger_pod_intent_count.store(
        static_cast<uint32_t>(intents.size()), std::memory_order_release);
    _trigger_pod_ack_count.store(
        static_cast<uint32_t>(acks.size()), std::memory_order_release);
    if (!ok) return false;
    _trigger_pod_state_hash.store(state_hash, std::memory_order_release);
    _trigger_pod_snapshot_generation.store(snapshot.generation,
                                           std::memory_order_release);
    uint32_t trigger_slot = 0;
    if (_trigger_snapshots.try_begin_write(trigger_slot)) {
        _trigger_snapshots.write_buffer(trigger_slot) = snapshot;
        _trigger_snapshots.publish(trigger_slot);
    }
    commit.dirty_families |= RUNTIME_DIRTY_EVENTS;
    commit.work_units += intents.size() + snapshot.states.size();
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
    // G8: publish the immutable snapshot for main-thread NativeIdeologyRuntime
    // write-back. The shared_ptr above stays for SHADOW diagnostics readers.
    uint32_t ideology_slot = 0;
    if (_ideology_snapshots.try_begin_write(ideology_slot)) {
        _ideology_snapshots.write_buffer(ideology_slot) = snapshot;
        _ideology_snapshots.publish(ideology_slot);
    }
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

uint32_t NativeSimulationHost::ack_ideology_intents_in_worker(int64_t day) {
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    uint32_t acked = 0;
    while (!_ideology_intents.empty()) {
        if (_ideology_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) break;
        const RuntimeDomainIntent intent = _ideology_intents.front();
        _ideology_intents.pop_front();
        RuntimeDomainAck ack;
        // Ideology transitions address EFFECT, so the ACK must carry the
        // EFFECT domain tag even though no Effect instance is involved:
        // RuntimeIdeologyPodAuthority::apply_ack ignores every other domain.
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        ack.code = RuntimeDomainAckCode::OK;
        ack.request_id = intent.request_id != 0 ? intent.request_id
                                                : intent.source_id;
        ack.transaction_id = intent.source_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.effective_day = intent.effective_day;
        ack.producer_id = intent.producer_id;
        ack.sequence = intent.sequence;
        _ideology_acks.push_back(ack);
        ++acked;
    }
    (void)day;
    return acked;
}

bool NativeSimulationHost::execute_modifier_worker_stage(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeCommandPacket> &day_commands,
        bool effect_upstream_ok,
        RuntimeDomainAuthorityPlan *authority_plan,
        std::string &authority_error,
        std::string &error) {
    error.clear();
    std::vector<RuntimeModifierPodCommand> modifier_commands;
    modifier_commands.reserve(day_commands.size());
    for (const RuntimeCommandPacket &packet : day_commands) {
        RuntimeModifierPodCommand command;
        if (decode_modifier_packet(packet, command))
            modifier_commands.push_back(command);
    }

    // Effect POD upstream (F7/E8): when Effect stage succeeded with a non-empty
    // catalog, Modifier consumes those intents. SHADOW fixture intents are
    // stripped by the caller when upstream is active. ACTIVE with an empty
    // Effect catalog uses empty intents (no fixture).
    const std::vector<RuntimeDomainIntent> empty_intents;
    const std::vector<RuntimeDomainIntent> &intent_source =
        effect_upstream_ok ? _effect_day_modifier_intents
                           : (authority_plan != nullptr ? authority_plan->intents
                                                       : empty_intents);
    std::vector<RuntimeModifierPodCommand> modifier_intents;
    modifier_intents.reserve(intent_source.size());
    for (const RuntimeDomainIntent &intent : intent_source) {
        if (intent.target_domain !=
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
            continue;
        }
        RuntimeModifierPodCommand command;
        command.request_id =
            intent.request_id != 0 ? intent.request_id : intent.source_id;
        command.producer_id = intent.producer_id;
        command.sequence = intent.sequence;
        command.effective_day = intent.effective_day;
        command.requested_day = intent.effective_day;
        command.opcode = intent.opcode;
        command.domain = intent.payload[1] >= 0 && intent.payload[1] < 4
            ? static_cast<uint16_t>(intent.payload[1]) : 0;
        // Effect catalogs store the Modifier definition_key, not a dense id, in
        // command metadata. Resolve via key hash (with legacy payload[0] fallback).
        command.definition_id =
            resolve_modifier_definition_id_for_effect_intent(intent);
        command.entity_handle = intent.target_handle;
        command.target_generation = intent.target_generation;
        command.group_handle = intent.group_handle;
        command.modifier_handle = intent.modifier_handle;
        command.duration_days = intent.duration_days;
        command.stacks = intent.stacks > 0 ? intent.stacks : 1;
        command.magnitude_q16 = intent.magnitude_q16 > 0
            ? intent.magnitude_q16 : 65536;
        command.input_generation = input_generation;
        // Match EffectRuntime native adapter semantics (technology/family/person).
        // payload[2]==0 means "unset", not GLOBAL — defaulting to GLOBAL made
        // has_technology_effect miss ENTITY+TECH unique keys after a successful
        // apply, and wrong source_type blocked UNIQUE_SOURCE identity.
        if (command.domain == 1) {
            command.scope = 2; // ENTITY
            command.source_type = 0x54454348ULL; // TECH
            command.source_id = intent.source_id & 0xffffULL;
            command.magnitude_q16 = 65536;
        } else if (command.domain == 2) {
            command.scope = 1; // GROUP
            command.group_handle = intent.target_generation;
            command.source_type = 0x46414d494c59ULL; // FAMILY
            command.source_id = intent.target_handle;
        } else if (command.domain == 3) {
            command.scope = 2; // ENTITY
            command.source_type = 0x504552534f4eULL; // PERSON
            command.source_id = intent.source_id;
        } else if (intent.payload[2] >= 1 && intent.payload[2] <= 2) {
            command.scope = static_cast<int32_t>(intent.payload[2]);
            command.source_type = static_cast<uint64_t>(RuntimeDomainId::EFFECT);
            command.source_id = intent.source_id;
        } else {
            command.scope = 2;
            command.source_type = static_cast<uint64_t>(RuntimeDomainId::EFFECT);
            command.source_id = intent.source_id;
        }
        if (command.definition_id < 0) {
            static int s_def_left = 12;
            if (s_def_left-- > 0) {
                godot::UtilityFunctions::print(godot::vformat(
                    "[tech-ack-diag/modifier] definition_id unresolved "
                    "request=%d seq=%d domain=%d payload0=%d hashes=%d",
                    static_cast<int64_t>(command.request_id),
                    static_cast<int64_t>(command.sequence),
                    static_cast<int64_t>(command.domain),
                    static_cast<int64_t>(intent.payload[0]),
                    static_cast<int64_t>(
                        _modifier_definition_id_by_key_hash.size())));
            }
        }
        modifier_intents.push_back(command);
    }

    auto publish_fallback = [this](const char *reason) {
        size_t i = 0;
        for (; i + 1 < _modifier_pod_fallback_reason.size() &&
                reason != nullptr && reason[i] != '\0'; ++i) {
            _modifier_pod_fallback_reason[i].store(
                reason[i], std::memory_order_release);
        }
        for (; i < _modifier_pod_fallback_reason.size(); ++i) {
            _modifier_pod_fallback_reason[i].store(
                '\0', std::memory_order_release);
        }
    };

    // SHADOW may run the diagnostic domain runner without a Modifier POD
    // catalog. ACTIVE always requires the POD when this stage is invoked.
    if (!_modifier_pod_configured) {
        if (!modifier_commands.empty() || !modifier_intents.empty()) {
            error = "modifier_pod_not_configured";
            publish_fallback(error.c_str());
            _modifier_pod_ready.store(false, std::memory_order_release);
            if (authority_plan != nullptr) {
                _domain_authority_runner.discard_plan();
                if (authority_error.empty()) authority_error = error;
            }
            return false;
        }
        _modifier_pod_ready.store(false, std::memory_order_release);
        publish_fallback("modifier_pod_not_configured");
        if (authority_plan != nullptr) {
            return _domain_authority_runner.commit_day(
                *authority_plan, authority_error);
        }
        error = "modifier_pod_not_configured";
        return false;
    }

    bool modifier_ok = true;
    std::string modifier_error;
    RuntimeModifierPodSnapshot modifier_snapshot;
    RuntimeModifierPodReport modifier_report;
    std::vector<RuntimeDomainAck> modifier_acks;
    double modifier_plan_ms = 0.0;
    const auto plan_started = std::chrono::steady_clock::now();
    modifier_ok = _modifier_pod_authority.plan_day(
        day, input_generation, modifier_commands, modifier_intents,
        modifier_snapshot, modifier_acks, modifier_report, modifier_error);
    modifier_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_started).count();
    if (!modifier_ok) {
        static int s_mod_fail_left = 12;
        if (s_mod_fail_left-- > 0 && !modifier_intents.empty()) {
            godot::UtilityFunctions::print(godot::vformat(
                "[tech-ack-diag/modifier] plan_day FAILED day=%d intents=%d "
                "reason=%s def0=%d scope0=%d src_type0=%d",
                day, static_cast<int64_t>(modifier_intents.size()),
                godot::String(modifier_error.c_str()),
                static_cast<int64_t>(modifier_intents.front().definition_id),
                static_cast<int64_t>(modifier_intents.front().scope),
                static_cast<int64_t>(modifier_intents.front().source_type)));
        }
        _modifier_pod_authority.discard_plan();
    }

    bool authority_ok = true;
    if (modifier_ok) {
        if (effect_upstream_ok) {
            if (!modifier_acks.empty() &&
                !_effect_pod_authority.apply_acks(
                    modifier_acks, modifier_error)) {
                modifier_ok = false;
            } else {
                _effect_pod_ack_count.store(
                    static_cast<uint32_t>(modifier_acks.size()),
                    std::memory_order_release);
                _effect_pod_state_hash.store(
                    _effect_pod_authority.snapshot().deterministic_state_hash,
                    std::memory_order_release);
            }
        } else if (authority_plan != nullptr) {
            modifier_ok = _domain_authority_runner.accept_modifier_acks(
                *authority_plan, modifier_acks, modifier_error);
        }
    }

    uint32_t modifier_slot = 0;
    bool modifier_slot_reserved = false;
    if (modifier_ok) {
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
        modifier_ok = _modifier_pod_authority.commit_day(
            modifier_snapshot, modifier_error);
        if (modifier_ok && authority_plan != nullptr) {
            authority_ok = _domain_authority_runner.commit_day(
                *authority_plan, authority_error);
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
        if (authority_plan != nullptr) {
            _domain_authority_runner.discard_plan();
            if (authority_error.empty()) authority_error = modifier_error;
        }
    }
    if ((!modifier_ok || !authority_ok) && modifier_slot_reserved)
        _modifier_snapshots.release(modifier_slot);
    const double modifier_replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();

    const bool modifier_committed = modifier_ok && authority_ok;
    _modifier_pod_ready.store(modifier_committed, std::memory_order_release);
    _modifier_pod_plan_ms.store(modifier_plan_ms, std::memory_order_release);
    _modifier_pod_replay_ms.store(modifier_replay_ms, std::memory_order_release);
    _modifier_pod_work_units.store(modifier_report.work_units,
                                   std::memory_order_release);
    _modifier_pod_state_hash.store(
        modifier_committed ? modifier_snapshot.state_hash
                           : _modifier_pod_authority.snapshot().state_hash,
        std::memory_order_release);
    _modifier_pod_ack_count.store(
        modifier_committed ? static_cast<uint32_t>(modifier_acks.size()) : 0u,
        std::memory_order_release);
    const char *reason = modifier_committed ? "" :
        (modifier_error.empty() ? "modifier_pod_plan_failed"
                                : modifier_error.c_str());
    publish_fallback(reason);
    if (!modifier_committed) {
        error = reason;
        return false;
    }
    return true;
}


RuntimeCommandPacket make_effect_intent_events_packet(
        const RuntimeDomainIntent &intent, int64_t day) {
    RuntimeCommandPacket event_packet{};
    event_packet.envelope.request_id = intent.request_id != 0
        ? intent.request_id
        : (0xEFFE0000ull ^ static_cast<uint64_t>(intent.sequence));
    event_packet.envelope.producer_id = intent.producer_id != 0
        ? intent.producer_id : 77u;
    event_packet.envelope.sequence = intent.sequence != 0 ? intent.sequence : 1u;
    event_packet.envelope.requested_day = day;
    event_packet.envelope.effective_day =
        intent.effective_day >= 0 ? intent.effective_day : day;
    event_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    event_packet.envelope.opcode =
        static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
    std::vector<uint8_t> payload;
    payload.reserve(96u);
    const auto put_u32 = [&payload](uint32_t value) {
        for (int i = 0; i < 4; ++i)
            payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
    };
    const auto put_u64 = [&payload](uint64_t value) {
        for (int i = 0; i < 8; ++i)
            payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
    };
    const auto put_i32 = [&put_u32](int32_t value) {
        put_u32(static_cast<uint32_t>(value));
    };
    const auto put_i64 = [&put_u64](int64_t value) {
        put_u64(static_cast<uint64_t>(value));
    };
    const uint64_t idempotency =
        intent.idempotency_key != 0
            ? intent.idempotency_key
            : (intent.request_id != 0
                   ? intent.request_id
                   : (static_cast<uint64_t>(intent.producer_id) << 32) ^
                         static_cast<uint64_t>(intent.sequence) ^
                         static_cast<uint64_t>(intent.effective_day));
    put_u32(RUNTIME_EVENTS_ABI_VERSION);
    put_u32(1u);
    put_i64(event_packet.envelope.effective_day);
    put_i32(7); // effect transaction publication phase
    put_i32(900); // effect typed intent publication
    put_i32(4); // PK_EVENT_SOURCE_EFFECT
    put_i32(0);
    put_u64(intent.target_handle);
    put_i32(0);
    put_i32(0);
    put_i32(1);
    put_i64(static_cast<int64_t>(intent.request_id));
    put_i32(static_cast<int32_t>(intent.target_domain));
    put_i32(static_cast<int32_t>(intent.opcode));
    put_i32(0);
    put_i32(0);
    put_u64(idempotency);
    event_packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    if (payload.size() <= event_packet.payload.size())
        std::memcpy(event_packet.payload.data(), payload.data(), payload.size());
    return event_packet;
}

bool NativeSimulationHost::drain_effect_transport_queues(std::string &error) {
    error.clear();
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::deque<RuntimeEffectPodInstanceInput> instances;
    std::deque<EffectPodMetricQueueItem> metrics;
    std::deque<EffectPodRemoveQueueItem> removes;
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        instances.swap(_effect_instance_queue);
        metrics.swap(_effect_metric_queue);
        removes.swap(_effect_remove_queue);
        acks.assign(_effect_acks.begin(), _effect_acks.end());
        _effect_acks.clear();
    }

    auto restore_remaining =
        [this](std::deque<RuntimeEffectPodInstanceInput> &left,
               std::deque<EffectPodMetricQueueItem> &metrics_left,
               std::deque<EffectPodRemoveQueueItem> &removes_left) {
            std::lock_guard<std::mutex> lock(_effect_transport_mutex);
            while (!left.empty()) {
                _effect_instance_queue.push_front(left.back());
                left.pop_back();
            }
            while (!metrics_left.empty()) {
                _effect_metric_queue.push_front(metrics_left.back());
                metrics_left.pop_back();
            }
            while (!removes_left.empty()) {
                _effect_remove_queue.push_front(removes_left.back());
                removes_left.pop_back();
            }
        };

    while (!removes.empty()) {
        const EffectPodRemoveQueueItem item = removes.front();
        removes.pop_front();
        if (!_effect_pod_authority.remove_instance(item.instance_id,
                                                   item.generation, error)) {
            removes.push_front(item);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    while (!instances.empty()) {
        RuntimeEffectPodInstanceInput input = instances.front();
        instances.pop_front();
        // Queue may have waited across Effect soft-skips / climate parks.
        // Never-fired technology installs must land on the next plan day.
        const int64_t committed = _effect_pod_authority.snapshot().committed_day;
        if (committed >= 0 && input.next_due_day >= 0 &&
            input.next_due_day <= committed) {
            input.next_due_day = committed + 1;
        }
        if (!_effect_pod_authority.upsert_instance(input, error)) {
            instances.push_front(input);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    while (!metrics.empty()) {
        const EffectPodMetricQueueItem item = metrics.front();
        metrics.pop_front();
        if (!_effect_pod_authority.set_metric(
                item.instance_id, item.generation, item.metric_id,
                item.revision, item.value, error)) {
            metrics.push_front(item);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    if (!acks.empty() &&
        !_effect_pod_authority.apply_acks(acks, error)) {
        return false;
    }
    return true;
}

bool NativeSimulationHost::execute_effect_worker_stage(
        int64_t day, uint64_t input_generation, RuntimeDayCommit &commit,
        std::string &error) {
    (void)commit;
    error.clear();
    _effect_day_modifier_intents.clear();
    _effect_day_intents.clear();
    _effect_day_stage_ok = false;
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }

    if (!drain_effect_transport_queues(error)) return false;

    const auto plan_started = std::chrono::steady_clock::now();
    RuntimeEffectPodPlan plan;
    if (!_effect_pod_authority.plan_day(day, input_generation, plan, error)) {
        _effect_pod_authority.discard_plan();
        return false;
    }

    uint32_t emitted = 0;
    uint32_t modifier_targeted = 0;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        for (const RuntimeDomainIntent &intent : plan.intents) {
            if (_effect_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                _effect_pod_authority.discard_plan();
                error = "effect_intent_capacity_exceeded";
                return false;
            }
            _effect_intents.push_back(intent);
            _effect_day_intents.push_back(intent);
            ++emitted;
            if (intent.target_domain ==
                static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                _effect_day_modifier_intents.push_back(intent);
                ++modifier_targeted;
            }
        }
    }
    (void)modifier_targeted;

    const auto replay_started = std::chrono::steady_clock::now();
    if (!_effect_pod_authority.commit_day(plan, error)) {
        _effect_pod_authority.discard_plan();
        return false;
    }
    // After commit the transaction arena is published; resolve Modifier
    // definition ids so the same-day Modifier stage (and soft-skip reemit)
    // see a dense payload[0] even when the Effect catalog left it unset.
    for (RuntimeDomainIntent &intent : _effect_day_modifier_intents) {
        if (intent.payload[0] > 0) continue;
        const int32_t definition_id =
            resolve_modifier_definition_id_for_effect_intent(intent);
        if (definition_id >= 0) intent.payload[0] = definition_id;
    }
    for (RuntimeDomainIntent &intent : _effect_day_intents) {
        if (intent.target_domain !=
                static_cast<uint16_t>(RuntimeDomainId::MODIFIER) ||
            intent.payload[0] > 0) {
            continue;
        }
        const int32_t definition_id =
            resolve_modifier_definition_id_for_effect_intent(intent);
        if (definition_id >= 0) intent.payload[0] = definition_id;
    }
    // PUBLISH_EVENT (technology.adopted) is published by the Events stage but
    // never ACKed there. Settle the Events bit in-worker so technology fire
    // does not wait on the main-thread Effect pump.
    ack_effect_events_intents_in_worker(_effect_day_intents);
    const double replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();
    const RuntimeEffectPodSnapshot &snapshot = _effect_pod_authority.snapshot();
    _effect_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _effect_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _effect_pod_state_hash.store(snapshot.deterministic_state_hash,
                                 std::memory_order_release);
    _effect_pod_snapshot_generation.store(snapshot.generation,
                                          std::memory_order_release);
    _effect_pod_intent_count.store(emitted, std::memory_order_release);
    // ACKs are applied at the top of this stage via drain_effect_transport_queues.
    _effect_pod_ack_count.store(0u, std::memory_order_release);
    // F8: publish immutable snapshot for main-thread EffectRuntime write-back.
    uint32_t effect_slot = 0;
    if (_effect_snapshots.try_begin_write(effect_slot)) {
        _effect_snapshots.write_buffer(effect_slot) = snapshot;
        _effect_snapshots.publish(effect_slot);
    }
    _effect_day_stage_ok = true;
    return true;
}

RuntimeDayCommit NativeSimulationHost::execute_day_plan(
        RuntimeDayPlan &plan,
        const RuntimeEnvironmentSnapshot *environment,
        const std::vector<RuntimeCommandPacket> &day_commands,
        std::vector<RuntimeCommandReceipt> &day_receipts,
        uint64_t admitted_submit_order) {
    RuntimeDayCommit commit;
    if (try_fault_injection("day.plan.before")) {
        commit.preflight_ok = 0;
        return commit;
    }
    _pod_visual_intents.clear();
    // INPUT_CAPTURE is a real freeze boundary, not merely a validation bit.
    // Capture only an input that belongs to this exact sealed day. A stale or
    // future frame must never replace the last accepted manifest before the
    // stage has had a chance to reject it.
    const auto capture_input_manifest = [&](const RuntimeEnvironmentSnapshot &accepted) {
        const uint64_t prior_generation =
            _input_capture_generation.load(std::memory_order_relaxed);
        const int64_t prior_day =
            _input_capture_day.load(std::memory_order_relaxed);
        if (prior_generation == accepted.generation &&
            prior_day == accepted.day) {
            _input_capture_reused.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        {
            RuntimeInputCaptureManifest manifest{};
            manifest.session_epoch = _country_worker_session_epoch;
            manifest.input_generation = accepted.generation;
            manifest.effective_day = accepted.day;
            manifest.map_generation = accepted.topology_generation;
            manifest.country_generation = _country_read_view_generation;
            manifest.building_generation = accepted.vision_revision;
            manifest.resource_generation = _economy_pod_input_generation.load(
                std::memory_order_relaxed);
            manifest.catalog_hash = accepted.climate_catalog_hash;
            manifest.command_watermark = admitted_submit_order;
            uint64_t manifest_hash = RuntimeClimateKernel::input_hash(accepted);
            manifest_hash = mix_hash(manifest_hash, manifest.session_epoch);
            manifest_hash = mix_hash(manifest_hash, manifest.input_generation);
            manifest_hash = mix_hash(manifest_hash, static_cast<uint64_t>(manifest.effective_day));
            manifest_hash = mix_hash(manifest_hash, manifest.map_generation);
            manifest_hash = mix_hash(manifest_hash, manifest.country_generation);
            manifest_hash = mix_hash(manifest_hash, manifest.building_generation);
            manifest_hash = mix_hash(manifest_hash, manifest.resource_generation);
            manifest_hash = mix_hash(manifest_hash, manifest.catalog_hash);
            manifest_hash = mix_hash(manifest_hash, manifest.command_watermark);
            manifest.input_hash = manifest_hash;
            manifest.frozen = 1;
            manifest.validated = accepted.topology_validated ? 1 : 0;
            _input_manifest = manifest;
            _input_capture_generation.store(accepted.generation,
                                            std::memory_order_relaxed);
            _input_capture_day.store(accepted.day, std::memory_order_relaxed);
            _input_capture_hash.store(manifest_hash, std::memory_order_relaxed);
            _input_capture_count.fetch_add(1, std::memory_order_relaxed);
        }
    };
    // Returns false only on a hard Events plan/commit failure. "Disabled" and
    // "already processed this host day" are true: an I8 ACTIVE Events stage
    // soft-completes on them so the shared grant is not held hostage by a
    // diagnostic mirror with no work.
    // GAMEPLAY_EFFECT produces typed Events commands inside the same sealed
    // worker day. They are private until the subsequent EVENTS stage commits.
    std::vector<RuntimeCommandPacket> gameplay_event_commands;
    const auto run_events_probe = [&](int64_t event_day) -> bool {
        if (!_events_probe_enabled.load(std::memory_order_acquire) ||
            _events_last_processed_day >= event_day) {
            return true;
        }
        RuntimeEventsSnapshot events_snapshot;
        RuntimeEventsReport events_report;
        std::string events_error;
        // RuntimeEventsAuthority owns its receipt vector. Keep that vector
        // separate from the host's ordinary command receipts: plan_day()
        // intentionally clears its output before replaying Events commands.
        std::vector<RuntimeCommandReceipt> event_receipts;
        const auto events_plan_started = std::chrono::steady_clock::now();
        const std::vector<RuntimeCommandPacket> *event_inputs = &day_commands;
        std::vector<RuntimeCommandPacket> merged_event_inputs;
        if (!gameplay_event_commands.empty()) {
            merged_event_inputs.reserve(day_commands.size() +
                                        gameplay_event_commands.size());
            merged_event_inputs.insert(merged_event_inputs.end(),
                                       day_commands.begin(), day_commands.end());
            merged_event_inputs.insert(merged_event_inputs.end(),
                                       gameplay_event_commands.begin(),
                                       gameplay_event_commands.end());
            event_inputs = &merged_event_inputs;
        }
        bool events_ok = true;
        if (try_fault_injection("events.append.before")) {
            events_ok = false;
            events_error = "events_append_fault_injected_before";
        } else {
            events_ok = _events_authority.plan_day(
                event_day, *event_inputs, events_snapshot, event_receipts,
                events_report, events_error);
        }
        const double events_plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - events_plan_started).count();
        double events_replay_ms = 0.0;
        if (events_ok) {
            if (try_fault_injection("events.append.after")) {
                events_ok = false;
                events_error = "events_append_fault_injected_after";
                _events_authority.discard_plan();
            }
        }
        if (events_ok) {
            if (try_fault_injection("events.commit.before")) {
                events_ok = false;
                events_error = "events_commit_fault_injected_before";
                _events_authority.discard_plan();
            } else {
                const auto events_replay_started = std::chrono::steady_clock::now();
                events_ok = _events_authority.commit_day(events_snapshot, events_error);
                events_replay_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - events_replay_started).count();
                if (events_ok && try_fault_injection("events.commit.after")) {
                    events_ok = false;
                    events_error = "events_commit_fault_injected_after";
                }
            }
        } else {
            _events_authority.discard_plan();
        }
        const bool events_authoritative =
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u;
        // Probe mode records a rejected attempt once. Authority mode must retry
        // the same sealed day and cannot advance its watermark on failure.
        if (events_ok || !events_authoritative)
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
        if (!events_ok) return false;
        uint32_t events_slot = 0;
        if (_events_snapshots.try_begin_write(events_slot)) {
            _events_snapshots.write_buffer(events_slot) = _events_authority.snapshot();
            _events_snapshots.publish(events_slot);
        } else {
            _events_pod_ready.store(false, std::memory_order_release);
        }
        return true;
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
        // Climate 日以 trace/environment 为准，不是 plan.context.day。
        // 后者是 worker 时钟 `_committed_day + 1`；第一帧常见情况是生成期
        // environment.day=0，而 worker 已经在计划 day=1。ACTIVE 路径已经按
        // environment.day 对齐；SHADOW 冷启动若把 store.committed_day 写成计划日，
        // 下一帧真正的 plan_day 会撞上 climate_day_not_monotonic，Climate barrier
        // 永久失败，Country 对拍永远进不去。
        const int64_t climate_day = climate_environment != nullptr
            ? climate_environment->day : -1;
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
                    climate_day, *trace_frame.reference_store,
                    *climate_environment, climate_report)) {
                runtime_copy_text(climate_report.parity_reason,
                                  "climate_cold_start_baseline");
                // 日对齐时，这一天的生产态就是基线，可以放行 worker 日。
                // 日错位时只收基线、不放行：让下一轮再吃匹配帧，避免跳过该日的
                // Climate 对拍，也避免 Country 在 Climate 还没算到计划日时前进。
                climate_ok = (climate_day == plan.context.day);
            } else {
                if (climate_report.error[0] == '\0') {
                    runtime_copy_text(climate_report.error,
                                      "climate_cold_start_baseline_failed");
                }
                climate_ok = false;
            }
            if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                             "[climate][boundary] cold-start env_day=%lld plan_day=%lld "
                             "ok=%d ref_hash=%llu adopted_parity=%llu round_ran=%d\n",
                             static_cast<long long>(climate_day),
                             static_cast<long long>(plan.context.day), climate_ok ? 1 : 0,
                             static_cast<unsigned long long>(trace_frame.reference_state_hash),
                             static_cast<unsigned long long>(
                                 _climate_authority.store().parity_hash()),
                             climate_environment->climate_round_ran ? 1 : 0);
                std::fflush(stderr);
            }
            _climate_pod_parity_compared.store(false, std::memory_order_release);
            _climate_pod_parity_matched.store(false, std::memory_order_release);
            _climate_parity_day.store(climate_day, std::memory_order_release);
            for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
                _climate_pod_parity_reason[i].store(
                    climate_report.parity_reason[i], std::memory_order_release);
                if (climate_report.parity_reason[i] == '\0') break;
            }
        } else if (climate_environment != nullptr) {
            if (climate_day != plan.context.day) {
                std::memset(&climate_report, 0, sizeof(climate_report));
                runtime_copy_text(climate_report.error,
                                  "climate_environment_day_mismatch");
                climate_ok = false;
                if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                    std::fprintf(stderr,
                                 "[climate][boundary] day=%lld env_day=%lld planned=0 "
                                 "compared=0 matched=0 err=climate_environment_day_mismatch\n",
                                 static_cast<long long>(plan.context.day),
                                 static_cast<long long>(climate_day));
                    std::fflush(stderr);
                }
            } else {
            const bool climate_planned = _climate_authority.plan_day(
                climate_day, *climate_environment, climate_report,
                /*compute_hashes=*/true, /*validate_input=*/false);
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
                             static_cast<long long>(climate_day), climate_planned ? 1 : 0,
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
                    diff.day = climate_day;
                    // The full per-field fold is what the divergence matrix is
                    // built from; the first difference alone would only ever
                    // name the earliest field in table order.
                    accumulate_climate_parity_fields(
                        climate_day, *trace_frame.reference_store,
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
                                         static_cast<long long>(climate_day), diff.field,
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
                        climate_day, *trace_frame.reference_store,
                        climate_report);
                    _climate_parity_forced_days.fetch_add(1,
                                                          std::memory_order_relaxed);
                    if (!climate_ok && climate_report.error[0] == '\0') {
                        runtime_copy_text(climate_report.error,
                                          "climate_forced_commit_failed");
                    }
                    if (climate_ok) {
                        _climate_committed_day.store(climate_day,
                                                     std::memory_order_release);
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
                        climate_day, *trace_frame.reference_store,
                        _climate_authority.planned_store());
                }
                // Only a matching next-state hash may cross the commit
                // boundary. The kernel's plan hash is identical to the
                // committed hash because commit only swaps the two lanes.
                climate_ok = _climate_authority.commit_day(
                    climate_day, climate_report);
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
                    // B8 P0：SHADOW 也推进交付游标。诊断报告里的
                    // climate_committed_day 不能只在 ACTIVE 下有意义，否则
                    // 同一份 CSV 在两种模式间不可比。
                    _climate_committed_day.store(climate_day,
                                                 std::memory_order_release);
                }
            }
            }
            for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
                _climate_pod_parity_reason[i].store(climate_report.parity_reason[i],
                                                    std::memory_order_release);
                if (climate_report.parity_reason[i] == '\0') break;
            }
            _climate_pod_reference_hash.store(trace_frame.reference_state_hash,
                                               std::memory_order_release);
            _climate_parity_day.store(climate_day, std::memory_order_release);
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
        // 停在 barrier（缺帧 / future / 日错位）时不要把上一帧已经提交的
        // climate_pod_state_hash 和 stage 诊断写成 0。worker 会立刻重试同一日，
        // 主线程读到的就会是“Climate 从未跑过”。
        const bool climate_diagnostics_fresh =
            climate_cold_start ||
            (climate_environment != nullptr && climate_day == plan.context.day);
        if (climate_diagnostics_fresh) {
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
            _climate_production_stage_mask.store(climate_report.production_stage_mask,
                                                std::memory_order_release);
            _climate_worker_stage_mask.store(climate_report.worker_stage_mask,
                                            std::memory_order_release);
            _climate_cyclone_alive.store(climate_report.cyclone_alive,
                                         std::memory_order_release);
            _climate_cyclone_injected.store(climate_report.cyclone_injected,
                                            std::memory_order_release);
            _climate_cyclone_replaced.store(climate_report.cyclone_replaced,
                                            std::memory_order_release);
            _climate_cyclone_decayed.store(climate_report.cyclone_decayed,
                                           std::memory_order_release);
            _climate_cyclone_touched.store(climate_report.cyclone_touched,
                                           std::memory_order_release);
        }
        for (size_t i = 0; i < _climate_pod_fallback_reason.size(); ++i) {
            _climate_pod_fallback_reason[i].store(climate_report.error[i],
                                                  std::memory_order_release);
            if (climate_report.error[i] == '\0') break;
        }

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
                static std::atomic<int> s_country_boundary_errors_left{8};
                if (s_country_boundary_errors_left.fetch_sub(
                        1, std::memory_order_relaxed) > 0) {
                    std::fprintf(stderr,
                                 "[country][boundary] day=%lld failed=%s "
                                 "climate_day=%lld input_generation=%llu\n",
                                 static_cast<long long>(plan.context.day),
                                 country_error.empty() ? "country_worker_stage_pending" :
                                     country_error.c_str(),
                                 static_cast<long long>(climate_day),
                                 static_cast<unsigned long long>(
                                     diagnostic_context.input_generation));
                    std::fflush(stderr);
                }
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
        // This whole block is SHADOW-only; G8 ACTIVE Ideology runs from the
        // stage loop below, where a failure isolates the domain instead of
        // being folded into the Climate/Country diagnostic chain.
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

        // F7 SHADOW Effect stage. Runs after Ideology and before Modifier so
        // real Effect POD intents can replace diagnostic run_effect fixtures
        // as the Modifier upstream. An empty cold-start catalog does not enable
        // the stage, so Modifier E7 keeps its fixture upstream until a real
        // Effect catalog is configured. Failure is diagnostic only and never
        // stalls Climate/Country or grants EFFECT ACTIVE authority.
        std::string effect_error;
        bool effect_ok = false;
        const bool effect_stage_enabled =
            _effect_pod_configured && !_effect_pod_catalog.definitions.empty();
        if (effect_stage_enabled) {
            effect_ok = execute_effect_worker_stage(
                plan.context.day, diagnostic_context.input_generation,
                commit, effect_error);
        } else {
            _effect_day_modifier_intents.clear();
            _effect_day_stage_ok = false;
            effect_error = _effect_pod_configured
                ? "effect_pod_catalog_empty" : "effect_pod_not_configured";
        }
        _effect_pod_ready.store(effect_ok, std::memory_order_release);
        const char *effect_reason = effect_ok ? "" :
            (effect_error.empty() ? "effect_pod_plan_failed" :
                                    effect_error.c_str());
        size_t effect_reason_index = 0;
        for (; effect_reason_index + 1 < _effect_pod_fallback_reason.size() &&
               effect_reason[effect_reason_index] != '\0';
             ++effect_reason_index) {
            _effect_pod_fallback_reason[effect_reason_index].store(
                effect_reason[effect_reason_index], std::memory_order_release);
        }
        for (; effect_reason_index < _effect_pod_fallback_reason.size();
             ++effect_reason_index) {
            _effect_pod_fallback_reason[effect_reason_index].store(
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
                // F7/E8: Effect POD upstream when catalog is non-empty and the
                // Effect stage succeeded. Strip fixture MODIFIER intents so the
                // domain-runner ACK barrier does not wait on a second Effect
                // writer. Empty cold-start catalogs keep fixture upstream for
                // Modifier E7.
                const bool use_effect_pod_upstream =
                    effect_stage_enabled && _effect_day_stage_ok;
                if (use_effect_pod_upstream) {
                    std::vector<RuntimeDomainIntent> retained_intents;
                    retained_intents.reserve(authority_plan.intents.size());
                    for (const RuntimeDomainIntent &intent : authority_plan.intents) {
                        if (intent.target_domain ==
                            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                            continue;
                        }
                        retained_intents.push_back(intent);
                    }
                    authority_plan.intents.swap(retained_intents);
                    authority_plan.ack_required_mask &=
                        ~runtime_domain_mask(RuntimeDomainId::MODIFIER);
                }
                std::string modifier_error;
                const auto modifier_started = std::chrono::steady_clock::now();
                const bool modifier_ok = execute_modifier_worker_stage(
                    plan.context.day, diagnostic_context.input_generation,
                    day_commands, use_effect_pod_upstream, &authority_plan,
                    authority_error, modifier_error);
                authority_ok = modifier_ok;
                authority_replay_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - modifier_started).count();
                if (!modifier_ok && authority_error.empty())
                    authority_error = modifier_error;
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
            const RuntimeEconomyReplayReport &economy_replay =
                _domain_authority_runner.economy_replay_report();
            _economy_replay_completed_stage_mask.store(
                economy_replay.completed_stage_mask, std::memory_order_release);
            _economy_replay_stage_cursor.store(
                economy_replay.stage_cursor, std::memory_order_release);
            _economy_replay_input_hash.store(
                economy_replay.input_hash, std::memory_order_release);
            _economy_replay_base_hash.store(
                economy_replay.base_hash, std::memory_order_release);
            _economy_replay_next_hash.store(
                economy_replay.next_hash, std::memory_order_release);
            for (size_t i = 0; i < RuntimeEconomyReplayReport::STAGE_COUNT; ++i) {
                _economy_replay_stage_hash[i].store(
                    economy_replay.stage_hash[i], std::memory_order_release);
                _economy_replay_stage_work[i].store(
                    economy_replay.stage_work[i], std::memory_order_release);
                _economy_replay_stage_ms[i].store(
                    economy_replay.stage_ms[i], std::memory_order_release);
            }
            _economy_replay_input_captured.store(
                economy_replay.input_captured != 0, std::memory_order_release);
            _economy_replay_committed.store(
                economy_replay.committed != 0, std::memory_order_release);
            _economy_replay_parity_ready.store(
                economy_replay.parity_ready != 0, std::memory_order_release);
            for (size_t i = 0; i < _economy_replay_fallback_reason.size(); ++i) {
                _economy_replay_fallback_reason[i].store(
                    economy_replay.fallback_reason[i], std::memory_order_release);
                if (economy_replay.fallback_reason[i] == '\0') break;
            }
            // Dedicated Economy SHADOW stage handler (J2-B). Replays the same
            // epoch contract through RuntimeEconomyPodAuthority; does not grant
            // ACTIVE mask.
            if (economy_parity_shadow_enabled()) {
                std::string economy_stage_error;
                const uint32_t economy_cells =
                    climate_environment != nullptr
                        ? climate_environment->cell_count : 0u;
                const uint64_t economy_catalog =
                    climate_environment != nullptr
                        ? climate_environment->generation : 0u;
                const uint64_t economy_country_generation =
                    country_snapshot != nullptr ? country_snapshot->generation : 0u;
                if (economy_cells > 0u) {
                    (void)execute_economy_worker_stage(
                        diagnostic_context.day,
                        diagnostic_context.input_generation, economy_cells,
                        economy_country_generation, economy_catalog,
                        economy_stage_error);
                }
            }
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
        RuntimeEconomyPodSnapshot economy_snapshot;
        _pod_pipeline.snapshot_economy(economy_snapshot);
        _economy_pod_ready.store(
            pipeline_report.domains[static_cast<size_t>(RuntimeDomainId::ECONOMY) - 1u].completed != 0,
            std::memory_order_release);
        _economy_pod_committed.store(economy_snapshot.committed,
                                     std::memory_order_release);
        _economy_pod_authority_ready.store(economy_snapshot.authority_ready,
                                            std::memory_order_release);
        _economy_pod_committed_day.store(economy_snapshot.committed_day,
                                         std::memory_order_release);
        _economy_pod_epoch_sample_day.store(economy_snapshot.epoch_sample_day,
                                            std::memory_order_release);
        _economy_pod_generation.store(economy_snapshot.generation,
                                       std::memory_order_release);
        _economy_pod_state_hash.store(economy_snapshot.state_hash,
                                      std::memory_order_release);
        _economy_pod_input_generation.store(economy_snapshot.input_generation,
                                            std::memory_order_release);
        _economy_pod_country_generation.store(economy_snapshot.country_generation,
                                              std::memory_order_release);
        _economy_pod_completed_stage_mask.store(economy_snapshot.completed_stage_mask,
                                                std::memory_order_release);
        _economy_pod_pending_outbox.store(economy_snapshot.pending_outbox,
                                          std::memory_order_release);
        _economy_pod_pending_inbox.store(economy_snapshot.pending_inbox,
                                         std::memory_order_release);
        _economy_pod_operation_gate_mask.store(economy_snapshot.operation_gate_mask,
                                               std::memory_order_release);
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
        // 与 build_day_plan 使用同一不可变输入，重试不能重新读取 latest。
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
        // Only drop ring slots the worker has truly finished with. Popping a
        // future day while the Host clock is pinned (later domain failed M5
        // after Climate already committed) permanently desyncs 0xFFF grants:
        // the original env is gone and every newer publish mismatches forever.
        bool consume_environment = false;
        // Holds a refreshed ring head after drain so `environment` never dangles.
        std::shared_ptr<const RuntimeEnvironmentSnapshot> environment_holder;
        if (plan.context.day <= climate_committed) {
            // Idempotent retry: Climate already advanced this worker day (or
            // past it) before a later domain failed the atomic COMMIT gate.
            // Reuse without requiring the original env generation — Country
            // has the same shape via committed_day skip.
            active_climate_ok = true;
            // Drop every env Climate has already absorbed. A full ring of
            // day<=committed leftovers (or a single stale head under newer
            // publishes) otherwise nails WorldClock on
            // climate_input_capacity_day_barrier while this day retries peers.
            const size_t drained =
                _environment_ring.pop_while_day_at_most(climate_committed);
            if (drained > 0u) {
                environment_holder = _environment_ring.peek_oldest();
                environment = environment_holder.get();
                _climate_wait_cv.notify_all();
            }
            if (environment != nullptr && environment->day <= plan.context.day) {
                consume_environment = true;
            }
        } else if (environment == nullptr) {
            runtime_copy_text(climate_report.error, "climate_environment_missing");
        } else if (plan.context.day != climate_day ||
                   plan.context.input_generation != environment->generation) {
            runtime_copy_text(climate_report.error,
                              "climate_environment_day_mismatch");
            // Stale only. Keep newer days queued for when the worker advances.
            if (climate_day < plan.context.day) {
                consume_environment = true;
            }
        } else if (climate_day == climate_committed &&
                   environment->generation == _climate_committed_input_generation.load(
                       std::memory_order_acquire)) {
            // Country/Effect continuation 重试只复用同日同代成功提交，不重跑 Climate。
            active_climate_ok = true;
            consume_environment = true;
        } else if (climate_day <= climate_committed) {
            runtime_copy_text(climate_report.error, "climate_input_commit_mismatch");
            consume_environment = true;
        } else if (_climate_authority.plan_day(climate_day, *environment,
                                               climate_report,
                                               /*compute_hashes=*/false,
                                               /*validate_input=*/false)) {
            climate_day_computed = true;
            active_climate_ok = _climate_authority.commit_day(climate_day,
                                                              climate_report);
            if (active_climate_ok) {
                _climate_committed_input_generation.store(environment->generation,
                                                          std::memory_order_release);
                _climate_committed_day.store(climate_day,
                                             std::memory_order_release);
                consume_environment = true;
            } else {
                _climate_authority.discard_plan();
                // Keep the matching env for an immediate kernel retry.
            }
        } else {
            climate_day_computed = true;
            _climate_authority.discard_plan();
            // Plan rejected the matching frame; keep it so a corrected retry
            // (or diagnostic) can still observe the same generation.
        }
        // B8 P0：消费游标只在真正处理完该代输入时前进。提前弹出未来日会让
        // 主线程以为已送达，worker 却永远对不上 pinned 的 plan.day。
        if (environment != nullptr && consume_environment) {
            _climate_consumed_generation.store(environment->generation,
                                               std::memory_order_release);
            // B8 P3：FIFO 弹出已评估的最旧输入，给主线程腾出 ring 空位。
            _environment_ring.pop_generation(environment->generation);
            // 只有"第一次看到这一代"才算消费了一天；失败/挂起天的重试会反复评估
            // 同一份环境，把它们计数会把 delivered 指标变成重试计数器。
            uint64_t last_counted =
                _climate_last_counted_generation.load(std::memory_order_relaxed);
            while (environment->generation > last_counted &&
                   !_climate_last_counted_generation.compare_exchange_weak(
                       last_counted, environment->generation,
                       std::memory_order_relaxed)) {
            }
            if (environment->generation > last_counted) {
                _environment_consumed_days.fetch_add(1,
                                                     std::memory_order_relaxed);
            }
            // 等待方在 _climate_wait_cv 上等这个游标，必须显式唤醒。用专用 CV：
            // _control_cv 上还挂着 worker 自己的 preflight 重试等待。
            _climate_wait_cv.notify_all();
        }
        if (climate_day_computed) {
            if (!active_climate_ok) {
                set_fault(climate_report.error[0] != '\0'
                    ? climate_report.error : "climate_commit_failed");
            }
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
            _climate_cyclone_alive.store(climate_report.cyclone_alive,
                                         std::memory_order_release);
            _climate_cyclone_injected.store(climate_report.cyclone_injected,
                                            std::memory_order_release);
            _climate_cyclone_replaced.store(climate_report.cyclone_replaced,
                                            std::memory_order_release);
            _climate_cyclone_decayed.store(climate_report.cyclone_decayed,
                                           std::memory_order_release);
            _climate_cyclone_touched.store(climate_report.cyclone_touched,
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

    RuntimeDomainId previous_domain = RuntimeDomainId::INPUT_CAPTURE;
    bool previous_domain_valid = false;
    for (uint32_t i = 0; i < plan.stage_count; ++i) {
        RuntimeDomainPlan &stage = plan.stages[i];
        if (previous_domain_valid) {
            char after_point[72];
            std::snprintf(after_point, sizeof(after_point), "%s.plan.after",
                          runtime_domain_fault_tag(previous_domain));
            if (try_fault_injection(after_point)) {
                commit.preflight_ok = 0;
                return commit;
            }
        }
        {
            char before_point[72];
            std::snprintf(before_point, sizeof(before_point), "%s.plan.before",
                          runtime_domain_fault_tag(stage.domain));
            if (try_fault_injection(before_point)) {
                commit.preflight_ok = 0;
                return commit;
            }
        }
        previous_domain = stage.domain;
        previous_domain_valid = true;
        if (stage.domain == RuntimeDomainId::INPUT_CAPTURE &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE)) != 0u) {
            // M4/M5: INPUT_CAPTURE owns the immutable manifest for the whole
            // sealed day.  A missing, stale, or malformed frame parks the
            // day before any downstream domain can publish a partial result.
            std::string input_error;
            const bool input_ok = environment != nullptr &&
                environment->generation == plan.context.input_generation &&
                environment->day == plan.context.day &&
                validate_runtime_environment_snapshot(*environment, input_error);
            if (!input_ok) {
                stage.completed = 0;
                commit.preflight_ok = 0;
                commit.continuation_pending = 1;
                continue;
            }
            capture_input_manifest(*environment);
            stage.work_units = 1;
            stage.completed = 1;
            commit.work_units += stage.work_units;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE);
            ++commit.completed_stage_count;
            _active_evidence_mask.fetch_or(
                runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE),
                std::memory_order_release);
            continue;
        }
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
                const int64_t country_committed =
                    _country_pod_authority.committed_day();
                // Country packets behind the POD committed day are no longer
                // rejected here: execute_country_worker_stage reschedules them
                // onto the day it is planning. A player stamps effective_day
                // from the UI clock, which trails the worker clock at high
                // speed, so dropping them silently discarded research/tax
                // intents. Only malformed packets can still be terminal-ed,
                // and that happens inside the stage.
                (void)country_committed;
                // Country POD advances its committed_day as soon as the stage
                // succeeds (including commit_rejected_day). A later domain can
                // still fail the whole day and force a Host retry of the same
                // day index. Treat an already-committed Country day as an
                // idempotent success so the retry is not stuck forever on
                // country_day_not_contiguous.
                if (plan.context.day <= country_committed) {
                    stage.completed = 1;
                    commit.completed_domain_mask |=
                        runtime_domain_mask(RuntimeDomainId::COUNTRY);
                    ++commit.completed_stage_count;
                    _country_pod_ready.store(true, std::memory_order_release);
                    continue;
                }
                // Mirror SHADOW's climate_ok gate. Under ACTIVE Climate parks
                // when the worker clock outruns the published environment; if
                // Country still commits that day, the day then fails
                // preflight and the retry dies on country_day_not_contiguous.
                if (climate_authority_requested && !active_climate_ok) {
                    stage.completed = 0;
                    continue;
                }
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
                    _country_pod_ready.store(true, std::memory_order_release);
                } else {
                    _country_pod_ready.store(false, std::memory_order_release);
                    const char *reason = country_error.empty()
                        ? "country_worker_stage_pending" : country_error.c_str();
                    for (size_t i = 0; i + 1 < _country_pod_fallback_reason.size();
                         ++i) {
                        _country_pod_fallback_reason[i].store(
                            reason[i], std::memory_order_release);
                        if (reason[i] == '\0') break;
                    }
                    _country_pod_fallback_reason[
                        _country_pod_fallback_reason.size() - 1]
                        .store('\0', std::memory_order_release);
                    static std::atomic<int> s_active_country_errors_left{8};
                    if (s_active_country_errors_left.fetch_sub(
                            1, std::memory_order_relaxed) > 0) {
                        std::fprintf(stderr,
                                     "[country][active] day=%lld failed=%s "
                                     "input_generation=%llu\n",
                                     static_cast<long long>(plan.context.day),
                                     reason,
                                     static_cast<unsigned long long>(
                                         plan.context.input_generation));
                        std::fflush(stderr);
                    }
                    if (country_error == "country_worker_peer_results_pending" ||
                        country_error == "country_peer_results_pending" ||
                        country_error == "country_economy_asset_results_pending") {
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
        if (stage.domain == RuntimeDomainId::TRIGGER_INPUT &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u) {
            // H7 ACTIVE Trigger stage. It sits between Country and Ideology in
            // the stage order, so this day's effect intents are available to the
            // Effect stage's in-worker ACK drain below. Park with Climate like
            // Country/Ideology/Effect/Modifier.
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            const uint32_t dirty_before = commit.dirty_families;
            const uint64_t work_before = commit.work_units;
            std::string trigger_error;
            const bool trigger_ok = execute_trigger_worker_stage(
                plan.context.day, plan.context.input_generation, commit,
                trigger_error);
            _trigger_pod_ready.store(trigger_ok, std::memory_order_release);
            const char *trigger_reason = trigger_ok ? "" :
                (trigger_error.empty() ? "trigger_pod_plan_failed"
                                       : trigger_error.c_str());
            size_t trigger_reason_index = 0;
            for (; trigger_reason_index + 1 <
                       _trigger_pod_fallback_reason.size() &&
                   trigger_reason[trigger_reason_index] != '\0';
                 ++trigger_reason_index) {
                _trigger_pod_fallback_reason[trigger_reason_index].store(
                    trigger_reason[trigger_reason_index],
                    std::memory_order_release);
            }
            for (; trigger_reason_index < _trigger_pod_fallback_reason.size();
                 ++trigger_reason_index) {
                _trigger_pod_fallback_reason[trigger_reason_index].store(
                    '\0', std::memory_order_release);
            }
            // Soft-complete input-not-ready failures so the shared grant is not
            // held hostage by Trigger. An incomplete ACK barrier is the normal
            // first-visit outcome for a firing day: the intents were published
            // above, the Effect stage ACKs them, and the next visit commits the
            // same replayed plan. ready stays false and the fallback reason
            // keeps the diagnosis. Hard kernel/command failures still isolate.
            const bool trigger_soft =
                !trigger_ok &&
                (trigger_error == "trigger_pod_not_configured" ||
                 trigger_error == "trigger_pod_not_bootstrapped" ||
                 trigger_error == "ack_barrier_incomplete" ||
                 trigger_error == "ack_retry" ||
                 trigger_error == "stale_generation" ||
                 trigger_error == "ack_rejected");
            if (trigger_ok || trigger_soft) {
                if (trigger_ok) {
                    stage.dirty_families =
                        (commit.dirty_families | dirty_before) &
                        RUNTIME_DIRTY_EVENTS;
                    stage.work_units = commit.work_units >= work_before
                        ? commit.work_units - work_before : 0;
                }
                stage.completed = 1;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT);
                ++commit.completed_stage_count;
            } else {
                stage.completed = 0;
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::IDEOLOGY &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u) {
            // G8 ACTIVE Ideology stage. It runs before Effect in the stage
            // order, so this day's transition intents are still available to
            // the in-worker ACK bridge below. Park with Climate like
            // Country/Effect/Modifier.
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            std::string ideology_error;
            const bool ideology_ok = execute_ideology_worker_stage(
                plan.context.day, commit, ideology_error);
            _ideology_pod_ready.store(ideology_ok, std::memory_order_release);
            const char *ideology_reason = ideology_ok ? "" :
                (ideology_error.empty() ? "ideology_pod_plan_failed"
                                        : ideology_error.c_str());
            size_t ideology_reason_index = 0;
            for (; ideology_reason_index + 1 <
                       _ideology_pod_fallback_reason.size() &&
                   ideology_reason[ideology_reason_index] != '\0';
                 ++ideology_reason_index) {
                _ideology_pod_fallback_reason[ideology_reason_index].store(
                    ideology_reason[ideology_reason_index],
                    std::memory_order_release);
            }
            for (; ideology_reason_index <
                       _ideology_pod_fallback_reason.size();
                 ++ideology_reason_index) {
                _ideology_pod_fallback_reason[ideology_reason_index].store(
                    '\0', std::memory_order_release);
            }
            // Soft-complete input-not-ready failures so Climate|Country|
            // Effect|Modifier grant is not held hostage by Ideology's
            // Economy-opinion dependency (revision stays 0 until the first
            // Economy COMMIT after generate). ready stays false; fallback
            // reason keeps the diagnosis. Hard plan failures still isolate.
            const bool ideology_soft =
                !ideology_ok &&
                (ideology_error == "ideology_opinion_snapshot_missing" ||
                 ideology_error == "ideology_country_snapshot_missing" ||
                 ideology_error == "ideology_pod_not_configured" ||
                 ideology_error == "ideology_opinion_snapshot_invalid" ||
                 ideology_error == "ideology_opinion_snapshot_shape_invalid" ||
                 ideology_error == "ideology_day_not_monotonic" ||
                 ideology_error.find("ideology_opinion_") == 0);
            if (ideology_ok || ideology_soft) {
                if (ideology_ok) {
                    stage.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
                    commit.dirty_families |= stage.dirty_families;
                }
                stage.completed = 1;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::IDEOLOGY);
                ++commit.completed_stage_count;
            } else {
                stage.completed = 0;
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::EFFECT &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u) {
            // F8 ACTIVE independent Effect stage (Ideology order already passed
            // in the stage list). Park with Climate like Country/Modifier.
            if (climate_authority_requested && !active_climate_ok) {
                // Still absorb ENSURE registrations so technology instances are
                // present when Climate unblocks the Effect plan lane.
                std::string drain_error;
                drain_effect_transport_queues(drain_error);
                stage.completed = 0;
                continue;
            }
            const bool effect_stage_enabled =
                _effect_pod_configured &&
                !_effect_pod_catalog.definitions.empty();
            if (!effect_stage_enabled) {
                _effect_day_modifier_intents.clear();
                _effect_day_stage_ok = false;
                stage.completed = 0;
                continue;
            }
            // Same M5 retry shape as Country: Effect commits its POD day
            // before later domains (Economy/Ideology continuation) can still
            // fail the atomic gate. Re-planning that day then dies on
            // effect_pod_day_not_sequential and pins 0xFFF forever.
            const int64_t effect_committed =
                _effect_pod_authority.snapshot().committed_day;
            if (plan.context.day <= effect_committed) {
                _effect_day_modifier_intents.clear();
                _effect_day_intents.clear();
                // Soft-skip must still drain ENSURE queues and re-emit
                // COMMITTED→ACK handoffs. Otherwise technology instances stay
                // present=0 / queued>0 across advancing pod days.
                size_t queued_before = 0;
                {
                    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
                    queued_before = _effect_instance_queue.size();
                }
                std::string drain_error;
                drain_effect_transport_queues(drain_error);
                const uint32_t nudged =
                    _effect_pod_authority.reschedule_unfired_due_instances(
                        effect_committed);
                reemit_effect_committed_pending_intents(plan.context.day);
                std::string catchup_error;
                const uint32_t catchup_fired =
                    _effect_pod_authority.catchup_fire_never_fired_instances(
                        effect_committed + 1, _effect_day_intents,
                        catchup_error);
                _effect_day_modifier_intents.clear();
                for (const RuntimeDomainIntent &intent : _effect_day_intents) {
                    if (intent.target_domain ==
                        static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                        _effect_day_modifier_intents.push_back(intent);
                    }
                }
                {
                    const auto &snap = _effect_pod_authority.snapshot();
                    static int s_drain_left = 12;
                    int unfired_due = 0;
                    for (const auto &inst : snap.instances) {
                        if (inst.active != 0 && inst.fire_sequence == 0 &&
                            inst.next_due_day >= 0 &&
                            inst.next_due_day <= effect_committed + 1)
                            ++unfired_due;
                    }
                    if ((queued_before > 0 || unfired_due > 0 || nudged > 0 ||
                         catchup_fired > 0) &&
                        s_drain_left-- > 0) {
                        godot::UtilityFunctions::print(godot::vformat(
                            "[tech-ack-diag/soft-skip] day=%d committed=%d "
                            "queued_before=%d instances=%d unfired_due=%d "
                            "nudged=%d catchup=%d drain_err=%s catchup_err=%s",
                            plan.context.day, effect_committed,
                            static_cast<int64_t>(queued_before),
                            static_cast<int64_t>(snap.instances.size()),
                            unfired_due, static_cast<int64_t>(nudged),
                            static_cast<int64_t>(catchup_fired),
                            godot::String(drain_error.c_str()),
                            godot::String(catchup_error.c_str())));
                    }
                }
                ack_effect_events_intents_in_worker(_effect_day_intents);
                _effect_day_stage_ok = true;
                stage.completed = 1;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::EFFECT);
                ++commit.completed_stage_count;
                _effect_pod_ready.store(true, std::memory_order_release);
                for (size_t i = 0; i < _effect_pod_fallback_reason.size(); ++i)
                    _effect_pod_fallback_reason[i].store(
                        '\0', std::memory_order_release);
                continue;
            }
            std::string effect_error;
            const bool effect_ok = execute_effect_worker_stage(
                plan.context.day, plan.context.input_generation,
                commit, effect_error);
            _effect_pod_ready.store(effect_ok, std::memory_order_release);
            const char *effect_reason = effect_ok ? "" :
                (effect_error.empty() ? "effect_pod_plan_failed"
                                      : effect_error.c_str());
            size_t effect_reason_index = 0;
            for (; effect_reason_index + 1 <
                       _effect_pod_fallback_reason.size() &&
                   effect_reason[effect_reason_index] != '\0';
                 ++effect_reason_index) {
                _effect_pod_fallback_reason[effect_reason_index].store(
                    effect_reason[effect_reason_index],
                    std::memory_order_release);
            }
            for (; effect_reason_index <
                       _effect_pod_fallback_reason.size();
                 ++effect_reason_index) {
                _effect_pod_fallback_reason[effect_reason_index].store(
                    '\0', std::memory_order_release);
            }
            if (effect_ok) {
                // Production ACTIVE Effect→Events: typed intents become
                // APPEND_BATCH commands for the subsequent EVENTS stage.
                // Events failure clears EVENTS completion and blocks COMMIT.
                for (const RuntimeDomainIntent &intent : _effect_day_intents) {
                    gameplay_event_commands.push_back(
                        make_effect_intent_events_packet(
                            intent, plan.context.day));
                }
                stage.completed = 1;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::EFFECT);
                ++commit.completed_stage_count;
                if (!_effect_day_intents.empty()) {
                    _active_evidence_mask.fetch_or(
                        runtime_domain_mask(RuntimeDomainId::EFFECT),
                        std::memory_order_release);
                }
                // G8: when the worker also owns IDEOLOGY, the Effect side of an
                // Ideology transition is this stage. ACK in-worker so the
                // transition settles on the next Ideology visit without a
                // main-thread round trip. The pump stays for IDEOLOGY-only
                // grants and for anything this drain missed.
                if ((_requested_authority_mask.load(std::memory_order_acquire) &
                     runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u) {
                    ack_ideology_intents_in_worker(plan.context.day);
                }
                // H8: same bridge for Trigger. Its effect intents are delivered
                // by this stage under a joint TRIGGER|EFFECT grant, so ACK them
                // here and let the next Trigger visit clear its barrier.
                if ((_requested_authority_mask.load(std::memory_order_acquire) &
                     runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u) {
                    ack_trigger_intents_in_worker(plan.context.day);
                }
            } else {
                stage.completed = 0;
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::MODIFIER &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {
            // Park with Climate the same way Country does: when the worker
            // clock outruns the published environment, do not advance Modifier.
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            // F8: when EFFECT is granted, the independent EFFECT stage already
            // ran. Otherwise keep the E8 embedded upstream for Mod-only grant.
            const bool effect_authority_requested =
                (_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u;
            bool effect_upstream_ok = false;
            if (effect_authority_requested) {
                effect_upstream_ok = _effect_day_stage_ok;
            } else {
                const bool effect_stage_enabled =
                    _effect_pod_configured &&
                    !_effect_pod_catalog.definitions.empty();
                if (effect_stage_enabled) {
                    std::string effect_error;
                    effect_upstream_ok = execute_effect_worker_stage(
                        plan.context.day, plan.context.input_generation,
                        commit, effect_error);
                    _effect_pod_ready.store(effect_upstream_ok,
                                             std::memory_order_release);
                    const char *effect_reason = effect_upstream_ok ? "" :
                        (effect_error.empty() ? "effect_pod_plan_failed"
                                              : effect_error.c_str());
                    size_t effect_reason_index = 0;
                    for (; effect_reason_index + 1 <
                               _effect_pod_fallback_reason.size() &&
                           effect_reason[effect_reason_index] != '\0';
                         ++effect_reason_index) {
                        _effect_pod_fallback_reason[effect_reason_index].store(
                            effect_reason[effect_reason_index],
                            std::memory_order_release);
                    }
                    for (; effect_reason_index <
                               _effect_pod_fallback_reason.size();
                         ++effect_reason_index) {
                        _effect_pod_fallback_reason[effect_reason_index].store(
                            '\0', std::memory_order_release);
                    }
                } else {
                    _effect_day_modifier_intents.clear();
                    _effect_day_stage_ok = false;
                }
            }
            std::string modifier_error;
            std::string unused_authority_error;
            // ACTIVE: no diagnostic domain runner. Failure isolates Modifier —
            // Climate/Country already committed stay.
            if (execute_modifier_worker_stage(
                    plan.context.day, plan.context.input_generation,
                    day_commands, effect_upstream_ok, nullptr,
                    unused_authority_error, modifier_error)) {
                stage.dirty_families = RUNTIME_DIRTY_COUNTRY_STATE;
                stage.work_units = _modifier_pod_work_units.load(
                    std::memory_order_relaxed);
                stage.completed = 1;
                commit.dirty_families |= stage.dirty_families;
                commit.work_units += stage.work_units;
                commit.completed_domain_mask |=
                    runtime_domain_mask(RuntimeDomainId::MODIFIER);
                ++commit.completed_stage_count;
            } else {
                stage.completed = 0;
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::ECONOMY &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::ECONOMY)) != 0u) {
            AtomicCounterScope economy_scope(_economy_inflight_mutations);
            // ACTIVE Economy production: compact_slice (default) or StageOps
            // Host day loop when effective writer is STAGE_OPS (opt-in; start
            // gate still refuses until BOUNDED_KERNELS lands).
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            if (_economy_production_runtime == nullptr) {
                // Fail open: leave incomplete so the full mask does not grant
                // ECONOMY suppression without a production runner.
                stage.completed = 0;
                continue;
            }
            const EconomyProductionWriter production_writer =
                economy_production_writer_effective();
            const auto economy_attempt_started = std::chrono::steady_clock::now();
            std::string economy_error;
            bool economy_day_done = false;
            uint64_t economy_work = 0;
            bool economy_fatal = false;
            bool economy_pending_input = false;
            if (environment && environment->economy_input &&
                !_economy_production_runtime->epoch_active() &&
                (_economy_production_runtime->needs_environment_capture(plan.context.day) ||
                 _economy_production_runtime->needs_building_context_capture(plan.context.day))) {
                if (environment->economy_input->day != plan.context.day ||
                    !_economy_production_runtime->capture_worker_day_input(
                        *environment->economy_input, economy_error)) {
                    set_fault(economy_error.empty() ? "economy_worker_input_day_mismatch" : economy_error.c_str());
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    continue;
                }
            }
            const auto economy_asset_pending_reason = [](const std::string &reason) {
                return runtime_country_asset_pending_reason(reason) ||
                    reason == "fiscal_reserve_peer_results" ||
                    // Mid-epoch fiscal return/collect uses the same origin-asset
                    // prepare loop as epoch-open reserve. Omitting this reason
                    // soft-completes ECONOMY without prepare and deadlocks the
                    // next Country stage waiting for an Economy terminal.
                    reason == "fiscal_peer_results" ||
                    reason == "fiscal_settlement_peer_pending" ||
                    reason == "country_research_peer_results" ||
                    reason == "economy_stage_ops_prelude_pending_input";
            };
            // Country prepares Economy-origin assets in its own stage, which
            // runs earlier in the day plan. An enqueue that lands during this
            // ECONOMY visit must prepare+service in-place or the worker parks
            // on CV with a full Climate ring and WorldClock never advances.
            // Tax settlement can need one peer txn per country × return/collect
            // (≥12 on a 6-country map); keep preparing until the fiscal peer
            // barrier clears or we hit a hard safety cap.
            constexpr int kMaxEconomyAssetRounds = 64;
            for (int asset_round = 0; asset_round < kMaxEconomyAssetRounds;
                 ++asset_round) {
                economy_pending_input = false;
                economy_fatal = false;
                economy_day_done = false;
                if (production_writer == EconomyProductionWriter::STAGE_OPS) {
                    for (int slice = 0; slice < 64; ++slice) {
                        bool slice_done = false;
                        bool pending_input = false;
                        if (!worker_run_stage_ops_slice(
                                plan.context.day, plan.context.input_generation,
                                economy_error, &slice_done, &pending_input)) {
                            economy_fatal = true;
                            break;
                        }
                        if (pending_input) {
                            economy_pending_input = true;
                            break;
                        }
                        ++economy_work;
                        if (slice_done) {
                            economy_day_done = true;
                            break;
                        }
                    }
                } else {
                    for (int slice = 0; slice < 64; ++slice) {
                        bool slice_done = false;
                        bool pending_input = false;
                        if (!_economy_production_runtime->worker_run_compact_slice(
                                plan.context.day, economy_error, &slice_done,
                                &pending_input)) {
                            economy_fatal = true;
                            break;
                        }
                        if (pending_input) {
                            economy_pending_input = true;
                            break;
                        }
                        ++economy_work;
                        if (slice_done) {
                            economy_day_done = true;
                            break;
                        }
                    }
                }
                if (economy_fatal || !economy_pending_input) break;
                if (!economy_asset_pending_reason(economy_error)) break;
                // The Country plan window can only close in the next Country
                // stage. Nothing was enqueued, so re-running prepare here just
                // burns the round budget; soft-complete and let the next pulse
                // retry the parked Economy stage.
                if (economy_error == "country_economy_asset_country_plan_pending")
                    break;
                std::string prepare_error;
                const uint32_t prepared =
                    prepare_economy_origin_country_assets(prepare_error);
                if (!prepare_error.empty()) {
                    economy_error = prepare_error;
                    economy_fatal = true;
                    break;
                }
                if (prepared == 0u) {
                    // Request may already be COUNTRY_PREPARED/pollable from an
                    // earlier prepare. Keep slicing so service can terminal it
                    // instead of parking the day with an in-flight asset.
                    continue;
                }
            }
            publish_economy_tax_diag(
                economy_error, static_cast<uint32_t>(economy_work));
            if (economy_fatal) {
                std::fprintf(stderr, "[economy-worker-fatal] day=%lld phase=%u stage=%u reason=%s\n",
                    static_cast<long long>(plan.context.day), static_cast<unsigned>(_stage_ops_day_phase),
                    _economy_pod_authority.planned_stage_index(), economy_error.c_str());
                set_fault(economy_error.empty()
                              ? (production_writer ==
                                         EconomyProductionWriter::STAGE_OPS
                                     ? "economy_worker_stage_ops_fatal"
                                     : "economy_worker_compact_fatal")
                              : economy_error.c_str());
                stage.completed = 0;
                commit.preflight_ok = 0;
                continue;
            }
            if (economy_pending_input) {
                if (economy_error == "same_day_environment_not_captured" ||
                    economy_error == "same_day_building_context_not_captured") {
                    _economy_input_requested_day.store(plan.context.day,
                        std::memory_order_release);
                    stage.completed = 0;
                    continue;
                }
                if (economy_asset_pending_reason(economy_error)) {
                    // Soft-complete after same-day prepare rounds so Climate can
                    // keep draining the input ring. Hard-parking ECONOMY here
                    // filled the ring and permanently armed
                    // climate_input_capacity_day_barrier while research waited.
                    // Tax/subsidy fiscal peers commonly park here under 50x —
                    // drop every env Climate already absorbed so Host capacity
                    // recovers immediately instead of waiting for the next
                    // calendar day to start.
                    const int64_t climate_committed =
                        _climate_authority.store().committed_day;
                    if (climate_committed >= 0 &&
                        _environment_ring.pop_while_day_at_most(
                            climate_committed) > 0u) {
                        _climate_wait_cv.notify_all();
                        _control_cv.notify_all();
                    }
                    {
                        static int s_fiscal_soft_left = 12;
                        if (s_fiscal_soft_left-- > 0) {
                            godot::UtilityFunctions::print(godot::vformat(
                                "[economy-fiscal-soft] day=%d reason=%s "
                                "work=%d ring=%d climate_committed=%d",
                                plan.context.day,
                                godot::String(economy_error.c_str()),
                                static_cast<int64_t>(economy_work),
                                static_cast<int64_t>(_environment_ring.size()),
                                climate_committed));
                        }
                    }
                    commit.continuation_pending = 1;
                    stage.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
                    stage.work_units = economy_work;
                    stage.completed = 1;
                    commit.dirty_families |= stage.dirty_families;
                    commit.work_units += stage.work_units;
                    commit.completed_domain_mask |=
                        runtime_domain_mask(RuntimeDomainId::ECONOMY);
                    ++commit.completed_stage_count;
                    continue;
                }
                stage.completed = 0;
                continue;
            }
            {
                // Apply any terminals produced by the same-day asset service
                // before later domains / M5 observe Country cash.
                std::string flush_error;
                if (!flush_country_economy_asset_commits(flush_error)) {
                    set_fault(flush_error.empty()
                        ? "country_economy_asset_flush_failed"
                        : flush_error.c_str());
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    continue;
                }
            }
            // slice done 也可能表示空闲或前置领域尚未就绪，不能伪造 epoch 提交。
            const auto economy_formulas_finished = std::chrono::steady_clock::now();
            economy_day_done = economy_day_done &&
                !_economy_production_runtime->epoch_active() &&
                _economy_production_runtime->last_committed_day() >= 0;
            // Soft-complete even a partial pulse (epoch still in progress) so
            // the per-domain grant can include ECONOMY; continuation resumes on
            // the next worker day the same way sync pulses resume.
            stage.dirty_families = RUNTIME_DIRTY_ECONOMY_UI;
            stage.work_units = economy_work;
            stage.completed = 1;
            commit.dirty_families |= stage.dirty_families;
            commit.work_units += stage.work_units;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::ECONOMY);
            ++commit.completed_stage_count;
            if (economy_work > 0u) {
                _active_evidence_mask.fetch_or(
                    runtime_domain_mask(RuntimeDomainId::ECONOMY),
                    std::memory_order_release);
            }
            _economy_pod_ready.store(true, std::memory_order_release);
            _economy_pod_committed.store(economy_day_done,
                                         std::memory_order_release);
            _economy_pod_authority_ready.store(true, std::memory_order_release);
            _economy_pod_committed_day.store(
                economy_day_done ? _economy_production_runtime->last_committed_day()
                                 : _economy_pod_committed_day.load(
                                       std::memory_order_relaxed),
                std::memory_order_release);
            _economy_pod_epoch_sample_day.store(plan.context.day,
                                                std::memory_order_release);
            // POD hash is published after committed ledger import below; legacy source hash stays in the ledger record.
            _economy_pod_operation_gate_mask.store(
                _economy_production_runtime->d7_operation_gate_mask(),
                std::memory_order_release);
            // Only a fully committed epoch may cross the legacy/POD boundary.
            // In-progress slices retain their private mutable SoA in the
            // production runtime and never become observable POD state.
            if (economy_day_done &&
                _economy_pod_authority.committed_ledger_state().generation !=
                    _economy_production_runtime->committed_generation()) {
                bool ledger_published = false;
                if (_economy_production_runtime->formula_owned_bound()) {
                    // N10 Owned identity export: POD `state()` is the very
                    // OwnedState the production runtime is bound to, so a NER
                    // capture → POD import would replace the bound object.
                    // Flush the domain mirrors into the Owned committed blocks
                    // and republish the snapshot from that live state instead.
                    _economy_production_runtime
                        ->flush_formula_owned_domain_mirrors();
                    ledger_published =
                        _economy_pod_authority.publish_owned_committed_mirror(
                            _economy_production_runtime->committed_generation(),
                            _economy_production_runtime->current_day(),
                            economy_error);
                } else {
                    RuntimeEconomyLedgerState ledger_state;
                    const auto capture_started = std::chrono::steady_clock::now();
                    _economy_production_runtime
                        ->capture_committed_ledger_state(ledger_state,
                            production_writer == EconomyProductionWriter::STAGE_OPS
                                ? _economy_replay_stage_hash[RUNTIME_ECONOMY_GRAPH_STAGE_COUNT - 1].load(
                                      std::memory_order_acquire) : 0);
                    const auto import_started = std::chrono::steady_clock::now();
                    ledger_published =
                        _economy_pod_authority.import_and_publish_committed_ledger(
                            std::move(ledger_state), economy_error);
                    static thread_local unsigned mirror_samples = 0;
                    if (mirror_samples++ < 8) {
                        std::fprintf(stderr, "[economy-mirror-cost] day=%lld capture_ms=%.3f import_ms=%.3f\n",
                            static_cast<long long>(plan.context.day),
                            std::chrono::duration<double, std::milli>(import_started - capture_started).count(),
                            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - import_started).count());
                    }
                }
                if (!ledger_published) {
                    // Reject the boundary visibly. An incomplete stage is not
                    // a safe ownership handoff and must not hide invalid state.
                    set_fault(economy_error.empty()
                        ? "economy_pod_committed_ledger_capture_invalid"
                        : economy_error.c_str());
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    continue;
                }
                // M6: mirror readiness never changes the production writer
                // implicitly.  The caller must request switch_economy_authority
                // at a later, observable epoch boundary; this prevents a
                // silent dual-writer handoff in the middle of a day.
            }
            if (economy_day_done) {
                _economy_pod_state_hash.store(_economy_pod_authority.state_hash(), std::memory_order_release);
            }
            if (plan.context.day % 100 == 0) {
                double stages_ms = 0;
                for (const auto &ms : _economy_replay_stage_ms) stages_ms += ms.load(std::memory_order_relaxed);
                std::fprintf(stderr, "[economy-boundary-cost] day=%lld formulas_ms=%.3f stages_ms=%.3f mirror_ms=%.3f\n",
                    static_cast<long long>(plan.context.day),
                    std::chrono::duration<double, std::milli>(economy_formulas_finished - economy_attempt_started).count(),
                    stages_ms,
                    std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - economy_formulas_finished).count());
            }
            // Phase 5: publish production snapshot into the Economy POD ring.
            {
                uint32_t ring_index = 0;
                if (_economy_pod_authority.snapshot_ring().try_begin_write(
                        ring_index)) {
                    RuntimeEconomySnapshotPayload &payload =
                        _economy_pod_authority.snapshot_ring().write_buffer(
                            ring_index);
                    payload = RuntimeEconomySnapshotPayload{};
                    payload.header.session_epoch = 1;
                    payload.header.generation =
                        _economy_pod_generation.load(std::memory_order_relaxed);
                    payload.header.committed_day =
                        economy_day_done ? _economy_production_runtime->last_committed_day()
                                         : _economy_pod_committed_day.load(
                                               std::memory_order_relaxed);
                    payload.header.epoch_sample_day = plan.context.day;
                    payload.header.state_hash =
                        _economy_pod_state_hash.load(std::memory_order_relaxed);
                    payload.header.operation_gate_mask =
                        _economy_pod_operation_gate_mask.load(
                            std::memory_order_relaxed);
                    payload.header.committed = economy_day_done;
                    payload.header.authority_ready = true;
                    payload.operation_gate_mask =
                        payload.header.operation_gate_mask;
                    payload.authority_mode = static_cast<uint32_t>(
                        _economy_pod_authority.authority_mode());
                    int64_t pop_err = 0, money_err = 0, goods_err = 0;
                    int64_t changed_cells = 0, changed_cohorts = 0;
                    uint32_t dirty_family_mask = 0;
                    _economy_production_runtime->fill_economy_audit_snapshot(
                        pop_err, money_err, goods_err, dirty_family_mask,
                        changed_cells, changed_cohorts);
                    payload.population_error = pop_err;
                    payload.money_error = money_err;
                    payload.goods_error = goods_err;
                    payload.header.population_error = pop_err;
                    payload.header.money_error = money_err;
                    payload.header.goods_error = goods_err;
                    payload.header.changed_cells =
                        static_cast<uint32_t>(std::max<int64_t>(0, changed_cells));
                    payload.header.changed_cohorts =
                        static_cast<uint32_t>(std::max<int64_t>(0, changed_cohorts));
                    payload.dirty_family_mask = dirty_family_mask;
                    _economy_production_runtime->fill_economy_business_summary(
                        payload.summary_population, payload.summary_funds,
                        payload.summary_markets, payload.summary_buildings,
                        payload.summary_cohorts, payload.summary_families);
                    _economy_pod_authority.set_business_summary(
                        pop_err, money_err, goods_err,
                        payload.summary_population, payload.summary_funds,
                        payload.summary_markets, payload.summary_buildings,
                        payload.summary_cohorts, payload.summary_families);
                    _economy_pod_authority.snapshot_ring().publish(ring_index);
                }
            }
            // POD command execute via apply_command, then drain receipts.
            _economy_pod_authority.sync_identity(
                1u, _economy_production_runtime->committed_generation());
            const uint32_t command_mutations =
                _economy_pod_authority.commit_pending_commands();
            // Phase-3: verify owned mirror hash/shape before full recapture.
            if (command_mutations > 0u &&
                !_economy_production_runtime->epoch_active() &&
                _economy_production_runtime->formula_owned_bound()) {
                // N10: bound means POD and NER share the same OwnedState, so a
                // NER capture would only be compared against itself. Refresh
                // the Owned committed blocks and republish the snapshot.
                _economy_production_runtime
                    ->flush_formula_owned_domain_mirrors();
                if (!_economy_pod_authority.publish_owned_committed_mirror(
                        _economy_production_runtime->committed_generation(),
                        _economy_production_runtime->current_day(),
                        economy_error)) {
                    set_fault("economy_pod_command_recapture_failed");
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    continue;
                }
                _economy_pod_command_verify_count.fetch_add(
                    command_mutations, std::memory_order_relaxed);
                _economy_pod_state_hash.store(
                    _economy_pod_authority.state_hash(),
                    std::memory_order_release);
            } else if (command_mutations > 0u &&
                       !_economy_production_runtime->epoch_active()) {
                RuntimeEconomyLedgerState ledger_state;
                _economy_production_runtime->capture_committed_ledger_state(
                    ledger_state);
                if (!ledger_state.valid()) {
                    set_fault("economy_pod_command_recapture_failed");
                    stage.completed = 0;
                    commit.preflight_ok = 0;
                    continue;
                }
                ledger_state.recompute_hash();
                const uint64_t ner_ledger_hash = ledger_state.computed_hash();
                RuntimeEconomyLedgerState owned_export;
                std::string verify_error;
                const bool export_ok =
                    _economy_pod_authority.export_committed_ledger(
                        owned_export, verify_error);
                if (export_ok) owned_export.recompute_hash();
                const bool shape_ok =
                    export_ok &&
                    owned_export.cohort_funds.size() ==
                        ledger_state.cohort_funds.size() &&
                    owned_export.market_stock.size() ==
                        ledger_state.market_stock.size() &&
                    owned_export.cohort_population.size() ==
                        ledger_state.cohort_population.size();
                if (shape_ok &&
                    owned_export.computed_hash() == ner_ledger_hash) {
                    _economy_pod_command_verify_count.fetch_add(
                        command_mutations, std::memory_order_relaxed);
                } else {
                    if (!export_ok ||
                        !_economy_pod_authority.import_committed_ledger(
                            ledger_state, economy_error) ||
                        !_economy_pod_authority.capture_committed_ledger_state(
                            std::move(ledger_state))) {
                        set_fault("economy_pod_command_recapture_failed");
                        stage.completed = 0;
                        commit.preflight_ok = 0;
                        continue;
                    }
                    _economy_pod_command_recapture_count.fetch_add(
                        command_mutations, std::memory_order_relaxed);
                }
                _economy_pod_state_hash.store(
                    _economy_pod_authority.state_hash(),
                    std::memory_order_release);
            }
            {
                RuntimeEconomyPodReceipt receipt;
                uint32_t ack_n = 0;
                while (ack_n < 64u &&
                       _economy_pod_authority.poll_receipt(receipt)) {
                    ++ack_n;
                }
                commit.work_units += ack_n;
            }
            // ACTIVE_WITH_PARITY: after a completed epoch, replay StageOps
            // (mutate=false) against frozen stage refs from compact slices.
            // Incomplete pulses skip — refs would be partial.
            if (economy_day_done && economy_parity_shadow_enabled()) {
                std::string parity_error;
                const uint32_t economy_cells = static_cast<uint32_t>(
                    std::max(0, _economy_production_runtime->cell_count()));
                const uint64_t input_generation =
                    plan.context.input_generation != 0
                        ? plan.context.input_generation
                        : static_cast<uint64_t>(std::max<int64_t>(
                              1, plan.context.day + 1));
                if (economy_cells > 0u) {
                    (void)execute_economy_worker_stage(
                        plan.context.day, input_generation, economy_cells,
                        _economy_pod_country_generation.load(
                            std::memory_order_relaxed),
                        input_generation, parity_error);
                }
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::GAMEPLAY_EFFECT &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT)) != 0u) {
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            // Gameplay commands arrive as typed RuntimeCommandPacket rows.
            // The worker owns admission, deterministic ordering and terminal
            // accounting here; publication of the resulting event is handled
            // by the subsequent EVENTS stage. No Godot value is touched.
            uint32_t terminal = 0;
            uint64_t effect_hash = 1469598103934665603ull;
            bool gameplay_effect_ok = true;
            for (const RuntimeCommandPacket &packet : day_commands) {
                if (packet.envelope.domain != static_cast<uint16_t>(
                        RuntimeDomainId::GAMEPLAY_EFFECT) ||
                    packet.envelope.effective_day > plan.context.day) {
                    continue;
                }
                const bool payload_bounds =
                    packet.envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                    packet.envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                    packet.envelope.payload_offset <=
                        RUNTIME_MAX_COMMAND_PAYLOAD - packet.envelope.payload_size;
                const uint8_t *payload = payload_bounds
                    ? packet.payload.data() + packet.envelope.payload_offset : nullptr;
                const size_t payload_size = payload_bounds
                    ? packet.envelope.payload_size : 0u;
                size_t cursor = 0;
                int32_t action = 0;
                int32_t target_domain = 0;
                int32_t opcode = 0;
                int64_t effective_day = -1;
                uint64_t target_handle = 0;
                uint32_t target_generation = 0;
                int64_t value_i64 = 0;
                std::array<int64_t, 4> typed_payload{};
                uint64_t idempotency_key = 0;
                const bool decoded = payload_bounds &&
                    d7_read_i32(payload, payload_size, cursor, action) &&
                    d7_read_i32(payload, payload_size, cursor, target_domain) &&
                    d7_read_i32(payload, payload_size, cursor, opcode) &&
                    d7_read_i64(payload, payload_size, cursor, effective_day) &&
                    d7_read_u64(payload, payload_size, cursor, target_handle) &&
                    d7_read_u32(payload, payload_size, cursor, target_generation) &&
                    d7_read_i64(payload, payload_size, cursor, value_i64) &&
                    d7_read_i64(payload, payload_size, cursor, typed_payload[0]) &&
                    d7_read_i64(payload, payload_size, cursor, typed_payload[1]) &&
                    d7_read_i64(payload, payload_size, cursor, typed_payload[2]) &&
                    d7_read_i64(payload, payload_size, cursor, typed_payload[3]) &&
                    d7_read_u64(payload, payload_size, cursor, idempotency_key) &&
                    cursor == payload_size;
                const bool publishes_event =
                    (action == 4 && target_domain == 3) ||
                    (action == 5 && target_domain == 4);
                if (!decoded || !publishes_event || opcode <= 0 ||
                    effective_day != packet.envelope.effective_day ||
                    target_handle == 0 || target_generation == 0 ||
                    idempotency_key == 0) {
                    gameplay_effect_ok = false;
                    break;
                }
                RuntimeCommandPacket event_packet{};
                event_packet.envelope.request_id = packet.envelope.request_id;
                event_packet.envelope.producer_id = packet.envelope.producer_id;
                event_packet.envelope.sequence = packet.envelope.sequence;
                event_packet.envelope.observed_generation =
                    packet.envelope.observed_generation;
                event_packet.envelope.requested_day = packet.envelope.requested_day;
                event_packet.envelope.effective_day = effective_day;
                event_packet.envelope.domain = static_cast<uint16_t>(
                    RuntimeDomainId::EVENTS);
                event_packet.envelope.opcode = static_cast<uint16_t>(
                    RuntimeEventsCommand::APPEND_BATCH);
                std::vector<uint8_t> event_payload;
                event_payload.reserve(88u);
                const auto put_u32 = [&event_payload](uint32_t value) {
                    for (uint32_t i = 0; i < 4u; ++i)
                        event_payload.push_back(static_cast<uint8_t>(
                            (value >> (i * 8u)) & 0xffu));
                };
                const auto put_u64 = [&event_payload](uint64_t value) {
                    for (uint32_t i = 0; i < 8u; ++i)
                        event_payload.push_back(static_cast<uint8_t>(
                            (value >> (i * 8u)) & 0xffu));
                };
                const auto put_i32 = [&put_u32](int32_t value) {
                    put_u32(static_cast<uint32_t>(value));
                };
                const auto put_i64 = [&put_u64](int64_t value) {
                    put_u64(static_cast<uint64_t>(value));
                };
                put_u32(RUNTIME_EVENTS_ABI_VERSION);
                put_u32(1u);
                put_i64(effective_day);
                put_i32(95);
                put_i32(opcode);
                put_i32(4); // PK_EVENT_SOURCE_EFFECT
                put_i32(0);
                put_u64(target_handle);
                put_i32(static_cast<int32_t>(typed_payload[0]));
                put_i32(static_cast<int32_t>(typed_payload[1]));
                put_i32(static_cast<int32_t>(typed_payload[2]));
                put_i64(value_i64);
                put_i32(static_cast<int32_t>(typed_payload[0]));
                put_i32(static_cast<int32_t>(typed_payload[1]));
                put_i32(static_cast<int32_t>(typed_payload[2]));
                put_i32(static_cast<int32_t>(typed_payload[3]));
                put_u64(idempotency_key);
                event_packet.envelope.payload_size = static_cast<uint32_t>(
                    event_payload.size());
                if (event_payload.size() > event_packet.payload.size()) {
                    gameplay_effect_ok = false;
                    break;
                }
                std::memcpy(event_packet.payload.data(), event_payload.data(),
                            event_payload.size());
                gameplay_event_commands.push_back(event_packet);
                ++terminal;
                effect_hash = mix_hash(effect_hash, packet.envelope.request_id);
                effect_hash = mix_hash(effect_hash, packet.envelope.sequence);
                effect_hash = mix_hash(effect_hash, packet.envelope.opcode);
                // GAMEPLAY_EFFECT packets carry the fixed typed ingress row
                // (action/domain/opcode/day/target/value/payload/key). Hash
                // the bytes as part of the worker state so receipts cannot
                // report success for an envelope whose typed body was lost.
                effect_hash = mix_hash(effect_hash, packet.envelope.payload_size);
                for (uint32_t i = 0; i < packet.envelope.payload_size; ++i)
                    effect_hash = mix_hash(effect_hash, packet.payload[i]);
            }
            if (!gameplay_effect_ok) {
                gameplay_event_commands.clear();
                _gameplay_effect_pending.store(terminal + 1u,
                                               std::memory_order_release);
                _gameplay_effect_terminal.store(0, std::memory_order_release);
                stage.completed = 0;
                commit.preflight_ok = 0;
                continue;
            }
            _gameplay_effect_generation.fetch_add(1, std::memory_order_release);
            _gameplay_effect_pending.store(0, std::memory_order_release);
            _gameplay_effect_terminal.store(terminal, std::memory_order_release);
            _gameplay_effect_state_hash.store(effect_hash,
                                               std::memory_order_release);
            stage.work_units = std::max<uint64_t>(1u, terminal);
            stage.dirty_families = terminal != 0 ? RUNTIME_DIRTY_EVENTS : 0;
            stage.completed = 1;
            commit.work_units += stage.work_units;
            commit.dirty_families |= stage.dirty_families;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT);
            ++commit.completed_stage_count;
            if (terminal > 0u) {
                _active_evidence_mask.fetch_or(
                    runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT),
                    std::memory_order_release);
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::EVENTS &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u) {
            // ACTIVE Events is the production journal and consumer-cursor
            // owner. A rejected batch holds COMMIT at the sealed day.
            if (climate_authority_requested && !active_climate_ok) {
                stage.completed = 0;
                continue;
            }
            const bool events_ok = run_events_probe(plan.context.day);
            if (_events_pod_event_count.load(std::memory_order_relaxed) > 0u) {
                stage.dirty_families = RUNTIME_DIRTY_EVENTS;
                commit.dirty_families |= stage.dirty_families;
            }
            stage.work_units =
                _events_pod_event_count.load(std::memory_order_relaxed);
            commit.work_units += stage.work_units;
            if (!events_ok) {
                stage.completed = 0;
                commit.preflight_ok = 0;
                continue;
            }
            stage.completed = 1;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::EVENTS);
            ++commit.completed_stage_count;
            if (stage.work_units > 0u) {
                _active_evidence_mask.fetch_or(
                    runtime_domain_mask(RuntimeDomainId::EVENTS),
                    std::memory_order_release);
            }
            continue;
        }
        if (stage.domain == RuntimeDomainId::VISUAL &&
            _mode.load(std::memory_order_acquire) ==
                RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::VISUAL)) != 0u) {
            // VISUAL authority ends at deterministic intent production.  The
            // Godot renderer/GPU remains outside the worker; publish_day()
            // later sorts, deduplicates and commits this POD batch atomically.
            uint32_t intent_index = 0;
            const uint32_t dirty = commit.dirty_families;
            for (uint32_t bit = 0; bit < RUNTIME_DIRTY_FAMILY_COUNT; ++bit) {
                const uint32_t family_bit = 1u << bit;
                if ((dirty & family_bit) == 0u) continue;
                RuntimeVisualIntent intent{};
                intent.family = family_bit;
                intent.cell_index = 0;
                intent.field_id = bit;
                intent.value_i32 = static_cast<int32_t>(plan.context.day);
                intent.value_f32 = 0.0f;
                _pod_visual_intents.push_back(intent);
                ++intent_index;
            }
            stage.work_units = intent_index;
            stage.dirty_families = 0;
            stage.completed = 1;
            commit.work_units += stage.work_units;
            commit.completed_domain_mask |=
                runtime_domain_mask(RuntimeDomainId::VISUAL);
            ++commit.completed_stage_count;
            if (intent_index > 0u) {
                _active_evidence_mask.fetch_or(
                    runtime_domain_mask(RuntimeDomainId::VISUAL),
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
    if (previous_domain_valid) {
        char after_point[72];
        std::snprintf(after_point, sizeof(after_point), "%s.plan.after",
                      runtime_domain_fault_tag(previous_domain));
        if (try_fault_injection(after_point)) {
            commit.preflight_ok = 0;
            return commit;
        }
    }
    // M5 atomic COMMIT gate: every domain explicitly requested for ACTIVE
    // authority must have completed before the worker clock or snapshot can
    // advance.  Unrequested domains remain on their legacy writer and are
    // intentionally absent from this mask.  This closes the old hole where a
    // missing stage could still let COMMIT publish a half-day.
    const uint32_t active_requested =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE
            ? _requested_authority_mask.load(std::memory_order_acquire) : 0u;
    if (active_requested != 0u &&
        (commit.completed_domain_mask & active_requested) != active_requested) {
        commit.preflight_ok = 0;
        commit.continuation_pending = 1;
    }
    run_events_probe(plan.context.day);
    // A failed authoritative Climate day must not advance the clock. The main
    // thread is suppressed, so advancing anyway would silently drop that day:
    // nobody computed it and nothing would ever go back for it. Zero here parks
    // the worker on the same day until the input barrier clears.
    if (climate_authority_requested && !active_climate_ok) {
        commit.preflight_ok = 0;
    }
    if (try_fault_injection("day.plan.after")) {
        commit.preflight_ok = 0;
    }
    return commit;
}

void NativeSimulationHost::publish_day(
        int64_t from_day, int64_t day,
        const RuntimeDayCommit &day_commit,
        const std::vector<RuntimeCommandReceipt> &day_receipts) {
    if (try_fault_injection("day.commit.before")) {
        return;
    }
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
    // VISUAL is a committed intent boundary. Sort and deduplicate worker
    // intents before exposing them, so consumers never observe order that
    // depends on worker traversal or a half-built batch.
    std::stable_sort(_pod_visual_intents.begin(), _pod_visual_intents.end(),
        [](const RuntimeVisualIntent &a, const RuntimeVisualIntent &b) {
            if (a.family != b.family) return a.family < b.family;
            if (a.cell_index != b.cell_index) return a.cell_index < b.cell_index;
            return a.field_id < b.field_id;
        });
    _pod_visual_intents.erase(std::unique(_pod_visual_intents.begin(),
        _pod_visual_intents.end(), [](const RuntimeVisualIntent &a,
                                      const RuntimeVisualIntent &b) {
            return a.family == b.family && a.cell_index == b.cell_index &&
                   a.field_id == b.field_id && a.value_i32 == b.value_i32 &&
                   a.value_f32 == b.value_f32;
        }), _pod_visual_intents.end());
    _visual_intent_generation.store(generation, std::memory_order_release);
    _visual_intent_count.store(static_cast<uint32_t>(
        std::min<size_t>(_pod_visual_intents.size(),
                         std::numeric_limits<uint32_t>::max())),
        std::memory_order_release);
    _visual_full_refresh.store(_snapshots.publish_drop_count() != 0,
                               std::memory_order_release);
    commit.visual_intents.clear();
    commit.visual_intents.reserve(_pod_visual_intents.size());
    commit.visual_intents.insert(commit.visual_intents.end(),
                                 _pod_visual_intents.begin(),
                                 _pod_visual_intents.end());
    commit.receipts.clear();
    commit.receipts.reserve(day_receipts.size());
    for (const RuntimeCommandReceipt &receipt : day_receipts) {
        commit.receipts.push_back(receipt);
    }
    _snapshots.publish(index);
    _last_visual_publish_us.store(produced_at_us, std::memory_order_release);
    _last_commit_produced_at_us.store(commit.header.produced_at_us,
                                      std::memory_order_release);
    try_fault_injection("day.commit.after");
}

void NativeSimulationHost::publish_economy_tax_diag(
        const std::string &yield_reason, uint32_t slices) {
    const auto store_text = [](auto &dst, const char *text) {
        const char *value = text != nullptr ? text : "";
        size_t i = 0;
        for (; i + 1 < dst.size() && value[i] != '\0'; ++i)
            dst[i].store(value[i], std::memory_order_relaxed);
        for (; i < dst.size(); ++i)
            dst[i].store('\0', std::memory_order_relaxed);
    };
    NativeEconomyRuntime::TaxSchedDiag diag;
    char stage[32] = {};
    char substage[40] = {};
    if (_economy_production_runtime != nullptr) {
        _economy_production_runtime->copy_tax_sched_diag(
            diag, stage, sizeof(stage), substage, sizeof(substage));
    }
    store_text(_economy_yield_reason, yield_reason.c_str());
    store_text(_economy_stage_name, stage);
    store_text(_economy_substage_name, substage);
    _economy_epoch_fiscal_ms.store(diag.epoch_fiscal_ms, std::memory_order_relaxed);
    _economy_fiscal_settlement_ms.store(
        diag.fiscal_settlement_ms, std::memory_order_relaxed);
    _economy_income_subsidy_ms.store(
        diag.income_subsidy_ms, std::memory_order_relaxed);
    _economy_negative_tax_mask.store(diag.negative_tax_mask, std::memory_order_relaxed);
    _economy_active_tax_mask.store(diag.active_tax_mask, std::memory_order_relaxed);
    _economy_attempt_slices.store(slices, std::memory_order_relaxed);
}

void NativeSimulationHost::record_save_failure(const char *reason) {
    const char *value = reason ? reason : "unknown";
    size_t i = 0;
    for (; i + 1 < _save_failure_reason.size() && value[i] != '\0'; ++i)
        _save_failure_reason[i].store(value[i], std::memory_order_relaxed);
    for (; i < _save_failure_reason.size(); ++i)
        _save_failure_reason[i].store('\0', std::memory_order_relaxed);
}

std::string NativeSimulationHost::save_failure_reason() const {
    std::string out;
    for (const auto &c : _save_failure_reason) {
        const char value = c.load(std::memory_order_relaxed);
        if (value == '\0') break;
        out.push_back(value);
    }
    return out;
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
    _economy_authority_fault_paused.store(true, std::memory_order_release);
    _economy_authority_last_committed_generation.store(
        _economy_pod_authority.committed_ledger_state().generation,
        std::memory_order_release);
    _economy_authority_last_committed_hash.store(
        _economy_pod_authority.state_hash(), std::memory_order_release);
}

bool NativeSimulationHost::arm_fault_injection(const char *point) noexcept {
    if (point == nullptr || point[0] == '\0') return false;
    size_t i = 0;
    for (; i + 1 < _fault_injection_point.size() && point[i] != '\0'; ++i) {
        _fault_injection_point[i].store(point[i], std::memory_order_relaxed);
    }
    if (point[i] != '\0') {
        // Reject truncated names so soak scripts cannot silently arm a
        // different boundary than the one they asked for.
        for (auto &character : _fault_injection_point)
            character.store('\0', std::memory_order_relaxed);
        _fault_injection_armed.store(false, std::memory_order_release);
        return false;
    }
    for (; i < _fault_injection_point.size(); ++i)
        _fault_injection_point[i].store('\0', std::memory_order_relaxed);
    _fault_injection_armed.store(true, std::memory_order_release);
    return true;
}

void NativeSimulationHost::clear_fault_injection() noexcept {
    _fault_injection_armed.store(false, std::memory_order_release);
    for (auto &character : _fault_injection_point)
        character.store('\0', std::memory_order_relaxed);
}

bool NativeSimulationHost::try_fault_injection(const char *point) noexcept {
    if (point == nullptr || point[0] == '\0') return false;
    if (!_fault_injection_armed.load(std::memory_order_acquire)) return false;
    for (size_t i = 0; i + 1 < _fault_injection_point.size(); ++i) {
        const char armed = _fault_injection_point[i].load(
            std::memory_order_relaxed);
        const char expected = point[i];
        if (armed != expected) return false;
        if (expected == '\0') break;
    }
    // One-shot: clear before set_fault so a nested check cannot re-enter.
    _fault_injection_armed.store(false, std::memory_order_release);
    _fault_injection_trip_count.fetch_add(1, std::memory_order_relaxed);
    char code[96];
    std::snprintf(code, sizeof(code), "fault_injected:%s", point);
    set_fault(code);
    return true;
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
    _save_failed_request_id.store(0, std::memory_order_release);
    record_save_failure("");
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
    if (try_fault_injection("restore.decode.before")) {
        error = "restore_decode_fault_injected_before";
        return false;
    }
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
                                 RUNTIME_SAVE_SECTION_IDEOLOGY |
                                 RUNTIME_SAVE_SECTION_ECONOMY_ASSET |
                                 RUNTIME_SAVE_SECTION_ECONOMY_POD |
                                 RUNTIME_SAVE_SECTION_ECONOMY_ECP2 |
                                 RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT)) != 0) {
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
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ASSET) != 0) {
        constexpr uint32_t D7_SECTION_MARKER = 0x31543744u; // D7T1
        uint32_t d7_marker = 0;
        uint32_t d7_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, d7_marker) ||
            !read_u32(cursor + 4u, d7_size) ||
            d7_marker != D7_SECTION_MARKER ||
            d7_size > 64u * 1024u * 1024u ||
            d7_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_d7_transaction_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_asset_bytes.assign(bytes + cursor,
                                          bytes + cursor + d7_size);
        cursor += d7_size;
        uint64_t d7_checksum = 0;
        if (!read_u64(cursor, d7_checksum)) {
            error = "runtime_bundle_d7_transaction_checksum_missing";
            return false;
        }
        uint64_t computed_d7 = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_asset_bytes) {
            computed_d7 ^= static_cast<uint64_t>(byte);
            computed_d7 *= 1099511628211ull;
        }
        if (computed_d7 != d7_checksum) {
            error = "runtime_bundle_d7_transaction_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_asset_bytes.size() < 8u ||
            std::memcmp(parsed.economy_asset_bytes.data(), "D7T1", 4u) != 0) {
            error = "runtime_bundle_d7_transaction_marker_invalid";
            return false;
        }
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
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT) != 0) {
        constexpr uint32_t GMP1_MARKER = 0x31504d47u; // GMP1
        uint32_t marker = 0;
        uint32_t section_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, marker) ||
            !read_u32(cursor + 4u, section_size) || marker != GMP1_MARKER ||
            section_size != 32u || section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_gameplay_effect_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.gameplay_effect_bytes.assign(bytes + cursor,
                                            bytes + cursor + section_size);
        cursor += section_size;
        uint64_t stored_checksum = 0;
        if (!read_u64(cursor, stored_checksum)) {
            error = "runtime_bundle_gameplay_effect_checksum_missing";
            return false;
        }
        uint64_t computed_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.gameplay_effect_bytes) {
            computed_checksum ^= static_cast<uint64_t>(byte);
            computed_checksum *= 1099511628211ull;
        }
        if (computed_checksum != stored_checksum) {
            error = "runtime_bundle_gameplay_effect_checksum_failed";
            return false;
        }
        cursor += 8u;
        size_t gmp_cursor = 0;
        uint32_t inner_marker = 0;
        uint32_t abi = 0;
        uint64_t generation = 0;
        uint32_t pending = 0;
        uint32_t terminal = 0;
        uint64_t state_hash = 0;
        if (!d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, inner_marker) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, abi) ||
            !d7_read_u64(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, generation) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, pending) ||
            !d7_read_u32(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, terminal) ||
            !d7_read_u64(parsed.gameplay_effect_bytes.data(), section_size,
                         gmp_cursor, state_hash) || gmp_cursor != section_size ||
            inner_marker != GMP1_MARKER || abi != 1u) {
            error = "runtime_bundle_gameplay_effect_payload_invalid";
            return false;
        }
        uint32_t actual_pending = 0;
        for (const RuntimeCommandPacket &packet : parsed.pending_commands) {
            if (packet.envelope.domain == static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT))
                ++actual_pending;
        }
        if (pending != actual_pending) {
            error = "runtime_bundle_gameplay_effect_pending_mismatch";
            return false;
        }
        (void)generation;
        (void)terminal;
        (void)state_hash;
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
            std::memcmp(parsed.ideology_bytes.data(), "IDP1", 4u) != 0) {
            error = "runtime_bundle_ideology_section_marker_invalid";
            return false;
        }
        // The ideology POD catalog is derived from the Country POD snapshot,
        // so it can only be configured after PKCN restores — and PKSR restores
        // before PKCN. When the catalog is not configured yet, the checksum and
        // marker above still reject corrupt bytes; the catalog-dependent dry
        // run is deferred to worker start, which restores IDP1 against the
        // then-configured catalog and faults before any day runs if it fails.
        if (_ideology_pod_configured) {
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
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_POD) != 0) {
        constexpr uint32_t ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
        uint32_t economy_marker = 0;
        uint32_t economy_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, economy_marker) ||
            !read_u32(cursor + 4u, economy_size) ||
            economy_marker != ECONOMY_POD_SECTION_MARKER ||
            economy_size > 64u * 1024u * 1024u ||
            economy_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_economy_pod_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_pod_bytes.assign(bytes + cursor,
                                        bytes + cursor + economy_size);
        cursor += economy_size;
        uint64_t economy_checksum = 0;
        if (!read_u64(cursor, economy_checksum)) {
            error = "runtime_bundle_economy_pod_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_pod_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != economy_checksum) {
            error = "runtime_bundle_economy_pod_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_pod_bytes.size() < 4u ||
            std::memcmp(parsed.economy_pod_bytes.data(), "ECP1", 4u) != 0) {
            error = "runtime_bundle_economy_pod_section_marker_invalid";
            return false;
        }
        RuntimeEconomyPodAuthority candidate;
        std::string economy_restore_error;
        if (!candidate.restore_ecp1(parsed.economy_pod_bytes.data(),
                                    parsed.economy_pod_bytes.size(),
                                    economy_restore_error)) {
            error = economy_restore_error.empty()
                ? "runtime_bundle_economy_pod_restore_invalid"
                : economy_restore_error;
            return false;
        }
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_ECONOMY_ECP2) != 0) {
        constexpr uint32_t ECONOMY_ECP2_SECTION_MARKER = 0x32504345u; // ECP2
        uint32_t economy_marker = 0;
        uint32_t economy_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, economy_marker) ||
            !read_u32(cursor + 4u, economy_size) ||
            economy_marker != ECONOMY_ECP2_SECTION_MARKER ||
            economy_size > 64u * 1024u * 1024u ||
            economy_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_economy_ecp2_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.economy_ecp2_bytes.assign(bytes + cursor,
                                         bytes + cursor + economy_size);
        cursor += economy_size;
        uint64_t economy_checksum = 0;
        if (!read_u64(cursor, economy_checksum)) {
            error = "runtime_bundle_economy_ecp2_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.economy_ecp2_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != economy_checksum) {
            error = "runtime_bundle_economy_ecp2_section_checksum_failed";
            return false;
        }
        cursor += 8u;
        if (parsed.economy_ecp2_bytes.size() < 4u ||
            std::memcmp(parsed.economy_ecp2_bytes.data(), "ECP2", 4u) != 0) {
            error = "runtime_bundle_economy_ecp2_section_marker_invalid";
            return false;
        }
        RuntimeEconomyEcp2State candidate_ecp2;
        std::string economy_ecp2_restore_error;
        if (!decode_ecp2(parsed.economy_ecp2_bytes.data(),
                         parsed.economy_ecp2_bytes.size(), candidate_ecp2,
                         economy_ecp2_restore_error)) {
            error = economy_ecp2_restore_error.empty()
                ? "runtime_bundle_economy_ecp2_restore_invalid"
                : economy_ecp2_restore_error;
            return false;
        }
        if (!ecp2_has_required_domains(candidate_ecp2.authority_domain_mask,
                                       ECP2_DOMAIN_CORE_AUTHORITY)) {
            error = "runtime_bundle_economy_ecp2_core_domains_missing";
            return false;
        }
    }
    if (cursor != payload_end) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    _pending_restore_bundle = std::move(parsed);
    if (try_fault_injection("restore.validate.before")) {
        error = "restore_validate_fault_injected_before";
        _pending_restore_bundle = RuntimeSaveBundle{};
        _has_pending_restore = false;
        return false;
    }
    _has_pending_restore = true;
    // The main thread numbers the next environment input from the reported
    // environment generation, and it captures the first post-load input
    // before the worker starts. Publishing the saved generation only at worker
    // start let that first input restart at 1, below the restored Climate
    // authority's last input, which faulted with
    // climate_input_generation_not_monotonic on the first day after a load.
    if (_pending_restore_bundle.environment_generation >
            _environment_generation.load(std::memory_order_acquire)) {
        _environment_generation.store(_pending_restore_bundle.environment_generation,
                                      std::memory_order_release);
    }
    // GPU/Object state is intentionally outside the runtime bundle. The next
    // committed visual batch must therefore be a reconstructible full refresh
    // after any successful restore, even when the visual ring had no drop.
    _visual_full_refresh.store(true, std::memory_order_release);
    if (try_fault_injection("restore.swap.before")) {
        error = "restore_swap_fault_injected_before";
        _pending_restore_bundle = RuntimeSaveBundle{};
        _has_pending_restore = false;
        return false;
    }
    return true;
}

void NativeSimulationHost::build_save_bundle(
        uint64_t request_id,
        const std::vector<RuntimeCommandPacket> &pending_commands) {
    if (try_fault_injection("save.barrier.before")) {
        return;
    }
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
    // Under worker Country authority the checkpoint must describe the same
    // committed day as this bundle. A mismatch restores a Country POD that can
    // never plan the next host day (country_day_not_contiguous forever), so
    // reject the save explicitly instead of writing an inconsistent bundle.
    if (country_checkpoint != nullptr &&
        domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        country_checkpoint->committed_day != bundle->committed_day) {
        record_save_failure("save_country_checkpoint_day_mismatch");
        return;
    }
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
    std::string d7_save_error;
    if (!serialize_country_economy_asset_journal(
            bundle->economy_asset_bytes, d7_save_error)) {
        set_fault(d7_save_error.empty() ? "d7_transaction_journal_encode_failed" :
                  d7_save_error.c_str());
        return;
    }
    if (!bundle->economy_asset_bytes.empty())
        bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_ASSET;
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
    {
        constexpr uint32_t GMP1_MARKER = 0x31504d47u; // GMP1
        constexpr uint32_t GMP1_ABI = 1u;
        uint32_t pending_gameplay = 0;
        for (const RuntimeCommandPacket &packet : pending_commands) {
            if (packet.envelope.domain == static_cast<uint16_t>(
                    RuntimeDomainId::GAMEPLAY_EFFECT))
                ++pending_gameplay;
        }
        std::vector<uint8_t> &gmp = bundle->gameplay_effect_bytes;
        gmp.clear();
        d7_append_u32(gmp, GMP1_MARKER);
        d7_append_u32(gmp, GMP1_ABI);
        d7_append_u64(gmp, _gameplay_effect_generation.load(
            std::memory_order_acquire));
        d7_append_u32(gmp, pending_gameplay);
        d7_append_u32(gmp, _gameplay_effect_terminal.load(
            std::memory_order_acquire));
        d7_append_u64(gmp, _gameplay_effect_state_hash.load(
            std::memory_order_acquire));
        bundle->section_mask |= RUNTIME_SAVE_SECTION_GAMEPLAY_EFFECT;
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
    {
        std::string economy_pod_save_error;
        if (_economy_pod_authority.encode_ecp1(bundle->economy_pod_bytes,
                                               economy_pod_save_error)) {
            if (!bundle->economy_pod_bytes.empty())
                bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_POD;
        }
        // ECP1 is optional when the POD has never committed; encode failure
        // with empty bytes is not a host fault.
        if (!economy_pod_save_error.empty() &&
            economy_pod_save_error != "economy_pod_ecp1_save_blocked") {
            set_fault(economy_pod_save_error.c_str());
            return;
        }
    }
    if (_economy_ecp2_dual_write.load(std::memory_order_acquire) &&
        _economy_production_runtime != nullptr) {
        // The committed-ledger contract (capture and restore alike) needs at
        // least one economy commit. Before that there is nothing restorable
        // to write; reject the request and keep the runtime running instead
        // of faulting a healthy worker over a premature save.
        if (_economy_production_runtime->last_committed_day() < 0) {
            record_save_failure("save_requires_first_settlement");
            return;
        }
        uint32_t capture_flags = 0;
        if (_economy_ecp2_mid_epoch_save.load(std::memory_order_acquire))
            capture_flags |= ECP2_CAPTURE_ALLOW_MID_EPOCH |
                             ECP2_CAPTURE_INCLUDE_RESUME;
        RuntimeEconomyEcp2State ecp2_state;
        std::string ecp2_capture_error;
        // ECP2 records the Country identity it is bound to, and restore
        // requires it to match the Country restored from this same bundle.
        // Under worker Country authority that is the committed checkpoint
        // above, not the main-thread runtime the economy points at (which
        // stays at its bootstrap state and would never match on load).
        const bool stamp_worker_country =
            country_checkpoint != nullptr &&
            domain_is_worker_authoritative(RuntimeDomainId::COUNTRY);
        if (stamp_worker_country) {
            _economy_production_runtime->set_save_country_identity(
                country_checkpoint->generation,
                country_checkpoint->business_state_hash);
        }
        const bool ecp2_captured =
            _economy_production_runtime->capture_ecp2_authority(
                ecp2_state, ecp2_capture_error, capture_flags);
        if (stamp_worker_country)
            _economy_production_runtime->clear_save_country_identity();
        if (ecp2_captured) {
            std::string ecp2_encode_error;
            if (encode_ecp2(ecp2_state, bundle->economy_ecp2_bytes,
                            ecp2_encode_error) &&
                !bundle->economy_ecp2_bytes.empty()) {
                bundle->section_mask |= RUNTIME_SAVE_SECTION_ECONOMY_ECP2;
            } else if (!ecp2_encode_error.empty()) {
                set_fault(ecp2_encode_error.c_str());
                return;
            }
        } else if (!ecp2_capture_error.empty() &&
                   ecp2_capture_error != "save_requires_committed_boundary") {
            set_fault(ecp2_capture_error.c_str());
            return;
        }
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

    if (!bundle->economy_asset_bytes.empty()) {
        constexpr uint32_t D7_SECTION_MARKER = 0x31543744u; // D7T1
        append_u32_le(D7_SECTION_MARKER);
        const uint32_t d7_section_size = static_cast<uint32_t>(std::min<size_t>(
            bundle->economy_asset_bytes.size(), 64u * 1024u * 1024u));
        append_u32_le(d7_section_size);
        append_bytes(bundle->economy_asset_bytes.data(), d7_section_size);
        uint64_t d7_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < d7_section_size; ++i) {
            d7_checksum ^= static_cast<uint64_t>(bundle->economy_asset_bytes[i]);
            d7_checksum *= 1099511628211ull;
        }
        append_u64_le(d7_checksum);
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

    if (!bundle->gameplay_effect_bytes.empty()) {
        constexpr uint32_t GAMEPLAY_EFFECT_SECTION_MARKER = 0x31504d47u; // GMP1
        append_u32_le(GAMEPLAY_EFFECT_SECTION_MARKER);
        const uint32_t gameplay_effect_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->gameplay_effect_bytes.size(),
                             64u * 1024u * 1024u));
        append_u32_le(gameplay_effect_section_size);
        append_bytes(bundle->gameplay_effect_bytes.data(),
                     gameplay_effect_section_size);
        uint64_t gameplay_effect_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < gameplay_effect_section_size; ++i) {
            gameplay_effect_checksum ^= static_cast<uint64_t>(
                bundle->gameplay_effect_bytes[i]);
            gameplay_effect_checksum *= 1099511628211ull;
        }
        append_u64_le(gameplay_effect_checksum);
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

    if (!bundle->economy_pod_bytes.empty()) {
        constexpr uint32_t ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
        append_u32_le(ECONOMY_POD_SECTION_MARKER);
        const uint32_t economy_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->economy_pod_bytes.size(),
                             64u * 1024u * 1024u));
        append_u32_le(economy_section_size);
        append_bytes(bundle->economy_pod_bytes.data(), economy_section_size);
        uint64_t economy_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < economy_section_size; ++i) {
            economy_checksum ^=
                static_cast<uint64_t>(bundle->economy_pod_bytes[i]);
            economy_checksum *= 1099511628211ull;
        }
        append_u64_le(economy_checksum);
    }

    if (!bundle->economy_ecp2_bytes.empty()) {
        constexpr uint32_t ECONOMY_ECP2_SECTION_MARKER = 0x32504345u; // ECP2
        append_u32_le(ECONOMY_ECP2_SECTION_MARKER);
        const uint32_t ecp2_section_size = static_cast<uint32_t>(
            std::min<size_t>(bundle->economy_ecp2_bytes.size(),
                             64u * 1024u * 1024u));
        append_u32_le(ecp2_section_size);
        append_bytes(bundle->economy_ecp2_bytes.data(), ecp2_section_size);
        uint64_t ecp2_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < ecp2_section_size; ++i) {
            ecp2_checksum ^=
                static_cast<uint64_t>(bundle->economy_ecp2_bytes[i]);
            ecp2_checksum *= 1099511628211ull;
        }
        append_u64_le(ecp2_checksum);
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
    try_fault_injection("save.barrier.after");
}

void NativeSimulationHost::worker_main() {
    _worker_timing.pause(_paused.load(std::memory_order_acquire));
    _worker_timing.start();
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
    int64_t logged_pending_day = -1;
    uint32_t logged_pending_mask = 0;
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
    const auto publish_pending_count = [&]() {
        const size_t active = pending_commands.size() >= pending_begin
            ? pending_commands.size() - pending_begin : 0u;
        _economy_pending_command_count.store(static_cast<uint32_t>(std::min<size_t>(
            active, std::numeric_limits<uint32_t>::max())),
            std::memory_order_release);
        // A switch audit should measure the command that is still crossing
        // the boundary, never an unrelated command from an earlier epoch.
        if (active == 0u &&
            _command_enqueue_pos.load(std::memory_order_acquire) ==
                _command_dequeue_pos.load(std::memory_order_acquire)) {
            _last_command_admitted_us.store(0u, std::memory_order_release);
        }
    };
    publish_pending_count();
    std::shared_ptr<const RuntimeEnvironmentSnapshot> active_environment;
    try {
        while (!_stop_requested.load(std::memory_order_acquire) &&
               _state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
            if (_stop_requested.load(std::memory_order_acquire)) break;

            const bool retained_day_pending = active_environment != nullptr &&
                active_environment->day == _committed_day.load(std::memory_order_acquire) + 1;
            // PKSR 不保存 pending environment；已消费 Climate 输入的同日 ACK 也要排空。
            if (!has_pending_climate_input() && !retained_day_pending &&
                _save_requested.exchange(false, std::memory_order_acq_rel)) {
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
                publish_pending_count();
                _state.store(RuntimeWorkerState::SAVE_PENDING, std::memory_order_release);
                _worker_timing.set(RuntimeWorkerTiming::SAVE_BUILD);
                build_save_bundle(request_id, pending_commands);
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                const auto built = std::atomic_load_explicit(
                    &_save_bundle, std::memory_order_acquire);
                if (built == nullptr || built->request_id != request_id) {
                    // Every build_save_bundle failure exit returns without a
                    // bundle. Publish the failure so poll_save callers stop
                    // waiting instead of timing out with no reason.
                    if (save_failure_reason().empty()) {
                        char fault[64]{};
                        for (size_t i = 0; i + 1 < sizeof(fault) &&
                                           i < _fault_code.size(); ++i)
                            fault[i] = _fault_code[i].load(std::memory_order_relaxed);
                        record_save_failure(fault[0] != '\0'
                            ? fault : "save_bundle_not_published");
                    }
                    _save_failed_request_id.store(request_id,
                                                  std::memory_order_release);
                }
                _save_request_id.store(0, std::memory_order_release);
                // build_save_bundle reports its failures through set_fault(),
                // which already moved the worker to FAULTED and released every
                // domain. Overwriting that with PAUSED/RUNNING hid the fault: the
                // worker looked alive while owning nothing.
                if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED)
                    break;
                _state.store(_paused.load(std::memory_order_acquire)
                        ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
                        std::memory_order_release);
                last = std::chrono::steady_clock::now();
                continue;
            }

            // 自动迁移在 worker 自己释放上一日边界后尝试，不再依赖主线程
            // 抢中两天之间的短暂空隙。沿用 M6 全部准入检查和审计。
            if (_economy_auto_pod_active.load(std::memory_order_acquire) &&
                _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
                _economy_production_runtime != nullptr &&
                !_economy_production_runtime->formula_owned_bound() &&
                _stage_ops_day_phase == StageOpsDayPhase::Done &&
                _economy_pod_authority.pod_active_ready() &&
                !_save_requested.load(std::memory_order_acquire) &&
                !_stop_requested.load(std::memory_order_acquire)) {
                std::string switch_error;
                switch_economy_authority(RuntimeEconomyAuthorityMode::POD_ACTIVE,
                                         switch_error);
            }
            const bool paused = _paused.load(std::memory_order_acquire);
            const double speed = _speed_days_per_second.load(std::memory_order_acquire);
            const bool climate_driven =
                _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
                (_requested_authority_mask.load(std::memory_order_acquire) &
                 runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
            const bool climate_pending = has_pending_climate_input() || retained_day_pending;
            if ((climate_driven && !climate_pending) ||
                (!climate_driven && (paused || speed <= 0.0 || !std::isfinite(speed)))) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                _state.store(RuntimeWorkerState::PAUSED, std::memory_order_release);
                last = std::chrono::steady_clock::now();
                std::unique_lock<std::mutex> lock(_control_mutex);
                _worker_timing.set(RuntimeWorkerTiming::INPUT_WAIT);
                _control_cv.wait(lock, [&] {
                    return _stop_requested.load(std::memory_order_acquire) ||
                        _save_requested.load(std::memory_order_acquire) ||
                        (climate_driven ? (has_pending_climate_input() || retained_day_pending) :
                            (!_paused.load(std::memory_order_acquire) &&
                             _speed_days_per_second.load(std::memory_order_acquire) > 0.0));
                });
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                continue;
            }
            if (_stop_requested.load(std::memory_order_acquire)) break;
            _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
            RuntimeCommandPacket incoming;
            while (pop_command(incoming)) {
                pending_commands.push_back(incoming);
                pending_commands_dirty = true;
            }
            publish_pending_count();
            const auto now = std::chrono::steady_clock::now();
            const double elapsed = std::chrono::duration<double>(now - last).count();
            last = now;
            double debt = climate_driven ? 1.0 : std::min(100.0,
                _time_debt_days.load(std::memory_order_relaxed) + elapsed * speed);
            int64_t target_days = static_cast<int64_t>(debt);
            if (target_days <= 0) {
                _time_debt_days.store(debt, std::memory_order_release);
                const double seconds_until_day = std::max(0.001, (1.0 - debt) / speed);
                std::unique_lock<std::mutex> lock(_control_mutex);
                _worker_timing.set(RuntimeWorkerTiming::CLOCK_WAIT);
                _control_cv.wait_until(lock, std::chrono::steady_clock::now() +
                    std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                        std::chrono::duration<double>(seconds_until_day)));
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                continue;
            }
            target_days = std::min<int64_t>(target_days, 8);
            debt -= static_cast<double>(target_days);
            _time_debt_days.store(std::min(100.0, debt), std::memory_order_release);
            for (int64_t step = 0; step < target_days; ++step) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                const int64_t from_day = _committed_day.load(std::memory_order_acquire);
                const int64_t day = from_day + 1;
                // Keep the authority switch closed across the whole semantic
                // day transaction, including publish_day() and generation
                // release. Counting only execute_day_plan() leaves a small
                // race where the worker has produced a commit but has not yet
                // made that commit observable.
                _worker_timing.set(RuntimeWorkerTiming::BOUNDARY_WAIT);
                std::unique_lock<std::mutex> boundary_lock(
                    _economy_authority_boundary_mutex);
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                AtomicCounterScope day_scope(_worker_day_inflight);
                if (try_fault_injection("worker.inflight.before")) {
                    break;
                }
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
                        command.envelope.domain >= static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) &&
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
                }
                // 与 build_day_plan 钉死同一份输入：同日重试不得换 latest。
                // 跨日时（environment.day < worker 下一拍）再从 FIFO 取最旧。
                if (!active_environment ||
                    active_environment->day < day) {
                    active_environment = environment_input_for_plan();
                }
                const auto &environment = active_environment;
                // 在执行前采样唤醒游标，避免执行期间已到达的 peer ACK 被漏掉。
                const uint64_t attempt_trace_signal =
                    _climate_trace_signal.load(std::memory_order_acquire);
                const uint64_t attempt_peer_signal =
                    _country_peer_signal.load(std::memory_order_acquire);
                const uint64_t attempt_environment_signal =
                    _environment_generation.load(std::memory_order_acquire);
                const uint64_t attempt_economy_signal =
                    _economy_input_signal.load(std::memory_order_acquire);
                _worker_timing.set(RuntimeWorkerTiming::EXECUTE);
                RuntimeDayPlan day_plan = build_day_plan(
                    day, speed, environment.get());
                const auto day_attempt_started = std::chrono::steady_clock::now();
                const RuntimeDayCommit day_commit = execute_day_plan(
                    day_plan, environment.get(), day_commands, day_receipts,
                    admitted_submit_order);
                if (day % 100 == 0) {
                    std::fprintf(stderr, "[runtime-day-cost] day=%lld ok=%u ms=%.3f\n",
                        static_cast<long long>(day), static_cast<unsigned>(day_commit.preflight_ok),
                        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - day_attempt_started).count());
                }
                bool country_commands_terminal = !day_commands.empty();
                if (country_commands_terminal) {
                    std::lock_guard<std::mutex> country_lock(
                        _country_transport_mutex);
                    for (const RuntimeCommandPacket &command : day_commands) {
                        if (command.envelope.domain != static_cast<uint16_t>(
                                RuntimeDomainId::COUNTRY) ||
                            command.envelope.request_id == 0 ||
                            _country_command_terminals.find(
                                command.envelope.request_id) ==
                                _country_command_terminals.end()) {
                            country_commands_terminal = false;
                            break;
                        }
                    }
                }
                // Command ownership transfers only after the semantic day
                // commits, or after Country has published a deterministic
                // terminal rejection. A missing/future Climate frame retries
                // the same day; consuming commands before that preflight
                // silently lost one-shot Effect/Bio ingress.
                if (day_commit.preflight_ok != 0 ||
                    country_commands_terminal) {
                    for (const RuntimeCommandReceipt &receipt : day_receipts)
                        push_receipt(receipt);
                    if (consumed_commands > pending_begin) {
                        // Country may idempotent-skip an already-committed day
                        // while Effect ACK packets still sit in day_commands.
                        // Dropping those on a successful M5 day leaves
                        // PREFLIGHTED transactions without a Host receipt.
                        std::vector<RuntimeCommandPacket> retain_country;
                        if (day_commit.preflight_ok != 0 &&
                            !country_commands_terminal) {
                            std::lock_guard<std::mutex> country_lock(
                                _country_transport_mutex);
                            for (size_t index = pending_begin;
                                 index < consumed_commands; ++index) {
                                const RuntimeCommandPacket &command =
                                    pending_commands[index];
                                if (command.envelope.domain !=
                                        static_cast<uint16_t>(
                                            RuntimeDomainId::COUNTRY) ||
                                    command.envelope.request_id == 0) {
                                    continue;
                                }
                                if (_country_command_terminals.find(
                                        command.envelope.request_id) ==
                                    _country_command_terminals.end()) {
                                    retain_country.push_back(command);
                                }
                            }
                        }
                        pending_begin = consumed_commands;
                        compact_pending_commands();
                        if (!retain_country.empty()) {
                            pending_commands.insert(
                                pending_commands.begin() +
                                    static_cast<ptrdiff_t>(pending_begin),
                                std::make_move_iterator(retain_country.begin()),
                                std::make_move_iterator(retain_country.end()));
                        }
                        publish_pending_count();
                    }
                }
                if (day_commit.preflight_ok == 0) {
                    const uint32_t missing = _requested_authority_mask.load(
                        std::memory_order_acquire) & ~day_commit.completed_domain_mask;
                    // Full domain coverage with preflight_ok=0 is a spurious
                    // barrier: parking here leaves future Climate envs stuck in
                    // a full ring and nails WorldClock on capacity forever.
                    if (missing == 0u &&
                        _requested_authority_mask.load(std::memory_order_acquire) !=
                            0u) {
                        static std::atomic<int> s_full_mask_preflight_left{8};
                        if (s_full_mask_preflight_left.fetch_sub(
                                1, std::memory_order_relaxed) > 0) {
                            godot::UtilityFunctions::print(godot::vformat(
                                "[runtime-day-wait] day=%d missing=0x0 "
                                "forcing advance (spurious preflight_ok=0) ring=%d",
                                day,
                                static_cast<int64_t>(_environment_ring.size())));
                        }
                        // Drop every env Climate already absorbed for this day
                        // (or earlier). Leaving a full ring of futures after a
                        // forced advance parks Host on capacity forever — the
                        // same kill shot as the peer soft-commit path.
                        const int64_t climate_committed =
                            _climate_authority.store().committed_day;
                        const int64_t drain_through =
                            climate_committed >= day ? climate_committed : day;
                        if (_environment_ring.pop_while_day_at_most(
                                drain_through) > 0u) {
                            _climate_wait_cv.notify_all();
                            _control_cv.notify_all();
                        }
                        // Fall through to the success path below.
                    } else {
                    if (logged_pending_day != day || logged_pending_mask != missing) {
                        logged_pending_day = day;
                        logged_pending_mask = missing;
                        std::fprintf(stderr, "[runtime-day-wait] day=%lld env_day=%lld missing=0x%x economy_input=%lld\n",
                            static_cast<long long>(day),
                            static_cast<long long>(environment ? environment->day : -1),
                            missing, static_cast<long long>(economy_input_requested_day()));
                        godot::UtilityFunctions::print(godot::vformat(
                            "[runtime-day-wait] day=%d env_day=%d missing=0x%x economy_input=%d ring=%d",
                            day,
                            environment ? environment->day : -1,
                            static_cast<int64_t>(missing),
                            economy_input_requested_day(),
                            static_cast<int64_t>(_environment_ring.size())));
                    }

                    if (_state.load(std::memory_order_acquire) ==
                        RuntimeWorkerState::FAULTED) {
                        break;
                    }
                    // An input/reference barrier failure must not advance the
                    // committed clock. Wait for the main thread to publish
                    // the matching reference or for a control message; this
                    // is a condition-variable wait, not a polling sleep.
                    if (day_commit.continuation_pending == 0) {
                        _time_debt_days.store(std::min(100.0,
                            _time_debt_days.load(std::memory_order_relaxed) + 1.0),
                            std::memory_order_release);
                    }
                    // Same-day Economy→Country asset prepare must happen before
                    // parking. Otherwise Climate ring stays full, main cannot
                    // publish, and country_peer_signal never fires.
                    std::string prepare_error;
                    const uint32_t prepared_before_wait =
                        prepare_economy_origin_country_assets(prepare_error);
                    if (!prepare_error.empty()) {
                        set_fault(prepare_error.c_str());
                        break;
                    }
                    // 捕获输入时主线程必须可取得边界锁；等待期间没有公式写入。
                    boundary_lock.unlock();
                    if (prepared_before_wait > 0u) {
                        // Origin assets are now pollable; retry this day without
                        // waiting for an external wake that may never arrive.
                        break;
                    }
                    const auto next_input = _environment_ring.peek_oldest();
                    const bool stale_input_consumed = environment != nullptr &&
                        environment->day < day && next_input != nullptr &&
                        next_input->generation != environment->generation;
                    const uint64_t trace_signal = attempt_trace_signal;
                    // Under ACTIVE Climate authority there is no trace signal
                    // to wait for: production is suppressed and the only input
                    // that can unblock the day is a fresh environment publish
                    // from the main thread. Waiting on the trace alone would
                    // park the worker forever the first time the environment
                    // is not yet available.
                    const uint64_t environment_signal = attempt_environment_signal;
                    const uint64_t country_peer_signal = attempt_peer_signal;
                    std::unique_lock<std::mutex> lock(_control_mutex);
                    _worker_timing.set(RuntimeWorkerTiming::INPUT_WAIT);
                _control_cv.wait(lock, [&] {
                        // Match the save admission condition above. A pending
                        // save cannot consume an unfinished environment day;
                        // waking on the request alone spins and starves the
                        // main-thread input capture needed to finish that day.
                        const bool save_can_run =
                            _save_requested.load(std::memory_order_acquire) &&
                            !has_pending_climate_input() &&
                            !(active_environment && active_environment->day == day);
                        return _stop_requested.load(std::memory_order_acquire) ||
                            save_can_run ||
                            (!climate_driven && _paused.load(std::memory_order_acquire)) ||
                            stale_input_consumed ||
                            _climate_trace_signal.load(std::memory_order_acquire) !=
                                trace_signal ||
                            _environment_generation.load(
                                std::memory_order_acquire) != environment_signal ||
                            _country_peer_signal.load(std::memory_order_acquire) !=
                                country_peer_signal ||
                            _economy_input_signal.load(std::memory_order_acquire) !=
                                attempt_economy_signal ||
                            (!climate_driven &&
                             _climate_trace.consumable_depth() != 0);
                    });
                    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
                    break;
                    } // missing != 0
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
                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
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
    _worker_timing.stop();
}

RuntimeThreadReport NativeSimulationHost::report() const {
    RuntimeThreadReport out;
    out.worker_time_us = _worker_timing.snapshot();
    out.state = _state.load(std::memory_order_acquire);
    out.mode = _mode.load(std::memory_order_acquire);
    out.graph_coverage_complete = _graph_coverage_complete.load(std::memory_order_acquire);
    out.authority_ready = _authority_ready.load(std::memory_order_acquire);
    out.required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    out.implemented_domain_mask = implemented_domain_mask();
    out.missing_domain_mask = out.required_domain_mask & ~out.implemented_domain_mask;
    out.completion_gate_missing_domain_mask = _completion_gate_missing_domain_mask.load(std::memory_order_acquire);
    out.active_gate_blocked = _active_gate_blocked.load(std::memory_order_acquire);
    out.requested_authority_mask =
        _requested_authority_mask.load(std::memory_order_acquire);
    out.authoritative_domain_mask =
        _authoritative_domain_mask.load(std::memory_order_acquire);
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
    out.interactive = _interactive.load(std::memory_order_acquire);
    out.paused = _paused.load(std::memory_order_acquire);
    out.speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    out.committed_day = _committed_day.load(std::memory_order_acquire);
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
