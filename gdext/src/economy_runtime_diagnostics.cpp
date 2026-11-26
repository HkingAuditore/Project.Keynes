#include "economy_runtime_diagnostics_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;

// The scene of the failure, captured by fail() before the epoch unwinds.
// Everything here answers a question the bare reason string cannot: which
// stage and command were running, which boundary conditions were open, and
// whether the Country peer was worker-authoritative at that instant.
Dictionary NativeEconomyRuntime::fatal_context_report() const {
    Dictionary out;
    out["valid"] = _fatal_context.valid;
    // R1-6: which binary produced this stop. Never persisted, never hashed.
    out["build_id"] = String::utf8(pk::pk_build_id());
    // R1-7/R1-8: assertion identity + ledger witness, emitted before the
    // _fatal_context.valid early-return because the stages that fail without a
    // command cursor record their row before fail() runs.
    out["assert_id"] = fatal_assert_id();
    out["witness"] = fatal_witness_report();
    if (_investment_fatal_row.valid) {
        // The BUILDING_COMMIT investment stage has no command/structural cursor,
        // so the generic fields below stay at their defaults. Without this block
        // a capital preflight fatal named no cell, type or leg at all. Emitted
        // even when _fatal_context.valid is still false so a caller that reports
        // before fail() runs (or the invariant probe) still sees the row.
        Dictionary row;
        row["branch"] = _investment_fatal_row.branch;
        row["cell"] = _investment_fatal_row.cell;
        row["type_id"] = _investment_fatal_row.type_id;
        row["portfolio_index"] = _investment_fatal_row.portfolio_index;
        row["portfolio_size"] = _investment_fatal_row.portfolio_size;
        row["allocated_count"] = _investment_fatal_row.allocated_count;
        row["owner_population"] = _investment_fatal_row.owner_population;
        row["funding_capital"] = _investment_fatal_row.funding_capital;
        row["merchant_credit"] = _investment_fatal_row.merchant_credit;
        row["required_capital"] = _investment_fatal_row.required_capital;
        row["carried"] = _investment_fatal_row.carried;
        row["correction"] = _investment_fatal_row.correction;
        row["sponsor_slot"] = _investment_fatal_row.sponsor_slot;
        row["sponsor_handle"] =
            static_cast<int64_t>(_investment_fatal_row.sponsor_handle);
        row["sponsor_family_handle"] = static_cast<int64_t>(
            _investment_fatal_row.sponsor_family_handle & 0x7fffffffffffffffULL);
        row["sponsor_population"] = _investment_fatal_row.sponsor_population;
        row["sponsor_funds"] = _investment_fatal_row.sponsor_funds;
        row["owner_slot"] = _investment_fatal_row.owner_slot;
        row["owner_funds"] = _investment_fatal_row.owner_funds;
        row["source_drained"] = _investment_fatal_row.source_drained;
        out["investment_row"] = row;
    }
    if (_construction_fatal_row.valid) {
        // Same reason as the investment row: a BUILDING_COMMIT
        // building_construction_preflight_*_drift stop has no cursor, so the
        // generic fields are all defaults. Emitted before the _fatal_context.valid
        // early-return so a reporter that runs before fail() still sees it.
        Dictionary row;
        row["reason"] = String::utf8(_construction_fatal_row.reason.c_str());
        row["cell"] = _construction_fatal_row.cell;
        row["type_id"] = _construction_fatal_row.type_id;
        row["allocated_count"] = _construction_fatal_row.allocated_count;
        row["total_cost"] = _construction_fatal_row.total_cost;
        row["owner_slot"] = _construction_fatal_row.owner_slot;
        row["owner_funds"] = _construction_fatal_row.owner_funds;
        row["funding_gap"] = _construction_fatal_row.funding_gap;
        row["debt_principal"] = _construction_fatal_row.debt_principal;
        row["material_feasible"] = _construction_fatal_row.material_feasible;
        row["good_count"] = _construction_fatal_row.good_count;
        row["first_good_id"] = _construction_fatal_row.first_good_id;
        row["first_required"] = _construction_fatal_row.first_required;
        row["first_stock"] = _construction_fatal_row.first_stock;
        row["portfolio_index"] = _construction_fatal_row.portfolio_index;
        row["portfolio_size"] = _construction_fatal_row.portfolio_size;
        row["capital_limited"] = _building_investment_capital_limited;
        row["cost_envelope_trimmed"] = _building_investment_cost_envelope_trimmed;
        row["pending_construction_count"] = static_cast<int64_t>(pending_construction_count());
        out["construction_row"] = row;
    }
    if (!_investment_leg_trace.empty()) {
        // Every leg of the cell that was being committed, in execution order:
        // what it carried / corrected / borrowed and how much the owner held when
        // the material invoice was paid. A drift can be diagnosed from this alone
        // even when the player cannot send the 40 MB save.
        godot::Array legs;
        for (const InvestmentLegTrace &leg : _investment_leg_trace) {
            Dictionary row;
            row["candidate"] = leg.candidate;
            row["type_id"] = leg.type_id;
            row["allocated"] = leg.allocated;
            row["transition"] = leg.transition;
            row["sponsor_slot"] = leg.sponsor_slot;
            row["owner_slot"] = leg.owner_slot;
            row["owner_population"] = leg.owner_population;
            row["required_capital"] = leg.required_capital;
            row["source_population_before"] = leg.source_population_before;
            row["source_funds_before"] = leg.source_funds_before;
            row["carried"] = leg.carried;
            row["correction"] = leg.correction;
            row["credit"] = leg.credit;
            row["owner_funds_after_move"] = leg.owner_funds_after_move;
            row["owner_funds_after_credit"] = leg.owner_funds_after_credit;
            row["material_cost"] = leg.material_cost;
            row["owner_funds_at_material"] = leg.owner_funds_at_material;
            row["source_drained"] = leg.source_drained;
            legs.push_back(row);
        }
        out["investment_legs"] = legs;
    }
    if (!_fatal_context.valid) return out;
    out["reason"] = String::utf8(_fatal_context.reason.c_str());
    out["stage"] = stage_name(static_cast<Stage>(_fatal_context.stage));
    out["executed_stage"] =
        stage_name(static_cast<Stage>(_fatal_context.executed_stage));
    out["executed_substage"] =
        String::utf8(_fatal_context.executed_substage.c_str());
    out["day"] = _fatal_context.day;
    out["epoch_id"] = _fatal_context.epoch_id;
    out["command_cursor"] = _fatal_context.command_cursor;
    out["structural_cursor"] = _fatal_context.structural_cursor;
    out["command_opcode"] = _fatal_context.command_opcode;
    out["target_handle"] = _fatal_context.target_handle;
    out["subject_handle"] = _fatal_context.subject_handle;
    out["amount"] = _fatal_context.amount;
    out["d7_operation_gate_mask"] =
        static_cast<int64_t>(_fatal_context.d7_operation_gate_mask);
    out["country_sync_writes_forbidden"] =
        _fatal_context.country_sync_writes_forbidden;
    out["country_worker_authoritative"] =
        _fatal_context.country_worker_authoritative;
    return out;
}

