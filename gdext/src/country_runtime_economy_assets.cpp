#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_host_port.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

const char *economy_asset_status_name(
        NativeCountryRuntime::AssetTransactionStatus status) {
    switch (status) {
    case NativeCountryRuntime::ECONOMY_ASSET_CREATED: return "created";
    case NativeCountryRuntime::ECONOMY_ASSET_COUNTRY_PREPARED:
        return "country_prepared";
    case NativeCountryRuntime::ECONOMY_ASSET_PEER_PREPARED:
        return "peer_prepared";
    case NativeCountryRuntime::ECONOMY_ASSET_COMMIT_DECIDED:
        return "commit_decided";
    case NativeCountryRuntime::ECONOMY_ASSET_COUNTRY_APPLIED:
        return "country_applied";
    case NativeCountryRuntime::ECONOMY_ASSET_PEER_APPLIED:
        return "peer_applied";
    case NativeCountryRuntime::ECONOMY_ASSET_COMPLETED: return "completed";
    case NativeCountryRuntime::ECONOMY_ASSET_REJECTED: return "rejected";
    case NativeCountryRuntime::ECONOMY_ASSET_AWAITING_PEER_PREPARED:
        return "awaiting_peer_prepared";
    case NativeCountryRuntime::ECONOMY_ASSET_AWAITING_PEER_APPLIED:
        return "awaiting_peer_applied";
    case NativeCountryRuntime::ECONOMY_ASSET_FAULTED: return "faulted";
    }
    return "unknown";
}

namespace {

Dictionary economy_asset_transaction_dictionary(
        const NativeCountryRuntime::EconomyAssetTransaction &transaction) {
    Dictionary out;
    out["ok"] = true;
    out["transaction_id"] = static_cast<int64_t>(transaction.transaction_id);
    out["request_id"] = static_cast<int64_t>(transaction.request_id);
    out["session_epoch"] = static_cast<int64_t>(transaction.session_epoch);
    out["origin_domain"] = static_cast<int64_t>(transaction.origin_domain);
    out["origin_epoch"] = transaction.origin_epoch;
    out["origin_stage"] = transaction.origin_stage;
    out["operation_sequence"] = static_cast<int64_t>(
        transaction.operation_sequence);
    out["operation"] = static_cast<int64_t>(transaction.operation);
    out["status"] = static_cast<int64_t>(transaction.status);
    out["status_name"] = economy_asset_status_name(transaction.status);
    out["country_handle"] = static_cast<int64_t>(transaction.country_handle);
    out["country_slot"] = transaction.country_slot;
    out["country_generation"] = static_cast<int64_t>(
        transaction.country_generation_before);
    out["peer_generation"] = static_cast<int64_t>(transaction.peer_generation);
    out["requested_cash"] = transaction.requested_cash;
    out["reserved_cash"] = transaction.reserved_cash;
    out["committed_cash"] = transaction.committed_cash;
    out["requested_quantity"] = transaction.requested_quantity;
    out["prepared_quantity"] = transaction.prepared_quantity;
    out["committed_quantity"] = transaction.committed_quantity;
    out["requested_goods_total"] = transaction.requested_goods_total;
    out["reserved_goods_total"] = transaction.reserved_goods_total;
    out["committed_goods_total"] = transaction.committed_goods_total;
    out["country_cash_before"] = transaction.country_cash_before;
    out["country_cash_after"] = transaction.country_cash_after;
    out["effective_country_day"] = transaction.effective_country_day;
    out["country_good_before"] = transaction.country_good_before;
    out["country_good_after"] = transaction.country_good_after;
    out["all_or_nothing"] = transaction.all_or_nothing;
    out["conservation_ok"] = transaction.conservation_ok;
    out["rejection_reason"] = String::utf8(
        transaction.rejection_reason.c_str());
    PackedInt32Array ids;
    PackedInt64Array quantities;
    PackedInt64Array before_goods;
    PackedInt64Array after_goods;
    ids.resize(static_cast<int64_t>(transaction.good_ids.size()));
    quantities.resize(static_cast<int64_t>(transaction.good_quantities.size()));
    before_goods.resize(ids.size());
    after_goods.resize(ids.size());
    for (int64_t i = 0; i < ids.size(); ++i) {
        ids.set(i, transaction.good_ids[static_cast<size_t>(i)]);
        quantities.set(i, transaction.good_quantities[static_cast<size_t>(i)]);
        before_goods.set(i, i < static_cast<int64_t>(
            transaction.country_goods_before.size())
            ? transaction.country_goods_before[static_cast<size_t>(i)] : 0);
        after_goods.set(i, i < static_cast<int64_t>(
            transaction.country_goods_after.size())
            ? transaction.country_goods_after[static_cast<size_t>(i)] : 0);
    }
    out["good_ids"] = ids;
    out["good_quantities"] = quantities;
    out["country_goods_before"] = before_goods;
    out["country_goods_after"] = after_goods;
    return out;
}

Dictionary economy_asset_failure(const char *code) {
    Dictionary out;
    out["ok"] = false;
    out["code"] = code;
    return out;
}

} // namespace

uint64_t NativeCountryRuntime::begin_economy_asset_transaction(
        EconomyAssetTransaction &transaction, uint64_t request_id,
        uint32_t origin_domain, int64_t origin_epoch, int32_t origin_stage) {
    if (_sync_store_writes_forbidden) {
        transaction.transaction_id = 0;
        transaction.status = ECONOMY_ASSET_REJECTED;
        transaction.rejection_reason = "country_worker_unique_writer";
        return 0;
    }
    transaction.transaction_id = _next_economy_asset_transaction_id++;
    if (transaction.transaction_id == 0)
        transaction.transaction_id = _next_economy_asset_transaction_id++;
    transaction.session_epoch = _session_epoch;
    transaction.origin_domain = origin_domain;
    transaction.origin_epoch = origin_epoch;
    transaction.origin_stage = origin_stage;
    transaction.operation_sequence = ++_economy_asset_operation_sequence;
    transaction.request_id = request_id != 0 ? request_id : transaction.transaction_id;
    transaction.status = ECONOMY_ASSET_CREATED;
    _economy_asset_request_index[transaction.request_id] =
        transaction.transaction_id;
    ++_economy_asset_transactions_created;
    return transaction.transaction_id;
}

