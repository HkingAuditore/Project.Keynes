#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <limits>
#include <vector>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

bool NativeEconomyRuntime::start_epoch(int64_t day_index, std::string &error) {
    EconomyCostProbe probe("epoch.start", day_index);
    const auto epoch_started = Clock::now();
    if (!_bootstrapped || _fatal || _epoch_active) {
        error = "epoch_start_state_invalid";
        return false;
    }
    if (day_index <= _last_committed_day.get()) return true;
    // All failure-prone checks happen here, before any state mutation.
    {
        // Each half is checked separately so the fault names the table, the
        // value it holds and the value the stride demands. A single
        // `market_shape_invariant_broken` with no sizes cannot distinguish a
        // stale market CSR from a stale good count, and this exact check is
        // what a restarted worker lifetime trips on.
        const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
        const size_t markets = static_cast<size_t>(
            std::max(0, market_store().market_count.get()));
        const size_t goods = static_cast<size_t>(
            std::max(0, market_store().good_count.get()));
        const char *shape = nullptr;
        if (market_store().good_count.get() != static_cast<int32_t>(_good_ids.size()))
            shape = "good_count_vs_catalog";
        else if (market_store().cell_to_market.size() != cells)
            shape = "cell_to_market_vs_cell_count";
        else if (market_store().stock.size() != markets * goods)
            shape = "stock_vs_market_x_good";
        else if (_market_cell_offsets.size() != markets + 1)
            shape = "market_cell_offsets_vs_market_count";
        if (shape != nullptr) {
            std::fprintf(stderr,
                "[economy-epoch-shape] day=%lld shape=%s epoch_active=%d "
                "last_committed=%lld current_day=%lld environment_day=%lld "
                "building_context_day=%lld cell_count=%d "
                "cell_to_market=%zu stock=%zu(expect=%zu) "
                "market_cell_offsets=%zu(expect=%zu) "
                "market_count=%d good_count=%d(expect=%zu) "
                "market_cells=%zu\n",
                static_cast<long long>(day_index), shape,
                _epoch_active ? 1 : 0,
                static_cast<long long>(_last_committed_day.get()),
                static_cast<long long>(_current_day.get()),
                static_cast<long long>(_environment_day.get()),
                static_cast<long long>(_building_context_day),
                _cell_count.get(),
                market_store().cell_to_market.size(),
                market_store().stock.size(), markets * goods,
                _market_cell_offsets.size(), markets + 1,
                market_store().market_count.get(),
                market_store().good_count.get(), _good_ids.size(),
                _market_cells.size());
            std::fflush(stderr);
            error = "market_shape_invariant_broken";
            return false;
        }
    }
    if (_environment_day.get() != day_index || _environment_temperature_q16.size() !=
            static_cast<size_t>(_cell_count.get())) {
        error = "same_day_environment_not_captured";
        return false;
    }
    if (!_building_types.empty() && (_building_context_day != day_index ||
        _building_elevation_q16.size() != static_cast<size_t>(_cell_count.get()) ||
        _building_neighbors.size() != static_cast<size_t>(_cell_count.get()) * 6 ||
        resource_stock_lanes().size() != _resource_ids.size() * static_cast<size_t>(_cell_count.get()))) {
        error = "same_day_building_context_not_captured";
        return false;
    }
    if (_merchant_primary_slot.size() != static_cast<size_t>(_cell_count.get())) {
        error = "merchant_index_shape_invalid";
        return false;
    }
    bool merchant_index_dirty = false;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const int32_t primary = _merchant_primary_slot[cell];
        if (is_merchant_slot(primary)) continue;
        if (primary < 0 &&
            (cell >= static_cast<int32_t>(_committed_cells.size()) ||
             _committed_cells[cell].population <= 0))
            continue;
        int64_t population = 0;
        bool has_living_merchant = false;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            population = saturating_add(population, population_store().population[slot],
                                        _saturation_count);
            if (!has_living_merchant && is_merchant_slot(slot))
                has_living_merchant = true;
        });
        if (population <= 0) {
            if (primary >= 0) merchant_index_dirty = true;
            continue;
        }
        if (!has_living_merchant) {
            int64_t repairs = 0;
            if (!ensure_merchant_invariant(cell, repairs, error)) {
                if (error.empty()) error = "merchant_invariant_broken_before_cycle";
                return false;
            }
        }
        merchant_index_dirty = true;
    }
    if (merchant_index_dirty && !rebuild_merchant_ranges(error)) {
        if (error.empty()) error = "merchant_invariant_broken_before_cycle";
        return false;
    }
    const double preflight_ms = elapsed_ms(epoch_started);
    const auto prepare_started = Clock::now();
    clear_epoch_metrics();
    rebuild_family_demography_weights();
    _epoch_preflight_ms = preflight_ms;
    // Do not pin research_consumed here. capture_country_epoch / workset rebuild
    // can race peer-wait preview + late-fold catch_up, which spends TP and bumps
    // research_consumed_total after this pin but before opening goods refresh —
    // VERIFY then subtracts that spend twice and trips goods_error == spend.
    // Opening goods/cash/consumed are sampled together below.
    _country_research_consumed_opening = 0;
    _epoch_begin_reset_ms = elapsed_ms(prepare_started);
    const auto country_started = Clock::now();
    if (!advance_climate_day_columns(error)) return false;
    // The city-factor reader may yield mid-work-set (plan §14.3 sharding). A
    // yield is NOT a failure and NOT a completed epoch open: the caller must
    // park and re-enter.
    //
    // Returning `true` would let `start_epoch` continue into the workset build
    // and publish a half-painted factor matrix. Returning `false` with a plain
    // error would be fatal. So a yield is reported through the SAME soft-barrier
    // convention the function already uses for `same_day_environment_not_captured`
    // (`economy_runtime.cpp:15277-15290`): `false` + an error string the caller
    // recognises as "park, do not fail".
    bool city_factors_pending = false;
    if (!capture_country_epoch(error, &city_factors_pending)) return false;
    if (city_factors_pending) {
        error = "city_factor_shard_pending";
        return false;
    }
    _epoch_begin_country_ms = elapsed_ms(country_started);
    const auto workset_started = Clock::now();
    rebuild_economy_live_cells();
    // Freeze the birth-support population once, from the same boundary as the
    // country and cohort snapshots. Cadence refreshes may rebuild live cells
    // during the epoch, but must not change this period's demographic input.
    capture_epoch_country_population();
    maybe_lock_cadence_cycles(day_index);
    _rolling_phase = cycle_phase(day_index, _market_cycle_start_day.get(),
                                 locked_market_cycle_days());
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _epoch_plan_cells.clear();
    const int32_t market_count = std::max(0, market_store().market_count.get());
    const bool have_market_map =
        market_store().cell_to_market.size() == static_cast<size_t>(_cell_count.get());
    std::vector<uint8_t> market_added(static_cast<size_t>(market_count), 0);
    for (const int32_t cell : _economy_live_cells) {
        if (!cell_in_market_workset(cell, day_index)) continue;
        _epoch_settlement_cells.push_back(cell);
        int32_t market = cell;
        if (have_market_map) market = market_store().cell_to_market[cell];
        if (market < 0 || market >= market_count) continue;
        if (market_added[static_cast<size_t>(market)] != 0) continue;
        market_added[static_cast<size_t>(market)] = 1;
        _epoch_market_ids.push_back(market);
    }
    std::sort(_epoch_market_ids.begin(), _epoch_market_ids.end());
    _workset_cells_planned = static_cast<int64_t>(_epoch_settlement_cells.size());
    _resource_touched_lanes.reserve(
        _resource_ids.size() * _epoch_settlement_cells.size());
    const auto resource_lane_started = Clock::now();
    // Initialize only the lanes reachable by this rolling phase. Production
    // workers then operate on disjoint, preinitialized lanes and never race on
    // the touched list.
    for (int32_t resource = 0;
         resource < static_cast<int32_t>(_resource_ids.size()); ++resource) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count.get()) continue;
            ensure_resource_lane(
                static_cast<size_t>(resource) * _cell_count.get() + cell);
        }
    }
    _epoch_begin_resource_lane_ms = elapsed_ms(resource_lane_started);
    // Freeze the deterministic cost model once per epoch. Recomputing these
    // cohort/building scans in every household continuation was measurable
    // scheduler-side overhead and provided no newer information.
    _epoch_market_work_weights.resize(_epoch_market_ids.size());
    for (size_t relative = 0; relative < _epoch_market_ids.size(); ++relative) {
        const int32_t market = _epoch_market_ids[relative];
        int64_t market_work = 32;
        for (int32_t k = _market_cell_offsets[market];
             k < _market_cell_offsets[market + 1]; ++k) {
            const int32_t cell = _market_cells[k];
            market_work += static_cast<int64_t>(
                _committed_cells[cell].cohort_count) * 16;
            if (_building_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                market_work += static_cast<int64_t>(
                    _building_cell_offsets[cell + 1] -
                    _building_cell_offsets[cell]) * 4;
            }
        }
        _epoch_market_work_weights[relative] = market_work;
    }
    for (const int32_t cell : _building_active_cells) {
        if (cell_in_market_workset(cell, day_index))
            _epoch_building_cells.push_back(cell);
    }
    {
        _epoch_plan_cells.clear();
        for (const int32_t cell : _epoch_building_cells) {
            if (cell_due_plan_review(cell, day_index))
                _epoch_plan_cells.push_back(cell);
        }
        // Lifecycle health is an every-settlement observation. A producer
        // that has already recorded a severe loss must be reconsidered on the
        // next market boundary even when the slower investment cadence is not
        // due; otherwise hysteresis can stall between plan buckets.
        if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (const int32_t cell : _epoch_building_cells) {
                if (!cell_in_market_workset(cell, day_index)) continue;
                bool needs_lifecycle_review = false;
                for (int32_t g = _building_cell_offsets[cell];
                     g < _building_cell_offsets[cell + 1]; ++g) {
                    const auto group = building_view(static_cast<size_t>(g));
                    if (group.count > 0 && group.severe_loss_cycles >= 2) {
                        needs_lifecycle_review = true;
                        break;
                    }
                }
                if (needs_lifecycle_review && std::find(
                        _epoch_plan_cells.begin(), _epoch_plan_cells.end(), cell) ==
                        _epoch_plan_cells.end()) {
                    _epoch_plan_cells.push_back(cell);
                }
            }
            std::sort(_epoch_plan_cells.begin(), _epoch_plan_cells.end());
        }
    }
    // Sparse-workset probe: freeze this epoch's workset shape. Pure reads; the
    // values only ever reach the diagnostic report.
    _probe_workset_building_cells =
        static_cast<int64_t>(_epoch_building_cells.size());
    _probe_workset_plan_cells =
        static_cast<int64_t>(_epoch_plan_cells.size());
    _probe_workset_live_cells =
        static_cast<int64_t>(_economy_live_cells.size());
    _probe_market_bucket_index = _rolling_phase;
    _probe_market_cycle_days = locked_market_cycle_days();
    _probe_plan_cycle_days = locked_plan_cycle_days();
    _probe_cells_per_slice = _building_cells_per_slice;
    _probe_workset_coverage_permille = _probe_workset_live_cells > 0
        ? (_probe_workset_building_cells * 1000) / _probe_workset_live_cells
        : 0;
    {
        int64_t market_cells_due = 0;
        for (size_t relative = 0; relative < _epoch_market_ids.size();
             ++relative) {
            const int32_t market = _epoch_market_ids[relative];
            if (market < 0) continue;
            const size_t index = static_cast<size_t>(market);
            if (index + 1 >= _market_cell_offsets.size()) continue;
            market_cells_due += static_cast<int64_t>(
                _market_cell_offsets[index + 1] - _market_cell_offsets[index]);
        }
        _probe_workset_market_cells_due = market_cells_due;
    }
    _epoch_days = workset_elapsed_days(day_index);
    capture_cell_elapsed_days(day_index);
    refresh_cell_activity_tiers(day_index);
    _commit_lag_budget_days = std::max(0, locked_market_cycle_days() - 1);
    _epoch_begin_workset_ms = elapsed_ms(workset_started);
    // National procurement policy / era targets become visible only at this
    // epoch boundary (after the country capture and epoch_days are frozen,
    // before fiscal reservation reads the research floor).
    apply_pending_procurement_updates(day_index);
    freeze_epoch_procurement_budgets();
    const auto fiscal_started = Clock::now();
    if (!prepare_fiscal_budgets(day_index, error)) return false;
    _epoch_begin_fiscal_ms += elapsed_ms(fiscal_started);
    if (_fiscal_reservation_continuation.active) {
        _epoch_begin_post_fiscal_pending = true;
        _epoch_begin_pending_day = day_index;
        _prepare_ms = elapsed_ms(prepare_started);
        _epoch_begin_ms = elapsed_ms(epoch_started);
        return true;
    }
    if (!finish_epoch_start_after_fiscal(day_index, error)) return false;
    _prepare_ms = elapsed_ms(prepare_started);
    _epoch_begin_ms = elapsed_ms(epoch_started);
    if (day_index % 100 == 0) {
        std::fprintf(stderr, "[economy-open-cost] day=%lld total=%.3f preflight=%.3f reset=%.3f country=%.3f workset=%.3f resource=%.3f fiscal=%.3f csr=%.3f recovery=%.3f vectors=%.3f commands=%.3f\n",
            static_cast<long long>(day_index), _epoch_begin_ms, _epoch_preflight_ms,
            _epoch_begin_reset_ms, _epoch_begin_country_ms, _epoch_begin_workset_ms,
            _epoch_begin_resource_lane_ms, _epoch_begin_fiscal_ms,
            _epoch_begin_construction_csr_ms, _epoch_begin_recovery_apply_ms,
            _epoch_begin_vector_init_ms, _epoch_begin_commands_ms);
    }
    return true;
}

