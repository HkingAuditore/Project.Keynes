#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <string>
#include <type_traits>
#include <utility>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

// Read-only report diagnostics; stage and scheduler authority stays in the root.
int32_t NativeEconomyRuntime::stage_progress_q16() const {
    if (!_epoch_active) return _fatal ? 0 : static_cast<int32_t>(Q16_ONE - 1);
    switch (_stage) {
        case Stage::BUILDING_PLAN: {
            const int64_t phase_base = _building_plan_phase == 0 ? 0 : Q16_ONE / 20;
            const int64_t phase_progress =
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 20)) /
                std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size()));
            return static_cast<int32_t>(phase_base + phase_progress);
        }
        case Stage::LEDGER_APPLY:
            return static_cast<int32_t>(Q16_ONE / 10 +
                (_epoch_commands.empty() ? Q16_ONE / 10
                                         : (static_cast<int64_t>(_command_cursor) * (Q16_ONE / 10)) /
                                               static_cast<int64_t>(_epoch_commands.size())));
        case Stage::TRADE_SETTLE: return static_cast<int32_t>(Q16_ONE / 40);
        case Stage::TRADE_DISPATCH: return static_cast<int32_t>(Q16_ONE * 4 / 5);
        case Stage::BUILDING_EMPLOYMENT:
            return static_cast<int32_t>(Q16_ONE / 5 +
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 10)) /
                    std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size())));
        case Stage::BUILDING_PRODUCTION:
            return static_cast<int32_t>(Q16_ONE * 3 / 10 +
                (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 5)) /
                    std::max<int32_t>(1, static_cast<int32_t>(_building_active_cells.size())));
        case Stage::HOUSEHOLD_MARKET:
            return static_cast<int32_t>(Q16_ONE / 2 +
                (static_cast<int64_t>(_cell_cursor) * (Q16_ONE * 3 / 10)) /
                    std::max(1, _market.market_count));
        case Stage::STRUCTURAL_COMMIT:
            return static_cast<int32_t>(Q16_ONE * 4 / 5 +
                (_structural_commands.empty() ? Q16_ONE / 10
                                              : (static_cast<int64_t>(_structural_cursor) *
                                                 (Q16_ONE / 10)) /
                                                    static_cast<int64_t>(_structural_commands.size())));
        case Stage::WAIT_COMMIT: return static_cast<int32_t>(Q16_ONE * 17 / 20);
        case Stage::BUILDING_COMMIT: {
            const int32_t investment_cell_count = static_cast<int32_t>(
                _investment_review_cell_indices.size());
            const int64_t phase_progress = _building_commit_phase <= 0 ? 0
                : (_building_commit_phase >= 2 ? Q16_ONE / 20
                    : (static_cast<int64_t>(_building_cell_cursor) * (Q16_ONE / 20)) /
                        std::max(1, investment_cell_count));
            return static_cast<int32_t>(Q16_ONE * 9 / 10 + phase_progress);
        }
        case Stage::FAMILY_COMMIT:
            return static_cast<int32_t>(Q16_ONE * 19 / 20 +
                (_family_commit_phase == 0 ? 0 :
                    (_family_commit_phase == 1
                        ? (static_cast<int64_t>(_family_commit_cursor) *
                           (Q16_ONE / 40)) / std::max(1, _cell_count)
                        : Q16_ONE / 40)));
        case Stage::PERSON_COMMIT:
            return static_cast<int32_t>(Q16_ONE * 39 / 40 +
                std::min(4, _person_commit_phase) * (Q16_ONE / 240));
        case Stage::AGGREGATE_PUBLISH: {
            const int64_t phase = std::min<int64_t>(
                static_cast<int64_t>(_publish_phase),
                static_cast<int64_t>(PublishPhase::DONE));
            return static_cast<int32_t>(Q16_ONE * 19 / 20 +
                phase * (Q16_ONE / 20) /
                    std::max<int64_t>(1, static_cast<int64_t>(PublishPhase::DONE)));
        }
        default: return 0;
    }
}