void NativeCountryRuntime::finish_economy_asset_transaction(
        EconomyAssetTransaction &transaction, bool completed,
        const char *rejection_reason, bool conservation_failure) {
    if (completed) {
        transaction.status = ECONOMY_ASSET_COMPLETED;
        ++_economy_asset_transactions_completed;
        ++_economy_asset_complete_count;
    } else {
        transaction.status = ECONOMY_ASSET_REJECTED;
        transaction.conservation_ok = !conservation_failure;
        transaction.rejection_reason = rejection_reason == nullptr
            ? "country_economy_asset_transaction_rejected" : rejection_reason;
        ++_economy_asset_transactions_rejected;
        if (conservation_failure)
            ++_economy_asset_ledger_failures;
    }
    _economy_asset_request_index[transaction.request_id] =
        transaction.transaction_id;
    // Keep the map entry alive until every consumer has copied the terminal
    // transaction.  `transaction` is a reference into the map; erasing it
    // before copying made the history entry and the mirrored terminal receipt
    // read freed storage, so the final peer-applied ACK became
    // `transaction_unknown`.
    const uint64_t transaction_id = transaction.transaction_id;
    const EconomyAssetTransaction terminal = transaction;
    _economy_asset_transaction_history.push_back(terminal);
    _economy_asset_transactions_in_flight.erase(transaction_id);
    while (_economy_asset_transaction_history.size() > 4096)
        _economy_asset_transaction_history.pop_front();
    if (_simulation_host != nullptr && !_sync_store_writes_forbidden &&
        _simulation_host->country_pod_configured()) {
        CountryEconomyAssetRequest request;
        CountryEconomyAssetResult result;
        request.operation = static_cast<RuntimeEconomyAssetOperation>(
            terminal.operation);
        request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
        request.all_or_nothing = terminal.all_or_nothing ? 1 : 0;
        request.session_epoch = terminal.session_epoch;
        request.transaction_id = terminal.transaction_id;
        request.request_id = terminal.request_id;
        request.origin_domain = terminal.origin_domain;
        request.origin_epoch = terminal.origin_epoch;
        request.origin_stage = terminal.origin_stage;
        // Country references have already sealed _last_committed_day. An
        // external Economy mutation belongs to the next Country boundary;
        // SHADOW may be several days behind that reference when it arrives.
        request.day = terminal.effective_country_day >= 0
            ? terminal.effective_country_day
            : std::max<int64_t>(0, _last_committed_day + 1);
        request.operation_sequence = terminal.operation_sequence;
        request.country_generation = terminal.country_generation_before;
        request.peer_generation = terminal.peer_generation;
        request.country_handle = terminal.country_handle;
        request.country_slot = terminal.country_slot;
        request.good_id = terminal.good_id;
        request.good_count = static_cast<uint32_t>(std::min<size_t>(
            terminal.good_ids.size(), RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY));
        for (uint32_t i = 0; i < request.good_count; ++i) {
            request.good_ids[i] = terminal.good_ids[i];
            request.good_quantities[i] = i < terminal.good_quantities.size()
                ? terminal.good_quantities[i] : 0;
        }
        request.requested_quantity = terminal.requested_quantity;
        request.prepared_quantity = terminal.prepared_quantity;
        request.requested_cash = terminal.requested_cash;
        // The sync commit has already released its reservation. Replay needs
        // the amount that commit actually decided, not the remaining reserve.
        request.reserved_cash = terminal.committed_cash;
        request.requested_goods_total = terminal.requested_goods_total;
        request.reserved_goods_total = terminal.reserved_goods_total;
        const bool ok = terminal.status == ECONOMY_ASSET_COMPLETED;
        result.code = ok ? RuntimeEconomyAssetResultCode::COMPLETED
                         : RuntimeEconomyAssetResultCode::REJECTED;
        result.state = ok ? RuntimeEconomyAssetState::COMPLETED
                          : RuntimeEconomyAssetState::REJECTED;
        result.accepted = ok ? 1 : 0;
        result.session_epoch = terminal.session_epoch;
        result.transaction_id = terminal.transaction_id;
        result.request_id = terminal.request_id;
        result.operation = request.operation;
        result.day = request.day;
        result.country_generation = terminal.country_generation_before;
        result.peer_generation = terminal.peer_generation;
        result.committed_peer_generation = terminal.peer_generation;
        result.country_slot = terminal.country_slot;
        result.committed_quantity = terminal.committed_quantity;
        result.committed_cash = terminal.committed_cash;
        result.committed_goods_total = terminal.committed_goods_total;
        const char *reason_src = terminal.rejection_reason.c_str();
        size_t reason_i = 0;
        if (reason_src != nullptr) {
            for (; reason_i + 1u < result.reason.size() && reason_src[reason_i] != '\0';
                 ++reason_i)
                result.reason[reason_i] = reason_src[reason_i];
        }
        result.reason[reason_i] = '\0';
        std::string mirror_error;
        _simulation_host->mirror_sync_country_economy_asset(
            request, result, mirror_error);
    }
}

