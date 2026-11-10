#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "country_api.h"
#include "economy_runtime_internal_external_types.inc"
#include "economy_host_port.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;


namespace {
bool reconcile_trigger_branch_binding(TriggerRuntime *runtime,
                                      const std::string &key,
                                      uint64_t branch_handle,
                                      int32_t cell,
                                      int32_t reward_target,
                                      bool enabled) {
    if (runtime == nullptr || key.empty()) return false;
    Dictionary batch;
    PackedStringArray keys;
    PackedInt64Array branches;
    PackedInt32Array cells;
    PackedInt32Array rewards;
    PackedByteArray states;
    keys.push_back(key.c_str());
    branches.push_back(static_cast<int64_t>(branch_handle));
    cells.push_back(cell);
    rewards.push_back(reward_target);
    states.push_back(enabled ? 1 : 0);
    batch["trigger_keys"] = keys;
    batch["branch_handles"] = branches;
    batch["cells"] = cells;
    batch["reward_targets"] = rewards;
    batch["enabled"] = states;
    const Dictionary result = runtime->reconcile_branch_bindings(batch);
    return static_cast<bool>(result.get("ok", false));
}

} // namespace

namespace {

using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

#define PK_RESOURCE_SCRATCH_ACCESSOR(TYPE, METHOD, COLUMN, LOCAL)              \
    std::vector<TYPE> &NativeEconomyRuntime::METHOD() noexcept {               \
        if (_resource_store_alias != nullptr)                                  \
            return _resource_store_alias->COLUMN;                              \
        return LOCAL;                                                          \
    }                                                                          \
    const std::vector<TYPE> &NativeEconomyRuntime::METHOD() const noexcept {   \
        if (_resource_store_alias != nullptr)                                  \
            return _resource_store_alias->COLUMN;                              \
        return LOCAL;                                                          \
    }

PK_RESOURCE_SCRATCH_ACCESSOR(int64_t, resource_remaining_lanes, remaining,
                             _resource_remaining)
PK_RESOURCE_SCRATCH_ACCESSOR(int64_t, resource_harvest_remaining_lanes,
                             harvest_remaining, _resource_harvest_remaining)
PK_RESOURCE_SCRATCH_ACCESSOR(int64_t, resource_delta_lanes, deltas,
                             _resource_deltas)
PK_RESOURCE_SCRATCH_ACCESSOR(uint32_t, resource_lane_generation_lanes,
                             lane_generation, _resource_lane_generation)
#undef PK_RESOURCE_SCRATCH_ACCESSOR

bool NativeEconomyRuntime::coordinate_country_fiscal_transaction(
        int32_t country, int32_t operation, int64_t amount,
        int64_t &committed, std::string &error,
        uint64_t *transport_request_id) {
    committed = 0;
    error.clear();
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        error = "country_fiscal_peer_unavailable";
        return false;
    }
    if (country < 0 || country >= _epoch_country_count ||
        country >= static_cast<int32_t>(_epoch_country_handles.size()) ||
        amount <= 0) {
        error = "country_fiscal_peer_request_invalid";
        return false;
    }
    if (_simulation_host != nullptr &&
        (country_reads().sync_store_writes_forbidden() ||
         _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) &&
        transport_request_id != nullptr &&
        *transport_request_id != 0) {
        RuntimeEconomyAssetResult terminal;
        if (_simulation_host->country_economy_asset_terminal_result(
                *transport_request_id, terminal)) {
            if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
                terminal.operation != static_cast<RuntimeEconomyAssetOperation>(operation)) {
                _simulation_host->acknowledge_country_economy_asset_consumed(
                    *transport_request_id);
                error = "country_economy_asset_host_terminal_rejected";
                return false;
            }
            // Peer completion has debited Economy escrow, but Country's
            // terminal commit/read snapshot must also be visible to this
            // worker before the same epoch's conservation audit.
            if (_simulation_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY) &&
                !_simulation_host->finish_worker_country_asset(
                    *transport_request_id, terminal, error))
                return false;
            committed = terminal.committed_quantity > 0
                ? terminal.committed_quantity : terminal.committed_cash;
            if (committed <= 0 || committed > amount) {
                error = "country_economy_asset_host_terminal_quantity_invalid";
                return false;
            }
            _simulation_host->acknowledge_country_economy_asset_consumed(
                *transport_request_id);
            return true;
        }
    }
    if (block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(operation),
            static_cast<int64_t>(_epoch_country_handles[static_cast<size_t>(country)]),
            amount, amount, -1, error, transport_request_id) !=
            CountryWorkerAssetRoute::NOT_APPLICABLE)
        return false;
    const int64_t handle = static_cast<int64_t>(
        _epoch_country_handles[static_cast<size_t>(country)]);
    const bool returning = operation == CountryApi::ECONOMY_ASSET_FISCAL_RETURN;
    const auto return_port = country_api::fiscal_return_port(*_country_runtime);
    godot::Dictionary begun;
    if (operation == CountryApi::ECONOMY_ASSET_FISCAL_RESERVE)
        begun = return_port.submit_cash(return_port.reserve_intent(
            handle, amount, _epoch_id.get(), static_cast<int32_t>(_stage)));
    else if (returning)
        begun = return_port.submit({return_port.next_order_key(),
            handle, amount, _epoch_id.get(), static_cast<int32_t>(_stage)});
    else if (operation == CountryApi::ECONOMY_ASSET_FISCAL_COLLECT)
        begun = return_port.submit_cash(return_port.collect_intent(
            handle, amount, _epoch_id.get(), static_cast<int32_t>(_stage)));
    else {
        error = "country_fiscal_peer_operation_invalid";
        return false;
    }
    if (!static_cast<bool>(begun.get("ok", false))) {
        error = String(begun.get("code", "country_fiscal_country_rejected")).utf8().get_data();
        return false;
    }
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("country_generation", 0)));
    const int64_t prepared_quantity = static_cast<int64_t>(
        begun.get("prepared_quantity", 0));
    const uint64_t peer_generation = _committed_generation;
    if (transaction_id == 0 || session_epoch == 0 || country_generation == 0 ||
        prepared_quantity <= 0 || peer_generation == 0) {
        error = "country_fiscal_peer_identity_invalid";
        return false;
    }
    const size_t country_index = static_cast<size_t>(country);
    const int64_t escrow = country_index < _fiscal_escrow_by_country.size()
        ? _fiscal_escrow_by_country[country_index] : 0;
    if (operation != CountryApi::ECONOMY_ASSET_FISCAL_RESERVE &&
        escrow < prepared_quantity) {
        return_port.prepared(
            {transaction_id, session_epoch, country_generation, peer_generation},
            false, "country_fiscal_peer_escrow_insufficient");
        error = "country_fiscal_peer_escrow_insufficient";
        return false;
    }
    if (operation == CountryApi::ECONOMY_ASSET_FISCAL_RESERVE &&
        escrow > std::numeric_limits<int64_t>::max() - prepared_quantity) {
        return_port.prepared(
            {transaction_id, session_epoch, country_generation, peer_generation},
            false, "country_fiscal_peer_escrow_overflow");
        error = "country_fiscal_peer_escrow_overflow";
        return false;
    }
    const godot::Dictionary prepared = return_port.prepared(
        {transaction_id, session_epoch, country_generation, peer_generation}, true, "");
    if (!static_cast<bool>(prepared.get("ok", false))) {
        error = "country_fiscal_peer_prepare_failed";
        return false;
    }
    const godot::Dictionary commit = return_port.apply(transaction_id);
    if (!static_cast<bool>(commit.get("ok", false))) {
        error = String(commit.get("code", "country_fiscal_country_commit_failed")).utf8().get_data();
        return false;
    }
    const int64_t actual = static_cast<int64_t>(
        commit.get("committed_quantity", prepared_quantity));
    if (actual <= 0 || actual > prepared_quantity) {
        error = "country_fiscal_peer_commit_quantity_invalid";
        return false;
    }
    if (operation == CountryApi::ECONOMY_ASSET_FISCAL_RESERVE)
        _fiscal_escrow_by_country.write_scalar(country_index, escrow + actual, market_mutation_sink());
    else
        _fiscal_escrow_by_country.write_scalar(country_index, escrow - actual, market_mutation_sink());
    // 无 worker 权威时（web / 主线程权威），这次 peer-applied ack 只是跨域账本
    // 的握手：commit 已经成功、escrow 也已经更新，握手失败不该把整个经济升级成
    // fatal（实测 web 上 day 1 就是死在这里）。有 worker 权威时保持原语义。
    const godot::Dictionary applied = return_port.applied(
        {transaction_id, session_epoch, country_generation, peer_generation}, true, "");
    const bool ack_completed =
        static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
    committed = actual;
    if (!ack_completed) {
        const bool worker_authoritative =
            _simulation_host != nullptr &&
            _simulation_host->domain_is_worker_authoritative(
                RuntimeDomainId::COUNTRY);
        if (!worker_authoritative) {
            return true;
        }
        error = "country_fiscal_peer_apply_ack_failed";
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::coordinate_country_cohort_cash(
        int32_t cohort_slot, int64_t country_handle, int32_t operation,
        int64_t amount, int64_t &committed, std::string &error) {
    committed = 0;
    error.clear();
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        error = "country_cohort_cash_peer_unavailable";
        return false;
    }
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            population_store().active.size()) || population_store().active[cohort_slot] == 0 ||
        (operation != CountryApi::ECONOMY_ASSET_CASH_TO_COHORT &&
         operation != CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT)) {
        error = "country_cohort_cash_request_invalid";
        return false;
    }
    if (amount < 0) {
        // An indebted estate or residue has no cash to hand over. Structural
        // callers keep the drained cohort and its debt rather than mint or burn.
        error = "country_cohort_cash_negative_balance";
        return true;
    }
    if (amount == 0) return true;
    if (country_handle == 0) {
        // A cohort can sit in a cell whose Country claim has not committed yet
        // (a settling expedition). There is no treasury to move its cash to,
        // so callers keep the cash on the cohort and retry later.
        error = "country_cohort_cash_treasury_unowned";
        return true;
    }
    // The in-thread prepare below is worker-only: it reads the Country POD
    // authority directly. Economy still runs on the main thread until its own
    // ACTIVE grant lands, and taking this branch from there raised
    // country_worker_cohort_cash_boundary_invalid as a fatal — the cohort was
    // credited while the treasury debit never happened (money_error).
    // Main-thread Economy must use the Host peer queue further down instead.
    // Host 授权是权威来源；本地禁写镜像滞后时也必须走线程内结算。
    // 无游标的异步分支会在每次结构提交重试时创建新请求并永久 park。
    if (_simulation_host != nullptr && _country_runtime != nullptr &&
        _simulation_host->on_worker_thread() &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) &&
        (_d7_operation_gate_mask & (1u << static_cast<uint32_t>(operation))) != 0u) {
        const int64_t funds = population_store().funds[cohort_slot];
        if ((operation == CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT &&
             (funds < amount || population_store().epoch_expense[cohort_slot] > INT64_MAX - amount)) ||
            (operation == CountryApi::ECONOMY_ASSET_CASH_TO_COHORT &&
             (funds > INT64_MAX - amount ||
              population_store().epoch_income[cohort_slot] > INT64_MAX - amount))) {
            error = "country_cohort_cash_balance_invalid";
            return false;
        }
        RuntimeEconomyAssetRequest request;
        request.operation = static_cast<RuntimeEconomyAssetOperation>(operation);
        request.origin_epoch = _epoch_id.get();
        request.origin_stage = static_cast<int32_t>(_stage);
        request.day = _current_day.get();
        request.country_handle = static_cast<uint64_t>(country_handle);
        request.target_slot = cohort_slot;
        request.target_handle = population_store().handle_for_slot(cohort_slot);
        request.peer_generation = _committed_generation;
        request.requested_cash = amount;
        request.requested_quantity = amount;
        if (!_simulation_host->prepare_worker_cohort_cash(request, error) ||
            !service_country_economy_asset_peer(RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY, error))
            return false;
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host->finish_worker_country_asset(request.request_id, terminal, error))
            return false;
        committed = terminal.committed_cash;
        return true;
    }
    const CountryWorkerAssetRoute route = block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(operation), country_handle, amount, amount, -1,
            error);
    if (route == CountryWorkerAssetRoute::GATE_SOFT_UNAVAILABLE) {
        committed = 0;
        return true;
    }
    if (route != CountryWorkerAssetRoute::NOT_APPLICABLE)
        return false;
    const auto port = country_api::fiscal_return_port(*_country_runtime);
    godot::Dictionary begun;
    if (operation == CountryApi::ECONOMY_ASSET_CASH_TO_COHORT) {
        begun = port.submit_transfer(port.cash_to_cohort(
            country_handle, amount, _epoch_id.get(), static_cast<int32_t>(_stage)));
    } else {
        begun = port.submit_transfer(port.cash_from_cohort(
            country_handle, amount, _epoch_id.get(), static_cast<int32_t>(_stage)));
    }
    if (!static_cast<bool>(begun.get("ok", false))) {
        error = String(begun.get("code", "country_cohort_cash_country_rejected"))
            .utf8().get_data();
        return false;
    }
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("country_generation", 0)));
    const int64_t prepared_quantity = static_cast<int64_t>(
        begun.get("prepared_quantity", 0));
    const uint64_t peer_generation = _committed_generation;
    if (transaction_id == 0 || session_epoch == 0 || country_generation == 0 ||
        prepared_quantity <= 0 || peer_generation == 0) {
        error = "country_cohort_cash_identity_invalid";
        return false;
    }

    const int64_t funds_before = std::max<int64_t>(0, population_store().funds[cohort_slot]);
    const int64_t income_before = std::max<int64_t>(
        0, population_store().epoch_income[cohort_slot]);
    if (operation == CountryApi::ECONOMY_ASSET_CASH_TO_COHORT) {
        if (funds_before > std::numeric_limits<int64_t>::max() - prepared_quantity ||
            income_before > std::numeric_limits<int64_t>::max() - prepared_quantity) {
            port.prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                false, "country_cohort_cash_credit_overflow");
            error = "country_cohort_cash_credit_overflow";
            return false;
        }
    } else if (funds_before < prepared_quantity) {
        port.prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                false, "country_cohort_cash_insufficient");
        error = "country_cohort_cash_insufficient";
        return false;
    }

    const godot::Dictionary prepared =
        port.prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                true, "");
    if (!static_cast<bool>(prepared.get("ok", false))) {
        error = "country_cohort_cash_peer_prepare_failed";
        return false;
    }
    const godot::Dictionary commit =
        port.apply(transaction_id);
    if (!static_cast<bool>(commit.get("ok", false))) {
        error = String(commit.get("code", "country_cohort_cash_country_commit_failed"))
            .utf8().get_data();
        return false;
    }
    const int64_t actual = static_cast<int64_t>(
        commit.get("committed_quantity", prepared_quantity));
    if (actual <= 0 || actual > prepared_quantity) {
        error = "country_cohort_cash_commit_quantity_invalid";
        return false;
    }

    touch_accounting_slot(cohort_slot);
    if (operation == CountryApi::ECONOMY_ASSET_CASH_TO_COHORT) {
        population_store().funds.write_scalar(cohort_slot, saturating_add(
            population_store().funds[cohort_slot], actual, _saturation_count), market_mutation_sink());
        population_store().epoch_income.write_scalar(cohort_slot, saturating_add(
            population_store().epoch_income[cohort_slot], actual, _saturation_count), market_mutation_sink());
    } else {
        population_store().funds.write_scalar(cohort_slot, population_store().funds[cohort_slot] - (actual), market_mutation_sink());
        population_store().epoch_expense.write_scalar(cohort_slot, saturating_add(
            population_store().epoch_expense[cohort_slot], actual, _saturation_count), market_mutation_sink());
    }
    const godot::Dictionary applied =
        port.applied(
                {transaction_id, session_epoch, country_generation, peer_generation},
                true, "");
    if (!static_cast<bool>(applied.get("ok", false)) ||
        String(applied.get("status_name", "")) != "completed") {
        error = "country_cohort_cash_peer_apply_ack_failed";
        return false;
    }
    committed = actual;
    return true;
}

