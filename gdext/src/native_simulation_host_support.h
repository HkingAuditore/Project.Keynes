#pragma once

#include "native_simulation_host.h"
#include <algorithm>
#include <type_traits>

// Stateless helpers shared by the mechanically separated host members.
// Anonymous linkage is retained; mutable/static caches do not belong here.
namespace pk {
namespace {

template <typename T>
inline bool read_modifier_payload(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    if (data == nullptr || cursor > size || size - cursor < sizeof(T)) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(T);
    value = static_cast<T>(bits);
    return true;
}

inline bool decode_modifier_packet(const RuntimeCommandPacket &packet,
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

inline bool modifier_packet_shape_valid(const RuntimeModifierPodCommand &command) {
    return command.opcode >= static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY) &&
        command.opcode <= static_cast<uint16_t>(RuntimeModifierPodOpcode::SET_MAGNITUDE) &&
        command.domain < 4u && command.scope >= 0 && command.scope < 3 &&
        command.effective_day >= 0;
}

inline bool map_country_peer_intent(const RuntimeDomainIntent &intent,
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

inline bool economy_asset_operation_valid(RuntimeEconomyAssetOperation operation) {
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

inline bool economy_asset_state_valid(RuntimeEconomyAssetState state) {
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

inline bool economy_asset_result_terminal(const RuntimeEconomyAssetResult &result) {
    return result.code == RuntimeEconomyAssetResultCode::COMPLETED ||
        result.code == RuntimeEconomyAssetResultCode::REJECTED ||
        result.code == RuntimeEconomyAssetResultCode::FAULTED ||
        result.state == RuntimeEconomyAssetState::COMPLETED ||
        result.state == RuntimeEconomyAssetState::REJECTED ||
        result.state == RuntimeEconomyAssetState::FAULTED;
}

inline int economy_asset_state_rank(RuntimeEconomyAssetState state) {
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

inline bool economy_asset_result_code_state_valid(
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

inline bool economy_asset_request_equal(const RuntimeEconomyAssetRequest &lhs,
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

inline bool economy_asset_country_prepare_transition_valid(
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

inline bool economy_asset_result_equal(const RuntimeEconomyAssetResult &lhs,
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

inline bool economy_asset_request_shape_valid(
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

inline bool economy_asset_journal_request_valid(
        const RuntimeEconomyAssetRequest &request, std::string &error,
        bool terminal_history = false) {
    if (!economy_asset_state_valid(request.state)) {
        error = "d7_transaction_journal_request_state_invalid";
        return false;
    }
    RuntimeEconomyAssetRequest admission = request;
    // Historical terminal transfers may predate a captured calendar context.
    // Keep their persisted day=-1 identity; only admission-shape validation
    // uses day zero, and never for an unresolved transaction.
    if (terminal_history && request.day == -1)
        admission.day = 0;
    admission.state = request.origin_domain ==
            static_cast<uint32_t>(RuntimeDomainId::ECONOMY)
        ? RuntimeEconomyAssetState::CREATED
        : RuntimeEconomyAssetState::COUNTRY_PREPARED;
    return economy_asset_request_shape_valid(admission, error);
}
// Copies text into an atomic char buffer one character at a time. The reader
// loads the same way, so a partially written value can be observed as a
// truncated string but never as a torn one.
template <size_t N>
inline void store_atomic_text(std::array<std::atomic<char>, N> &destination,
                       const char *source) {
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < N && source[index] != '\0'; ++index)
            destination[index].store(source[index], std::memory_order_relaxed);
    }
    for (; index < N; ++index)
        destination[index].store('\0', std::memory_order_relaxed);
}
inline void store_atomic_chars(std::array<std::atomic<char>, 64> &dst, const char *src) {
    size_t i = 0;
    if (src != nullptr) {
        for (; i + 1u < dst.size() && src[i] != '\0'; ++i)
            dst[i].store(src[i], std::memory_order_relaxed);
    }
    for (; i < dst.size(); ++i)
        dst[i].store('\0', std::memory_order_relaxed);
}

inline void store_atomic_chars48(std::array<std::atomic<char>, 48> &dst, const char *src) {
    size_t i = 0;
    if (src != nullptr) {
        for (; i + 1u < dst.size() && src[i] != '\0'; ++i)
            dst[i].store(src[i], std::memory_order_relaxed);
    }
    for (; i < dst.size(); ++i)
        dst[i].store('\0', std::memory_order_relaxed);
}

inline void load_atomic_chars(const std::array<std::atomic<char>, 64> &src, char *dst, size_t cap) {
    size_t i = 0;
    for (; i + 1u < cap && i < src.size(); ++i) {
        dst[i] = src[i].load(std::memory_order_relaxed);
        if (dst[i] == '\0') return;
    }
    if (cap > 0) dst[std::min(i, cap - 1u)] = '\0';
}

inline void load_atomic_chars48(const std::array<std::atomic<char>, 48> &src, char *dst, size_t cap) {
    size_t i = 0;
    for (; i + 1u < cap && i < src.size(); ++i) {
        dst[i] = src[i].load(std::memory_order_relaxed);
        if (dst[i] == '\0') return;
    }
    if (cap > 0) dst[std::min(i, cap - 1u)] = '\0';
}


} // namespace
} // namespace pk