bool NativeCountryRuntime::find_economy_asset_transaction(
        uint64_t request_id, EconomyAssetTransaction &out) const {
    if (request_id == 0) return false;
    const auto indexed = _economy_asset_request_index.find(request_id);
    if (indexed == _economy_asset_request_index.end()) return false;
    const auto pending = _economy_asset_transactions_in_flight.find(
        indexed->second);
    if (pending != _economy_asset_transactions_in_flight.end()) {
        out = pending->second;
        return true;
    }
    for (auto it = _economy_asset_transaction_history.rbegin();
         it != _economy_asset_transaction_history.rend(); ++it) {
        if (it->transaction_id == indexed->second) {
            out = *it;
            return true;
        }
    }
    return false;
}
Dictionary NativeCountryRuntime::begin_economy_treasury_spend(
        int64_t country_handle, const PackedInt32Array &good_ids,
        const PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_TREASURY_SPEND;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_cash = cash;
    transaction.requested_goods_total = 0;
    transaction.all_or_nothing = true;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }

    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (cash < 0 || good_ids.size() != quantities.size() ||
        good_ids.size() > 4096 ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_treasury_async_target_invalid");

    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    transaction.good_ids.reserve(static_cast<size_t>(good_ids.size()));
    transaction.good_quantities.reserve(static_cast<size_t>(quantities.size()));
    const size_t base = static_cast<size_t>(slot) * _good_ids.size();
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available_cash < cash)
        return reject("country_treasury_async_cash_insufficient");
    for (int64_t i = 0; i < good_ids.size(); ++i) {
        const int32_t good_id = good_ids[i];
        const int64_t quantity = quantities[i];
        if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
            quantity < 0)
            return reject("country_treasury_async_good_invalid");
        for (const int32_t prior : transaction.good_ids)
            if (prior == good_id)
                return reject("country_treasury_async_duplicate_good");
        if (transaction.requested_goods_total >
                std::numeric_limits<int64_t>::max() - quantity)
            return reject("country_treasury_async_quantity_overflow");
        const size_t index = base + static_cast<size_t>(good_id);
        const int64_t available = _country_goods[index] -
            _economy_asset_reserved_goods[index];
        if (available < quantity)
            return reject("country_treasury_async_goods_insufficient");
        transaction.good_ids.push_back(good_id);
        transaction.good_quantities.push_back(quantity);
        transaction.requested_goods_total += quantity;
        transaction.reserved_goods_total += quantity;
        if (i == 0) transaction.good_id = good_id;
    }
    transaction.reserved_cash = cash;
    transaction.prepared_quantity = transaction.requested_goods_total;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] += cash;
    for (size_t i = 0; i < transaction.good_ids.size(); ++i)
        _economy_asset_reserved_goods[base + static_cast<size_t>(
            transaction.good_ids[i])] += transaction.good_quantities[i];
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::acknowledge_economy_asset_peer_prepared(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const String &reason) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end()) {
        EconomyAssetTransaction terminal;
        for (auto history = _economy_asset_transaction_history.rbegin();
             history != _economy_asset_transaction_history.rend(); ++history) {
            if (history->transaction_id == transaction_id) {
                terminal = *history;
                Dictionary out = economy_asset_transaction_dictionary(terminal);
                out["replayed"] = true;
                return out;
            }
        }
        return economy_asset_failure("country_treasury_async_transaction_unknown");
    }
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status == ECONOMY_ASSET_PEER_PREPARED && accepted) {
        if (session_epoch != transaction.session_epoch ||
            country_generation != transaction.country_generation_before ||
            peer_generation != transaction.peer_generation)
            return economy_asset_failure(
                "country_treasury_async_prepare_duplicate_mismatch");
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["replayed"] = true;
        return out;
    }
    if (transaction.status != ECONOMY_ASSET_AWAITING_PEER_PREPARED)
        return economy_asset_failure("country_treasury_async_prepare_state_invalid");
    if (session_epoch != transaction.session_epoch ||
        country_generation != transaction.country_generation_before ||
        peer_generation == 0)
        return economy_asset_failure("country_treasury_async_prepare_identity_mismatch");
    auto release_reservation = [&]() {
        if (transaction.country_slot < 0) return;
        const size_t slot = static_cast<size_t>(transaction.country_slot);
        _economy_asset_reserved_cash[slot] -= transaction.reserved_cash;
        const size_t base = slot * _good_ids.size();
        for (size_t i = 0; i < transaction.good_ids.size(); ++i)
            _economy_asset_reserved_goods[base + static_cast<size_t>(
                transaction.good_ids[i])] -= transaction.good_quantities[i];
        if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE &&
            slot < _economy_asset_reserved_research_points.size())
            _economy_asset_reserved_research_points[slot] -=
                transaction.prepared_quantity;
        transaction.reserved_cash = 0;
        transaction.reserved_goods_total = 0;
    };
    if (!accepted) {
        release_reservation();
        transaction.rejection_reason = reason.is_empty()
            ? "country_treasury_async_peer_prepare_rejected"
            : reason.utf8().get_data();
        finish_economy_asset_transaction(transaction, false,
            transaction.rejection_reason.c_str());
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.peer_generation = peer_generation;
    transaction.status = ECONOMY_ASSET_PEER_PREPARED;
    Dictionary out = economy_asset_transaction_dictionary(transaction);
    out["ok"] = true;
    return out;
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_FISCAL_RESERVE;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = requested;
    transaction.requested_cash = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_fiscal_async_reserve_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available <= 0)
        return reject("country_fiscal_async_reserve_cash_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.reserved_cash = transaction.prepared_quantity;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] +=
        transaction.reserved_cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_cash_credit(
        AssetOperation operation, int64_t country_handle, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        const char *invalid_reason) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = operation;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = offered;
    transaction.requested_cash = offered;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject(invalid_reason);
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    transaction.prepared_quantity = std::min(
        offered, std::numeric_limits<int64_t>::max() -
            transaction.country_cash_before);
    if (transaction.prepared_quantity <= 0)
        return reject("country_fiscal_async_credit_capacity_exhausted");
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_FISCAL_RETURN, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_fiscal_async_return_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_FISCAL_COLLECT, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_fiscal_async_collect_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_CASH_TO_COHORT;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = requested;
    transaction.requested_cash = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_cash_to_cohort_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available <= 0)
        return reject("country_cash_to_cohort_async_cash_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.reserved_cash = transaction.prepared_quantity;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] +=
        transaction.reserved_cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return begin_economy_fiscal_cash_credit(
        ECONOMY_ASSET_CASH_FROM_COHORT, country_handle, offered, origin_epoch,
        origin_stage, request_id, "country_cash_from_cohort_async_target_invalid");
}