bool NativeEconomyRuntime::coordinate_country_market_goods(
        int32_t market, int32_t good, int64_t country_handle,
        int32_t operation, int64_t amount, int64_t &committed,
        std::string &error) {
    committed = 0;
    error.clear();
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        error = "country_market_goods_peer_unavailable";
        return false;
    }
    if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
        good >= market_store().good_count.get() || country_handle == 0 || amount < 0 ||
        (operation != CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET &&
         operation != CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET)) {
        error = "country_market_goods_request_invalid";
        return false;
    }
    if (amount == 0) return true;
    const CountryWorkerAssetRoute route = block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(operation), country_handle, 0, amount, good,
            error);
    if (route == CountryWorkerAssetRoute::GATE_SOFT_UNAVAILABLE) {
        committed = 0;
        return true;
    }
    if (route != CountryWorkerAssetRoute::NOT_APPLICABLE)
        return false;
    const size_t market_index = market_store().index(market, good);
    if (market_index >= market_store().stock.size()) {
        error = "country_market_goods_lane_invalid";
        return false;
    }
    const auto port = country_api::fiscal_return_port(*_country_runtime);
    godot::Dictionary begun;
    if (operation == CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET) {
        begun = port.submit_transfer(port.good_to_market(
            country_handle, good, amount, _epoch_id.get(), static_cast<int32_t>(_stage)));
    } else {
        begun = port.submit_transfer(port.good_from_market(
            country_handle, good, amount, _epoch_id.get(), static_cast<int32_t>(_stage)));
    }
    if (!static_cast<bool>(begun.get("ok", false))) {
        error = String(begun.get("code", "country_market_goods_country_rejected"))
            .utf8().get_data();
        return false;
    }
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begun.get("country_generation", 0)));
    const int64_t prepared_quantity = static_cast<int64_t>(
        begun.get("prepared_quantity", 0));
    const uint64_t peer_generation = _committed_generation;
    if (transaction_id == 0 || session_epoch == 0 || country_generation == 0 ||
        prepared_quantity <= 0 || peer_generation == 0) {
        error = "country_market_goods_identity_invalid";
        return false;
    }
    const int64_t market_before = std::max<int64_t>(0, market_store().stock[market_index]);
    if (operation == CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET &&
        market_before < prepared_quantity) {
        port.prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                false, "country_market_goods_stock_insufficient");
        error = "country_market_goods_stock_insufficient";
        return false;
    }
    if (operation == CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET &&
        market_before > std::numeric_limits<int64_t>::max() - prepared_quantity) {
        port.prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                false, "country_market_goods_stock_overflow");
        error = "country_market_goods_stock_overflow";
        return false;
    }
    const godot::Dictionary prepared =
        port.prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                true, "");
    if (!static_cast<bool>(prepared.get("ok", false))) {
        error = "country_market_goods_peer_prepare_failed";
        return false;
    }
    const godot::Dictionary commit =
        port.apply(transaction_id);
    if (!static_cast<bool>(commit.get("ok", false))) {
        error = String(commit.get("code", "country_market_goods_country_commit_failed"))
            .utf8().get_data();
        return false;
    }
    const int64_t actual = static_cast<int64_t>(
        commit.get("committed_quantity", prepared_quantity));
    if (actual <= 0 || actual > prepared_quantity) {
        error = "country_market_goods_commit_quantity_invalid";
        return false;
    }
    audit_touch_market_lane(market_index);
    if (operation == CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET)
        market_store().stock.write_scalar(market_index, saturating_add(
            market_store().stock[market_index], actual, _saturation_count), market_mutation_sink());
    else
        market_store().stock.write_scalar(market_index, market_store().stock[market_index] - (actual), market_mutation_sink());
    const godot::Dictionary applied =
        port.applied(
                {transaction_id, session_epoch, country_generation, peer_generation},
                true, "");
    if (!static_cast<bool>(applied.get("ok", false)) ||
        String(applied.get("status_name", "")) != "completed") {
        error = "country_market_goods_peer_apply_ack_failed";
        return false;
    }
    committed = actual;
    return true;
}

