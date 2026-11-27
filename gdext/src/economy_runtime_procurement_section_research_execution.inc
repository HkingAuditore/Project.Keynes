NativeEconomyRuntime::CountryWorkerAssetRoute
NativeEconomyRuntime::block_or_enqueue_country_worker_asset(
        uint16_t operation, int64_t country_handle, int64_t cash,
        int64_t quantity, const std::vector<int32_t> &good_ids,
        const std::vector<int64_t> &good_quantities, std::string &error,
        uint64_t *request_id, int32_t target_slot) {
    if (_country_runtime == nullptr ||
        (!country_reads().sync_store_writes_forbidden() &&
         !(_simulation_host != nullptr && _simulation_host->domain_is_worker_authoritative(
             RuntimeDomainId::COUNTRY))))
        return CountryWorkerAssetRoute::NOT_APPLICABLE;
    // Gate is a bit-mask over RuntimeEconomyAssetOperation. Default is fiscal
    // only (M1); open_all_d7_operation_gates() expands to all nine ops.
    // Soft-unavailable (not TERMINAL_ERROR): callers must skip the op without
    // failing the whole economy runtime — Country unique-writer + Economy sync
    // is an expected production pairing before M2–M5 land.
    const uint32_t op_bit = 1u << static_cast<uint32_t>(operation);
    if ((_d7_operation_gate_mask & op_bit) == 0u) {
        error = "country_economy_operation_gate_closed";
        return CountryWorkerAssetRoute::GATE_SOFT_UNAVAILABLE;
    }
    if (_simulation_host == nullptr) {
        error = "country_economy_bridge_unavailable";
        return CountryWorkerAssetRoute::TERMINAL_ERROR;
    }
    uint64_t wire_request_id = request_id != nullptr ? *request_id : 0;
    if (wire_request_id == 0)
        wire_request_id = _simulation_host->allocate_command_request_id();
    RuntimeEconomyAssetRequest request;
    request.operation = static_cast<RuntimeEconomyAssetOperation>(operation);
    request.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    request.origin_epoch = _epoch_id.get();
    request.origin_stage = static_cast<int32_t>(_stage);
    // A fiscal reservation continuation owns the admission day until every
    // country in that frozen plan has reached a terminal peer result. The
    // scheduler may deliver the next pulse with a later wall-clock day, but
    // allowing that value into the wire identity would make one logical
    // continuation appear to cross days and can reject an otherwise valid
    // retry as stale. Keep the request day stable for the whole reservation
    // boundary.
    const int64_t request_day =
        _fiscal_reservation_continuation.active &&
            _fiscal_reservation_continuation.day_index >= 0
        ? _fiscal_reservation_continuation.day_index
        : (_fiscal_settlement_continuation.active &&
            _fiscal_settlement_continuation.day_index >= 0
            ? _fiscal_settlement_continuation.day_index
            : std::max<int64_t>(0, _current_day.get()));
    request.day = request_day;
    request.transaction_id = wire_request_id;
    request.request_id = wire_request_id;
    request.operation_sequence = wire_request_id;
    // Same identity the sync cohort-cash path stamps. Leaving it 0 made every
    // worker-routed fiscal/research terminal record fail PKEC restore
    // (save_fiscal_peer_completed_record_invalid:peer_generation), so any save
    // made with an active tax could be written but never loaded. The value is
    // stable across a continuation: _committed_generation only advances at
    // aggregate publish, after every same-epoch peer request has terminated.
    request.peer_generation = _committed_generation;
    request.country_handle = static_cast<uint64_t>(country_handle);
    request.target_slot = target_slot;
    request.requested_cash = cash;
    request.requested_quantity = quantity;
    request.requested_goods_total = quantity;
    request.good_count = 0;
    const size_t copied = std::min(good_ids.size(), good_quantities.size());
    for (size_t i = 0; i < copied && i < RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY; ++i) {
        request.good_ids[i] = good_ids[i];
        request.good_quantities[i] = good_quantities[i];
        ++request.good_count;
    }
    if (request.good_count > 0) request.good_id = request.good_ids[0];
    if (request_id != nullptr) *request_id = wire_request_id;
    if (!_simulation_host->enqueue_economy_origin_country_asset(request, error)) {
        if (error.empty()) error = "country_economy_asset_enqueue_failed";
        return CountryWorkerAssetRoute::TERMINAL_ERROR;
    }
    error = "country_economy_asset_host_pending";
    return CountryWorkerAssetRoute::ENQUEUED_PENDING;
}

