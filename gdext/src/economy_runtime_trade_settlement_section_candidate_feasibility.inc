    for (const TradeCandidate &candidate : _trade_plan.ready_candidates) {
        const int32_t source_country = candidate.source_country >= 0
            ? candidate.source_country : candidate.country;
        const int32_t destination_country = candidate.destination_country >= 0
            ? candidate.destination_country : candidate.country;
        if (candidate.source < 0 || candidate.destination < 0 ||
            candidate.good < 0 || candidate.good >= market_store().good_count.get() ||
            source_country < 0 || source_country >= _epoch_country_count ||
            destination_country < 0 || destination_country >= _epoch_country_count ||
            candidate.topology_generation != _trade_topology.topology_generation ||
            candidate.source >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            candidate.destination >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            _epoch_cell_country[candidate.source] != source_country ||
            _epoch_cell_country[candidate.destination] != destination_country ||
            (candidate.source_country_handle != 0 &&
             _epoch_country_handles[static_cast<size_t>(source_country)] !=
                candidate.source_country_handle) ||
            (candidate.destination_country_handle != 0 &&
             _epoch_country_handles[static_cast<size_t>(destination_country)] !=
                candidate.destination_country_handle)) {
            ++_trade_rejected_route;
            if (candidate.destination >= 0 && candidate.good >= 0)
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_ROUTE);
            continue;
        }
        if (!trade_vision_allows_pair(candidate.source, candidate.destination)) {
            ++_trade_rejected_vision;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_ROUTE);
            continue;
        }
        if (candidate.source_price_stock_generation !=
                _cell_price_stock_gen[candidate.source] ||
            candidate.destination_price_stock_generation !=
                _cell_price_stock_gen[candidate.destination]) {
            ++_trade_candidates_stale_generation;
        }
        if ((candidate.expected_profit <= 0 &&
             (candidate.flags & TRADE_LINE_RELIEF) == 0) ||
            candidate.quantity <= 0) {
            ++_trade_rejected_profit;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        TradeCandidate clipped = candidate;
        const int64_t market_index = market_store().index(candidate.source, candidate.good);
        int64_t target_sat = 0;
        const int64_t local_stock_target = trade_export_floor(
            candidate.source, candidate.good, target_sat);
        _saturation_count = saturating_add(
            _saturation_count, target_sat, _saturation_count);
        const uint64_t source_key = (static_cast<uint64_t>(
            static_cast<uint32_t>(candidate.source)) << 32) |
            static_cast<uint32_t>(candidate.good);
        auto source_it = source_remaining.find(source_key);
        if (source_it == source_remaining.end()) {
            source_it = source_remaining.emplace(source_key, std::max<int64_t>(
                0, market_store().stock[market_index] - local_stock_target)).first;
        }
        int64_t reserved_stock = 0;
        clipped.quantity = std::min(clipped.quantity,
            std::max<int64_t>(0, source_it->second));
        const uint64_t destination_key = (static_cast<uint64_t>(
            static_cast<uint32_t>(candidate.destination)) << 32) |
            static_cast<uint32_t>(candidate.good);
        auto destination_it = destination_remaining.find(destination_key);
        if (destination_it == destination_remaining.end()) {
            int64_t destination_sat = 0;
            const int64_t target = trade_local_stock_target(
                candidate.destination, candidate.good, destination_sat);
            int64_t inbound = 0;
            for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
                if (trade_orders_store().destinations[order] != candidate.destination) continue;
                for (int32_t line = trade_orders_store().line_offsets[order];
                     line < trade_orders_store().line_offsets[order + 1]; ++line) {
                    if (trade_orders_store().line_goods[line] == candidate.good)
                        inbound = saturating_add(inbound,
                            trade_orders_store().line_quantities[line], destination_sat);
                }
            }
            const int64_t destination_stock = market_store().stock[market_store().index(
                candidate.destination, candidate.good)];
            destination_it = destination_remaining.emplace(destination_key,
                std::max<int64_t>(0, target - destination_stock - inbound)).first;
            _saturation_count = saturating_add(
                _saturation_count, destination_sat, _saturation_count);
        }
        clipped.quantity = std::min(clipped.quantity,
                                    std::max<int64_t>(0, destination_it->second));
        int64_t sat = 0;
        const int64_t unit_work = saturating_mul(
            _good_transport_load_per_unit_q16[candidate.good],
            candidate.route_cost, sat);
        if (clipped.quantity <= 0) {
            if (source_it->second <= 0 || destination_it->second <= 0) {
                ++_trade_candidates_arbitrated_out;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_ARBITRATED_OUT);
            } else {
                ++_trade_rejected_capacity;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CAPACITY);
            }
            continue;
        }
        const int64_t destination_index = market_store().index(
            candidate.destination, candidate.good);
        clipped.source_price = estimate_trade_price(candidate.source, candidate.good,
            market_store().stock[market_index] - clipped.quantity, sat);
        clipped.destination_price = estimate_trade_price(
            candidate.destination, candidate.good,
            market_store().stock[destination_index] + clipped.quantity, sat);
        auto destination_cash_it = destination_trade_cash_remaining.find(
            candidate.destination);
        if (destination_cash_it == destination_trade_cash_remaining.end()) {
            int64_t merchant_cash = 0;
            for (int32_t k = _merchant_offsets[candidate.destination];
                 k < _merchant_offsets[candidate.destination + 1]; ++k) {
                merchant_cash = saturating_add(merchant_cash,
                    std::max<int64_t>(0,
                        population_store().funds[_merchant_slots[k]]), sat);
            }
            int64_t existing_order_reserved_cash = 0;
            for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
                if (trade_orders_store().destinations[order] ==
                        candidate.destination) {
                    existing_order_reserved_cash = saturating_add(
                        existing_order_reserved_cash,
                        std::max<int64_t>(0,
                            trade_orders_store().cash_escrow[order]), sat);
                }
            }
            const int64_t operating_floor = mul_div_sat(
                merchant_cash, _merchant_procurement_cash_reserve_q16.get(),
                Q16_ONE, sat);
            destination_cash_it = destination_trade_cash_remaining.emplace(
                candidate.destination, std::max<int64_t>(0,
                    merchant_cash -
                    std::min(merchant_cash, existing_order_reserved_cash) -
                    std::min(merchant_cash, operating_floor))).first;
        }
        const int64_t available_cash = std::max<int64_t>(
            0, destination_cash_it->second);
        const int64_t relief_q16 = trade_relief_pressure_q16(
            candidate.destination, candidate.good, sat);
        const bool relief_route = relief_q16 >= Q16_ONE / 8;
        const auto quote_is_viable = [&](const TradeQuote &quote) {
            const bool merchant_cash_safe = quote.importer_outlay >= 0 &&
                quote.importer_profit >= 0 && quote.exporter_receipt > 0;
            const bool route_profit_safe = relief_route
                ? quote.combined_profit >= 0
                : quote.combined_profit > 0 &&
                    quote.margin_q16 >= _trade_min_margin_q16.get();
            return merchant_cash_safe && route_profit_safe;
        };
        const int64_t before_profit_clip = clipped.quantity;
        int64_t margin_q16 = 0;
        clipped.quantity = profitable_trade_quantity(
            candidate.source, candidate.destination, candidate.good,
            clipped.quantity, relief_route, clipped.source_price,
            clipped.destination_price, clipped.expected_profit,
            margin_q16, sat);
        if (clipped.quantity <= 0) {
            ++_trade_rejected_profit;
            ++_trade_rejected_margin;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        if (clipped.quantity < before_profit_clip) ++_trade_quantity_profit_clips;
        auto quote_for_quantity = [&](int64_t quantity, TradeQuote &quote,
                                      int64_t &total_work,
                                      int64_t &source_work,
                                      int64_t &destination_work) {
            const int32_t quoted_source = estimate_trade_price(
                candidate.source, candidate.good,
                market_store().stock[market_index] - quantity, sat);
            const int32_t quoted_destination = estimate_trade_price(
                candidate.destination, candidate.good,
                market_store().stock[destination_index] + quantity, sat);
            quote = make_trade_quote(candidate.source, candidate.destination,
                candidate.good, quantity, quoted_source, quoted_destination,
                relief_route, sat);
            total_work = mul_div_sat(quantity, unit_work, GOODS_SCALE, sat);
            if (quote.foreign) {
                source_work = total_work / 2;
                destination_work = total_work - source_work;
            } else {
                source_work = total_work;
                destination_work = 0;
            }
        };
        int64_t low = 1;
        int64_t high = clipped.quantity;
        int64_t best_quantity = 0;
        TradeQuote best_quote;
        int64_t best_total_work = 0;
        int64_t best_source_work = 0;
        int64_t best_destination_work = 0;
        while (low <= high) {
            const int64_t mid = low + (high - low) / 2;
            TradeQuote quote;
            int64_t total_work = 0;
            int64_t source_work = 0;
            int64_t destination_work = 0;
            quote_for_quantity(mid, quote, total_work, source_work,
                               destination_work);
            const bool capacity_ok = total_work > 0 &&
                source_work <= country_capacity[static_cast<size_t>(source_country)] &&
                destination_work <= country_capacity[
                    static_cast<size_t>(destination_country)];
            const bool cash_ok = quote.importer_outlay >= 0 &&
                quote.importer_outlay <= available_cash;
            const bool subsidy_ok =
                -std::min<int64_t>(0, quote.export_transfer) <=
                    tariff_remaining(source_country, 1) &&
                -std::min<int64_t>(0, quote.import_transfer) <=
                    tariff_remaining(destination_country, 0);
            if (capacity_ok && cash_ok && subsidy_ok) {
                best_quantity = mid;
                best_quote = quote;
                best_total_work = total_work;
                best_source_work = source_work;
                best_destination_work = destination_work;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }
        if (best_quantity > 0 && !quote_is_viable(best_quote)) {
            best_quantity = 0;
            best_total_work = 0;
            best_source_work = 0;
            best_destination_work = 0;
        }
        if (best_quantity <= 0) {
            TradeQuote unit_quote;
            int64_t unit_total_work = 0;
            int64_t unit_source_work = 0;
            int64_t unit_destination_work = 0;
            quote_for_quantity(1, unit_quote, unit_total_work,
                               unit_source_work, unit_destination_work);
            TradeQuote nominal_quote;
            int64_t nominal_total_work = 0;
            int64_t nominal_source_work = 0;
            int64_t nominal_destination_work = 0;
            quote_for_quantity(clipped.quantity, nominal_quote,
                               nominal_total_work, nominal_source_work,
                               nominal_destination_work);
            const bool subsidy_blocked =
                -std::min<int64_t>(0, nominal_quote.export_transfer) >
                    tariff_remaining(source_country, 1) ||
                -std::min<int64_t>(0, nominal_quote.import_transfer) >
                    tariff_remaining(destination_country, 0);
            if (subsidy_blocked && _trade_runtime_mode.get() == 2) {
                // An intent is a bounded next-batch request only. It must not
                // change stock, merchant cash, actual tariff events, or the
                // current fiscal base. Its resource arbitration is shadow-only
                // and follows the same stable candidate order as real dispatch.
                const uint64_t source_key = (static_cast<uint64_t>(
                    static_cast<uint32_t>(candidate.source)) << 32) |
                    static_cast<uint32_t>(candidate.good);
                const uint64_t destination_key = (static_cast<uint64_t>(
                    static_cast<uint32_t>(candidate.destination)) << 32) |
                    static_cast<uint32_t>(candidate.good);
                auto intent_source_it = intent_source_remaining.find(source_key);
                if (intent_source_it == intent_source_remaining.end())
                    intent_source_it = intent_source_remaining.emplace(
                        source_key, source_it->second).first;
                auto intent_destination_it = intent_destination_remaining.find(
                    destination_key);
                if (intent_destination_it == intent_destination_remaining.end())
                    intent_destination_it = intent_destination_remaining.emplace(
                        destination_key, destination_it->second).first;
                auto intent_cash_it = intent_destination_cash_remaining.find(
                    candidate.destination);
                if (intent_cash_it == intent_destination_cash_remaining.end())
                    intent_cash_it = intent_destination_cash_remaining.emplace(
                        candidate.destination, available_cash).first;
                int64_t intent_quantity = 0;
                TradeQuote intent_quote;
                int64_t intent_source_work = 0;
                int64_t intent_destination_work = 0;
                int64_t intent_low = 1;
                int64_t intent_high = std::min(clipped.quantity,
                    std::min(intent_source_it->second,
                        intent_destination_it->second));
                while (intent_low <= intent_high) {
                    const int64_t mid = intent_low +
                        (intent_high - intent_low) / 2;
                    TradeQuote quote;
                    int64_t total_work = 0;
                    int64_t source_work = 0;
                    int64_t destination_work = 0;
                    quote_for_quantity(mid, quote, total_work, source_work,
                        destination_work);
                    const bool capacity_ok = total_work > 0 &&
                        source_work <= intent_country_capacity[
                            static_cast<size_t>(source_country)] &&
                        destination_work <= intent_country_capacity[
                            static_cast<size_t>(destination_country)];
                    const bool cash_ok = quote.importer_outlay >= 0 &&
                        quote.importer_outlay <= intent_cash_it->second;
                    if (capacity_ok && cash_ok) {
                        intent_quantity = mid;
                        intent_quote = quote;
                        intent_source_work = source_work;
                        intent_destination_work = destination_work;
                        intent_low = mid + 1;
                    } else {
                        intent_high = mid - 1;
                    }
                }
                if (intent_quantity > 0 && !quote_is_viable(intent_quote))
                    intent_quantity = 0;
                const int64_t import_request = intent_quantity > 0
                    ? -std::min<int64_t>(0, intent_quote.import_transfer) : 0;
                const int64_t export_request = intent_quantity > 0
                    ? -std::min<int64_t>(0, intent_quote.export_transfer) : 0;
                if (import_request > 0) {
                    const int32_t lane = tariff_epoch_lane_index(
                        candidate.destination, 0, true);
                    if (lane < 0) {
                        error = "tariff_intent_lane_allocate_failed";
                        return false;
                    }
                    _tariff_epoch_requests[lane] = saturating_add(
                        _tariff_epoch_requests[lane], import_request, sat);
                    const int32_t row = ensure_tariff_history(
                        destination_country, CountryApi::TAX_IMPORT);
                    _tariff_history.requests.write_scalar(row, saturating_add(
                        _tariff_history.requests[row], import_request, sat), market_mutation_sink());
                }
                if (export_request > 0) {
                    const int32_t lane = tariff_epoch_lane_index(
                        candidate.source, 1, true);
                    if (lane < 0) {
                        error = "tariff_intent_lane_allocate_failed";
                        return false;
                    }
                    _tariff_epoch_requests[lane] = saturating_add(
                        _tariff_epoch_requests[lane], export_request, sat);
                    const int32_t row = ensure_tariff_history(
                        source_country, CountryApi::TAX_EXPORT);
                    _tariff_history.requests.write_scalar(row, saturating_add(
                        _tariff_history.requests[row], export_request, sat), market_mutation_sink());
                }
                if (intent_quantity > 0 && (import_request > 0 || export_request > 0)) {
                    intent_source_it->second = std::max<int64_t>(0,
                        intent_source_it->second - intent_quantity);
                    intent_destination_it->second = std::max<int64_t>(0,
                        intent_destination_it->second - intent_quantity);
                    intent_country_capacity[static_cast<size_t>(source_country)] =
                        std::max<int64_t>(0,
                            intent_country_capacity[static_cast<size_t>(source_country)] -
                            intent_source_work);
                    intent_country_capacity[static_cast<size_t>(destination_country)] =
                        std::max<int64_t>(0,
                            intent_country_capacity[static_cast<size_t>(destination_country)] -
                            intent_destination_work);
                    intent_cash_it->second = std::max<int64_t>(0,
                        intent_cash_it->second - intent_quote.importer_outlay);
                    CommittedGameplayFact fact;
                    fact.kind = GAMEPLAY_FACT_TARIFF_SUBSIDY_INTENT;
                    fact.cell = candidate.destination;
                    fact.entity_id = -1;
                    fact.value = saturating_add(import_request, export_request, sat);
                    fact.payload = {candidate.source, source_country,
                                    destination_country, candidate.good};
                    fact.flags = TRADE_LINE_FOREIGN |
                        (intent_quote.import_transfer < 0
                            ? TRADE_LINE_IMPORT_SUBSIDY : 0) |
                        (intent_quote.export_transfer < 0
                            ? TRADE_LINE_EXPORT_SUBSIDY : 0);
                    _staging_gameplay_facts.push_back(fact);
                    if (static_cast<int32_t>(
                            _trade_plan.deferred_subsidy_candidates.size()) <
                            _trade_max_candidates.get()) {
                        _trade_plan.deferred_subsidy_candidates.push_back(candidate);
                    }
                    std::vector<EventLeg> intent_legs;
                    if (trace_detail_for_cell(candidate.source) ||
                        trace_detail_for_cell(candidate.destination)) {
                        intent_legs.push_back({FIELD_TRADE_BASE_VALUE,
                            SUBJECT_MARKET, candidate.destination, candidate.good,
                            0, intent_quote.base});
                        intent_legs.push_back({FIELD_TRADE_IMPORT_TRANSFER,
                            SUBJECT_MARKET, candidate.destination, candidate.good,
                            0, intent_quote.import_transfer});
                        intent_legs.push_back({FIELD_TRADE_EXPORT_TRANSFER,
                            SUBJECT_MARKET, candidate.source, candidate.good,
                            0, intent_quote.export_transfer});
                    }
                    trace_append(EVENT_TARIFF_SUBSIDY_INTENT,
                        static_cast<int32_t>(Stage::TRADE_DISPATCH),
                        candidate.destination, SUBJECT_MARKET,
                        candidate.destination, candidate.source,
                        candidate.destination, intent_quantity, intent_quote.base,
                        fact.value, 0,
                        intent_legs.empty() ? nullptr : &intent_legs,
                        static_cast<int32_t>(fact.flags) << 8);
                }
            }
            if (available_cash < unit_quote.importer_outlay) {
                ++_trade_rejected_cash;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CASH);
            } else {
                ++_trade_rejected_capacity;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CAPACITY);
            }
            continue;
        }
        clipped.quantity = best_quantity;
        clipped.source_price = best_quote.source_price;
        clipped.destination_price = best_quote.destination_price;
        clipped.expected_profit = best_quote.combined_profit;
        clipped.base_value = best_quote.base;
        clipped.retail_value = best_quote.retail;
        clipped.import_transfer = best_quote.import_transfer;
        clipped.export_transfer = best_quote.export_transfer;
        clipped.transaction_transfer = best_quote.transaction_transfer;
        clipped.capacity_work = best_total_work;
        clipped.flags = best_quote.foreign ? TRADE_LINE_FOREIGN : 0;
        if (relief_route) clipped.flags |= TRADE_LINE_RELIEF;
        if (best_quote.import_transfer < 0)
            clipped.flags |= TRADE_LINE_IMPORT_SUBSIDY;
        else if (best_quote.import_transfer > 0)
            clipped.flags |= TRADE_LINE_IMPORT_TAX;
        if (best_quote.export_transfer < 0)
            clipped.flags |= TRADE_LINE_EXPORT_SUBSIDY;
        else if (best_quote.export_transfer > 0)
            clipped.flags |= TRADE_LINE_EXPORT_TAX;
        int64_t density_profit = best_quote.combined_profit;
        if (relief_route && density_profit <= 0) {
            density_profit = std::max<int64_t>(1, mul_div_sat(
                best_quote.base, std::max<int64_t>(1, relief_q16),
                Q16_ONE, sat));
        }
        clipped.density_q16 = mul_div_sat(
            density_profit, Q16_ONE, clipped.capacity_work, sat);
        const int64_t purchase_cash = best_quote.importer_outlay;
        if (market_store().stock[market_index] - local_stock_target - reserved_stock <
                clipped.quantity) {
            ++_trade_rejected_stock;
            ++_trade_true_source_stock_failures;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_STOCK);
            continue;
        }
        if (_trade_runtime_mode.get() == 2 &&
            trade_orders_store().size() + static_cast<int32_t>(accepted.size()) >=
                _trade_max_orders.get()) {
            ++_trade_rejected_order_cap;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_ORDER_CAP);
            break;
        }
        const int64_t import_subsidy = -std::min<int64_t>(
            0, clipped.import_transfer);
        const int64_t export_subsidy = -std::min<int64_t>(
            0, clipped.export_transfer);
        if (_trade_runtime_mode.get() == 2 && (import_subsidy > 0 || export_subsidy > 0)) {
            // prepare_fiscal_budgets already reserved the combined country
            // escrow. Dispatch only consumes its frozen epoch remainder.
            const size_t import_budget = static_cast<size_t>(destination_country) * 2U;
            const size_t export_budget = static_cast<size_t>(source_country) * 2U + 1U;
            if (import_subsidy > 0 && import_budget < _tariff_country_remaining.size()) {
                _tariff_country_remaining[import_budget] = std::max<int64_t>(0,
                    _tariff_country_remaining[import_budget] - import_subsidy);
            }
            if (export_subsidy > 0 && export_budget < _tariff_country_remaining.size()) {
                _tariff_country_remaining[export_budget] = std::max<int64_t>(0,
                    _tariff_country_remaining[export_budget] - export_subsidy);
            }
        }
        country_capacity[static_cast<size_t>(source_country)] -=
            best_source_work;
        country_capacity[static_cast<size_t>(destination_country)] -=
            best_destination_work;
        intent_country_capacity[static_cast<size_t>(source_country)] =
            std::max<int64_t>(0,
                intent_country_capacity[static_cast<size_t>(source_country)] -
                best_source_work);
        intent_country_capacity[static_cast<size_t>(destination_country)] =
            std::max<int64_t>(0,
                intent_country_capacity[static_cast<size_t>(destination_country)] -
                best_destination_work);
        source_it->second = std::max<int64_t>(0,
            source_it->second - clipped.quantity);
        destination_it->second = std::max<int64_t>(0,
            destination_it->second - clipped.quantity);
        if (auto intent_it = intent_source_remaining.find(source_key);
            intent_it != intent_source_remaining.end()) {
            intent_it->second = std::max<int64_t>(0,
                intent_it->second - clipped.quantity);
        }
        if (auto intent_it = intent_destination_remaining.find(destination_key);
            intent_it != intent_destination_remaining.end()) {
            intent_it->second = std::max<int64_t>(0,
                intent_it->second - clipped.quantity);
        }
        _trade_capacity_used = saturating_add(_trade_capacity_used,
            clipped.capacity_work, _saturation_count);
        ++_trade_candidates_accepted;
        destination_cash_it->second = std::max<int64_t>(
            0, destination_cash_it->second - purchase_cash);
        if (auto intent_it = intent_destination_cash_remaining.find(
                candidate.destination);
            intent_it != intent_destination_cash_remaining.end()) {
            intent_it->second = std::max<int64_t>(0,
                intent_it->second - purchase_cash);
        }
        if (_trade_runtime_mode.get() == 1) {
            accepted.push_back(clipped);
            continue;
        }
        const int64_t import_tax = std::max<int64_t>(
            0, clipped.import_transfer);
        const int32_t tx_rate = frozen_tax_rate(candidate.destination,
            CountryApi::TAX_TRANSACTION, candidate.good);
        const int32_t tx_mode = frozen_tax_mode(candidate.destination,
            CountryApi::TAX_TRANSACTION, candidate.good);
        const int64_t tx_base =
            tx_mode == CountryApi::TAX_MODE_ABSOLUTE
                ? std::max<int64_t>(0, clipped.quantity)
                : clipped.base_value;
        const int64_t transaction_tax = apply_fiscal_tax(
            candidate.destination, CountryApi::TAX_TRANSACTION,
            tx_base, std::max<int32_t>(0, tx_rate), tx_mode,
            _saturation_count);
        // The merchant pays the base purchase. A positive import transfer is
        // an additional tax expense; a negative transfer is credited from the
        // escrow before the base debit so a subsidy can unlock a cash-poor
        // importer without creating money outside the country treasury.
        if (import_subsidy > 0) {
            credit_local_merchants(candidate.destination, import_subsidy,
                CASHFLOW_IMPORT_SUBSIDY);
        }
        const int64_t debited_base = debit_local_merchants(
            candidate.destination, clipped.base_value,
            CASHFLOW_MERCHANT_PROCUREMENT);
        const int64_t debited_tax = import_tax > 0
            ? debit_local_merchants(candidate.destination, import_tax,
                CASHFLOW_IMPORT_TAX) : 0;
        const int64_t debited_transaction = transaction_tax > 0
            ? debit_local_merchants(candidate.destination, transaction_tax,
                CASHFLOW_CONSUMPTION_TAX) : 0;
        const int64_t debited = saturating_add(
            saturating_add(debited_base, debited_tax, _saturation_count),
            debited_transaction, _saturation_count);
        const int64_t expected_debit = saturating_add(
            saturating_add(clipped.base_value, import_tax,
                           _saturation_count),
            std::max<int64_t>(0, clipped.transaction_transfer),
            _saturation_count);
        if (debited != expected_debit) {
            if (import_subsidy > 0) {
                const size_t budget = static_cast<size_t>(destination_country) * 2U;
                if (budget < _tariff_country_remaining.size())
                    _tariff_country_remaining[budget] = saturating_add(
                        _tariff_country_remaining[budget], import_subsidy,
                        _saturation_count);
            }
            if (export_subsidy > 0) {
                const size_t budget = static_cast<size_t>(source_country) * 2U + 1U;
                if (budget < _tariff_country_remaining.size())
                    _tariff_country_remaining[budget] = saturating_add(
                        _tariff_country_remaining[budget], export_subsidy,
                        _saturation_count);
            }
            error = "trade_cash_reservation_failed";
            return false;
        }
        _merchant_trade_purchase_cash = saturating_add(
            _merchant_trade_purchase_cash, purchase_cash,
            _saturation_count);
        if (candidate.destination >= 0 &&
            candidate.destination < static_cast<int32_t>(
                _merchant_trade_purchase_by_cell.size())) {
            _merchant_trade_purchase_by_cell[candidate.destination] =
                saturating_add(
                    _merchant_trade_purchase_by_cell[candidate.destination],
                    purchase_cash, _saturation_count);
        }
        audit_touch_market_lane(static_cast<size_t>(market_index));
        market_store().stock.write_scalar(market_index, market_store().stock[market_index] - (clipped.quantity), market_mutation_sink());
        // Household settlement already contributed its closing totals. Move the
        // dispatched value from those local totals into trade escrow/transit so
        // the later conservation audit counts it exactly once.
        _publish_accum.goods_stock = saturating_sub(
            _publish_accum.goods_stock, clipped.quantity, _saturation_count);
        _publish_accum.cohort_funds = saturating_sub(
            _publish_accum.cohort_funds, purchase_cash, _saturation_count);
        if ((clipped.flags & TRADE_LINE_FOREIGN) != 0) {
            const int32_t import_lane = tariff_epoch_lane_index(
                candidate.destination, 0, true);
            const int32_t export_lane = tariff_epoch_lane_index(
                candidate.source, 1, true);
            if (import_lane < 0 || export_lane < 0) {
                error = "tariff_epoch_lane_allocate_failed";
                return false;
            }
            for (const int32_t lane : {import_lane, export_lane}) {
                _tariff_epoch_bases[lane] = saturating_add(
                    _tariff_epoch_bases[lane], clipped.base_value,
                    _saturation_count);
                _tariff_epoch_events[lane] = saturating_add(
                    _tariff_epoch_events[lane], 1, _saturation_count);
            }
            const auto record_transfer = [&](int32_t lane, int64_t transfer) {
                if (transfer > 0) {
                    _tariff_epoch_assessed[lane] = saturating_add(
                        _tariff_epoch_assessed[lane], transfer,
                        _saturation_count);
                    _tariff_epoch_collected[lane] = saturating_add(
                        _tariff_epoch_collected[lane], transfer,
                        _saturation_count);
                } else if (transfer < 0) {
                    const int64_t subsidy = -transfer;
                    _tariff_epoch_requests[lane] = saturating_add(
                        _tariff_epoch_requests[lane], subsidy,
                        _saturation_count);
                    _tariff_epoch_reserved[lane] = saturating_add(
                        _tariff_epoch_reserved[lane], subsidy,
                        _saturation_count);
                    _tariff_epoch_paid[lane] = saturating_add(
                        _tariff_epoch_paid[lane], subsidy,
                        _saturation_count);
                }
            };
            record_transfer(import_lane, clipped.import_transfer);
            record_transfer(export_lane, clipped.export_transfer);
            const int32_t import_good = ensure_country_good(
                destination_country, candidate.good);
            const int32_t export_good = ensure_country_good(
                source_country, candidate.good);
            begin_country_good_batch(import_good);
            begin_country_good_batch(export_good);
            _country_good_trade.import_quantity.write_scalar(import_good, saturating_add(
                _country_good_trade.import_quantity[import_good], clipped.quantity,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_import_quantity.write_scalar(import_good, saturating_add(
                _country_good_trade.batch_import_quantity[import_good],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_good_trade.import_base.write_scalar(import_good, saturating_add(
                _country_good_trade.import_base[import_good], clipped.base_value,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_import_base.write_scalar(import_good, saturating_add(
                _country_good_trade.batch_import_base[import_good],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_good_trade.import_tariff.write_scalar(import_good, saturating_add(
                _country_good_trade.import_tariff[import_good],
                clipped.import_transfer, _saturation_count), market_mutation_sink());
            _country_good_trade.batch_import_tariff.write_scalar(import_good, saturating_add(
                _country_good_trade.batch_import_tariff[import_good],
                clipped.import_transfer, _saturation_count), market_mutation_sink());
            _country_good_trade.export_quantity.write_scalar(export_good, saturating_add(
                _country_good_trade.export_quantity[export_good], clipped.quantity,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_export_quantity.write_scalar(export_good, saturating_add(
                _country_good_trade.batch_export_quantity[export_good],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_good_trade.export_base.write_scalar(export_good, saturating_add(
                _country_good_trade.export_base[export_good], clipped.base_value,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_export_base.write_scalar(export_good, saturating_add(
                _country_good_trade.batch_export_base[export_good],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_good_trade.export_tariff.write_scalar(export_good, saturating_add(
                _country_good_trade.export_tariff[export_good],
                clipped.export_transfer, _saturation_count), market_mutation_sink());
            _country_good_trade.batch_export_tariff.write_scalar(export_good, saturating_add(
                _country_good_trade.batch_export_tariff[export_good],
                clipped.export_transfer, _saturation_count), market_mutation_sink());
            const int32_t importer_partner = ensure_country_partner(
                destination_country, source_country);
            const int32_t exporter_partner = ensure_country_partner(
                source_country, destination_country);
            begin_country_partner_batch(importer_partner);
            begin_country_partner_batch(exporter_partner);
            _country_partner_trade.import_quantity.write_scalar(importer_partner, saturating_add(
                _country_partner_trade.import_quantity[importer_partner],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_import_quantity.write_scalar(importer_partner, saturating_add(_country_partner_trade.batch_import_quantity[
                    importer_partner], clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.import_base.write_scalar(importer_partner, saturating_add(
                _country_partner_trade.import_base[importer_partner],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_import_base.write_scalar(importer_partner, saturating_add(_country_partner_trade.batch_import_base[
                    importer_partner], clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.order_count.write_scalar(importer_partner, saturating_add(
                _country_partner_trade.order_count[importer_partner], 1,
                _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_order_count.write_scalar(importer_partner, saturating_add(_country_partner_trade.batch_order_count[
                    importer_partner], 1, _saturation_count), market_mutation_sink());
            _country_partner_trade.export_quantity.write_scalar(exporter_partner, saturating_add(
                _country_partner_trade.export_quantity[exporter_partner],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_export_quantity.write_scalar(exporter_partner, saturating_add(_country_partner_trade.batch_export_quantity[
                    exporter_partner], clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.export_base.write_scalar(exporter_partner, saturating_add(
                _country_partner_trade.export_base[exporter_partner],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_export_base.write_scalar(exporter_partner, saturating_add(_country_partner_trade.batch_export_base[
                    exporter_partner], clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.order_count.write_scalar(exporter_partner, saturating_add(
                _country_partner_trade.order_count[exporter_partner], 1,
                _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_order_count.write_scalar(exporter_partner, saturating_add(_country_partner_trade.batch_order_count[
                    exporter_partner], 1, _saturation_count), market_mutation_sink());
            const auto update_tariff_history = [&](int32_t country, int32_t kind,
                                                    int64_t transfer) {
                const int32_t row = ensure_tariff_history(country, kind);
                _tariff_history.bases.write_scalar(row, saturating_add(
                    _tariff_history.bases[row], clipped.base_value,
                    _saturation_count), market_mutation_sink());
                if (transfer > 0) {
                    _tariff_history.assessed.write_scalar(row, saturating_add(
                        _tariff_history.assessed[row], transfer, _saturation_count), market_mutation_sink());
                    _tariff_history.collected.write_scalar(row, saturating_add(
                        _tariff_history.collected[row], transfer, _saturation_count), market_mutation_sink());
                } else if (transfer < 0) {
                    const int64_t subsidy = -transfer;
                    _tariff_history.requests.write_scalar(row, saturating_add(
                        _tariff_history.requests[row], subsidy, _saturation_count), market_mutation_sink());
                    _tariff_history.reserved.write_scalar(row, saturating_add(
                        _tariff_history.reserved[row], subsidy, _saturation_count), market_mutation_sink());
                    _tariff_history.paid.write_scalar(row, saturating_add(
                        _tariff_history.paid[row], subsidy, _saturation_count), market_mutation_sink());
                }
            };
            update_tariff_history(destination_country,
                CountryApi::TAX_IMPORT, clipped.import_transfer);
            update_tariff_history(source_country,
                CountryApi::TAX_EXPORT, clipped.export_transfer);
        }
        merchant_funds_touched.push_back(candidate.destination);
        accepted.push_back(clipped);
        record_trade_signal_attempt(candidate.destination, candidate.good,
            TRADE_SIGNAL_DIAG_DISPATCHED);
        const int32_t destination_signal = trade_signal_clock_index(
            candidate.destination, candidate.good);
        if (_trade_runtime_mode.get() == 2 && destination_signal >= 0 &&
            destination_signal < static_cast<int32_t>(_trade_signal_first_seen_day.size()) &&
            destination_signal < static_cast<int32_t>(_trade_signal_first_dispatch_day.size()) &&
            _trade_signal_first_seen_day[destination_signal] >= 0 &&
            _trade_signal_first_dispatch_day[destination_signal] < 0) {
            _trade_signal_first_dispatch_day[destination_signal] = _sample_day;
            _trade_first_dispatch_delay_max_days = std::max<int64_t>(
                _trade_first_dispatch_delay_max_days,
                std::max<int64_t>(0, _sample_day -
                    _trade_signal_first_seen_day[destination_signal]));
            ++_trade_deficit_episodes_resolved;
            _trade_signal_first_seen_day[destination_signal] = -1;
            _trade_signal_first_dispatch_day[destination_signal] = -1;
            _trade_signal_deadline_reported[destination_signal] = 0;
        }
        const int32_t flow = trade_flow_index(candidate.source, candidate.good, true);
        if (flow >= 0) _trade_flows.period_export.write_scalar(flow, saturating_add(
            _trade_flows.period_export[flow], clipped.quantity, _saturation_count), market_mutation_sink());
    }