bool NativeEconomyRuntime::coordinate_country_treasury_spend(
        int32_t merchant_cell, int32_t market, int64_t country_handle,
        const std::vector<int32_t> &good_ids,
        const std::vector<int64_t> &treasury_quantities,
        const std::vector<int64_t> &market_quantities, int64_t cash,
        int64_t &committed_cash, std::string &error) {
    committed_cash = 0;
    error.clear();
    if (_country_runtime == nullptr || !country_reads().economy_available()) {
        error = "country_treasury_peer_unavailable";
        return false;
    }
    // An empty bill is valid for authored zero-material buildings. The caller
    // still supplies aligned (empty) treasury/market vectors, and the fast
    // return below keeps this path out of the Country asset bridge.
    if (country_handle == 0 || market < 0 || market >= market_store().market_count.get() ||
        merchant_cell < 0 || merchant_cell >= _cell_count.get() || cash < 0 ||
        good_ids.size() != treasury_quantities.size() ||
        good_ids.size() != market_quantities.size()) {
        error = "country_treasury_peer_request_invalid";
        return false;
    }
    int64_t goods_total = 0;
    for (size_t i = 0; i < good_ids.size(); ++i) {
        if (good_ids[i] < 0 || good_ids[i] >= market_store().good_count.get() ||
            treasury_quantities[i] < 0 || market_quantities[i] < 0 ||
            goods_total > std::numeric_limits<int64_t>::max() -
                treasury_quantities[i] - market_quantities[i]) {
            error = "country_treasury_peer_goods_invalid";
            return false;
        }
        goods_total += treasury_quantities[i] + market_quantities[i];
        const size_t lane = market_store().index(market, good_ids[i]);
        if (lane >= market_store().stock.size() ||
            market_store().stock[lane] < market_quantities[i]) {
            error = "country_treasury_peer_market_stock_insufficient";
            return false;
        }
    }
    if (cash == 0 && goods_total == 0) return true;
    // Country is the unique treasury writer in production. When Economy is
    // running on the worker and Country is the worker-authoritative peer, use
    // the same-thread prepare/service/finish cycle so construction does not
    // observe an ENQUEUED_PENDING result as a failed debit. Synchronous
    // fixtures keep the ordinary transaction path below.
    bool treasury_peer_committed = false;
    int64_t peer_committed_cash = 0;
    const bool worker_inline_country = _simulation_host != nullptr &&
        _simulation_host->on_worker_thread() &&
        _simulation_host->domain_is_worker_authoritative(
            RuntimeDomainId::COUNTRY) &&
        (_d7_operation_gate_mask &
            (1u << static_cast<uint32_t>(
                RuntimeEconomyAssetOperation::TREASURY_SPEND))) != 0u;
    if (worker_inline_country) {
        RuntimeEconomyAssetRequest request;
        request.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
        request.origin_epoch = _epoch_id.get();
        request.origin_stage = static_cast<int32_t>(_stage);
        request.day = _current_day.get();
        request.country_handle = static_cast<uint64_t>(country_handle);
        request.peer_generation = _committed_generation;
        request.requested_cash = cash;
        request.requested_quantity = goods_total;
        request.requested_goods_total = goods_total;
        const size_t copied = std::min(good_ids.size(),
            static_cast<size_t>(RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY));
        for (size_t i = 0; i < copied; ++i) {
            request.good_ids[i] = good_ids[i];
            request.good_quantities[i] = treasury_quantities[i];
            ++request.good_count;
        }
        if (request.good_count > 0) request.good_id = request.good_ids[0];
        std::string peer_error;
        if (!_simulation_host->prepare_worker_cohort_cash(request, peer_error) ||
            !service_country_economy_asset_peer(
                RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY, peer_error)) {
            error = peer_error.empty()
                ? "country_treasury_peer_prepare_failed" : peer_error;
            return false;
        }
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host->finish_worker_country_asset(
                request.request_id, terminal, peer_error) ||
            terminal.code != RuntimeEconomyAssetResultCode::COMPLETED) {
            error = peer_error.empty()
                ? "country_treasury_peer_not_completed" : peer_error;
            return false;
        }
        treasury_peer_committed = true;
        peer_committed_cash = terminal.committed_cash;
        error.clear();
    } else {
        const CountryWorkerAssetRoute route = block_or_enqueue_country_worker_asset(
                static_cast<uint16_t>(CountryApi::ECONOMY_ASSET_TREASURY_SPEND),
                country_handle, cash, goods_total, good_ids, treasury_quantities,
                error);
        if (route == CountryWorkerAssetRoute::GATE_SOFT_UNAVAILABLE) {
            // Treasury spend must not silently create construction/canal without
            // paying. Reject the coordinator so callers soft-fail the command.
            committed_cash = 0;
            return false;
        }
        if (route != CountryWorkerAssetRoute::NOT_APPLICABLE)
            return false;
    }

    std::vector<int32_t> living_merchants;
    if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t edge = _merchant_offsets[merchant_cell];
             edge < _merchant_offsets[merchant_cell + 1]; ++edge) {
            const int32_t slot = _merchant_slots[edge];
            if (is_merchant_slot(slot) && slot >= 0 &&
                slot < static_cast<int32_t>(population_store().population.size()) &&
                population_store().population[slot] > 0)
                living_merchants.push_back(slot);
        }
    }
    if (cash > 0 && living_merchants.empty()) {
        error = "country_treasury_peer_merchant_missing";
        return false;
    }
    int64_t merchant_population = 0;
    for (const int32_t slot : living_merchants)
        merchant_population = saturating_add(
            merchant_population, population_store().population[slot], _saturation_count);
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (const int32_t slot : living_merchants) {
        prefix = saturating_add(prefix, population_store().population[slot], _saturation_count);
        const int64_t next = mul_div_sat(
            cash, prefix, merchant_population, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        if (population_store().funds[slot] >
                std::numeric_limits<int64_t>::max() - share ||
            population_store().epoch_income[slot] >
                std::numeric_limits<int64_t>::max() - share) {
            error = "country_treasury_peer_merchant_credit_overflow";
            return false;
        }
    }
    if (cash > 0 && distributed != cash) {
        error = "country_treasury_peer_merchant_distribution_drift";
        return false;
    }

    godot::PackedInt32Array ids;
    godot::PackedInt64Array quantities;
    ids.resize(static_cast<int64_t>(good_ids.size()));
    quantities.resize(static_cast<int64_t>(treasury_quantities.size()));
    for (int64_t i = 0; i < ids.size(); ++i) {
        ids.set(i, good_ids[static_cast<size_t>(i)]);
        quantities.set(i, treasury_quantities[static_cast<size_t>(i)]);
    }
    int64_t actual_cash = cash;
    uint64_t transaction_id = 0;
    uint64_t session_epoch = 0;
    uint64_t country_generation = 0;
    const uint64_t peer_generation = _committed_generation;
    if (!treasury_peer_committed) {
        const godot::Dictionary begun =
            country_api::fiscal_return_port(*_country_runtime).submit_spend(
                country_api::fiscal_return_port(*_country_runtime).spend_intent(
                    country_handle, ids, quantities, cash, _epoch_id.get(),
                    static_cast<int32_t>(_stage)));
        if (!static_cast<bool>(begun.get("ok", false))) {
            error = String(begun.get("code", "country_treasury_peer_country_rejected"))
                .utf8().get_data();
            return false;
        }
        transaction_id = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("transaction_id", 0)));
        session_epoch = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("session_epoch", 0)));
        country_generation = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("country_generation", 0)));
        if (transaction_id == 0 || session_epoch == 0 || country_generation == 0 ||
            peer_generation == 0) {
            error = "country_treasury_peer_identity_invalid";
            return false;
        }
        const godot::Dictionary prepared =
            country_api::fiscal_return_port(*_country_runtime).prepared(
                {transaction_id, session_epoch, country_generation, peer_generation},
                true, "");
        if (!static_cast<bool>(prepared.get("ok", false))) {
            error = "country_treasury_peer_prepare_failed";
            return false;
        }
        const godot::Dictionary commit =
            country_api::fiscal_return_port(*_country_runtime).apply(transaction_id);
        if (!static_cast<bool>(commit.get("ok", false))) {
            error = String(commit.get("code", "country_treasury_peer_country_commit_failed"))
                .utf8().get_data();
            return false;
        }
        actual_cash = static_cast<int64_t>(commit.get("committed_cash", cash));
        if (actual_cash != cash) {
            error = "country_treasury_peer_cash_commit_drift";
            return false;
        }
    }
    for (size_t i = 0; i < good_ids.size(); ++i) {
        const size_t lane = market_store().index(market, good_ids[i]);
        audit_touch_market_lane(lane);
        market_store().stock.write_scalar(lane, market_store().stock[lane] - (market_quantities[i]), market_mutation_sink());
    }
    prefix = 0;
    distributed = 0;
    for (const int32_t slot : living_merchants) {
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, population_store().population[slot], _saturation_count);
        const int64_t next = mul_div_sat(
            cash, prefix, merchant_population, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        population_store().funds.write_scalar(slot, saturating_add(
            population_store().funds[slot], share, _saturation_count), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(
            population_store().epoch_income[slot], share, _saturation_count), market_mutation_sink());
        trace_record_cashflow(merchant_cell, population_store().handle_for_slot(slot),
                              CASHFLOW_MERCHANT_BUSINESS, share, 0);
    }
    if (!treasury_peer_committed) {
        const godot::Dictionary applied =
            country_api::fiscal_return_port(*_country_runtime).applied(
                {transaction_id, session_epoch, country_generation, peer_generation},
                true, "");
        if (!static_cast<bool>(applied.get("ok", false)) ||
            String(applied.get("status_name", "")) != "completed") {
            error = "country_treasury_peer_apply_ack_failed";
            return false;
        }
    }
    committed_cash = treasury_peer_committed ? peer_committed_cash : actual_cash;
    return true;
}

CountryReadView NativeEconomyRuntime::country_reads() const {
    return country_api::read_view(*_country_runtime);
}