bool NativeEconomyRuntime::pull_owned_command_result(
        RuntimeEconomyOwnedState &owned, const RuntimeEconomyPodCommand &command,
        int64_t settled, std::string &error) {
    error.clear();
    if (RuntimeEconomyPodAuthority::is_owned_heavy_pod_opcode(command.opcode)) {
        if (!sync_owned_columns_to_production(owned, error)) return false;
        if (!apply_pod_command(command, error)) return false;
        sync_production_core_columns_to_owned(owned);
        capture_owned_mirror_stores(owned);
        return true;
    }
    if (!sync_owned_columns_to_production(owned, error)) return false;

    const uint64_t target_handle = command.target_cohort != 0
                                       ? command.target_cohort
                                       : command.target_building;
    int32_t slot = -1;

    switch (command.opcode) {
    case COMMAND_TRANSFER_TO_COHORT:
    case COMMAND_TRANSFER_FROM_COHORT: {
        if (!population_store().valid_handle(target_handle, slot)) {
            error = "stale_cohort_handle_during_transfer";
            return false;
        }
        const int32_t event_cell =
            population_store().page_cell[slot / COHORT_PAGE_SIZE];
        const int64_t country_handle =
            command.payload1 != 0
                ? command.payload1
                : (_country_runtime == nullptr
                       ? 0
                       : country_reads().country_handle_for_cell(event_cell));
        if (country_handle == 0) {
            error = "country_treasury_target_invalid";
            return false;
        }
        if (settled > 0) {
            if (command.opcode == COMMAND_TRANSFER_TO_COHORT) {
                population_store().funds.write_scalar(slot, std::max<int64_t>(0, population_store().funds[slot] - settled), market_mutation_sink());
                population_store().epoch_income.write_scalar(slot, std::max<int64_t>(
                    0, population_store().epoch_income[slot] - settled), market_mutation_sink());
            } else {
                population_store().funds.write_scalar(slot, saturating_add(
                    population_store().funds[slot], settled, _saturation_count), market_mutation_sink());
                population_store().epoch_expense.write_scalar(slot, std::max<int64_t>(
                    0, population_store().epoch_expense[slot] - settled), market_mutation_sink());
            }
        }
        int64_t committed = 0;
        const int32_t operation =
            command.opcode == COMMAND_TRANSFER_TO_COHORT
                ? CountryApi::ECONOMY_ASSET_CASH_TO_COHORT
                : CountryApi::ECONOMY_ASSET_CASH_FROM_COHORT;
        if (!coordinate_country_cohort_cash(slot, country_handle, operation,
                                            settled, committed, error))
            return false;
        sync_production_core_columns_to_owned(owned);
        break;
    }
    case COMMAND_COUNTRY_GOOD_TO_MARKET:
    case COMMAND_MARKET_GOOD_TO_COUNTRY: {
        const int32_t market_id = command.target_cell;
        const int32_t good_id = static_cast<int32_t>(command.target_country);
        const int64_t index = market_store().index(market_id, good_id);
        if (index < 0 || static_cast<size_t>(index) >= market_store().stock.size()) {
            error = "economy_pod_owned_core_market_oob";
            return false;
        }
        const int64_t country_handle = static_cast<int64_t>(target_handle);
        if (country_handle == 0 ||
            _country_runtime == nullptr ||
            !country_reads().valid_handle(country_handle)) {
            error = "country_treasury_target_invalid";
            return false;
        }
        // The Country/Economy asset coordinator owns the market mutation.
        // Do not pre-apply the stock delta here: the coordinator commits the
        // Country transaction and applies the market side exactly once.
        int64_t moved = 0;
        const int32_t operation =
            command.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET
                ? CountryApi::ECONOMY_ASSET_GOOD_TO_MARKET
                : CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET;
        if (!coordinate_country_market_goods(
                market_id, good_id, country_handle, operation, settled, moved,
                error))
            return false;
        sync_production_core_columns_to_owned(owned);
        break;
    }
    case COMMAND_MINT_TO_COHORT:
        _explicit_money_mint =
            saturating_add(_explicit_money_mint, settled, _saturation_count);
        break;
    case COMMAND_BURN_FROM_COHORT:
        _explicit_money_burn =
            saturating_add(_explicit_money_burn, settled, _saturation_count);
        break;
    case COMMAND_ADD_STOCK:
        // OwnedState has already changed the stock. Retain its audit preimage
        // so an idle command is included in the next epoch's opening totals.
        audit_touch_market_lane(static_cast<size_t>(market_store().index(
            command.target_cell, static_cast<int32_t>(command.target_country))));
        _explicit_stock_delta =
            saturating_add(_explicit_stock_delta, settled, _saturation_count);
        break;
    case COMMAND_REMOVE_STOCK:
        audit_touch_market_lane(static_cast<size_t>(market_store().index(
            command.target_cell, static_cast<int32_t>(command.target_country))));
        _explicit_stock_delta =
            saturating_sub(_explicit_stock_delta, settled, _saturation_count);
        break;
    default:
        break;
    }
    return true;
}

