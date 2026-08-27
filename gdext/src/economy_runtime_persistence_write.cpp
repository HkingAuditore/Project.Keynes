#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_persistence_codec.h"

#include <algorithm>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace persistence_codec;

PackedByteArray NativeEconomyRuntime::read_save_chunk(int32_t max_bytes) {
    if (!_save.active || _save.end_emitted) return {};
    const int32_t budget = std::clamp(max_bytes > 0 ? max_bytes : _save.chunk_bytes,
                                      64 * 1024, 16 * 1024 * 1024);
    std::vector<uint8_t> payload;
    if (_save.section == SAVE_SECTION_HEADER) {
        append_le<int32_t>(payload, _cell_count);
        append_le<int32_t>(payload, _market.market_count);
        append_le<int32_t>(payload, _market.good_count);
        append_le<int32_t>(payload, static_cast<int32_t>(_population.page_next.size()));
        append_le<int64_t>(payload, _population.active_count);
        append_le<int32_t>(payload, _epoch_days);
        append_le<int64_t>(payload, _last_committed_day);
        append_le<int64_t>(payload, _epoch_id);
        append_le<int32_t>(payload, NativeCountryRuntime::SCHEMA_VERSION);
        append_le<uint64_t>(payload, _country_runtime->generation());
        append_le<uint64_t>(payload, static_cast<uint64_t>(_country_runtime->state_hash()));
        append_le<int64_t>(payload, _seed);
        append_le<int64_t>(payload, _catalog_hash);
        append_le<int64_t>(payload, _building_catalog_hash);
        append_le<int32_t>(payload, static_cast<int32_t>(_buildings.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_pending_construction.size()));
        append_le<int64_t>(payload, _environment_day);
        append_le<int64_t>(payload, _environment_hash);
        append_le<uint64_t>(payload, _next_submit_order);
        append_le<int64_t>(payload, MONEY_SCALE);
        append_le<int64_t>(payload, GOODS_SCALE);
        append_le<int64_t>(payload, Q16_ONE);
        append_le<int64_t>(payload, Q32_ONE);
        append_le<int32_t>(payload, static_cast<int32_t>(_pending_commands.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_audit_history.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_market_signals.good_ids.size()));
        append_le<int32_t>(payload,
                           static_cast<int32_t>(_labor_signals.profession_ids.size()));
        append_le<int64_t>(payload, _next_event_id);
        append_le<uint64_t>(payload, _event_stream_hash);
        append_le<int32_t>(payload, _trade_orders.size());
        append_le<int32_t>(payload, static_cast<int32_t>(_trade_flows.cells.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(
            _tariff_history.countries.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(
            _country_good_trade.countries.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(
            _country_partner_trade.countries.size()));
        append_le<uint64_t>(payload, _country_trade_revision);
        append_le<int64_t>(payload, _trade_orders.next_id);
        append_le<int32_t>(payload, _trade_runtime_mode);
        append_le<int64_t>(payload, _trade_capacity_per_merchant_q16);
        append_le<int32_t>(payload, _trade_speed_cost_per_day);
        append_le<int32_t>(payload, _trade_min_margin_q16);
        append_le<int32_t>(payload, _trade_target_count);
        append_le<int32_t>(payload, _trade_signal_pairs_per_slice);
        append_le<int32_t>(payload, _trade_route_searches_per_slice);
        append_le<int32_t>(payload, _trade_max_route_expansions);
        append_le<int32_t>(payload, _trade_route_cache_entries);
        append_le<int32_t>(payload, _trade_max_signals);
        append_le<int32_t>(payload, _trade_max_candidates);
        append_le<int32_t>(payload, _trade_max_orders);
        append_le<int32_t>(payload, _trade_flow_ema_alpha_q16);
        append_le<int32_t>(payload, _trade_max_stock_share_q16);
        append_le<int32_t>(payload, _building_severe_loss_threshold_q16);
        append_le<int32_t>(payload, _building_severe_loss_cycles);
        append_le<int32_t>(payload, _building_restart_margin_q16);
        append_le<int32_t>(payload, _building_restart_cycles);
        append_le<int32_t>(payload, _merchant_procurement_cash_reserve_q16);
        append_le<int32_t>(payload, _merchant_market_making_days_q16);
        append_le<int32_t>(payload, _merchant_credit_runtime_mode);
        append_le<int32_t>(payload, _merchant_credit_exposure_q16);
        append_le<int32_t>(payload, _merchant_credit_premium_q16);
        append_le<int32_t>(payload, _merchant_credit_term_cycles);
        append_le<int32_t>(payload, _recovery_success_cycles);
        append_le<int32_t>(payload, _recovery_liquidation_failed_reviews);
        append_le<int32_t>(payload, _trade_export_floor_days);
        append_le<int32_t>(payload, _trade_export_inventory_fraction_q16);
        append_le<int32_t>(payload, _trade_import_fill_fraction_q16);
        append_le<int32_t>(payload, _trade_response_days);
        append_le<int32_t>(payload, _investment_review_days);
        append_le<int32_t>(payload, _investment_min_shortage_q16);
        append_le<int32_t>(payload, _investment_min_utilization_q16);
        append_le<int32_t>(payload, _investment_max_payback_days);
        append_le<int32_t>(payload, _investment_operating_cycles);
        append_le<int32_t>(payload, _investment_gap_fill_share_q16);
        append_le<int32_t>(payload, _investment_portfolio_max_types);
        append_le<int32_t>(payload, _investment_max_type_owner_share_q16);
        append_le<int32_t>(payload, _investment_max_growth_share_q16);
        append_le<int32_t>(payload, _investment_new_type_seed_buildings);
        append_le<int32_t>(
            payload, _investment_merchant_transition_min_improvement_q16);
        append_le<int32_t>(payload, _recovery_liquidation_max_share_q16);
        append_le<int32_t>(payload, _resource_min_reserve_q16);
        append_le<int32_t>(payload, _resource_safe_harvest_q16);
        append_le<int32_t>(payload, _resource_min_horizon_days);
        append_le<int32_t>(payload, _bullion_monthly_issue_cap_q16);
        append_le<int32_t>(payload, _producer_support_monthly_cap_q16);
        append_le<int64_t>(payload, _government_research_procured_points);
        append_le<int64_t>(payload, _government_research_procurement_cash);
        append_le<int64_t>(payload, _government_research_procurement_orders);
        append_le<int64_t>(payload, _prosperity_profile_hash);
        append_le<int32_t>(payload, _building_plan_days);
        append_le<int64_t>(payload, _family_catalog_hash);
        append_le<int32_t>(payload, _family_runtime_mode);
        append_le<int32_t>(payload, _family_min_settlement_tier);
        append_le<int32_t>(payload, _family_review_days);
        append_le<int64_t>(payload, _family_min_population_per_active);
        append_le<int64_t>(payload, _family_split_population_threshold);
        append_le<int32_t>(payload, _family_max_per_cell);
        append_le<int32_t>(payload, _family_decline_reviews);
        append_le<int64_t>(payload, _person_catalog_hash);
        append_le<int32_t>(payload, _person_runtime_mode);
        append_le<int32_t>(payload, _person_max_per_family);
        append_le<int32_t>(payload, _person_max_per_cell);
        append_le<int32_t>(payload, _person_max_total);
        append_le<int32_t>(payload, _person_records_per_slice);
        append_le<int32_t>(payload,
            static_cast<int32_t>(_persons.active.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(_person_needs.size()));
        append_le<int32_t>(payload, _family_trait_catalog_version);
        append_le<int64_t>(payload, _family_trait_catalog_hash);
        append_le<int32_t>(payload,
            static_cast<int32_t>(_family_traits.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(_family_influences.active.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(_family_trait_commands.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(_family_expeditions.active.size()));
        append_le<int32_t>(payload,
            static_cast<int32_t>(_family_expeditions.active_count));
        append_le<int64_t>(payload, _next_family_expedition_stable_id);
        append_le<int64_t>(payload, _next_colonization_receipt_id);
        append_le<int32_t>(payload, static_cast<int32_t>(_canal_quotes.size()));
        append_le<int32_t>(payload, static_cast<int32_t>(_canal_projects.size()));
        append_le<uint64_t>(payload, _next_canal_quote_token);
        append_le<uint64_t>(payload, _next_canal_project_id);
        append_le<int64_t>(payload, _next_canal_receipt_id);
        append_le<int32_t>(payload, _locked_market_cycle_days);
        append_le<int64_t>(payload, _market_cycle_start_day);
        append_le<int32_t>(payload, _locked_slow_cycle_days);
        append_le<int64_t>(payload, _slow_cycle_start_day);
        append_le<int32_t>(payload, _locked_investment_cycle_days);
        append_le<int64_t>(payload, _investment_cycle_start_day);
        for (int32_t sector = 0; sector < 5; ++sector)
            append_le<int32_t>(payload, _maintenance_horizon_days_by_sector[sector]);
        append_le<int32_t>(payload, _building_maintenance_cost_factor_q16);
        append_le<int32_t>(payload, _startup_demand_runtime_mode);
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
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_population.page_next.size()),
                                              _save.page_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.page_cursor)) * record_bytes);
        const int32_t begin = _save.page_cursor;
        for (; _save.page_cursor < end; ++_save.page_cursor) {
            const int32_t page = _save.page_cursor;
            append_le<int32_t>(payload, page);
            append_le<int32_t>(payload, _population.page_next[page]);
            append_le<int32_t>(payload, _population.page_cell[page]);
            const int32_t base = page * COHORT_PAGE_SIZE;
            for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
                const int32_t slot = base + lane;
                append_le<uint8_t>(payload, _population.active[slot]);
                append_le<uint32_t>(payload, _population.signature_id[slot]);
                append_le<uint32_t>(payload, _population.generation[slot]);
                append_le<int64_t>(payload, _population.population[slot]);
                append_le<int64_t>(payload, _population.funds[slot]);
                append_le<int64_t>(payload, _population.epoch_income[slot]);
                append_le<int64_t>(payload, _population.epoch_expense[slot]);
                append_le<int64_t>(payload, _population.income_ema[slot]);
                append_le<uint16_t>(payload, _population.needs_satisfaction[slot]);
                append_le<uint16_t>(payload, _population.worst_need_id[slot]);
                append_le<uint16_t>(payload, _population.flags[slot]);
                append_le<int64_t>(payload, _population.demography_residual[slot]);
                append_le<int64_t>(payload, _population.owner_employed[slot]);
                append_le<int64_t>(payload, _population.employee_employed[slot]);
                append_le<uint16_t>(payload, _population.composite_satisfaction[slot]);
                append_le<uint8_t>(payload, _population.worst_dimension_id[slot]);
                const size_t dims_base = static_cast<size_t>(slot) *
                    static_cast<size_t>(SAT_DIM_COUNT);
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                    append_le<uint16_t>(payload,
                        _population.satisfaction_dims[dims_base +
                                                      static_cast<size_t>(dim)]);
                append_le<int64_t>(payload, _population.income_baseline_ema[slot]);
                append_le<int64_t>(payload, _population.epoch_tax_paid[slot]);
                append_le<int64_t>(payload, _population.epoch_subsidy_received[slot]);
            }
        }
        if (_save.page_cursor >= static_cast<int32_t>(_population.page_next.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_PAGES,
                               static_cast<uint32_t>(_save.page_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_MARKETS) {
        const int32_t record_bytes = 4 + _market.good_count * 22;
        const int32_t max_records = std::max(1, (budget - 16) / std::max(1, record_bytes));
        const int32_t end = std::min(_market.market_count, _save.market_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.market_cursor)) * record_bytes);
        const int32_t begin = _save.market_cursor;
        for (; _save.market_cursor < end; ++_save.market_cursor) {
            const int32_t market = _save.market_cursor;
            append_le<int32_t>(payload, market);
            for (int32_t good = 0; good < _market.good_count; ++good) {
                const int64_t idx = _market.index(market, good);
                append_le<int64_t>(payload, _market.stock[idx]);
                append_le<int32_t>(payload, _market.price[idx]);
                append_le<int64_t>(payload, _market.demand_ema[idx]);
                append_le<uint16_t>(payload, _market.last_shortage_q16[idx]);
            }
        }
        if (_save.market_cursor >= _market.market_count) ++_save.section;
        return make_save_chunk(SAVE_SECTION_MARKETS,
                               static_cast<uint32_t>(_save.market_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CELLS) {
        const int32_t record_bytes = 167 +
            static_cast<int32_t>(_ethnicity_ids.size()) * 8;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min(_cell_count, _save.cell_cursor + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - _save.cell_cursor)) * record_bytes);
        const int32_t begin = _save.cell_cursor;
        for (; _save.cell_cursor < end; ++_save.cell_cursor) {
            append_le<int32_t>(payload, _save.cell_cursor);
            append_le<int32_t>(payload, _market.cell_to_market[_save.cell_cursor]);
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
            append_le<int32_t>(payload, _food_flow_previous_period_days);
        }
        if (_save.cell_cursor >= _cell_count) ++_save.section;
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
            append_le<uint64_t>(payload, cmd.effect_idempotency_key);
        }
        if (_save.command_cursor >= static_cast<int32_t>(_pending_commands.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_COMMANDS,
                               static_cast<uint32_t>(_save.command_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_BUILDINGS) {
        const int32_t max_records = std::max(1, (budget - 16) / 1024);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_buildings.size()),
                                              _save.building_cursor + max_records);
        const int32_t begin = _save.building_cursor;
        for (; _save.building_cursor < end; ++_save.building_cursor) {
            const BuildingGroup &group = _buildings[_save.building_cursor];
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
        if (_save.building_cursor >= static_cast<int32_t>(_buildings.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_BUILDINGS,
                               static_cast<uint32_t>(_save.building_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_CONSTRUCTION) {
        constexpr int32_t record_bytes = 62;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_pending_construction.size()),
                                              _save.construction_cursor + max_records);
        const int32_t begin = _save.construction_cursor;
        for (; _save.construction_cursor < end; ++_save.construction_cursor) {
            const PendingConstruction &pending = _pending_construction[_save.construction_cursor];
            append_le<int32_t>(payload, pending.cell);
            append_le<int32_t>(payload, pending.type_id);
            append_le<int32_t>(payload, pending.owner_signature_id);
            append_le<int64_t>(payload, pending.count);
            append_le<int64_t>(payload, pending.ready_day);
            append_le<int64_t>(payload, pending.sequence);
            append_le<int64_t>(payload, pending.merchant_debt_principal);
            append_le<int64_t>(payload, pending.merchant_debt_premium);
            append_le<uint16_t>(payload, pending.merchant_debt_term_cycles_left);
            append_le<uint64_t>(payload, pending.sponsor_family_handle);
        }
        if (_save.construction_cursor >= static_cast<int32_t>(_pending_construction.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_CONSTRUCTION,
                               static_cast<uint32_t>(_save.construction_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_AUDIT) {
        constexpr int32_t record_bytes = 72;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_audit_history.size()),
                                              _save.audit_cursor + max_records);
        const int32_t begin = _save.audit_cursor;
        for (; _save.audit_cursor < end; ++_save.audit_cursor) {
            const AuditFrame &frame = _audit_history[static_cast<size_t>(_save.audit_cursor)];
            append_le<int64_t>(payload, frame.epoch_id);
            append_le<int64_t>(payload, frame.sample_day);
            append_le<int64_t>(payload, frame.commit_day);
            append_le<int64_t>(payload, frame.event_count);
            append_le<int64_t>(payload, frame.leg_count);
            append_le<int64_t>(payload, frame.population_error);
            append_le<int64_t>(payload, frame.money_error);
            append_le<int64_t>(payload, frame.goods_error);
            append_le<uint64_t>(payload, frame.stream_hash);
        }
        if (_save.audit_cursor >= static_cast<int32_t>(_audit_history.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_AUDIT,
                               static_cast<uint32_t>(_save.audit_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_SIGNALS) {
        constexpr int32_t record_bytes = 36;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
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
        }
        if (_save.signal_cursor >= static_cast<int32_t>(_market_signals.good_ids.size()))
            ++_save.section;
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
        const int32_t end = std::min(_trade_orders.size(), begin + 1);
        for (; _save.trade_order_cursor < end; ++_save.trade_order_cursor) {
            const int32_t order = _save.trade_order_cursor;
            append_le<int64_t>(payload, _trade_orders.ids[order]);
            append_le<int32_t>(payload, _trade_orders.sources[order]);
            append_le<int32_t>(payload, _trade_orders.destinations[order]);
            append_le<int32_t>(payload, _trade_orders.countries[order]);
            append_le<uint64_t>(payload,
                _trade_orders.source_country_handles[order]);
            append_le<uint64_t>(payload,
                _trade_orders.destination_country_handles[order]);
            append_le<int32_t>(payload,
                _trade_orders.source_country_slots[order]);
            append_le<int32_t>(payload,
                _trade_orders.destination_country_slots[order]);
            append_le<int64_t>(payload, _trade_orders.departure_days[order]);
            append_le<int64_t>(payload, _trade_orders.arrival_days[order]);
            append_le<int64_t>(payload, _trade_orders.cash_escrow[order]);
            append_le<int64_t>(payload, _trade_orders.capacity_work[order]);
            append_le<uint8_t>(payload, _trade_orders.states[order]);
            append_le<uint8_t>(payload, _trade_orders.cargo_delivered[order]);
            const int32_t line_count = _trade_orders.line_offsets[order + 1] -
                _trade_orders.line_offsets[order];
            const int32_t seller_count = _trade_orders.seller_offsets[order + 1] -
                _trade_orders.seller_offsets[order];
            append_le<int32_t>(payload, line_count);
            append_le<int32_t>(payload, seller_count);
            for (int32_t line = _trade_orders.line_offsets[order];
                 line < _trade_orders.line_offsets[order + 1]; ++line) {
                append_le<int32_t>(payload, _trade_orders.line_goods[line]);
                append_le<int64_t>(payload, _trade_orders.line_quantities[line]);
                append_le<int32_t>(payload, _trade_orders.line_unit_prices[line]);
                append_le<int32_t>(payload,
                    _trade_orders.line_destination_prices[line]);
                append_le<int64_t>(payload,
                    _trade_orders.line_base_values[line]);
                append_le<int64_t>(payload,
                    _trade_orders.line_retail_values[line]);
                append_le<int64_t>(payload,
                    _trade_orders.line_import_transfers[line]);
                append_le<int64_t>(payload,
                    _trade_orders.line_export_transfers[line]);
                append_le<int64_t>(payload,
                    _trade_orders.line_transaction_transfers[line]);
                append_le<uint8_t>(payload, _trade_orders.line_flags[line]);
            }
            for (int32_t seller = _trade_orders.seller_offsets[order];
                 seller < _trade_orders.seller_offsets[order + 1]; ++seller) {
                append_le<uint64_t>(payload, _trade_orders.seller_handles[seller]);
                append_le<int64_t>(payload, _trade_orders.seller_weights[seller]);
            }
        }
        if (_save.trade_order_cursor >= _trade_orders.size()) ++_save.section;
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
            4 + NativeCountryRuntime::TAX_KIND_COUNT * 12 * 8;
        const int32_t country_count = static_cast<int32_t>(
            _epoch_country_handles.size());
        const int32_t max_records = std::max(
            1, (budget - 16) / record_bytes);
        const int32_t begin = _save.fiscal_cursor;
        const int32_t end = std::min(
            country_count, begin + max_records);
        const auto append_group = [&](const std::vector<int64_t> &values,
                                      int32_t country) {
            for (int32_t kind = 0;
                 kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
                const size_t index = static_cast<size_t>(country) *
                    NativeCountryRuntime::TAX_KIND_COUNT + kind;
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
        }
        if (_save.fiscal_cursor >= country_count) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FISCAL,
            static_cast<uint32_t>(_save.fiscal_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_SETTLEMENT_NAMES) {
        uint32_t records = 0;
        while (_save.settlement_cursor < _cell_count) {
            const int32_t cell = _save.settlement_cursor++;
            if (_settlements.name_active[cell] == 0) continue;
            std::vector<uint8_t> record;
            append_le<int32_t>(record, cell);
            append_string(record, _settlement_name_pack_id);
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
        if (_save.settlement_cursor >= _cell_count) ++_save.section;
        return make_save_chunk(SAVE_SECTION_SETTLEMENT_NAMES, records, payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_RECORDS) {
        constexpr int32_t record_bytes = 57;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_families.active.size(),
            _save.family_cursor + max_records);
        const int32_t begin = _save.family_cursor;
        for (; _save.family_cursor < end; ++_save.family_cursor) {
            const int32_t i = _save.family_cursor;
            append_le<int32_t>(payload, i);
            append_le<uint8_t>(payload, _families.active[i]);
            append_le<uint32_t>(payload, _families.generation[i]);
            append_le<int64_t>(payload, _families.stable_id[i]);
            append_le<int32_t>(payload, _families.surname_id[i]);
            append_le<uint32_t>(payload, _families.surname_disambiguator[i]);
            append_le<int64_t>(payload, _families.founded_day[i]);
            append_le<int32_t>(payload, _families.home_cell[i]);
            append_le<int32_t>(payload, _families.origin_cell[i]);
            append_le<int32_t>(payload, _families.origin_ethnicity[i]);
            append_le<int32_t>(payload, _families.culture_group_id[i]);
            append_le<uint32_t>(payload, _families.split_sequence[i]);
            append_le<uint16_t>(payload, _families.decline_reviews[i]);
            append_le<uint16_t>(payload, _families.flags[i]);
        }
        if (_save.family_cursor >= static_cast<int32_t>(_families.active.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_RECORDS,
            static_cast<uint32_t>(_save.family_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_MEMBERSHIP) {
        constexpr int32_t record_bytes = 64;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_family_memberships.size(),
            _save.family_membership_cursor + max_records);
        const int32_t begin = _save.family_membership_cursor;
        for (; _save.family_membership_cursor < end;
             ++_save.family_membership_cursor) {
            const FamilyMembershipEdge &edge =
                _family_memberships[_save.family_membership_cursor];
            append_le<uint64_t>(payload, edge.family_handle);
            append_le<uint64_t>(payload, edge.cohort_handle);
            append_le<int64_t>(payload, edge.people);
            append_le<int64_t>(payload, edge.cash_claim);
            append_le<int64_t>(payload, edge.population_basis);
            append_le<int64_t>(payload, edge.funds_basis);
            append_le<int64_t>(payload, edge.owner_employed);
            append_le<int64_t>(payload, edge.employee_employed);
        }
        if (_save.family_membership_cursor >= static_cast<int32_t>(
                _family_memberships.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_MEMBERSHIP,
            static_cast<uint32_t>(_save.family_membership_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_OWNERSHIP) {
        constexpr int32_t record_bytes = 32;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_family_ownerships.size(),
            _save.family_ownership_cursor + max_records);
        const int32_t begin = _save.family_ownership_cursor;
        for (; _save.family_ownership_cursor < end;
             ++_save.family_ownership_cursor) {
            const FamilyBuildingOwnership &edge =
                _family_ownerships[_save.family_ownership_cursor];
            append_le<uint64_t>(payload, edge.family_handle);
            append_le<uint64_t>(payload, edge.building_handle);
            append_le<int64_t>(payload, edge.owned_count);
            append_le<int64_t>(payload, edge.filled_owner);
        }
        if (_save.family_ownership_cursor >= static_cast<int32_t>(
                _family_ownerships.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_OWNERSHIP,
            static_cast<uint32_t>(_save.family_ownership_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_PERSON_RECORDS) {
        constexpr int32_t record_bytes = 124;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_persons.active.size(),
            _save.person_cursor + max_records);
        const int32_t begin = _save.person_cursor;
        for (; _save.person_cursor < end; ++_save.person_cursor) {
            const int32_t i = _save.person_cursor;
            append_le<int32_t>(payload, i);
            append_le<uint8_t>(payload, _persons.active[i]);
            append_le<uint32_t>(payload, _persons.generation[i]);
            append_le<int64_t>(payload, _persons.stable_id[i]);
            append_le<uint64_t>(payload, _persons.family_handle[i]);
            append_le<uint64_t>(payload, _persons.cohort_handle[i]);
            append_le<int32_t>(payload, _persons.given_name_id[i]);
            append_le<uint32_t>(payload, _persons.name_disambiguator[i]);
            append_le<int64_t>(payload, _persons.notable_since_day[i]);
            append_le<uint16_t>(payload, _persons.flags[i]);
            append_le<int64_t>(payload, _persons.cash_claim[i]);
            append_le<int64_t>(payload, _persons.family_equity_share_q32[i]);
            append_le<int64_t>(payload, _persons.epoch_job_income[i]);
            append_le<int64_t>(payload, _persons.epoch_business_result[i]);
            append_le<int64_t>(payload, _persons.epoch_consumption_expense[i]);
            append_le<int64_t>(payload, _persons.epoch_tax[i]);
            append_le<int64_t>(payload, _persons.income_ema[i]);
            append_le<uint16_t>(payload, _persons.needs_satisfaction[i]);
            append_le<uint16_t>(payload, _persons.worst_need_id[i]);
            append_le<uint64_t>(payload, _persons.building_handle[i]);
            append_le<uint8_t>(payload, _persons.job_kind[i]);
            append_le<int32_t>(payload, _persons.employee_role_index[i]);
            append_le<int64_t>(payload, _persons.job_since_day[i]);
        }
        if (_save.person_cursor >= static_cast<int32_t>(_persons.active.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_PERSON_RECORDS,
            static_cast<uint32_t>(_save.person_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_PERSON_NEEDS) {
        constexpr int32_t record_bytes = 30;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_person_needs.size(),
            _save.person_need_cursor + max_records);
        const int32_t begin = _save.person_need_cursor;
        for (; _save.person_need_cursor < end; ++_save.person_need_cursor) {
            const PersonNeedState &state =
                _person_needs[_save.person_need_cursor];
            append_le<uint64_t>(payload, state.person_handle);
            append_le<int32_t>(payload, state.stable_need_id);
            append_le<int64_t>(payload, state.desired_period_units);
            append_le<uint16_t>(payload, state.satisfaction_q16);
            append_le<int64_t>(payload, state.attributed_spend);
        }
        if (_save.person_need_cursor >= static_cast<int32_t>(_person_needs.size()))
            ++_save.section;
        return make_save_chunk(SAVE_SECTION_PERSON_NEEDS,
            static_cast<uint32_t>(_save.person_need_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_TRAITS) {
        constexpr int32_t record_bytes = 17;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_family_traits.size(),
            _save.family_trait_cursor + max_records);
        const int32_t begin = _save.family_trait_cursor;
        for (; _save.family_trait_cursor < end; ++_save.family_trait_cursor) {
            const FamilyTraitRoll &roll =
                _family_traits[_save.family_trait_cursor];
            append_le<uint64_t>(payload, roll.family_handle);
            append_le<int32_t>(payload, roll.trait_id);
            append_le<int32_t>(payload, roll.strength_q16);
            append_le<uint8_t>(payload, roll.core);
        }
        if (_save.family_trait_cursor >= static_cast<int32_t>(
                _family_traits.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_TRAITS,
            static_cast<uint32_t>(_save.family_trait_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_INFLUENCES) {
        constexpr int32_t record_bytes = 84;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_family_influences.active.size(),
            _save.family_influence_cursor + max_records);
        const int32_t begin = _save.family_influence_cursor;
        for (; _save.family_influence_cursor < end;
             ++_save.family_influence_cursor) {
            const int32_t i = _save.family_influence_cursor;
            append_le<int32_t>(payload, i);
            append_le<uint8_t>(payload, _family_influences.active[i]);
            append_le<uint32_t>(payload, _family_influences.generation[i]);
            append_le<uint64_t>(payload, _family_influences.family_handle[i]);
            append_le<int32_t>(payload, _family_influences.cell[i]);
            append_le<int64_t>(payload, _family_influences.stable_id[i]);
            append_le<int64_t>(payload, _family_influences.population[i]);
            append_le<int64_t>(payload, _family_influences.cash[i]);
            append_le<int64_t>(payload, _family_influences.building_asset[i]);
            append_le<int32_t>(payload,
                _family_influences.population_share_q16[i]);
            append_le<int32_t>(payload,
                _family_influences.cash_share_q16[i]);
            append_le<int32_t>(payload,
                _family_influences.building_share_q16[i]);
            append_le<int32_t>(payload, _family_influences.score_q16[i]);
            append_le<int32_t>(payload, _family_influences.satisfaction_q16[i]);
            append_le<uint8_t>(payload, _family_influences.prestige_level[i]);
            append_le<uint8_t>(payload,
                _family_influences.pending_target_level[i]);
            append_le<uint8_t>(payload, _family_influences.review_streak[i]);
            append_le<int64_t>(payload, _family_influences.last_review_day[i]);
        }
        if (_save.family_influence_cursor >= static_cast<int32_t>(
                _family_influences.active.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_INFLUENCES,
            static_cast<uint32_t>(_save.family_influence_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_TRAIT_COMMANDS) {
        constexpr int32_t record_bytes = 48;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(_family_trait_commands.size(),
            _save.family_trait_command_cursor + max_records);
        const int32_t begin = _save.family_trait_command_cursor;
        for (; _save.family_trait_command_cursor < end;
             ++_save.family_trait_command_cursor) {
            const FamilyTraitCommand &command =
                _family_trait_commands[_save.family_trait_command_cursor];
            append_le<int32_t>(payload, command.operation);
            append_le<uint64_t>(payload, command.family_handle);
            append_le<int32_t>(payload, command.trait_id);
            append_le<int32_t>(payload, command.strength_q16);
            append_le<int64_t>(payload, command.effective_day);
            append_le<int32_t>(payload, command.priority);
            append_le<int64_t>(payload, command.sequence);
            append_le<uint64_t>(payload, command.submit_order);
        }
        if (_save.family_trait_command_cursor >= static_cast<int32_t>(
                _family_trait_commands.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_TRAIT_COMMANDS,
            static_cast<uint32_t>(_save.family_trait_command_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_EXPEDITIONS) {
        const int32_t begin = _save.family_expedition_cursor;
        while (_save.family_expedition_cursor < static_cast<int32_t>(
                _family_expeditions.active.size())) {
            const int32_t i = _save.family_expedition_cursor;
            std::vector<uint8_t> record;
            append_le<int32_t>(record, i);
            append_le<uint8_t>(record, _family_expeditions.active[i]);
            append_le<uint32_t>(record, _family_expeditions.generation[i]);
            append_le<int64_t>(record, _family_expeditions.stable_id[i]);
            append_le<uint64_t>(record, _family_expeditions.country_handle[i]);
            append_le<uint64_t>(record, _family_expeditions.family_handle[i]);
            append_le<int32_t>(record, _family_expeditions.source_cell[i]);
            append_le<int32_t>(record, _family_expeditions.target_cell[i]);
            append_le<int64_t>(record, _family_expeditions.departure_day[i]);
            append_le<int64_t>(record, _family_expeditions.due_day[i]);
            append_le<int32_t>(record, _family_expeditions.route_cost[i]);
            append_le<int32_t>(record, _family_expeditions.speed[i]);
            append_le<uint8_t>(record, _family_expeditions.state[i]);
            append_le<int64_t>(record, _family_expeditions.population[i]);
            append_le<int64_t>(record,
                _family_expeditions.effect_transaction_id[i]);
            append_le<uint64_t>(record, _family_expeditions.idempotency_key[i]);
            const uint32_t route_count = _family_expeditions.active[i] != 0
                ? _family_expeditions.route_count[i] : 0;
            const uint32_t payload_count = _family_expeditions.active[i] != 0
                ? _family_expeditions.payload_count[i] : 0;
            append_le<uint32_t>(record, route_count);
            append_le<uint32_t>(record, payload_count);
            const uint32_t route_begin = _family_expeditions.route_begin[i];
            for (uint32_t r = 0; r < route_count; ++r) {
                append_le<int32_t>(record,
                    _family_expedition_route_cells[route_begin + r]);
                append_le<int32_t>(record,
                    _family_expedition_route_costs[route_begin + r]);
            }
            const uint32_t payload_begin =
                _family_expeditions.payload_begin[i];
            for (uint32_t p = 0; p < payload_count; ++p) {
                const FamilyExpeditionPayload &lane =
                    _family_expedition_payloads[payload_begin + p];
                append_le<uint64_t>(record, lane.source_cohort_handle);
                append_le<int32_t>(record, lane.signature);
                append_le<int64_t>(record, lane.people);
                append_le<int64_t>(record, lane.funds);
                append_le<int64_t>(record, lane.epoch_income);
                append_le<int64_t>(record, lane.epoch_expense);
                append_le<int64_t>(record, lane.epoch_in_kind_income);
                append_le<int64_t>(record, lane.income_ema);
                append_le<int64_t>(record, lane.epoch_tax_paid);
                append_le<int64_t>(record, lane.epoch_subsidy_received);
                append_le<int64_t>(record, lane.income_baseline_ema);
                append_le<int64_t>(record, lane.demography_residual);
                append_le<int64_t>(record, lane.cash_claim);
                append_le<int64_t>(record, lane.owner_employed);
                append_le<int64_t>(record, lane.employee_employed);
                append_le<uint16_t>(record, lane.needs_satisfaction);
                append_le<uint16_t>(record, lane.worst_need_id);
                append_le<uint16_t>(record, lane.composite_satisfaction);
                append_le<uint8_t>(record, lane.worst_dimension_id);
                for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                    append_le<uint16_t>(record, lane.satisfaction_dims[dim]);
                append_le<uint32_t>(record, lane.person_count);
                for (uint32_t person = 0; person < lane.person_count; ++person)
                    append_le<uint64_t>(record,
                        _family_expedition_person_handles[
                            lane.person_begin + person]);
            }
            const uint32_t cargo_count = _family_expeditions.active[i] != 0
                ? _family_expeditions.cargo_count[i] : 0;
            const uint32_t kit_count = _family_expeditions.active[i] != 0
                ? _family_expeditions.kit_building_count[i] : 0;
            append_le<uint32_t>(record, cargo_count);
            const uint32_t cargo_begin = _family_expeditions.cargo_begin[i];
            for (uint32_t c = 0; c < cargo_count; ++c) {
                const FamilyExpeditionCargoLine &line =
                    _family_expedition_cargo[cargo_begin + c];
                append_le<int32_t>(record, line.good_id);
                append_le<int64_t>(record, line.quantity);
                append_le<uint8_t>(record, line.flags);
            }
            append_le<uint32_t>(record, kit_count);
            const uint32_t kit_begin =
                _family_expeditions.kit_building_begin[i];
            for (uint32_t k = 0; k < kit_count; ++k) {
                const FamilyExpeditionKitBuilding &row =
                    _family_expedition_kit_buildings[kit_begin + k];
                append_le<int32_t>(record, row.type_id);
                append_le<int64_t>(record, row.count);
            }
            uint64_t missing_identity = 0;
            uint32_t missing_count = 0;
            uint32_t missing_begin = 0;
            if (_family_expeditions.active[i] != 0) {
                missing_identity =
                    _family_expeditions.kit_missing_stock_identity[i];
                missing_count = _family_expeditions.missing_good_count[i];
                missing_begin = _family_expeditions.missing_good_begin[i];
            }
            append_le<uint64_t>(record, missing_identity);
            append_le<uint32_t>(record, missing_count);
            for (uint32_t m = 0; m < missing_count; ++m) {
                append_le<int32_t>(record,
                    _family_expedition_missing_good_ids[missing_begin + m]);
                append_le<int64_t>(record,
                    _family_expedition_missing_good_quantities[missing_begin + m]);
            }
            if (!payload.empty() && payload.size() + record.size() + 16U >
                    static_cast<size_t>(budget)) break;
            payload.insert(payload.end(), record.begin(), record.end());
            ++_save.family_expedition_cursor;
        }
        if (_save.family_expedition_cursor >= static_cast<int32_t>(
                _family_expeditions.active.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_FAMILY_EXPEDITIONS,
            static_cast<uint32_t>(_save.family_expedition_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_TARIFF_HISTORY) {
        constexpr int32_t record_bytes = 104;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.tariff_history_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_tariff_history.countries.size()),
            begin + max_records);
        for (; _save.tariff_history_cursor < end; ++_save.tariff_history_cursor) {
            const int32_t i = _save.tariff_history_cursor;
            append_le<int32_t>(payload, _tariff_history.countries[i]);
            append_le<int32_t>(payload, _tariff_history.kinds[i]);
            append_le<int64_t>(payload, _tariff_history.bases[i]);
            append_le<int64_t>(payload, _tariff_history.assessed[i]);
            append_le<int64_t>(payload, _tariff_history.collected[i]);
            append_le<int64_t>(payload, _tariff_history.requests[i]);
            append_le<int64_t>(payload, _tariff_history.reserved[i]);
            append_le<int64_t>(payload, _tariff_history.paid[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_bases[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_collected[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_requests[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_paid[i]);
        }
        if (_save.tariff_history_cursor >= static_cast<int32_t>(
                _tariff_history.countries.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_TARIFF_HISTORY,
            static_cast<uint32_t>(_save.tariff_history_cursor - begin), payload);
    }
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
    _save.end_emitted = true;
    return make_save_chunk(SAVE_SECTION_END, 0, payload);
}



} // namespace pk