bool NativeEconomyRuntime::cell_has_technology(int32_t cell, int32_t technology_id,
                                               bool frozen) const {
    if (cell < 0 || cell >= _cell_count.get() || technology_id < 0 ||
        technology_id >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_words <= 0) return false;
    if (frozen && _epoch_active) {
        if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count.get()) ||
            _epoch_country_technology_words <= 0) return false;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) return false;
        const size_t index = static_cast<size_t>(country) * _epoch_country_technology_words +
            technology_id / 64;
        return index < _epoch_country_technologies.size() &&
            (_epoch_country_technologies[index] & (uint64_t{1} << (technology_id % 64))) != 0;
    }
    const int32_t country = _country_runtime == nullptr
        ? CountryApi::NEUTRAL_SLOT : country_reads().country_slot_for_cell(cell);
    return _country_runtime != nullptr && country_reads().has_technology(country, technology_id);
}

// Building availability/constructibility gates live in
// economy_runtime_building_production.cpp.


// Emits one gameplay fact per settled cell whose population-weighted pressure
// level actually changed. The level, not the raw composite, is the dedup key,
// so a cell drifting inside a band stays silent and the event volume per epoch
// is bounded by the rolling workset.

// Fiscal settlement implementations live in economy_runtime_fiscal.cpp.

// Building resource lane implementations live in
// economy_runtime_building_resources.cpp.

// Building graph storage implementations live in
// economy_runtime_building_storage.cpp.

// Building wage planning and labor signal updates live in
// economy_runtime_building_employment.cpp.

// Production climate capacity helpers live in
// economy_runtime_building_production.cpp.


// Building command/construction mutation implementations live in
// economy_runtime_building_construction.cpp.

int64_t NativeEconomyRuntime::projected_owner_income_per_day(
        BuildingGroupConstRef group, int64_t &sat) const {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const BuildingType &type = _building_types[group.type_id];
    const int64_t days = std::max<int64_t>(1, _epoch_days.get());
    // Owner mobility is based on people actually attached to this lot. The
    // former max(planned, filled) fallback made an empty lot look profitable
    // at full nameplate capacity and pulled population into phantom income.
    int64_t owner_jobs = std::max<int64_t>(0, group.filled_owner);
    // A lot can be vacated by the current employment pass after producing a
    // factual period. Keep that realized receipt visible as the opportunity
    // signal for the next pass; only wholly unobserved vacant lots remain at
    // zero and cannot attract labor from phantom income.
    if (owner_jobs <= 0 && (group.last_output > 0 || group.last_sold > 0 ||
                            group.last_market_receipt > 0)) {
        owner_jobs = std::max<int64_t>(0, planned_owner_demand(group, sat));
    }
    if (owner_jobs <= 0) return 0;
    const bool observed_capacity = group.last_observed_capacity_days_q16 > 0;
    int64_t fact_scale_q16 = Q16_ONE;
    if (observed_capacity) {
        int64_t workforce_q16 = Q16_ONE;
        const int64_t owner_slots = saturating_mul(
            group.count, type.owner_slots_per_building, sat);
        workforce_q16 = owner_slots > 0
            ? std::clamp<int64_t>(mul_div_sat(
                owner_jobs, Q16_ONE, owner_slots, sat), 0, Q16_ONE)
            : Q16_ONE;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int64_t role_slots = saturating_mul(
                group.count, role.slots_per_building, sat);
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t filled = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[role_index]) : 0;
            const int64_t role_capacity = role_slots > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    filled, Q16_ONE, role_slots, sat), 0, Q16_ONE)
                : Q16_ONE;
            workforce_q16 = std::min(workforce_q16, role_capacity);
        }
        const int64_t current_capacity_days_q16 = saturating_mul(
            workforce_q16,
            saturating_mul(std::max<int64_t>(1, group.count), days, sat), sat);
        // This is a capacity-days multiplier, not a utilization ratio. It may
        // legitimately exceed Q16 when the current period is longer or has
        // more staffed capacity than the observed period.
        fact_scale_q16 = current_capacity_days_q16 > 0
            ? mul_div_sat(current_capacity_days_q16, Q16_ONE,
                std::max<int64_t>(1, group.last_observed_capacity_days_q16), sat)
            : 0;
    }
    auto scale_fact = [&](int64_t value) -> int64_t {
        return observed_capacity
            ? mul_div_sat(std::max<int64_t>(0, value), fact_scale_q16,
                          Q16_ONE, sat)
            : std::max<int64_t>(0, value);
    };
    int64_t input_cost = 0;
    int64_t maintenance_cost = 0;
    int64_t wage_cost = 0;
    if (observed_capacity) {
        // These are the previous committed period's actual cash outflows.
        // They remain authoritative even when the next plan is forced to a
        // lower utilization by a newly scarce input or resource.
        input_cost = scale_fact(group.last_input_cost);
        maintenance_cost = scale_fact(group.last_maintenance_cost);
        wage_cost = scale_fact(group.last_wages_paid);
    } else {
        const int64_t utilization = std::clamp<int64_t>(
            group.planned_utilization_q16, 0, Q16_ONE);
        if (utilization <= 0) return 0;
        input_cost = saturating_mul(
            saturating_mul(group.sample_unit_input_cost, group.count,
                           sat),
            days, sat);
        input_cost = mul_div_sat(input_cost, utilization, Q16_ONE, sat);
        maintenance_cost = saturating_mul(
            saturating_mul(group.sample_unit_maintenance_cost, group.count,
                           sat),
            days, sat);
        maintenance_cost = mul_div_sat(maintenance_cost, utilization, Q16_ONE,
                                       sat);
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_role_contract_wage.size())
                ? _building_role_contract_wage[role_index]
                : 0;
            const int64_t filled = role_index >= 0 && role_index <
                    static_cast<int32_t>(_building_employee_filled.size())
                ? std::max<int64_t>(0, _building_employee_filled[role_index]) : 0;
            int64_t role_cost = saturating_mul(
                saturating_mul(filled, wage, sat), days, sat);
            role_cost = mul_div_sat(role_cost, utilization, Q16_ONE, sat);
            wage_cost = saturating_add(wage_cost, role_cost, sat);
        }
    }
    // Owner subsistence is not a business cost here: callers compare this
    // income against the owner living cost (investment viability, job
    // mobility), so netting it out would double-count it.
    const int64_t owner_living_cost = saturating_mul(
        saturating_mul(living_cost_for_signature(
            group.cell, group.owner_signature_id, _living_cost_base_plan_id,
            sat), owner_jobs, sat), days, sat);
    // Keep the owner opportunity quote on the same realized-income basis as
    // the production plan: cash receipts, support, and retained owner output
    // are all income.  Otherwise a cashless subsistence cycle is reported as
    // a loss even when it covered the owner's food needs.
    const int64_t observed_receipts = scale_fact(saturating_add(
        saturating_add(std::max<int64_t>(0, group.last_market_receipt),
                       std::max<int64_t>(0, group.last_bullion_mint_receipt), sat),
        std::max<int64_t>(0, group.last_producer_support_receipt), sat));
    int64_t realized_survival_output_value = 0;
    if (group.last_output > 0 && group.cell >= 0 && group.cell < _cell_count.get()) {
        const int32_t market = market_store().cell_to_market[group.cell];
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (good < 0 || good >= market_store().good_count.get() ||
                good >= static_cast<int32_t>(_survival_food_good_mask.size()) ||
                _survival_food_good_mask[good] == 0) continue;
            realized_survival_output_value = std::max<int64_t>(
                realized_survival_output_value,
                mul_div_sat(group.last_output,
                    market_store().price[market_store().index(market, good)],
                    GOODS_SCALE, sat));
        }
    }
    // Once a period has settled, mobility uses its actual cash receipts.
    // A production-plan quote can outlive both a price change and a workforce
    // move. Scaling that stale quote again invents income and causes workers
    // to oscillate between otherwise equivalent lots. In-kind income is added
    // exactly once below and is never a cash tax base.
    const int64_t quoted_revenue = observed_capacity
        ? observed_receipts : std::max<int64_t>(0, group.last_expected_revenue);
    const uint8_t owner_tax_mask = static_cast<uint8_t>(
        (1U << CountryApi::TAX_INCOME) |
        (1U << CountryApi::TAX_BUSINESS));
    if ((_epoch_active_tax_mask & owner_tax_mask) == 0) {
        const int64_t owner_pool = std::max<int64_t>(0,
            saturating_sub(quoted_revenue,
                saturating_add(saturating_add(
                    input_cost, wage_cost, sat),
                    maintenance_cost, sat), sat));
        const int64_t economic_owner_pool = std::max<int64_t>(saturating_add(
            owner_pool,
            scale_fact(group.last_in_kind_livelihood_value), sat),
            realized_survival_output_value);
        // Per-owner daily disposable signal for mobility / UI.
        return (economic_owner_pool / std::max<int64_t>(1, days)) /
            std::max<int64_t>(1, owner_jobs);
    }
    const int64_t operating_income = saturating_sub(
        quoted_revenue,
        saturating_add(saturating_add(
            input_cost, wage_cost, sat), maintenance_cost, sat), sat);
    const int32_t business_rate = frozen_tax_rate(
        group.cell, CountryApi::TAX_BUSINESS, group.type_id);
    const int64_t eligible_business_cost = saturating_add(
        saturating_add(input_cost, wage_cost, sat), maintenance_cost, sat);
    const int64_t business_base = business_rate < 0
        ? eligible_business_cost
        : std::max<int64_t>(0, quoted_revenue);
    const int64_t absolute_building_days = saturating_mul(
        group.count, std::max<int64_t>(1, days), sat);
    const int64_t business_transfer = observed_capacity
        ? saturating_sub(scale_fact(group.last_business_subsidy_received),
                         scale_fact(group.last_business_tax_paid), sat)
        : expected_resolved_fiscal_transfer(
            group.cell, CountryApi::TAX_BUSINESS, group.type_id,
            business_base, absolute_building_days, sat);
    const int64_t taxable_income = std::max<int64_t>(0, saturating_sub(
        operating_income, std::max<int64_t>(0, business_transfer), sat));
    const int32_t profession = group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size())
        ? _signatures[group.owner_signature_id].profession_id : -1;
    const int32_t income_rate = frozen_tax_rate(
        group.cell, CountryApi::TAX_INCOME, profession);
    int64_t income_subsidy_base = taxable_income;
    if (income_rate < 0) {
        income_subsidy_base = std::max(
            income_subsidy_base, owner_living_cost);
    }
    const int64_t absolute_owner_days = saturating_mul(
        owner_jobs, std::max<int64_t>(1, days), sat);
    const int64_t income_transfer = expected_resolved_fiscal_transfer(
        group.cell, CountryApi::TAX_INCOME, profession,
        income_subsidy_base, absolute_owner_days, sat);
    const int64_t owner_pool = std::max<int64_t>(0, saturating_sub(
        saturating_sub(operating_income, business_transfer, sat),
        income_transfer, sat));
    const int64_t economic_owner_pool = std::max<int64_t>(saturating_add(
        owner_pool, scale_fact(group.last_in_kind_livelihood_value), sat),
        realized_survival_output_value);
    // Per-owner daily signal (group pool ÷ attached owner people ÷ days).
    return (economic_owner_pool / std::max<int64_t>(1, days)) /
        std::max<int64_t>(1, owner_jobs);
}
