bool NativeEconomyRuntime::run_government_research_procurement(std::string &error) {
    if (_country_runtime == nullptr || !country_reads().economy_available()) return true;
    const int32_t good = country_reads().technology_points_good_id();
    if (good < 0 || good >= market_store().good_count.get()) {
        error = "government_research_good_invalid";
        return false;
    }
    constexpr size_t CANDIDATES_PER_SLICE = 32;
    CountryResearchProcurementContinuation &continuation =
        _country_research_procurement_continuation;
    if (!_country_research_procurement_initialized) {
        _country_research_procurement_candidates.clear();
        _country_research_procurement_candidates.reserve(_epoch_market_ids.size());
        for (const int32_t market : _epoch_market_ids) {
            if (market < 0 || market >= _cell_count.get() ||
                market >= static_cast<int32_t>(_epoch_cell_country.size()) ||
                !market_has_living_merchant(market)) continue;
            const int32_t country = _epoch_cell_country[market];
            if (country < 0 || country >= _epoch_country_count) continue;
            const int64_t index = market_store().index(market, good);
            _country_research_procurement_candidates.push_back({
                country, market, good, market_store().price[index]});
        }
        std::stable_sort(_country_research_procurement_candidates.begin(),
            _country_research_procurement_candidates.end(),
            [](const CountryResearchProcurementCandidate &lhs,
               const CountryResearchProcurementCandidate &rhs) {
                if (lhs.country != rhs.country) return lhs.country < rhs.country;
                if (lhs.price != rhs.price) return lhs.price < rhs.price;
                return lhs.market < rhs.market;
            });
        const size_t country_count = static_cast<size_t>(
            std::max(0, _epoch_country_count));
        _country_research_procurement_budgets.assign(country_count, 0);
        _country_research_procurement_remaining.assign(country_count, 0);
        _country_research_procurement_enabled.assign(country_count, 0);
        _country_research_procurement_cursor = 0;
        _country_research_procurement_phase = 0;
        _country_research_procurement_initialized = true;
        _country_research_procurement_done = false;
        continuation = CountryResearchProcurementContinuation{};
    }
    // Starter treasury stock often zeros remaining_points on the first epoch
    // slice. Country research may then spend that stock and enqueue more work
    // while this economy epoch is still open. Re-read live policy when the
    // pass is finished, or when a country had no live demand — never rewrite
    // in-flight remaining mid-purchase (that would over-buy). Phase 1 only
    // books ceiling signals against remaining; a zero there is not a bought
    // gap, and waking on it rewinds the cursor forever once candidates
    // exceed one slice.
    if (!continuation.active &&
        (_country_research_procurement_phase == 0 ||
         _country_research_procurement_done)) {
        const size_t country_count = static_cast<size_t>(
            std::max(0, _epoch_country_count));
        if (_country_research_procurement_budgets.size() != country_count ||
            _country_research_procurement_remaining.size() != country_count ||
            _country_research_procurement_enabled.size() != country_count) {
            _country_research_procurement_budgets.assign(country_count, 0);
            _country_research_procurement_remaining.assign(country_count, 0);
            _country_research_procurement_enabled.assign(country_count, 0);
        }
        bool demand_appeared = false;
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const size_t index = static_cast<size_t>(country);
            const uint8_t was_enabled =
                _country_research_procurement_enabled[index];
            const int64_t was_remaining =
                _country_research_procurement_remaining[index];
            const bool refresh_country =
                _country_research_procurement_done || was_enabled == 0 ||
                was_remaining <= 0;
            if (!refresh_country) continue;
            bool policy_enabled = false;
            int64_t daily_budget = 0;
            int64_t demand = 0;
            if (!research_procurement_policy_for(
                    country, policy_enabled, daily_budget, demand) ||
                !policy_enabled || daily_budget <= 0 || demand <= 0) {
                _country_research_procurement_enabled[index] = 0;
                _country_research_procurement_budgets[index] = 0;
                _country_research_procurement_remaining[index] = 0;
                continue;
            }
            _country_research_procurement_enabled[index] = 1;
            _country_research_procurement_budgets[index] =
                std::min(country_reads().cash_for_slot(country),
                    saturating_mul(daily_budget, std::max(1, _epoch_days.get()),
                                   _saturation_count));
            _country_research_procurement_remaining[index] = demand;
            // Wake a finished pass, or a country that previously had no gap.
            if (demand > 0 &&
                (_country_research_procurement_done || was_enabled == 0 ||
                 was_remaining <= 0))
                demand_appeared = true;
        }
        if (demand_appeared) {
            refresh_epoch_research_demand();
            _country_research_procurement_done = false;
            if (_country_research_procurement_phase > 1)
                _country_research_procurement_phase = 0;
            _country_research_procurement_cursor = 0;
        }
    }
    if (_country_research_procurement_done) return true;

    {
        static int s_procure_diag_left = 24;
        if (s_procure_diag_left > 0) {
            int64_t enabled_n = 0;
            int64_t remaining_sum = 0;
            int64_t budget_sum = 0;
            for (size_t i = 0; i < _country_research_procurement_enabled.size();
                 ++i) {
                if (_country_research_procurement_enabled[i] == 0) continue;
                ++enabled_n;
                if (i < _country_research_procurement_remaining.size())
                    remaining_sum += _country_research_procurement_remaining[i];
                if (i < _country_research_procurement_budgets.size())
                    budget_sum += _country_research_procurement_budgets[i];
            }
            if (enabled_n > 0 || remaining_sum > 0 ||
                !_country_research_procurement_candidates.empty()) {
                --s_procure_diag_left;
                const uint32_t research_bit = 1u << static_cast<uint32_t>(
                    RuntimeEconomyAssetOperation::RESEARCH_PURCHASE);
                std::fprintf(stderr,
                    "[research-procure-diag] day=%lld phase=%d done=%d "
                    "cands=%zu cursor=%zu enabled=%lld remain=%lld budget=%lld "
                    "gate_mask=0x%x research_gate=%d orders=%lld rej=%lld "
                    "procured=%lld last_err=%s\n",
                    static_cast<long long>(_current_day.get()),
                    _country_research_procurement_phase,
                    _country_research_procurement_done ? 1 : 0,
                    _country_research_procurement_candidates.size(),
                    _country_research_procurement_cursor,
                    static_cast<long long>(enabled_n),
                    static_cast<long long>(remaining_sum),
                    static_cast<long long>(budget_sum),
                    _d7_operation_gate_mask,
                    (_d7_operation_gate_mask & research_bit) != 0u ? 1 : 0,
                    static_cast<long long>(_government_research_procurement_orders.get()),
                    static_cast<long long>(_country_research_procurement_rejections),
                    static_cast<long long>(_government_research_procured_points.get()),
                    continuation.last_error.c_str());
            }
        }
    }

    const auto finish_terminal_continuation = [&]() -> bool {
        if (continuation.phase == 7) {
            ++_country_research_procurement_rejections;
            error = continuation.last_error.empty()
                ? "country_research_procurement_faulted"
                : continuation.last_error;
            continuation = CountryResearchProcurementContinuation{};
            return false;
        }
        if (continuation.phase == 6) {
            ++_country_research_procurement_rejections;
            ++_country_research_procurement_cursor;
            continuation = CountryResearchProcurementContinuation{};
            return true;
        }
        if (continuation.phase == 5) {
            const size_t country = static_cast<size_t>(continuation.country);
            if (country >= _country_research_procurement_budgets.size() ||
                country >= _country_research_procurement_remaining.size() ||
                continuation.market < 0 || continuation.market >=
                    static_cast<int32_t>(_epoch_ceiling_research_requested.size()) ||
                continuation.market >= static_cast<int32_t>(
                    _epoch_ceiling_research_delivered.size())) {
                error = "country_research_procurement_terminal_identity_invalid";
                continuation = CountryResearchProcurementContinuation{};
                return false;
            }
            _country_research_procurement_budgets[country] -= continuation.cash;
            _country_research_procurement_remaining[country] -= continuation.quantity;
            // The treasury debit landed in this same advance (sync peer or Host
            // peer flush), so attribute the cash to the paying country here and
            // let commit_fiscal publish it as a non-tax outflow.
            if (country < _epoch_country_handles.size()) {
                note_non_tax_outflow(_epoch_country_handles[country],
                    NON_TAX_RESEARCH_PURCHASE, continuation.cash);
                note_procurement_cash(_epoch_country_handles[country], 0,
                    continuation.cash);
            }
            _government_research_procured_points = saturating_add(
                _government_research_procured_points.get(), continuation.quantity,
                _saturation_count);
            _government_research_procurement_cash = saturating_add(
                _government_research_procurement_cash.get(), continuation.cash,
                _saturation_count);
            if (_epoch_ceiling_research_requested[continuation.market] == 0 &&
                _epoch_ceiling_research_delivered[continuation.market] == 0)
                _epoch_ceiling_research_touched.push_back(continuation.market);
            _epoch_ceiling_research_requested[continuation.market] = saturating_add(
                _epoch_ceiling_research_requested[continuation.market],
                continuation.quantity, _saturation_count);
            _epoch_ceiling_research_delivered[continuation.market] = saturating_add(
                _epoch_ceiling_research_delivered[continuation.market],
                continuation.quantity, _saturation_count);
            ++_government_research_procurement_orders;
            ++_country_research_procurement_transactions;
            ++_country_research_procurement_cursor;
            continuation = CountryResearchProcurementContinuation{};
            return true;
        }
        error = "country_research_procurement_terminal_phase_invalid";
        continuation = CountryResearchProcurementContinuation{};
        return false;
    };

    // A selected candidate is sealed in continuation before any Country
    // mutation.  Every later call resumes the same transaction identity and
    // merchant allocation; it never re-sorts or re-selects a market.
    if (continuation.active) {
        const bool advanced = advance_country_research_procurement(
            continuation, error);
        if (!advanced) return false;
        if (continuation.active) return true;
        return finish_terminal_continuation();
    }

    // A Country rejection is terminal even though the continuation has
    // already released its reservation and cleared `active`.
    if (continuation.phase == 6 || continuation.phase == 7 ||
        continuation.phase == 5)
        return finish_terminal_continuation();

    if (_country_research_procurement_phase == 0) {
        const size_t end = std::min(
            _country_research_procurement_candidates.size(),
            _country_research_procurement_cursor + CANDIDATES_PER_SLICE);
        while (_country_research_procurement_cursor < end) {
            const size_t candidate_index = _country_research_procurement_cursor;
            const CountryResearchProcurementCandidate &candidate =
                _country_research_procurement_candidates[candidate_index];
            const size_t country = static_cast<size_t>(candidate.country);
            if (country >= _country_research_procurement_enabled.size() ||
                _country_research_procurement_enabled[country] == 0 ||
                _country_research_procurement_budgets[country] <= 0 ||
                _country_research_procurement_remaining[country] <= 0 ||
                candidate.price <= 0) {
                ++_country_research_procurement_cursor;
                continue;
            }
            const int64_t index = market_store().index(candidate.market, candidate.good);
            const int64_t quantity = std::min({
                market_store().stock[index],
                _country_research_procurement_remaining[country],
                mul_div_sat(_country_research_procurement_budgets[country],
                    GOODS_SCALE, candidate.price, _saturation_count)});
            if (quantity <= 0) {
                ++_country_research_procurement_cursor;
                continue;
            }
            const int64_t cash = goods_cost(
                quantity, candidate.price, _saturation_count);
            if (cash <= 0) {
                ++_country_research_procurement_cursor;
                continue;
            }
            continuation = CountryResearchProcurementContinuation{};
            continuation.active = true;
            continuation.phase = 1;
            continuation.candidate_index = static_cast<int32_t>(candidate_index);
            continuation.country = candidate.country;
            continuation.market = candidate.market;
            continuation.good = candidate.good;
            continuation.quantity = quantity;
            continuation.cash = cash;
            continuation.living_merchants.reserve(16);
            if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1) &&
                candidate.market >= 0 && candidate.market < _cell_count.get()) {
                for (int32_t edge = _merchant_offsets[candidate.market];
                     edge < _merchant_offsets[candidate.market + 1]; ++edge) {
                    const int32_t slot = _merchant_slots[edge];
                    if (is_merchant_slot(slot))
                        continuation.living_merchants.push_back(slot);
                }
            }
            if (continuation.living_merchants.empty())
                collect_living_merchant_slots(candidate.market,
                                              continuation.living_merchants);
            int64_t merchant_population = 0;
            for (const int32_t slot : continuation.living_merchants)
                merchant_population = saturating_add(
                    merchant_population, population_store().population[slot],
                    _saturation_count);
            if (merchant_population <= 0) {
                continuation.last_error = "country_research_peer_merchant_empty";
                ++_country_research_procurement_rejections;
                continuation.active = false;
                ++_country_research_procurement_cursor;
                continue;
            }
            continuation.merchant_population = merchant_population;
            ++_country_research_procurement_slices;
            return true;
        }
        _country_research_procurement_phase = 1;
        _country_research_procurement_cursor = 0;
    }

    if (_country_research_procurement_phase == 1) {
        const size_t end = std::min(
            _country_research_procurement_candidates.size(),
            _country_research_procurement_cursor + CANDIDATES_PER_SLICE);
        for (; _country_research_procurement_cursor < end;
             ++_country_research_procurement_cursor) {
            const CountryResearchProcurementCandidate &candidate =
                _country_research_procurement_candidates[
                    _country_research_procurement_cursor];
            const size_t country = static_cast<size_t>(candidate.country);
            if (country >= _country_research_procurement_enabled.size() ||
                _country_research_procurement_enabled[country] == 0 ||
                _country_research_procurement_budgets[country] <= 0 ||
                _country_research_procurement_remaining[country] <= 0) continue;
            const int64_t quantity = std::min(
                _country_research_procurement_remaining[country],
                mul_div_sat(_country_research_procurement_budgets[country],
                    GOODS_SCALE, std::max<int64_t>(1, candidate.price),
                    _saturation_count));
            if (quantity <= 0) continue;
            if (_epoch_ceiling_research_requested[candidate.market] == 0 &&
                _epoch_ceiling_research_delivered[candidate.market] == 0)
                _epoch_ceiling_research_touched.push_back(candidate.market);
            _epoch_ceiling_research_requested[candidate.market] = saturating_add(
                _epoch_ceiling_research_requested[candidate.market], quantity,
                _saturation_count);
            _country_research_procurement_remaining[country] -= quantity;
            _country_research_procurement_budgets[country] -= goods_cost(
                quantity, candidate.price, _saturation_count);
        }
        if (_country_research_procurement_cursor <
                _country_research_procurement_candidates.size()) {
            ++_country_research_procurement_slices;
            return true;
        }
        _country_research_procurement_phase = 2;
        _country_research_procurement_done = true;
        return true;
    }
    error = "country_research_procurement_phase_invalid";
    return false;
}
