    if (_save.section == SAVE_SECTION_SIGNALS) {
        constexpr int32_t record_bytes = 68;
        constexpr int32_t observation_sizes_bytes = 4 * sizeof(uint32_t);
        const int32_t max_records = std::max(1,
            (budget - 16 - observation_sizes_bytes) / record_bytes);
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_market_signals.good_ids.size()),
            _save.signal_cursor + max_records);
        const int32_t begin = _save.signal_cursor;
        int32_t cell = 0;
        while (cell + 1 < static_cast<int32_t>(_market_signals.cell_offsets.size()) &&
               _market_signals.cell_offsets[cell + 1] <= begin) ++cell;
        for (; _save.signal_cursor < end; ++_save.signal_cursor) {
            while (cell + 1 < static_cast<int32_t>(_market_signals.cell_offsets.size()) &&
                   _market_signals.cell_offsets[cell + 1] <= _save.signal_cursor) ++cell;
            append_le<int32_t>(payload, cell);
            append_le<int32_t>(payload, _market_signals.good_ids[_save.signal_cursor]);
            append_le<int64_t>(payload,
                               _market_signals.business_demand_ema[_save.signal_cursor]);
            append_le<int64_t>(payload,
                               _market_signals.offered_supply_ema[_save.signal_cursor]);
            append_le<int64_t>(payload,
                               _market_signals.realized_withdrawal_ema[_save.signal_cursor]);
            append_le<int32_t>(payload,
                               _market_signals.cost_anchor_price[_save.signal_cursor]);
            const auto append_observation = [&](const std::vector<int64_t> &values) {
                append_le<int64_t>(payload,
                    static_cast<size_t>(_save.signal_cursor) < values.size()
                        ? values[_save.signal_cursor] : 0);
            };
            append_observation(_epoch_producer_sellable_current);
            append_observation(_epoch_producer_merchant_sold_current);
            append_observation(_epoch_previous_producer_sellable);
            append_observation(_epoch_previous_producer_merchant_sold);
        }
        if (_save.signal_cursor >= static_cast<int32_t>(_market_signals.good_ids.size())) {
            // The market topology can grow after these observations were
            // sampled. Padding on the wire must not make an old sample look
            // aligned with the new topology at the next epoch's opening.
            const size_t count = _market_signals.good_ids.size();
            const std::array<size_t, 4> sizes{
                _epoch_producer_sellable_current.size(),
                _epoch_producer_merchant_sold_current.size(),
                _epoch_previous_producer_sellable.size(),
                _epoch_previous_producer_merchant_sold.size()};
            if (std::any_of(sizes.begin(), sizes.end(),
                    [count](size_t size) { return size < count; })) {
                for (const size_t size : sizes)
                    append_le<uint32_t>(payload, static_cast<uint32_t>(std::min(size, count)));
            }
            ++_save.section;
        }
        return make_save_chunk(SAVE_SECTION_SIGNALS,
                               static_cast<uint32_t>(_save.signal_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_LABOR_SIGNALS) {
        constexpr int32_t record_bytes = 52;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_labor_signals.profession_ids.size()),
            _save.labor_signal_cursor + max_records);
        const int32_t begin = _save.labor_signal_cursor;
        int32_t cell = 0;
        while (cell + 1 < static_cast<int32_t>(_labor_signals.cell_offsets.size()) &&
               _labor_signals.cell_offsets[cell + 1] <= begin) ++cell;
        for (; _save.labor_signal_cursor < end; ++_save.labor_signal_cursor) {
            while (cell + 1 < static_cast<int32_t>(_labor_signals.cell_offsets.size()) &&
                   _labor_signals.cell_offsets[cell + 1] <=
                       _save.labor_signal_cursor) ++cell;
            const int32_t i = _save.labor_signal_cursor;
            append_le<int32_t>(payload, cell);
            append_le<int32_t>(payload, _labor_signals.profession_ids[i]);
            append_le<int64_t>(payload, _labor_signals.base_living_cost[i]);
            append_le<int64_t>(payload, _labor_signals.role_living_cost[i]);
            append_le<int64_t>(payload, _labor_signals.contract_wage_ema[i]);
            append_le<int64_t>(payload, _labor_signals.paid_wage_ema[i]);
            append_le<int64_t>(payload, _labor_signals.job_days[i]);
            append_le<int32_t>(payload, _labor_signals.pay_ratio_q16[i]);
        }
        if (_save.labor_signal_cursor >=
            static_cast<int32_t>(_labor_signals.profession_ids.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_LABOR_SIGNALS,
            static_cast<uint32_t>(_save.labor_signal_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_TRADE_ORDERS) {
        const int32_t begin = _save.trade_order_cursor;
        const int32_t end = std::min(trade_orders_store().size(), begin + 1);
        for (; _save.trade_order_cursor < end; ++_save.trade_order_cursor) {
            const int32_t order = _save.trade_order_cursor;
            append_le<int64_t>(payload, trade_orders_store().ids[order]);
            append_le<int32_t>(payload, trade_orders_store().sources[order]);
            append_le<int32_t>(payload, trade_orders_store().destinations[order]);
            append_le<int32_t>(payload, trade_orders_store().countries[order]);
            append_le<uint64_t>(payload,
                trade_orders_store().source_country_handles[order]);
            append_le<uint64_t>(payload,
                trade_orders_store().destination_country_handles[order]);
            append_le<int32_t>(payload,
                trade_orders_store().source_country_slots[order]);
            append_le<int32_t>(payload,
                trade_orders_store().destination_country_slots[order]);
            append_le<int64_t>(payload, trade_orders_store().departure_days[order]);
            append_le<int64_t>(payload, trade_orders_store().arrival_days[order]);
            append_le<int64_t>(payload, trade_orders_store().cash_escrow[order]);
            append_le<int64_t>(payload, trade_orders_store().capacity_work[order]);
            append_le<uint8_t>(payload, trade_orders_store().states[order]);
            append_le<uint8_t>(payload, trade_orders_store().cargo_delivered[order]);
            const int32_t line_count = trade_orders_store().line_offsets[order + 1] -
                trade_orders_store().line_offsets[order];
            const int32_t seller_count = trade_orders_store().seller_offsets[order + 1] -
                trade_orders_store().seller_offsets[order];
            append_le<int32_t>(payload, line_count);
            append_le<int32_t>(payload, seller_count);
            for (int32_t line = trade_orders_store().line_offsets[order];
                 line < trade_orders_store().line_offsets[order + 1]; ++line) {
                append_le<int32_t>(payload, trade_orders_store().line_goods[line]);
                append_le<int64_t>(payload, trade_orders_store().line_quantities[line]);
                append_le<int32_t>(payload, trade_orders_store().line_unit_prices[line]);
                append_le<int32_t>(payload,
                    trade_orders_store().line_destination_prices[line]);
                append_le<int64_t>(payload,
                    trade_orders_store().line_base_values[line]);
                append_le<int64_t>(payload,
                    trade_orders_store().line_retail_values[line]);
                append_le<int64_t>(payload,
                    trade_orders_store().line_import_transfers[line]);
                append_le<int64_t>(payload,
                    trade_orders_store().line_export_transfers[line]);
                append_le<int64_t>(payload,
                    trade_orders_store().line_transaction_transfers[line]);
                append_le<uint8_t>(payload, trade_orders_store().line_flags[line]);
            }
            for (int32_t seller = trade_orders_store().seller_offsets[order];
                 seller < trade_orders_store().seller_offsets[order + 1]; ++seller) {
                append_le<uint64_t>(payload, trade_orders_store().seller_handles[seller]);
                append_le<int64_t>(payload, trade_orders_store().seller_weights[seller]);
            }
        }
        if (_save.trade_order_cursor >= trade_orders_store().size()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_TRADE_ORDERS,
            static_cast<uint32_t>(_save.trade_order_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_TRADE_FLOWS) {
        constexpr int32_t record_bytes = 40;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.trade_flow_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_trade_flows.cells.size()), begin + max_records);
        for (; _save.trade_flow_cursor < end; ++_save.trade_flow_cursor) {
            const int32_t flow = _save.trade_flow_cursor;
            append_le<int32_t>(payload, _trade_flows.cells[flow]);
            append_le<int32_t>(payload, _trade_flows.goods[flow]);
            append_le<int64_t>(payload, _trade_flows.import_ema[flow]);
            append_le<int64_t>(payload, _trade_flows.export_ema[flow]);
            append_le<int64_t>(payload, _trade_flows.period_import[flow]);
            append_le<int64_t>(payload, _trade_flows.period_export[flow]);
        }
        if (_save.trade_flow_cursor >= static_cast<int32_t>(_trade_flows.cells.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_TRADE_FLOWS,
            static_cast<uint32_t>(_save.trade_flow_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_MODIFIERS) {
        const size_t payload_budget = static_cast<size_t>(std::max(1, budget - 16));
        const size_t remaining = _save.modifier_bytes.size() - _save.modifier_cursor;
        const size_t take = std::min(remaining, payload_budget);
        if (take > 0) {
            payload.insert(payload.end(),
                           _save.modifier_bytes.begin() + static_cast<ptrdiff_t>(_save.modifier_cursor),
                           _save.modifier_bytes.begin() + static_cast<ptrdiff_t>(_save.modifier_cursor + take));
        }
        _save.modifier_cursor += take;
        if (_save.modifier_cursor >= _save.modifier_bytes.size()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_MODIFIERS,
                               static_cast<uint32_t>(take), payload);
    }
    if (_save.section == SAVE_SECTION_FISCAL) {
        constexpr int32_t record_bytes =
            4 + CountryApi::TAX_KIND_COUNT * 12 * 8 + 8 +
            NON_TAX_PERSISTED_KIND_COUNT * 8;
        const int32_t country_count = _save.fiscal_country_count;
        const int32_t max_records = std::max(
            1, (budget - 16) / record_bytes);
        const int32_t begin = _save.fiscal_cursor;
        const int32_t end = std::min(
            country_count, begin + max_records);
        const auto append_group = [&](const std::vector<int64_t> &values,
                                      int32_t country) {
            for (int32_t kind = 0;
                 kind < CountryApi::TAX_KIND_COUNT; ++kind) {
                const size_t index = static_cast<size_t>(country) *
                    CountryApi::TAX_KIND_COUNT + kind;
                append_le<int64_t>(payload,
                    index < values.size() ? values[index] : 0);
            }
        };
        for (; _save.fiscal_cursor < end; ++_save.fiscal_cursor) {
            const int32_t country = _save.fiscal_cursor;
            append_le<int32_t>(payload, country);
            append_group(_fiscal_last_bases, country);
            append_group(_fiscal_last_assessed, country);
            append_group(_fiscal_last_collected, country);
            append_group(_fiscal_last_requests, country);
            append_group(_fiscal_last_reserved, country);
            append_group(_fiscal_last_paid, country);
            append_group(_fiscal_last_unmet, country);
            append_group(_fiscal_last_events, country);
            append_group(_fiscal_cumulative_bases, country);
            append_group(_fiscal_cumulative_collected, country);
            append_group(_fiscal_cumulative_requests, country);
            append_group(_fiscal_cumulative_paid, country);
            append_le<int64_t>(payload,
                static_cast<size_t>(country) < _fiscal_escrow_by_country.size()
                    ? _fiscal_escrow_by_country[static_cast<size_t>(country)]
                    : 0);
            // Schema 58: the batch's non-tax treasury outflows (research
            // procurement, expedition cargo, construction, canal), one slot per
            // kind in NonTaxOutflow order.
            for (int32_t kind = 0; kind < NON_TAX_PERSISTED_KIND_COUNT; ++kind) {
                const size_t lane = static_cast<size_t>(country) *
                    static_cast<size_t>(NON_TAX_KIND_COUNT) +
                    static_cast<size_t>(kind);
                append_le<int64_t>(payload,
                    lane < _fiscal_last_non_tax_outflow.size()
                        ? _fiscal_last_non_tax_outflow[lane] : 0);
            }
        }
        if (_save.fiscal_cursor >= country_count) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FISCAL,
            static_cast<uint32_t>(_save.fiscal_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_SETTLEMENT_NAMES) {
        uint32_t records = 0;
        while (_save.settlement_cursor < _cell_count.get()) {
            const int32_t cell = _save.settlement_cursor++;
            if (_settlements.name_active[cell] == 0) continue;
            std::vector<uint8_t> record;
            append_le<int32_t>(record, cell);
            append_string(record, _settlement_name_pack_id.get());
            const bool full_name = _settlements.root[cell] < 0;
            append_string(record, full_name
                ? _settlement_full_name_ids[_settlements.prefix[cell]]
                : _settlement_prefix_ids[_settlements.prefix[cell]]);
            append_string(record, full_name ? std::string() :
                _settlement_root_ids[_settlements.root[cell]]);
            append_string(record, full_name ? std::string() :
                _settlement_suffix_ids[_settlements.suffix[cell]]);
            append_le<uint32_t>(record, _settlements.disambiguator[cell]);
            if (!payload.empty() &&
                payload.size() + record.size() >
                    static_cast<size_t>(budget - 16)) {
                --_save.settlement_cursor;
                break;
            }
            payload.insert(payload.end(), record.begin(), record.end());
            ++records;
        }
        if (_save.settlement_cursor >= _cell_count.get()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_SETTLEMENT_NAMES, records, payload);
    }
