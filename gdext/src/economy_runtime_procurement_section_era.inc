// ── Era demand signals ───────────────────────────────────────────────────

void NativeEconomyRuntime::refresh_epoch_era_demand() {
    _epoch_era_demand_by_cell.clear();
    _epoch_era_demand_by_market.clear();
    if (_country_procurement.empty() || _country_runtime == nullptr ||
        market_store().market_count.get() <= 0) return;
    const bool cell_market_shape = market_store().cell_to_market.size() ==
        static_cast<size_t>(_cell_count.get());
    const int64_t days = std::max(1, _epoch_days.get());
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const EconomyProcurementState *state = procurement_state_for_slot(country);
        if (state == nullptr || !state->policy_enabled || !state->era_active ||
            state->era_daily <= 0) continue;
        int64_t budget = std::min(
            std::max<int64_t>(0, country_reads().cash_for_slot(country)),
            saturating_mul(state->era_daily, days, _saturation_count));
        for (const EraProcurementLine &line : state->era_goods) {
            if (budget <= 0) break;
            const int64_t remaining = std::max<int64_t>(0,
                line.required - country_reads().good_for_slot(country, line.good));
            if (remaining <= 0) continue;
            // Signal the cheapest in-territory market with a living merchant.
            int32_t best_cell = -1, best_market = -1;
            int64_t best_price = std::numeric_limits<int64_t>::max();
            for (const int32_t cell : _economy_live_cells) {
                if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
                    _epoch_cell_country[static_cast<size_t>(cell)] != country) continue;
                const int32_t market = cell_market_shape
                    ? market_store().cell_to_market[static_cast<size_t>(cell)] : cell;
                if (market < 0 || market >= market_store().market_count.get() ||
                    !market_has_living_merchant(market)) continue;
                const int64_t price = std::max<int64_t>(1,
                    market_store().price[market_store().index(market, line.good)]);
                if (price < best_price) {
                    best_price = price; best_cell = cell; best_market = market;
                }
            }
            if (best_market < 0) continue;
            const int64_t affordable = std::min(remaining,
                mul_div_sat(budget, GOODS_SCALE, best_price, _saturation_count));
            if (affordable <= 0) continue;
            budget -= goods_cost(affordable, best_price, _saturation_count);
            _epoch_era_demand_by_cell.push_back(
                {era_procurement_key(best_cell, line.good), affordable});
            _epoch_era_demand_by_market.push_back(
                {era_procurement_key(best_market, line.good), affordable});
            ensure_market_signal_index(best_cell, line.good);
        }
    }
    auto merge = [&](auto &rows) {
        std::sort(rows.begin(), rows.end());
        size_t write = 0;
        for (size_t read = 0; read < rows.size(); ++read) {
            if (write > 0 && rows[write - 1].first == rows[read].first)
                rows[write - 1].second = saturating_add(
                    rows[write - 1].second, rows[read].second, _saturation_count);
            else rows[write++] = rows[read];
        }
        rows.resize(write);
    };
    merge(_epoch_era_demand_by_cell);
    merge(_epoch_era_demand_by_market);
}

// ── Era procurement pass (market -> treasury) ────────────────────────────

