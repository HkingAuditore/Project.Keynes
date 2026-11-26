#include "economy_runtime_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;

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
            if (!finish_country_fiscal_asset(*transport_request_id, terminal, error))
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

} // namespace pk