int64_t NativeEconomyRuntime::memory_bytes() const {
    int64_t bytes = 0;
    auto cap = [&](const auto &v) { bytes += static_cast<int64_t>(v.capacity() * sizeof(typename std::decay_t<decltype(v)>::value_type)); };
    cap(_market.price_ceilings);
    for (const auto &row : _market.price_ceilings) cap(row);
    cap(_epoch_price_ceiling_observations);
    cap(_epoch_ceiling_business_requested); cap(_epoch_ceiling_business_unfilled);
    cap(_epoch_ceiling_research_requested); cap(_epoch_ceiling_research_delivered);
    cap(_population.cell_first_page); cap(_population.page_next); cap(_population.page_cell);
    cap(_population.free_pages); cap(_population.active); cap(_population.reserved);
    cap(_population.reservation_owner); cap(_population.signature_id);
    cap(_population.generation); cap(_population.population); cap(_population.funds);
    cap(_population.epoch_income); cap(_population.epoch_expense);
    cap(_population.epoch_in_kind_income); cap(_population.income_ema);
    cap(_population.epoch_tax_paid); cap(_population.epoch_subsidy_received);
    cap(_population.income_baseline_ema);
    cap(_population.needs_satisfaction); cap(_population.worst_need_id);
    cap(_population.composite_satisfaction); cap(_population.satisfaction_dims);
    cap(_population.worst_dimension_id);
    cap(_population.flags); cap(_population.demography_residual);
    cap(_birth_residual_q32);
    cap(_cell_support_ema_q16);
    cap(_cell_carrying_k_geo); cap(_cell_carrying_k_eff);
    cap(_cell_carrying_surplus_q16); cap(_cell_carrying_sat_q16);
    cap(_cell_carrying_family_surplus_q16); cap(_cell_carrying_family_bindable);
    cap(_cell_food_output_eq_period); cap(_cell_food_input_eq_period);
    cap(_cell_food_import_eq_period); cap(_cell_food_export_eq_period);
    cap(_cell_food_access_eq_period);
    cap(_cell_food_output_eq_previous); cap(_cell_food_input_eq_previous);
    cap(_cell_food_import_eq_previous); cap(_cell_food_export_eq_previous);
    cap(_cell_food_access_eq_previous); cap(_cell_food_flow_valid);
    cap(_population.owner_employed); cap(_population.employee_employed);
    cap(_families.active); cap(_families.generation); cap(_families.stable_id);
    cap(_families.surname_id); cap(_families.surname_disambiguator);
    cap(_families.founded_day); cap(_families.home_cell);
    cap(_families.origin_ethnicity); cap(_families.decline_reviews);
    cap(_families.flags); cap(_families.free_indices);
    cap(_family_memberships); cap(_family_ownerships);
    cap(_family_traits); cap(_family_trait_commands);
    cap(_family_behavior_factor_offsets); cap(_family_behavior_factor_rows);
    cap(_family_purchase_factor_q16); cap(_family_investment_factor_q16);
    cap(_family_birth_factor_q16); cap(_family_absorb_bonus_q16);
    cap(_family_colonization_population_reward);
    cap(_pending_family_split_gifts); cap(_family_policy_stamped_cells);
    cap(_epoch_cell_rain_event_threshold_q16);
    cap(_epoch_cell_cold_capacity_factor_q16);
    cap(_epoch_cell_sector_output_factor_q16);
    cap(_family_modifier_bindings); cap(_family_trigger_bindings);
    cap(_family_effect_bindings);
    cap(_family_industry_stats); cap(_family_owned_output_rows);
    for (const FamilyEffectBinding &binding : _family_effect_bindings)
        bytes += static_cast<int64_t>(binding.definition_key.capacity());
    bytes += static_cast<int64_t>(_family_effect_binding_by_instance.size()) *
        static_cast<int64_t>(sizeof(int64_t) + sizeof(size_t));
    for (const auto &entry : _family_effect_instances_by_branch)
        bytes += static_cast<int64_t>(sizeof(entry.first) +
            entry.second.capacity() * sizeof(int64_t));
    for (const auto &entry : _family_effect_instances_by_cell)
        bytes += static_cast<int64_t>(sizeof(entry.first) +
            entry.second.capacity() * sizeof(int64_t));
    cap(_family_member_offsets); cap(_family_member_edge_indices);
    cap(_family_owned_offsets); cap(_family_owned_edge_indices);
    cap(_family_cohort_offsets); cap(_family_cohort_edge_indices);
    cap(_family_building_offsets); cap(_family_building_edge_indices);
    cap(_family_cell_offsets); cap(_family_cell_indices);
    cap(_family_expeditions.active); cap(_family_expeditions.generation);
    cap(_family_expeditions.stable_id); cap(_family_expeditions.country_handle);
    cap(_family_expeditions.family_handle); cap(_family_expeditions.source_cell);
    cap(_family_expeditions.target_cell); cap(_family_expeditions.departure_day);
    cap(_family_expeditions.due_day); cap(_family_expeditions.route_cost);
    cap(_family_expeditions.speed); cap(_family_expeditions.state);
    cap(_family_expeditions.population); cap(_family_expeditions.route_begin);
    cap(_family_expeditions.route_count); cap(_family_expeditions.payload_begin);
    cap(_family_expeditions.payload_count);
    cap(_family_expeditions.effect_transaction_id);
    cap(_family_expeditions.idempotency_key); cap(_family_expeditions.free_indices);
    cap(_family_expedition_route_cells); cap(_family_expedition_route_costs);
    cap(_family_expedition_payloads); cap(_family_expedition_person_handles);
    cap(_family_expedition_due_heap); cap(_colonization_receipts);
    cap(_colonization_quote_cache); cap(_colonization_quote_route_cells);
    cap(_colonization_quote_route_costs); cap(_colonization_distance);
    cap(_colonization_distance_stamp); cap(_colonization_parent);
    cap(_colonization_parent_stamp); cap(_colonization_route_heap);
    bytes += static_cast<int64_t>(_family_expedition_target_index.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int32_t));
    bytes += static_cast<int64_t>(_colonization_quote_index.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int32_t));
    cap(_persons.active); cap(_persons.generation); cap(_persons.stable_id);
    cap(_persons.family_handle); cap(_persons.cohort_handle);
    cap(_persons.given_name_id); cap(_persons.name_disambiguator);
    cap(_persons.notable_since_day); cap(_persons.flags); cap(_persons.cash_claim);
    cap(_persons.family_equity_share_q32); cap(_persons.epoch_job_income);
    cap(_persons.epoch_business_result); cap(_persons.epoch_consumption_expense);
    cap(_persons.epoch_tax); cap(_persons.income_ema);
    cap(_persons.needs_satisfaction); cap(_persons.worst_need_id);
    cap(_persons.building_handle); cap(_persons.job_kind);
    cap(_persons.employee_role_index); cap(_persons.job_since_day);
    cap(_persons.free_indices); cap(_person_needs); cap(_person_epoch_needs);
    cap(_person_family_offsets); cap(_person_family_indices);
    cap(_person_cohort_offsets); cap(_person_cohort_indices);
    cap(_person_cell_offsets); cap(_person_cell_indices);
    cap(_person_building_offsets); cap(_person_building_indices);
    cap(_person_need_offsets); cap(_person_opening_cash_claim);
    cap(_person_previous_building_handle); cap(_person_previous_job_kind);
    cap(_person_previous_employee_role_index);
    cap(_settlements.tier); cap(_settlements.name_active);
    cap(_settlements.name_forced);
    cap(_settlements.prosperity_generation);
    cap(_settlements.name_roll_generation);
    cap(_settlements.prefix); cap(_settlements.root); cap(_settlements.suffix);
    cap(_settlements.disambiguator);
    cap(_market.stock); cap(_market.price); cap(_market.demand_ema);
    cap(_market.last_shortage_q16); cap(_market.cell_to_market);
    cap(_environment_temperature_q16); cap(_environment_temperature_30d_q16);
    cap(_environment_moisture_q16); cap(_environment_plant_available_water_q16);
    cap(_environment_precipitation_q16);
    cap(_environment_snow_q16); cap(_environment_weather_q16);
    cap(_audit_shadow_population); cap(_audit_shadow_funds);
    cap(_audit_shadow_market_stock);
    cap(_audit_population_lane_stamp); cap(_audit_market_lane_stamp);
    cap(_audit_population_touched_lanes); cap(_audit_market_touched_lanes);
    cap(_market_signals.cell_offsets); cap(_market_signals.good_ids);
    cap(_market_signals.dense_index);
    cap(_market_signals.business_demand_ema); cap(_market_signals.offered_supply_ema);
    cap(_market_signals.realized_withdrawal_ema);
    cap(_market_signals.cost_anchor_price);
    cap(_market_signals_rebuild_scratch.cell_offsets);
    cap(_market_signals_rebuild_scratch.good_ids);
    cap(_market_signals_rebuild_scratch.dense_index);
    cap(_market_signals_rebuild_scratch.business_demand_ema);
    cap(_market_signals_rebuild_scratch.offered_supply_ema);
    cap(_market_signals_rebuild_scratch.realized_withdrawal_ema);
    cap(_market_signals_rebuild_scratch.cost_anchor_price);
    cap(_market_signal_overflow_cells);
    cap(_epoch_business_demand_ema); cap(_epoch_desired_business_demand);
    cap(_epoch_funded_business_demand); cap(_epoch_offered_supply_ema);
    cap(_epoch_producer_sellable_current);
    cap(_epoch_producer_merchant_sold_current);
    cap(_epoch_producer_discarded_current);
    cap(_epoch_research_demand_by_cell); cap(_epoch_research_demand_by_market);
    cap(_epoch_bullion_quota_keys); cap(_epoch_bullion_quota_initial);
    cap(_epoch_bullion_quota_remaining);
    cap(_investment_monetary_units_by_cell);
    cap(_epoch_cost_anchor_price);
    cap(_epoch_nonhousehold_withdrawals);
    cap(_production_input_reserve);
    cap(_construction_material_reserve);
    cap(_cell_last_settlement_day); cap(_cell_settlement_generation);
    cap(_cell_price_stock_gen); cap(_cell_owner_cash_gen); cap(_cell_population_gen);
    cap(_cell_building_structure_gen); cap(_cell_technology_gen);
    cap(_cell_resource_gen); cap(_cell_trade_gen); cap(_cell_effect_shortage_q16);
    cap(_cell_essentials_shortage_q16); cap(_cell_resource_abundance_q16);
    cap(_cell_previous_precipitation_q16); cap(_cell_rain_event_q16);
    cap(_epoch_cell_country); cap(_epoch_cell_visible); cap(_epoch_country_technologies);
    cap(_city_output_shared_goods_q16); cap(_city_output_cell_offsets);
    cap(_city_output_good_indices); cap(_city_output_factors_q16);
    cap(_city_output_scope_cells_scratch);
    cap(_city_output_scope_stat_ids_scratch);
    cap(_epoch_cell_compiled_tax_policy);
    cap(_epoch_cell_active_tax_mask);
    cap(_epoch_compiled_cell_tax_policies);
    cap(_epoch_compiled_cell_tax_overrides);
    cap(_epoch_compiled_cell_tax_default_rows);
    cap(_epoch_compiled_cell_tax_default_rates);
    cap(_epoch_country_building_available);
    cap(_epoch_country_support_yield);
    cap(_epoch_country_good_available);
    cap(_epoch_country_profession_available);
    cap(_epoch_country_variant_available);
    cap(_epoch_country_building_type_offsets);
    cap(_epoch_country_building_type_indices);
    cap(_fiscal_previous_requests);
    cap(_fiscal_previous_country_handles);
    cap(_fiscal_reservation_requests);
    cap(_fiscal_current_requests); cap(_fiscal_budgets);
    cap(_fiscal_remaining); cap(_fiscal_epoch_bases);
    cap(_fiscal_epoch_assessed); cap(_fiscal_epoch_collected);
    cap(_fiscal_epoch_paid); cap(_fiscal_escrow_by_country);
    cap(_fiscal_last_bases); cap(_fiscal_last_assessed);
    cap(_fiscal_last_collected); cap(_fiscal_last_requests);
    cap(_fiscal_last_reserved); cap(_fiscal_last_paid);
    cap(_fiscal_last_unmet); cap(_fiscal_cumulative_bases);
    cap(_fiscal_cumulative_collected);
    cap(_fiscal_cumulative_requests); cap(_fiscal_cumulative_paid);
    cap(_tariff_epoch_cells); cap(_tariff_epoch_kinds);
    cap(_tariff_epoch_bases); cap(_tariff_epoch_assessed);
    cap(_tariff_epoch_collected); cap(_tariff_epoch_requests);
    cap(_tariff_epoch_reserved); cap(_tariff_epoch_paid);
    cap(_tariff_epoch_events); cap(_tariff_lane_index);
    cap(_tariff_lane_stamp);
    cap(_tariff_history.countries); cap(_tariff_history.kinds);
    cap(_tariff_history.bases); cap(_tariff_history.assessed);
    cap(_tariff_history.collected); cap(_tariff_history.requests);
    cap(_tariff_history.reserved); cap(_tariff_history.paid);
    cap(_tariff_history.cumulative_bases);
    cap(_tariff_history.cumulative_collected);
    cap(_tariff_history.cumulative_requests);
    cap(_tariff_history.cumulative_paid);
    cap(_country_good_trade.countries); cap(_country_good_trade.goods);
    cap(_country_good_trade.import_quantity);
    cap(_country_good_trade.export_quantity);
    cap(_country_good_trade.import_base); cap(_country_good_trade.export_base);
    cap(_country_good_trade.import_tariff);
    cap(_country_good_trade.export_tariff);
    cap(_country_good_trade.batch_epoch);
    cap(_country_good_trade.batch_import_quantity);
    cap(_country_good_trade.batch_export_quantity);
    cap(_country_good_trade.batch_import_base);
    cap(_country_good_trade.batch_export_base);
    cap(_country_good_trade.batch_import_tariff);
    cap(_country_good_trade.batch_export_tariff);
    cap(_country_partner_trade.countries); cap(_country_partner_trade.partners);
    cap(_country_partner_trade.import_quantity);
    cap(_country_partner_trade.export_quantity);
    cap(_country_partner_trade.import_base);
    cap(_country_partner_trade.export_base);
    cap(_country_partner_trade.order_count);
    cap(_country_partner_trade.batch_epoch);
    cap(_country_partner_trade.batch_import_quantity);
    cap(_country_partner_trade.batch_export_quantity);
    cap(_country_partner_trade.batch_import_base);
    cap(_country_partner_trade.batch_export_base);
    cap(_country_partner_trade.batch_order_count);
    cap(_country_good_display_rows); cap(_country_partner_display_rows);
    cap(_country_good_display_dirty); cap(_country_partner_display_dirty);
    for (const auto &rows : _country_good_display_rows) cap(rows);
    for (const auto &rows : _country_partner_display_rows) cap(rows);
    bytes += static_cast<int64_t>(_country_good_trade_index.size()) *
        static_cast<int64_t>(sizeof(std::pair<const uint64_t, int32_t>));
    bytes += static_cast<int64_t>(_country_partner_trade_index.size()) *
        static_cast<int64_t>(sizeof(std::pair<const uint64_t, int32_t>));
    bytes += static_cast<int64_t>(_tariff_history_index.size()) *
        static_cast<int64_t>(sizeof(std::pair<const uint64_t, int32_t>));
    cap(_income_taxable_base_by_slot);
    cap(_income_subsidy_floor_by_slot);
    cap(_epoch_market_ids); cap(_epoch_market_work_weights);
    cap(_economy_live_cells);
    cap(_epoch_settlement_cells); cap(_epoch_building_cells);
    cap(_epoch_plan_cells);
    cap(_household_post_saturation_scratch);
    cap(_household_post_restarted_scratch);
    cap(_household_post_failed_scratch);
    cap(_household_reserve_shortfall_scratch);
    cap(_employment_metrics_epoch_by_cell); cap(_employment_owner_jobs_by_cell);
    cap(_employment_employee_jobs_by_cell); cap(_employment_unemployed_by_cell);
    cap(_building_survival_utilization_floor_q16);
    cap(_building_planned_capacity_before_climate_q16);
    cap(_building_funded_capacity_q16); cap(_building_working_capital_allocated);
    cap(_building_owner_livelihood_credit);
    cap(_building_merchant_credit_limit);
    cap(_building_recovery_probe_capacity_q16);
    cap(_building_recovery_liquidation_eligible);
    cap(_building_investment_score_q16); cap(_building_investment_payback_days);
    cap(_building_investment_rejection); cap(_trade_active_keys);
    cap(_trade_active_key_present);
    cap(_building_review_phase_offsets); cap(_building_review_group_indices);
    cap(_building_special_reset_group_indices);
    cap(_investment_employment_cells);
    cap(_investment_review_cell_indices);
    cap(_investment_resource_committed_by_cell);
    cap(_investment_merchant_cash_by_cell);
    cap(_investment_outstanding_credit_by_cell);
    cap(_investment_resource_commitment_stamp);
    cap(_investment_cell_finance_stamp);
    cap(_investment_output_signals_scratch);
    cap(_investment_incumbent_lanes_scratch);
    cap(_investment_good_type_offsets);
    cap(_investment_good_type_indices);
    cap(_investment_active_good_words);
    cap(_investment_active_goods_scratch);
    cap(_investment_type_stamp);
    cap(_investment_good_stamp);
    cap(_investment_review_types_scratch);
    cap(_investment_good_queue_scratch);
    cap(_startup_demand_values);
    cap(_startup_demand_stamps);
    cap(_startup_demand_touched_keys);
    cap(_startup_monetary_good_indices);
    cap(_startup_remote_lanes);
    cap(_startup_remote_groups);
    cap(_startup_inbound_lanes);
    cap(_startup_remote_accumulator_scratch);
    cap(_market_results_scratch);
    for (const MarketResult &result : _market_results_scratch)
        bytes += result.capacity_bytes();
    cap(_production_results_scratch);
    for (const ProductionResult &result : _production_results_scratch)
        bytes += result.capacity_bytes();
    bytes += static_cast<int64_t>(_investment_pending_by_cell_type.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int64_t));
    bytes += static_cast<int64_t>(_investment_existing_by_cell_type.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(InvestmentExistingType));
    cap(_trade_signal_clock_keys); cap(_trade_signal_first_seen_day);
    cap(_trade_signal_bulk_keys_scratch);
    cap(_trade_signal_first_dispatch_day); cap(_trade_signal_last_attempt_day);
    cap(_trade_signal_last_rejection_reason); cap(_trade_signal_deadline_reported);
    cap(_owner_retained_outputs);
    cap(_trade_topology.neighbors); cap(_trade_topology.passable);
    cap(_trade_topology.enter_cost); cap(_trade_topology.component);
    cap(_trade_topology.edge_cost);
    cap(_trade_topology.canal_edge_mask); cap(_trade_topology.canal_water);
    cap(_trade_topology.water_class); cap(_trade_topology.has_river);
    cap(_trade_topology.component_layers);
    for (const auto &graph : _trade_topology.water_portals) {
        cap(graph.cell_portal); cap(graph.portal_cells);
        cap(graph.offsets); cap(graph.targets); cap(graph.costs);
        cap(graph.reverse_offsets); cap(graph.reverse_targets); cap(graph.reverse_costs);
    }
    cap(_epoch_country_water_capability);
    cap(_transport_succ_cells); cap(_transport_succ_costs);
    cap(_canal_quotes); cap(_canal_projects); cap(_canal_receipts);
    for (const CanalQuote &quote : _canal_quotes) {
        cap(quote.route_cells); cap(quote.route_edge_dirs);
    }
    for (const CanalProject &project : _canal_projects) {
        cap(project.route_cells); cap(project.route_edge_dirs);
    }
    bytes += static_cast<int64_t>(_canal_quote_index.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int32_t));
    bytes += static_cast<int64_t>(_canal_project_index.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int32_t));
    cap(_trade_plan.sources); cap(_trade_plan.destinations);
    cap(_trade_plan.scan_cells); cap(_trade_plan.scan_goods); cap(_trade_plan.scan_inbound);
    cap(_trade_plan.working_candidates); cap(_trade_plan.ready_candidates);
    cap(_trade_plan.distance); cap(_trade_plan.distance_stamp);
    cap(_trade_plan.target_signal); cap(_trade_plan.target_stamp);
    cap(_trade_plan.heap); cap(_trade_plan.route_cache_keys);
    cap(_trade_plan.route_cache_costs);
    cap(_trade_plan_init.component_queue);
    cap(_trade_plan_init.inflight_keys);
    cap(_trade_plan_init.retained_active_keys);
    cap(_trade_plan_init.rotated_inbound);
    cap(_trade_orders.ids); cap(_trade_orders.sources); cap(_trade_orders.destinations);
    cap(_trade_orders.countries); cap(_trade_orders.departure_days);
    cap(_trade_orders.arrival_days); cap(_trade_orders.cash_escrow);
    cap(_trade_orders.capacity_work); cap(_trade_orders.states);
    cap(_trade_orders.cargo_delivered); cap(_trade_orders.line_offsets);
    cap(_trade_orders.line_goods); cap(_trade_orders.line_quantities);
    cap(_trade_orders.line_unit_prices); cap(_trade_orders.seller_offsets);
    cap(_trade_orders.seller_handles); cap(_trade_orders.seller_weights);
    cap(_trade_orders.arrival_bucket_days);
    cap(_trade_orders.arrival_bucket_offsets);
    cap(_trade_orders.arrival_bucket_orders);
    cap(_trade_flows.cells); cap(_trade_flows.goods); cap(_trade_flows.import_ema);
    cap(_trade_flows.export_ema); cap(_trade_flows.period_import);
    cap(_trade_flows.period_export);
    cap(_labor_signals.cell_offsets); cap(_labor_signals.profession_ids);
    cap(_labor_signals.base_living_cost); cap(_labor_signals.role_living_cost);
    cap(_labor_signals.contract_wage_ema); cap(_labor_signals.paid_wage_ema);
    cap(_labor_signals.job_days); cap(_labor_signals.pay_ratio_q16);
    cap(_labor_signals_rebuild_scratch.cell_offsets);
    cap(_labor_signals_rebuild_scratch.profession_ids);
    cap(_labor_signals_rebuild_scratch.base_living_cost);
    cap(_labor_signals_rebuild_scratch.role_living_cost);
    cap(_labor_signals_rebuild_scratch.contract_wage_ema);
    cap(_labor_signals_rebuild_scratch.paid_wage_ema);
    cap(_labor_signals_rebuild_scratch.job_days);
    cap(_labor_signals_rebuild_scratch.pay_ratio_q16);
    cap(_market_cell_offsets); cap(_market_cells);
    cap(_signatures); cap(_plans); cap(_survival_required_need_indices);
    cap(_survival_food_need_mask);
    cap(_rules); cap(_rule_params); cap(_pending_commands);
    cap(_epoch_commands); cap(_structural_commands); cap(_committed_cells);
    cap(_staging_cells); cap(_staging_touched_cells);
    for (const std::vector<int32_t> &buffer : _staging_touched_task_scratch)
        cap(buffer);
    cap(_staging_cell_generation);
    cap(_structural_touched_cells); cap(_population_changed_cells);
    cap(_demand_basis_cache_day); cap(_demand_basis_variant_scores);
    cap(_demand_basis_variant_prices); cap(_demand_basis_need_score_sums);
    cap(_demand_basis_need_composites); cap(_demand_basis_need_environment);
    cap(_building_types); cap(_building_type_market_signal_goods);
    cap(_building_type_labor_signal_professions);
    cap(_building_employee_roles); cap(_building_construction_goods);
    cap(_building_maintenance_author_offsets);
    cap(_building_maintenance_author_goods);
    cap(_building_maintenance_goods);
	cap(_building_upgrade_family_ids); cap(_building_upgrade_family_indices);
	cap(_building_upgrade_tiers);
    cap(_building_inputs); cap(_building_input_candidates);
    cap(_building_outputs); cap(_building_resources);
	cap(_building_output_cost_shares_q16);
	cap(_cycle_flow_good_ids);
    cap(_building_resource_generation);
    cap(_building_conditions); cap(_buildings);
    cap(_building_groups_rebuild_scratch);
    cap(_building_existing_indices_scratch); cap(_building_new_indices_scratch);
    cap(_building_investment_score_rebuild_scratch);
    cap(_building_investment_payback_rebuild_scratch);
    cap(_building_investment_rejection_rebuild_scratch);
    cap(_building_free_role_spans_by_type);
    for (const auto &spans : _building_free_role_spans_by_type) cap(spans);
    cap(_building_market_signal_stamp); cap(_building_labor_signal_stamp);
    cap(_building_cell_offsets);
    cap(_building_active_cells);
    cap(_building_employee_filled);
    cap(_building_last_input_selected_goods);
    cap(_building_role_contract_wage); cap(_building_role_base_living_cost);
    cap(_building_role_living_cost); cap(_building_role_local_average_wage);
    cap(_building_role_base_wage_due); cap(_building_role_base_wage_paid);
    cap(_building_role_bonus_due); cap(_building_role_bonus_paid);
    cap(_pending_construction);
    cap(_pending_construction_cell_offsets);
    cap(_pending_construction_cell_indices);
    cap(_resource_snapshot); cap(_resource_remaining);
    cap(_resource_harvest_remaining);
    cap(_resource_gen_base); cap(_resource_gen_temp); cap(_resource_gen_moisture);
    cap(_resource_gen_self); cap(_resource_decay_base); cap(_resource_decay_temp);
    cap(_resource_decay_moisture); cap(_resource_decay_self_q16);
    cap(_resource_ecology_capacity); cap(_resource_ecology_growth_q16);
    cap(_resource_temp_lo_q16); cap(_resource_temp_hi_q16);
    cap(_resource_deltas); cap(_last_published_resource_deltas);
    cap(_resource_lane_generation); cap(_resource_touched_lanes);
    cap(_last_published_resource_touched_lanes);
    cap(_building_elevation_q16); cap(_building_terrain);
    cap(_building_landform); cap(_building_vegetation); cap(_building_is_water);
    cap(_building_has_river); cap(_building_neighbors);
    bytes += trace_memory_bytes();
    return bytes;
}

Dictionary NativeEconomyRuntime::household_slice_breakdown_ms() const {
    static constexpr const char *PHASE_NAMES[HOUSEHOLD_SLICE_PHASE_COUNT] = {
        "settle.prepare",
        "settle.worker",
        "settle.merge_aggregate",
        "settle.merge_trade",
        "settle.trace",
        "settle.other",
        "post_buildings",
        "reserve_shortfall",
        "income_subsidy",
        "structural_sort",
    };
    Dictionary out;
    for (size_t phase = 0; phase < HOUSEHOLD_SLICE_PHASE_COUNT; ++phase) {
        const std::string key =
            std::string("household_market.") + PHASE_NAMES[phase];
        out[key.c_str()] = _household_slice_phase_ms[phase];
    }
    return out;
}

Dictionary NativeEconomyRuntime::household_slice_breakdown_work() const {
    static constexpr const char *PHASE_NAMES[HOUSEHOLD_SLICE_PHASE_COUNT] = {
        "settle.prepare",
        "settle.worker",
        "settle.merge_aggregate",
        "settle.merge_trade",
        "settle.trace",
        "settle.other",
        "post_buildings",
        "reserve_shortfall",
        "income_subsidy",
        "structural_sort",
    };
    Dictionary out;
    for (size_t phase = 0; phase < HOUSEHOLD_SLICE_PHASE_COUNT; ++phase) {
        const std::string key =
            std::string("household_market.") + PHASE_NAMES[phase];
        out[key.c_str()] = _household_slice_phase_work[phase];
    }
    return out;
}

