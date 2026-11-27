    } else if (section == SAVE_SECTION_AUDIT) {
        for (uint32_t record = 0; record < records; ++record) {
            AuditFrame frame;
            if (!read_le(bytes, cursor, frame.epoch_id) ||
                !read_le(bytes, cursor, frame.sample_day) ||
                !read_le(bytes, cursor, frame.commit_day) ||
                !read_le(bytes, cursor, frame.event_count) ||
                !read_le(bytes, cursor, frame.leg_count) ||
                !read_le(bytes, cursor, frame.population_error) ||
                !read_le(bytes, cursor, frame.money_error) ||
                !read_le(bytes, cursor, frame.goods_error) ||
                !read_le(bytes, cursor, frame.stream_hash) ||
                frame.event_count < 0 || frame.leg_count < 0) {
                error = "save_audit_record_invalid";
                return false;
            }
            _audit_history.push_back(frame);
            ++_restore.restored_audits;
        }
    } else if (section == SAVE_SECTION_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t good = -1;
            int64_t business = 0;
            int64_t supply = 0;
            int64_t realized = 0;
            int32_t anchor = 0;
            int64_t sellable = 0, merchant_sold = 0;
            int64_t previous_sellable = 0, previous_merchant_sold = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, business) || !read_le(bytes, cursor, supply) ||
                (_restore.schema_version >= 12 && !read_le(bytes, cursor, realized)) ||
                !read_le(bytes, cursor, anchor) ||
                (schema >= 64 && (!read_le(bytes, cursor, sellable) ||
                    !read_le(bytes, cursor, merchant_sold) ||
                    !read_le(bytes, cursor, previous_sellable) ||
                    !read_le(bytes, cursor, previous_merchant_sold))) ||
                sellable < 0 || merchant_sold < 0 || merchant_sold > sellable ||
                previous_sellable < 0 || previous_merchant_sold < 0 ||
                previous_merchant_sold > previous_sellable ||
                cell < 0 || cell >= _cell_count.get() ||
                good < 0 || good >= market_store().good_count.get() || business < 0 || supply < 0 ||
                realized < 0 ||
                anchor < 0 || (anchor != 0 &&
                    (anchor < PRICE_NUMERIC_GUARD_MIN ||
                     anchor > PRICE_NUMERIC_GUARD_MAX)) ||
                (_restore.last_signal_cell > cell) ||
                (_restore.last_signal_cell == cell && _restore.last_signal_good >= good)) {
                error = "save_market_signal_record_invalid";
                return false;
            }
            _restore.last_signal_cell = cell;
            _restore.last_signal_good = good;
            _market_signals.cell_offsets.write_scalar(cell + 1, _market_signals.cell_offsets[cell + 1] + 1, market_mutation_sink());
            _market_signals.good_ids.push_back(good);
            _market_signals.business_demand_ema.push_back(business);
            _market_signals.offered_supply_ema.push_back(supply);
            _market_signals.realized_withdrawal_ema.push_back(realized);
            _market_signals.cost_anchor_price.push_back(anchor);
            _epoch_producer_sellable_current.push_back(sellable);
            _epoch_producer_merchant_sold_current.push_back(merchant_sold);
            _epoch_previous_producer_sellable.push_back(previous_sellable);
            _epoch_previous_producer_merchant_sold.push_back(previous_merchant_sold);
            ++_restore.restored_signals;
        }
        if (schema >= 64 && cursor < bytes.size()) {
            for (auto *values : {&_epoch_producer_sellable_current,
                    &_epoch_producer_merchant_sold_current,
                    &_epoch_previous_producer_sellable,
                    &_epoch_previous_producer_merchant_sold}) {
                uint32_t size = 0;
                if (!read_le(bytes, cursor, size) || size > values->size()) {
                    error = "save_market_signal_observation_size_invalid";
                    return false;
                }
                values->resize(size);
            }
        }
