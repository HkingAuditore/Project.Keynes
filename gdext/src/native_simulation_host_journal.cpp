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
            request.session_epoch == 0 ||
            (request.session_epoch != serialized_session &&
             ((flags & 7u) != 7u || (flags & (8u | 16u)) != 0)) ||
            !requests.emplace(request_id, request).second) {
            error = "d7_transaction_journal_request_invalid";
            return false;
        }
        std::string shape_error;
        const bool terminal_history = (flags & 7u) == 7u &&
            (flags & (8u | 16u)) == 0;
        if (!economy_asset_journal_request_valid(request, shape_error, terminal_history)) {
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

} // namespace pk