Dictionary NativeEconomyRuntime::compact_report() const {
    Dictionary out;
    const int64_t age_days = _epoch_active
        ? std::max<int64_t>(0, _current_day - _sample_day)
        : _settlement_max_age_days;
    const int64_t deadline_day = _sample_day;
    const bool commit_due = _epoch_active && _current_day >= deadline_day;

    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["report_mode"] = "compact_slice";
    out["configured"] = _configured;
    out["bootstrapped"] = _bootstrapped;
    out["epoch_active"] = _epoch_active;
    out["epoch_id"] = _epoch_id;
    out["sample_day"] = _sample_day;
    out["current_day"] = _current_day;
    out["commit_day"] = _commit_day;
    out["age_days"] = age_days;
    out["stage"] = stage_name();
    out["next_stage"] = stage_name();
    out["executed_stage"] = stage_name(_executed_stage);
    out["executed_substage"] = _executed_substage.c_str();
    out["progress_q16"] = stage_progress_q16();
    out["publish_phase"] = publish_phase_name(_publish_phase);
    out["building_commit_phase"] = _stage == Stage::BUILDING_COMMIT
        ? _building_commit_phase : -1;
    out["processed_cells"] = _processed_cells;
    out["processed_cohorts"] = _processed_cohorts;
    out["processed_rules"] = _processed_rules;
    out["processed_building_groups"] = _processed_building_groups;
    out["climate_profiled_building_groups"] =
        _climate_profiled_building_groups;
    out["climate_limited_building_groups"] =
        _climate_limited_building_groups;
    out["average_climate_capacity_q16"] =
        _climate_profiled_building_groups > 0
        ? _climate_capacity_sum_q16 / _climate_profiled_building_groups
        : Q16_ONE;

    if (_executed_stage == Stage::TRADE_PLANNING || _trade_plan_ms > 0.0) {
        const double accounted_ms = _trade_plan_scan_body_ms +
            _trade_plan_scan_finalize_ms + _trade_plan_route_prepare_ms +
            _trade_plan_route_expand_ms + _trade_plan_route_finalize_ms;
        Dictionary breakdown_ms;
        breakdown_ms["trade_planning.scan_body"] = _trade_plan_scan_body_ms;
        breakdown_ms["trade_planning.scan_finalize"] = _trade_plan_scan_finalize_ms;
        breakdown_ms["trade_planning.route_prepare"] = _trade_plan_route_prepare_ms;
        breakdown_ms["trade_planning.route_expand"] = _trade_plan_route_expand_ms;
        breakdown_ms["trade_planning.route_finalize"] = _trade_plan_route_finalize_ms;
        breakdown_ms["trade_planning.other"] =
            std::max(0.0, _trade_plan_ms - accounted_ms);
        out["trade_plan_breakdown_ms"] = breakdown_ms;

        Dictionary breakdown_work;
        breakdown_work["trade_planning.scan_pairs"] = _trade_plan_scan_pairs_slice;
        breakdown_work["trade_planning.route_sources_prepared"] =
            _trade_plan_route_sources_prepared_slice;
        breakdown_work["trade_planning.route_expansions"] =
            _trade_plan_route_expansions_slice;
        breakdown_work["trade_planning.candidates_finalized"] =
            _trade_plan_candidates_finalized_slice;
        out["trade_plan_breakdown_work"] = breakdown_work;

        const char *substage = "";
        double substage_ms = 0.0;
        const auto choose_substage = [&](const char *name, double value) {
            if (value > substage_ms) {
                substage = name;
                substage_ms = value;
            }
        };
        choose_substage("scan_body", _trade_plan_scan_body_ms);
        choose_substage("scan_finalize", _trade_plan_scan_finalize_ms);
        choose_substage("route_prepare", _trade_plan_route_prepare_ms);
        choose_substage("route_expand", _trade_plan_route_expand_ms);
        choose_substage("route_finalize", _trade_plan_route_finalize_ms);
        choose_substage("other", std::max(0.0, _trade_plan_ms - accounted_ms));
        out["trade_plan_substage"] = substage;
        if (_executed_substage.empty()) out["executed_substage"] = substage;
    }

    if (_executed_stage == Stage::AGGREGATE_PUBLISH) {
        Dictionary breakdown_ms;
        Dictionary breakdown_work;
        for (size_t phase = 0; phase < static_cast<size_t>(PublishPhase::COUNT); ++phase) {
            const std::string key = std::string("aggregate_publish.") +
                publish_phase_name(static_cast<PublishPhase>(phase));
            breakdown_ms[key.c_str()] = _publish_slice_phase_ms[phase];
            breakdown_work[key.c_str()] = _publish_slice_phase_work[phase];
        }
        const size_t trade_init_phase = static_cast<size_t>(PublishPhase::TRADE_INIT);
        if (_publish_slice_phase_ms[trade_init_phase] > 0.0 &&
            _executed_substage.rfind("trade_init.", 0) == 0) {
            const std::string key = std::string("aggregate_publish.") +
                _executed_substage;
            breakdown_ms[key.c_str()] = _publish_slice_phase_ms[trade_init_phase];
            breakdown_work[key.c_str()] = _publish_slice_phase_work[trade_init_phase];
            breakdown_ms["aggregate_publish.trade_init"] = 0.0;
            breakdown_work["aggregate_publish.trade_init"] = 0;
        }
        out["publish_breakdown_ms"] = breakdown_ms;
        out["publish_breakdown_work"] = breakdown_work;
    }

    if (_executed_stage == Stage::BUILDING_COMMIT) {
        static constexpr const char *PHASE_NAMES[BUILDING_COMMIT_PHASE_COUNT] = {
            "review_prepare", "special_reset", "recovery_review",
            "construction_commit", "investment_prepare", "investment",
            "finalize",
        };
        Dictionary breakdown_ms;
        Dictionary breakdown_work;
        for (size_t phase = 0; phase < BUILDING_COMMIT_PHASE_COUNT; ++phase) {
            const std::string key = std::string("building_commit.") + PHASE_NAMES[phase];
            breakdown_ms[key.c_str()] = _building_commit_slice_phase_ms[phase];
            breakdown_work[key.c_str()] = _building_commit_slice_phase_work[phase];
        }
        out["building_commit_breakdown_ms"] = breakdown_ms;
        out["building_commit_breakdown_work"] = breakdown_work;
    }
    if (_executed_stage == Stage::HOUSEHOLD_MARKET) {
        out["household_market_breakdown_ms"] =
            household_slice_breakdown_ms();
        out["household_market_breakdown_work"] =
            household_slice_breakdown_work();
    }

    out["economy_event_newest_id"] = _next_event_id - 1;
    out["economy_event_last_batch_count"] = _committed_event_batches.empty() ? 0 :
        static_cast<int64_t>(_committed_event_batches.back().events.size());
    out["worker_tasks"] = _worker_tasks;
    out["high_speed_batching_enabled"] = _high_speed_batching_enabled;
    out["high_speed_batch_multiplier"] = _active_batch_multiplier;
    out["high_speed_market_dispatches_saved"] =
        _high_speed_market_dispatches_saved;
    out["high_speed_production_dispatches_saved"] =
        _high_speed_production_dispatches_saved;
    out["building_production_worker_tasks"] = _production_worker_tasks;
    out["building_production_worker_parallel_dispatches"] =
        _production_worker_parallel_dispatches;
    out["building_production_worker_weight_total"] =
        _production_worker_weight_total;
    out["building_production_worker_task_weight_min"] =
        _production_worker_task_weight_min;
    out["building_production_worker_task_weight_max"] =
        _production_worker_task_weight_max;
    out["building_production_worker_imbalance_q16_max"] =
        _production_worker_imbalance_q16_max;
    out["building_production_worker_cpu_ms"] =
        _production_worker_cpu_ms;
    out["audit_worker_tasks_max"] = _audit_worker_tasks_max;
    out["audit_worker_dispatches"] = _audit_worker_dispatches;
    out["audit_worker_cpu_ms"] = _audit_worker_cpu_ms;
    out["building_plan_worker_tasks_max"] =
        _building_plan_worker_tasks_max;
    out["building_plan_worker_parallel_dispatches"] =
        _building_plan_worker_parallel_dispatches;
    out["building_plan_worker_cpu_ms"] =
        _building_plan_worker_cpu_ms;
    out["opening_audit_fast_paths"] = _opening_audit_fast_paths;
    out["opening_audit_full_verifications"] =
        _opening_audit_full_verifications;
    out["closing_audit_mode"] = _closing_audit_mode == 0 ? "FULL" :
        (_closing_audit_mode == 1 ? "PROBE" : "INCREMENTAL");
    out["closing_audit_runtime_disabled"] =
        _closing_audit_runtime_disabled;
    out["closing_audit_fast_paths"] = _closing_audit_fast_paths;
    out["closing_audit_full_verifications"] =
        _closing_audit_full_verifications;
    out["closing_audit_mismatches"] = _closing_audit_mismatches;
    out["closing_audit_mismatch_ledger"] =
        _closing_audit_mismatch_ledger.c_str();
    out["closing_audit_mismatch_lane"] = _closing_audit_mismatch_lane;
    out["closing_audit_population_touched_lanes"] =
        static_cast<int64_t>(_audit_population_touched_lanes.size());
    out["closing_audit_market_touched_lanes"] =
        static_cast<int64_t>(_audit_market_touched_lanes.size());
    out["closing_audit_population_full_scan_entries"] =
        _closing_audit_population_full_scan_entries;
    out["closing_audit_market_full_scan_entries"] =
        _closing_audit_market_full_scan_entries;
    out["closing_audit_incremental_this_epoch"] =
        _closing_audit_incremental_this_epoch;
    out["investment_scheduled_review_cells"] =
        _investment_scheduled_review_cells;
    out["investment_review_cells"] = _investment_review_cells;
    out["investment_type_evaluations"] =
        _investment_type_evaluations;
    out["investment_market_signal_rejections"] =
        _investment_market_signal_rejections;
    out["investment_ethnicity_evaluations"] =
        _investment_ethnicity_evaluations;
    out["investment_sparse_mode"] =
        _investment_sparse_mode == 0 ? "OFF" :
        (_investment_sparse_mode == 1 ? "PROBE" : "ACTIVE");
    out["investment_sparse_runtime_disabled"] =
        _investment_sparse_runtime_disabled;
    out["investment_sparse_considered_types"] =
        _investment_sparse_considered_types;
    out["investment_sparse_selected_types"] =
        _investment_sparse_selected_types;
    out["investment_sparse_skipped_types"] =
        _investment_sparse_skipped_types;
    out["investment_sparse_mismatches"] =
        _investment_sparse_mismatches;
    out["investment_sparse_dense_fallbacks"] =
        _investment_sparse_dense_fallbacks;
    out["investment_displacement_type_evaluations"] =
        _investment_displacement_type_evaluations;
    out["investment_gate_capital_type_skips"] =
        _investment_gate_capital_type_skips;
    out["building_factor_cache_hits"] = _building_factor_cache_hits;
    out["building_factor_cache_misses"] = _building_factor_cache_misses;
    out["city_good_output_shared_count"] = static_cast<int64_t>(
        _city_output_shared_goods_q16.size());
    out["city_good_output_non_neutral_shared_count"] = static_cast<int64_t>(
        std::count_if(_city_output_shared_goods_q16.begin(),
            _city_output_shared_goods_q16.end(),
            [](int32_t value) { return value != Q16_ONE; }));
    out["city_good_output_override_count"] = static_cast<int64_t>(
        _city_output_good_indices.size());
    int64_t city_good_output_override_cells = 0;
    for (size_t cell = 0; cell + 1 < _city_output_cell_offsets.size(); ++cell)
        if (_city_output_cell_offsets[cell] != _city_output_cell_offsets[cell + 1])
            ++city_good_output_override_cells;
    out["city_good_output_override_cell_count"] =
        city_good_output_override_cells;
    out["city_good_output_cache_bytes"] = static_cast<int64_t>(
        _city_output_shared_goods_q16.capacity() * sizeof(int32_t) +
        _city_output_cell_offsets.capacity() * sizeof(int32_t) +
        _city_output_good_indices.capacity() * sizeof(int32_t) +
        _city_output_factors_q16.capacity() * sizeof(int32_t));
    out["cell_tax_compiled_policy_count"] = static_cast<int64_t>(
        _epoch_compiled_cell_tax_policies.empty()
            ? 0 : _epoch_compiled_cell_tax_policies.size() - 1);
    out["cell_tax_shared_default_row_count"] = static_cast<int64_t>(
        _epoch_compiled_cell_tax_default_rows.size());
    out["cell_tax_compiled_override_count"] = static_cast<int64_t>(
        _epoch_compiled_cell_tax_overrides.size());
    out["cell_tax_cache_bytes"] = _epoch_cell_tax_cache_bytes;
    out["cell_tax_epoch_compile_ms"] = _epoch_cell_tax_compile_ms;
    out["fiscal_business_prospective_lanes"] =
        _fiscal_business_prospective_lanes;
    out["fiscal_business_prospective_request"] =
        _fiscal_business_prospective_request;
    out["approximation_probe_violations"] =
        _approximation_probe_violations;
    out["approximation_probe_max_spend_error_q16"] =
        _approximation_probe_max_spend_error_q16;
    out["approximation_probe_max_demand_error_q16"] =
        _approximation_probe_max_demand_error_q16;
    out["approximation_cooldown_epochs_left"] =
        _approximation_cooldown_epochs_left;
    out["budgeted_building_commit_phase_fusions"] =
        _budgeted_building_commit_phase_fusions;
    out["budgeted_publish_phase_fusions"] =
        _budgeted_publish_phase_fusions;
    out["family_runtime_mode"] = _family_runtime_mode == 0 ? "OFF" :
        (_family_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["family_count"] = _families.active_count;
    out["family_membership_edge_count"] = static_cast<int64_t>(
        _family_memberships.size());
    out["family_ownership_edge_count"] = static_cast<int64_t>(
        _family_ownerships.size());
    out["family_trait_roll_count"] = static_cast<int64_t>(
        _family_traits.size());
    out["family_branch_count"] = static_cast<int64_t>(std::count(
        _family_influences.active.begin(), _family_influences.active.end(),
        uint8_t{1}));
    out["family_modifier_binding_count"] = static_cast<int64_t>(
        _family_modifier_bindings.size());
    out["family_trigger_binding_count"] = static_cast<int64_t>(
        _family_trigger_bindings.size());
    out["family_effect_binding_count"] = static_cast<int64_t>(
        _family_effect_bindings.size());
    out["family_owned_output_row_count"] = static_cast<int64_t>(
        _family_owned_output_rows.size());
    out["family_industry_stat_count"] = static_cast<int64_t>(
        _family_industry_stats.size());
    out["family_behavior_factor_row_count"] = static_cast<int64_t>(
        _family_behavior_factor_rows.size());
    out["family_behavior_class_row_count"] = _family_behavior_class_rows;
    out["family_behavior_cache_rebuilds"] =
        _family_behavior_cache_rebuilds;
    out["family_behavior_cache_skips"] = _family_behavior_cache_skips;
    out["family_behavior_metric_contexts_built"] =
        _family_behavior_metric_contexts_built;
    out["family_behavior_condition_edges_evaluated"] =
        _family_behavior_condition_edges_evaluated;
    out["family_behavior_cache_ms"] = _family_behavior_cache_ms;
    out["family_behavior_cache_dirty"] = _family_behavior_cache_dirty;
    out["family_behavior_cache_last_dirty_reasons"] = static_cast<int64_t>(
        _family_behavior_cache_last_reasons);
    out["family_expedition_active_count"] = static_cast<int64_t>(std::count(
        _family_expeditions.active.begin(), _family_expeditions.active.end(),
        uint8_t{1}));
    out["family_expedition_due_heap_count"] = static_cast<int64_t>(
        _family_expedition_due_heap.size());
    out["family_expedition_transit_population"] = [&]() {
        int64_t total = 0;
        int64_t local_saturation_count = 0;
        for (size_t index = 0; index < _family_expeditions.active.size(); ++index)
            if (_family_expeditions.active[index] != 0)
                total = saturating_add(total,
                    family_expedition_payload_people(static_cast<int32_t>(index)),
                    local_saturation_count);
        return total;
    }();
    out["colonization_route_query_ms"] = _colonization_route_query_ms;
    out["colonization_payload_split_ms"] = _colonization_payload_split_ms;
    out["colonization_cross_domain_ms"] = _colonization_cross_domain_ms;
    out["canal_quote_count"] = static_cast<int64_t>(_canal_quotes.size());
    out["canal_active_quote_count"] = static_cast<int64_t>(
        _canal_quote_index.size());
    out["canal_project_count"] = static_cast<int64_t>(_canal_projects.size());
    out["canal_next_project_id"] = static_cast<int64_t>(_next_canal_project_id);
    out["canal_receipt_count"] = static_cast<int64_t>(_canal_receipts.size());
    int64_t canal_building = 0;
    int64_t canal_awaiting_effect = 0;
    int64_t canal_completed = 0;
    int64_t canal_failed = 0;
    for (const CanalProject &project : _canal_projects) {
        if (project.state == CANAL_PROJECT_BUILDING) ++canal_building;
        else if (project.state == CANAL_PROJECT_AWAITING_EFFECT)
            ++canal_awaiting_effect;
        else if (project.state == CANAL_PROJECT_COMPLETED) ++canal_completed;
        else if (project.state == CANAL_PROJECT_FAILED) ++canal_failed;
    }
    out["canal_project_building_count"] = canal_building;
    out["canal_project_awaiting_effect_count"] = canal_awaiting_effect;
    out["canal_project_completed_count"] = canal_completed;
    out["canal_project_failed_count"] = canal_failed;
    out["canal_topology_hash"] = static_cast<int64_t>(
        _trade_topology.topology_hash & 0x7fffffffffffffffULL);
    int64_t canal_directed_edges = 0;
    for (const uint8_t mask : _trade_topology.canal_edge_mask)
        for (int direction = 0; direction < 6; ++direction)
            canal_directed_edges += (mask >> direction) & 1U;
    out["canal_edge_count"] = canal_directed_edges / 2;
    out["family_membership_edges_processed"] =
        _family_membership_edges_processed;
    out["family_ownership_edges_processed"] =
        _family_ownership_edges_processed;
    out["families_formed"] = _families_formed;
    out["families_dissolved"] = _families_dissolved;
    out["family_owner_jobs_filled"] = _family_owner_jobs_filled;
    out["family_owner_jobs_vacant"] = _family_owner_jobs_vacant;
    out["notable_person_runtime_mode"] = _person_runtime_mode == 0 ? "OFF" :
        (_person_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["notable_person_count"] = _persons.active_count;
    out["person_need_edge_count"] = static_cast<int64_t>(_person_needs.size());
    out["persons_promoted"] = _persons_promoted;
    out["persons_died"] = _persons_died;
    out["persons_migrated"] = _persons_migrated;
    out["person_jobs_bound"] = _person_jobs_bound;
    out["person_need_edges_processed"] = _person_need_edges_processed;
    out["settlement_phase"] = _rolling_phase;
    out["due_cells"] = _rolling_due_cells;
    out["processed_due_cells"] = _rolling_processed_cells;
    out["deferred_cells"] = _rolling_deferred_cells;
    out["settlement_watermark"] = _settlement_watermark;
    out["newest_state_day"] = _settlement_newest_day;
    out["max_state_age_days"] = _settlement_max_age_days;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    out["fatal"] = _fatal;
    out["commit_over_budget"] = _epoch_active && age_days > _commit_lag_budget_days;
    out["commit_due"] = commit_due;
    out["boundary_continuation_required"] = false;
    out["cycle_deadline_day"] = deadline_day;
    write_cadence_report(out);
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    return out;
}

Dictionary NativeEconomyRuntime::report() const {
    Dictionary out;
    const int64_t age_days = _epoch_active
        ? std::max<int64_t>(0, _current_day - _sample_day)
        : _settlement_max_age_days;
    const int64_t deadline_day = _sample_day;
    const bool commit_due = _epoch_active && _current_day >= deadline_day;
    const int64_t population_expected = _opening_totals.population + _births - _deaths +
                                        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds +
        _opening_totals.country_cash + _opening_totals.escrow_cash;
    const int64_t money_close = _closing_totals.cohort_funds +
        _closing_totals.country_cash + _closing_totals.escrow_cash;
    const int64_t goods_expected = _opening_totals.goods_stock +
        _explicit_stock_delta + _production_output_stock +
        _production_output_discarded + _production_output_retained -
        _consumed_goods - _owner_output_consumed -
        _construction_goods_consumed - _production_inputs_consumed -
        _maintenance_goods_consumed -
        _production_output_discarded - _cycle_flow_discarded -
        _bullion_stock_consumed - _country_research_goods_consumed;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["report_mode"] = "full";
    out["configured"] = _configured;
    out["bootstrapped"] = _bootstrapped;
    out["epoch_active"] = _epoch_active;
    out["epoch_id"] = _epoch_id;
    write_cadence_report(out);
    out["sample_day"] = _sample_day;
    out["current_day"] = _current_day;
    out["commit_day"] = _commit_day;
    out["age_days"] = age_days;
    out["stage"] = stage_name();
    out["next_stage"] = stage_name();
    out["executed_stage"] = stage_name(_executed_stage);
    out["executed_substage"] = _executed_substage.c_str();
    out["progress_q16"] = stage_progress_q16();
    out["publish_phase"] = publish_phase_name(_publish_phase);
    out["publish_entries_per_slice"] = PUBLISH_ENTRIES_PER_SLICE;
    out["publish_audit_entries_per_slice"] = PUBLISH_AUDIT_ENTRIES_PER_SLICE;
    out["building_review_groups_per_slice"] = BUILDING_REVIEW_GROUPS_PER_SLICE;
    out["investment_cells_per_slice"] =
        _investment_cells_per_slice;
    out["building_finalize_cells_per_slice"] =
        _building_finalize_cells_per_slice;
    out["building_plan_cells_per_slice"] =
        _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    out["plan_evaluate_cells"] =
        static_cast<int64_t>(_epoch_plan_cells.size());
    out["household_post_building_cells_per_slice"] =
        _household_post_building_cells_per_slice_override > 0
        ? _household_post_building_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    out["epoch_available_building_type_count"] = static_cast<int64_t>(
        _epoch_country_building_type_indices.size());
    out["household_market_phase"] = _stage == Stage::HOUSEHOLD_MARKET
        ? _household_market_phase : -1;
    out["building_plan_phase"] = _stage == Stage::BUILDING_PLAN
        ? _building_plan_phase : -1;
    out["building_commit_phase"] = _stage == Stage::BUILDING_COMMIT
        ? _building_commit_phase : -1;
    out["processed_cells"] = _processed_cells;
    out["processed_cohorts"] = _processed_cohorts;
    out["processed_rules"] = _processed_rules;
    out["processed_commands"] = _processed_commands;
    out["rejected_commands"] = _rejected_commands;
    out["formula_ms"] = _formula_ms;
    out["clear_ms"] = _clear_ms;
    out["ledger_ms"] = _ledger_ms;
    out["processed_needs"] = _processed_needs;
    out["processed_variants"] = _processed_variants;
    out["processed_components"] = _processed_components;
    out["carrying_old_resource_scan_steps"] = _carrying_old_resource_scan_steps;
    out["food_output_events"] = _food_output_events;
    out["food_input_events"] = _food_input_events;
    out["food_trade_events"] = _food_trade_events;
    out["food_access_events"] = _food_access_events;
    out["fallback_ms"] = _fallback_ms;
    out["merchant_settle_ms"] = _merchant_settle_ms;
    out["price_ms"] = _price_ms;
    out["structure_ms"] = _structure_ms;
    out["prosperity_changed_cells"] = _prosperity_changed_cells;
    out["prosperity_promotions"] = _prosperity_promotions;
    out["prosperity_demotions"] = _prosperity_demotions;
    out["settlement_names_assigned"] = _settlement_names_assigned;
    out["settlement_names_released"] = _settlement_names_released;
    out["settlement_name_collision_probes"] =
        _settlement_name_collision_probes;
    out["prosperity_update_ms"] = _prosperity_update_ms;
    out["settlement_revision"] = _settlements.revision;
    int64_t settlement_memory = 0;
    settlement_memory += static_cast<int64_t>(
        _settlements.tier.capacity() * sizeof(uint8_t) +
        _settlements.name_active.capacity() * sizeof(uint8_t) +
        _settlements.name_forced.capacity() * sizeof(uint8_t) +
        _settlements.prosperity_generation.capacity() * sizeof(uint32_t) +
        _settlements.name_roll_generation.capacity() * sizeof(uint32_t) +
        _settlements.prefix.capacity() * sizeof(int32_t) +
        _settlements.root.capacity() * sizeof(int32_t) +
        _settlements.suffix.capacity() * sizeof(int32_t) +
        _settlements.disambiguator.capacity() * sizeof(uint32_t));
    for (const auto &entry : _settlements.active_names)
        settlement_memory += static_cast<int64_t>(
            sizeof(entry) + entry.first.capacity());
    for (const auto &revision : _settlements.revisions)
        settlement_memory += static_cast<int64_t>(
            sizeof(revision) + revision.changes.capacity() *
                sizeof(SettlementChange));
    out["settlement_memory_bytes"] = settlement_memory;
    out["publish_ms"] = _publish_ms;
    const CountryClassOpinionSnapshot &class_opinion =
        country_class_opinion_snapshot();
    out["class_opinion_revision"] =
        static_cast<int64_t>(class_opinion.revision);
    out["class_opinion_class_hash"] =
        static_cast<int64_t>(class_opinion.class_hash);
    out["class_opinion_country_count"] = class_opinion.country_count;
    out["class_opinion_class_count"] = class_opinion.class_count;
    out["class_opinion_cells"] =
        static_cast<int64_t>(_class_opinion_cells_scanned);
    out["class_opinion_slots_scanned"] =
        static_cast<int64_t>(_class_opinion_slots_scanned);
    out["class_opinion_zero_population_rows"] =
        static_cast<int64_t>(_class_opinion_zero_population_rows);
    out["class_opinion_last_cells_scanned"] =
        static_cast<int64_t>(_last_class_opinion_cells_scanned);
    out["class_opinion_last_slots_scanned"] =
        static_cast<int64_t>(_last_class_opinion_slots_scanned);
    out["class_opinion_last_zero_population_rows"] =
        static_cast<int64_t>(_last_class_opinion_zero_population_rows);
    out["class_opinion_ms"] = _class_opinion_ms;
    Dictionary publish_breakdown_ms;
    Dictionary publish_breakdown_work;
    Dictionary publish_cumulative_breakdown_ms;
    Dictionary publish_cumulative_breakdown_work;
    for (size_t phase = 0; phase < static_cast<size_t>(PublishPhase::COUNT); ++phase) {
        const std::string key = std::string("aggregate_publish.") +
            publish_phase_name(static_cast<PublishPhase>(phase));
        publish_breakdown_ms[key.c_str()] = _publish_slice_phase_ms[phase];
        publish_breakdown_work[key.c_str()] = _publish_slice_phase_work[phase];
        publish_cumulative_breakdown_ms[key.c_str()] = _publish_phase_ms[phase];
        publish_cumulative_breakdown_work[key.c_str()] = _publish_phase_work[phase];
    }
    publish_breakdown_ms["aggregate_publish.class_opinion"] =
        _class_opinion_ms;
    publish_breakdown_work["aggregate_publish.class_opinion"] =
        static_cast<int64_t>(_last_class_opinion_slots_scanned);
    const size_t trade_init_phase = static_cast<size_t>(PublishPhase::TRADE_INIT);
    if (_publish_slice_phase_ms[trade_init_phase] > 0.0 &&
        _executed_substage.rfind("trade_init.", 0) == 0) {
        const std::string detailed_key = std::string("aggregate_publish.") +
            _executed_substage;
        publish_breakdown_ms[detailed_key.c_str()] =
            _publish_slice_phase_ms[trade_init_phase];
        publish_breakdown_work[detailed_key.c_str()] =
            _publish_slice_phase_work[trade_init_phase];
        publish_breakdown_ms["aggregate_publish.trade_init"] = 0.0;
        publish_breakdown_work["aggregate_publish.trade_init"] = 0;
    }
    out["publish_breakdown_ms"] = publish_breakdown_ms;
    out["publish_breakdown_work"] = publish_breakdown_work;
    out["publish_cumulative_breakdown_ms"] = publish_cumulative_breakdown_ms;
    out["publish_cumulative_breakdown_work"] = publish_cumulative_breakdown_work;
    out["household_market_breakdown_ms"] =
        household_slice_breakdown_ms();
    out["household_market_breakdown_work"] =
        household_slice_breakdown_work();
    static constexpr const char *BUILDING_COMMIT_PHASE_NAMES[
        BUILDING_COMMIT_PHASE_COUNT] = {
        "review_prepare", "special_reset", "recovery_review",
        "construction_commit", "investment_prepare", "investment",
        "finalize",
    };
    Dictionary building_commit_breakdown_ms;
    Dictionary building_commit_breakdown_work;
    for (size_t phase = 0; phase < BUILDING_COMMIT_PHASE_COUNT; ++phase) {
        const std::string key = std::string("building_commit.") +
            BUILDING_COMMIT_PHASE_NAMES[phase];
        building_commit_breakdown_ms[key.c_str()] =
            _building_commit_slice_phase_ms[phase];
        building_commit_breakdown_work[key.c_str()] =
            _building_commit_slice_phase_work[phase];
    }
    out["building_commit_breakdown_ms"] = building_commit_breakdown_ms;
    out["building_commit_breakdown_work"] = building_commit_breakdown_work;
    out["building_employment_ms"] = _employment_ms;
    out["building_production_ms"] = _production_ms;
    out["building_production_merge_ms"] = _production_merge_ms;
    out["building_production_worker_ms"] = _production_worker_ms;
    out["household_market_worker_ms"] = _market_worker_ms;
    out["household_market_prepare_ms"] = _household_market_prepare_ms;
    out["household_market_merge_ms"] = _market_merge_ms;
    out["household_market_merge_aggregate_ms"] = _market_merge_aggregate_ms;
    out["household_market_merge_trade_ms"] = _market_merge_trade_ms;
    out["prepare_reuse_count"] = _prepare_reuse_count;
    out["workset_cells_planned"] = _workset_cells_planned;
    out["workset_cells_executed"] = _workset_cells_executed;
    out["economy_live_cells"] = static_cast<int32_t>(_economy_live_cells.size());
    out["duplicate_range_count"] = _duplicate_range_count;
    out["market_result_allocation_growth_count"] =
        _market_result_allocation_growth_count;
    out["market_result_allocation_growth_bytes"] =
        _market_result_allocation_growth_bytes;
    out["production_result_allocation_growth_count"] =
        _production_result_allocation_growth_count;
    out["production_result_allocation_growth_bytes"] =
        _production_result_allocation_growth_bytes;
    out["building_plan_ms"] = _building_plan_ms;
    out["building_plan_evaluate_ms"] = _building_plan_evaluate_ms;
    out["building_plan_reserve_ms"] = _building_plan_reserve_ms;
    out["building_structure_count_only_updates"] =
        _building_structure_count_only_updates;
    out["building_structure_new_groups"] = _building_structure_new_groups;
    out["building_structure_removed_groups"] =
        _building_structure_removed_groups;
    out["building_structure_topology_rebuilds"] =
        _building_structure_topology_rebuilds;
    out["building_structure_role_span_reuses"] =
        _building_structure_role_span_reuses;
    out["building_structure_role_span_appends"] =
        _building_structure_role_span_appends;
    out["building_structure_group_merge_ms"] =
        _building_structure_group_merge_ms;
    out["building_structure_market_cache_ms"] =
        _building_structure_market_cache_ms;
    out["building_structure_labor_cache_ms"] =
        _building_structure_labor_cache_ms;
    out["market_signal_lookup_mode"] =
        _market_signals.dense_index.empty() ? "csr" : "dense";
    out["market_signal_lookup_entries"] = static_cast<int64_t>(
        _market_signals.dense_index.size());
    out["pending_construction_index_entries"] = static_cast<int64_t>(
        _pending_construction_cell_indices.size());
    out["building_investment_ms"] = _investment_ms;
    out["investment_evaluate_ms"] = _investment_evaluate_ms;
    out["investment_allocate_ms"] = _investment_allocate_ms;
    out["working_capital_scale_error_bound_q16"] =
        _working_capital_scale_error_bound_q16;
    out["market_signal_ms"] = _market_signal_ms;
    out["market_signal_insert_ms"] = _market_signal_insert_ms;
    out["market_signal_flush_ms"] = _market_signal_flush_ms;
    out["market_signal_insert_count"] = _market_signal_insert_count;
    out["wage_plan_ms"] = _wage_plan_ms;
    out["labor_signal_ms"] = _labor_signal_ms;
    out["trade_plan_ms"] = _trade_plan_ms;
    const double trade_plan_accounted_ms = _trade_plan_scan_body_ms +
        _trade_plan_scan_finalize_ms + _trade_plan_route_prepare_ms +
        _trade_plan_route_expand_ms + _trade_plan_route_finalize_ms;
    Dictionary trade_plan_breakdown_ms;
    trade_plan_breakdown_ms["trade_planning.scan_body"] = _trade_plan_scan_body_ms;
    trade_plan_breakdown_ms["trade_planning.scan_finalize"] =
        _trade_plan_scan_finalize_ms;
    trade_plan_breakdown_ms["trade_planning.route_prepare"] =
        _trade_plan_route_prepare_ms;
    trade_plan_breakdown_ms["trade_planning.route_expand"] =
        _trade_plan_route_expand_ms;
    trade_plan_breakdown_ms["trade_planning.route_finalize"] =
        _trade_plan_route_finalize_ms;
    trade_plan_breakdown_ms["trade_planning.other"] =
        std::max(0.0, _trade_plan_ms - trade_plan_accounted_ms);
    out["trade_plan_breakdown_ms"] = trade_plan_breakdown_ms;
    Dictionary trade_plan_breakdown_work;
    trade_plan_breakdown_work["trade_planning.scan_pairs"] =
        _trade_plan_scan_pairs_slice;
    trade_plan_breakdown_work["trade_planning.route_sources_prepared"] =
        _trade_plan_route_sources_prepared_slice;
    trade_plan_breakdown_work["trade_planning.route_expansions"] =
        _trade_plan_route_expansions_slice;
    trade_plan_breakdown_work["trade_planning.candidates_finalized"] =
        _trade_plan_candidates_finalized_slice;
    out["trade_plan_breakdown_work"] = trade_plan_breakdown_work;
    const char *trade_plan_substage = "";
    double trade_plan_substage_ms = 0.0;
    auto choose_trade_plan_substage = [&](const char *name, double value) {
        if (value > trade_plan_substage_ms) {
            trade_plan_substage = name;
            trade_plan_substage_ms = value;
        }
    };
    choose_trade_plan_substage("scan_body", _trade_plan_scan_body_ms);
    choose_trade_plan_substage("scan_finalize", _trade_plan_scan_finalize_ms);
    choose_trade_plan_substage("route_prepare", _trade_plan_route_prepare_ms);
    choose_trade_plan_substage("route_expand", _trade_plan_route_expand_ms);
    choose_trade_plan_substage("route_finalize", _trade_plan_route_finalize_ms);
    choose_trade_plan_substage("other",
        std::max(0.0, _trade_plan_ms - trade_plan_accounted_ms));
    out["trade_plan_substage"] = trade_plan_substage;
    if (_executed_substage.empty() && _executed_stage == Stage::TRADE_PLANNING)
        out["executed_substage"] = trade_plan_substage;
    out["trade_settle_ms"] = _trade_settle_ms;
    out["trade_dispatch_ms"] = _trade_dispatch_ms;
    out["epoch_begin_ms"] = _epoch_begin_ms;
    out["epoch_begin_reset_ms"] = _epoch_begin_reset_ms;
    out["epoch_begin_country_ms"] = _epoch_begin_country_ms;
    out["epoch_begin_city_factor_ms"] = _epoch_begin_city_factor_ms;
    out["epoch_begin_building_factor_ms"] = _epoch_begin_building_factor_ms;
    static constexpr const char *SCAN_STAGE_NAMES[SCAN_STAGE_SLOTS] = {
        "idle", "epoch_begin", "ledger_apply", "household_market",
        "structural_commit", "wait_commit", "building_employment",
        "building_production", "building_commit", "aggregate_publish",
        "fatal", "trade_settle", "trade_dispatch", "trade_planning",
        "building_plan", "government_research_procurement", "family_commit",
        "person_commit",
    };
    for (size_t i = 0; i < SCAN_STAGE_SLOTS; ++i)
        out[(std::string("scan_steps_stage_") + SCAN_STAGE_NAMES[i]).c_str()] =
            _scan_steps_by_stage[i];
    out["scan_steps_find_building_group"] = _scan_steps_find_building_group;
    out["scan_steps_find_signature"] = _scan_steps_find_signature;
    out["scan_steps_membership_fallback"] = _scan_steps_membership_fallback;
    out["scan_steps_person_linear"] = _scan_steps_person_linear;
    out["scan_steps_family_linear"] = _scan_steps_family_linear;
    out["scan_calls_find_building_group"] = _scan_calls_find_building_group;
    out["scan_calls_find_signature"] = _scan_calls_find_signature;
    out["scan_calls_membership_fallback"] = _scan_calls_membership_fallback;
    out["family_commit_normalize_ms"] = _family_commit_normalize_ms;
    out["family_commit_attribution_ms"] = _family_commit_attribution_ms;
    out["family_commit_form_ms"] = _family_commit_form_ms;
    out["family_commit_index_ms"] = _family_commit_index_ms;
    out["family_commit_lifecycle_ms"] = _family_commit_lifecycle_ms;
    out["family_commit_influence_ms"] = _family_commit_influence_ms;
    out["rebuild_family_membership_ms"] = _rebuild_family_membership_ms;
    out["rebuild_family_ownership_ms"] = _rebuild_family_ownership_ms;
    out["rebuild_family_csr_ms"] = _rebuild_family_csr_ms;
    out["rebuild_family_cellindex_ms"] = _rebuild_family_cellindex_ms;
    out["rebuild_person_needs_ms"] = _rebuild_person_needs_ms;
    out["rebuild_person_count_ms"] = _rebuild_person_count_ms;
    out["rebuild_person_fill_ms"] = _rebuild_person_fill_ms;
    out["rebuild_person_sort_ms"] = _rebuild_person_sort_ms;
    out["rebuild_person_needoffsets_ms"] = _rebuild_person_needoffsets_ms;
    out["person_retire_call_ms"] = _person_retire_call_ms;
    out["person_retire_calls"] = _person_retire_calls;
    out["person_commit_retire_ms"] = _person_commit_retire_ms;
    out["person_commit_index_ms"] = _person_commit_index_ms;
    out["person_commit_bind_jobs_ms"] = _person_commit_bind_jobs_ms;
    out["person_commit_claims_ms"] = _person_commit_claims_ms;
    out["person_commit_equity_ms"] = _person_commit_equity_ms;
    out["person_commit_promote_ms"] = _person_commit_promote_ms;
    out["epoch_begin_workset_ms"] = _epoch_begin_workset_ms;
    out["epoch_begin_resource_lane_ms"] = _epoch_begin_resource_lane_ms;
    out["epoch_begin_fiscal_ms"] = _epoch_begin_fiscal_ms;
    out["epoch_begin_construction_csr_ms"] = _epoch_begin_construction_csr_ms;
    out["epoch_begin_recovery_apply_ms"] = _epoch_begin_recovery_apply_ms;
    out["epoch_begin_vector_init_ms"] = _epoch_begin_vector_init_ms;
    out["epoch_begin_audit_lane_ms"] = _epoch_begin_audit_lane_ms;
    out["epoch_begin_commands_ms"] = _epoch_begin_commands_ms;
    out["epoch_preflight_ms"] = _epoch_preflight_ms;
    out["prepare_ms"] = _prepare_ms;
    out["audit_ms"] = _audit_ms;
    out["watermark_ms"] = _watermark_ms;
    out["event_summary_ms"] = _event_summary_ms;
    out["event_detail_ms"] = _event_detail_ms;
    out["event_publish_ms"] = _event_publish_ms;
    out["event_stream_hash"] = static_cast<int64_t>(_event_stream_hash);
    out["economy_event_newest_id"] = _next_event_id - 1;
    out["economy_event_last_batch_count"] = _committed_event_batches.empty() ? 0 :
        static_cast<int64_t>(_committed_event_batches.back().events.size());
    out["economy_trace_memory_bytes"] = trace_memory_bytes();
    out["economy_trace_detail_truncated"] = _trace_detail_truncated;
    out["worker_tasks"] = _worker_tasks;
    out["high_speed_batching_enabled"] = _high_speed_batching_enabled;
    out["high_speed_batch_multiplier"] = _active_batch_multiplier;
     out["high_speed_market_dispatches_saved"] =
        _high_speed_market_dispatches_saved;
    out["high_speed_production_dispatches_saved"] =
        _high_speed_production_dispatches_saved;
    out["building_production_worker_tasks"] = _production_worker_tasks;
    out["market_worker_tasks_max"] = _market_worker_tasks_max;
    out["market_worker_task_sum"] = _market_worker_task_sum;
    out["market_worker_dispatches"] = _market_worker_dispatches;
    out["market_worker_parallel_dispatches"] =
        _market_worker_parallel_dispatches;
    out["building_production_worker_tasks_max"] =
        _production_worker_tasks_max;
    out["building_production_worker_task_sum"] =
        _production_worker_task_sum;
    out["building_production_worker_dispatches"] =
        _production_worker_dispatches;
    out["building_production_worker_parallel_dispatches"] =
        _production_worker_parallel_dispatches;
    out["building_production_worker_weight_total"] =
        _production_worker_weight_total;
    out["building_production_worker_task_weight_min"] =
        _production_worker_task_weight_min;
    out["building_production_worker_task_weight_max"] =
        _production_worker_task_weight_max;
    out["building_production_worker_imbalance_q16_max"] =
        _production_worker_imbalance_q16_max;
    out["building_production_worker_cpu_ms"] =
        _production_worker_cpu_ms;
    out["audit_worker_tasks_max"] = _audit_worker_tasks_max;
    out["audit_worker_dispatches"] = _audit_worker_dispatches;
    out["audit_worker_cpu_ms"] = _audit_worker_cpu_ms;
    out["building_plan_worker_tasks_max"] =
        _building_plan_worker_tasks_max;
    out["building_plan_worker_parallel_dispatches"] =
        _building_plan_worker_parallel_dispatches;
    out["building_plan_worker_cpu_ms"] =
        _building_plan_worker_cpu_ms;
    out["opening_audit_fast_paths"] = _opening_audit_fast_paths;
    out["opening_audit_full_verifications"] =
        _opening_audit_full_verifications;
    out["closing_audit_mode"] = _closing_audit_mode == 0 ? "FULL" :
        (_closing_audit_mode == 1 ? "PROBE" : "INCREMENTAL");
    out["closing_audit_runtime_disabled"] =
        _closing_audit_runtime_disabled;
    out["closing_audit_fast_paths"] = _closing_audit_fast_paths;
    out["closing_audit_full_verifications"] =
        _closing_audit_full_verifications;
    out["closing_audit_mismatches"] = _closing_audit_mismatches;
    out["closing_audit_mismatch_ledger"] =
        _closing_audit_mismatch_ledger.c_str();
    out["closing_audit_mismatch_lane"] = _closing_audit_mismatch_lane;
    out["closing_audit_population_touched_lanes"] =
        static_cast<int64_t>(_audit_population_touched_lanes.size());
    out["closing_audit_market_touched_lanes"] =
        static_cast<int64_t>(_audit_market_touched_lanes.size());
    out["closing_audit_population_full_scan_entries"] =
        _closing_audit_population_full_scan_entries;
    out["closing_audit_market_full_scan_entries"] =
        _closing_audit_market_full_scan_entries;
    out["closing_audit_incremental_this_epoch"] =
        _closing_audit_incremental_this_epoch;
    out["investment_scheduled_review_cells"] =
        _investment_scheduled_review_cells;
    out["investment_review_cells"] = _investment_review_cells;
    out["investment_type_evaluations"] =
        _investment_type_evaluations;
    out["investment_market_signal_rejections"] =
        _investment_market_signal_rejections;
    out["investment_ethnicity_evaluations"] =
        _investment_ethnicity_evaluations;
    out["investment_sparse_mode"] =
        _investment_sparse_mode == 0 ? "OFF" :
        (_investment_sparse_mode == 1 ? "PROBE" : "ACTIVE");
    out["investment_sparse_runtime_disabled"] =
        _investment_sparse_runtime_disabled;
    out["investment_sparse_considered_types"] =
        _investment_sparse_considered_types;
    out["investment_sparse_selected_types"] =
        _investment_sparse_selected_types;
    out["investment_sparse_skipped_types"] =
        _investment_sparse_skipped_types;
    out["investment_sparse_mismatches"] =
        _investment_sparse_mismatches;
    out["investment_sparse_dense_fallbacks"] =
        _investment_sparse_dense_fallbacks;
    out["investment_displacement_type_evaluations"] =
        _investment_displacement_type_evaluations;
    out["investment_gate_capital_type_skips"] =
        _investment_gate_capital_type_skips;
    out["approximation_probe_violations"] =
        _approximation_probe_violations;
    out["approximation_probe_max_spend_error_q16"] =
        _approximation_probe_max_spend_error_q16;
    out["approximation_probe_max_demand_error_q16"] =
        _approximation_probe_max_demand_error_q16;
    out["approximation_cooldown_epochs_left"] =
        _approximation_cooldown_epochs_left;
    out["budgeted_building_commit_phase_fusions"] =
        _budgeted_building_commit_phase_fusions;
    out["budgeted_publish_phase_fusions"] =
        _budgeted_publish_phase_fusions;
    out["last_completed_price_numeric_floor_hits"] = _last_completed_perf.price_numeric_floor_hits;
    out["last_completed_price_numeric_ceiling_hits"] = _last_completed_perf.price_numeric_ceiling_hits;
    out["last_completed_price_min_tick_hits"] = _last_completed_perf.price_min_tick_hits;
    out["last_completed_price_glut_cost_damp_hits"] = _last_completed_perf.price_glut_cost_damp_hits;
    out["last_completed_small_payment_roundups"] = _last_completed_perf.small_payment_roundups;
    out["last_completed_price_ms"] = _last_completed_perf.price_ms;
    out["last_completed_perf_valid"] = _last_completed_perf.valid;
    out["last_completed_epoch_id"] = _last_completed_perf.epoch_id;
    out["last_completed_sample_day"] = _last_completed_perf.sample_day;
    out["last_completed_continuation_slices"] =
        _last_completed_perf.continuation_slices;
    out["last_completed_market_worker_tasks_max"] =
        _last_completed_perf.market_worker_tasks_max;
    out["last_completed_market_worker_task_sum"] =
        _last_completed_perf.market_worker_task_sum;
    out["last_completed_market_worker_dispatches"] =
        _last_completed_perf.market_worker_dispatches;
    out["last_completed_market_worker_parallel_dispatches"] =
        _last_completed_perf.market_worker_parallel_dispatches;
    out["last_completed_building_production_worker_tasks_max"] =
        _last_completed_perf.production_worker_tasks_max;
    out["last_completed_building_production_worker_task_sum"] =
        _last_completed_perf.production_worker_task_sum;
    out["last_completed_building_production_worker_dispatches"] =
        _last_completed_perf.production_worker_dispatches;
    out["last_completed_building_production_worker_parallel_dispatches"] =
        _last_completed_perf.production_worker_parallel_dispatches;
    out["last_completed_building_production_worker_weight_total"] =
        _last_completed_perf.production_worker_weight_total;
    out["last_completed_building_production_worker_task_weight_min"] =
        _last_completed_perf.production_worker_task_weight_min;
    out["last_completed_building_production_worker_task_weight_max"] =
        _last_completed_perf.production_worker_task_weight_max;
    out["last_completed_building_production_worker_imbalance_q16_max"] =
        _last_completed_perf.production_worker_imbalance_q16_max;
    out["last_completed_building_production_worker_cpu_ms"] =
        _last_completed_perf.production_worker_cpu_ms;
    out["last_completed_audit_worker_tasks_max"] =
        _last_completed_perf.audit_worker_tasks_max;
    out["last_completed_audit_worker_dispatches"] =
        _last_completed_perf.audit_worker_dispatches;
    out["last_completed_audit_worker_cpu_ms"] =
        _last_completed_perf.audit_worker_cpu_ms;
    out["last_completed_building_plan_worker_tasks_max"] =
        _last_completed_perf.building_plan_worker_tasks_max;
    out["last_completed_building_plan_worker_parallel_dispatches"] =
        _last_completed_perf.building_plan_worker_parallel_dispatches;
    out["last_completed_building_plan_worker_cpu_ms"] =
        _last_completed_perf.building_plan_worker_cpu_ms;
    out["last_completed_opening_audit_fast_paths"] =
        _last_completed_perf.opening_audit_fast_paths;
    out["last_completed_opening_audit_full_verifications"] =
        _last_completed_perf.opening_audit_full_verifications;
    out["last_completed_closing_audit_fast_paths"] =
        _last_completed_perf.closing_audit_fast_paths;
    out["last_completed_closing_audit_full_verifications"] =
        _last_completed_perf.closing_audit_full_verifications;
    out["last_completed_closing_audit_mismatches"] =
        _last_completed_perf.closing_audit_mismatches;
    out["last_completed_closing_audit_mismatch_ledger"] =
        _last_completed_perf.closing_audit_mismatch_ledger.c_str();
    out["last_completed_closing_audit_mismatch_lane"] =
        _last_completed_perf.closing_audit_mismatch_lane;
    out["last_completed_closing_audit_population_touched_lanes"] =
        _last_completed_perf.closing_audit_population_touched_lanes;
    out["last_completed_closing_audit_market_touched_lanes"] =
        _last_completed_perf.closing_audit_market_touched_lanes;
    out["last_completed_closing_audit_population_full_scan_entries"] =
        _last_completed_perf.closing_audit_population_full_scan_entries;
    out["last_completed_closing_audit_market_full_scan_entries"] =
        _last_completed_perf.closing_audit_market_full_scan_entries;
    out["last_completed_investment_scheduled_review_cells"] =
        _last_completed_perf.investment_scheduled_review_cells;
    out["last_completed_investment_review_cells"] =
        _last_completed_perf.investment_review_cells;
    out["last_completed_investment_type_evaluations"] =
        _last_completed_perf.investment_type_evaluations;
    out["last_completed_investment_market_signal_rejections"] =
        _last_completed_perf.investment_market_signal_rejections;
    out["last_completed_investment_ethnicity_evaluations"] =
        _last_completed_perf.investment_ethnicity_evaluations;
    out["last_completed_investment_sparse_considered_types"] =
        _last_completed_perf.investment_sparse_considered_types;
    out["last_completed_investment_sparse_selected_types"] =
        _last_completed_perf.investment_sparse_selected_types;
    out["last_completed_investment_sparse_skipped_types"] =
        _last_completed_perf.investment_sparse_skipped_types;
    out["last_completed_investment_sparse_mismatches"] =
        _last_completed_perf.investment_sparse_mismatches;
    out["last_completed_investment_sparse_dense_fallbacks"] =
        _last_completed_perf.investment_sparse_dense_fallbacks;
    out["last_completed_investment_displacement_type_evaluations"] =
        _last_completed_perf.investment_displacement_type_evaluations;
    out["last_completed_building_investment_displacement_starts"] =
        _last_completed_perf.building_investment_displacement_starts;
    out["last_completed_approximation_decisions"] =
        _last_completed_perf.approximation_decisions;
    out["last_completed_approximation_exact_probes"] =
        _last_completed_perf.approximation_exact_probes;
    out["last_completed_approximation_certificate_failures"] =
        _last_completed_perf.approximation_certificate_failures;
    out["last_completed_approximation_exact_fallbacks"] =
        _last_completed_perf.approximation_exact_fallbacks;
    out["last_completed_approximation_frontier_candidates"] =
        _last_completed_perf.approximation_frontier_candidates;
    out["last_completed_approximation_frontier_pruned"] =
        _last_completed_perf.approximation_frontier_pruned;
    out["last_completed_approximation_max_observed_regret_q16"] =
        _last_completed_perf.approximation_max_observed_regret_q16;
    out["last_completed_approximation_probe_violations"] =
        _last_completed_perf.approximation_probe_violations;
    out["last_completed_approximation_probe_max_spend_error_q16"] =
        _last_completed_perf.approximation_probe_max_spend_error_q16;
    out["last_completed_approximation_probe_max_demand_error_q16"] =
        _last_completed_perf.approximation_probe_max_demand_error_q16;
    out["last_completed_approximation_cooldown_epochs_left"] =
        _last_completed_perf.approximation_cooldown_epochs_left;
    out["last_completed_high_speed_batch_multiplier"] =
        _last_completed_perf.high_speed_batch_multiplier;
    out["last_completed_high_speed_market_dispatches_saved"] =
        _last_completed_perf.high_speed_market_dispatches_saved;
    out["last_completed_high_speed_production_dispatches_saved"] =
        _last_completed_perf.high_speed_production_dispatches_saved;
    out["last_completed_budgeted_building_commit_phase_fusions"] =
        _last_completed_perf.budgeted_building_commit_phase_fusions;
    out["last_completed_budgeted_publish_phase_fusions"] =
        _last_completed_perf.budgeted_publish_phase_fusions;
    out["last_completed_building_plan_ms"] =
        _last_completed_perf.building_plan_ms;
    out["last_completed_building_plan_evaluate_ms"] =
        _last_completed_perf.building_plan_evaluate_ms;
    out["last_completed_building_plan_reserve_ms"] =
        _last_completed_perf.building_plan_reserve_ms;
    out["last_completed_building_employment_ms"] =
        _last_completed_perf.building_employment_ms;
    out["last_completed_building_production_ms"] =
        _last_completed_perf.building_production_ms;
    out["last_completed_building_production_worker_ms"] =
        _last_completed_perf.building_production_worker_ms;
    out["last_completed_building_production_merge_ms"] =
        _last_completed_perf.building_production_merge_ms;
    out["last_completed_household_market_worker_ms"] =
        _last_completed_perf.household_market_worker_ms;
    out["last_completed_household_market_prepare_ms"] =
        _last_completed_perf.household_market_prepare_ms;
    out["last_completed_household_market_merge_ms"] =
        _last_completed_perf.household_market_merge_ms;
    out["last_completed_household_market_merge_aggregate_ms"] =
        _last_completed_perf.household_market_merge_aggregate_ms;
    out["last_completed_household_market_merge_trade_ms"] =
        _last_completed_perf.household_market_merge_trade_ms;
    out["last_completed_prepare_reuse_count"] =
        _last_completed_perf.prepare_reuse_count;
    out["last_completed_workset_cells_planned"] =
        _last_completed_perf.workset_cells_planned;
    out["last_completed_workset_cells_executed"] =
        _last_completed_perf.workset_cells_executed;
    out["last_completed_duplicate_range_count"] =
        _last_completed_perf.duplicate_range_count;
    out["last_completed_building_investment_ms"] =
        _last_completed_perf.building_investment_ms;
    out["last_completed_investment_evaluate_ms"] =
        _last_completed_perf.investment_evaluate_ms;
    out["last_completed_investment_allocate_ms"] =
        _last_completed_perf.investment_allocate_ms;
    out["last_completed_investment_prepare_lanes_ms"] =
        _last_completed_perf.investment_prepare_lanes_ms;
    out["last_completed_investment_prepare_pending_ms"] =
        _last_completed_perf.investment_prepare_pending_ms;
    out["last_completed_investment_prepare_groups_ms"] =
        _last_completed_perf.investment_prepare_groups_ms;
    out["last_completed_startup_demand_prepare_ms"] =
        _last_completed_perf.startup_demand_prepare_ms;
    out["last_completed_startup_demand_seed_count"] =
        _last_completed_perf.startup_demand_seed_count;
    out["last_completed_startup_demand_touched_lanes"] =
        _last_completed_perf.startup_demand_touched_lanes;
    out["last_completed_startup_demand_catalog_edges"] =
        _last_completed_perf.startup_demand_catalog_edges;
    out["last_completed_startup_demand_cycle_skips"] =
        _last_completed_perf.startup_demand_cycle_skips;
    out["last_completed_startup_demand_remote_lanes"] =
        _last_completed_perf.startup_demand_remote_lanes;
    out["last_completed_startup_demand_matched_review_cells"] =
        _last_completed_perf.startup_demand_matched_review_cells;
    out["last_completed_startup_demand_buildings_started"] =
        _last_completed_perf.startup_demand_buildings_started;
    out["last_completed_startup_demand_scratch_bytes"] =
        _last_completed_perf.startup_demand_scratch_bytes;
    out["last_completed_finalize_construction_ms"] =
        _last_completed_perf.finalize_construction_ms;
    out["last_completed_finalize_reconcile_ms"] =
        _last_completed_perf.finalize_reconcile_ms;
    out["last_completed_building_factor_refresh_ms"] =
        _last_completed_perf.building_factor_refresh_ms;
    out["last_completed_building_role_storage_ms"] =
        _last_completed_perf.building_role_storage_ms;
    out["last_completed_building_factor_cache_hits"] =
        _last_completed_perf.building_factor_cache_hits;
    out["last_completed_building_factor_cache_misses"] =
        _last_completed_perf.building_factor_cache_misses;
    out["last_completed_building_factor_miss_modver"] =
        _last_completed_perf.building_factor_miss_modver;
    out["last_completed_building_factor_miss_country"] =
        _last_completed_perf.building_factor_miss_country;
    out["last_completed_building_factor_miss_sector"] =
        _last_completed_perf.building_factor_miss_sector;
    out["last_completed_building_factor_miss_research"] =
        _last_completed_perf.building_factor_miss_research;
    out["last_completed_building_factor_miss_identity"] =
        _last_completed_perf.building_factor_miss_identity;
    out["last_completed_aggregate_publish_ms"] =
        _last_completed_perf.aggregate_publish_ms;
    out["last_completed_aggregate_audit_ms"] =
        _last_completed_perf.aggregate_audit_ms;
    out["last_completed_market_result_allocation_growth_count"] =
        _last_completed_perf.market_result_allocation_growth_count;
    out["last_completed_market_result_allocation_growth_bytes"] =
        _last_completed_perf.market_result_allocation_growth_bytes;
    out["last_completed_production_result_allocation_growth_count"] =
        _last_completed_perf.production_result_allocation_growth_count;
    out["last_completed_production_result_allocation_growth_bytes"] =
        _last_completed_perf.production_result_allocation_growth_bytes;
    out["last_completed_building_structure_count_only_updates"] =
        _last_completed_perf.building_structure_count_only_updates;
    out["last_completed_building_structure_new_groups"] =
        _last_completed_perf.building_structure_new_groups;
    out["last_completed_building_structure_removed_groups"] =
        _last_completed_perf.building_structure_removed_groups;
    out["last_completed_building_structure_topology_rebuilds"] =
        _last_completed_perf.building_structure_topology_rebuilds;
    out["last_completed_building_structure_role_span_reuses"] =
        _last_completed_perf.building_structure_role_span_reuses;
    out["last_completed_building_structure_role_span_appends"] =
        _last_completed_perf.building_structure_role_span_appends;
    out["last_completed_building_structure_group_merge_ms"] =
        _last_completed_perf.building_structure_group_merge_ms;
    out["last_completed_building_structure_market_cache_ms"] =
        _last_completed_perf.building_structure_market_cache_ms;
    out["last_completed_building_structure_labor_cache_ms"] =
        _last_completed_perf.building_structure_labor_cache_ms;
    out["due_cells"] = _rolling_due_cells;
    out["processed_due_cells"] = _rolling_processed_cells;
    out["deferred_cells"] = _rolling_deferred_cells;
    out["settlement_watermark"] = _settlement_watermark;
    out["newest_state_day"] = _settlement_newest_day;
    out["max_state_age_days"] = _settlement_max_age_days;
    out["rolling_deadline_violations"] = _rolling_deadline_violations;
    out["worker_enabled"] = _worker_enabled;
    out["worker_market_threshold"] = _worker_market_threshold;
    out["markets_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["building_groups_per_slice"] = _building_groups_per_slice;
    out["auto_slice_by_scale"] = _auto_slice_by_scale;
    out["family_runtime_mode"] = _family_runtime_mode == 0 ? "OFF" :
        (_family_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["family_count"] = _families.active_count;
    out["family_membership_edge_count"] = static_cast<int64_t>(
        _family_memberships.size());
    out["family_ownership_edge_count"] = static_cast<int64_t>(
        _family_ownerships.size());
    out["family_trait_roll_count"] = static_cast<int64_t>(
        _family_traits.size());
    out["family_branch_count"] = static_cast<int64_t>(std::count(
        _family_influences.active.begin(), _family_influences.active.end(),
        uint8_t{1}));
    out["family_modifier_binding_count"] = static_cast<int64_t>(
        _family_modifier_bindings.size());
    out["family_trigger_binding_count"] = static_cast<int64_t>(
        _family_trigger_bindings.size());
    out["family_effect_binding_count"] = static_cast<int64_t>(
        _family_effect_bindings.size());
    out["family_owned_output_row_count"] = static_cast<int64_t>(
        _family_owned_output_rows.size());
    out["family_industry_stat_count"] = static_cast<int64_t>(
        _family_industry_stats.size());
    out["family_behavior_factor_row_count"] = static_cast<int64_t>(
        _family_behavior_factor_rows.size());
    out["family_behavior_class_row_count"] = _family_behavior_class_rows;
    out["family_behavior_cache_rebuilds"] =
        _family_behavior_cache_rebuilds;
    out["family_behavior_cache_skips"] = _family_behavior_cache_skips;
    out["family_behavior_metric_contexts_built"] =
        _family_behavior_metric_contexts_built;
    out["family_behavior_condition_edges_evaluated"] =
        _family_behavior_condition_edges_evaluated;
    out["family_behavior_cache_ms"] = _family_behavior_cache_ms;
    out["family_behavior_cache_dirty"] = _family_behavior_cache_dirty;
    out["family_behavior_cache_last_dirty_reasons"] = static_cast<int64_t>(
        _family_behavior_cache_last_reasons);
    out["family_expedition_active_count"] = static_cast<int64_t>(std::count(
        _family_expeditions.active.begin(), _family_expeditions.active.end(),
        uint8_t{1}));
    out["family_expedition_due_heap_count"] = static_cast<int64_t>(
        _family_expedition_due_heap.size());
    out["family_expedition_transit_population"] = [&]() {
        int64_t total = 0;
        int64_t local_saturation_count = 0;
        for (size_t index = 0; index < _family_expeditions.active.size(); ++index)
            if (_family_expeditions.active[index] != 0)
                total = saturating_add(total,
                    family_expedition_payload_people(static_cast<int32_t>(index)),
                    local_saturation_count);
        return total;
    }();
    out["colonization_route_query_ms"] = _colonization_route_query_ms;
    out["colonization_payload_split_ms"] = _colonization_payload_split_ms;
    out["colonization_cross_domain_ms"] = _colonization_cross_domain_ms;
    out["canal_quote_count"] = static_cast<int64_t>(_canal_quotes.size());
    out["canal_active_quote_count"] = static_cast<int64_t>(
        _canal_quote_index.size());
    out["canal_project_count"] = static_cast<int64_t>(_canal_projects.size());
    out["canal_receipt_count"] = static_cast<int64_t>(_canal_receipts.size());
    int64_t canal_building = 0;
    int64_t canal_awaiting_effect = 0;
    int64_t canal_completed = 0;
    int64_t canal_failed = 0;
    for (const CanalProject &project : _canal_projects) {
        if (project.state == CANAL_PROJECT_BUILDING) ++canal_building;
        else if (project.state == CANAL_PROJECT_AWAITING_EFFECT)
            ++canal_awaiting_effect;
        else if (project.state == CANAL_PROJECT_COMPLETED) ++canal_completed;
        else if (project.state == CANAL_PROJECT_FAILED) ++canal_failed;
    }
    out["canal_project_building_count"] = canal_building;
    out["canal_project_awaiting_effect_count"] = canal_awaiting_effect;
    out["canal_project_completed_count"] = canal_completed;
    out["canal_project_failed_count"] = canal_failed;
    out["canal_topology_hash"] = static_cast<int64_t>(
        _trade_topology.topology_hash & 0x7fffffffffffffffULL);
    int64_t canal_directed_edges = 0;
    for (const uint8_t mask : _trade_topology.canal_edge_mask)
        for (int direction = 0; direction < 6; ++direction)
            canal_directed_edges += (mask >> direction) & 1U;
    out["canal_edge_count"] = canal_directed_edges / 2;
    out["family_membership_edges_processed"] =
        _family_membership_edges_processed;
    out["family_ownership_edges_processed"] =
        _family_ownership_edges_processed;
    out["families_formed"] = _families_formed;
    out["families_dissolved"] = _families_dissolved;
    out["family_owner_jobs_filled"] = _family_owner_jobs_filled;
    out["family_owner_jobs_vacant"] = _family_owner_jobs_vacant;
    out["notable_person_runtime_mode"] = _person_runtime_mode == 0 ? "OFF" :
        (_person_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["notable_person_count"] = _persons.active_count;
    out["person_need_edge_count"] = static_cast<int64_t>(_person_needs.size());
    out["persons_promoted"] = _persons_promoted;
    out["persons_died"] = _persons_died;
    out["persons_migrated"] = _persons_migrated;
    out["person_jobs_bound"] = _person_jobs_bound;
    out["person_need_edges_processed"] = _person_need_edges_processed;
    out["memory_bytes"] = memory_bytes();
    out["city_good_output_shared_count"] = static_cast<int64_t>(
        _city_output_shared_goods_q16.size());
    out["city_good_output_non_neutral_shared_count"] = static_cast<int64_t>(
        std::count_if(_city_output_shared_goods_q16.begin(),
            _city_output_shared_goods_q16.end(),
            [](int32_t value) { return value != Q16_ONE; }));
    out["city_good_output_override_count"] = static_cast<int64_t>(
        _city_output_good_indices.size());
    int64_t city_good_output_override_cells = 0;
    for (size_t cell = 0; cell + 1 < _city_output_cell_offsets.size(); ++cell)
        if (_city_output_cell_offsets[cell] != _city_output_cell_offsets[cell + 1])
            ++city_good_output_override_cells;
    out["city_good_output_override_cell_count"] =
        city_good_output_override_cells;
    out["city_good_output_cache_bytes"] = static_cast<int64_t>(
        _city_output_shared_goods_q16.capacity() * sizeof(int32_t) +
        _city_output_cell_offsets.capacity() * sizeof(int32_t) +
        _city_output_good_indices.capacity() * sizeof(int32_t) +
        _city_output_factors_q16.capacity() * sizeof(int32_t));
    out["canal_next_project_id"] = static_cast<int64_t>(_next_canal_project_id);
    out["cohort_count"] = _population.active_count;
    out["market_count"] = _market.market_count;
    out["good_count"] = _market.good_count;
    out["building_type_count"] = static_cast<int64_t>(_building_types.size());
    out["building_group_count"] = static_cast<int64_t>(_buildings.size());
    out["pending_construction_count"] = static_cast<int64_t>(_pending_construction.size());
    out["processed_building_groups"] = _processed_building_groups;
    out["climate_profiled_building_groups"] =
        _climate_profiled_building_groups;
    out["climate_limited_building_groups"] =
        _climate_limited_building_groups;
    out["average_climate_capacity_q16"] =
        _climate_profiled_building_groups > 0
        ? _climate_capacity_sum_q16 / _climate_profiled_building_groups
        : Q16_ONE;
    out["filled_owner_jobs"] = _filled_owner_jobs;
    out["filled_employee_jobs"] = _filled_employee_jobs;
    out["unemployed_population"] = _unemployed_population;
    out["construction_goods_consumed"] = _construction_goods_consumed;
    out["explicit_stock_delta"] = _explicit_stock_delta;
    out["building_investment_model"] = "endogenous_owner_portfolio_v9";
    out["startup_demand_runtime_mode"] =
        _startup_demand_runtime_mode == 0 ? "OFF" : "ACTIVE";
    out["startup_demand_seed_count"] = _startup_demand_seed_count;
    out["startup_demand_touched_lanes"] = _startup_demand_touched_lanes;
    out["startup_demand_catalog_edges"] = _startup_demand_catalog_edges;
    out["startup_demand_cycle_skips"] = _startup_demand_cycle_skips;
    out["startup_demand_remote_lanes"] = _startup_demand_remote_lanes;
    out["startup_demand_matched_review_cells"] =
        _startup_demand_matched_review_cells;
    out["startup_demand_buildings_started"] =
        _startup_demand_buildings_started;
    out["startup_demand_prepare_ms"] = _startup_demand_prepare_ms;
    out["startup_demand_scratch_bytes"] = _startup_demand_scratch_bytes;
    out["investment_gap_fill_share_q16"] =
        _investment_gap_fill_share_q16;
    out["investment_portfolio_max_types"] =
        _investment_portfolio_max_types;
    out["investment_max_type_owner_share_q16"] =
        _investment_max_type_owner_share_q16;
    out["investment_max_growth_share_q16"] =
        _investment_max_growth_share_q16;
    out["investment_new_type_seed_buildings"] =
        _investment_new_type_seed_buildings;
    out["investment_displacement_min_advantage_q16"] =
        _investment_displacement_min_advantage_q16;
    out["investment_merchant_transition_min_improvement_q16"] =
        _investment_merchant_transition_min_improvement_q16;
    out["recovery_liquidation_max_share_q16"] =
        _recovery_liquidation_max_share_q16;
    out["building_investment_candidates"] = _building_investment_candidates;
    out["building_owner_mobility"] = _building_owner_mobility;
    out["building_owner_job_reallocations"] =
        _building_owner_job_reallocations;
    out["building_survival_priority_candidates"] =
        _building_survival_priority_candidates;
    out["building_owner_opportunity_quotes"] =
        _building_owner_opportunity_quotes;
    out["building_owner_opportunity_zero_feasible"] =
        _building_owner_opportunity_zero_feasible;
    out["building_owner_survival_reallocations"] =
        _building_owner_survival_reallocations;
    out["bullion_quota_pressure_clamps"] = _bullion_quota_pressure_clamps;
    out["bullion_quote_overallocation_prevented"] =
        _bullion_quote_overallocation_prevented;
    out["building_owner_job_profession_changes"] =
        _building_owner_job_profession_changes;
    out["building_owner_job_probability_skips"] =
        _building_owner_job_probability_skips;
    out["building_employee_to_owner_reallocations"] =
        _building_employee_to_owner_reallocations;
    out["building_investments_started"] = _building_investments_started;
    out["building_investment_displacement_starts"] =
        _building_investment_displacement_starts;
    out["building_investment_blocked_funds"] =
        _building_investment_blocked_funds;
    out["building_investment_blocked_materials"] =
        _building_investment_blocked_materials;
    out["building_investment_blocked_sponsor_capital"] =
        _building_investment_blocked_sponsor_capital;
    out["building_investment_blocked_resources"] =
        _building_investment_blocked_resources;
    out["building_investment_probability_skips"] =
        _building_investment_probability_skips;
    out["building_investment_capital_transferred"] =
        _building_investment_capital_transferred;
    out["building_investment_buildings_started"] =
        _building_investment_buildings_started;
    out["building_investment_portfolios_started"] =
        _building_investment_portfolios_started;
    out["building_investment_types_started"] =
        _building_investment_types_started;
    out["building_investment_owner_population_moved"] =
        _building_investment_owner_population_moved;
    out["building_investment_max_type_owner_share_q16"] =
        _building_investment_max_type_owner_share_q16;
    out["building_investment_demand_limited"] =
        _building_investment_demand_limited;
    out["building_investment_material_limited"] =
        _building_investment_material_limited;
    out["building_investment_capital_limited"] =
        _building_investment_capital_limited;
    out["building_investment_owner_population_limited"] =
        _building_investment_owner_population_limited;
    out["building_investment_jobs_started"] =
        _building_investment_jobs_started;
    out["building_investment_employment_gap"] =
        _building_investment_employment_gap;
    out["building_investment_employment_catchup_cells"] =
        _building_investment_employment_catchup_cells;
    out["desired_business_demand"] = _desired_business_demand;
    out["funded_business_demand"] = _funded_business_demand;
    out["unfunded_business_demand"] = _unfunded_business_demand;
    out["owner_working_capital_allocated"] = _owner_working_capital_allocated;
    out["production_inputs_consumed"] = _production_inputs_consumed;
    out["production_output_stock"] = _production_output_stock;
    out["production_output_discarded"] = _production_output_discarded;
    out["production_output_retained"] = _production_output_retained;
    out["production_output_supported"] = _production_output_supported;
    out["owner_output_consumed"] = _owner_output_consumed;
    out["producer_revenue"] = _producer_revenue;
	out["producer_support_money_issued"] = _producer_support_money_issued;
	out["producer_support_price_numerator"] = PRODUCER_SUPPORT_PRICE_NUMERATOR;
	out["producer_support_price_denominator"] = PRODUCER_SUPPORT_PRICE_DENOMINATOR;
	out["bullion_money_issued"] = _bullion_money_issued;
	out["bullion_stock_consumed"] = _bullion_stock_consumed;
	out["gold_accepted"] = _gold_accepted;
	out["silver_accepted"] = _silver_accepted;
	out["gold_money_issued"] = _gold_money_issued;
	out["silver_money_issued"] = _silver_money_issued;
	out["bullion_quota_initial"] = _epoch_bullion_quota_initial_total;
	out["bullion_quota_remaining"] = _epoch_bullion_quota_remaining_total;
	out["bullion_quota_remainder_units"] = _epoch_bullion_quota_remainder_units;
	out["cycle_flow_produced"] = _cycle_flow_produced;
	out["cycle_flow_consumed"] = _cycle_flow_consumed;
    out["cycle_flow_discarded"] = _cycle_flow_discarded;
    out["consumed_goods"] = _consumed_goods;
    out["building_wages_paid"] = _building_wages_paid;
    out["building_wages_unpaid"] = _building_wages_unpaid;
    out["building_base_wages_due"] = _building_base_wages_due;
    out["building_base_wages_paid"] = _building_base_wages_paid;
    out["building_bonus_due"] = _building_bonus_due;
    out["building_bonus_paid"] = _building_bonus_paid;
    out["wage_suspended_building_groups"] = _wage_suspended_building_groups;
    out["loss_suspended_building_groups"] = _loss_suspended_building_groups;
    out["merchant_procurement_budget"] = _merchant_procurement_budget;
    out["merchant_procurement_opportunity"] = _merchant_procurement_opportunity;
    out["merchant_procurement_allocated"] = _merchant_procurement_allocated;
    out["merchant_procurement_unspent_allocated"] = _merchant_procurement_unspent_allocated;
    out["merchant_survival_procurement_required"] =
        _merchant_survival_procurement_required;
    out["merchant_survival_procurement_allocated"] =
        _merchant_survival_procurement_allocated;
    out["merchant_input_procurement_required"] =
        _merchant_input_procurement_required;
    out["merchant_input_procurement_allocated"] =
        _merchant_input_procurement_allocated;
    out["merchant_procurement_reserved"] = _merchant_procurement_reserved;
    out["merchant_procurement_spent"] = _merchant_procurement_spent;
    int64_t report_sat = 0;
    const int64_t merchant_operating_outflow = saturating_add(
        saturating_add(_merchant_procurement_spent,
            _merchant_trade_purchase_cash, report_sat),
        _merchant_credit_drawn, report_sat);
    const int64_t merchant_economic_assets = saturating_add(
        _closing_totals.merchant_cash,
        _closing_totals.merchant_inventory_liquidation_value, report_sat);
    out["merchant_cash"] = _closing_totals.merchant_cash;
    out["merchant_inventory_retail_value"] =
        _closing_totals.merchant_inventory_retail_value;
    out["merchant_inventory_liquidation_value"] =
        _closing_totals.merchant_inventory_liquidation_value;
    out["merchant_economic_assets"] = merchant_economic_assets;
    out["merchant_procurement_margin_value"] = std::max<int64_t>(
        0, _merchant_procurement_retail_value -
            _merchant_procurement_spent);
    out["merchant_trade_purchase_cash"] = _merchant_trade_purchase_cash;
    out["merchant_trade_sale_cash"] = _merchant_trade_sale_cash;
    out["government_research_procured_points"] =
        _government_research_procured_points;
    out["government_research_procurement_cash"] =
        _government_research_procurement_cash;
    out["government_research_procurement_orders"] =
        _government_research_procurement_orders;
    out["merchant_operating_outflow"] = merchant_operating_outflow;
    out["merchant_liquidity_coverage_q16"] =
        merchant_operating_outflow > 0
            ? mul_div_sat(_closing_totals.merchant_cash, Q16_ONE,
                merchant_operating_outflow, report_sat)
            : Q16_ONE;
    out["merchant_effective_buy_factor_q16"] =
        _merchant_procurement_spent > 0
            ? std::clamp<int64_t>(
                _merchant_procurement_factor_weighted_cash_q16 /
                    _merchant_procurement_spent,
                0, Q16_ONE)
            : Q16_ONE;
    int64_t merchant_credit_outstanding = 0;
    for (const BuildingGroup &group : _buildings) {
        merchant_credit_outstanding = saturating_add(
            merchant_credit_outstanding, saturating_add(
                group.merchant_debt_principal, group.merchant_debt_premium,
                report_sat), report_sat);
    }
    for (const PendingConstruction &pending : _pending_construction) {
        merchant_credit_outstanding = saturating_add(
            merchant_credit_outstanding, saturating_add(
                pending.merchant_debt_principal, pending.merchant_debt_premium,
                report_sat), report_sat);
    }
    out["merchant_credit_runtime_mode"] = _merchant_credit_runtime_mode == 0
        ? "OFF" : (_merchant_credit_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["merchant_credit_budget"] = _merchant_credit_budget;
    out["merchant_credit_committed"] = _merchant_credit_committed;
    out["merchant_credit_drawn"] = _merchant_credit_drawn;
    out["merchant_credit_repaid"] = _merchant_credit_repaid;
    out["merchant_credit_premium_repaid"] = _merchant_credit_premium_repaid;
    out["merchant_credit_outstanding"] = merchant_credit_outstanding;
    out["merchant_credit_bad_debt"] = _merchant_credit_bad_debt;
    out["recovery_candidates"] = _recovery_candidates;
    out["recovery_approved"] = _recovery_approved;
    out["recovery_restarted"] = _recovery_restarted;
    out["recovery_failed"] = _recovery_failed;
    out["recovery_liquidated_buildings"] = _recovery_liquidated_buildings;
    out["recovery_partially_liquidated_buildings"] =
        _recovery_partially_liquidated_buildings;
    out["recovery_fully_liquidated_groups"] =
        _recovery_fully_liquidated_groups;
    out["production_input_reserved"] = _production_input_reserved;
    out["production_input_reserve_shortfall"] =
        _production_input_reserve_shortfall;
    out["construction_material_reserved"] = _construction_material_reserved;
    out["maintenance_goods_consumed"] = _maintenance_goods_consumed;
    out["maintenance_unmet"] = _maintenance_unmet;
    out["maintenance_unpaid_value"] = _maintenance_unpaid_value;
    out["owner_working_capital_reserved"] = _owner_working_capital_reserved;
    out["building_severe_loss_threshold_q16"] = _building_severe_loss_threshold_q16;
    out["building_severe_loss_cycles"] = _building_severe_loss_cycles;
    out["building_restart_margin_q16"] = _building_restart_margin_q16;
    out["building_restart_cycles"] = _building_restart_cycles;
    out["merchant_procurement_cash_reserve_q16"] =
        _merchant_procurement_cash_reserve_q16;
    out["merchant_market_making_days_q16"] = _merchant_market_making_days_q16;
    out["labor_signal_edges"] =
        static_cast<int64_t>(_labor_signals.profession_ids.size());
    out["labor_signal_updates"] = _labor_signal_updates;
    out["building_resource_generated"] = _building_resource_generated;
    out["building_resource_consumed"] = _building_resource_consumed;
    out["building_resource_net_delta"] =
        _building_resource_generated - _building_resource_consumed;
    out["building_resource_limited_groups"] = _building_resource_limited_groups;
    out["market_signal_edges"] = static_cast<int64_t>(_market_signals.good_ids.size());
    out["market_signal_updates"] = _market_signal_updates;
    out["trade_runtime_mode"] = _trade_runtime_mode == 0 ? "OFF"
        : (_trade_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["trade_topology_ready"] = _trade_topology.ready;
    out["trade_topology_generation"] = static_cast<int64_t>(
        _trade_topology.topology_generation);
    out["trade_topology_hash"] = static_cast<int64_t>(
        _trade_topology.topology_hash);
    int64_t water_portals = 0;
    int64_t water_portal_edges = 0;
    for (const auto &graph : _trade_topology.water_portals) {
        water_portals += static_cast<int64_t>(graph.portal_cells.size());
        water_portal_edges += static_cast<int64_t>(graph.targets.size());
    }
    out["trade_water_portal_count"] = water_portals;
    out["trade_water_portal_edges"] = water_portal_edges;
    // Compatibility key retained for CSV/UI readers; this is now the stable
    // frozen border hash rather than the country's treasury mutation generation.
    out["trade_country_generation"] = static_cast<int64_t>(
        _trade_topology.component_country_hash);
    out["trade_country_topology_hash"] = static_cast<int64_t>(
        _epoch_country_topology_hash);
    out["trade_plan_phase"] = _trade_plan.phase == TradePlanStore::SCAN ? "SCAN"
        : (_trade_plan.phase == TradePlanStore::ROUTE ? "ROUTE" : "IDLE");
    out["trade_scan_cursor"] = _trade_plan.scan_cursor;
    out["trade_scan_total"] = _trade_plan.scan_total;
    out["trade_active_key_count"] = static_cast<int64_t>(_trade_active_keys.size());
    out["trade_scan_progress_q16"] = _trade_plan.scan_total <= 0 ? 0
        : static_cast<int64_t>(std::min<int64_t>(Q16_ONE,
            (_trade_plan.scan_cursor * Q16_ONE) / _trade_plan.scan_total));
    out["trade_completed_scans"] = _trade_plan.completed_scans;
    out["trade_route_cursor"] = _trade_plan.route_cursor;
    out["trade_route_total"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_source_signals"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_destination_signals"] =
        static_cast<int64_t>(_trade_plan.destinations.size());
    out["trade_route_current_source_cell"] =
        _trade_plan.route_cursor >= 0 && _trade_plan.route_cursor <
            static_cast<int32_t>(_trade_plan.sources.size())
        ? _trade_plan.sources[_trade_plan.route_cursor].cell : -1;
    out["trade_route_current_source_good"] =
        _trade_plan.route_cursor >= 0 && _trade_plan.route_cursor <
            static_cast<int32_t>(_trade_plan.sources.size())
        ? _trade_plan.sources[_trade_plan.route_cursor].good : -1;
    out["trade_route_current_source_country"] =
        _trade_plan.route_cursor >= 0 && _trade_plan.route_cursor <
            static_cast<int32_t>(_trade_plan.sources.size())
        ? _trade_plan.sources[_trade_plan.route_cursor].country : -1;
    out["trade_route_search_active"] = _trade_plan.route_search_active;
    out["trade_route_search_source"] = _trade_plan.route_search_source;
    out["trade_route_expansion_cursor"] = _trade_plan.route_search_expansions;
    out["trade_route_expansions_per_slice"] =
        TRADE_ROUTE_EXPANSIONS_PER_SLICE;
    out["trade_route_pending_targets"] =
        _trade_plan.route_search_pending_targets;
    out["trade_route_accepted_targets"] =
        _trade_plan.route_search_accepted;
    out["trade_plan_reset_count"] = _trade_plan_reset_count;
    out["trade_topology_content_change_count"] =
        _trade_topology_content_change_count;
    out["trade_last_plan_reset_reason"] = String(
        _trade_last_plan_reset_reason.c_str());
    out["trade_source_signals"] = static_cast<int64_t>(_trade_plan.sources.size());
    out["trade_destination_signals"] = static_cast<int64_t>(
        _trade_plan.destinations.size());
    out["trade_ready_candidates"] = static_cast<int64_t>(
        _trade_plan.ready_candidates.size());
    out["trade_signal_max_age_days"] = _trade_signal_max_age_days;
    out["trade_first_dispatch_delay_max_days"] =
        _trade_first_dispatch_delay_max_days;
    out["trade_response_deadline_misses"] = _trade_response_deadline_misses;
    out["trade_response_deadline_misses_cumulative"] =
        _trade_response_deadline_misses_cumulative;
    out["trade_unresolved_no_attempt"] = _trade_unresolved_no_attempt;
    out["trade_unresolved_no_spread"] = _trade_unresolved_no_spread;
    out["trade_unresolved_margin"] = _trade_unresolved_margin;
    out["trade_unresolved_route"] = _trade_unresolved_route;
    out["trade_unresolved_stock"] = _trade_unresolved_stock;
    out["trade_unresolved_capacity"] = _trade_unresolved_capacity;
    out["trade_unresolved_cash"] = _trade_unresolved_cash;
    out["trade_unresolved_order_cap"] = _trade_unresolved_order_cap;
    out["trade_route_expansions"] = _trade_route_expansions;
    out["trade_route_cache_hits"] = _trade_route_cache_hits;
    out["trade_route_cache_misses"] = _trade_route_cache_misses;
    out["trade_candidates_generated"] = _trade_candidates_generated;
    out["trade_candidates_accepted"] = _trade_candidates_accepted;
    out["trade_rejected_profit"] = _trade_rejected_profit;
    out["trade_rejected_no_spread"] = _trade_rejected_no_spread;
    out["trade_rejected_margin"] = _trade_rejected_margin;
    out["trade_quantity_profit_clips"] = _trade_quantity_profit_clips;
    out["trade_relief_candidates"] = _trade_relief_candidates;
    out["trade_rejected_capacity"] = _trade_rejected_capacity;
    out["trade_rejected_stock"] = _trade_rejected_stock;
    out["trade_rejected_cash"] = _trade_rejected_cash;
    out["trade_rejected_route"] = _trade_rejected_route;
    out["trade_rejected_vision"] = _trade_rejected_vision;
    out["trade_vision_gated"] = _epoch_trade_vision_gated;
    out["trade_rejected_order_cap"] = _trade_rejected_order_cap;
    out["trade_active_keys_pruned"] = _trade_active_keys_pruned;
    out["trade_deficit_episodes_started"] = _trade_deficit_episodes_started;
    out["trade_deficit_episodes_resolved"] = _trade_deficit_episodes_resolved;
    out["trade_candidates_stale_generation"] =
        _trade_candidates_stale_generation;
    out["trade_candidates_arbitrated_out"] =
        _trade_candidates_arbitrated_out;
    out["trade_true_source_stock_failures"] =
        _trade_true_source_stock_failures;
    out["trade_orders_in_flight"] = _trade_orders.size();
    out["trade_arrival_bucket_count"] = static_cast<int64_t>(
        _trade_orders.arrival_bucket_days.size());
    out["trade_orders_dispatched"] = _trade_orders_dispatched;
    out["trade_orders_arrived"] = _trade_orders_arrived;
    out["trade_unclaimed_orders"] = _trade_unclaimed_orders;
    out["trade_capacity_available"] = _trade_capacity_available;
    out["trade_capacity_used"] = _trade_capacity_used;
    out["trade_capacity_utilization_q16"] = _trade_capacity_available <= 0 ? 0
        : std::min<int64_t>(Q16_ONE,
            (_trade_capacity_used * Q16_ONE) / _trade_capacity_available);
    out["trade_tariff_lane_count"] = static_cast<int64_t>(
        _tariff_epoch_cells.size());
    out["trade_country_good_aggregate_count"] = static_cast<int64_t>(
        _country_good_trade.countries.size());
    out["trade_country_partner_aggregate_count"] = static_cast<int64_t>(
        _country_partner_trade.countries.size());
    out["trade_transit_goods"] = trade_transit_goods();
    out["trade_escrow_cash"] = trade_escrow_cash();
    out["trade_settlement_lag_days"] = _trade_settlement_lag_days;
    out["price_cost_anchor_hits"] = _price_cost_anchor_hits;
    out["price_inactive_reversions"] = _price_inactive_reversions;
    out["unprofitable_building_groups"] = _unprofitable_building_groups;
    out["zero_utilization_building_groups"] = _zero_utilization_building_groups;
    out["average_planned_utilization_q16"] = _buildings.empty() ? Q16_ONE :
        _utilization_sum_q16 / static_cast<int64_t>(_buildings.size());
    out["building_resource_capacity_checks"] = _building_resource_capacity_checks;
    out["building_resource_capacity_limited_groups"] =
        _building_resource_capacity_limited_groups;
    out["last_building_rejection_reason"] = String(_last_building_rejection_reason.c_str());
    out["population_error"] = _epoch_active ? 0 : _closing_totals.population - population_expected;
    out["opening_population"] = _opening_totals.population;
    out["closing_population"] = _closing_totals.population;
    out["population_expected"] = population_expected;
    out["external_population_delta"] = _external_population_delta;
    out["money_error"] = _epoch_active ? 0
        : money_close - (money_open + _explicit_money_mint - _explicit_money_burn);
    out["money_open"] = money_open;
    out["money_close"] = money_close;
    out["money_expected"] = money_open + _explicit_money_mint - _explicit_money_burn;
    out["explicit_money_mint"] = _explicit_money_mint;
    out["explicit_money_burn"] = _explicit_money_burn;
    out["opening_cohort_funds"] = _opening_totals.cohort_funds;
    out["closing_cohort_funds"] = _closing_totals.cohort_funds;
    out["opening_country_cash"] = _opening_totals.country_cash;
    out["closing_country_cash"] = _closing_totals.country_cash;
    out["opening_escrow_cash"] = _opening_totals.escrow_cash;
    out["closing_escrow_cash"] = _closing_totals.escrow_cash;
    out["opening_expedition_funds"] = _opening_totals.expedition_funds;
    out["closing_expedition_funds"] = _closing_totals.expedition_funds;
    out["opening_transit_population"] = _opening_totals.transit_population;
    out["closing_transit_population"] = _closing_totals.transit_population;
    out["closing_audit_incremental_this_epoch"] =
        _closing_audit_incremental_this_epoch;
    out["opening_goods_stock"] = _opening_totals.goods_stock;
    out["closing_goods_stock"] = _closing_totals.goods_stock;
    out["opening_country_goods"] = _opening_totals.country_goods;
    out["closing_country_goods"] = _closing_totals.country_goods;
    out["goods_expected"] = goods_expected;
    out["goods_error"] = _epoch_active ? 0
        : _closing_totals.goods_stock - goods_expected;
    out["country_research_goods_consumed"] =
        _country_research_goods_consumed;
    out["saturation_count"] = _saturation_count;
    out["fatal_reason"] = String(_fatal_reason.c_str());
    out["fatal"] = _fatal;
    out["commit_lag_budget_days"] = _commit_lag_budget_days;
    out["commit_over_budget"] = _epoch_active && age_days > _commit_lag_budget_days;
    out["commit_due"] = commit_due;
    out["boundary_continuation_required"] = false;
    out["cycle_deadline_day"] = deadline_day;
    out["days_until_commit"] = _epoch_active
        ? std::max<int64_t>(0, deadline_day - _current_day) : 0;
    write_cadence_report(out);
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["market_cells_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    out["approximation_version"] = 19;
    out["approximation_model"] = "rolling_cell_settlement_v19_class_good_elasticity";
    out["economy_accuracy_preset"] = _accuracy_preset == 0 ? "EXACT" :
        (_accuracy_preset == 1 ? "BALANCED" :
        (_accuracy_preset == 2 ? "FAST" : "CUSTOM"));
    out["economy_approximation_runtime_mode"] =
        _approximation_runtime_mode == 0 ? "OFF" :
        (_approximation_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    out["approximation_large_world_scalar_guard"] = false;
    out["approximation_authoritative"] =
        _approximation_runtime_mode == 2 && _accuracy_preset != 0 &&
        _approximation_cooldown_epochs_left == 0;
    out["accuracy_max_regret_q16"] = _accuracy_max_regret_q16;
    out["accuracy_household_tail_share_q16"] =
        _accuracy_household_tail_share_q16;
    out["accuracy_candidate_top_k"] = _accuracy_candidate_top_k;
    out["accuracy_choice_temperature_q16"] =
        _accuracy_choice_temperature_q16;
    out["employment_mobility_daily_q16"] = _employment_mobility_daily_q16;
    out["employment_choice_temperature_q16"] =
        _employment_choice_temperature_q16;
    out["accuracy_exact_probe_rate_q16"] = _accuracy_exact_probe_rate_q16;
    out["accuracy_fallback_cooldown_epochs"] =
        _accuracy_fallback_cooldown_epochs;
    out["approximation_decisions"] = _approximation_decisions;
    out["approximation_exact_probes"] = _approximation_exact_probes;
    out["approximation_certificate_failures"] =
        _approximation_certificate_failures;
    out["approximation_exact_fallbacks"] = _approximation_exact_fallbacks;
    out["approximation_frontier_candidates"] =
        _approximation_frontier_candidates;
    out["approximation_frontier_pruned"] = _approximation_frontier_pruned;
    out["approximation_max_observed_regret_q16"] =
        _approximation_max_observed_regret_q16;
    out["approximation_probe_violations"] =
        _approximation_probe_violations;
    out["approximation_probe_max_spend_error_q16"] =
        _approximation_probe_max_spend_error_q16;
    out["approximation_probe_max_demand_error_q16"] =
        _approximation_probe_max_demand_error_q16;
    out["approximation_cooldown_epochs_left"] =
        _approximation_cooldown_epochs_left;
    out["starvation_satisfaction_threshold_q16"] =
        _starvation_satisfaction_threshold_q16;
    out["survival_production_target_q16"] = _survival_production_target_q16;
    out["starvation_death_rate_q32"] = _starvation_death_rate_q32;
    out["births"] = _births;
    out["deaths"] = _deaths;
    out["period_transactions"] = true;
    out["max_command_latency_days"] = locked_market_cycle_days();
    out["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    out["catalog_hash"] = _catalog_hash;
    out["building_catalog_hash"] = _building_catalog_hash;
    out["environment_day"] = _environment_day;
    out["environment_hash"] = _environment_hash;
    out["country_schema_version"] = NativeCountryRuntime::SCHEMA_VERSION;
    out["country_generation"] = static_cast<int64_t>(_epoch_country_generation);
    out["country_state_hash"] = static_cast<int64_t>(_epoch_country_hash);
    out["country_commands_due"] = _country_runtime != nullptr &&
        _country_runtime->should_run(_current_day);
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = _merchant_repairs;
    out["price_cap_hits"] = _price_cap_hits;
    out["price_rate_clamp_hits"] = _price_rate_clamp_hits;
    out["price_ceiling_expansions"] = _price_ceiling_expansions;
    out["price_ceiling_recoveries"] = _price_ceiling_recoveries;
    out["price_ceiling_blocked_rises"] = _price_ceiling_blocked_rises;
    out["price_ceiling_active_states"] = price_ceiling_state_count();
    int64_t ceiling_capacity_bytes = 0;
    for (const auto &row : _market.price_ceilings)
        ceiling_capacity_bytes += static_cast<int64_t>(row.capacity() * sizeof(PriceCeilingState));
    out["price_ceiling_state_bytes"] = ceiling_capacity_bytes;
    out["price_ceiling_confirm_days"] = _price_ceiling_confirm_days;
    out["price_ceiling_expand_bp"] = _price_ceiling_expand_bp;
    out["price_ceiling_recover_bp"] = _price_ceiling_recover_bp;
    out["price_numeric_floor_hits"] = _price_numeric_floor_hits;
    out["price_numeric_ceiling_hits"] = _price_numeric_ceiling_hits;
    out["price_ceiling_limit_hits"] = _price_catalog_bound_hits;
    out["price_min_tick_hits"] = _price_min_tick_hits;
    out["price_glut_cost_damp_hits"] = _price_glut_cost_damp_hits;
    out["small_payment_roundups"] = _small_payment_roundups;
    out["price_rise_fade_hits"] = _price_rise_fade_hits;
    out["price_headroom_damp_hits"] = _price_headroom_damp_hits;
    out["price_catalog_bound_hits"] = _price_catalog_bound_hits;
    out["price_rise_fade_model"] = "disabled_price_v6";
    out["price_runtime_bounds"] = "numeric_min_dynamic_ceiling";
    out["price_model"] = "price_v6_dynamic_ceiling";
    out["price_numeric_guard_min"] = PRICE_NUMERIC_GUARD_MIN;
    out["price_numeric_guard_max"] = PRICE_NUMERIC_GUARD_MAX;
    out["continuation_slices"] = _continuation_slices;
    out["market_runtime_mode"] = _market_runtime_mode == 0 ? "OFF" :
                                   (_market_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    return out;
}

} // namespace pk
