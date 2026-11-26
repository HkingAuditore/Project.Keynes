    if (_save.section == SAVE_SECTION_HEADER) {
        append_le<int32_t>(payload, _cell_count.get());
        append_le<int32_t>(payload, market_store().market_count.get());
        append_le<int32_t>(payload, market_store().good_count.get());
        append_le<int32_t>(payload, static_cast<int32_t>(population_store().page_next.size()));
        append_le<int64_t>(payload, population_store().active_count);
        append_le<int32_t>(payload, _epoch_days.get());
        append_le<int64_t>(payload, _last_committed_day.get());
        append_le<int64_t>(payload, _epoch_id.get());
        append_le<int32_t>(payload, CountryApi::SCHEMA_VERSION);
        append_le<uint64_t>(payload, _save_country_identity_override
            ? _save_country_generation : country_reads().generation());
        append_le<uint64_t>(payload, _save_country_identity_override
            ? _save_country_state_hash
            : static_cast<uint64_t>(country_reads().state_hash()));
        append_le<int64_t>(payload, _seed.get());
        append_le<int64_t>(payload, _catalog_hash.get());
        append_le<int64_t>(payload, _building_catalog_hash.get());
        append_le<int32_t>(payload, static_cast<int32_t>(building_count()));
        append_le<int32_t>(payload, static_cast<int32_t>(pending_construction_count()));
        append_le<int64_t>(payload, _environment_day.get());
        append_le<int64_t>(payload, _environment_hash.get());
        append_le<uint64_t>(payload, _next_submit_order.get());
        append_le<int64_t>(payload, MONEY_SCALE);
        append_le<int64_t>(payload, GOODS_SCALE);
        append_le<int64_t>(payload, Q16_ONE);
        append_le<int64_t>(payload, Q32_ONE);
        append_le<int32_t>(payload, static_cast<int32_t>(_pending_commands.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_audit_history.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_market_signals.good_ids.size()));
        append_le<int32_t>(payload,
                           static_cast<int32_t>(_labor_signals.profession_ids.size()));
        append_le<int64_t>(payload, _next_event_id.get());
        append_le<uint64_t>(payload, _event_stream_hash.get());
        append_le<int32_t>(payload, trade_orders_store().size());
        append_le<int32_t>(payload, static_cast<int32_t>(_trade_flows.cells.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(
            _tariff_history.countries.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(
            _country_good_trade.countries.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(
            _country_partner_trade.countries.size()));
        append_le<uint64_t>(payload, _country_trade_revision.get());
        append_le<int64_t>(payload, trade_orders_store().next_id);
        append_le<int32_t>(payload, _trade_runtime_mode.get());
        append_le<int64_t>(payload, _trade_capacity_per_merchant_q16.get());
        append_le<int32_t>(payload, _trade_speed_cost_per_day.get());
        append_le<int32_t>(payload, _trade_min_margin_q16.get());
        append_le<int32_t>(payload, _trade_target_count.get());
        append_le<int32_t>(payload, _trade_signal_pairs_per_slice.get());
        append_le<int32_t>(payload, _trade_route_searches_per_slice.get());
        append_le<int32_t>(payload, _trade_max_route_expansions.get());
        append_le<int32_t>(payload, _trade_route_cache_entries.get());
        append_le<int32_t>(payload, _trade_max_signals.get());
        append_le<int32_t>(payload, _trade_max_candidates.get());
        append_le<int32_t>(payload, _trade_max_orders.get());
        append_le<int32_t>(payload, _trade_flow_ema_alpha_q16.get());
        append_le<int32_t>(payload, _trade_max_stock_share_q16.get());
        append_le<int32_t>(payload, _building_severe_loss_threshold_q16.get());
        append_le<int32_t>(payload, _building_severe_loss_cycles.get());
        append_le<int32_t>(payload, _building_restart_margin_q16.get());
        append_le<int32_t>(payload, _building_restart_cycles.get());
        append_le<int32_t>(payload, _merchant_procurement_cash_reserve_q16.get());
        append_le<int32_t>(payload, _merchant_market_making_days_q16.get());
        append_le<int32_t>(payload, _merchant_credit_runtime_mode.get());
        append_le<int32_t>(payload, _merchant_credit_exposure_q16.get());
        append_le<int32_t>(payload, _merchant_credit_premium_q16.get());
        append_le<int32_t>(payload, _merchant_credit_term_cycles.get());
        append_le<int32_t>(payload, _recovery_success_cycles.get());
        append_le<int32_t>(payload, _recovery_liquidation_failed_reviews.get());
        append_le<int32_t>(payload, _trade_export_floor_days.get());
        append_le<int32_t>(payload, _trade_export_inventory_fraction_q16.get());
        append_le<int32_t>(payload, _trade_import_fill_fraction_q16.get());
        append_le<int32_t>(payload, _trade_response_days.get());
        append_le<int32_t>(payload, _investment_review_days.get());
        append_le<int32_t>(payload, _investment_min_shortage_q16.get());
        append_le<int32_t>(payload, _investment_min_utilization_q16.get());
        append_le<int32_t>(payload, _investment_max_payback_days.get());
        append_le<int32_t>(payload, _investment_operating_cycles.get());
        append_le<int32_t>(payload, _investment_gap_fill_share_q16.get());
        append_le<int32_t>(payload, _investment_portfolio_max_types.get());
        append_le<int32_t>(payload, _investment_max_type_owner_share_q16.get());
        append_le<int32_t>(payload, _investment_max_growth_share_q16.get());
        append_le<int32_t>(payload, _investment_new_type_seed_buildings.get());
        append_le<int32_t>(
            payload, _investment_merchant_transition_min_improvement_q16.get());
        append_le<int32_t>(payload, _recovery_liquidation_max_share_q16.get());
        append_le<int32_t>(payload, _resource_min_reserve_q16.get());
        append_le<int32_t>(payload, _resource_safe_harvest_q16.get());
        append_le<int32_t>(payload, _resource_min_horizon_days.get());
        append_le<int32_t>(payload, _bullion_monthly_issue_cap_q16.get());
        append_le<int32_t>(payload, _producer_support_monthly_cap_q16.get());
        append_le<int64_t>(payload, _government_research_procured_points.get());
        append_le<int64_t>(payload, _government_research_procurement_cash.get());
        append_le<int64_t>(payload, _government_research_procurement_orders.get());
        append_le<int64_t>(payload, _prosperity_profile_hash.get());
        append_le<int32_t>(payload, _building_plan_days.get());
        append_le<int64_t>(payload, _family_catalog_hash.get());
        append_le<int32_t>(payload, _family_runtime_mode.get());
        append_le<int32_t>(payload, static_cast<int32_t>(
            _family_min_founder_people.get()));
        append_le<int32_t>(payload, _family_review_days.get());
        append_le<int64_t>(payload, family_milestone_hash());
        append_le<int64_t>(payload, _family_split_population_threshold.get());
        append_le<int32_t>(payload, _family_max_per_cell.get());
        append_le<int32_t>(payload, _family_decline_reviews.get());
        append_le<int64_t>(payload, _person_catalog_hash.get());
        append_le<int32_t>(payload, _person_runtime_mode.get());
        append_le<int32_t>(payload, _person_max_per_family.get());
        append_le<int32_t>(payload, _person_max_per_cell.get());
        append_le<int32_t>(payload, _person_max_total.get());
        append_le<int32_t>(payload, _person_records_per_slice.get());
        append_le<int32_t>(payload,
            static_cast<int32_t>(persons_store().active.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(person_needs().size()));
        append_le<int32_t>(payload, _family_trait_catalog_version.get());
        append_le<int64_t>(payload, _family_trait_catalog_hash.get());
        append_le<int32_t>(payload,
            static_cast<int32_t>(family_trait_rolls().size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(family_influences().active.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(_family_trait_commands.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(family_expeditions_store().active.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(family_expeditions_store().active_count));
        append_le<int64_t>(payload, _next_family_expedition_stable_id.get());
        append_le<int64_t>(payload, _next_colonization_receipt_id.get());
        append_le<int32_t>(payload, static_cast<int32_t>(_canal_quotes.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_canal_projects.size()));
        append_le<uint64_t>(payload, _next_canal_quote_token.get());
        append_le<uint64_t>(payload, _next_canal_project_id.get());
        append_le<int64_t>(payload, _next_canal_receipt_id.get());
        append_le<int32_t>(payload, _locked_market_cycle_days.get());
        append_le<int64_t>(payload, _market_cycle_start_day.get());
        append_le<int32_t>(payload, _locked_slow_cycle_days.get());
        append_le<int64_t>(payload, _slow_cycle_start_day.get());
        append_le<int32_t>(payload, _locked_investment_cycle_days.get());
        append_le<int64_t>(payload, _investment_cycle_start_day.get());
        for (int32_t sector = 0; sector < 5; ++sector)
            append_le<int32_t>(payload, _maintenance_horizon_days_by_sector[sector]);
        append_le<int32_t>(payload, _building_maintenance_cost_factor_q16.get());
        append_le<int32_t>(payload, _startup_demand_runtime_mode.get());
        append_le<int32_t>(payload, _price_ceiling_confirm_days.get());
        append_le<int32_t>(payload, _price_ceiling_expand_bp.get());
        append_le<int32_t>(payload, _price_ceiling_recover_bp.get());
        append_le<int64_t>(payload, price_ceiling_state_count());
        append_le<int32_t>(payload, static_cast<int32_t>(
            _asset_peer_journal.size()));
        append_id_table(payload, _profession_ids);
        append_id_table(payload, _ethnicity_ids);
        append_id_table(payload, _good_ids);
        append_id_table(payload, _plan_ids);
        ++_save.section;
        return make_save_chunk(SAVE_SECTION_HEADER, 1, payload);
    }
    if (_save.section == SAVE_SECTION_PAGES) {
        // 79 bytes of pre-v30 lane state plus 43 bytes of composite satisfaction
        // and fiscal-burden columns.
        const int32_t record_bytes = 12 + COHORT_PAGE_SIZE * 122;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(population_store().page_next.size()),
                                              _save.page_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.page_cursor)) * record_bytes);
        const int32_t begin = _save.page_cursor;
        for (; _save.page_cursor < end; ++_save.page_cursor) {
            const int32_t page = _save.page_cursor;
            append_le<int32_t>(payload, page);
            append_le<int32_t>(payload, population_store().page_next[page]);
            append_le<int32_t>(payload, population_store().page_cell[page]);
            const int32_t base = page * COHORT_PAGE_SIZE;
            for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                append_le<uint8_t>(payload, population_store().active[slot]);
                append_le<uint32_t>(payload, population_store().signature_id[slot]);
                append_le<uint32_t>(payload, population_store().generation[slot]);
                append_le<int64_t>(payload, population_store().population[slot]);
                append_le<int64_t>(payload, population_store().funds[slot]);
                append_le<int64_t>(payload, population_store().epoch_income[slot]);
                append_le<int64_t>(payload, population_store().epoch_expense[slot]);
                append_le<int64_t>(payload, population_store().income_ema[slot]);
                append_le<uint16_t>(payload, population_store().needs_satisfaction[slot]);
                append_le<uint16_t>(payload, population_store().worst_need_id[slot]);
                append_le<uint16_t>(payload, population_store().flags[slot]);
                append_le<int64_t>(payload, population_store().demography_residual[slot]);
                append_le<int64_t>(payload, population_store().owner_employed[slot]);
                append_le<int64_t>(payload, population_store().employee_employed[slot]);
                append_le<uint16_t>(payload, population_store().composite_satisfaction[slot]);
                append_le<uint8_t>(payload, population_store().worst_dimension_id[slot]);
                const size_t dims_base = static_cast<size_t>(slot) *
                    static_cast<size_t>(SAT_DIM_COUNT);
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                    append_le<uint16_t>(payload,
                        population_store().satisfaction_dims[dims_base +
                                                      static_cast<size_t>(dim)]);
                append_le<int64_t>(payload, population_store().income_baseline_ema[slot]);
                append_le<int64_t>(payload, population_store().epoch_tax_paid[slot]);
                append_le<int64_t>(payload, population_store().epoch_subsidy_received[slot]);
            }
        }
        if (_save.page_cursor >= static_cast<int32_t>(population_store().page_next.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_PAGES,
                               static_cast<uint32_t>(_save.page_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_MARKETS) {
        const int32_t record_bytes = 4 + market_store().good_count.get() * 22;
        const int32_t max_records = std::max(1, (budget - 16) / std::max(1, record_bytes));
        const int32_t end = std::min(market_store().market_count.get(), _save.market_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.market_cursor)) * record_bytes);
        const int32_t begin = _save.market_cursor;
        if (bulk_little_endian_enabled()) {
            // 长度一次定形，保持原 market/good 交错记录和 LE 字节完全一致。
            payload.resize(static_cast<size_t>(end - begin) * record_bytes);
            uint8_t *cursor = payload.data();
            for (; _save.market_cursor < end; ++_save.market_cursor) {
                const int32_t market = _save.market_cursor;
                store_le(cursor, market); cursor += 4;
                const int64_t base = market_store().index(market, 0);
                for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
                    const int64_t idx = base + good;
                    store_le<int64_t>(cursor, market_store().stock[idx]); cursor += 8;
                    store_le<int32_t>(cursor, market_store().price[idx]); cursor += 4;
                    store_le<int64_t>(cursor, market_store().demand_ema[idx]); cursor += 8;
                    store_le<uint16_t>(cursor, market_store().last_shortage_q16[idx]); cursor += 2;
                }
            }
            if (_save.market_cursor >= market_store().market_count.get()) ++_save.section;
            return make_save_chunk(SAVE_SECTION_MARKETS,
                static_cast<uint32_t>(end - begin), payload);
        }
        for (; _save.market_cursor < end; ++_save.market_cursor) {
            const int32_t market = _save.market_cursor;
            append_le<int32_t>(payload, market);
            for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
                const int64_t idx = market_store().index(market, good);
                append_le<int64_t>(payload, market_store().stock[idx]);
                append_le<int32_t>(payload, market_store().price[idx]);
                append_le<int64_t>(payload, market_store().demand_ema[idx]);
                append_le<uint16_t>(payload, market_store().last_shortage_q16[idx]);
            }
        }
        if (_save.market_cursor >= market_store().market_count.get()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_MARKETS,
                               static_cast<uint32_t>(_save.market_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CELLS) {
        const int32_t record_bytes = 176 +
            static_cast<int32_t>(_ethnicity_ids.size()) * 8;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min(_cell_count.get(), _save.cell_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.cell_cursor)) * record_bytes);
        const int32_t begin = _save.cell_cursor;
        for (; _save.cell_cursor < end; ++_save.cell_cursor) {
            append_le<int32_t>(payload, _save.cell_cursor);
            append_le<int32_t>(payload, market_store().cell_to_market[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_temperature_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_temperature_30d_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_moisture_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_plant_available_water_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_precipitation_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_snow_q16[_save.cell_cursor]);
            append_le<int32_t>(payload, _environment_weather_q16[_save.cell_cursor]);
            append_le<int64_t>(payload, _cell_last_settlement_day[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_settlement_generation[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_price_stock_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_owner_cash_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_population_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_building_structure_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_technology_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_resource_gen[_save.cell_cursor]);
            append_le<uint32_t>(payload, _cell_trade_gen[_save.cell_cursor]);
            append_le<int32_t>(payload, (( _save.cell_cursor %
                std::max(1, locked_market_cycle_days())) +
                locked_market_cycle_days()) % locked_market_cycle_days());
            const size_t fiscal_cell = static_cast<size_t>(_save.cell_cursor);
            append_le<uint64_t>(payload,
                fiscal_cell < _fiscal_previous_country_handles.size()
                    ? _fiscal_previous_country_handles[fiscal_cell] : 0);
            for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
                const size_t lane =
                    fiscal_cell * ACTIVE_TAX_KIND_COUNT + kind;
                append_le<int64_t>(payload,
                    lane < _fiscal_previous_requests.size()
                        ? _fiscal_previous_requests[lane] : 0);
            }
            append_le<uint8_t>(payload,
                static_cast<uint8_t>(_settlements.tier[_save.cell_cursor] |
                    (_settlements.name_forced[_save.cell_cursor] != 0
                        ? 0x80U : 0U)));
            append_le<uint32_t>(payload,
                _settlements.prosperity_generation[_save.cell_cursor]);
            append_le<uint32_t>(payload,
                _settlements.name_roll_generation[_save.cell_cursor]);
            append_le<uint8_t>(payload,
                _cell_social_pressure_level[_save.cell_cursor]);
            const size_t birth_lane_begin =
                static_cast<size_t>(_save.cell_cursor) * _ethnicity_ids.size();
            for (size_t ethnicity = 0; ethnicity < _ethnicity_ids.size(); ++ethnicity)
                append_le<int64_t>(payload,
                    _birth_residual_q32[birth_lane_begin + ethnicity]);
            append_le<int32_t>(payload, _cell_support_ema_q16[_save.cell_cursor]);
            const size_t food_cell = static_cast<size_t>(_save.cell_cursor);
            append_le<uint8_t>(payload,
                food_cell < _cell_food_flow_valid.size()
                    ? _cell_food_flow_valid[food_cell] : 0);
            append_le<int64_t>(payload,
                food_cell < _cell_food_output_eq_previous.size()
                    ? _cell_food_output_eq_previous[food_cell] : 0);
            append_le<int64_t>(payload,
                food_cell < _cell_food_input_eq_previous.size()
                    ? _cell_food_input_eq_previous[food_cell] : 0);
            append_le<int64_t>(payload,
                food_cell < _cell_food_import_eq_previous.size()
                    ? _cell_food_import_eq_previous[food_cell] : 0);
            append_le<int64_t>(payload,
                food_cell < _cell_food_export_eq_previous.size()
                    ? _cell_food_export_eq_previous[food_cell] : 0);
            append_le<int64_t>(payload,
                food_cell < _cell_food_access_eq_previous.size()
                    ? _cell_food_access_eq_previous[food_cell] : 0);
            append_le<int32_t>(payload, _food_flow_previous_period_days.get());
            append_le<int32_t>(payload,
                food_cell < _cell_dry_streak_days.size()
                    ? _cell_dry_streak_days[food_cell] : 0);
            append_le<int32_t>(payload,
                food_cell < _cell_days_since_hazard.size()
                    ? _cell_days_since_hazard[food_cell] : 0);
            append_le<uint8_t>(payload,
                food_cell < _cell_previous_hazard_mask.size()
                    ? _cell_previous_hazard_mask[food_cell]
                    : 0);
        }
        if (_save.cell_cursor >= _cell_count.get()) ++_save.section;
        return make_save_chunk(SAVE_SECTION_CELLS,
                               static_cast<uint32_t>(_save.cell_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_COMMANDS) {
        constexpr int32_t record_bytes = 76;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_pending_commands.size()),
                                              _save.command_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.command_cursor)) * record_bytes);
        const int32_t begin = _save.command_cursor;
        for (; _save.command_cursor < end; ++_save.command_cursor) {
            const Command &cmd = _pending_commands[_save.command_cursor];
            append_le<int32_t>(payload, cmd.opcode);
            append_le<int64_t>(payload, cmd.effective_day);
            append_le<int64_t>(payload, cmd.sequence);
            append_le<uint64_t>(payload, cmd.target_handle);
            append_le<int32_t>(payload, cmd.i32_0);
            append_le<int32_t>(payload, cmd.i32_1);
            append_le<int64_t>(payload, cmd.i64_0);
            append_le<int64_t>(payload, cmd.i64_1);
            append_le<uint64_t>(payload, cmd.submit_order);
            append_le<int64_t>(payload, cmd.effect_request_id);
            append_le<uint64_t>(payload, cmd.opcode == COMMAND_START_FAMILY_EXPEDITION
                ? cmd.expedition_route_hash : cmd.effect_idempotency_key);
        }
        if (_save.command_cursor >= static_cast<int32_t>(_pending_commands.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_COMMANDS,
                               static_cast<uint32_t>(_save.command_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_BUILDINGS) {
        const int32_t max_records = std::max(1, (budget - 16) / 1024);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(building_count()),
                                              _save.building_cursor + max_records);
        const int32_t begin = _save.building_cursor;
        std::vector<std::pair<uint32_t, int64_t>> maintenance_exceptions;
        for (; _save.building_cursor < end; ++_save.building_cursor) {
            const auto group = building_view(static_cast<size_t>(_save.building_cursor));
            append_le<int32_t>(payload, group.cell);
            append_le<int32_t>(payload, group.type_id);
            append_le<int32_t>(payload, group.owner_signature_id);
            append_le<int64_t>(payload, group.count);
            append_le<int64_t>(payload, group.filled_owner);
            append_le<int64_t>(payload, group.last_capacity_q16);
            append_le<int64_t>(payload, group.last_temperature_fit_q16);
            append_le<int64_t>(payload, group.last_water_fit_q16);
            append_le<int64_t>(payload, group.last_climate_capacity_q16);
            append_le<int64_t>(payload, group.last_climate_lost_output);
            append_le<int64_t>(payload, group.last_input);
            append_le<int64_t>(payload, group.last_output);
            append_le<int64_t>(payload, group.last_sold);
            append_le<int64_t>(payload, group.last_discarded);
            append_le<int64_t>(payload, group.last_resource);
            append_le<int64_t>(payload, group.last_resource_generated);
            append_le<int64_t>(payload, group.last_revenue);
            append_le<int64_t>(payload, group.last_input_cost);
            append_le<int64_t>(payload, group.last_wages_paid);
            append_le<int64_t>(payload, group.last_wages_due);
            append_le<int64_t>(payload, group.last_expected_revenue);
            append_le<int64_t>(payload, group.last_operating_cost);
            append_le<int32_t>(payload, group.last_margin_gap_q16);
            append_le<int32_t>(payload, group.planned_utilization_q16);
            append_le<int64_t>(payload, group.last_base_wages_paid);
            append_le<int64_t>(payload, group.last_base_wages_due);
            append_le<int64_t>(payload, group.last_bonus_paid);
            append_le<int64_t>(payload, group.last_bonus_due);
            append_le<uint8_t>(payload, group.wage_suspended);
            append_le<int64_t>(payload, group.purchase_intent_capacity_q16);
            append_le<int32_t>(payload, group.realized_profit_margin_q16);
            append_le<uint16_t>(payload, group.severe_loss_cycles);
            append_le<uint16_t>(payload, group.recovery_cycles);
            // v35 never emits the retired RECOVERY_PROBE state or its
            // pending/cooldown lanes. Keep the fields in the binary record so
            // older readers remain structurally aligned, but serialize only
            // the two-state lifecycle and neutral compatibility values.
            append_le<uint8_t>(payload, std::min<uint8_t>(group.operating_state, 1));
            append_le<uint8_t>(payload,
                group.pending_operating_state <= 1 ? group.pending_operating_state : uint8_t{255});
            append_le<uint16_t>(payload, 0);
            append_le<uint16_t>(payload, group.recovery_failed_reviews);
            append_le<uint16_t>(payload, group.merchant_debt_term_cycles_left);
            append_le<uint16_t>(payload, group.merchant_debt_delinquent_cycles);
            append_le<int64_t>(payload, group.merchant_debt_principal);
            append_le<int64_t>(payload, group.merchant_debt_premium);
            append_le<int64_t>(payload, group.last_in_kind_livelihood_value);
            // v47 appends fact/quote diagnostics after the legacy business
            // payload so v41-v46 readers keep their role spans aligned.
            append_le<int64_t>(payload, group.last_market_receipt);
            append_le<int64_t>(payload, group.last_bullion_mint_receipt);
            append_le<int64_t>(payload, group.last_producer_support_receipt);
            append_le<int64_t>(payload, group.last_business_tax_paid);
            append_le<int64_t>(payload, group.last_business_subsidy_received);
            append_le<int64_t>(payload, group.last_maintenance_due);
            append_le<int64_t>(payload, group.last_observed_capacity_days_q16);
            append_le<int64_t>(payload, group.last_quoted_market_receipt);
            append_le<int64_t>(payload, group.last_quoted_operating_cost);
            if (group.last_maintenance_cost != maintenance_from_operating_cost(
                    group.last_operating_cost, group.last_input_cost, group.last_wages_due)) {
                maintenance_exceptions.emplace_back(
                    static_cast<uint32_t>(_save.building_cursor - begin),
                    group.last_maintenance_cost);
            }
            const int32_t roles = _building_types[group.type_id].employee_count;
            append_le<int32_t>(payload, roles);
            for (int32_t r = 0; r < roles; ++r) {
                const int32_t index = group.employee_fill_begin + r;
                append_le<int64_t>(payload, _building_employee_filled[index]);
                append_le<int64_t>(payload, _building_role_contract_wage[index]);
                append_le<int64_t>(payload, _building_role_base_living_cost[index]);
                append_le<int64_t>(payload, _building_role_living_cost[index]);
                append_le<int64_t>(payload, _building_role_local_average_wage[index]);
                append_le<int64_t>(payload, _building_role_base_wage_due[index]);
                append_le<int64_t>(payload, _building_role_base_wage_paid[index]);
                append_le<int64_t>(payload, _building_role_bonus_due[index]);
                append_le<int64_t>(payload, _building_role_bonus_paid[index]);
            }
        }
        // Keep a separate paid amount only when the settled total cannot be
        // inverted (for example, when the total saturated).
        for (const auto &[row, paid] : maintenance_exceptions) {
            append_le<uint32_t>(payload, row);
            append_le<int64_t>(payload, paid);
        }
        if (_save.building_cursor >= static_cast<int32_t>(building_count())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_BUILDINGS,
                               static_cast<uint32_t>(_save.building_cursor - begin), payload);
    }
