    if (_save.section == SAVE_SECTION_COUNTRY_GOOD) {
        constexpr int32_t record_bytes = 112;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.country_good_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_country_good_trade.countries.size()),
            begin + max_records);
        for (; _save.country_good_cursor < end; ++_save.country_good_cursor) {
            const int32_t i = _save.country_good_cursor;
            append_le<int32_t>(payload, _country_good_trade.countries[i]);
            append_le<int32_t>(payload, _country_good_trade.goods[i]);
            append_le<int64_t>(payload, _country_good_trade.import_quantity[i]);
            append_le<int64_t>(payload, _country_good_trade.export_quantity[i]);
            append_le<int64_t>(payload, _country_good_trade.import_base[i]);
            append_le<int64_t>(payload, _country_good_trade.export_base[i]);
            append_le<int64_t>(payload, _country_good_trade.import_tariff[i]);
            append_le<int64_t>(payload, _country_good_trade.export_tariff[i]);
            append_le<int64_t>(payload, _country_good_trade.batch_epoch[i]);
            append_le<int64_t>(payload,
                _country_good_trade.batch_import_quantity[i]);
            append_le<int64_t>(payload,
                _country_good_trade.batch_export_quantity[i]);
            append_le<int64_t>(payload,
                _country_good_trade.batch_import_base[i]);
            append_le<int64_t>(payload,
                _country_good_trade.batch_export_base[i]);
            append_le<int64_t>(payload,
                _country_good_trade.batch_import_tariff[i]);
            append_le<int64_t>(payload,
                _country_good_trade.batch_export_tariff[i]);
        }
        if (_save.country_good_cursor >= static_cast<int32_t>(
                _country_good_trade.countries.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_COUNTRY_GOOD,
            static_cast<uint32_t>(_save.country_good_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_COUNTRY_PARTNER) {
        constexpr int32_t record_bytes = 96;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.country_partner_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_country_partner_trade.countries.size()),
            begin + max_records);
        for (; _save.country_partner_cursor < end; ++_save.country_partner_cursor) {
            const int32_t i = _save.country_partner_cursor;
            append_le<int32_t>(payload, _country_partner_trade.countries[i]);
            append_le<int32_t>(payload, _country_partner_trade.partners[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.import_quantity[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.export_quantity[i]);
            append_le<int64_t>(payload, _country_partner_trade.import_base[i]);
            append_le<int64_t>(payload, _country_partner_trade.export_base[i]);
            append_le<int64_t>(payload, _country_partner_trade.order_count[i]);
            append_le<int64_t>(payload, _country_partner_trade.batch_epoch[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.batch_import_quantity[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.batch_export_quantity[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.batch_import_base[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.batch_export_base[i]);
            append_le<int64_t>(payload,
                _country_partner_trade.batch_order_count[i]);
        }
        if (_save.country_partner_cursor >= static_cast<int32_t>(
                _country_partner_trade.countries.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_COUNTRY_PARTNER,
            static_cast<uint32_t>(_save.country_partner_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CANAL_QUOTES) {
        const int32_t begin = _save.canal_quote_cursor;
        while (_save.canal_quote_cursor < static_cast<int32_t>(_canal_quotes.size())) {
            const CanalQuote &quote = _canal_quotes[static_cast<size_t>(
                _save.canal_quote_cursor)];
            const size_t record_bytes = 106U +
                quote.route_cells.size() * sizeof(int32_t) +
                quote.route_edge_dirs.size() * sizeof(int32_t);
            if (_save.canal_quote_cursor > begin &&
                payload.size() + record_bytes > static_cast<size_t>(budget - 16))
                break;
            append_le<uint64_t>(payload, quote.token);
            append_le<uint64_t>(payload, quote.country_handle);
            append_le<int64_t>(payload, quote.snapshot_day);
            append_le<uint64_t>(payload, quote.topology_hash);
            append_le<uint64_t>(payload, quote.country_generation);
            append_le<uint64_t>(payload, quote.price_hash);
            append_le<uint8_t>(payload, quote.source_kind);
            append_le<int32_t>(payload, quote.new_edge_count);
            append_le<int32_t>(payload, quote.reused_edge_count);
            append_le<int32_t>(payload, quote.construction_days);
            append_le<int64_t>(payload, quote.cash_required);
            for (int32_t value : quote.material_good_ids)
                append_le<int32_t>(payload, value);
            for (int64_t value : quote.material_quantities)
                append_le<int64_t>(payload, value);
            append_le<uint8_t>(payload,
                _canal_quote_index.find(quote.token) != _canal_quote_index.end() ? 1 : 0);
            append_le<uint32_t>(payload,
                static_cast<uint32_t>(quote.route_cells.size()));
            append_le<uint32_t>(payload,
                static_cast<uint32_t>(quote.route_edge_dirs.size()));
            for (int32_t cell : quote.route_cells) append_le<int32_t>(payload, cell);
            for (int32_t dir : quote.route_edge_dirs) append_le<int32_t>(payload, dir);
            ++_save.canal_quote_cursor;
        }
        if (_save.canal_quote_cursor >= static_cast<int32_t>(_canal_quotes.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_CANAL_QUOTES,
            static_cast<uint32_t>(_save.canal_quote_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CANAL_PROJECTS) {
        const int32_t begin = _save.canal_project_cursor;
        while (_save.canal_project_cursor < static_cast<int32_t>(_canal_projects.size())) {
            const CanalProject &project = _canal_projects[static_cast<size_t>(
                _save.canal_project_cursor)];
            const size_t record_bytes = 103U +
                project.route_cells.size() * sizeof(int32_t) +
                project.route_edge_dirs.size() * sizeof(int32_t);
            if (_save.canal_project_cursor > begin &&
                payload.size() + record_bytes > static_cast<size_t>(budget - 16))
                break;
            append_le<uint64_t>(payload, project.handle);
            append_le<uint32_t>(payload, project.generation);
            append_le<uint64_t>(payload, project.country_handle);
            append_le<int64_t>(payload, project.effective_day);
            append_le<int64_t>(payload, project.sequence);
            append_le<int64_t>(payload, project.ready_day);
            append_le<int64_t>(payload, project.effect_transaction_id);
            append_le<uint64_t>(payload, project.topology_hash);
            append_le<int64_t>(payload, project.cash_paid);
            append_le<int64_t>(payload, project.treasury_goods_used);
            append_le<int64_t>(payload, project.market_goods_used);
            append_le<uint8_t>(payload, project.source_kind);
            append_le<uint8_t>(payload, project.state);
            append_le<uint32_t>(payload,
                static_cast<uint32_t>(project.route_cells.size()));
            append_le<uint32_t>(payload,
                static_cast<uint32_t>(project.route_edge_dirs.size()));
            for (int32_t cell : project.route_cells) append_le<int32_t>(payload, cell);
            for (int32_t dir : project.route_edge_dirs) append_le<int32_t>(payload, dir);
            ++_save.canal_project_cursor;
        }
        if (_save.canal_project_cursor >= static_cast<int32_t>(_canal_projects.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_CANAL_PROJECTS,
            static_cast<uint32_t>(_save.canal_project_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_PRICE_CEILINGS) {
        uint32_t records = 0;
        while (_save.ceiling_market_cursor < market_store().market_count.get()) {
            const auto &row = market_store().price_ceilings[_save.ceiling_market_cursor];
            if (_save.ceiling_row_cursor >= static_cast<int32_t>(row.size())) {
                ++_save.ceiling_market_cursor; _save.ceiling_row_cursor = 0; continue;
            }
            if (records > 0 && payload.size() + 14 > static_cast<size_t>(budget - 16)) break;
            const auto &state = row[_save.ceiling_row_cursor++];
            append_le<int32_t>(payload, _save.ceiling_market_cursor);
            append_le<int32_t>(payload, state.good);
            append_le<int32_t>(payload, state.limit);
            append_le<uint16_t>(payload, state.confirmation_days);
            ++records;
        }
        if (_save.ceiling_market_cursor >= market_store().market_count.get()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_PRICE_CEILINGS, records, payload);
    }
    if (_save.section == SAVE_SECTION_FISCAL_PEER) {
        std::vector<uint64_t> request_ids;
        request_ids.reserve(_asset_peer_journal.size());
        for (const auto &entry : _asset_peer_journal)
            request_ids.push_back(entry.first);
        std::sort(request_ids.begin(), request_ids.end());
        const int32_t begin = _save.fiscal_peer_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(request_ids.size()),
            begin + std::max(1, (budget - 16) / 176));
        for (; _save.fiscal_peer_cursor < end; ++_save.fiscal_peer_cursor) {
            const auto &record = _asset_peer_journal.at(request_ids[
                static_cast<size_t>(_save.fiscal_peer_cursor)]);
            append_le<uint64_t>(payload, record.request_id);
            append_le<uint64_t>(payload, record.transaction_id);
            append_le<uint64_t>(payload, record.country_handle);
            append_le<uint64_t>(payload, record.country_generation);
            append_le<uint64_t>(payload, record.peer_generation);
            append_le<uint64_t>(payload, record.committed_peer_generation);
            append_le<int64_t>(payload, record.day);
            append_le<uint64_t>(payload, record.operation_sequence);
            append_le<uint32_t>(payload, record.continuation_index);
            append_le<int32_t>(payload, record.country_slot);
            append_le<uint16_t>(payload, static_cast<uint16_t>(record.operation));
            append_le<uint8_t>(payload, static_cast<uint8_t>(record.result_code));
            append_le<uint8_t>(payload, static_cast<uint8_t>(record.state));
            append_le<uint8_t>(payload, record.accepted);
            append_le<uint8_t>(payload, 0);
            append_le<uint16_t>(payload, 0);
            append_le<int64_t>(payload, record.requested_quantity);
            append_le<int64_t>(payload, record.requested_cash);
            append_le<int64_t>(payload, record.committed_quantity);
            append_le<int64_t>(payload, record.committed_cash);
            for (const char value : record.reason)
                append_le<uint8_t>(payload, static_cast<uint8_t>(value));
        }
        if (_save.fiscal_peer_cursor >= static_cast<int32_t>(request_ids.size()))
            _save.section = SAVE_SECTION_RESOURCE_STOCK;
        return make_save_chunk(SAVE_SECTION_FISCAL_PEER,
            static_cast<uint32_t>(_save.fiscal_peer_cursor - begin), payload);
    }