bool NativeEconomyRuntime::apply_command(const Command &cmd, std::string &error) {
    int32_t slot = -1;
    int32_t event_cell = -1;
    int64_t settled_value = 0;
    std::vector<EventLeg> event_legs;
    auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
        if (before != after && trace_detail_for_cell(event_cell)) {
            event_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
        }
    };
    switch (cmd.opcode) {
        case COMMAND_MILITARY_PROCUREMENT_DEMAND:
            return retain_military_procurement_demand(cmd, error);
        case COMMAND_START_FAMILY_EXPEDITION:
        case COMMAND_CANCEL_FAMILY_EXPEDITION:
            return apply_family_expedition_player_command(cmd, error);
        case COMMAND_SETTLE_FAMILY_EXPEDITION:
            return apply_settle_family_expedition(cmd, error);
        case COMMAND_TRANSFER_TO_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_ledger";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : country_reads().country_handle_for_cell(event_cell));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : country_reads().total_cash();
            const int64_t funds_before = population_store().funds[slot];
            const int64_t income_before = population_store().epoch_income[slot];
            int64_t amount = 0;
            std::string cohort_cash_error;
            if (!coordinate_country_cohort_cash(
                    slot, country_handle,
                    CountryApi::ECONOMY_ASSET_CASH_TO_COHORT,
                    std::max<int64_t>(0, cmd.i64_0), amount, cohort_cash_error)) {
                error = cohort_cash_error.empty()
                    ? "country_cohort_cash_transfer_failed" : cohort_cash_error;
                return false;
            }
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, amount, 0);
            settled_value = amount;
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, country_reads().total_cash());
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, population_store().epoch_income[slot]);
            break;
        }
        case COMMAND_MINT_TO_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_mint";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t funds_before = population_store().funds[slot];
            const int64_t income_before = population_store().epoch_income[slot];
            population_store().funds.write_scalar(slot, saturating_add(population_store().funds[slot], cmd.i64_0, _saturation_count), market_mutation_sink());
            population_store().epoch_income.write_scalar(slot, saturating_add(population_store().epoch_income[slot], cmd.i64_0, _saturation_count), market_mutation_sink());
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, cmd.i64_0, 0);
            _explicit_money_mint = saturating_add(_explicit_money_mint, cmd.i64_0, _saturation_count);
            settled_value = cmd.i64_0;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, population_store().epoch_income[slot]);
            break;
        }
        case COMMAND_BURN_FROM_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_burn";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, population_store().funds[slot]));
            const int64_t funds_before = population_store().funds[slot];
            const int64_t expense_before = population_store().epoch_expense[slot];
            population_store().funds.write_scalar(slot, population_store().funds[slot] - (amount), market_mutation_sink());
            population_store().epoch_expense.write_scalar(slot, saturating_add(population_store().epoch_expense[slot], amount, _saturation_count), market_mutation_sink());
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            _explicit_money_burn = saturating_add(_explicit_money_burn, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, population_store().epoch_expense[slot]);
            break;
        }
        case COMMAND_ADD_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = market_store().stock[idx];
            audit_touch_market_lane(static_cast<size_t>(idx));
            market_store().stock.write_scalar(idx, saturating_add(market_store().stock[idx], cmd.i64_0, _saturation_count), market_mutation_sink());
            _explicit_stock_delta = saturating_add(_explicit_stock_delta, cmd.i64_0, _saturation_count);
            settled_value = market_store().stock[idx] - stock_before;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, market_store().stock[idx]);
            break;
        }
        case COMMAND_REMOVE_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = market_store().stock[idx];
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, market_store().stock[idx]));
            audit_touch_market_lane(static_cast<size_t>(idx));
            market_store().stock.write_scalar(idx, market_store().stock[idx] - (amount), market_mutation_sink());
            _explicit_stock_delta = saturating_sub(_explicit_stock_delta, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, market_store().stock[idx]);
            break;
        }
        case COMMAND_COUNTRY_GOOD_TO_MARKET: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t before = market_store().stock[index];
            int64_t moved = 0;
            std::string market_goods_error;
            if (!coordinate_country_market_goods(
                    cmd.i32_0, cmd.i32_1,
                    static_cast<int64_t>(cmd.target_handle),
                    CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET,
                    std::max<int64_t>(0, cmd.i64_0), moved, market_goods_error)) {
                error = market_goods_error.empty()
                    ? "country_market_goods_transfer_failed" : market_goods_error;
                return false;
            }
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, market_store().stock[index]);
            break;
        }
        case COMMAND_MARKET_GOOD_TO_COUNTRY: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = market_store().index(cmd.i32_0, cmd.i32_1);
            const int64_t before = market_store().stock[index];
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, market_store().stock[index]));
            int64_t moved = 0;
            std::string market_goods_error;
            if (!coordinate_country_market_goods(
                    cmd.i32_0, cmd.i32_1,
                    static_cast<int64_t>(cmd.target_handle),
                    CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET,
                    offered, moved, market_goods_error)) {
                error = market_goods_error.empty()
                    ? "country_market_goods_transfer_failed" : market_goods_error;
                return false;
            }
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, market_store().stock[index]);
            break;
        }
        case COMMAND_ADD_POPULATION: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_population_adjust";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t before = population_store().population[slot];
            const int64_t after = std::max<int64_t>(0, saturating_add(before, cmd.i64_0,
                                                                      _saturation_count));
            const int64_t actual_delta = after - before;
            population_store().population.write_scalar(slot, after, market_mutation_sink());
            // A negative population adjustment (for example an externally
            // issued removal) must carry its employment out of the cohort too;
            // otherwise the next POD mirror export can observe jobs belonging
            // to people who no longer exist.
            population_store().owner_employed.write_scalar(slot, std::clamp<int64_t>(
                population_store().owner_employed[slot], 0, after), market_mutation_sink());
            population_store().employee_employed.write_scalar(slot, std::clamp<int64_t>(
                population_store().employee_employed[slot], 0,
                after - population_store().owner_employed[slot]), market_mutation_sink());
            settled_value = actual_delta;
            add_leg(FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1, before, after);
            _external_population_delta = saturating_add(_external_population_delta, actual_delta,
                                                        _saturation_count);
            if (actual_delta != 0)
                _structural_touched_cells.push_back(event_cell);
            if (after == 0) {
                const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
                _structural_commands.push_back({0, slot, cell,
                                                static_cast<int32_t>(population_store().signature_id[slot]),
                                                0, 0, cmd.sequence});
            }
            break;
        }
        case COMMAND_MILITARY_CONVERT_COHORT: {
            // B (design 5.4): state-directed cohort conversion inside one cell,
            // named by signature so no slot id crosses an execution boundary.
            // It goes through the ORDINARY structural path instead of writing
            // population directly: a direct write bypassed the economy ledger's
            // slot/page bookkeeping and eventually failed
            // validate_shape_and_values() (economy_pod_ledger_shape_invalid).
            //
            // The same command can reach this switch more than once (POD plan plus
            // the epoch drain), so the sequence is deduplicated: applying it twice
            // silently converts twice as many people as Military asked for
            // (observed economy 15 vs military 12).
            static thread_local int64_t recent_seq[64] = {};
            static thread_local size_t recent_at = 0;
            const int64_t conv_sequence = cmd.sequence;
            if (conv_sequence != 0) {
                for (int64_t seen : recent_seq) {
                    if (seen == conv_sequence) {
                        settled_value = 0;
                        return true;
                    }
                }
                recent_seq[recent_at % 64] = conv_sequence;
                ++recent_at;
            }
            const int32_t conv_cell = cmd.i32_0;
            const int32_t dst_signature = cmd.i32_1;
            const int32_t src_signature = static_cast<int32_t>(cmd.i64_1);
            if (conv_cell < 0 || conv_cell >= _cell_count.get() ||
                src_signature < 0 || dst_signature < 0) {
                error = "military_convert_target_invalid";
                return false;
            }
            const int32_t conv_src = population_store().find_signature(
                conv_cell, static_cast<uint32_t>(src_signature));
            if (conv_src < 0 || population_store().active[conv_src] == 0) {
                error = "military_convert_source_missing";
                return false;
            }
            const int64_t conv_requested = std::max<int64_t>(0, cmd.i64_0);
            const int64_t conv_available =
                std::max<int64_t>(0, population_store().population[conv_src]);
            const int64_t conv_moved = std::min(conv_requested, conv_available);
            if (conv_moved <= 0) {
                error = "military_convert_source_empty";
                return false;
            }
            _structural_commands.push_back({
                COMMAND_CHANGE_SIGNATURE, conv_src, conv_cell, dst_signature,
                conv_moved, 0, cmd.sequence});
            settled_value = conv_moved;
            break;
        }
        // BEGIN army personnel lane (contract §1.2).
        case COMMAND_ARMY_EMBARK:
        case COMMAND_ARMY_DISEMBARK:
        case COMMAND_ARMY_MERGE_LANES:
        case COMMAND_ARMY_SPLIT_LANES:
        // 34 (army-pay contract §1): treasury -> lane wages, lane named by army
        // handle. Same dispatch, no cohort and no structural command.
        case COMMAND_ARMY_LANE_PAY: {
            int64_t lane_settled = 0;
            if (!apply_army_lane_command(cmd, error, lane_settled)) return false;
            settled_value = lane_settled;
            break;
        }
        // END army personnel lane
        case COMMAND_MOVE_POPULATION:
        case COMMAND_CHANGE_SIGNATURE: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_structure_queue";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t requested = cmd.i64_0 <= 0 ? population_store().population[slot] : cmd.i64_0;
            _structural_commands.push_back({cmd.opcode, slot,
                                            cmd.opcode == COMMAND_MOVE_POPULATION
                                                ? cmd.i32_0
                                                : population_store().page_cell[slot / COHORT_PAGE_SIZE],
                                            cmd.opcode == COMMAND_CHANGE_SIGNATURE
                                                ? cmd.i32_0
                                                : static_cast<int32_t>(population_store().signature_id[slot]),
                                            requested, 0, cmd.sequence});
            settled_value = requested;
            break;
        }
        case COMMAND_TRANSFER_FROM_COHORT: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_transfer";
                return false;
            }
            event_cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : country_reads().country_handle_for_cell(event_cell));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, population_store().funds[slot]));
            const int64_t funds_before = population_store().funds[slot];
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : country_reads().total_cash();
            const int64_t expense_before = population_store().epoch_expense[slot];
            int64_t amount = 0;
            std::string cohort_cash_error;
            if (!coordinate_country_cohort_cash(
                    slot, country_handle,
                    CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                    offered, amount, cohort_cash_error)) {
                error = cohort_cash_error.empty()
                    ? "country_cohort_cash_transfer_failed" : cohort_cash_error;
                return false;
            }
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, population_store().funds[slot]);
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, country_reads().total_cash());
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, population_store().epoch_expense[slot]);
            break;
        }
        case COMMAND_BUILD: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_build";
                return false;
            }
            return apply_build_command(cmd, slot, error);
        }
        case COMMAND_DEMOLISH: {
            if (!population_store().valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_demolish";
                return false;
            }
            return apply_demolish_command(cmd, slot, error);
        }
        case COMMAND_FAMILY_FREE_BUILDING:
            return apply_family_free_building_reward(cmd, error);
        case COMMAND_FAMILY_POPULATION_REWARD:
            return apply_family_population_reward(cmd, error);
        case COMMAND_FAMILY_ABSORB_ANONYMOUS:
            return apply_family_absorb_anonymous(cmd, error);
        case COMMAND_FAMILY_PURCHASE_DISCOUNT:
            return apply_family_purchase_discount(cmd, error);
        case COMMAND_FAMILY_SET_SPLIT_POLICY:
            return apply_family_set_split_policy(cmd, error);
        case COMMAND_TREASURY_SPONSORED_BUILD:
            return apply_treasury_sponsored_build_command(cmd, error);
        case COMMAND_TREASURY_SPONSORED_DEMOLISH:
            return apply_treasury_sponsored_demolish_command(cmd, error);
        case COMMAND_BUILD_CANAL:
            return apply_canal_build_command(cmd, error);
        default:
            error = "unsupported_command_opcode";
            return false;
    }
    trace_append(EVENT_COMMAND_SETTLED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 event_cell, SUBJECT_COMMAND, cmd.sequence, cmd.opcode, cmd.i32_1,
                 cmd.opcode, settled_value, cmd.i64_0, cmd.i64_1,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

bool NativeEconomyRuntime::commit_structural(const StructuralCommand &cmd,
                                             std::string &error) {
    // BEGIN army personnel lane (contract §1.2): lane transfers own their
    // cohort-side bookkeeping but run on this same structural stage.
    if (cmd.opcode == STRUCTURAL_ARMY_EMBARK ||
        cmd.opcode == STRUCTURAL_ARMY_DISEMBARK)
        return commit_structural_army_lane(cmd, error);
    // END army personnel lane
    if (cmd.opcode == STRUCTURAL_BIRTH) {
        if (cmd.cell < 0 || cmd.cell >= _cell_count.get() || cmd.signature < 0 ||
            cmd.signature >= static_cast<int32_t>(_signatures.size()) ||
            cmd.population <= 0 || _signatures[cmd.signature].profession_id !=
                _unemployed_profession_id) {
            error = "structural_birth_target_invalid";
            return false;
        }
        const int32_t destination = population_store().allocate_slot(
            cmd.cell, static_cast<uint32_t>(cmd.signature));
        if (destination < 0) {
            error = "structural_birth_allocation_failed";
            return false;
        }
        touch_accounting_slot(destination);
        const int64_t population_before = population_store().population[destination];
        population_store().population.write_scalar(destination, saturating_add(
            population_before, cmd.population, _saturation_count), market_mutation_sink());
        apply_family_birth_attribution(destination, cmd.population);
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            static_cast<int64_t>(population_store().handle_for_slot(destination)), -1,
                            population_before, population_store().population[destination]});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT,
                     static_cast<int64_t>(population_store().handle_for_slot(destination)),
                     cmd.signature, cmd.cell, cmd.population, 0, cmd.cell, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    // A producer from another execution context (the POD queue) cannot know this
    // runtime's cohort slot ids. Re-resolve the source from the cell plus the
    // source signature it recorded in the funds lane before giving up.
    if ((cmd.source_slot < 0 ||
         cmd.source_slot >= static_cast<int32_t>(population_store().active.size()) ||
         population_store().active[cmd.source_slot] == 0) &&
        cmd.signature >= 0 && cmd.funds > 0 && cmd.funds <= 0x7fffffffLL &&
        cmd.cell >= 0 && cmd.cell < _cell_count.get()) {
        const int32_t resolved = population_store().find_signature(
            cmd.cell, static_cast<uint32_t>(cmd.funds));
        if (resolved >= 0 && population_store().active[resolved] != 0) {
            StructuralCommand repaired = cmd;
            repaired.source_slot = resolved;
            return commit_structural(repaired, error);
        }
    }
    if (cmd.source_slot < 0 || cmd.source_slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[cmd.source_slot] == 0) {
        // A prior command may have consumed/released the same source. Stable
        // sequence semantics make the remaining command a deterministic no-op.
        return true;
    }
    const int32_t source = cmd.source_slot;
    const int32_t source_cell = population_store().page_cell[source / COHORT_PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(population_store().handle_for_slot(source));
    if (cmd.opcode == STRUCTURAL_REMOVE_EMPTY) {
        const int64_t estate_funds = population_store().funds[source];
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : country_reads().country_handle_for_cell(source_cell);
        const int64_t treasury_before = _country_runtime == nullptr ? 0
            : country_reads().total_cash();
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(source_cell)) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                            estate_funds, 0});
            legs.push_back({FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                            treasury_before, treasury_before});
        }
        int64_t moved = 0;
        std::string cohort_cash_error;
        if (!coordinate_country_cohort_cash(
                source, country_handle,
                CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                estate_funds, moved, cohort_cash_error)) {
            error = cohort_cash_error.empty()
                ? "country_treasury_estate_transfer_failed" : cohort_cash_error;
            return false;
        }
        if (moved != estate_funds) {
            // Country unique-writer + closed M2 cash peer: keep the empty
            // cohort until a later day can transfer the estate. Do not burn
            // money and do not release the slot.
            if (moved == 0 &&
                (cohort_cash_error == "country_economy_operation_gate_closed" ||
                 cohort_cash_error == "country_cohort_cash_treasury_unowned" ||
                 cohort_cash_error == "country_cohort_cash_negative_balance"))
                return true;
            error = "country_treasury_estate_transfer_failed";
            return false;
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, estate_funds, _saturation_count);
        // A demography command can drain a cohort after the employment stage.
        // Remove its stale lane counts before releasing the slot; the committed
        // reconciliation pass below then clips the corresponding group fills.
        _filled_owner_jobs = saturating_sub(_filled_owner_jobs,
            std::max<int64_t>(0, population_store().owner_employed[source]), _saturation_count);
        _filled_employee_jobs = saturating_sub(_filled_employee_jobs,
            std::max<int64_t>(0, population_store().employee_employed[source]), _saturation_count);
        audit_touch_population_lane(source);
        population_store().funds.write_scalar(source, 0, market_mutation_sink());
        population_store().release_slot(source);
        population_store().reclaim_empty_pages(source_cell);
        _structural_touched_cells.push_back(source_cell);
        if (legs.size() > 1) legs[1].after = country_reads().total_cash();
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                     SUBJECT_COHORT, source_handle, 0, -1,
                     0, estate_funds, source_cell, -1,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    if (cmd.cell < 0 || cmd.cell >= _cell_count.get() || cmd.signature < 0 ||
        cmd.signature >= static_cast<int32_t>(_signatures.size())) {
        ++_rejected_commands;   // unknown destination signature: drop this move, keep the day alive
        return true;
    }
    // State-service professions (soldier) are emplaced by the state, not by the
    // local job market: a barracks is a Military state building and never shows
    // up as an Economy employment seat, so requiring local availability would
    // reject every enlistment. The design (5.4) makes these posts ordinary
    // state payroll seats; the caller owns the post validation.
    const int32_t destination_profession = _signatures[cmd.signature].profession_id;
    if (!profession_is_state_service_only(destination_profession) &&
        !profession_available(cmd.cell, destination_profession, true)) {
        ++_rejected_commands;
        return true;
    }
    if (cmd.cell == source_cell &&
        cmd.signature == static_cast<int32_t>(population_store().signature_id[source])) return true;
    return move_cohort_population(source, cmd.cell, cmd.signature, cmd.population, error);
}

