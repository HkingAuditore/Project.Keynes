    auto arrival_for = [&](const TradeCandidate &candidate) {
        const int32_t source_country = candidate.source_country >= 0
            ? candidate.source_country : candidate.country;
        const int32_t destination_country = candidate.destination_country >= 0
            ? candidate.destination_country : candidate.country;
        int64_t speed_factor = Q16_ONE;
        if (source_country >= 0 && destination_country >= 0 &&
            source_country < static_cast<int32_t>(
                _epoch_country_trade_speed_factor_q16.size()) &&
            destination_country < static_cast<int32_t>(
                _epoch_country_trade_speed_factor_q16.size())) {
            speed_factor = (static_cast<int64_t>(
                _epoch_country_trade_speed_factor_q16[source_country]) +
                _epoch_country_trade_speed_factor_q16[destination_country]) / 2;
        }
        // A4: the per-good speed factor multiplies the two-end country average,
        // so a card that names one good changes only that good's transit time.
        // The array defaults to Q16_ONE, which keeps the previous behaviour
        // bit-for-bit when no per-good modifier is active.
        const int32_t candidate_good = candidate.good;
        if (candidate_good >= 0 && source_country >= 0 && destination_country >= 0) {
            const size_t good_count = _good_ids.size();
            const size_t source_good_index =
                static_cast<size_t>(source_country) * good_count +
                static_cast<size_t>(candidate_good);
            const size_t destination_good_index =
                static_cast<size_t>(destination_country) * good_count +
                static_cast<size_t>(candidate_good);
            if (good_count > 0 &&
                static_cast<size_t>(candidate_good) < good_count &&
                source_good_index <
                    _epoch_country_good_trade_speed_factor_q16.size() &&
                destination_good_index <
                    _epoch_country_good_trade_speed_factor_q16.size()) {
                const int64_t good_speed_factor = (static_cast<int64_t>(
                    _epoch_country_good_trade_speed_factor_q16[source_good_index]) +
                    _epoch_country_good_trade_speed_factor_q16[destination_good_index]) / 2;
                if (good_speed_factor != Q16_ONE) {
                    speed_factor = mul_div_sat(speed_factor, good_speed_factor,
                        Q16_ONE, _saturation_count);
                }
            }
        }
        const int64_t effective_speed = std::max<int64_t>(
            1, mul_div_sat(_trade_speed_cost_per_day.get(), speed_factor,
                           Q16_ONE, _saturation_count));
        const int64_t raw_days = std::max<int64_t>(1,
            (candidate.route_cost + effective_speed - 1) / effective_speed);
        // Transport is a daily authority transaction. Local markets consume
        // the delivered stock on their next rolling settlement, but cargo must
        // not wait for or align to that five-day cadence.
        return _sample_day + raw_days;
    };
    std::stable_sort(accepted.begin(), accepted.end(), [&](const TradeCandidate &a,
                                                           const TradeCandidate &b) {
        if (a.source != b.source) return a.source < b.source;
        if (a.destination != b.destination) return a.destination < b.destination;
        const int64_t arrival_a = arrival_for(a);
        const int64_t arrival_b = arrival_for(b);
        if (arrival_a != arrival_b) return arrival_a < arrival_b;
        return a.good < b.good;
    });
    size_t cursor = 0;
    while (cursor < accepted.size()) {
        const TradeCandidate &first = accepted[cursor];
        const int64_t arrival = arrival_for(first);
        const size_t begin = cursor;
        while (cursor < accepted.size() && cursor - begin < 16 &&
               accepted[cursor].source == first.source &&
               accepted[cursor].destination == first.destination &&
               arrival_for(accepted[cursor]) == arrival) ++cursor;
        trade_orders_store().ids.push_back(trade_orders_store().next_id++);
        trade_orders_store().sources.push_back(first.source);
        trade_orders_store().destinations.push_back(first.destination);
        trade_orders_store().countries.push_back(first.country);
        trade_orders_store().source_country_handles.push_back(
            first.source_country_handle);
        trade_orders_store().destination_country_handles.push_back(
            first.destination_country_handle);
        trade_orders_store().source_country_slots.push_back(first.source_country);
        trade_orders_store().destination_country_slots.push_back(
            first.destination_country);
        trade_orders_store().departure_days.push_back(_sample_day);
        trade_orders_store().arrival_days.push_back(arrival);
        trade_orders_store().states.push_back(TradeOrderStore::IN_TRANSIT);
        trade_orders_store().cargo_delivered.push_back(0);
        int64_t cash = 0;
        int64_t capacity = 0;
        int32_t trade_event_flags = 0;
        std::vector<EventLeg> trade_legs;
        trade_legs.reserve((cursor - begin) * 6U);
        for (size_t i = begin; i < cursor; ++i) {
            const TradeCandidate &candidate = accepted[i];
            int64_t sat = 0;
            const int64_t line_cash = saturating_sub(
                candidate.base_value, candidate.export_transfer, sat);
            cash = saturating_add(cash, line_cash, _saturation_count);
            capacity = saturating_add(capacity, candidate.capacity_work, _saturation_count);
            trade_orders_store().line_goods.push_back(candidate.good);
            trade_orders_store().line_quantities.push_back(candidate.quantity);
            trade_orders_store().line_unit_prices.push_back(candidate.source_price);
            trade_orders_store().line_destination_prices.push_back(
                candidate.destination_price);
            trade_orders_store().line_base_values.push_back(candidate.base_value);
            trade_orders_store().line_retail_values.push_back(candidate.retail_value);
            trade_orders_store().line_import_transfers.push_back(
                candidate.import_transfer);
            trade_orders_store().line_export_transfers.push_back(
                candidate.export_transfer);
            trade_orders_store().line_transaction_transfers.push_back(
                candidate.transaction_transfer);
            trade_orders_store().line_flags.push_back(candidate.flags);
            trade_event_flags |= static_cast<int32_t>(candidate.flags) << 8;
            const int64_t order_id = trade_orders_store().ids.back();
            trade_legs.push_back({FIELD_TRADE_QUANTITY,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.quantity});
            trade_legs.push_back({FIELD_TRADE_BASE_VALUE,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.base_value});
            trade_legs.push_back({FIELD_TRADE_RETAIL_VALUE,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.retail_value});
            trade_legs.push_back({FIELD_TRADE_IMPORT_TRANSFER,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.import_transfer});
            trade_legs.push_back({FIELD_TRADE_EXPORT_TRANSFER,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.export_transfer});
            trade_legs.push_back({FIELD_TRADE_TRANSACTION_TRANSFER,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.transaction_transfer});
        }
        trade_orders_store().cash_escrow.push_back(cash);
        trade_orders_store().capacity_work.push_back(capacity);
        trade_orders_store().line_offsets.push_back(
            static_cast<int32_t>(trade_orders_store().line_goods.size()));
        for (int32_t k = _merchant_offsets[first.source];
             k < _merchant_offsets[first.source + 1]; ++k) {
            const int32_t slot = _merchant_slots[k];
            trade_orders_store().seller_handles.push_back(population_store().handle_for_slot(slot));
            trade_orders_store().seller_weights.push_back(
                std::max<int64_t>(1, population_store().population[slot]));
        }
        trade_orders_store().seller_offsets.push_back(
            static_cast<int32_t>(trade_orders_store().seller_handles.size()));
        const bool trace_trade_detail = trace_detail_for_cell(first.source) ||
            trace_detail_for_cell(first.destination);
        trace_append(EVENT_TRADE_DISPATCHED,
            static_cast<int32_t>(Stage::TRADE_DISPATCH), first.destination,
            SUBJECT_TRADE_ORDER, trade_orders_store().ids.back(), first.source,
            first.destination, static_cast<int64_t>(cursor - begin), cash,
            capacity, arrival, trace_trade_detail ? &trade_legs : nullptr,
            trade_event_flags);
        ++_trade_orders_dispatched;
        // Transient per-country counter for era advancement (country as
        // source or destination; one count per dispatched order).
        note_trade_order_countries(first.source, first.destination);
        trade_orders_store().arrival_buckets_dirty = true;
    }