bool NativeEconomyRuntime::advance_era_procurement(EraProcurementContinuation &c,
                                                   std::string &error) {
    error.clear();
    if (!c.active) return true;
    if (c.phase == 1) {
        if (c.pending_request_id == 0 || _simulation_host == nullptr) {
            c.active = false;
            c.last_error = "era_procurement_peer_identity_missing";
            return true;
        }
        RuntimeEconomyAssetResult terminal;
        if (!_simulation_host->country_economy_asset_terminal_result(
                c.pending_request_id, terminal)) {
            return true; // still pending; caller parks the stage
        }
        if (terminal.code != RuntimeEconomyAssetResultCode::COMPLETED ||
            terminal.operation != RuntimeEconomyAssetOperation::GOOD_FROM_MARKET) {
            c.last_error = terminal.reason[0] != '\0' ? terminal.reason.data()
                                                      : "era_procurement_peer_rejected";
            _simulation_host->acknowledge_country_economy_asset_consumed(c.pending_request_id);
            c.pending_request_id = 0;
            c.active = false;
            c.phase = 6;
            return true;
        }
        if (_simulation_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY)) {
            if (!_simulation_host->finish_worker_country_asset(
                    c.pending_request_id, terminal, error))
                return false;
        } else if (!_simulation_host->flush_country_economy_asset_commits(
                       error, c.pending_request_id) ||
                   !_simulation_host->publish_country_worker_snapshot(
                       RUNTIME_DIRTY_COUNTRY_STATE, error)) {
            return false;
        } else {
            _simulation_host->acknowledge_country_economy_asset_consumed(c.pending_request_id);
        }
        const int64_t committed_qty = terminal.committed_quantity > 0
            ? terminal.committed_quantity : c.quantity;
        const int64_t committed_cash = terminal.committed_cash > 0
            ? terminal.committed_cash : c.cash;
        if (committed_qty != c.quantity || committed_cash != c.cash) {
            error = "era_procurement_host_commit_quantity_drift";
            return false;
        }
        c.transaction_id = c.pending_request_id;
        c.pending_request_id = 0;
        c.host_peer = true;
        // The worker-side GOOD_FROM_MARKET service already removed the stock.
        c.market_applied = true;
        c.phase = 4;
    }
    if (c.phase == 4) {
        if (!c.market_applied) {
            const size_t lane = market_store().index(c.market, c.good);
            if (lane >= market_store().stock.size() ||
                market_store().stock[lane] < c.quantity) {
                error = "era_procurement_market_stock_drift";
                return false;
            }
            audit_touch_market_lane(lane);
            market_store().stock.write_scalar(lane,
                market_store().stock[lane] - c.quantity, market_mutation_sink());
            c.market_applied = true;
        }
        // Credit the local merchants with the frozen population weights.
        int64_t prefix = 0, distributed = 0;
        for (size_t index = 0; index < c.living_merchants.size(); ++index) {
            const int32_t slot = c.living_merchants[index];
            prefix = saturating_add(prefix, c.merchant_weights[index], _saturation_count);
            const int64_t next = mul_div_sat(c.cash, prefix, c.merchant_population,
                                             _saturation_count);
            const int64_t share = std::max<int64_t>(0, next - distributed);
            distributed = next;
            audit_touch_population_lane(slot);
            touch_accounting_slot(slot);
            population_store().funds.write_scalar(slot, saturating_add(
                population_store().funds[slot], share, _saturation_count),
                market_mutation_sink());
            population_store().epoch_income.write_scalar(slot, saturating_add(
                population_store().epoch_income[slot], share, _saturation_count),
                market_mutation_sink());
            trace_record_cashflow(c.market, population_store().handle_for_slot(slot),
                CASHFLOW_MERCHANT_BUSINESS, share, 0);
        }
        if (distributed != c.cash) {
            error = "era_procurement_merchant_distribution_drift";
            return false;
        }
        if (!c.host_peer) {
            const Dictionary applied = country_api::procurement_port(*_country_runtime).applied(
                {c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation}, true, "");
            if (!static_cast<bool>(applied.get("ok", false)) ||
                String(applied.get("status_name", "")) != "completed") {
                error = "era_procurement_peer_apply_ack_failed";
                return false;
            }
        }
        c.phase = 5;
        c.active = false;
        return true;
    }
    error = "era_procurement_phase_invalid";
    return false;
}