bool NativeEconomyRuntime::move_cohort_population(int32_t source, int32_t dest_cell,
                                                   int32_t dest_signature,
                                                   int64_t requested_pop,
                                                   std::string &error,
                                                   bool *source_drained_out,
                                                   uint64_t preferred_family_handle,
                                                   bool preferred_family_strict) {
    if (source_drained_out != nullptr) *source_drained_out = false;
    const int32_t source_cell = population_store().page_cell[source / COHORT_PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(population_store().handle_for_slot(source));
    const int32_t cmd_cell = dest_cell;
    const int32_t cmd_signature = dest_signature;
    const int64_t source_pop = std::max<int64_t>(0, population_store().population[source]);
    const int64_t move_pop = std::min(std::max<int64_t>(0, requested_pop), source_pop);
    if (move_pop == 0) return true;
    _structural_touched_cells.push_back(source_cell);
    _structural_touched_cells.push_back(cmd_cell);
    // Money follows people: family members carry their per-capita claim,
    // anonymous movers the per-capita anonymous remainder.
    int64_t move_funds = move_pop == source_pop
                             ? population_store().funds[source]
                             : mul_div_sat(population_store().funds[source], move_pop, source_pop,
                                           _saturation_count);
    if (!family_memberships().empty()) {
        const int64_t anonymous_moved = plan_family_membership_move(source, cmd_cell,
            move_pop, preferred_family_handle, preferred_family_strict);
        if (move_pop < source_pop && !_family_edge_scratch.empty()) {
            int64_t family_people = 0, family_claim = 0, moved_claim = 0;
            for (int32_t edge : _family_edge_scratch) {
                family_people += std::max<int64_t>(0, family_memberships()[edge].people);
                family_claim += std::max<int64_t>(0, family_memberships()[edge].cash_claim);
            }
            for (const FamilyMovePlanRow &row : _family_move_plan)
                moved_claim = saturating_add(moved_claim, row.claim, _saturation_count);
            const int64_t source_funds = std::max<int64_t>(0, population_store().funds[source]);
            const int64_t anonymous = std::max<int64_t>(0, source_pop - family_people);
            const int64_t anonymous_funds = std::max<int64_t>(0, source_funds - family_claim);
            const int64_t anonymous_move_funds = anonymous > 0
                ? mul_div_sat(anonymous_funds, std::min(anonymous_moved, anonymous),
                              anonymous, _saturation_count) : 0;
            move_funds = std::clamp<int64_t>(saturating_add(moved_claim,
                anonymous_move_funds, _saturation_count), 0, source_funds);
        }
    }
    const int64_t move_income = move_pop == source_pop
                                    ? population_store().epoch_income[source]
                                    : mul_div_sat(population_store().epoch_income[source], move_pop, source_pop,
                                                  _saturation_count);
    const int64_t move_expense = move_pop == source_pop
                                     ? population_store().epoch_expense[source]
                                     : mul_div_sat(population_store().epoch_expense[source], move_pop, source_pop,
                                                   _saturation_count);
    const int64_t move_in_kind = move_pop == source_pop
                                     ? population_store().epoch_in_kind_income[source]
                                     : mul_div_sat(population_store().epoch_in_kind_income[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_ema = move_pop == source_pop
                                 ? population_store().income_ema[source]
                                 : mul_div_sat(population_store().income_ema[source], move_pop, source_pop,
                                               _saturation_count);
    const int64_t move_residual = move_pop == source_pop
                                      ? population_store().demography_residual[source]
                                      : mul_div_sat(population_store().demography_residual[source], move_pop,
                                                    source_pop, _saturation_count);
    const int64_t move_tax_paid = move_pop == source_pop
                                      ? population_store().epoch_tax_paid[source]
                                      : mul_div_sat(population_store().epoch_tax_paid[source],
                                                    move_pop, source_pop, _saturation_count);
    const int64_t move_subsidy = move_pop == source_pop
                                     ? population_store().epoch_subsidy_received[source]
                                     : mul_div_sat(population_store().epoch_subsidy_received[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_baseline_ema = move_pop == source_pop
                                          ? population_store().income_baseline_ema[source]
                                          : mul_div_sat(population_store().income_baseline_ema[source],
                                                        move_pop, source_pop, _saturation_count);
    const uint16_t move_satisfaction = population_store().needs_satisfaction[source];
    const uint16_t move_composite = population_store().composite_satisfaction[source];
    const uint8_t move_worst_dimension = population_store().worst_dimension_id[source];

    const int64_t source_population_before = population_store().population[source];
    const int64_t source_funds_before = population_store().funds[source];
    const int64_t source_income_before = population_store().epoch_income[source];
    const int64_t source_expense_before = population_store().epoch_expense[source];
    const int64_t source_ema_before = population_store().income_ema[source];
    const int64_t source_residual_before = population_store().demography_residual[source];

    const int32_t destination = population_store().allocate_slot(cmd_cell, static_cast<uint32_t>(cmd_signature));
    if (destination < 0) {
        _family_move_plan.clear();
        error = "structural_destination_allocation_failed";
        return false;
    }
    const int64_t destination_pop_before = population_store().population[destination];
    if ((move_pop == source_pop && slot_has_merchant_profession(source)) ||
        (destination_pop_before == 0 && slot_has_merchant_profession(destination)))
        _merchant_ranges_dirty = true;
    const int64_t destination_funds_before = population_store().funds[destination];
    const int64_t destination_income_before = population_store().epoch_income[destination];
    const int64_t destination_expense_before = population_store().epoch_expense[destination];
    const int64_t destination_ema_before = population_store().income_ema[destination];
    const int64_t destination_residual_before = population_store().demography_residual[destination];
    touch_accounting_slot(destination);
    audit_touch_population_lane(destination);
    const int64_t destination_handle = static_cast<int64_t>(
        population_store().handle_for_slot(destination));
    population_store().population.write_scalar(destination, saturating_add(destination_pop_before, move_pop,
                                                         _saturation_count), market_mutation_sink());
    population_store().funds.write_scalar(destination, saturating_add(population_store().funds[destination], move_funds,
                                                    _saturation_count), market_mutation_sink());
    population_store().epoch_income.write_scalar(destination, saturating_add(
        population_store().epoch_income[destination], move_income, _saturation_count), market_mutation_sink());
    population_store().epoch_expense.write_scalar(destination, saturating_add(
        population_store().epoch_expense[destination], move_expense, _saturation_count), market_mutation_sink());
    population_store().epoch_in_kind_income.write_scalar(destination, saturating_add(
        population_store().epoch_in_kind_income[destination], move_in_kind, _saturation_count), market_mutation_sink());
    population_store().income_ema.write_scalar(destination, saturating_add(population_store().income_ema[destination],
                                                         move_ema, _saturation_count), market_mutation_sink());
    population_store().demography_residual.write_scalar(destination, saturating_add(
        population_store().demography_residual[destination], move_residual, _saturation_count), market_mutation_sink());
    population_store().epoch_tax_paid.write_scalar(destination, saturating_add(
        population_store().epoch_tax_paid[destination], move_tax_paid, _saturation_count), market_mutation_sink());
    population_store().epoch_subsidy_received.write_scalar(destination, saturating_add(
        population_store().epoch_subsidy_received[destination], move_subsidy, _saturation_count), market_mutation_sink());
    population_store().income_baseline_ema.write_scalar(destination, saturating_add(
        population_store().income_baseline_ema[destination], move_baseline_ema,
        _saturation_count), market_mutation_sink());
    // Satisfaction is an intensive per-capita quantity, so merging two cohorts
    // blends it by population rather than summing it.
    const int64_t merged_pop = population_store().population[destination];
    const auto blend_satisfaction = [&](uint16_t destination_value,
                                        uint16_t incoming_value) -> uint16_t {
        if (merged_pop <= 0) return static_cast<uint16_t>(Q16_ONE - 1);
        const int64_t weighted = saturating_add(
            mul_div_sat(destination_value, destination_pop_before, 1, _saturation_count),
            mul_div_sat(incoming_value, move_pop, 1, _saturation_count),
            _saturation_count);
        return static_cast<uint16_t>(
            std::clamp<int64_t>(weighted / merged_pop, 0, Q16_ONE - 1));
    };
    population_store().needs_satisfaction.write_scalar(destination, blend_satisfaction(
        population_store().needs_satisfaction[destination], move_satisfaction), market_mutation_sink());
    population_store().composite_satisfaction.write_scalar(destination, blend_satisfaction(
        population_store().composite_satisfaction[destination], move_composite), market_mutation_sink());
    {
        const size_t destination_base =
            static_cast<size_t>(destination) * static_cast<size_t>(SAT_DIM_COUNT);
        const size_t source_base =
            static_cast<size_t>(source) * static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            population_store().satisfaction_dims.write_scalar(destination_base + static_cast<size_t>(dim), blend_satisfaction(
                    population_store().satisfaction_dims[destination_base +
                                                  static_cast<size_t>(dim)],
                    population_store().satisfaction_dims[source_base + static_cast<size_t>(dim)]), market_mutation_sink());
        }
    }
    if (destination_pop_before <= 0)
        population_store().worst_dimension_id.write_scalar(destination, move_worst_dimension, market_mutation_sink());

    audit_touch_population_lane(source);
    population_store().population.write_scalar(source, population_store().population[source] - (move_pop), market_mutation_sink());
    population_store().funds.write_scalar(source, population_store().funds[source] - (move_funds), market_mutation_sink());
    population_store().epoch_income.write_scalar(source, population_store().epoch_income[source] - (move_income), market_mutation_sink());
    population_store().epoch_expense.write_scalar(source, population_store().epoch_expense[source] - (move_expense), market_mutation_sink());
    population_store().epoch_in_kind_income.write_scalar(source, population_store().epoch_in_kind_income[source] - (move_in_kind), market_mutation_sink());
    population_store().income_ema.write_scalar(source, population_store().income_ema[source] - (move_ema), market_mutation_sink());
    population_store().epoch_tax_paid.write_scalar(source, population_store().epoch_tax_paid[source] - (move_tax_paid), market_mutation_sink());
    population_store().epoch_subsidy_received.write_scalar(source, population_store().epoch_subsidy_received[source] - (move_subsidy), market_mutation_sink());
    population_store().income_baseline_ema.write_scalar(source, population_store().income_baseline_ema[source] - (move_baseline_ema), market_mutation_sink());
    population_store().demography_residual.write_scalar(source, population_store().demography_residual[source] - (move_residual), market_mutation_sink());
    if (!family_memberships().empty())
        move_family_membership(source, destination, move_funds);
    if (population_store().population[source] == 0) {
        // Any rounding residue is money, not an implicit burn.
        const int64_t residue_funds = population_store().funds[source];
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : country_reads().country_handle_for_cell(source_cell);
        int64_t moved = 0;
        std::string cohort_cash_error;
        if (!coordinate_country_cohort_cash(
                source, country_handle,
                CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT,
                residue_funds, moved, cohort_cash_error)) {
            error = cohort_cash_error.empty()
                ? "country_treasury_residue_transfer_failed" : cohort_cash_error;
            return false;
        }
        if (moved != residue_funds) {
            // Same gate soft-unavailable path as STRUCTURAL_REMOVE_EMPTY:
            // keep residual funds on the drained slot until Country peer opens.
            if (moved == 0 &&
                (cohort_cash_error == "country_economy_operation_gate_closed" ||
                 cohort_cash_error == "country_cohort_cash_treasury_unowned" ||
                 cohort_cash_error == "country_cohort_cash_negative_balance")) {
                if (source_drained_out != nullptr) *source_drained_out = false;
                return true;
            }
            error = "country_treasury_residue_transfer_failed";
            return false;
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, residue_funds, _saturation_count);
        population_store().funds.write_scalar(source, 0, market_mutation_sink());
        population_store().release_slot(source);
        population_store().reclaim_empty_pages(source_cell);
        if (source_drained_out != nullptr) *source_drained_out = true;
    }
    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(source_cell) || trace_detail_for_cell(cmd_cell)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                        source_population_before, source_population_before - move_pop});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                        source_funds_before, source_funds_before - move_funds});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, source_handle, -1,
                        source_income_before, source_income_before - move_income});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, source_handle, -1,
                        source_expense_before, source_expense_before - move_expense});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, source_handle, -1,
                        source_ema_before, source_ema_before - move_ema});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        source_handle, -1, source_residual_before,
                        source_residual_before - move_residual});
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, destination_handle, -1,
                        destination_pop_before, population_store().population[destination]});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, destination_handle, -1,
                        destination_funds_before, population_store().funds[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, destination_handle, -1,
                        destination_income_before, population_store().epoch_income[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, destination_handle, -1,
                        destination_expense_before, population_store().epoch_expense[destination]});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, destination_handle, -1,
                        destination_ema_before, population_store().income_ema[destination]});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        destination_handle, -1, destination_residual_before,
                        population_store().demography_residual[destination]});
    }
    trace_append(EVENT_STRUCTURAL_CHANGE,
                 static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                 SUBJECT_COHORT, source_handle, cmd_signature, cmd_cell,
                 move_pop, move_funds, source_cell, cmd_cell,
                 legs.empty() ? nullptr : &legs);
    if (source_cell != cmd_cell) {
        if (source_cell >= 0 && source_cell < static_cast<int32_t>(_cell_moved_out.size()))
            _cell_moved_out[static_cast<size_t>(source_cell)] =
                saturating_add(_cell_moved_out[static_cast<size_t>(source_cell)],
                    move_pop, _saturation_count);
        if (cmd_cell >= 0 && cmd_cell < static_cast<int32_t>(_cell_moved_in.size()))
            _cell_moved_in[static_cast<size_t>(cmd_cell)] =
                saturating_add(_cell_moved_in[static_cast<size_t>(cmd_cell)],
                    move_pop, _saturation_count);
    }
    return true;
}