Dictionary NativeCountryRuntime::begin_economy_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_GOOD_TO_MARKET;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.good_id = good_id;
    transaction.requested_quantity = requested;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (requested <= 0 || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_good_to_market_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const size_t index = static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(good_id);
    transaction.country_good_before = _country_goods[index];
    const int64_t available = transaction.country_good_before -
        _economy_asset_reserved_goods[index];
    if (available <= 0)
        return reject("country_good_to_market_async_goods_insufficient");
    transaction.prepared_quantity = std::min(requested, available);
    transaction.good_ids.push_back(good_id);
    transaction.good_quantities.push_back(transaction.prepared_quantity);
    transaction.requested_goods_total = requested;
    transaction.reserved_goods_total = transaction.prepared_quantity;
    _economy_asset_reserved_goods[index] += transaction.prepared_quantity;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        int64_t cash) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_GOOD_FROM_MARKET;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.good_id = good_id;
    transaction.requested_quantity = offered;
    transaction.requested_cash = cash;
    transaction.all_or_nothing = false;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }
    int32_t slot = -1;
    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    if (offered <= 0 || cash < 0 || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_good_from_market_async_target_invalid");
    transaction.country_slot = slot;
    transaction.country_generation_before = _generation;
    transaction.country_cash_before = _countries.cash[static_cast<size_t>(slot)];
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[static_cast<size_t>(slot)];
    if (available_cash < cash)
        return reject("country_good_from_market_async_cash_insufficient");
    const size_t index = static_cast<size_t>(slot) * _good_ids.size() +
        static_cast<size_t>(good_id);
    transaction.country_good_before = _country_goods[index];
    transaction.prepared_quantity = std::min(
        offered, std::numeric_limits<int64_t>::max() -
            transaction.country_good_before);
    if (transaction.prepared_quantity <= 0)
        return reject("country_good_from_market_async_capacity_exhausted");
    transaction.good_ids.push_back(good_id);
    transaction.good_quantities.push_back(transaction.prepared_quantity);
    transaction.requested_goods_total = offered;
    transaction.reserved_cash = cash;
    _economy_asset_reserved_cash[static_cast<size_t>(slot)] += cash;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::begin_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (request_id != 0) {
        EconomyAssetTransaction previous;
        if (find_economy_asset_transaction(request_id, previous)) {
            Dictionary out = economy_asset_transaction_dictionary(previous);
            out["replayed"] = true;
            return out;
        }
    }
    EconomyAssetTransaction transaction;
    transaction.operation = ECONOMY_ASSET_RESEARCH_PURCHASE;
    transaction.country_handle = static_cast<uint64_t>(country_handle);
    transaction.requested_quantity = quantity;
    transaction.requested_cash = total_cost;
    transaction.requested_goods_total = quantity;
    transaction.all_or_nothing = true;
    begin_economy_asset_transaction(transaction, request_id,
        static_cast<uint32_t>(RuntimeDomainId::ECONOMY), origin_epoch,
        origin_stage);
    if (transaction.transaction_id == 0) {
        godot::Dictionary out;
        out["ok"] = false;
        out["code"] = "country_worker_unique_writer";
        return out;
    }

    auto reject = [&](const char *reason) {
        finish_economy_asset_transaction(transaction, false, reason);
        Dictionary out = economy_asset_transaction_dictionary(transaction);
        out["ok"] = false;
        out["code"] = reason;
        return out;
    };
    int32_t slot = -1;
    if (quantity <= 0 || total_cost < 0 ||
        _technology_points_good_id < 0 ||
        _technology_points_good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot))
        return reject("country_research_purchase_async_target_invalid");

    transaction.country_slot = slot;
    transaction.good_id = _technology_points_good_id;
    transaction.country_generation_before = _generation;
    const size_t country_slot = static_cast<size_t>(slot);
    const size_t good_index = country_slot * _good_ids.size() +
        static_cast<size_t>(_technology_points_good_id);
    transaction.country_cash_before = _countries.cash[country_slot];
    transaction.country_good_before = _country_goods[good_index];
    const int64_t available_cash = transaction.country_cash_before -
        _economy_asset_reserved_cash[country_slot];
    const int64_t reserved_points =
        _economy_asset_reserved_research_points[country_slot];
    const int64_t points_capacity = std::numeric_limits<int64_t>::max() -
        transaction.country_good_before;
    const int64_t purchased_capacity = std::numeric_limits<int64_t>::max() -
        _country_research_purchased_total[country_slot];
    if (available_cash < total_cost || reserved_points > points_capacity ||
        quantity > points_capacity - reserved_points ||
        quantity > purchased_capacity)
        return reject("country_research_purchase_async_resources_insufficient");

    transaction.good_ids.push_back(_technology_points_good_id);
    transaction.good_quantities.push_back(quantity);
    transaction.prepared_quantity = quantity;
    transaction.reserved_cash = total_cost;
    _economy_asset_reserved_cash[country_slot] += total_cost;
    _economy_asset_reserved_research_points[country_slot] += quantity;
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_PREPARED;
    ++_economy_asset_prepare_count;
    _economy_asset_transactions_in_flight.emplace(
        transaction.transaction_id, transaction);
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::commit_economy_asset_transaction(
        uint64_t transaction_id) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end())
        return economy_asset_transaction_snapshot(transaction_id);
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status == ECONOMY_ASSET_AWAITING_PEER_APPLIED ||
        transaction.status == ECONOMY_ASSET_COUNTRY_APPLIED ||
        transaction.status == ECONOMY_ASSET_PEER_APPLIED) {
        return economy_asset_transaction_dictionary(transaction);
    }
    if (transaction.status != ECONOMY_ASSET_PEER_PREPARED)
        return economy_asset_failure("country_treasury_async_commit_state_invalid");
    if (transaction.operation != ECONOMY_ASSET_TREASURY_SPEND &&
        transaction.operation != ECONOMY_ASSET_FISCAL_RESERVE &&
        transaction.operation != ECONOMY_ASSET_FISCAL_RETURN &&
        transaction.operation != ECONOMY_ASSET_FISCAL_COLLECT &&
        transaction.operation != ECONOMY_ASSET_CASH_TO_COHORT &&
        transaction.operation != ECONOMY_ASSET_CASH_FROM_COHORT &&
        transaction.operation != ECONOMY_ASSET_GOOD_TO_MARKET &&
        transaction.operation != ECONOMY_ASSET_GOOD_FROM_MARKET &&
        transaction.operation != ECONOMY_ASSET_RESEARCH_PURCHASE)
        return economy_asset_failure("country_economy_async_commit_operation_invalid");
    const size_t slot = static_cast<size_t>(transaction.country_slot);
    const size_t base = slot * _good_ids.size();
    const bool credits_country = transaction.operation == ECONOMY_ASSET_FISCAL_RETURN ||
        transaction.operation == ECONOMY_ASSET_FISCAL_COLLECT ||
        transaction.operation == ECONOMY_ASSET_CASH_FROM_COHORT;
    const bool credits_goods = transaction.operation == ECONOMY_ASSET_GOOD_FROM_MARKET ||
        transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE;
    const bool moves_goods = transaction.operation == ECONOMY_ASSET_GOOD_TO_MARKET ||
        transaction.operation == ECONOMY_ASSET_GOOD_FROM_MARKET;
    const int64_t commit_cash = transaction.operation == ECONOMY_ASSET_FISCAL_RESERVE ||
        credits_country ? transaction.prepared_quantity : transaction.requested_cash;
    if ((!credits_country && _countries.cash[slot] < commit_cash) ||
        (credits_country && _countries.cash[slot] >
            std::numeric_limits<int64_t>::max() - commit_cash))
        return economy_asset_failure("country_treasury_async_commit_cash_invalid");
    for (size_t i = 0; i < transaction.good_ids.size(); ++i) {
        const size_t index = base + static_cast<size_t>(transaction.good_ids[i]);
        if ((!credits_goods && _country_goods[index] < transaction.good_quantities[i]) ||
            (credits_goods && _country_goods[index] >
                std::numeric_limits<int64_t>::max() - transaction.good_quantities[i]))
            return economy_asset_failure("country_treasury_async_commit_goods_invalid");
    }
    transaction.status = ECONOMY_ASSET_COMMIT_DECIDED;
    transaction.effective_country_day = std::max<int64_t>(0, _last_committed_day + 1);
    ++_economy_asset_commit_count;
    if (credits_country)
        _countries.cash[slot] += commit_cash;
    else
        _countries.cash[slot] -= commit_cash;
    for (size_t i = 0; i < transaction.good_ids.size(); ++i) {
        int64_t &stock = _country_goods[base + static_cast<size_t>(transaction.good_ids[i])];
        if (credits_goods) stock += transaction.good_quantities[i];
        else stock -= transaction.good_quantities[i];
    }
    if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE)
        _country_research_purchased_total[slot] += transaction.prepared_quantity;
    _economy_asset_reserved_cash[slot] -= transaction.reserved_cash;
    if (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE &&
        slot < _economy_asset_reserved_research_points.size())
        _economy_asset_reserved_research_points[slot] -=
            transaction.prepared_quantity;
    if (!credits_goods) {
        for (size_t i = 0; i < transaction.good_ids.size(); ++i)
            _economy_asset_reserved_goods[base + static_cast<size_t>(
                transaction.good_ids[i])] -= transaction.good_quantities[i];
    }
    transaction.reserved_cash = 0;
    transaction.reserved_goods_total = 0;
    transaction.committed_cash = commit_cash;
    transaction.committed_quantity = moves_goods
        ? transaction.prepared_quantity
        : (transaction.operation == ECONOMY_ASSET_FISCAL_RESERVE ||
            transaction.operation == ECONOMY_ASSET_CASH_TO_COHORT ||
            credits_country
            ? commit_cash : transaction.requested_goods_total);
    transaction.committed_goods_total = moves_goods
        ? transaction.prepared_quantity : transaction.requested_goods_total;
    transaction.country_cash_after = _countries.cash[slot];
    transaction.country_goods_before.clear();
    transaction.country_goods_after.clear();
    transaction.country_goods_before.reserve(transaction.good_ids.size());
    transaction.country_goods_after.reserve(transaction.good_ids.size());
    for (size_t i = 0; i < transaction.good_ids.size(); ++i) {
        const int64_t after = _country_goods[base + static_cast<size_t>(
            transaction.good_ids[i])];
        transaction.country_goods_after.push_back(after);
        transaction.country_goods_before.push_back(credits_goods
            ? after - transaction.good_quantities[i]
            : after + transaction.good_quantities[i]);
    }
    transaction.country_good_before = transaction.country_goods_before.empty() ? 0
        : transaction.country_goods_before[0];
    transaction.country_good_after = transaction.country_goods_after.empty() ? 0
        : transaction.country_goods_after[0];
    ++_countries.state_version[slot];
    ++_generation;
    _state_hash_cache_valid = false;
    record_direct_reference_frame(
        transaction.operation == ECONOMY_ASSET_TREASURY_SPEND
            ? "treasury_spend_async"
            : (transaction.operation == ECONOMY_ASSET_FISCAL_RESERVE
                ? "fiscal_reserve_async"
                : (transaction.operation == ECONOMY_ASSET_RESEARCH_PURCHASE
                    ? "research_procurement_async"
                    : (moves_goods ? "market_goods_async" : "fiscal_credit_async"))));
    transaction.status = ECONOMY_ASSET_COUNTRY_APPLIED;
    bool goods_conserved = transaction.country_goods_before.size() ==
        transaction.good_quantities.size() &&
        transaction.country_goods_after.size() == transaction.good_quantities.size();
    for (size_t i = 0; goods_conserved && i < transaction.good_quantities.size(); ++i)
        goods_conserved = credits_goods
            ? transaction.country_goods_after[i] - transaction.country_goods_before[i] ==
                transaction.good_quantities[i]
            : transaction.country_goods_before[i] - transaction.country_goods_after[i] ==
                transaction.good_quantities[i];
    const bool cash_conserved = credits_country
        ? transaction.country_cash_after - transaction.country_cash_before ==
            transaction.committed_cash
        : transaction.country_cash_before - transaction.country_cash_after ==
            transaction.committed_cash;
    if (!cash_conserved || !goods_conserved) {
        transaction.conservation_ok = false;
        transaction.status = ECONOMY_ASSET_FAULTED;
        transaction.rejection_reason = transaction.operation ==
                ECONOMY_ASSET_RESEARCH_PURCHASE
            ? "research_purchase_async_conservation_failure"
            : "country_treasury_async_conservation_failure";
        ++_economy_asset_ledger_failures;
        _economy_asset_request_index[transaction.request_id] = transaction_id;
        _economy_asset_transaction_history.push_back(transaction);
        _economy_asset_transactions_in_flight.erase(transaction_id);
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.status = ECONOMY_ASSET_AWAITING_PEER_APPLIED;
    return economy_asset_transaction_dictionary(transaction);
}