bool NativeEconomyRuntime::run_government_era_procurement(std::string &error) {
    error.clear();
    if (_era_procurement_done) return true;
    if (_country_runtime == nullptr || !country_reads().economy_available() ||
        _country_procurement.empty()) {
        _era_procurement_done = true;
        return true;
    }
    constexpr size_t CANDIDATES_PER_SLICE = 32;
    if (!_era_procurement_initialized) {
        _era_procurement_initialized = true;
        _era_procurement_cursor = 0;
        _era_procurement_candidates.clear();
        const size_t countries = static_cast<size_t>(std::max(0, _epoch_country_count));
        _era_procurement_budgets.assign(countries, 0);
        _era_procurement_handles.assign(countries, 0);
        _era_procurement_line_offsets.assign(countries + 1, 0);
        _era_procurement_remaining.clear();
        const int64_t days = std::max(1, _epoch_days.get());
        bool any = false;
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const EconomyProcurementState *state = procurement_state_for_slot(country);
            _era_procurement_line_offsets[static_cast<size_t>(country)] =
                static_cast<int32_t>(_era_procurement_remaining.size());
            if (state == nullptr || !state->policy_enabled || !state->era_active ||
                state->era_daily <= 0) continue;
            _era_procurement_handles[static_cast<size_t>(country)] = state->country_handle;
            _era_procurement_budgets[static_cast<size_t>(country)] = std::min(
                std::max<int64_t>(0, country_reads().cash_for_slot(country)),
                saturating_mul(state->era_daily, days, _saturation_count));
            for (const EraProcurementLine &line : state->era_goods) {
                const int64_t remaining = std::max<int64_t>(0,
                    line.required - country_reads().good_for_slot(country, line.good));
                _era_procurement_remaining.push_back(remaining);
                if (remaining > 0) any = true;
            }
        }
        _era_procurement_line_offsets[countries] =
            static_cast<int32_t>(_era_procurement_remaining.size());
        if (!any) {
            _era_procurement_done = true;
            return true;
        }
        const bool cell_market_shape = market_store().cell_to_market.size() ==
            static_cast<size_t>(_cell_count.get());
        for (const int32_t market : _epoch_market_ids) {
            if (market < 0 || market >= _cell_count.get() ||
                market >= static_cast<int32_t>(_epoch_cell_country.size()) ||
                !market_has_living_merchant(market)) continue;
            // One cell is one local market; the market id is its cell.
            if (cell_market_shape &&
                market_store().cell_to_market[static_cast<size_t>(market)] != market) continue;
            const int32_t country = _epoch_cell_country[static_cast<size_t>(market)];
            if (country < 0 || country >= _epoch_country_count ||
                _era_procurement_budgets[static_cast<size_t>(country)] <= 0) continue;
            const EconomyProcurementState *state = procurement_state_for_slot(country);
            if (state == nullptr) continue;
            const int32_t base = _era_procurement_line_offsets[static_cast<size_t>(country)];
            for (int32_t line = 0; line < static_cast<int32_t>(state->era_goods.size()); ++line) {
                if (_era_procurement_remaining[static_cast<size_t>(base + line)] <= 0) continue;
                const int32_t good = state->era_goods[static_cast<size_t>(line)].good;
                const size_t index = market_store().index(market, good);
                if (index >= market_store().stock.size() || market_store().stock[index] <= 0)
                    continue;
                _era_procurement_candidates.push_back({country, line, good, market,
                    market_store().price[index]});
            }
        }
        std::stable_sort(_era_procurement_candidates.begin(), _era_procurement_candidates.end(),
            [](const EraProcurementCandidate &a, const EraProcurementCandidate &b) {
                return std::tie(a.country, a.line, a.price, a.market) <
                    std::tie(b.country, b.line, b.price, b.market);
            });
    }

    EraProcurementContinuation &c = _era_procurement_continuation;
    const auto settle = [&]() {
        const size_t country = static_cast<size_t>(c.country);
        if (c.phase == 5) {
            const int32_t base = _era_procurement_line_offsets[country];
            int64_t &remaining = _era_procurement_remaining[static_cast<size_t>(base + c.line)];
            remaining = std::max<int64_t>(0, remaining - c.quantity);
            _era_procurement_budgets[country] =
                std::max<int64_t>(0, _era_procurement_budgets[country] - c.cash);
            const uint64_t handle = _era_procurement_handles[country];
            auto found = _country_procurement.find(handle);
            if (found != _country_procurement.end()) {
                for (EraProcurementLine &line : found->second.era_goods)
                    if (line.good == c.good)
                        line.purchased_total = saturating_add(line.purchased_total,
                            c.quantity, _saturation_count);
            }
            note_procurement_cash(handle, PROCUREMENT_CASH_ERA, c.cash);
            note_non_tax_outflow(handle, NON_TAX_ERA_PROCUREMENT, c.cash);
            // Non-household demand event, same channel as expedition cargo.
            const int32_t signal = ensure_market_signal_index(c.market, c.good);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())) {
                _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                    _epoch_nonhousehold_withdrawals[signal], c.quantity, _saturation_count);
                const int64_t daily = c.quantity / std::max(1, _epoch_days.get());
                _market_signals.business_demand_ema.write_scalar(signal, saturating_add(
                    _market_signals.business_demand_ema[signal], daily,
                    _saturation_count), market_mutation_sink());
                _market_signals.realized_withdrawal_ema.write_scalar(signal, saturating_add(
                    _market_signals.realized_withdrawal_ema[signal], daily,
                    _saturation_count), market_mutation_sink());
            }
            ++_era_procurement_orders;
        } else {
            ++_era_procurement_rejections;
        }
        ++_era_procurement_cursor;
        c = EraProcurementContinuation{};
    };

    if (c.active) {
        if (!advance_era_procurement(c, error)) return false;
        if (c.active) return true;
        settle();
        return true;
    }

    const size_t end = std::min(_era_procurement_candidates.size(),
                                _era_procurement_cursor + CANDIDATES_PER_SLICE);
    while (_era_procurement_cursor < end) {
        const EraProcurementCandidate candidate =
            _era_procurement_candidates[_era_procurement_cursor];
        const size_t country = static_cast<size_t>(candidate.country);
        const int32_t base = _era_procurement_line_offsets[country];
        const int64_t remaining = _era_procurement_remaining[static_cast<size_t>(base + candidate.line)];
        const int64_t budget = std::min(_era_procurement_budgets[country],
            std::max<int64_t>(0, country_reads().cash_for_slot(candidate.country)));
        const size_t index = market_store().index(candidate.market, candidate.good);
        const int64_t price = index < market_store().price.size()
            ? market_store().price[index] : 0;
        if (remaining <= 0 || budget <= 0 || price <= 0 ||
            index >= market_store().stock.size()) {
            ++_era_procurement_cursor;
            continue;
        }
        const int64_t quantity = std::min({market_store().stock[index], remaining,
            mul_div_sat(budget, GOODS_SCALE, price, _saturation_count)});
        const int64_t cash = quantity > 0 ? goods_cost(quantity, price, _saturation_count) : 0;
        if (quantity <= 0 || cash <= 0 || cash > budget) {
            ++_era_procurement_cursor;
            continue;
        }
        c = EraProcurementContinuation{};
        c.active = true;
        c.phase = 1;
        c.country = candidate.country;
        c.line = candidate.line;
        c.market = candidate.market;
        c.good = candidate.good;
        c.quantity = quantity;
        c.cash = cash;
        if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t edge = _merchant_offsets[candidate.market];
                 edge < _merchant_offsets[candidate.market + 1]; ++edge) {
                const int32_t slot = _merchant_slots[edge];
                if (is_merchant_slot(slot) && slot >= 0 &&
                    slot < static_cast<int32_t>(population_store().population.size()) &&
                    population_store().population[slot] > 0)
                    c.living_merchants.push_back(slot);
            }
        }
        for (const int32_t slot : c.living_merchants) {
            c.merchant_weights.push_back(population_store().population[slot]);
            c.merchant_population = saturating_add(c.merchant_population,
                population_store().population[slot], _saturation_count);
        }
        if (c.merchant_population <= 0) {
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        const uint64_t handle = _era_procurement_handles[country];
        const std::vector<int32_t> ids{candidate.good};
        const std::vector<int64_t> goods{quantity};
        std::string route_error;
        const CountryWorkerAssetRoute route = block_or_enqueue_country_worker_asset(
            static_cast<uint16_t>(CountryApi::ECONOMY_ASSET_GOOD_FROM_MARKET),
            static_cast<int64_t>(handle), cash, quantity, ids, goods, route_error,
            &c.pending_request_id, candidate.market);
        if (route == CountryWorkerAssetRoute::ENQUEUED_PENDING) {
            // Do NOT mark this request as self-settled (deferred). Deferral is
            // for continuations that settle outside the epoch (family
            // expedition preparation at the idle boundary). Inside the epoch a
            // deferred request keeps country_authority_drain_idle_locked()
            // false, so the Country worker never finishes the day that would
            // commit it, the generic flush never sweeps it, and the stage
            // parks on era_asset_peer_pending until the fiscal-peer stall
            // timeout. The research purchase in the same stage polls the
            // terminal instead, and so does this one (see phase 1).
            c.host_peer = true;
            return true; // parked until the Country worker prepares/commits
        }
        if (route != CountryWorkerAssetRoute::NOT_APPLICABLE) {
            c.last_error = route_error;
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        const auto port = country_api::procurement_port(*_country_runtime);
        const Dictionary begun = port.submit({port.next_order_key(),
            static_cast<int64_t>(handle), candidate.good, quantity, _epoch_id.get(),
            static_cast<int32_t>(_stage), cash});
        if (!static_cast<bool>(begun.get("ok", false))) {
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        c.transaction_id = static_cast<uint64_t>(static_cast<int64_t>(begun.get("transaction_id", 0)));
        c.session_epoch = static_cast<uint64_t>(static_cast<int64_t>(begun.get("session_epoch", 0)));
        c.country_generation = static_cast<uint64_t>(
            static_cast<int64_t>(begun.get("country_generation", 0)));
        c.peer_generation = _committed_generation;
        if (static_cast<int64_t>(begun.get("prepared_quantity", 0)) != quantity) {
            port.prepared(
                {c.transaction_id, c.session_epoch, c.country_generation,
                c.peer_generation}, false, "era_procurement_quantity_drift");
            c.phase = 6;
            c.active = false;
            settle();
            continue;
        }
        const Dictionary prepared = port.prepared(
            {c.transaction_id, c.session_epoch, c.country_generation,
            c.peer_generation}, true, "");
        if (!static_cast<bool>(prepared.get("ok", false))) {
            error = "era_procurement_peer_prepare_failed";
            return false;
        }
        const Dictionary committed = port.apply(c.transaction_id);
        if (!static_cast<bool>(committed.get("ok", false)) ||
            static_cast<int64_t>(committed.get("committed_quantity", 0)) != quantity ||
            static_cast<int64_t>(committed.get("committed_cash", cash)) != cash) {
            error = "era_procurement_peer_commit_failed";
            return false;
        }
        c.host_peer = false;
        c.market_applied = false;
        c.phase = 4;
        if (!advance_era_procurement(c, error)) return false;
        settle();
    }
    if (_era_procurement_cursor >= _era_procurement_candidates.size())
        _era_procurement_done = true;
    return true;
}
