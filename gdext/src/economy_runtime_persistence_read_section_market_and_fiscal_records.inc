    } else if (section == SAVE_SECTION_PRICE_CEILINGS) {
        if (_restore.restored_ceilings + records > _restore.expected_ceilings) {
            error = "save_price_ceiling_count_invalid"; return false;
        }
        for (uint32_t i = 0; i < records; ++i) {
            int32_t market = -1;
            PriceCeilingState state;
            if (!read_le(bytes, cursor, market) || !read_le(bytes, cursor, state.good) ||
                !read_le(bytes, cursor, state.limit) || !read_le(bytes, cursor, state.confirmation_days) ||
                market < 0 || market >= market_store().market_count.get() || state.good < 0 ||
                state.good >= market_store().good_count.get() || state.limit < 1 ||
                state.confirmation_days > _price_ceiling_confirm_days.get()) {
                error = "save_price_ceiling_record_invalid"; return false;
            }
            const int64_t key = int64_t(market) * market_store().good_count.get() + state.good;
            if (key <= _restore.last_ceiling_key) {
                error = "save_price_ceiling_order_invalid"; return false;
            }
            _restore.last_ceiling_key = key;
            auto ceiling_write = market_store().price_ceilings.edit_row(market);
            ceiling_write[0].push_back(state);
            ++_restore.restored_ceilings;
        }
        _restore.ceilings_seen = true;
    } else if (schema >= 52 && section == SAVE_SECTION_FISCAL_PEER) {
        if (_restore.expected_fiscal_peer < 0 ||
            _restore.restored_fiscal_peer + static_cast<int64_t>(records) >
                _restore.expected_fiscal_peer) {
            error = "save_fiscal_peer_record_count_invalid";
            return false;
        }
        for (uint32_t i = 0; i < records; ++i) {
            NativeEconomyRuntime::FiscalPeerJournalRecord record;
            uint16_t operation = 0;
            uint8_t result_code = 0, state = 0, reserved0 = 0;
            uint16_t reserved1 = 0;
            if (!read_le(bytes, cursor, record.request_id) ||
                !read_le(bytes, cursor, record.transaction_id) ||
                !read_le(bytes, cursor, record.country_handle) ||
                !read_le(bytes, cursor, record.country_generation) ||
                !read_le(bytes, cursor, record.peer_generation) ||
                !read_le(bytes, cursor, record.committed_peer_generation) ||
                !read_le(bytes, cursor, record.day) ||
                !read_le(bytes, cursor, record.operation_sequence) ||
                !read_le(bytes, cursor, record.continuation_index) ||
                !read_le(bytes, cursor, record.country_slot) ||
                !read_le(bytes, cursor, operation) ||
                !read_le(bytes, cursor, result_code) ||
                !read_le(bytes, cursor, state) ||
                !read_le(bytes, cursor, record.accepted) ||
                !read_le(bytes, cursor, reserved0) ||
                !read_le(bytes, cursor, reserved1) ||
                !read_le(bytes, cursor, record.requested_quantity) ||
                !read_le(bytes, cursor, record.requested_cash) ||
                !read_le(bytes, cursor, record.committed_quantity) ||
                !read_le(bytes, cursor, record.committed_cash)) {
                error = "save_fiscal_peer_record_truncated";
                return false;
            }
            for (char &value : record.reason) {
                uint8_t byte = 0;
                if (!read_le(bytes, cursor, byte)) {
                    error = "save_fiscal_peer_record_truncated";
                    return false;
                }
                value = static_cast<char>(byte);
            }
            record.operation = static_cast<RuntimeEconomyAssetOperation>(operation);
            record.result_code = static_cast<RuntimeEconomyAssetResultCode>(result_code);
            record.state = static_cast<RuntimeEconomyAssetState>(state);
            record.effective_day = record.day;
            record.sequence = record.operation_sequence;
            record.reservation_state = runtime_d7_reservation_state_from_asset(
                record.state, record.result_code, record.reason.data());
            record.terminal_result = runtime_d7_terminal_result_from_asset(
                record.result_code, record.state, record.reason.data());
            record.retry_identity = record.request_id ^
                (static_cast<uint64_t>(record.continuation_index) << 1);
            if (record.result_code == RuntimeEconomyAssetResultCode::REJECTED &&
                runtime_d7_reason_is_stale_reject(record.reason.data())) {
                record.late_ack_rejection_reason = record.reason;
            }
            const char *record_defect = nullptr;
            // Goods-only treasury/market transfers (cash=0) commit zero cash.
            // Older saves journaled the goods quantity in the cash lane too;
            // accept that legacy shape but clear it below so a replayed
            // terminal never debits treasury cash by a goods count.
            const bool goods_only_transfer =
                record.requested_cash == 0 &&
                (record.operation == RuntimeEconomyAssetOperation::TREASURY_SPEND ||
                 record.operation == RuntimeEconomyAssetOperation::GOOD_TO_MARKET ||
                 record.operation == RuntimeEconomyAssetOperation::GOOD_FROM_MARKET);
            const int64_t requested_cash_limit = goods_only_transfer
                ? record.requested_quantity : record.requested_cash;
            if (record.request_id == 0 || record.transaction_id == 0)
                record_defect = "identity";
            else if (record.country_handle == 0) record_defect = "country_handle";
            // Only the lower bound is checkable here. The Country epoch the
            // upper bound refers to is captured in end_restore, after every
            // section is read; at this point the restore target has just been
            // reset to zero countries, so an upper-bound check rejected every
            // save that carried a completed fiscal transaction (any save made
            // with a non-zero tax). end_restore validates the upper bound.
            else if (record.country_slot < -1)
                record_defect = "country_slot";
            else if (record.committed_peer_generation < record.peer_generation)
                record_defect = "peer_generation";
            else if (record.day < -1) record_defect = "day";
            else if (record.operation < RuntimeEconomyAssetOperation::RESEARCH_PURCHASE ||
                     record.operation > RuntimeEconomyAssetOperation::TREASURY_SPEND)
                record_defect = "operation";
            else if ((record.result_code != RuntimeEconomyAssetResultCode::COMPLETED &&
                      record.result_code != RuntimeEconomyAssetResultCode::REJECTED) ||
                     (record.state != RuntimeEconomyAssetState::COMPLETED &&
                      record.state != RuntimeEconomyAssetState::REJECTED))
                record_defect = "not_terminal";
            else if (record.accepted > 1 || record.requested_quantity < 0 ||
                     record.requested_cash < 0 || record.committed_quantity < 0 ||
                     record.committed_cash < 0 ||
                     record.committed_quantity > record.requested_quantity ||
                     record.committed_cash > requested_cash_limit ||
                     (goods_only_transfer && record.committed_cash != 0 &&
                      record.committed_cash != record.committed_quantity))
                record_defect = "amounts";
            else if (reserved0 != 0 || reserved1 != 0) record_defect = "reserved";
            if (record_defect != nullptr) {
                error = std::string("save_fiscal_peer_record_invalid:") + record_defect;
                return false;
            }
            if (goods_only_transfer) record.committed_cash = 0;
            if (record.result_code == RuntimeEconomyAssetResultCode::COMPLETED) {
                const char *completed_defect =
                    record.accepted == 0 ? "not_accepted" :
                    record.country_slot < 0 ? "country_slot" :
                    record.country_generation == 0 ? "country_generation" :
                    record.peer_generation == 0 ? "peer_generation" :
                    record.committed_quantity <= 0 ? "committed_quantity" :
                    (!goods_only_transfer && record.committed_cash <= 0)
                        ? "committed_cash" : nullptr;
                if (completed_defect != nullptr) {
                    error = std::string("save_fiscal_peer_completed_record_invalid:") +
                        completed_defect + ":op" +
                        std::to_string(static_cast<int>(record.operation));
                    return false;
                }
            }
            if (!_asset_peer_journal.emplace(record.request_id, record).second) {
                error = "save_fiscal_peer_duplicate";
                return false;
            }
            _fiscal_digest_rebuild = true;
            ++_restore.restored_fiscal_peer;
        }
        _restore.fiscal_peer_seen = true;
    } else if (schema >= 52 && section == SAVE_SECTION_RESOURCE_STOCK) {
        if (!_restore.resource_stock_seen) {
            // An empty section means the save carried no resource rows at all.
            if (records == 0)
                _restore.expected_resource_rows = 0;
            const size_t rows = static_cast<size_t>(
                std::max<int64_t>(0, _restore.expected_resource_rows));
            resource_stock_lanes().assign(rows, 0);
            resource_lane_generation_lanes().assign(rows, 0);
            _restore.resource_stock_seen = true;
        }
        for (uint32_t i = 0; i < records; ++i) {
            int32_t resource = -1;
            int32_t cell = -1;
            int64_t stock = 0;
            uint32_t generation = 0;
            if (!read_le(bytes, cursor, resource) || !read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, stock) || !read_le(bytes, cursor, generation) ||
                resource < 0 || resource >= static_cast<int32_t>(_resource_ids.size()) ||
                cell < 0 || cell >= _cell_count.get() || stock < 0) {
                error = "save_resource_stock_record_invalid";
                return false;
            }
            const int64_t key = static_cast<int64_t>(resource) * _cell_count.get() + cell;
            if (key <= _restore.last_resource_key ||
                key >= static_cast<int64_t>(resource_stock_lanes().size())) {
                error = "save_resource_stock_order_invalid";
                return false;
            }
            _restore.last_resource_key = key;
            resource_stock_lanes().write_scalar(static_cast<size_t>(key), stock);
            resource_lane_generation_lanes()[static_cast<size_t>(key)] = generation;
            ++_restore.restored_resource_rows;
        }
    } else if (schema >= 52 && section == SAVE_SECTION_CADENCE_STATE) {
        if (!_restore.cadence_state_seen) {
            _cell_tier.assign(static_cast<size_t>(_cell_count.get()), 1);
            _cell_next_review_day.assign(static_cast<size_t>(_cell_count.get()), 0);
            _cell_force_wake.assign(static_cast<size_t>(_cell_count.get()), 0);
            _cell_tier_seen_gen.assign(static_cast<size_t>(_cell_count.get()), 0);
            _cell_tier_seen_population.assign(static_cast<size_t>(_cell_count.get()), -1);
            _cell_tier_change_day.assign(static_cast<size_t>(_cell_count.get()),
                                         _last_committed_day.get());
            _cell_shortage_since_day.assign(static_cast<size_t>(_cell_count.get()), -1);
            _restore.cadence_state_seen = true;
        }
        for (uint32_t i = 0; i < records; ++i) {
            int32_t cell = -1;
            uint8_t tier = 0, force_wake = 0;
            int64_t next_review = 0, seen_population = 0,
                    change_day = 0, shortage_since = 0;
            int32_t effect_shortage = 0, essentials_shortage = 0;
            uint32_t seen_gen = 0;
            if (!read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, tier) ||
                !read_le(bytes, cursor, next_review) ||
                !read_le(bytes, cursor, force_wake) ||
                !read_le(bytes, cursor, seen_gen) ||
                !read_le(bytes, cursor, seen_population) ||
                !read_le(bytes, cursor, change_day) ||
                !read_le(bytes, cursor, shortage_since) ||
                !read_le(bytes, cursor, effect_shortage) ||
                !read_le(bytes, cursor, essentials_shortage) ||
                cell < 0 || cell >= _cell_count.get() || tier > 3 || force_wake > 1 ||
                effect_shortage < 0 || essentials_shortage < 0 ||
                cell != _restore.restored_cadence_cells) {
                error = "save_cadence_state_record_invalid";
                return false;
            }
            const size_t index = static_cast<size_t>(cell);
            _cell_tier.write_scalar(index, tier, market_mutation_sink());
            _cell_next_review_day.write_scalar(index, next_review, market_mutation_sink());
            _cell_force_wake.write_scalar(index, force_wake, market_mutation_sink());
            _cell_tier_seen_gen.write_scalar(index, seen_gen, market_mutation_sink());
            _cell_tier_seen_population.write_scalar(index, seen_population, market_mutation_sink());
            _cell_tier_change_day.write_scalar(index, change_day, market_mutation_sink());
            _cell_shortage_since_day.write_scalar(index, shortage_since, market_mutation_sink());
            _cell_effect_shortage_q16.write_scalar(index, effect_shortage, market_mutation_sink());
            _cell_essentials_shortage_q16.write_scalar(index, essentials_shortage, market_mutation_sink());
            ++_restore.restored_cadence_cells;
        }
        if (cursor < bytes.size()) {
            uint64_t generation = 0;
            if (_restore.committed_generation_seen || !read_cadence_footer(
                    bytes, cursor, _cell_count.get(), generation,
                    _restore.track_b_investment_cells_pending,
                    _restore.track_b_derived_cell_cache_day,
                    _restore.track_b_derived_cell_cache,
                    _restore.military_ration_cells, _restore.military_ration_q16)) {
                error = "save_cadence_generation_footer_invalid";
                return false;
            }
            _restore.committed_generation_seen = true;
            _restore.restored_committed_generation = generation;
        }
    } else if (schema >= 53 && section == SAVE_SECTION_D7_PEER_EXT) {
        if (_restore.expected_d7_peer_ext < 0 ||
            _restore.restored_d7_peer_ext + static_cast<int64_t>(records) >
                _restore.expected_d7_peer_ext) {
            error = "save_d7_peer_ext_record_count_invalid";
            return false;
        }
        for (uint32_t i = 0; i < records; ++i) {
            uint64_t request_id = 0;
            uint64_t transaction_id = 0;
            uint64_t session_epoch = 0;
            uint32_t source_domain = 0;
            uint32_t target_domain = 0;
            int64_t effective_day = -1;
            uint64_t sequence = 0;
            uint8_t reservation_state = 0;
            uint8_t terminal_result = 0;
            uint16_t reserved = 0;
            uint64_t retry_identity = 0;
            uint64_t state_hash_before = 0;
            uint64_t state_hash_after = 0;
            std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> late_reason{};
            if (!read_le(bytes, cursor, request_id) ||
                !read_le(bytes, cursor, transaction_id) ||
                !read_le(bytes, cursor, session_epoch) ||
                !read_le(bytes, cursor, source_domain) ||
                !read_le(bytes, cursor, target_domain) ||
                !read_le(bytes, cursor, effective_day) ||
                !read_le(bytes, cursor, sequence) ||
                !read_le(bytes, cursor, reservation_state) ||
                !read_le(bytes, cursor, terminal_result) ||
                !read_le(bytes, cursor, reserved) ||
                !read_le(bytes, cursor, retry_identity) ||
                reserved != 0) {
                error = "save_d7_peer_ext_record_truncated";
                return false;
            }
            for (char &value : late_reason) {
                uint8_t byte = 0;
                if (!read_le(bytes, cursor, byte)) {
                    error = "save_d7_peer_ext_record_truncated";
                    return false;
                }
                value = static_cast<char>(byte);
            }
            if (!read_le(bytes, cursor, state_hash_before) ||
                !read_le(bytes, cursor, state_hash_after) ||
                request_id == 0 || transaction_id == 0) {
                error = "save_d7_peer_ext_record_invalid";
                return false;
            }
            const auto journal = _asset_peer_journal.find(request_id);
            if (journal == _asset_peer_journal.end()) {
                error = "save_d7_peer_ext_missing_base";
                return false;
            }
            if (journal->second.transaction_id != transaction_id) {
                error = "save_d7_peer_ext_transaction_mismatch";
                return false;
            }
            auto journal_write = _asset_peer_journal.edit(request_id);
            auto &journal_record = journal_write.get();
            journal_record.session_epoch = session_epoch;
            journal_record.source_domain = source_domain;
            journal_record.target_domain = target_domain;
            journal_record.effective_day = effective_day;
            journal_record.sequence = sequence;
            journal_record.reservation_state =
                static_cast<RuntimeD7ReservationState>(reservation_state);
            journal_record.terminal_result =
                static_cast<RuntimeD7TerminalResult>(terminal_result);
            journal_record.retry_identity = retry_identity;
            journal_record.late_ack_rejection_reason = late_reason;
            journal_record.state_hash_before = state_hash_before;
            journal_record.state_hash_after = state_hash_after;
            _fiscal_digest_rebuild = true;
            ++_restore.restored_d7_peer_ext;
        }
        _restore.d7_peer_ext_seen = true;
