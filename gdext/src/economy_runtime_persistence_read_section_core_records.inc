    if (section == SAVE_SECTION_PAGES) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t page = -1, next = -1, cell = -1;
            if (!read_le(bytes, cursor, page) || !read_le(bytes, cursor, next) ||
                !read_le(bytes, cursor, cell) || page != _restore.restored_pages ||
                page < 0 || page >= _restore.expected_pages) {
                error = "save_page_record_invalid";
                return false;
            }
            population_store().page_next.write_scalar(page, next, market_mutation_sink());
            population_store().page_cell.write_scalar(page, cell, market_mutation_sink());
            const int32_t base = page * COHORT_PAGE_SIZE;
            for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                if (!read_column_le(bytes, cursor, population_store().active, slot) ||
                    !read_column_le(bytes, cursor, population_store().signature_id, slot) ||
                    !read_column_le(bytes, cursor, population_store().generation, slot) ||
                    !read_column_le(bytes, cursor, population_store().population, slot) ||
                    !read_column_le(bytes, cursor, population_store().funds, slot) ||
                    !read_column_le(bytes, cursor, population_store().epoch_income, slot) ||
                    !read_column_le(bytes, cursor, population_store().epoch_expense, slot) ||
                    !read_column_le(bytes, cursor, population_store().income_ema, slot) ||
                    !read_column_le(bytes, cursor, population_store().needs_satisfaction, slot) ||
                    !read_column_le(bytes, cursor, population_store().worst_need_id, slot) ||
                    !read_column_le(bytes, cursor, population_store().flags, slot) ||
                    !read_column_le(bytes, cursor, population_store().demography_residual, slot) ||
                    !read_column_le(bytes, cursor, population_store().owner_employed, slot) ||
                    !read_column_le(bytes, cursor, population_store().employee_employed, slot) ||
                    !read_column_le(bytes, cursor, population_store().composite_satisfaction, slot) ||
                    !read_column_le(bytes, cursor, population_store().worst_dimension_id, slot)) {
                    error = "save_page_payload_truncated";
                    return false;
                }
                const size_t dims_base = static_cast<size_t>(slot) *
                    static_cast<size_t>(SAT_DIM_COUNT);
                // satisfaction_dims 是 uint16_t（[0, 65535]），而合法值域上限恰好就是
                // Q16_ONE - 1 = 65535——两者重合，所以「>= Q16_ONE(65536)」这类范围检查
                // 对该存储类型永远不可能为真（也是 clang 在 web 构建里报
                // -Wtautological-constant-out-of-range-compare 的位置）。不是漏检：
                // 任何能从文件里读出来的比特模式已经天然落在合法区间，删掉判断不改变
                // 校验结果，只是去掉死代码。
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
                    if (!read_column_le(bytes, cursor, population_store().satisfaction_dims,
                                     dims_base + static_cast<size_t>(dim))) {
                        error = "save_page_payload_truncated";
                        return false;
                    }
                }
                if (!read_column_le(bytes, cursor, population_store().income_baseline_ema, slot) ||
                    !read_column_le(bytes, cursor, population_store().epoch_tax_paid, slot) ||
                    !read_column_le(bytes, cursor, population_store().epoch_subsidy_received, slot)) {
                    error = "save_page_payload_truncated";
                    return false;
                }
                // composite_satisfaction 同样是 uint16_t，见上方 satisfaction_dims 的
                // 注释——「>= Q16_ONE」对该类型恒假，不是遗漏的校验条件。
                if ((population_store().worst_dimension_id[slot] !=
                         std::numeric_limits<uint8_t>::max() &&
                     population_store().worst_dimension_id[slot] >= SAT_DIM_COUNT) ||
                    population_store().epoch_tax_paid[slot] < 0 ||
                    population_store().epoch_subsidy_received[slot] < 0) {
                    error = "save_page_satisfaction_state_out_of_range";
                    return false;
                }
            }
            ++_restore.restored_pages;
        }
    } else if (section == SAVE_SECTION_MARKETS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t market = -1;
            if (!read_le(bytes, cursor, market) || market != _restore.restored_markets ||
                market < 0 || market >= market_store().market_count.get()) {
                error = "save_market_record_invalid";
                return false;
            }
            for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
                const int64_t idx = market_store().index(market, good);
                int64_t stock = 0, demand = 0;
                int32_t price = 0;
                uint16_t shortage = 0;
                if (!read_le(bytes, cursor, stock) ||
                    !read_le(bytes, cursor, price) ||
                    !read_le(bytes, cursor, demand) ||
                    !read_le(bytes, cursor, shortage)) {
                    error = "save_market_payload_truncated";
                    return false;
                }
                market_store().stock.write_scalar(idx, stock);
                market_store().price.write_scalar(idx, price);
                market_store().demand_ema.write_scalar(idx, demand);
                market_store().last_shortage_q16.write_scalar(idx, shortage);
            }
            ++_restore.restored_markets;
        }
    } else if (section == SAVE_SECTION_CELLS) {
        for (uint32_t record = 0; record < records; ++record) {
            int32_t cell = -1, market = -1;
            if (!read_le(bytes, cursor, cell) || !read_le(bytes, cursor, market) ||
                cell != _restore.restored_cells || cell < 0 || cell >= _cell_count.get()) {
                error = "save_cell_market_record_invalid";
                return false;
            }
            if (!read_column_le(bytes, cursor, _environment_temperature_q16, cell) ||
                !read_column_le(bytes, cursor, _environment_temperature_30d_q16, cell) ||
                !read_column_le(bytes, cursor, _environment_moisture_q16, cell) ||
                !read_column_le(bytes, cursor, _environment_plant_available_water_q16, cell) ||
                !read_column_le(bytes, cursor, _environment_precipitation_q16, cell) ||
                !read_column_le(bytes, cursor, _environment_snow_q16, cell) ||
                !read_column_le(bytes, cursor, _environment_weather_q16, cell)) {
                error = "save_cell_environment_record_invalid";
                return false;
            }
            if (schema >= 15) {
                int32_t saved_phase = -1;
                const int32_t expected_phase = schema >= 38
                    ? ((cell % std::max(1, locked_market_cycle_days())) +
                        locked_market_cycle_days()) %
                        locked_market_cycle_days()
                    : cell % ROLLING_PHASE_COUNT;
                if (!read_column_le(bytes, cursor, _cell_last_settlement_day, cell) ||
                    !read_column_le(bytes, cursor, _cell_settlement_generation, cell) ||
                    !read_column_le(bytes, cursor, _cell_price_stock_gen, cell) ||
                    !read_column_le(bytes, cursor, _cell_owner_cash_gen, cell) ||
                    !read_column_le(bytes, cursor, _cell_population_gen, cell) ||
                    !read_column_le(bytes, cursor, _cell_building_structure_gen, cell) ||
                    !read_column_le(bytes, cursor, _cell_technology_gen, cell) ||
                    !read_column_le(bytes, cursor, _cell_resource_gen, cell) ||
                    !read_column_le(bytes, cursor, _cell_trade_gen, cell) ||
                    !read_le(bytes, cursor, saved_phase) ||
                    saved_phase != expected_phase) {
                    error = "save_cell_rolling_state_invalid";
                    return false;
                }
            }
            if (schema >= 23) {
                if (!read_column_le(bytes, cursor, _fiscal_previous_country_handles, cell)) {
                    error = "save_cell_fiscal_country_truncated";
                    return false;
                }
                for (int32_t kind = 0;
                     kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
                    const size_t lane = static_cast<size_t>(cell) *
                        ACTIVE_TAX_KIND_COUNT + kind;
                    if (!read_column_le(bytes, cursor, _fiscal_previous_requests, lane) ||
                        _fiscal_previous_requests[lane] < 0) {
                        error = "save_cell_fiscal_request_invalid";
                        return false;
                    }
                }
            }
            if (schema >= 24) {
                uint8_t tier_flags = 0;
                if (!read_le(bytes, cursor, tier_flags) ||
                    !read_column_le(bytes, cursor, _settlements.prosperity_generation, cell) ||
                    !read_column_le(bytes, cursor, _settlements.name_roll_generation, cell) ||
                    (tier_flags & 0x7fU) >= _prosperity_thresholds.size()) {
                    error = "save_cell_settlement_state_invalid";
                    return false;
                }
                _settlements.tier.write_scalar(cell, static_cast<uint8_t>(tier_flags & 0x7fU), market_mutation_sink());
                _settlements.name_forced.write_scalar(cell, (tier_flags & 0x80U) != 0 ? 1 : 0, market_mutation_sink());
            }
            if (schema >= 30) {
                if (!read_column_le(bytes, cursor, _cell_social_pressure_level, cell) ||
                    _cell_social_pressure_level[cell] >= SAT_PRESSURE_LEVEL_COUNT) {
                    error = "save_cell_social_pressure_level_invalid";
                    return false;
                }
            }
            if (schema >= 28) {
                const size_t birth_lane_begin =
                    static_cast<size_t>(cell) * _ethnicity_ids.size();
                for (size_t ethnicity = 0; ethnicity < _ethnicity_ids.size(); ++ethnicity) {
                    int64_t residual_q32 = 0;
                    if (!read_le(bytes, cursor, residual_q32) ||
                        residual_q32 < 0 || residual_q32 >= Q32_ONE) {
                        error = "save_cell_birth_residual_invalid";
                        return false;
                    }
                    _birth_residual_q32.write_scalar(birth_lane_begin + ethnicity, residual_q32);
                }
            }
            if (schema >= 36) {
                if (!read_column_le(bytes, cursor, _cell_support_ema_q16, cell) ||
                    _cell_support_ema_q16[cell] < 0 ||
                    _cell_support_ema_q16[cell] > Q16_ONE * 4) {
                    error = "save_cell_support_ema_invalid";
                    return false;
                }
            }
            if (schema >= 45) {
                int32_t saved_food_days = 0;
                if (!read_column_le(bytes, cursor, _cell_food_flow_valid, cell) ||
                    !read_column_le(bytes, cursor, _cell_food_output_eq_previous, cell) ||
                    !read_column_le(bytes, cursor, _cell_food_input_eq_previous, cell) ||
                    !read_column_le(bytes, cursor, _cell_food_import_eq_previous, cell) ||
                    !read_column_le(bytes, cursor, _cell_food_export_eq_previous, cell) ||
                    !read_column_le(bytes, cursor, _cell_food_access_eq_previous, cell) ||
                    !read_le(bytes, cursor, saved_food_days) ||
                    _cell_food_flow_valid[cell] > 1 ||
                    _cell_food_output_eq_previous[cell] < 0 ||
                    _cell_food_input_eq_previous[cell] < 0 ||
                    _cell_food_import_eq_previous[cell] < 0 ||
                    _cell_food_export_eq_previous[cell] < 0 ||
                    _cell_food_access_eq_previous[cell] < 0 ||
                    saved_food_days < 0) {
                    error = "save_food_flow_payload_invalid";
                    return false;
                }
                _food_flow_previous_period_days = std::max(
                    _food_flow_previous_period_days.get(), saved_food_days);
            }
            if (schema >= 57) {
                int32_t saved_dry_streak = 0;
                int32_t saved_days_since_hazard = 0;
                uint8_t saved_hazard_mask = 0;
                if (!read_le(bytes, cursor, saved_dry_streak) ||
                    !read_le(bytes, cursor, saved_days_since_hazard) ||
                    !read_le(bytes, cursor, saved_hazard_mask) ||
                    saved_dry_streak < 0 || saved_dry_streak > 3650 ||
                    saved_days_since_hazard < 0 ||
                    saved_days_since_hazard > 3650 ||
                    saved_hazard_mask > 0x0F) {
                    error = "save_climate_state_invalid";
                    return false;
                }
                _cell_dry_streak_days.write_scalar(
                    cell, saved_dry_streak, market_mutation_sink());
                _cell_days_since_hazard.write_scalar(
                    cell, saved_days_since_hazard, market_mutation_sink());
                _cell_previous_hazard_mask.write_scalar(
                    cell, saved_hazard_mask, market_mutation_sink());
                // The saved byte is the last committed hazard. Seed today's
                // derived lane so the first post-restore capture preserves it
                // as yesterday's edge input.
                _cell_hazard_today_mask.write_scalar(
                    cell, saved_hazard_mask, market_mutation_sink());
            }
            market_store().cell_to_market.write_scalar(cell, market, market_mutation_sink());
            ++_restore.restored_cells;
        }
    } else if (section == SAVE_SECTION_COMMANDS) {
        for (uint32_t record = 0; record < records; ++record) {
            Command cmd;
            if (!read_le(bytes, cursor, cmd.opcode) || !read_le(bytes, cursor, cmd.effective_day) ||
                !read_le(bytes, cursor, cmd.sequence) || !read_le(bytes, cursor, cmd.target_handle) ||
                !read_le(bytes, cursor, cmd.i32_0) || !read_le(bytes, cursor, cmd.i32_1) ||
                !read_le(bytes, cursor, cmd.i64_0) || !read_le(bytes, cursor, cmd.i64_1) ||
                !read_le(bytes, cursor, cmd.submit_order) ||
                (_restore.schema_version >= 31 &&
                    (!read_le(bytes, cursor, cmd.effect_request_id) ||
                     !read_le(bytes, cursor, cmd.effect_idempotency_key)))) {
                error = "save_command_payload_truncated";
                return false;
            }
            if (cmd.opcode == COMMAND_START_FAMILY_EXPEDITION) {
                cmd.expedition_route_hash = cmd.effect_idempotency_key;
                cmd.effect_idempotency_key = 0;
            }
            if (cmd.effect_request_id < 0 ||
                (cmd.effect_request_id == 0 && cmd.effect_idempotency_key != 0) ||
                (cmd.effect_request_id != 0 && cmd.effect_idempotency_key == 0)) {
                error = "save_effect_command_identity_invalid";
                return false;
            }
            if (cmd.effect_request_id != 0) {
                if (!_effect_idempotency_requests.emplace(
                        cmd.effect_idempotency_key, cmd.effect_request_id).second ||
                    !_effect_command_results.emplace(cmd.effect_request_id,
                        EffectCommandResult{}).second) {
                    error = "save_effect_command_identity_duplicate";
                    return false;
                }
                _next_effect_request_id = std::max(_next_effect_request_id,
                    cmd.effect_request_id + 1);
            }
            _pending_commands.push_back(cmd);
            ++_restore.restored_commands;
        }
    } else if (section == SAVE_SECTION_BUILDINGS) {
        const size_t first_group = building_count();
        for (uint32_t record = 0; record < records; ++record) {
            BuildingGroup group;
            int32_t roles = 0;
            if (!read_le(bytes, cursor, group.cell) || !read_le(bytes, cursor, group.type_id) ||
                !read_le(bytes, cursor, group.owner_signature_id) ||
                !read_le(bytes, cursor, group.count) ||
                !read_le(bytes, cursor, group.filled_owner) ||
                !read_le(bytes, cursor, group.last_capacity_q16) ||
                !read_le(bytes, cursor, group.last_temperature_fit_q16) ||
                !read_le(bytes, cursor, group.last_water_fit_q16) ||
                !read_le(bytes, cursor, group.last_climate_capacity_q16) ||
                !read_le(bytes, cursor, group.last_climate_lost_output) ||
                !read_le(bytes, cursor, group.last_input) ||
                !read_le(bytes, cursor, group.last_output) ||
                !read_le(bytes, cursor, group.last_sold) ||
                !read_le(bytes, cursor, group.last_discarded) ||
                !read_le(bytes, cursor, group.last_resource) ||
                !read_le(bytes, cursor, group.last_resource_generated) ||
                !read_le(bytes, cursor, group.last_revenue) ||
                !read_le(bytes, cursor, group.last_input_cost) ||
                !read_le(bytes, cursor, group.last_wages_paid) ||
                !read_le(bytes, cursor, group.last_wages_due) ||
                !read_le(bytes, cursor, group.last_expected_revenue) ||
                !read_le(bytes, cursor, group.last_operating_cost) ||
                !read_le(bytes, cursor, group.last_margin_gap_q16) ||
                !read_le(bytes, cursor, group.planned_utilization_q16) ||
                !read_le(bytes, cursor, group.last_base_wages_paid) ||
                !read_le(bytes, cursor, group.last_base_wages_due) ||
                !read_le(bytes, cursor, group.last_bonus_paid) ||
                !read_le(bytes, cursor, group.last_bonus_due) ||
                !read_le(bytes, cursor, group.wage_suspended)) {
                error = "save_building_record_invalid";
                return false;
            }
            if (_restore.schema_version >= 12 &&
                (!read_le(bytes, cursor, group.purchase_intent_capacity_q16) ||
                 !read_le(bytes, cursor, group.realized_profit_margin_q16) ||
                 !read_le(bytes, cursor, group.severe_loss_cycles) ||
                 !read_le(bytes, cursor, group.recovery_cycles) ||
                 !read_le(bytes, cursor, group.operating_state) ||
                 (_restore.schema_version >= 19 &&
                  (!read_le(bytes, cursor, group.pending_operating_state) ||
                   !read_le(bytes, cursor, group.recovery_cooldown_cycles))) ||
                 !read_le(bytes, cursor, group.recovery_failed_reviews) ||
                 !read_le(bytes, cursor, group.merchant_debt_term_cycles_left) ||
                 !read_le(bytes, cursor, group.merchant_debt_delinquent_cycles) ||
                 !read_le(bytes, cursor, group.merchant_debt_principal) ||
                 !read_le(bytes, cursor, group.merchant_debt_premium) ||
                 !read_le(bytes, cursor, group.last_in_kind_livelihood_value))) {
                error = "save_building_business_state_payload_truncated";
                return false;
            }
            if (_restore.schema_version >= 47 &&
                (!read_le(bytes, cursor, group.last_market_receipt) ||
                 !read_le(bytes, cursor, group.last_bullion_mint_receipt) ||
                 !read_le(bytes, cursor, group.last_producer_support_receipt) ||
                 !read_le(bytes, cursor, group.last_business_tax_paid) ||
                 !read_le(bytes, cursor, group.last_business_subsidy_received) ||
                 !read_le(bytes, cursor, group.last_maintenance_due) ||
                 !read_le(bytes, cursor, group.last_observed_capacity_days_q16) ||
                 !read_le(bytes, cursor, group.last_quoted_market_receipt) ||
                 !read_le(bytes, cursor, group.last_quoted_operating_cost))) {
                error = "save_building_fact_quote_payload_truncated";
                return false;
            }
            // A collapsed lot stays in the store as count == 0 until the prune
            // pass drops its identity; the row itself still carries the cell,
            // type and owner key, so rejecting zero here made a legally written
            // row unreadable. Negative counts remain corruption.
            if (!read_le(bytes, cursor, roles) || group.cell < 0 || group.cell >= _cell_count.get() ||
                group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()) ||
                group.owner_signature_id < 0 ||
                group.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                group.count < 0 || roles != _building_types[group.type_id].employee_count ||
                group.last_temperature_fit_q16 < 0 ||
                group.last_temperature_fit_q16 > Q16_ONE ||
                group.last_water_fit_q16 < 0 ||
                group.last_water_fit_q16 > Q16_ONE ||
                group.last_climate_capacity_q16 < 0 ||
                group.last_climate_capacity_q16 > Q16_ONE ||
                group.last_climate_lost_output < 0 ||
                group.purchase_intent_capacity_q16 < 0 ||
                group.purchase_intent_capacity_q16 > Q16_ONE ||
                (group.pending_operating_state > 1 && group.pending_operating_state != 255) ||
                group.operating_state > 1 || group.merchant_debt_principal < 0 ||
                group.merchant_debt_premium < 0 ||
                group.last_in_kind_livelihood_value < 0 ||
                group.last_market_receipt < 0 ||
                group.last_bullion_mint_receipt < 0 ||
                group.last_producer_support_receipt < 0 ||
                group.last_business_tax_paid < 0 ||
                group.last_business_subsidy_received < 0 ||
                group.last_maintenance_due < 0 ||
                group.last_observed_capacity_days_q16 < 0 ||
                group.last_quoted_market_receipt < 0 ||
                group.last_quoted_operating_cost < 0 ||
                ((group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) &&
                 group.merchant_debt_term_cycles_left == 0 &&
                 group.merchant_debt_delinquent_cycles == 0)) {
                error = "save_building_record_invalid";
                return false;
            }
            group.employee_fill_begin = static_cast<int32_t>(_building_employee_filled.size());
            group.last_input_selection_begin = static_cast<int32_t>(
                _building_last_input_selected_goods.size());
            _building_last_input_selected_goods.resize(
                _building_last_input_selected_goods.size() +
                    static_cast<size_t>(_building_types[group.type_id].input_count),
                -1);
            for (int32_t r = 0; r < roles; ++r) {
                int64_t value = 0;
                if (!read_le(bytes, cursor, value) || value < 0) {
                    error = "save_building_role_payload_invalid";
                    return false;
                }
                _building_employee_filled.push_back(value);
                int64_t contract = 0;
                int64_t base_living = 0;
                int64_t role_living = 0;
                int64_t local_average = 0;
                int64_t base_due = 0;
                int64_t base_paid = 0;
                int64_t bonus_due = 0;
                int64_t bonus_paid = 0;
                if (!read_le(bytes, cursor, contract) ||
                     !read_le(bytes, cursor, base_living) ||
                     !read_le(bytes, cursor, role_living) ||
                     !read_le(bytes, cursor, local_average) ||
                     !read_le(bytes, cursor, base_due) ||
                     !read_le(bytes, cursor, base_paid) ||
                     !read_le(bytes, cursor, bonus_due) ||
                     !read_le(bytes, cursor, bonus_paid)) {
                    error = "save_building_role_wage_payload_invalid";
                    return false;
                }
                if (contract < 0 || base_living < 0 || role_living < 0 ||
                    local_average < 0 || base_due < 0 || base_paid < 0 ||
                    bonus_due < 0 || bonus_paid < 0 || base_paid > base_due ||
                    bonus_paid > bonus_due) {
                    error = "save_building_role_wage_value_invalid";
                    return false;
                }
                _building_role_contract_wage.push_back(contract);
                _building_role_base_living_cost.push_back(base_living);
                _building_role_living_cost.push_back(role_living);
                _building_role_local_average_wage.push_back(local_average);
                _building_role_base_wage_due.push_back(base_due);
                _building_role_base_wage_paid.push_back(base_paid);
                _building_role_bonus_due.push_back(bonus_due);
                _building_role_bonus_paid.push_back(bonus_paid);
                _building_role_forecast_pay_ratio_q16.push_back(0);
            }
            group.last_maintenance_cost = maintenance_from_operating_cost(
                group.last_operating_cost, group.last_input_cost, group.last_wages_due);
            append_building_group(group);
            ++_restore.restored_buildings;
        }
        while (schema >= 64 && cursor < bytes.size()) {
            uint32_t row = 0;
            int64_t paid = 0;
            if (!read_le(bytes, cursor, row) || !read_le(bytes, cursor, paid) ||
                row >= records || paid < 0) {
                error = "save_building_maintenance_exception_invalid";
                return false;
            }
            building_at(first_group + row).last_maintenance_cost = paid;
        }
    } else if (section == SAVE_SECTION_CONSTRUCTION) {
        for (uint32_t record = 0; record < records; ++record) {
            PendingConstruction pending;
            if (!read_le(bytes, cursor, pending.cell) || !read_le(bytes, cursor, pending.type_id) ||
                !read_le(bytes, cursor, pending.owner_signature_id) ||
                !read_le(bytes, cursor, pending.count) ||
                !read_le(bytes, cursor, pending.ready_day) ||
                !read_le(bytes, cursor, pending.sequence) ||
                !read_le(bytes, cursor, pending.merchant_debt_principal) ||
                !read_le(bytes, cursor, pending.merchant_debt_premium) ||
                !read_le(bytes, cursor, pending.merchant_debt_term_cycles_left) ||
                (schema >= 26 && !read_le(bytes, cursor,
                    pending.sponsor_family_handle)) ||
                pending.cell < 0 ||
                pending.cell >= _cell_count.get() || pending.type_id < 0 ||
                pending.type_id >= static_cast<int32_t>(_building_types.size()) ||
                pending.owner_signature_id < 0 ||
                pending.owner_signature_id >= static_cast<int32_t>(_signatures.size()) ||
                pending.count <= 0 || pending.merchant_debt_principal < 0 ||
                pending.merchant_debt_premium < 0 ||
                ((pending.merchant_debt_principal > 0 ||
                  pending.merchant_debt_premium > 0) &&
                 pending.merchant_debt_term_cycles_left == 0)) {
                error = "save_construction_record_invalid";
                return false;
            }
            append_pending_construction(pending);
            ++_restore.restored_construction;
        }
