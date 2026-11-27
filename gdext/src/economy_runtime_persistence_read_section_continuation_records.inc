    } else if (section == SAVE_SECTION_LABOR_SIGNALS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            int32_t profession = -1;
            int64_t base_living = 0;
            int64_t role_living = 0;
            int64_t contract = 0;
            int64_t paid = 0;
            int64_t jobs = 0;
            int32_t ratio = 0;
            if (!read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, profession) ||
                !read_le(bytes, cursor, base_living) ||
                !read_le(bytes, cursor, role_living) ||
                !read_le(bytes, cursor, contract) ||
                !read_le(bytes, cursor, paid) ||
                !read_le(bytes, cursor, jobs) ||
                !read_le(bytes, cursor, ratio) ||
                cell < 0 || cell >= _cell_count.get() || profession < 0 ||
                profession >= static_cast<int32_t>(_profession_ids.size()) ||
                base_living < 0 || role_living < 0 || contract < 0 || paid < 0 ||
                jobs < 0 || ratio < 0 || ratio > Q16_ONE ||
                _restore.last_labor_cell > cell ||
                (_restore.last_labor_cell == cell &&
                 _restore.last_labor_profession >= profession)) {
                error = "save_labor_signal_record_invalid";
                return false;
            }
            _restore.last_labor_cell = cell;
            _restore.last_labor_profession = profession;
            _labor_signals.cell_offsets.write_scalar(cell + 1, _labor_signals.cell_offsets[cell + 1] + 1, market_mutation_sink());
            _labor_signals.profession_ids.push_back(profession);
            _labor_signals.base_living_cost.push_back(base_living);
            _labor_signals.role_living_cost.push_back(role_living);
            _labor_signals.contract_wage_ema.push_back(contract);
            _labor_signals.paid_wage_ema.push_back(paid);
            _labor_signals.job_days.push_back(jobs);
            _labor_signals.pay_ratio_q16.push_back(ratio);
            ++_restore.restored_labor_signals;
        }
    } else if (schema >= 11 && section == SAVE_SECTION_TRADE_ORDERS) {
        for (uint32_t record = 0; record < records; ++record) {
            int64_t id = 0, departure = 0, arrival = 0, cash = 0, capacity = 0;
            int32_t source = -1, destination = -1, country = -1;
            uint64_t source_country_handle = 0;
            uint64_t destination_country_handle = 0;
            int32_t source_country_slot = -1, destination_country_slot = -1;
            uint8_t state = 0, delivered = 0;
            int32_t line_count = 0, seller_count = 0;
            if (!read_le(bytes, cursor, id) || !read_le(bytes, cursor, source) ||
                !read_le(bytes, cursor, destination) || !read_le(bytes, cursor, country) ||
                !read_le(bytes, cursor, source_country_handle) ||
                !read_le(bytes, cursor, destination_country_handle) ||
                !read_le(bytes, cursor, source_country_slot) ||
                !read_le(bytes, cursor, destination_country_slot) ||
                !read_le(bytes, cursor, departure) || !read_le(bytes, cursor, arrival) ||
                !read_le(bytes, cursor, cash) || !read_le(bytes, cursor, capacity) ||
                !read_le(bytes, cursor, state) || !read_le(bytes, cursor, delivered) ||
                !read_le(bytes, cursor, line_count) ||
                !read_le(bytes, cursor, seller_count) || id <= 0 ||
                (!trade_orders_store().ids.empty() && id <= trade_orders_store().ids.back()) ||
                source_country_handle == 0 || destination_country_handle == 0 ||
                source_country_slot < 0 || destination_country_slot < 0 ||
                source < 0 || source >= _cell_count.get() || destination < 0 ||
                destination >= _cell_count.get() || source == destination || country < 0 ||
                departure < 0 || arrival < departure || cash < 0 || capacity <= 0 ||
                state > TradeOrderStore::WAITING_RECEIVER || delivered > 1 ||
                (state == TradeOrderStore::IN_TRANSIT && delivered != 0) ||
                (state == TradeOrderStore::WAITING_RECEIVER && delivered == 0) ||
                line_count <= 0 || line_count > 16 || seller_count < 0 ||
                seller_count > 1000000) {
                error = "save_trade_order_record_invalid";
                return false;
            }
            trade_orders_store().ids.push_back(id);
            trade_orders_store().sources.push_back(source);
            trade_orders_store().destinations.push_back(destination);
            trade_orders_store().countries.push_back(country);
            trade_orders_store().source_country_handles.push_back(source_country_handle);
            trade_orders_store().destination_country_handles.push_back(
                destination_country_handle);
            trade_orders_store().source_country_slots.push_back(source_country_slot);
            trade_orders_store().destination_country_slots.push_back(
                destination_country_slot);
            trade_orders_store().departure_days.push_back(departure);
            trade_orders_store().arrival_days.push_back(arrival);
            trade_orders_store().cash_escrow.push_back(cash);
            trade_orders_store().capacity_work.push_back(capacity);
            trade_orders_store().states.push_back(state);
            trade_orders_store().cargo_delivered.push_back(delivered);
            for (int32_t line = 0; line < line_count; ++line) {
                int32_t good = -1, price = 0, destination_price = 0;
                int64_t quantity = 0, base_value = 0, retail_value = 0;
                int64_t import_transfer = 0, export_transfer = 0;
                int64_t transaction_transfer = 0;
                uint8_t line_flags = 0;
                if (!read_le(bytes, cursor, good) ||
                    !read_le(bytes, cursor, quantity) ||
                    !read_le(bytes, cursor, price) ||
                    !read_le(bytes, cursor, destination_price) ||
                    !read_le(bytes, cursor, base_value) ||
                    !read_le(bytes, cursor, retail_value) ||
                    !read_le(bytes, cursor, import_transfer) ||
                    !read_le(bytes, cursor, export_transfer) ||
                    (schema >= 46 &&
                     !read_le(bytes, cursor, transaction_transfer)) ||
                    !read_le(bytes, cursor, line_flags) || good < 0 ||
                    good >= market_store().good_count.get() || _good_trade_enabled[good] == 0 ||
                    quantity <= 0 || price < PRICE_NUMERIC_GUARD_MIN ||
                    price > PRICE_NUMERIC_GUARD_MAX || destination_price < 0 ||
                    base_value < 0 || retail_value < 0) {
                    error = "save_trade_order_line_invalid";
                    return false;
                }
                trade_orders_store().line_goods.push_back(good);
                trade_orders_store().line_quantities.push_back(quantity);
                trade_orders_store().line_unit_prices.push_back(price);
                trade_orders_store().line_destination_prices.push_back(destination_price);
                trade_orders_store().line_base_values.push_back(base_value);
                trade_orders_store().line_retail_values.push_back(retail_value);
                trade_orders_store().line_import_transfers.push_back(import_transfer);
                trade_orders_store().line_export_transfers.push_back(export_transfer);
                trade_orders_store().line_transaction_transfers.push_back(
                    transaction_transfer);
                trade_orders_store().line_flags.push_back(line_flags);
            }
            trade_orders_store().line_offsets.push_back(
                static_cast<int32_t>(trade_orders_store().line_goods.size()));
            for (int32_t seller = 0; seller < seller_count; ++seller) {
                uint64_t handle = 0;
                int64_t weight = 0;
                if (!read_le(bytes, cursor, handle) ||
                    !read_le(bytes, cursor, weight) || handle == 0 || weight <= 0) {
                    error = "save_trade_order_seller_invalid";
                    return false;
                }
                trade_orders_store().seller_handles.push_back(handle);
                trade_orders_store().seller_weights.push_back(weight);
            }
            trade_orders_store().seller_offsets.push_back(
                static_cast<int32_t>(trade_orders_store().seller_handles.size()));
            ++_restore.restored_trade_orders;
        }
    } else if (schema >= 11 && section == SAVE_SECTION_TRADE_FLOWS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1, good = -1;
            int64_t import_ema = 0, export_ema = 0, period_import = 0,
                    period_export = 0;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, import_ema) ||
                !read_le(bytes, cursor, export_ema) ||
                !read_le(bytes, cursor, period_import) ||
                !read_le(bytes, cursor, period_export) || cell < 0 ||
                cell >= _cell_count.get() || good < 0 || good >= market_store().good_count.get() ||
                import_ema < 0 || export_ema < 0 || period_import < 0 ||
                period_export < 0 || (!_trade_flows.cells.empty() &&
                    (_trade_flows.cells.back() > cell ||
                     (_trade_flows.cells.back() == cell &&
                      _trade_flows.goods.back() >= good)))) {
                error = "save_trade_flow_record_invalid";
                return false;
            }
            _trade_flows.cells.push_back(cell);
            _trade_flows.goods.push_back(good);
            _trade_flows.import_ema.push_back(import_ema);
            _trade_flows.export_ema.push_back(export_ema);
            _trade_flows.period_import.push_back(period_import);
            _trade_flows.period_export.push_back(period_export);
            ++_restore.restored_trade_flows;
        }
    } else if (schema >= 20 && section == SAVE_SECTION_MODIFIERS) {
        if (records != payload_bytes ||
            _restore.modifier_bytes.size() + payload_bytes >
                256ULL * 1024ULL * 1024ULL) {
            error = "save_modifier_section_invalid";
            return false;
        }
        _restore.modifier_bytes.insert(_restore.modifier_bytes.end(),
                                       bytes.begin() + static_cast<ptrdiff_t>(cursor),
                                       bytes.end());
        cursor = bytes.size();
        _restore.modifier_seen = true;
    } else if (schema >= 23 && section == SAVE_SECTION_FISCAL) {
        CountryReadView::Snapshot country_snapshot;
        if (_country_runtime == nullptr ||
            !country_reads().copy_economy_snapshot(country_snapshot)) {
            error = "save_fiscal_country_snapshot_unavailable";
            return false;
        }
        const int32_t country_count = std::max(0,
            country_snapshot.country_count);
        const size_t summary_count = static_cast<size_t>(country_count) *
            CountryApi::TAX_KIND_COUNT;
        if (_restore.expected_fiscal < 0) {
            _restore.expected_fiscal = country_count;
            _fiscal_escrow_by_country.assign(
                static_cast<size_t>(country_count), 0);
        } else if (_restore.expected_fiscal != country_count ||
                   _restore.restored_fiscal +
                       static_cast<int64_t>(records) > country_count) {
            error = "save_fiscal_record_count_invalid";
            return false;
        }
        const auto ensure_summary_size = [&](size_t size) {
            _fiscal_last_bases.resize(size, 0);
            _fiscal_last_assessed.resize(size, 0);
            _fiscal_last_collected.resize(size, 0);
            _fiscal_last_requests.resize(size, 0);
            _fiscal_last_reserved.resize(size, 0);
            _fiscal_last_paid.resize(size, 0);
            _fiscal_last_unmet.resize(size, 0);
            _fiscal_last_events.resize(size, 0);
            _fiscal_cumulative_bases.resize(size, 0);
            _fiscal_cumulative_collected.resize(size, 0);
            _fiscal_cumulative_requests.resize(size, 0);
            _fiscal_cumulative_paid.resize(size, 0);
        };
        ensure_summary_size(summary_count);
        _fiscal_last_non_tax_outflow.resize(
            static_cast<size_t>(country_count) *
                static_cast<size_t>(NON_TAX_KIND_COUNT), 0);
        const auto read_group = [&](auto &values,
                                    int32_t country) {
            for (int32_t kind = 0;
                 kind < CountryApi::TAX_KIND_COUNT; ++kind) {
                const size_t index = static_cast<size_t>(country) *
                    CountryApi::TAX_KIND_COUNT + kind;
                if (index >= values.size() ||
                    !read_column_le(bytes, cursor, values, index) ||
                    values[index] < 0)
                    return false;
            }
            return true;
        };
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1;
            int64_t escrow = 0;
            if (!read_le(bytes, cursor, country) ||
                country != _restore.restored_fiscal ||
                country < 0 || static_cast<size_t>(country) *
                    CountryApi::TAX_KIND_COUNT >= summary_count ||
                !read_group(_fiscal_last_bases, country) ||
                !read_group(_fiscal_last_assessed, country) ||
                !read_group(_fiscal_last_collected, country) ||
                !read_group(_fiscal_last_requests, country) ||
                !read_group(_fiscal_last_reserved, country) ||
                !read_group(_fiscal_last_paid, country) ||
                !read_group(_fiscal_last_unmet, country) ||
                !read_group(_fiscal_last_events, country) ||
                !read_group(_fiscal_cumulative_bases, country) ||
                !read_group(_fiscal_cumulative_collected, country) ||
                !read_group(_fiscal_cumulative_requests, country) ||
                !read_group(_fiscal_cumulative_paid, country) ||
                !read_le(bytes, cursor, escrow) || escrow < 0 ||
                static_cast<size_t>(country) >=
                    _fiscal_escrow_by_country.size()) {
                error = "save_fiscal_record_invalid";
                return false;
            }
            // Schema 58 stores the batch's non-tax treasury outflows beside the
            // escrow balance: research procurement, expedition cargo,
            // construction and canal, one slot per kind. Older saves migrate to
            // zero, which is exactly what they displayed before the field
            // existed.
            int64_t non_tax_outflow[NON_TAX_KIND_COUNT] = {};
            if (_restore.schema_version >= 58) {
                for (int32_t kind = 0; kind < NON_TAX_PERSISTED_KIND_COUNT; ++kind) {
                    if (!read_le(bytes, cursor, non_tax_outflow[kind]) ||
                        non_tax_outflow[kind] < 0) {
                        error = "save_fiscal_record_invalid";
                        return false;
                    }
                }
            }
            _fiscal_escrow_by_country.write_scalar(static_cast<size_t>(country), escrow, market_mutation_sink());
            for (int32_t kind = 0; kind < NON_TAX_KIND_COUNT; ++kind) {
                const size_t lane = static_cast<size_t>(country) *
                    static_cast<size_t>(NON_TAX_KIND_COUNT) +
                    static_cast<size_t>(kind);
                _fiscal_last_non_tax_outflow.write_scalar(
                    lane, non_tax_outflow[kind], market_mutation_sink());
            }
            ++_restore.restored_fiscal;
        }
        _restore.fiscal_seen = true;
    } else if (schema >= 24 &&
               section == SAVE_SECTION_SETTLEMENT_NAMES) {
        const auto stable_index = [](
                const std::vector<std::string> &ids,
                const std::vector<std::string> &alias_ids,
                const std::vector<std::string> &alias_targets,
                const std::string &id) -> int32_t {
            const auto found = std::find(ids.begin(), ids.end(), id);
            if (found != ids.end())
                return static_cast<int32_t>(found - ids.begin());
            const auto alias = std::find(
                alias_ids.begin(), alias_ids.end(), id);
            if (alias == alias_ids.end()) return -1;
            const size_t alias_index = static_cast<size_t>(
                alias - alias_ids.begin());
            const auto target = std::find(ids.begin(), ids.end(),
                alias_targets[alias_index]);
            return target == ids.end() ? -1 :
                static_cast<int32_t>(target - ids.begin());
        };
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1;
            uint32_t disambiguator = 0;
            std::string pack_id, prefix_id, root_id, suffix_id;
            if (!read_le(bytes, cursor, cell) ||
                !read_string(bytes, cursor, pack_id) ||
                !read_string(bytes, cursor, prefix_id) ||
                !read_string(bytes, cursor, root_id) ||
                !read_string(bytes, cursor, suffix_id) ||
                !read_le(bytes, cursor, disambiguator) ||
                cell < 0 || cell >= _cell_count.get() ||
                _settlements.name_active[cell] != 0 ||
                (_settlements.tier[cell] < _settlement_named_tier &&
                 _settlements.name_forced[cell] == 0) ||
                pack_id != _settlement_name_pack_id.get()) {
                error = "save_settlement_name_record_invalid";
                return false;
            }
            const bool full_name_mode = root_id.empty() &&
                suffix_id.empty();
            const int32_t prefix = stable_index(
                full_name_mode ? _settlement_full_name_ids :
                    _settlement_prefix_ids,
                full_name_mode ? _settlement_full_name_alias_ids :
                    _settlement_prefix_alias_ids,
                full_name_mode ? _settlement_full_name_alias_targets :
                    _settlement_prefix_alias_targets, prefix_id);
            const int32_t root = full_name_mode ? -1 : stable_index(
                _settlement_root_ids, _settlement_root_alias_ids,
                _settlement_root_alias_targets, root_id);
            const int32_t suffix = full_name_mode ? -1 : stable_index(
                _settlement_suffix_ids, _settlement_suffix_alias_ids,
                _settlement_suffix_alias_targets, suffix_id);
            if (prefix < 0 ||
                (!full_name_mode && (root < 0 || suffix < 0))) {
                error = "save_settlement_name_component_missing";
                return false;
            }
            _settlements.name_active.write_scalar(cell, 1, market_mutation_sink());
            _settlements.prefix.write_scalar(cell, prefix, market_mutation_sink());
            _settlements.root.write_scalar(cell, root, market_mutation_sink());
            _settlements.suffix.write_scalar(cell, suffix, market_mutation_sink());
            _settlements.disambiguator.write_scalar(cell, disambiguator, market_mutation_sink());
            const std::string visible = settlement_name_for_cell(cell);
            if (!_settlements.active_names.emplace(visible, cell).second) {
                error = "save_settlement_name_duplicate";
                return false;
            }
        }
        _restore.settlement_names_seen = true;
    } else if ((schema >= 26 && section == SAVE_SECTION_FAMILY_RECORDS) ||
               (schema >= 26 && section == SAVE_SECTION_FAMILY_MEMBERSHIP) ||
               (schema >= 26 && section == SAVE_SECTION_FAMILY_OWNERSHIP) ||
               (schema >= 27 && section == SAVE_SECTION_PERSON_RECORDS) ||
               (schema >= 27 && section == SAVE_SECTION_PERSON_NEEDS) ||
               (section == SAVE_SECTION_FAMILY_TRAITS) ||
               (section == SAVE_SECTION_FAMILY_INFLUENCES) ||
               (section == SAVE_SECTION_FAMILY_TRAIT_COMMANDS) ||
               (section == SAVE_SECTION_FAMILY_EXPEDITIONS)) {
        if (!decode_restore_family_tables(bytes, cursor, schema, section, records, error))
            return false;
    } else if (schema >= 33 && section == SAVE_SECTION_TARIFF_HISTORY) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1, kind = -1;
            int64_t base = 0, assessed = 0, collected = 0, requests = 0,
                reserved = 0, paid = 0, cumulative_base = 0,
                cumulative_collected = 0, cumulative_requests = 0,
                cumulative_paid = 0;
            if (!read_le(bytes, cursor, country) || !read_le(bytes, cursor, kind) ||
                !read_le(bytes, cursor, base) || !read_le(bytes, cursor, assessed) ||
                !read_le(bytes, cursor, collected) || !read_le(bytes, cursor, requests) ||
                !read_le(bytes, cursor, reserved) || !read_le(bytes, cursor, paid) ||
                !read_le(bytes, cursor, cumulative_base) ||
                !read_le(bytes, cursor, cumulative_collected) ||
                !read_le(bytes, cursor, cumulative_requests) ||
                !read_le(bytes, cursor, cumulative_paid) || country < 0 ||
                kind < CountryApi::TAX_IMPORT ||
                kind > CountryApi::TAX_EXPORT || base < 0 || assessed < 0 ||
                collected < 0 || requests < 0 || reserved < 0 || paid < 0 ||
                cumulative_base < 0 || cumulative_collected < 0 ||
                cumulative_requests < 0 || cumulative_paid < 0) {
                error = "save_tariff_history_record_invalid";
                return false;
            }
            _tariff_history.countries.push_back(country);
            _tariff_history.kinds.push_back(kind);
            _tariff_history.bases.push_back(base);
            _tariff_history.assessed.push_back(assessed);
            _tariff_history.collected.push_back(collected);
            _tariff_history.requests.push_back(requests);
            _tariff_history.reserved.push_back(reserved);
            _tariff_history.paid.push_back(paid);
            _tariff_history.cumulative_bases.push_back(cumulative_base);
            _tariff_history.cumulative_collected.push_back(cumulative_collected);
            _tariff_history.cumulative_requests.push_back(cumulative_requests);
            _tariff_history.cumulative_paid.push_back(cumulative_paid);
            ++_restore.restored_tariff_history;
        }
        _restore.tariff_history_seen = true;
    } else if (schema >= 33 && section == SAVE_SECTION_COUNTRY_GOOD) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1, good = -1;
            int64_t import_quantity = 0, export_quantity = 0,
                import_base = 0, export_base = 0,
                import_tariff = 0, export_tariff = 0,
                batch_epoch = -1, batch_import_quantity = 0,
                batch_export_quantity = 0, batch_import_base = 0,
                batch_export_base = 0, batch_import_tariff = 0,
                batch_export_tariff = 0;
            if (!read_le(bytes, cursor, country) || !read_le(bytes, cursor, good) ||
                !read_le(bytes, cursor, import_quantity) ||
                !read_le(bytes, cursor, export_quantity) ||
                !read_le(bytes, cursor, import_base) ||
                !read_le(bytes, cursor, export_base) ||
                !read_le(bytes, cursor, import_tariff) ||
                !read_le(bytes, cursor, export_tariff) ||
                !read_le(bytes, cursor, batch_epoch) ||
                !read_le(bytes, cursor, batch_import_quantity) ||
                !read_le(bytes, cursor, batch_export_quantity) ||
                !read_le(bytes, cursor, batch_import_base) ||
                !read_le(bytes, cursor, batch_export_base) ||
                !read_le(bytes, cursor, batch_import_tariff) ||
                !read_le(bytes, cursor, batch_export_tariff) ||
                country < 0 || good < 0 ||
                good >= market_store().good_count.get() || import_quantity < 0 ||
                export_quantity < 0 || import_base < 0 || export_base < 0 ||
                batch_epoch < -1 || batch_epoch > _epoch_id.get() ||
                batch_import_quantity < 0 || batch_export_quantity < 0 ||
                batch_import_base < 0 || batch_export_base < 0) {
                error = "save_country_good_record_invalid";
                return false;
            }
            _country_good_trade.countries.push_back(country);
            _country_good_trade.goods.push_back(good);
            _country_good_trade.import_quantity.push_back(import_quantity);
            _country_good_trade.export_quantity.push_back(export_quantity);
            _country_good_trade.import_base.push_back(import_base);
            _country_good_trade.export_base.push_back(export_base);
            _country_good_trade.import_tariff.push_back(import_tariff);
            _country_good_trade.export_tariff.push_back(export_tariff);
            _country_good_trade.batch_epoch.push_back(batch_epoch);
            _country_good_trade.batch_import_quantity.push_back(
                batch_import_quantity);
            _country_good_trade.batch_export_quantity.push_back(
                batch_export_quantity);
            _country_good_trade.batch_import_base.push_back(batch_import_base);
            _country_good_trade.batch_export_base.push_back(batch_export_base);
            _country_good_trade.batch_import_tariff.push_back(batch_import_tariff);
            _country_good_trade.batch_export_tariff.push_back(batch_export_tariff);
            ++_restore.restored_country_good;
        }
        _restore.country_good_seen = true;
    } else if (schema >= 33 && section == SAVE_SECTION_COUNTRY_PARTNER) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t country = -1, partner = -1;
            int64_t import_quantity = 0, export_quantity = 0,
                import_base = 0, export_base = 0, order_count = 0,
                batch_epoch = -1, batch_import_quantity = 0,
                batch_export_quantity = 0, batch_import_base = 0,
                batch_export_base = 0, batch_order_count = 0;
            if (!read_le(bytes, cursor, country) || !read_le(bytes, cursor, partner) ||
                !read_le(bytes, cursor, import_quantity) ||
                !read_le(bytes, cursor, export_quantity) ||
                !read_le(bytes, cursor, import_base) ||
                !read_le(bytes, cursor, export_base) ||
                !read_le(bytes, cursor, order_count) ||
                !read_le(bytes, cursor, batch_epoch) ||
                !read_le(bytes, cursor, batch_import_quantity) ||
                !read_le(bytes, cursor, batch_export_quantity) ||
                !read_le(bytes, cursor, batch_import_base) ||
                !read_le(bytes, cursor, batch_export_base) ||
                !read_le(bytes, cursor, batch_order_count) ||
                country < 0 || partner < 0 || country == partner ||
                import_quantity < 0 || export_quantity < 0 || import_base < 0 ||
                export_base < 0 || order_count < 0 ||
                batch_epoch < -1 || batch_epoch > _epoch_id.get() ||
                batch_import_quantity < 0 || batch_export_quantity < 0 ||
                batch_import_base < 0 || batch_export_base < 0 ||
                batch_order_count < 0) {
                error = "save_country_partner_record_invalid";
                return false;
            }
            _country_partner_trade.countries.push_back(country);
            _country_partner_trade.partners.push_back(partner);
            _country_partner_trade.import_quantity.push_back(import_quantity);
            _country_partner_trade.export_quantity.push_back(export_quantity);
            _country_partner_trade.import_base.push_back(import_base);
            _country_partner_trade.export_base.push_back(export_base);
            _country_partner_trade.order_count.push_back(order_count);
            _country_partner_trade.batch_epoch.push_back(batch_epoch);
            _country_partner_trade.batch_import_quantity.push_back(
                batch_import_quantity);
            _country_partner_trade.batch_export_quantity.push_back(
                batch_export_quantity);
            _country_partner_trade.batch_import_base.push_back(batch_import_base);
            _country_partner_trade.batch_export_base.push_back(batch_export_base);
            _country_partner_trade.batch_order_count.push_back(batch_order_count);
            ++_restore.restored_country_partner;
        }
        _restore.country_partner_seen = true;
    } else if (schema >= 34 && section == SAVE_SECTION_CANAL_QUOTES) {
        for (uint32_t record = 0; record < records; ++record) {
            CanalQuote quote;
            uint8_t active = 0;
            uint32_t cell_count = 0, edge_count = 0;
            if (!read_le(bytes, cursor, quote.token) ||
                !read_le(bytes, cursor, quote.country_handle) ||
                !read_le(bytes, cursor, quote.snapshot_day) ||
                !read_le(bytes, cursor, quote.topology_hash) ||
                !read_le(bytes, cursor, quote.country_generation) ||
                !read_le(bytes, cursor, quote.price_hash) ||
                !read_le(bytes, cursor, quote.source_kind) ||
                !read_le(bytes, cursor, quote.new_edge_count) ||
                !read_le(bytes, cursor, quote.reused_edge_count) ||
                !read_le(bytes, cursor, quote.construction_days) ||
                !read_le(bytes, cursor, quote.cash_required)) {
                error = "save_canal_quote_truncated";
                return false;
            }
            for (int32_t &value : quote.material_good_ids)
                if (!read_le(bytes, cursor, value)) {
                    error = "save_canal_quote_truncated"; return false;
                }
            for (int64_t &value : quote.material_quantities)
                if (!read_le(bytes, cursor, value)) {
                    error = "save_canal_quote_truncated"; return false;
                }
            if (!read_le(bytes, cursor, active) ||
                !read_le(bytes, cursor, cell_count) ||
                !read_le(bytes, cursor, edge_count) || active > 1 ||
                quote.token == 0 || quote.country_handle == 0 ||
                quote.snapshot_day < -1 ||
                quote.source_kind < CANAL_SOURCE_SALINE ||
                quote.source_kind > CANAL_SOURCE_FRESHWATER ||
                quote.new_edge_count < 0 || quote.reused_edge_count < 0 ||
                quote.construction_days < 0 || quote.cash_required < 0 ||
                cell_count < 2 || cell_count > 33 || edge_count + 1 != cell_count) {
                error = "save_canal_quote_invalid";
                return false;
            }
            quote.route_cells.resize(cell_count);
            quote.route_edge_dirs.resize(edge_count);
            std::unordered_set<int32_t> unique_cells;
            for (int32_t &cell : quote.route_cells) {
                if (!read_le(bytes, cursor, cell) || cell < 0 || cell >= _cell_count.get() ||
                    !unique_cells.emplace(cell).second) {
                    error = "save_canal_quote_route_invalid"; return false;
                }
            }
            for (int32_t &dir : quote.route_edge_dirs) {
                if (!read_le(bytes, cursor, dir) || dir < 0 || dir >= 6) {
                    error = "save_canal_quote_route_invalid"; return false;
                }
            }
            if (active != 0 && _canal_quote_index.find(quote.token) !=
                    _canal_quote_index.end()) {
                error = "save_canal_quote_duplicate";
                return false;
            }
            const int32_t index = static_cast<int32_t>(_canal_quotes.size());
            _canal_quotes.push_back(std::move(quote));
            if (active != 0) _canal_quote_index.write_record(_canal_quotes.back().token, index);
            ++_restore.restored_canal_quotes;
        }
        _restore.canal_quotes_seen = true;
    } else if (schema >= 34 && section == SAVE_SECTION_CANAL_PROJECTS) {
        for (uint32_t record = 0; record < records; ++record) {
            CanalProject project;
            uint32_t cell_count = 0, edge_count = 0;
            if (!read_le(bytes, cursor, project.handle) ||
                !read_le(bytes, cursor, project.generation) ||
                !read_le(bytes, cursor, project.country_handle) ||
                !read_le(bytes, cursor, project.effective_day) ||
                !read_le(bytes, cursor, project.sequence) ||
                !read_le(bytes, cursor, project.ready_day) ||
                !read_le(bytes, cursor, project.effect_transaction_id) ||
                !read_le(bytes, cursor, project.topology_hash) ||
                !read_le(bytes, cursor, project.cash_paid) ||
                !read_le(bytes, cursor, project.treasury_goods_used) ||
                !read_le(bytes, cursor, project.market_goods_used) ||
                !read_le(bytes, cursor, project.source_kind) ||
                !read_le(bytes, cursor, project.state) ||
                !read_le(bytes, cursor, cell_count) ||
                !read_le(bytes, cursor, edge_count) ||
                project.handle == 0 || project.generation == 0 ||
                project.country_handle == 0 || project.effective_day < 0 ||
                project.sequence < 0 || project.ready_day < project.effective_day ||
                project.effect_transaction_id < 0 || project.cash_paid < 0 ||
                project.treasury_goods_used < 0 || project.market_goods_used < 0 ||
                project.source_kind < CANAL_SOURCE_SALINE ||
                project.source_kind > CANAL_SOURCE_FRESHWATER ||
                project.state < CANAL_PROJECT_BUILDING ||
                project.state > CANAL_PROJECT_FAILED || cell_count > 33 ||
                edge_count > 32 ||
                ((project.state == CANAL_PROJECT_BUILDING ||
                  project.state == CANAL_PROJECT_AWAITING_EFFECT) &&
                 (cell_count < 2 || edge_count + 1 != cell_count)) ||
                ((project.state == CANAL_PROJECT_COMPLETED ||
                  project.state == CANAL_PROJECT_FAILED) &&
                 !((cell_count == 0 && edge_count == 0) ||
                   (cell_count >= 2 && edge_count + 1 == cell_count)))) {
                error = "save_canal_project_invalid";
                return false;
            }
            project.route_cells.resize(cell_count);
            project.route_edge_dirs.resize(edge_count);
            std::unordered_set<int32_t> unique_cells;
            for (int32_t &cell : project.route_cells) {
                if (!read_le(bytes, cursor, cell) || cell < 0 || cell >= _cell_count.get() ||
                    !unique_cells.emplace(cell).second) {
                    error = "save_canal_project_route_invalid"; return false;
                }
            }
            for (int32_t &dir : project.route_edge_dirs) {
                if (!read_le(bytes, cursor, dir) || dir < 0 || dir >= 6) {
                    error = "save_canal_project_route_invalid"; return false;
                }
            }
            if (!_canal_project_index.emplace(project.handle,
                    static_cast<int32_t>(_canal_projects.size())).second) {
                error = "save_canal_project_duplicate";
                return false;
            }
            _canal_projects.push_back(std::move(project));
            ++_restore.restored_canal_projects;
        }
        _restore.canal_projects_seen = true;