bool NativeEconomyRuntime::finish_epoch_start_after_fiscal(
        int64_t day_index, std::string &error) {
    EconomyCostProbe probe("epoch.finish", day_index);
    if (_fiscal_reservation_continuation.active) {
        error = "fiscal_reservation_still_active";
        return false;
    }
    if (_fiscal_reservation_continuation.phase == 3) {
        error = _fiscal_reservation_continuation.last_error.empty()
            ? "fiscal_reservation_faulted"
            : _fiscal_reservation_continuation.last_error;
        return false;
    }
    // Fiscal escrow is removed from the country treasury by the reservation
    // pass. Research demand must see the remaining cash, so freeze it only
    // after fiscal budgets are prepared.
    refresh_epoch_research_demand();
    // Bullion issuance must use the post-reservation spendable treasury. The
    // quota routine excludes fiscal/trade escrow, so refresh it after fiscal
    // reservation and before production/investment planning.
    refresh_epoch_bullion_quota();
    const auto resource_lane_2_started = Clock::now();
    for (int32_t resource = 0;
         resource < static_cast<int32_t>(_resource_ids.size()); ++resource) {
        for (const int32_t cell : _epoch_building_cells) {
            ensure_resource_lane(
                static_cast<size_t>(resource) * _cell_count.get() + cell);
        }
    }
    _epoch_begin_resource_lane_ms += elapsed_ms(resource_lane_2_started);
    const auto construction_csr_started = Clock::now();
    // A+Y N8: CSR is rebuilt straight from the sole pending columns.
    const std::vector<int32_t> &pending_cells = buildings_store().pending_cell;
    _pending_construction_cell_offsets.assign(
        static_cast<size_t>(_cell_count.get()) + 1, 0);
    for (const int32_t pending_cell : pending_cells) {
        if (pending_cell >= 0 && pending_cell < _cell_count.get())
            ++_pending_construction_cell_offsets[pending_cell + 1];
    }
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        _pending_construction_cell_offsets[cell + 1] +=
            _pending_construction_cell_offsets[cell];
    }
    _pending_construction_cell_indices.resize(
        static_cast<size_t>(_pending_construction_cell_offsets.back()));
    auto &pending_cursors = _pending_construction_cursor_scratch;
    pending_cursors.assign(
        _pending_construction_cell_offsets.begin(),
        _pending_construction_cell_offsets.end() - 1);
    for (int32_t pending_index = 0;
         pending_index < static_cast<int32_t>(pending_cells.size());
         ++pending_index) {
        const int32_t cell = pending_cells[pending_index];
        if (cell >= 0 && cell < _cell_count.get())
            _pending_construction_cell_indices[pending_cursors[cell]++] = pending_index;
    }
    _epoch_begin_construction_csr_ms = elapsed_ms(construction_csr_started);
    const auto recovery_apply_started = Clock::now();
    // Recovery outcomes are committed only when this cell becomes due again.
    // This keeps employment and the published operating state on the same
    // frozen-cycle boundary instead of changing state after hiring has settled.
    for (const int32_t cell : _epoch_building_cells) {
        if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
            continue;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const auto view = building_view(static_cast<size_t>(g));
            if (view.pending_operating_state > 1 && view.operating_state <= 1 &&
                view.recovery_cycles == 0 && view.recovery_cooldown_cycles == 0) {
                continue;
            }
            auto group = building_at(static_cast<size_t>(g));
            const bool applying_pending = group.pending_operating_state <= 1;
            if (applying_pending) {
                group.operating_state = group.pending_operating_state;
                group.pending_operating_state = 255;
                if (group.operating_state == 0) {
                    group.severe_loss_cycles = 0;
                    group.recovery_failed_reviews = 0;
                }
            }
            if (group.operating_state > 1) {
                group.operating_state = 1;
                group.recovery_cycles = 0;
                group.recovery_cooldown_cycles = 0;
            }
            // These lanes are retained only for binary compatibility. The
            // lifecycle no longer has a probe or cooldown phase.
            group.recovery_cycles = 0;
            group.recovery_cooldown_cycles = 0;
        }
    }
    _epoch_begin_recovery_apply_ms = elapsed_ms(recovery_apply_started);
    {
    EconomyCostProbe probe("epoch_vectors", day_index, _market_signals.good_ids.size());
    const auto vector_init_started = Clock::now();
    _rolling_due_cells = static_cast<int32_t>(_epoch_settlement_cells.size());
    _rolling_processed_cells = 0;
    _rolling_deferred_cells = 0;
    _building_survival_utilization_floor_q16.assign(building_count(), 0);
    _building_planned_capacity_before_climate_q16.assign(
        building_count(), Q16_ONE);
    _building_owner_livelihood_credit.assign(building_count(), 0);
    _building_merchant_credit_limit.assign(building_count(), 0);
    _building_recovery_probe_capacity_q16.assign(building_count(), 0);
    _building_recovery_liquidation_eligible.assign(building_count(), 0);
    _production_input_reserve.assign(_market_signals.good_ids.size(), 0);
    _construction_material_reserve.assign(_market_signals.good_ids.size(), 0);
    _epoch_business_demand_ema = _market_signals.business_demand_ema;
    _epoch_derived_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_derived_anchor_price.assign(_market_signals.good_ids.size(), 0);
    // Keep last epoch's substitute demand through Leontief refresh so one-hop
    // intermediates still see category co-candidate pressure, then clear for
    // this epoch's production to republish.
    if (_epoch_substitute_business_demand.size() != _market_signals.good_ids.size()) {
        _epoch_substitute_business_demand.assign(_market_signals.good_ids.size(), 0);
    }
    _epoch_desired_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_funded_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_price_ceiling_observations.clear();
    _epoch_ceiling_business_requested.assign(_market_signals.good_ids.size(), 0);
    _epoch_ceiling_business_unfilled.assign(_market_signals.good_ids.size(), 0);
    _epoch_ceiling_research_requested.resize(market_store().market_count.get(), 0);
    _epoch_ceiling_research_delivered.resize(market_store().market_count.get(), 0);
    _epoch_offered_supply_ema = _market_signals.offered_supply_ema;
    _epoch_producer_sellable_current.assign(_market_signals.good_ids.size(), 0);
    _epoch_producer_merchant_sold_current.assign(
        _market_signals.good_ids.size(), 0);
    if (_epoch_previous_producer_sellable.size() !=
            _market_signals.good_ids.size())
        _epoch_previous_producer_sellable.assign(
            _market_signals.good_ids.size(), 0);
    if (_epoch_previous_producer_merchant_sold.size() !=
            _market_signals.good_ids.size())
        _epoch_previous_producer_merchant_sold.assign(
            _market_signals.good_ids.size(), 0);
    _epoch_producer_discarded_current.assign(_market_signals.good_ids.size(), 0);
    _epoch_nonhousehold_withdrawals.assign(_market_signals.good_ids.size(), 0);
    _epoch_cost_anchor_price = _market_signals.cost_anchor_price;
    refresh_epoch_colonization_demand();
    refresh_epoch_era_demand();
    drain_worker_command_inbox();
    refresh_epoch_military_demand(day_index);
    refresh_derived_business_demand();
    _epoch_substitute_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_begin_vector_init_ms = elapsed_ms(vector_init_started);
    }
    const auto audit_started = Clock::now();
    int64_t live_expedition_population = 0;
    int64_t live_expedition_funds = 0;
    int64_t live_expedition_goods = 0;
    sum_family_expedition_holdings(live_expedition_population,
                                   live_expedition_funds, live_expedition_goods,
                                   _saturation_count);
    // Idle start/return moves cohort funds into expedition escrow (or back)
    // before this opening snapshot. Copying last close then live-replacing
    // escrow would double-count or drop that money. Force a full scan whenever
    // in-transit holdings drifted since the last committed close.
    const bool expedition_holdings_changed =
        live_expedition_population != _closing_totals.transit_population ||
        live_expedition_funds != _closing_totals.expedition_funds ||
        live_expedition_goods != _closing_totals.expedition_goods;
    // BEGIN army personnel lane (contract §1.2): the same drift rule applies to
    // embarked people and their cash — the closing snapshot of the previous
    // epoch already folded them in (`army_lane_population`/`army_lane_funds`).
    int64_t live_army_lane_population = _army_personnel.total_population();
    int64_t live_army_lane_funds = _army_personnel.total_funds();
    const bool army_lane_holdings_changed =
        live_army_lane_population != _closing_totals.army_lane_population ||
        live_army_lane_funds != _closing_totals.army_lane_funds;
    // END army personnel lane
    const bool continuous_audit = audit_shadow_reuse_enabled() &&
        _closing_audit_mode == 2 && !_closing_audit_runtime_disabled &&
        _audit_mutation_generation != 0;
    const bool full_audit_verify = _opening_audit_force_full ||
        (_last_closing_audit_was_incremental && !continuous_audit) ||
        expedition_holdings_changed || army_lane_holdings_changed ||
        day_index % _full_audit_verify_interval_days == 0;
    // The new epoch invalidates last epoch's close until AGGREGATE_PUBLISH
    // recomputes it. A fatal before that point must report the conservation
    // errors as unknown, not as the stale delta against this opening snapshot.
    _closing_totals_valid = false;
    if (full_audit_verify) {
        EconomyCostProbe probe("opening_audit_full", day_index, market_store().stock.size());
        _opening_totals = audit_totals();
        ++_opening_audit_full_verifications;
    } else {
        _opening_totals = continuous_audit
            ? audit_totals_from_shadow(_closing_totals) : _closing_totals;
        int64_t opening_escrow_saturation = 0;
        _opening_totals.expedition_funds = live_expedition_funds;
        _opening_totals.expedition_goods = live_expedition_goods;
        _opening_totals.transit_population = live_expedition_population;
        _opening_totals.escrow_cash = saturating_add(
            saturating_add(trade_escrow_cash(), fiscal_escrow_total(),
                           opening_escrow_saturation),
            live_expedition_funds, opening_escrow_saturation);
        // BEGIN army personnel lane: embarked people and their cash sit outside
        // the cohort table, so the fast path must fold the live lane holdings in
        // the same way it folds the expedition escrow.
        _opening_totals.army_lane_population = live_army_lane_population;
        _opening_totals.army_lane_funds = live_army_lane_funds;
        _opening_totals.transit_population = saturating_add(
            _opening_totals.transit_population, live_army_lane_population,
            opening_escrow_saturation);
        _opening_totals.escrow_cash = saturating_add(
            _opening_totals.escrow_cash, live_army_lane_funds,
            opening_escrow_saturation);
        // END army personnel lane
        _saturation_count += opening_escrow_saturation;
        ++_opening_audit_fast_paths;
    }
    const char *verify_opening = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_AUDIT_VERIFY_EVERY_DAY);
    if (continuous_audit && verify_opening && std::strcmp(verify_opening, "1") == 0) {
        const AuditTotals reference = audit_totals();
        if (_opening_totals.population != reference.population ||
            _opening_totals.cohort_funds != reference.cohort_funds ||
            _opening_totals.goods_stock != reference.goods_stock ||
            _opening_totals.escrow_cash != reference.escrow_cash) {
            _closing_audit_runtime_disabled = true;
            _opening_audit_force_full = true;
            error = "opening_incremental_audit_mismatch";
            return false;
        }
    }
    // Pin country treasury goods/cash with research_consumed from one snapshot.
    // Peer-wait preview / late-fold catch_up must not split these across the
    // long epoch-begin window or VERIFY reports goods_error == spent TP.
    int64_t opening_country_goods = 0;
    int64_t opening_research_consumed = 0;
    int64_t opening_country_cash = 0;
    if (_country_runtime != nullptr) {
        country_reads().sample_economy_goods_audit(
            opening_country_goods, opening_research_consumed,
            opening_country_cash);
        _opening_totals.goods_stock +=
            opening_country_goods - _opening_totals.country_goods;
        _opening_totals.country_goods = opening_country_goods;
        _opening_totals.country_cash = _country_runtime != nullptr
        ? country_cash_for_audit(opening_country_cash)
        : opening_country_cash;
    }
    _country_research_consumed_opening = opening_research_consumed;
    _opening_audit_force_full = false;
    _audit_ms += elapsed_ms(audit_started);
    clear_demand_basis_day();
    _sample_day = day_index;
    _current_day = day_index;
    begin_incremental_audit_epoch();
    _epoch_active = true;
    // Keep restored resource lanes through every preflight capture; after the
    // epoch starts live MapData captures may resume their normal ownership.
    _resource_stock_restored_pending_capture = false;
    // Worker-local result lanes are registered on the owning thread when each
    // market/production range is merged. This avoids scanning every due cell
    // and every good at epoch open while preserving the incremental audit
    // shadow for all actual mutation lanes.
    _epoch_begin_audit_lane_ms = 0.0;
    ++_epoch_id;
    trace_begin_epoch();
    const auto commands_started = Clock::now();
    _epoch_commands.clear();
    process_country_ai_colonization_intents(day_index);
    drain_worker_command_inbox();
    auto due_end = _pending_commands.stable_partition(
                                         [&](const Command &c) {
        return c.opcode != COMMAND_MILITARY_PROCUREMENT_DEMAND && c.opcode != COMMAND_MILITARY_PURCHASE_RECEIPT && c.effective_day <= day_index;
    });
    _epoch_commands.assign(_pending_commands.begin(), due_end);
    _pending_commands.erase(_pending_commands.begin(), due_end);
    _epoch_commands.stable_sort( [](const Command &a, const Command &b) {
        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
        if (a.sequence != b.sequence) return a.sequence < b.sequence;
        if (a.opcode != b.opcode) return a.opcode < b.opcode;
        if (a.target_handle != b.target_handle) return a.target_handle < b.target_handle;
        if (a.i32_0 != b.i32_0) return a.i32_0 < b.i32_0;
        if (a.i32_1 != b.i32_1) return a.i32_1 < b.i32_1;
        if (a.i64_0 != b.i64_0) return a.i64_0 < b.i64_0;
        if (a.i64_1 != b.i64_1) return a.i64_1 < b.i64_1;
        return a.submit_order < b.submit_order;
    });
    auto reject_epoch_command = [&](const Command &cmd) {
        ++_rejected_commands;
        if (cmd.effect_request_id != 0) {
            EffectCommandResult &result =
                _effect_command_results[cmd.effect_request_id];
            result.complete = 1;
            result.ok = 0;
            if (result.reason.empty())
                result.reason = "effect_economy_epoch_preflight_rejected";
        }
        return true;
    };
    _epoch_commands.erase_if(
                                         [&](const Command &cmd) {
        const bool family_reward = is_family_ledger_command(cmd.opcode);
        const bool expedition_command =
            cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION;
        // Expedition commands target FamilyExpeditionStore handles, not
        // cohort handles. Treating SETTLE as a cohort write dropped the
        // command, left the Effect request incomplete, and froze the
        // expedition in SETTLING.
        const bool targets_cohort = !family_reward && !expedition_command &&
                                    cmd.opcode != COMMAND_MILITARY_PURCHASE &&
                                    cmd.opcode != COMMAND_MILITARY_PURCHASE_ACK &&
                                    cmd.opcode != COMMAND_TREASURY_SPONSORED_BUILD &&
                                    cmd.opcode != COMMAND_TREASURY_SPONSORED_DEMOLISH &&
                                    cmd.opcode != COMMAND_BUILD_CANAL &&
                                    cmd.opcode != COMMAND_ADD_STOCK &&
                                    cmd.opcode != COMMAND_REMOVE_STOCK &&
                                    cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                                    cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY;
        int32_t slot = -1;
        if (targets_cohort && !population_store().valid_handle(cmd.target_handle, slot))
            return reject_epoch_command(cmd);
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_REMOVE_STOCK ||
             cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
             cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= market_store().market_count.get() || cmd.i32_1 < 0 ||
             cmd.i32_1 >= market_store().good_count.get())) {
            return reject_epoch_command(cmd);
        }
        if ((cmd.opcode == COMMAND_ADD_STOCK || cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET) &&
            _merchant_primary_slot[cmd.i32_0] < 0) {
            return reject_epoch_command(cmd);
        }
        if ((cmd.opcode == COMMAND_MOVE_POPULATION &&
             (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count.get())) ||
            (cmd.opcode == COMMAND_CHANGE_SIGNATURE &&
             (cmd.i32_0 < 0 || cmd.i32_0 >= static_cast<int32_t>(_signatures.size())))) {
            return reject_epoch_command(cmd);
        }
        // Treasury construction validates in its settlement handler, which
        // publishes a terminal receipt for every accepted command.
        if ((cmd.opcode == COMMAND_BUILD || cmd.opcode == COMMAND_DEMOLISH) &&
            (cmd.i32_0 < 0 || cmd.i32_0 >= _cell_count.get() || cmd.i32_1 < 0 ||
             cmd.i32_1 >= static_cast<int32_t>(_building_types.size()) || cmd.i64_0 <= 0)) {
            return reject_epoch_command(cmd);
        }
        if (cmd.opcode == COMMAND_BUILD_CANAL &&
            (_country_runtime == nullptr || !country_reads().valid_handle(
                static_cast<int64_t>(cmd.target_handle)) || cmd.i64_0 <= 0)) {
            return reject_epoch_command(cmd);
        }
        if (cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION) {
            int32_t expedition = -1;
            if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition) ||
                cmd.i32_0 != family_expeditions_store().target_cell[expedition] ||
                cmd.i64_1 != static_cast<int64_t>(
                    family_expeditions_store().country_handle[expedition])) {
                return reject_epoch_command(cmd);
            }
        }
        if (family_reward && !family_ledger_command_preflight(cmd)) {
            return reject_epoch_command(cmd);
        }
        return false;
    });
    // Population adjustments must be visible to building plan / recovery. The
    // normal LEDGER_APPLY stage runs after BUILDING_PLAN, which previously let
    // recovery approve against labour that the same epoch was about to remove.
    {
        std::vector<Command> remaining;
        remaining.reserve(_epoch_commands.size());
        for (const Command &cmd : _epoch_commands) {
            if (cmd.opcode != COMMAND_ADD_POPULATION) {
                remaining.push_back(cmd);
                continue;
            }
            std::string apply_error;
            if (!apply_command(cmd, apply_error)) {
                if (cmd.effect_request_id != 0) {
                    EffectCommandResult &result =
                        _effect_command_results[cmd.effect_request_id];
                    result.complete = 1;
                    result.ok = 0;
                    result.reason = apply_error.empty()
                        ? "effect_economy_commit_failed" : apply_error;
                }
                error = apply_error.empty() ? "ledger_apply_failed" : apply_error;
                fail(error);
                return false;
            }
            if (cmd.effect_request_id != 0) {
                EffectCommandResult &result =
                    _effect_command_results[cmd.effect_request_id];
                result.complete = 1;
                result.ok = 1;
                result.reason.clear();
            }
            ++_processed_commands;
        }
        _epoch_commands.swap(remaining);
    }
    _epoch_begin_commands_ms = elapsed_ms(commands_started);
    if (day_index % 100 == 0) std::fprintf(stderr, "[economy-open-finish] day=%lld country=%.3f workset=%.3f fiscal=%.3f csr=%.3f recovery=%.3f vectors=%.3f audit=%.3f commands=%.3f\n", static_cast<long long>(day_index), _epoch_begin_country_ms, _epoch_begin_workset_ms, _epoch_begin_fiscal_ms, _epoch_begin_construction_csr_ms, _epoch_begin_recovery_apply_ms, _epoch_begin_vector_init_ms, _audit_ms, _epoch_begin_commands_ms);
    _stage = building_count() == 0 ? Stage::TRADE_SETTLE : Stage::BUILDING_PLAN;
    _epoch_begin_post_fiscal_pending = false;
    _epoch_begin_pending_day = -1;
    return true;
}

} // namespace pk