// Country/Economy asset backpressure surfaced from inside a cursor-driven
// stage drain. The cursor has not advanced past the failing command, so the
// same command replays on the next pulse. Drain the peer queue on the way out
// so Country-origin terminals keep landing while this stage is parked;
// otherwise the Country plan window that caused the park can never close.
void NativeEconomyRuntime::clear_family_branch_effects(uint64_t branch_handle) {
    int32_t branch = -1;
    if (!family_influences().valid_handle(branch_handle, branch)) return;
    for (const FamilyTriggerBinding &binding : _family_trigger_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        reconcile_trigger_branch_binding(_trigger_runtime,
            binding.definition_key, branch_handle,
            family_influences().cell[branch], binding.reward_target, false);
    }
    _family_trigger_bindings.erase_if(
        [&](const FamilyTriggerBinding &binding) {
            return binding.branch_handle == branch_handle;
        });
    if (_effect_runtime != nullptr) {
        const uint64_t stable_id = static_cast<uint64_t>(family_influences().stable_id[branch]);
        const uint32_t generation = static_cast<uint32_t>(branch_handle >> 32U);
        const auto branch_bindings = _family_effect_instances_by_branch.find(
            branch_handle);
        const std::vector<int64_t> instance_ids = branch_bindings ==
                _family_effect_instances_by_branch.end()
            ? std::vector<int64_t>() : branch_bindings->second;
        for (const int64_t instance_id : instance_ids) {
            const auto indexed = _family_effect_binding_by_instance.find(instance_id);
            if (indexed == _family_effect_binding_by_instance.end()) continue;
            const size_t binding_index = indexed->second;
            const FamilyEffectBinding &binding = _family_effect_bindings[binding_index];
            std::string error;
            const bool retired = effect_pod_retire(_effect_runtime,
                _effect_forwarder, binding.instance_id, binding.generation,
                _current_day.get(), error);
            if (retired) {
                remove_family_effect_binding(binding_index);
            }
        }
        for (size_t binding_row = 0; binding_row < _family_modifier_bindings.size(); ++binding_row) {
        auto binding_write = _family_modifier_bindings.edit_row(binding_row);
        FamilyModifierBinding &binding = binding_write[0];
            if (binding.branch_handle != branch_handle ||
                binding.magnitude_q16 == 0) continue;
            std::string error;
            uint64_t identity = trace_hash_mix(1469598103934665603ULL, stable_id);
            identity = trace_hash_mix(identity, static_cast<uint32_t>(
                family_influences().cell[branch]));
            uint64_t definition_hash = 1469598103934665603ULL;
            for (unsigned char ch : binding.definition_key)
                definition_hash = trace_hash_mix(definition_hash, ch);
            identity = trace_hash_mix(identity, definition_hash);
            const int64_t instance_id = static_cast<int64_t>(identity &
                0x7fffffffffffffffULL);
            const bool retired = effect_pod_retire(_effect_runtime,
                _effect_forwarder, instance_id, generation, _current_day.get(),
                error);
            // Keep a non-zero binding when the bounded Effect queue is full or
            // the definition is temporarily unavailable. The next branch
            // reconciliation can retry retirement instead of silently losing
            // the only cleanup handle.
            if (retired) binding.magnitude_q16 = 0;
        }
    } else if (_modifier_runtime != nullptr) {
        for (size_t binding_row = 0; binding_row < _family_modifier_bindings.size(); ++binding_row) {
        auto binding_write = _family_modifier_bindings.edit_row(binding_row);
        FamilyModifierBinding &binding = binding_write[0];
            if (binding.branch_handle != branch_handle ||
                binding.magnitude_q16 == 0) continue;
            std::string error;
            modifier_api::queue_family_group_effect_remove(*_modifier_runtime,
                binding.definition_key, family_influences().cell[branch],
                static_cast<uint64_t>(family_influences().stable_id[branch]),
                _current_day.get(), error);
            binding.magnitude_q16 = 0;
        }
    }
    _family_modifier_bindings.erase_if(
        [&](const FamilyModifierBinding &binding) {
            return binding.branch_handle == branch_handle &&
                binding.magnitude_q16 == 0;
        });
}