void NativeEconomyRuntime::write_fiscal_continuation_report(
        Dictionary &out) const {
    out["fiscal_reservation_continuation_active"] =
        _fiscal_reservation_continuation.active;
    out["fiscal_reservation_continuation_phase"] =
        _fiscal_reservation_continuation.phase;
    out["fiscal_reservation_country_cursor"] =
        _fiscal_reservation_continuation.country_cursor;
    out["fiscal_reservation_country_count"] =
        _fiscal_reservation_continuation.country_count;
    out["fiscal_reservation_day"] =
        _fiscal_reservation_continuation.day_index;
    out["fiscal_reservation_last_requested"] =
        _fiscal_reservation_continuation.last_requested;
    out["fiscal_reservation_last_reserved"] =
        _fiscal_reservation_continuation.last_reserved;
    out["fiscal_reservation_last_error"] = String::utf8(
        _fiscal_reservation_continuation.last_error.c_str());
    out["epoch_begin_post_fiscal_pending"] =
        _epoch_begin_post_fiscal_pending;
    out["epoch_begin_pending_day"] = _epoch_begin_pending_day;
    out["fiscal_settlement_day"] =
        _fiscal_settlement_continuation.day_index;
}

// Read-only report diagnostics; stage and scheduler authority stays in the root.
int32_t NativeEconomyRuntime::stage_progress_q16() const {
    if (!_epoch_active) {
        if (_fiscal_reservation_continuation.active) {
            const int64_t count = std::max<int32_t>(
                1, _fiscal_reservation_continuation.country_count);
            const int64_t cursor = std::clamp<int64_t>(
                _fiscal_reservation_continuation.country_cursor, 0, count);
            return static_cast<int32_t>(std::clamp<int64_t>(
                (cursor * (Q16_ONE / 10)) / count,
                0, Q16_ONE / 10));
        }
        if (_epoch_begin_post_fiscal_pending)
            return static_cast<int32_t>(Q16_ONE / 10);
        return _fatal ? 0 : static_cast<int32_t>(Q16_ONE - 1);
    }
    switch (_stage) {
        case Stage::EPOCH_BEGIN:
            return static_cast<int32_t>(Q16_ONE / 10);
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
                    std::max(1, market_store().market_count.get()));
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
                           (Q16_ONE / 40)) / std::max(1, _cell_count.get())
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
    const auto &market_pages = _formula_owned != nullptr ? _formula_owned->market_hash_pages : _market_hash_pages;
    for (const auto &column : market_pages) bytes += static_cast<int64_t>(column.memory_bytes());
    bytes += static_cast<int64_t>(_fiscal_hash_pages.memory_bytes());
    bytes += static_cast<int64_t>(_fiscal_hash_words.capacity() * sizeof(uint64_t));
    bytes += static_cast<int64_t>(_fiscal_record_digests.size() * (sizeof(std::pair<const uint64_t, uint64_t>) + 3 * sizeof(void *)));
    auto cap = [&](const auto &v) { bytes += static_cast<int64_t>(v.capacity() * sizeof(typename std::decay_t<decltype(v)>::value_type)); };
    cap(market_store().price_ceilings);
    for (const auto &row : market_store().price_ceilings) cap(row);
    cap(_epoch_price_ceiling_observations);
    cap(_epoch_ceiling_business_requested); cap(_epoch_ceiling_business_unfilled);
    cap(_epoch_ceiling_research_requested); cap(_epoch_ceiling_research_delivered);
    cap(_epoch_ceiling_research_touched);
    cap(_person_index_building_scratch); cap(_person_index_family_scratch);
    cap(_person_index_cohort_scratch); cap(_person_index_cell_scratch);
    cap(_person_index_building_cursor_scratch); cap(_pending_construction_cursor_scratch);
    cap(population_store().cell_first_page); cap(population_store().page_next); cap(population_store().page_cell);
    cap(population_store().free_pages); cap(population_store().active); cap(population_store().reserved);
    cap(population_store().reservation_owner); cap(population_store().signature_id);
    cap(population_store().generation); cap(population_store().population); cap(population_store().funds);
    cap(population_store().epoch_income); cap(population_store().epoch_expense);
    cap(population_store().epoch_in_kind_income); cap(population_store().income_ema);
    cap(population_store().epoch_tax_paid); cap(population_store().epoch_subsidy_received);
    cap(population_store().income_baseline_ema);
    cap(population_store().needs_satisfaction); cap(population_store().worst_need_id);
    cap(population_store().composite_satisfaction); cap(population_store().satisfaction_dims);
    cap(population_store().worst_dimension_id);
    cap(population_store().flags); cap(population_store().demography_residual);
    cap(_birth_residual_q32);
    cap(_cell_support_ema_q16);
    cap(_cell_carrying_k_geo); cap(_cell_carrying_k_eff);
    cap(_cell_carrying_surplus_q16); cap(_cell_carrying_sat_q16);
    cap(_military_ration_sat_q16); cap(_military_ration_sat_present);
    cap(_food_equivalent_goods);
    cap(_cell_carrying_family_surplus_q16); cap(_cell_carrying_family_bindable);
    cap(_cell_food_output_eq_period); cap(_cell_food_input_eq_period);
    cap(_cell_food_import_eq_period); cap(_cell_food_export_eq_period);
    cap(_cell_food_access_eq_period);
    cap(_cell_food_output_eq_previous); cap(_cell_food_input_eq_previous);
    cap(_cell_food_import_eq_previous); cap(_cell_food_export_eq_previous);
    cap(_cell_food_access_eq_previous); cap(_cell_food_flow_valid);
    cap(population_store().owner_employed); cap(population_store().employee_employed);
    cap(families_store().active); cap(families_store().generation); cap(families_store().stable_id);
    cap(families_store().surname_id); cap(families_store().surname_disambiguator);
    cap(families_store().founded_day); cap(families_store().home_cell);
    cap(families_store().origin_ethnicity); cap(families_store().decline_reviews);
    cap(families_store().flags); cap(families_store().free_indices);
    cap(family_memberships()); cap(family_ownerships());
    cap(family_trait_rolls()); cap(_family_trait_commands);
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
    cap(family_expeditions_store().active); cap(family_expeditions_store().generation);
    cap(family_expeditions_store().stable_id); cap(family_expeditions_store().country_handle);
    cap(family_expeditions_store().family_handle); cap(family_expeditions_store().source_cell);
    cap(family_expeditions_store().target_cell); cap(family_expeditions_store().departure_day);
    cap(family_expeditions_store().due_day); cap(family_expeditions_store().route_cost);
    cap(family_expeditions_store().speed); cap(family_expeditions_store().state);
    cap(family_expeditions_store().population); cap(family_expeditions_store().route_begin);
    cap(family_expeditions_store().route_count); cap(family_expeditions_store().payload_begin);
    cap(family_expeditions_store().payload_count);
    cap(family_expeditions_store().kit_bridge_required_units);
    cap(family_expeditions_store().kit_material_required_units);
    cap(family_expeditions_store().effect_transaction_id);
    cap(family_expeditions_store().idempotency_key); cap(family_expeditions_store().free_indices);
    cap(family_expedition_route_cells()); cap(family_expedition_route_costs());
    cap(family_expedition_payloads()); cap(family_expedition_person_handles());
    cap(_family_expedition_due_heap); cap(_colonization_receipts);
    cap(_colonization_quote_cache); cap(_colonization_quote_route_cells);
    cap(_colonization_quote_route_costs); cap(_colonization_distance);
    cap(_colonization_distance_stamp); cap(_colonization_parent);
    cap(_colonization_parent_stamp); cap(_colonization_route_heap);
    bytes += static_cast<int64_t>(_family_expedition_target_index.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int32_t));
    bytes += static_cast<int64_t>(_colonization_quote_index.size()) *
        static_cast<int64_t>(sizeof(uint64_t) + sizeof(int32_t));
    cap(persons_store().active); cap(persons_store().generation); cap(persons_store().stable_id);
    cap(persons_store().family_handle); cap(persons_store().cohort_handle);
    cap(persons_store().given_name_id); cap(persons_store().name_disambiguator);
    cap(persons_store().notable_since_day); cap(persons_store().flags); cap(persons_store().cash_claim);
    cap(persons_store().family_equity_share_q32); cap(persons_store().epoch_job_income);
    cap(persons_store().epoch_business_result); cap(persons_store().epoch_consumption_expense);
    cap(persons_store().epoch_tax); cap(persons_store().income_ema);
    cap(persons_store().needs_satisfaction); cap(persons_store().worst_need_id);
    cap(persons_store().building_handle); cap(persons_store().job_kind);
    cap(persons_store().employee_role_index); cap(persons_store().job_since_day);
    cap(persons_store().free_indices); cap(person_needs()); cap(_person_epoch_needs);
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
    cap(market_store().stock); cap(market_store().price); cap(market_store().demand_ema);
    cap(market_store().last_shortage_q16); cap(market_store().cell_to_market);
    cap(_environment_temperature_q16); cap(_environment_temperature_30d_q16);
    cap(_environment_moisture_q16); cap(_environment_plant_available_water_q16);
    cap(_environment_precipitation_q16);
    cap(_environment_snow_q16); cap(_environment_weather_q16);
    cap(_audit_shadow_population); cap(_audit_shadow_funds);
    cap(_audit_shadow_market_stock);
    cap(_audit_population_lane_stamp); cap(_audit_market_lane_stamp);
    cap(_audit_population_touched_lanes); cap(_audit_market_touched_lanes);
    cap(_money_stage_diagnostics);
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
    cap(_epoch_business_demand_ema); cap(_epoch_derived_business_demand);
    cap(_epoch_derived_anchor_price); cap(_track_b_derived_anchor_carry);
    cap(_derived_household_preview_scratch);
    for (const auto &preview : _derived_household_preview_scratch) cap(preview.goods);
    cap(_epoch_substitute_business_demand);
    cap(_epoch_desired_business_demand);
    cap(_epoch_funded_business_demand); cap(_epoch_offered_supply_ema);
    cap(_epoch_producer_sellable_current);
    cap(_epoch_producer_merchant_sold_current);
    cap(_epoch_producer_discarded_current);
    cap(_epoch_research_demand_by_cell); cap(_epoch_research_demand_by_market);
    cap(_epoch_colonization_demand_by_cell); cap(_epoch_colonization_demand_by_market); cap(_epoch_military_demand_by_cell); cap(_epoch_military_demand_by_market);
    cap(_epoch_bullion_quota_keys); cap(_epoch_bullion_quota_initial);
    cap(_epoch_bullion_quota_remaining);
    cap(_investment_monetary_units_by_cell);
    cap(_epoch_cost_anchor_price);
    cap(_epoch_nonhousehold_withdrawals);
    cap(_production_input_reserve);
    cap(_construction_material_reserve);
    cap(_cell_last_settlement_day); cap(_cell_elapsed_days);
    cap(_cell_tier); cap(_cell_next_review_day); cap(_cell_force_wake);
    cap(_cell_tier_seen_gen); cap(_cell_tier_seen_population);
    cap(_cell_tier_change_day); cap(_cell_shortage_since_day);
    cap(_cell_population_total);
    cap(_cell_settlement_generation);
    cap(_cell_price_stock_gen); cap(_cell_owner_cash_gen); cap(_cell_population_gen);
    cap(_cell_building_structure_gen); cap(_cell_technology_gen);
    cap(_cell_resource_gen); cap(_cell_trade_gen); cap(_cell_effect_shortage_q16);
    cap(_cell_essentials_shortage_q16); cap(_cell_resource_abundance_q16);
    cap(_cell_previous_precipitation_q16); cap(_cell_rain_event_q16);
    cap(_cell_temperature_annual_q16); cap(_cell_temperature_anomaly_q16);
    cap(_cell_hazard_today_mask); cap(_cell_dry_streak_days);
    cap(_cell_days_since_hazard); cap(_cell_previous_hazard_mask);
    cap(_cell_weather_type); cap(_cell_cover);
    cap(_epoch_cell_country); cap(_epoch_cell_visible); cap(_epoch_country_technologies);
    cap(_epoch_country_population);
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
    cap(_fiscal_reservation_continuation.requested_by_country);
    cap(_fiscal_settlement_continuation.unused_by_country);
    cap(_fiscal_settlement_continuation.collected_by_country);
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
    cap(_fiscal_last_non_tax_outflow); cap(_pending_non_tax_outflow);
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
    cap(trade_orders_store().ids); cap(trade_orders_store().sources); cap(trade_orders_store().destinations);
    cap(trade_orders_store().countries); cap(trade_orders_store().departure_days);
    cap(trade_orders_store().arrival_days); cap(trade_orders_store().cash_escrow);
    cap(trade_orders_store().capacity_work); cap(trade_orders_store().states);
    cap(trade_orders_store().cargo_delivered); cap(trade_orders_store().line_offsets);
    cap(trade_orders_store().line_goods); cap(trade_orders_store().line_quantities);
    cap(trade_orders_store().line_unit_prices); cap(trade_orders_store().seller_offsets);
    cap(trade_orders_store().seller_handles); cap(trade_orders_store().seller_weights);
    cap(trade_orders_store().arrival_bucket_days);
    cap(trade_orders_store().arrival_bucket_offsets);
    cap(trade_orders_store().arrival_bucket_orders);
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
    cap(_preview_need_basis_source);
    cap(_family_behavior_source_rows);
    cap(_family_review_cells_scratch);
    cap(_survival_food_need_mask);
    cap(_rules); cap(_rule_params); cap(_pending_commands);
    cap(_epoch_commands); cap(_structural_commands); cap(_committed_cells);
    cap(_staging_cells); cap(_staging_touched_cells);
    for (const std::vector<int32_t> &buffer : _staging_touched_task_scratch)
        cap(buffer);
    cap(_staging_cell_generation);
    cap(_structural_touched_cells); cap(_population_changed_cells);
    cap(_deferred_population_reconcile_cells);
    bytes += _demand_basis_cache.values_bytes() + _demand_basis_cache.index_bytes();
    cap(_building_types); cap(_building_type_market_signal_goods);
    cap(_building_type_labor_signal_professions);
    cap(_building_employee_roles); cap(_building_construction_goods);
    cap(_building_maintenance_author_offsets);
    cap(_building_maintenance_author_goods);
    cap(_building_maintenance_goods);
	cap(_building_upgrade_family_ids); cap(_building_upgrade_family_indices);
	cap(_building_upgrade_tiers); cap(_building_upgrade_required_tiers);
    cap(_building_inputs); cap(_building_input_candidates);
    cap(_building_outputs); cap(_building_resources);
	cap(_building_output_cost_shares_q16);
	cap(_cycle_flow_good_ids);
    cap(_building_resource_generation);
    cap(_building_conditions);
    bytes += building_group_memory_bytes();
    cap(_building_group_order_scratch); cap(_building_group_is_new_scratch);
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
    cap(_building_role_forecast_pay_ratio_q16);
    bytes += static_cast<int64_t>(pending_construction_memory_bytes());
    cap(_pending_construction_cell_offsets);
    cap(_pending_construction_cell_indices);
    cap(resource_stock_lanes()); cap(resource_remaining_lanes());
    cap(resource_harvest_remaining_lanes());
    cap(_resource_gen_base); cap(_resource_gen_temp); cap(_resource_gen_moisture);
    cap(_resource_gen_self); cap(_resource_decay_base); cap(_resource_decay_temp);
    cap(_resource_decay_moisture); cap(_resource_decay_self_q16);
    cap(_resource_ecology_capacity); cap(_resource_ecology_growth_q16);
    cap(_resource_temp_lo_q16); cap(_resource_temp_hi_q16);
    cap(_resource_climate_temp_opt_q16); cap(_resource_climate_temp_tol_q16);
    cap(_resource_climate_moisture_opt_q16);
    cap(_resource_climate_moisture_tol_q16);
    cap(_resource_runtime_fit_weight_q16);
    cap(_resource_temperature_signal); cap(_resource_moisture_signal);
    cap(resource_delta_lanes()); cap(_last_published_resource_deltas);
    cap(resource_lane_generation_lanes()); cap(_resource_touched_lanes);
    cap(_last_published_resource_touched_lanes);
    cap(_building_elevation_q16); cap(_building_terrain);
    cap(_building_landform); cap(_building_vegetation); cap(_building_is_water);
    cap(_building_has_river); cap(_building_neighbors);
    bytes += trace_memory_bytes();
    bytes += static_cast<int64_t>(family_memberships().canonical_memory_bytes() +
        family_ownerships().canonical_memory_bytes() + family_trait_rolls().canonical_memory_bytes() +
        person_needs().canonical_memory_bytes() + family_expedition_payloads().canonical_memory_bytes() +
        family_expedition_cargo().canonical_memory_bytes() + family_expedition_kit_buildings().canonical_memory_bytes());
    bytes += static_cast<int64_t>(_asset_peer_journal.canonical_memory_bytes() +
        _canal_quotes.canonical_memory_bytes() + _canal_projects.canonical_memory_bytes() +
        _canal_quote_index.canonical_memory_bytes() + market_store().price_ceilings.canonical_memory_bytes() +
        _family_founding_offers.canonical_memory_bytes() + _family_modifier_bindings.canonical_memory_bytes() +
        _family_trigger_bindings.canonical_memory_bytes() + _family_effect_bindings.canonical_memory_bytes() +
        _family_founding_effects.canonical_memory_bytes() + _family_split_parents.canonical_memory_bytes());
    return bytes;
}