Dictionary NativeCountryRuntime::commit_economy_treasury_spend(
        uint64_t transaction_id) {
    return commit_economy_asset_transaction(transaction_id);
}

Dictionary NativeCountryRuntime::acknowledge_economy_asset_peer_applied(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const String &reason) {
    auto it = _economy_asset_transactions_in_flight.find(transaction_id);
    if (it == _economy_asset_transactions_in_flight.end()) {
        Dictionary out = economy_asset_transaction_snapshot(transaction_id);
        if (static_cast<bool>(out.get("ok", false))) out["replayed"] = true;
        return out;
    }
    EconomyAssetTransaction &transaction = it->second;
    if (transaction.status != ECONOMY_ASSET_AWAITING_PEER_APPLIED)
        return economy_asset_failure("country_treasury_async_apply_state_invalid");
    if (session_epoch != transaction.session_epoch ||
        country_generation != transaction.country_generation_before ||
        peer_generation != transaction.peer_generation)
        return economy_asset_failure("country_treasury_async_apply_identity_mismatch");
    if (!accepted) {
        transaction.status = ECONOMY_ASSET_FAULTED;
        transaction.conservation_ok = false;
        transaction.rejection_reason = reason.is_empty()
            ? "country_treasury_async_peer_apply_rejected"
            : reason.utf8().get_data();
        ++_economy_asset_ledger_failures;
        _economy_asset_request_index[transaction.request_id] = transaction_id;
        _economy_asset_transaction_history.push_back(transaction);
        _economy_asset_transactions_in_flight.erase(transaction_id);
        return economy_asset_transaction_snapshot(transaction_id);
    }
    transaction.status = ECONOMY_ASSET_PEER_APPLIED;
    finish_economy_asset_transaction(transaction, true);
    return economy_asset_transaction_snapshot(transaction_id);
}

