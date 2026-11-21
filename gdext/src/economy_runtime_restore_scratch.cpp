#include "economy_runtime.h"

namespace pk {

void NativeEconomyRuntime::prepare_restore_candidate_scratch() {
    // Restoring into the same object must not retain another world's prepared
    // country views, even if its shape and generation numbers happen to match.
    _country_availability_cache.invalidate();
    _country_territory_cache.invalidate();
    // Candidate rebuild surface only. Callers must already hold a validated
    // ECP2 backup (or be on the explicit migrate helper path).
    _restore.scratch_prepared = true;
    _bootstrapped = false;
    population_store().clear(_cell_count.get());
    // PKEC62 legitimately has no mobilization section. A candidate starts
    // empty even when the destination previously held another world's rows.
    _stratum_mobilization.clear(_cell_count.get());
    family_expeditions_store().clear();
    family_expedition_route_cells().clear();
    family_expedition_route_costs().clear();
    family_expedition_payloads().clear();
    family_expedition_person_handles().clear();
    family_expedition_cargo().clear();
    family_expedition_kit_buildings().clear();
    family_expedition_missing_good_ids().clear();
    family_expedition_missing_good_quantities().clear();
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    // Outflows booked since the last published batch are transient; the restored
    // batch lane comes from the save, so a restore must not carry a stale one.
    _pending_non_tax_outflow.clear();
    _colonization_receipts.clear();
    {
        std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
        _worker_command_inbox->commands.clear();
    }
    clear_procurement_runtime_state(true);
    _birth_residual_q32.assign(
        static_cast<size_t>(_cell_count.get()) * _ethnicity_ids.size(), 0);
    _settlements.clear(_cell_count.get());
    market_store().clear();
    _market_signals.clear(_cell_count.get());
    _epoch_producer_sellable_current.clear();
    _epoch_producer_merchant_sold_current.clear();
    _epoch_previous_producer_sellable.clear();
    _epoch_previous_producer_merchant_sold.clear();
    _labor_signals.clear(_cell_count.get());
    _trade_plan.clear_transient();
    _trade_active_key_idle_cycles.clear();
    _trade_signal_clock_keys.clear();
    _trade_signal_bulk_keys_scratch.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    trade_orders_store().clear();
    _trade_flows.clear();
    _tariff_history.clear();
    _country_good_trade.clear();
    _country_partner_trade.clear();
    _country_good_trade_index.clear();
    _country_partner_trade_index.clear();
    _tariff_history_index.clear();
    _country_good_display_rows.clear();
    _country_partner_display_rows.clear();
    _country_good_display_dirty.clear();
    _country_partner_display_dirty.clear();
    _country_trade_revision = 0;
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    // BEGIN army personnel lane: a restore rebuilds lanes from its own section.
    _army_personnel.clear();
    // END army personnel lane
    clear_building_groups();
    _building_handle_index_clean = false;
    _building_group_order_scratch.clear();
    _building_group_is_new_scratch.clear();
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.clear();
    _building_free_role_spans_by_type.assign(_building_types.size(), {});
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _building_role_contract_wage.clear();
    _building_role_base_living_cost.clear();
    _building_role_living_cost.clear();
    _building_role_local_average_wage.clear();
    _building_role_base_wage_due.clear();
    _building_role_base_wage_paid.clear();
    _building_role_bonus_due.clear();
    _building_role_bonus_paid.clear();
    _building_role_forecast_pay_ratio_q16.clear();
    clear_pending_construction();
    _canal_quotes.clear();
    _canal_quote_index.clear();
    _canal_projects.clear();
    _canal_project_index.clear();
    _canal_receipts.clear();
    _next_canal_quote_token = 1;
    _next_canal_project_id = 1;
    _next_canal_receipt_id = 1;
    _committed_cells.assign(_cell_count.get(), {});
    _cell_last_settlement_day.assign(_cell_count.get(), -ROLLING_PHASE_COUNT);
    _cell_settlement_generation.assign(_cell_count.get(), 0);
    _cell_price_stock_gen.assign(_cell_count.get(), 0);
    _cell_owner_cash_gen.assign(_cell_count.get(), 0);
    _cell_population_gen.assign(_cell_count.get(), 0);
    _cell_building_structure_gen.assign(_cell_count.get(), 0);
    _cell_technology_gen.assign(_cell_count.get(), 0);
    _cell_resource_gen.assign(_cell_count.get(), 0);
    _cell_trade_gen.assign(_cell_count.get(), 0);
    _cell_effect_shortage_q16.assign(_cell_count.get(), 0);
    _cell_essentials_shortage_q16.assign(_cell_count.get(), 0);
    _cell_resource_abundance_q16.assign(_cell_count.get(), 0);
    _fiscal_previous_country_handles.assign(
        static_cast<size_t>(_cell_count.get()), 0);
    _fiscal_previous_requests.assign(
        static_cast<size_t>(_cell_count.get()) * ACTIVE_TAX_KIND_COUNT, 0);
    _fiscal_reservation_continuation = {};
    _fiscal_settlement_continuation = {};
    _asset_peer_journal.clear();
    _fiscal_digest_rebuild = true;
    _fiscal_words_dirty = true;
    _fiscal_hash_dirty_from_word = 0;
    _fiscal_record_digests.clear();
    _fiscal_hash_words.clear();
    _fiscal_hash_pages.clear();
    _epoch_begin_post_fiscal_pending = false;
    _epoch_begin_pending_day = -1;
    _fiscal_last_events.clear();
    _tariff_epoch_cells.clear();
    _tariff_epoch_kinds.clear();
    _tariff_epoch_bases.clear();
    _tariff_epoch_assessed.clear();
    _tariff_epoch_collected.clear();
    _tariff_epoch_requests.clear();
    _tariff_epoch_reserved.clear();
    _tariff_epoch_paid.clear();
    _tariff_epoch_events.clear();
    _tariff_lane_index.clear();
    _tariff_lane_stamp.clear();
    _tariff_lane_generation = 0;
    _tariff_country_requests.clear();
    _tariff_country_budgets.clear();
    _tariff_country_remaining.clear();
}

bool NativeEconomyRuntime::validate_restored_committed_snapshot(
        std::string &error) const {
    error.clear();
    if (!_bootstrapped) {
        error = "restore_snapshot_not_bootstrapped";
        return false;
    }
    if (_fatal) {
        error = _fatal_reason.empty() ? "restore_snapshot_fatal"
                                      : _fatal_reason;
        return false;
    }
    if (_last_committed_day.get() < 0 || _current_day.get() < _last_committed_day.get()) {
        error = "restore_day_order_invalid";
        return false;
    }
    if (_committed_generation == 0) {
        error = "restore_generation_invalid";
        return false;
    }
    RuntimeEconomyLedgerState ledger;
    const_cast<NativeEconomyRuntime *>(this)->capture_committed_ledger_state(
        ledger);
    if (!ledger.valid()) {
        error = "restore_ledger_invalid";
        return false;
    }
    if (ledger.generation != 0 &&
        ledger.generation != _committed_generation) {
        error = "restore_generation_mismatch";
        return false;
    }
    if (ledger.ledger_hash != 0 &&
        ledger.ledger_hash != ledger.computed_hash()) {
        error = "restore_ledger_hash_mismatch";
        return false;
    }
    return true;
}

} // namespace pk