void NativeEconomyRuntime::copy_tax_sched_diag(
        TaxSchedDiag &out, char *stage, size_t stage_cap,
        char *substage, size_t substage_cap) const {
    out.epoch_fiscal_ms = _epoch_begin_fiscal_ms;
    out.fiscal_settlement_ms = _fiscal_settlement_ms;
    out.income_subsidy_ms = _income_subsidy_epoch_ms;
    out.negative_tax_mask = _epoch_negative_tax_mask;
    out.active_tax_mask = _epoch_active_tax_mask;
    const auto copy_text = [](char *dest, size_t cap, const char *text) {
        if (dest == nullptr || cap == 0) return;
        if (text == nullptr) text = "";
        size_t i = 0;
        for (; i + 1 < cap && text[i] != '\0'; ++i) dest[i] = text[i];
        for (; i < cap; ++i) dest[i] = '\0';
    };
    copy_text(stage, stage_cap, stage_name());
    copy_text(substage, substage_cap, _executed_substage.c_str());
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

// ---------------------------------------------------------------------------
// Sparse-workset probe (diagnostic only).
//
// The headless CSV reads the compact slice report, while the full `report()`
// is what the graphical player consults. Both call this writer so the same
// counter names exist on both paths; nothing here feeds a settlement decision.
// ---------------------------------------------------------------------------
} // namespace pk