Dictionary NativeCountryRuntime::economy_asset_transaction_snapshot(
        uint64_t transaction_id) const {
    const auto pending = _economy_asset_transactions_in_flight.find(transaction_id);
    if (pending != _economy_asset_transactions_in_flight.end())
        return economy_asset_transaction_dictionary(pending->second);
    for (auto it = _economy_asset_transaction_history.rbegin();
         it != _economy_asset_transaction_history.rend(); ++it) {
        if (it->transaction_id == transaction_id)
            return economy_asset_transaction_dictionary(*it);
    }
    return economy_asset_failure("country_treasury_async_transaction_unknown");
}

int64_t NativeCountryRuntime::complete_economy_asset_compatibility(
        const Dictionary &begin) {
    if (!static_cast<bool>(begin.get("ok", false))) return 0;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed"
            ? static_cast<int64_t>(begin.get("committed_quantity", 0)) : 0;
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    if (transaction_id == 0 || session_epoch == 0 || country_generation == 0)
        return 0;
    // Legacy Economy callers remain synchronous until the real peer
    // coordinator is connected. They still traverse the typed protocol.
    const uint64_t peer_generation = transaction_id;
    const Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return 0;
    const Dictionary committed = commit_economy_asset_transaction(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return 0;
    const Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
            String(applied.get("status_name", "")) == "completed"
        ? static_cast<int64_t>(applied.get("committed_quantity", 0)) : 0;
}

int64_t NativeCountryRuntime::economy_reserve_fiscal_cash(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_reserve(
        country_handle, requested, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_return_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_return(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_collect_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_collect(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

bool NativeCountryRuntime::economy_purchase_research_points(
        int32_t country_slot, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (country_slot < 0 ||
        country_slot >= static_cast<int32_t>(_countries.active.size()))
        return false;
    const uint64_t handle = make_handle(country_slot);
    // The legacy production caller is still synchronous, but it now traverses
    // the same typed transaction state machine.  The synthetic peer ACKs are a
    // compatibility adapter until NativeEconomyRuntime owns the real market
    // prepare/apply coordinator; they must not be used as ACTIVE authority.
    Dictionary begin = begin_economy_research_purchase(
        static_cast<int64_t>(handle), quantity, total_cost, origin_epoch,
        origin_stage, request_id);
    if (!static_cast<bool>(begin.get("ok", false))) return false;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed";
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    const uint64_t peer_generation = transaction_id;
    Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return false;
    Dictionary committed = commit_economy_asset_transaction(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return false;
    Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
}

Dictionary NativeCountryRuntime::economy_asset_transaction_report() const {
    Dictionary out;
    out["created"] = static_cast<int64_t>(_economy_asset_transactions_created);
    out["completed"] = static_cast<int64_t>(_economy_asset_transactions_completed);
    out["rejected"] = static_cast<int64_t>(_economy_asset_transactions_rejected);
    out["prepared"] = static_cast<int64_t>(_economy_asset_prepare_count);
    out["commit_decisions"] = static_cast<int64_t>(_economy_asset_commit_count);
    out["complete"] = static_cast<int64_t>(_economy_asset_complete_count);
    out["ledger_failures"] = _economy_asset_ledger_failures;
    out["next_transaction_id"] = static_cast<int64_t>(_next_economy_asset_transaction_id);
    out["operation_sequence"] = static_cast<int64_t>(_economy_asset_operation_sequence);
    out["history_size"] = static_cast<int64_t>(_economy_asset_transaction_history.size());
    out["in_flight"] = static_cast<int64_t>(
        _economy_asset_transactions_in_flight.size());
    int64_t reserved_cash = 0;
    int64_t reserved_goods = 0;
    int64_t reserved_research_points = 0;
    for (const int64_t value : _economy_asset_reserved_cash)
        if (value > 0 && reserved_cash <=
                std::numeric_limits<int64_t>::max() - value)
            reserved_cash += value;
    for (const int64_t value : _economy_asset_reserved_goods)
        if (value > 0 && reserved_goods <=
                std::numeric_limits<int64_t>::max() - value)
            reserved_goods += value;
    for (const int64_t value : _economy_asset_reserved_research_points)
        if (value > 0 && reserved_research_points <=
                std::numeric_limits<int64_t>::max() - value)
            reserved_research_points += value;
    out["reserved_cash"] = reserved_cash;
    out["reserved_goods"] = reserved_goods;
    out["reserved_research_points"] = reserved_research_points;
    out["faulted"] = static_cast<int64_t>(std::count_if(
        _economy_asset_transaction_history.begin(),
        _economy_asset_transaction_history.end(), [](const auto &transaction) {
            return transaction.status == ECONOMY_ASSET_FAULTED;
        }));
    return out;
}

bool NativeCountryRuntime::purchase_research_points(int32_t country_slot,
                                                     int64_t quantity,
                                                     int64_t total_cost) {
    return economy_purchase_research_points(country_slot, quantity, total_cost,
        -1, -1);
}
int64_t NativeCountryRuntime::debit_country_cash(
        int64_t country_handle, int64_t requested, const char *trace_stage) {
    int32_t slot = -1;
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t moved = std::min(requested, _countries.cash[static_cast<size_t>(slot)]);
    _countries.cash[static_cast<size_t>(slot)] -= moved;
    if (moved > 0) {
        ++_countries.state_version[static_cast<size_t>(slot)];
        ++_generation;
        _state_hash_cache_valid = false;
        record_direct_reference_frame(trace_stage);
    }
    return moved;
}

int64_t NativeCountryRuntime::transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested) {
    return economy_transfer_cash_to_cohort(country_handle, requested, -1, -1);
}

int64_t NativeCountryRuntime::cash_for_handle(int64_t country_handle) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(country_handle), slot)
        ? _countries.cash[static_cast<size_t>(slot)] : 0;
}

int64_t NativeCountryRuntime::good_for_handle(int64_t country_handle,
                                               int32_t good_id) const {
    int32_t slot = -1;
    if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    return _country_goods[static_cast<size_t>(slot) * _good_ids.size() +
                          static_cast<size_t>(good_id)];
}

bool NativeCountryRuntime::spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash) {
    return economy_spend_treasury_assets(country_handle, good_ids, quantities,
        good_count, cash, -1, -1);
}

int64_t NativeCountryRuntime::credit_country_cash(
        int64_t country_handle, int64_t offered, const char *trace_stage) {
    int32_t slot = -1;
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t room = std::numeric_limits<int64_t>::max() - _countries.cash[static_cast<size_t>(slot)];
    const int64_t moved = std::min(offered, room);
    _countries.cash[static_cast<size_t>(slot)] += moved;
    if (moved > 0) {
        ++_countries.state_version[static_cast<size_t>(slot)];
        ++_generation;
        _state_hash_cache_valid = false;
        record_direct_reference_frame(trace_stage);
    }
    return moved;
}

int64_t NativeCountryRuntime::economy_transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_cash_to_cohort(
        country_handle, requested, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_cash_from_cohort(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_transfer_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_good_to_market(
        country_handle, good_id, requested, origin_epoch, origin_stage,
        request_id));
}

int64_t NativeCountryRuntime::economy_transfer_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_good_from_market(
        country_handle, good_id, offered, origin_epoch, origin_stage,
        request_id));
}