// Canonical row order is (person slot, need id). Rows arrive grouped by market
// cell batch, so a comparison sort would run in full every epoch; bucketing by
// slot is linear and produces the offsets the CSR needs as a by-product.
void NativeEconomyRuntime::retire_person(int32_t person_index) {
    if (person_index < 0 || person_index >= static_cast<int32_t>(
            persons_store().active.size()) || persons_store().active[person_index] == 0) return;
    const auto retire_call_started = Clock::now();
    ++_person_retire_calls;
    const uint64_t person_handle = persons_store().handle_for_index(person_index);
    if (_effect_runtime != nullptr) {
        uint64_t hash = trace_hash_mix(1469598103934665603ULL,
            static_cast<uint64_t>(persons_store().stable_id[person_index]));
        hash = trace_hash_mix(hash, 0x504552534f4eULL);
        std::string error;
        const int64_t instance_id = static_cast<int64_t>(
            hash & 0x7fffffffffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(person_handle >> 32U);
        effect_pod_retire(_effect_runtime, _effect_forwarder, instance_id,
                          generation, _current_day.get(), error);
    }
    if (_modifier_runtime != nullptr)
        modifier_api::unregister_person_target(*_modifier_runtime, person_handle);
    // Releasing the slot bumps the generation, so the retired handle can never
    // match again. Orphaned need rows are dropped by one compaction pass
    // instead of one full-array erase per retirement.
    _person_stable_ids.erase(persons_store().stable_id[person_index]);
    persons_store().release(person_index);
    _person_needs_orphaned = true;
    _person_indices_dirty = true;
    _person_retire_call_ms += elapsed_ms(retire_call_started);
}

void NativeEconomyRuntime::register_person_effect(int32_t person_index) {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr ||
        person_index < 0 || person_index >= static_cast<int32_t>(persons_store().active.size()) ||
        persons_store().active[person_index] == 0) return;
    const uint64_t person_handle = persons_store().handle_for_index(person_index);
    modifier_api::register_person_target(*_modifier_runtime, person_handle);
    uint64_t hash = trace_hash_mix(1469598103934665603ULL,
        static_cast<uint64_t>(persons_store().stable_id[person_index]));
    hash = trace_hash_mix(hash, 0x504552534f4eULL);
    const int64_t instance_id = static_cast<int64_t>(
        hash & 0x7fffffffffffffffULL);
    // Authority-aware dedup. EffectRuntime is writeback-only under worker
    // authority, so the old query was always false there and every call
    // re-upserted the row -- and each re-upsert carries a fresh next_due_day,
    // which kept postponing the fire instead of being a no-op.
    bool already_registered = false;
    effect_pod_instance_exists(_effect_runtime, _effect_forwarder, instance_id,
        static_cast<uint32_t>(person_handle >> 32U), already_registered);
    if (already_registered) return;
    std::string error;
    effect_pod_upsert(_effect_runtime, _effect_forwarder, instance_id,
        "person.modifier.gameplay.generic.bonus",
        static_cast<uint32_t>(person_handle >> 32U), 0x50455253,
        persons_store().stable_id[person_index], person_handle, person_handle,
        static_cast<uint32_t>(person_handle >> 32U), 0, _current_day.get(), -1,
        true, error);
}
} // namespace pk