bool NativeCountryRuntime::economy_spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    PackedInt32Array ids;
    PackedInt64Array amounts;
    ids.resize(static_cast<int64_t>(good_count));
    amounts.resize(static_cast<int64_t>(good_count));
    for (size_t i = 0; i < good_count; ++i) {
        ids.set(static_cast<int64_t>(i), good_ids == nullptr ? -1 : good_ids[i]);
        amounts.set(static_cast<int64_t>(i),
            quantities == nullptr ? -1 : quantities[i]);
    }
    Dictionary begin = begin_economy_treasury_spend(
        country_handle, ids, amounts, cash, origin_epoch, origin_stage,
        request_id);
    if (!static_cast<bool>(begin.get("ok", false))) return false;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed";
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    const uint64_t peer_generation = transaction_id;
    Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return false;
    Dictionary committed = commit_economy_treasury_spend(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return false;
    Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
}

int64_t NativeCountryRuntime::transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered) {
    return economy_transfer_cash_from_cohort(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::reserve_fiscal_cash(int64_t country_handle,
                                                   int64_t requested) {
    return economy_reserve_fiscal_cash(country_handle, requested, -1, -1);
}

int64_t NativeCountryRuntime::return_fiscal_cash(int64_t country_handle,
                                                  int64_t offered) {
    return economy_return_fiscal_cash(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::collect_fiscal_cash(int64_t country_handle,
                                                   int64_t offered) {
    return economy_collect_fiscal_cash(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                                       int64_t requested) {
    return economy_transfer_good_to_market(country_handle, good_id, requested,
        -1, -1);
}

int64_t NativeCountryRuntime::transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                                         int64_t offered) {
    return economy_transfer_good_from_market(country_handle, good_id, offered,
        -1, -1);
}

bool NativeCountryRuntime::copy_economy_snapshot(EconomySnapshot &out) const {
    if (!economy_available()) return false;
    // Pin one immutable Country commit for the whole economic freeze. The
    // legacy store stops advancing as soon as the worker owns Country.
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
    const auto &_cell_country_slot = worker ? worker->cell_country_slot : this->_cell_country_slot;
    const auto &_country_technologies = worker ? worker->country_technologies : this->_country_technologies;
    const auto &_country_research_signals = worker
        ? worker->country_research_signals : this->_country_research_signals;
    const auto &_country_tax_defaults = worker ? worker->country_tax_defaults : this->_country_tax_defaults;
    const auto &_country_tax_default_modes = worker ? worker->country_tax_default_modes : this->_country_tax_default_modes;
    const auto &_cell_tax_policy_ids = worker ? worker->cell_tax_policy_ids : this->_cell_tax_policy_ids;
    const auto &_country_income_tax_overrides = worker ? worker->country_income_tax_overrides : this->_country_income_tax_overrides;
    const auto &_country_income_tax_mode_overrides = worker ? worker->country_income_tax_mode_overrides : this->_country_income_tax_mode_overrides;
    const auto &_country_consumption_tax_overrides = worker ? worker->country_consumption_tax_overrides : this->_country_consumption_tax_overrides;
    const auto &_country_consumption_tax_mode_overrides = worker ? worker->country_consumption_tax_mode_overrides : this->_country_consumption_tax_mode_overrides;
    const auto &_country_business_tax_overrides = worker ? worker->country_business_tax_overrides : this->_country_business_tax_overrides;
    const auto &_country_business_tax_mode_overrides = worker ? worker->country_business_tax_mode_overrides : this->_country_business_tax_mode_overrides;
    const auto &_country_import_tax_overrides = worker ? worker->country_import_tax_overrides : this->_country_import_tax_overrides;
    const auto &_country_import_tax_mode_overrides = worker ? worker->country_import_tax_mode_overrides : this->_country_import_tax_mode_overrides;
    const auto &_country_export_tax_overrides = worker ? worker->country_export_tax_overrides : this->_country_export_tax_overrides;
    const auto &_country_export_tax_mode_overrides = worker ? worker->country_export_tax_mode_overrides : this->_country_export_tax_mode_overrides;

    out.cell_country_slot = _cell_country_slot;
    const auto &active = worker ? worker->country_active : _countries.active;
    const auto &generations = worker ? worker->country_generation : _countries.generation;
    const auto &regime_ids = worker ? worker->country_political_regime_ids : _countries.political_regime_id;
    const auto &regime_caps = worker ? worker->country_political_regime_capabilities : _countries.political_regime_capability_bits;
    out.country_handles.resize(active.size());
    for (size_t slot = 0; slot < active.size(); ++slot)
        out.country_handles[slot] = active[slot] != 0
            ? (uint64_t{generations[slot]} << 32u) | static_cast<uint32_t>(slot) : 0;
    out.country_political_regime_ids = regime_ids;
    out.country_political_regime_capabilities = regime_caps;
    out.country_technologies = _country_technologies;
    out.country_research_signals = _country_research_signals;
    out.country_count = static_cast<int32_t>(active.size());
    out.technology_words = _technology_words;
    out.research_signal_words = worker
        ? static_cast<int32_t>(worker->research_signal_words)
        : _research_signal_words;
    out.research_signal_count = worker
        ? static_cast<int32_t>(worker->research_signal_count)
        : static_cast<int32_t>(_research_signal_ids.size());
    out.profession_count = static_cast<int32_t>(_profession_ids.size());
    out.good_count = static_cast<int32_t>(_good_ids.size());
    out.building_type_count =
        static_cast<int32_t>(_building_type_ids.size());
    auto resolve_all = [&](int32_t kind,
                           const std::vector<int32_t> &overrides,
                           const std::vector<int32_t> &mode_overrides,
                           std::vector<int32_t> &rates,
                           std::vector<int32_t> &modes) {
        const int32_t item_count = tax_item_count(kind);
        rates.resize(static_cast<size_t>(out.country_count) * item_count);
        modes.resize(static_cast<size_t>(out.country_count) * item_count);
        for (int32_t slot = 0; slot < out.country_count; ++slot) {
            for (int32_t item = 0; item < item_count; ++item) {
                const size_t index =
                    static_cast<size_t>(slot) * item_count + item;
                rates[index] = resolved_tax_rate(
                    _country_tax_defaults, overrides, slot, kind, item,
                    item_count);
                modes[index] = resolved_tax_mode(
                    _country_tax_default_modes, mode_overrides, slot, kind,
                    item, item_count);
            }
        }
    };
    resolve_all(TAX_INCOME, _country_income_tax_overrides,
                _country_income_tax_mode_overrides, out.income_tax_rates,
                out.income_tax_modes);
    resolve_all(TAX_CONSUMPTION, _country_consumption_tax_overrides,
                _country_consumption_tax_mode_overrides,
                out.consumption_tax_rates, out.consumption_tax_modes);
    resolve_all(TAX_BUSINESS, _country_business_tax_overrides,
                _country_business_tax_mode_overrides, out.business_tax_rates,
                out.business_tax_modes);
    resolve_all(TAX_IMPORT, _country_import_tax_overrides,
                _country_import_tax_mode_overrides, out.import_tax_rates,
                out.import_tax_modes);
    resolve_all(TAX_EXPORT, _country_export_tax_overrides,
                _country_export_tax_mode_overrides, out.export_tax_rates,
                out.export_tax_modes);
    out.cell_tax_policy_ids = _cell_tax_policy_ids;
    if (worker) {
        out.cell_tax_policies.clear();
        for (const auto &policy : worker->cell_tax_policies) {
            CellTaxPolicy row;
            row.defaults = policy.defaults;
            row.default_modes = policy.modes;
            for (const auto &v : policy.overrides)
                row.overrides.push_back({v.kind, v.item, v.rate, v.mode});
            out.cell_tax_policies.push_back(std::move(row));
        }
    } else {
        out.cell_tax_policies = _cell_tax_policies;
    }
    out.tax_policy_version = worker ? worker->generation : _tax_policy_version;
    out.generation = worker ? worker->generation : _generation;
    out.state_hash = worker ? worker->state_hash : compute_state_hash();
    return true;
}

} // namespace pk
