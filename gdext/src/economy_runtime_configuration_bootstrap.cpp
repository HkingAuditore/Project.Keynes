#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "economy_host_port.h"
#include "parallel_dispatcher.h"
#include "runtime_economy_pod.h"

#include <algorithm>
#include <limits>
#include <numeric>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/variant/utility_functions.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

Dictionary NativeEconomyRuntime::bootstrap(const Dictionary &population_packet,
                                           const Dictionary &market_packet) {
    Dictionary out;
    out["path"] = "ECONOMY_GRAPH";
    if (!_configured || _epoch_active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" : "epoch_in_flight";
        return out;
    }
    _bootstrapped = false;
    _demand_basis_cache = {};
    population_store().clear(_cell_count.get());
    _birth_residual_q32.assign(
        static_cast<size_t>(_cell_count.get()) * _ethnicity_ids.size(), 0);
    _settlements.clear(_cell_count.get());
    market_store().clear();
    _market_signals.clear(_cell_count.get());
    _labor_signals.clear(_cell_count.get());
    _trade_plan.clear_transient();
    _trade_active_keys.clear();
    _trade_active_key_present.clear();
    _trade_active_key_idle_cycles.clear();
    _trade_signal_clock_keys.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    trade_orders_store().clear();
    _trade_flows.clear();
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    // BEGIN army personnel lane: a reconfiguration drops every lane.
    _army_personnel.clear();
    // END army personnel lane
    clear_building_groups();
    _building_factor_cache.clear();
    _pending_building_topology_rebuild = false;
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
    _investment_pending_by_cell_type.clear();
    _investment_existing_by_cell_type.clear();
    _investment_prepared_epoch = -1;
    _investment_merchant_cash_by_cell.clear();
    _investment_outstanding_credit_by_cell.clear();
    _investment_employment_cells.clear();
    _investment_review_cell_indices.clear();
    _investment_active_goods_scratch.clear();
    _startup_demand_touched_keys.clear();
    _startup_remote_lanes.clear();
    _startup_remote_groups.clear();
    _startup_inbound_lanes.clear();
    _startup_remote_accumulator_scratch.clear();
    std::string country_error;
    if (!capture_country_epoch(country_error)) {
        out["ok"] = false;
        out["reason"] = country_error.c_str();
        return out;
    }

    const std::vector<int32_t> cells = packed_i32(population_packet, "cell_indices");
    const std::vector<int32_t> signatures = packed_i32(population_packet, "signature_ids");
    const std::vector<int64_t> populations = packed_i64(population_packet, "population");
    const std::vector<int64_t> funds = packed_i64(population_packet, "funds");
    std::vector<int32_t> forced_named_cells = packed_i32(
        population_packet, "forced_named_cells");
    if (cells.size() != signatures.size() || cells.size() != populations.size() ||
        cells.size() != funds.size()) {
        out["ok"] = false;
        out["reason"] = "population_packet_size_mismatch";
        return out;
    }
    std::vector<size_t> bootstrap_order(cells.size());
    std::iota(bootstrap_order.begin(), bootstrap_order.end(), size_t{0});
    std::stable_sort(bootstrap_order.begin(), bootstrap_order.end(), [&](size_t a, size_t b) {
        if (cells[a] != cells[b]) return cells[a] < cells[b];
        if (signatures[a] != signatures[b]) return signatures[a] < signatures[b];
        return a < b;
    });
    for (size_t i : bootstrap_order) {
        if (cells[i] < 0 || cells[i] >= _cell_count.get() || signatures[i] < 0 ||
            signatures[i] >= static_cast<int32_t>(_signatures.size()) || populations[i] < 0 ||
            funds[i] < 0) {
            out["ok"] = false;
            out["reason"] = "population_packet_entry_invalid";
            population_store().clear(_cell_count.get());
            return out;
        }
        if (populations[i] == 0) continue;
        const int32_t slot = population_store().allocate_slot(cells[i], static_cast<uint32_t>(signatures[i]));
        if (slot < 0) {
            out["ok"] = false;
            out["reason"] = "population_page_allocation_failed";
            population_store().clear(_cell_count.get());
            return out;
        }
        population_store().population.write_scalar(slot, saturating_add(population_store().population[slot], populations[i], _saturation_count), market_mutation_sink());
        population_store().funds.write_scalar(slot, saturating_add(population_store().funds[slot], funds[i], _saturation_count), market_mutation_sink());
    }
    std::sort(forced_named_cells.begin(), forced_named_cells.end());
    forced_named_cells.erase(std::unique(
        forced_named_cells.begin(), forced_named_cells.end()),
        forced_named_cells.end());
    for (int32_t cell : forced_named_cells) {
        bool has_population = false;
        for (size_t i = 0; i < cells.size(); ++i) {
            if (cells[i] == cell && populations[i] > 0) {
                has_population = true;
                break;
            }
        }
        if (cell < 0 || cell >= _cell_count.get() || !has_population) {
            out["ok"] = false;
            out["reason"] = "forced_named_cell_invalid";
            population_store().clear(_cell_count.get());
            return out;
        }
    }

    int64_t merchant_repairs = 0;
    std::string merchant_error;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        if (!ensure_merchant_invariant(cell, merchant_repairs, merchant_error)) {
            out["ok"] = false;
            out["reason"] = String(merchant_error.c_str());
            population_store().clear(_cell_count.get());
            return out;
        }
    }
    if (!rebuild_merchant_ranges(merchant_error)) {
        out["ok"] = false;
        out["reason"] = String(merchant_error.c_str());
        return out;
    }

    int32_t market_count = dict_num<int32_t>(market_packet, "market_count", _cell_count.get());
    if (market_count != _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = "market_v2_requires_one_market_per_cell";
        return out;
    }
    market_store().market_count = market_count;
    market_store().price_ceilings.resize(market_count);
    market_store().good_count = static_cast<int32_t>(_good_ids.size());
    const int64_t matrix_size = static_cast<int64_t>(market_count) * market_store().good_count.get();
    if (matrix_size <= 0 || matrix_size > 25000000LL) {
        out["ok"] = false;
        out["reason"] = "market_matrix_capacity_exceeded";
        return out;
    }
    market_store().stock.resize(static_cast<size_t>(matrix_size));
    market_store().price.resize(static_cast<size_t>(matrix_size));
    market_store().demand_ema.assign(static_cast<size_t>(matrix_size), 0);
    market_store().last_shortage_q16.assign(static_cast<size_t>(matrix_size), 0);
    _trade_active_key_present.assign(static_cast<size_t>(matrix_size), 0);
    const size_t investment_good_words =
        (static_cast<size_t>(market_store().good_count.get()) + 63U) / 64U;
    _investment_active_good_words.assign(investment_good_words, 0);
    _investment_active_goods_scratch.clear();
    _startup_demand_values.assign(static_cast<size_t>(matrix_size), 0);
    _startup_demand_stamps.assign(static_cast<size_t>(matrix_size), 0);
    _startup_demand_generation = 0;
    _startup_demand_touched_keys.clear();
    market_store().cell_to_market.resize(_cell_count.get());
    for (int32_t c = 0; c < _cell_count.get(); ++c) market_store().cell_to_market.write_scalar(c, c % market_count, market_mutation_sink());
    for (int32_t m = 0; m < market_count; ++m) {
        for (int32_t g = 0; g < market_store().good_count.get(); ++g) {
            const int64_t idx = market_store().index(m, g);
            audit_touch_market_lane(static_cast<size_t>(idx));
            market_store().stock.write_scalar(idx, 0, market_mutation_sink());
            market_store().price.write_scalar(idx, _good_default_price[g], market_mutation_sink());
        }
    }

    std::vector<int32_t> cell_to_market = packed_i32(market_packet, "cell_to_market");
    if (!cell_to_market.empty()) {
        if (cell_to_market.size() != static_cast<size_t>(_cell_count.get())) {
            out["ok"] = false;
            out["reason"] = "cell_to_market_size_mismatch";
            return out;
        }
        for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
            if (cell_to_market[cell] != cell) {
                out["ok"] = false;
                out["reason"] = "market_v2_requires_identity_cell_mapping";
                return out;
            }
        }
        market_store().cell_to_market.swap(cell_to_market);
    }
    std::vector<int64_t> stock = packed_i64(market_packet, "stock");
    std::vector<int32_t> price = packed_i32(market_packet, "price");
    if (market_packet.has("market_cash")) {
        out["ok"] = false;
        out["reason"] = "market_cash_removed_in_schema_v2";
        return out;
    }
    if (!stock.empty()) {
        if (stock.size() != static_cast<size_t>(matrix_size) ||
            std::any_of(stock.begin(), stock.end(), [](int64_t v) { return v < 0; })) {
            out["ok"] = false;
            out["reason"] = "market_stock_invalid";
            return out;
        }
        market_store().stock.swap(stock);
    }
    if (!price.empty()) {
        if (price.size() != static_cast<size_t>(matrix_size)) {
            out["ok"] = false;
            out["reason"] = "market_price_size_mismatch";
            return out;
        }
        for (int32_t m = 0; m < market_count; ++m) {
            for (int32_t g = 0; g < market_store().good_count.get(); ++g) {
                const int64_t idx = market_store().index(m, g);
                if (price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                    price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                    out["ok"] = false;
                    out["reason"] = "market_price_out_of_range";
                    return out;
                }
            }
        }
        market_store().price.swap(price);
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }

    const std::vector<int32_t> building_cells = packed_i32(market_packet, "building_cells");
    const std::vector<int32_t> building_types = packed_i32(market_packet, "building_type_ids");
    const std::vector<int32_t> building_owners = packed_i32(market_packet, "building_owner_signature_ids");
    const std::vector<int64_t> building_counts = packed_i64(market_packet, "building_counts");
    const std::vector<int64_t> building_owner_fill = packed_i64(market_packet, "building_owner_fill");
    const bool has_owner_fill = market_packet.has("building_owner_fill");
    std::vector<int32_t> founder_cells = packed_i32(
        market_packet, "founder_family_cells");
    std::vector<int32_t> founder_types = packed_i32(
        market_packet, "founder_family_building_type_ids");
    std::vector<int32_t> founder_owners = packed_i32(
        market_packet, "founder_family_owner_signature_ids");
    if (building_cells.size() != building_types.size() ||
        building_cells.size() != building_owners.size() ||
        building_cells.size() != building_counts.size() ||
        (has_owner_fill && building_owner_fill.size() != building_cells.size())) {
        out["ok"] = false;
        out["reason"] = "building_bootstrap_column_size_mismatch";
        return out;
    }
    if (founder_cells.size() != founder_types.size() ||
        founder_cells.size() != founder_owners.size()) {
        out["ok"] = false;
        out["reason"] = "founder_family_bootstrap_column_size_mismatch";
        return out;
    }
    // Native authority also recognizes the formal opening from its persisted
    // invariants. This keeps a long-lived editor that still emits the v2
    // GDScript packet from silently losing founders: forced capital + actual
    // gathering ground is sufficient to derive the same sparse declaration.
    if (founder_cells.empty() && !forced_named_cells.empty()) {
        const auto type_it = std::lower_bound(_building_type_ids.begin(),
            _building_type_ids.end(), std::string("gathering_ground"));
        if (type_it != _building_type_ids.end() &&
            *type_it == "gathering_ground") {
            const int32_t founder_type = static_cast<int32_t>(
                type_it - _building_type_ids.begin());
            for (int32_t cell : forced_named_cells) {
                for (size_t i = 0; i < building_cells.size(); ++i) {
                    if (building_cells[i] != cell ||
                        building_types[i] != founder_type) continue;
                    founder_cells.push_back(cell);
                    founder_types.push_back(founder_type);
                    founder_owners.push_back(building_owners[i]);
                    break;
                }
            }
        }
    }
    if (!founder_cells.empty() &&
        (_family_runtime_mode.get() != 2 || _person_runtime_mode.get() != 2)) {
        out["ok"] = false;
        out["reason"] = _family_runtime_mode.get() != 2
            ? "founder_family_runtime_inactive"
            : "founder_person_runtime_inactive";
        return out;
    }
    for (size_t i = 0; i < building_cells.size(); ++i) {
        if (building_cells[i] < 0 || building_cells[i] >= _cell_count.get() ||
            building_types[i] < 0 || building_types[i] >= static_cast<int32_t>(_building_types.size()) ||
            building_owners[i] < 0 || building_owners[i] >= static_cast<int32_t>(_signatures.size()) ||
            building_counts[i] <= 0 ||
            _signatures[building_owners[i]].profession_id !=
                _building_types[building_types[i]].owner_profession_id) {
            out["ok"] = false;
            out["reason"] = "building_bootstrap_entry_invalid";
            return out;
        }
        const int32_t existing = find_building_group(building_cells[i], building_types[i],
                                                     building_owners[i]);
        if (existing >= 0) {
            buildings_store().group_units.write_scalar(existing, saturating_add(buildings_store().group_units[existing],
                                                        building_counts[i], _saturation_count));
            _building_handle_index_clean = false;
        } else {
            BuildingGroup group;
            group.cell = building_cells[i];
            group.type_id = building_types[i];
            group.owner_signature_id = building_owners[i];
            group.count = building_counts[i];
            append_building_group(group);
        }
    }
    rebuild_building_role_storage();
    refresh_building_modifier_factors();

    // The opening planner owns staffing intent. Apply its explicit allocation
    // before automatic matching: catalog/type ordering must not let a non-food
    // lot consume the same profession reserved for opening food production.
    if (has_owner_fill) {
        std::vector<int64_t> reserved(population_store().population.size(), 0);
        for (size_t i = 0; i < building_cells.size(); ++i) {
            const int64_t fill = building_owner_fill[i];
            const int32_t slot = find_cohort_slot(building_cells[i], building_owners[i]);
            const int64_t capacity = saturating_mul(building_counts[i],
                _building_types[building_types[i]].owner_slots_per_building, _saturation_count);
            if (fill < 0 || fill > capacity || (fill > 0 &&
                (slot < 0 || fill > population_store().population[slot] - reserved[slot]))) {
                out["ok"] = false;
                out["reason"] = "building_bootstrap_owner_fill_invalid";
                return out;
            }
            if (fill > 0) reserved[slot] += fill;
        }
        for (size_t i = 0; i < building_cells.size(); ++i) {
            if (building_owner_fill[i] == 0) continue;
            const int32_t group = find_building_group(
                building_cells[i], building_types[i], building_owners[i]);
            buildings_store().filled_owner.write_scalar(group,
                buildings_store().filled_owner[group] + building_owner_fill[i]);
        }
        for (size_t slot = 0; slot < reserved.size(); ++slot) {
            if (reserved[slot] > 0)
                population_store().owner_employed.write_scalar(slot, reserved[slot], market_mutation_sink());
        }
    }

    int32_t founder_family_count = 0;
    int32_t founder_person_count = 0;
    if (!founder_cells.empty()) {
        std::vector<size_t> founder_order(founder_cells.size());
        std::iota(founder_order.begin(), founder_order.end(), size_t{0});
        std::stable_sort(founder_order.begin(), founder_order.end(),
            [&](size_t a, size_t b) {
                return std::tie(founder_cells[a], founder_types[a],
                                founder_owners[a], a) <
                    std::tie(founder_cells[b], founder_types[b],
                             founder_owners[b], b);
            });
        std::vector<int32_t> founder_family_indices;
        founder_family_indices.reserve(founder_order.size());
        int32_t previous_cell = -1;
        for (size_t packet_index : founder_order) {
            const int32_t cell = founder_cells[packet_index];
            const int32_t type_id = founder_types[packet_index];
            const int32_t owner_signature = founder_owners[packet_index];
            if (cell < 0 || cell >= _cell_count.get() || cell == previous_cell ||
                type_id < 0 ||
                type_id >= static_cast<int32_t>(_building_types.size()) ||
                owner_signature < 0 ||
                owner_signature >= static_cast<int32_t>(_signatures.size()) ||
                _signatures[owner_signature].profession_id !=
                    _building_types[type_id].owner_profession_id) {
                out["ok"] = false;
                out["reason"] = "founder_family_bootstrap_entry_invalid";
                return out;
            }
            previous_cell = cell;
            const int32_t group_index = find_building_group(
                cell, type_id, owner_signature);
            const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
            const int64_t owner_slots =
                _building_types[type_id].owner_slots_per_building;
            if (group_index < 0 || owner_slot < 0 || owner_slots <= 0 ||
                buildings_store().group_units[group_index] <= 0 ||
                buildings_store().modifier_handle[group_index] == 0 ||
                population_store().population[owner_slot] < owner_slots) {
                out["ok"] = false;
                out["reason"] = "founder_family_bootstrap_target_invalid";
                return out;
            }
            buildings_store().filled_owner.write_scalar(group_index, std::max(
                buildings_store().filled_owner[group_index], owner_slots));
            population_store().owner_employed.write_scalar(owner_slot, std::max(
                population_store().owner_employed[owner_slot], owner_slots), market_mutation_sink());
            const int64_t founders = family_household_people_for_slot(
                owner_slot, owner_slots);
            const int32_t family_index = create_family_for_building(
                cell, group_index, founders, owner_slots, true);
            if (family_index < 0) {
                out["ok"] = false;
                out["reason"] = "founder_family_bootstrap_failed";
                return out;
            }
            founder_family_indices.push_back(family_index);
            ++founder_family_count;
        }
        rebuild_family_indices();
        rebuild_person_indices();
        for (int32_t family_index : founder_family_indices) {
            const int64_t before = persons_store().active_count;
            promote_person_for_family(family_index);
            if (persons_store().active_count != before + 1) {
                out["ok"] = false;
                out["reason"] = "founder_person_bootstrap_failed";
                return out;
            }
            ++founder_person_count;
        }
        rebuild_person_indices();
        bind_notable_person_jobs();
        update_person_equity_shares();
    }

    // Opening lots are pre-staffed from their owner-profession cohorts so an
    // installed group produces on its first epoch. Otherwise the proprietors are
    // shed into unemployment before the first employment pass and can only
    // trickle back at the per-period mobility rate, which leaves a bootstrapped
    // settlement idle for several epochs. Each cohort seats its own people once,
    // in building order, so shared owner signatures stay reconciled.
    std::vector<int64_t> bootstrap_owner_available(
        population_store().population.size(), -1);
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_at(pk_row);
        if (group.count <= 0 || group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) {
            continue;
        }
        const int64_t owner_slots = saturating_mul(
            group.count,
            _building_types[group.type_id].owner_slots_per_building,
            _saturation_count);
        if (owner_slots <= group.filled_owner) continue;
        const int32_t owner_slot = find_cohort_slot(
            group.cell, group.owner_signature_id);
        if (owner_slot < 0 || owner_slot >= static_cast<int32_t>(
                bootstrap_owner_available.size())) {
            continue;
        }
        int64_t &available = bootstrap_owner_available[owner_slot];
        if (available < 0) {
            available = std::max<int64_t>(0, saturating_sub(
                population_store().population[owner_slot],
                std::max<int64_t>(0,
                    population_store().owner_employed[owner_slot]),
                _saturation_count));
        }
        const int64_t fill = std::min(
            owner_slots - group.filled_owner, available);
        if (fill <= 0) continue;
        group.filled_owner = saturating_add(
            group.filled_owner, fill, _saturation_count);
        available -= fill;
        population_store().owner_employed.write_scalar(owner_slot, saturating_add(
            population_store().owner_employed[owner_slot], fill,
            _saturation_count), market_mutation_sink());
    }

    if (_configured_target_cohorts_per_slice == 0) {
        _target_cohorts_per_slice = population_store().active_count <= 500000 ? 4000
            : (population_store().active_count <= 2000000 ? 12000 : 30000);
    }
    if (_auto_slice_by_scale) {
        _cells_per_slice = std::clamp(market_store().market_count.get(), 1, 128);
    }
    if (_auto_building_slice_by_scale)
        _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    _epoch_days = choose_epoch_days(population_store().active_count);
    _commit_lag_budget_days = std::max(0, locked_market_cycle_days() - 1);
    _last_committed_day = -1;
    _cell_last_settlement_day.resize(_cell_count.get());
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
    const int32_t n = locked_market_cycle_days();
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        _cell_last_settlement_day.write_scalar(cell, static_cast<int64_t>(((cell % n) + n) % n) - n, market_mutation_sink());
    }
    _settlement_watermark = -n;
    _settlement_newest_day = -1;
    _settlement_max_age_days = n - 1;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _epoch_id = 0;
    _bootstrapped = true;
    _fatal = false;
    _fatal_reason.clear();
    rebuild_committed_summaries();
    initialize_settlements_from_population();
    for (int32_t cell : forced_named_cells) {
        _settlements.name_forced.write_scalar(cell, 1, market_mutation_sink());
        assign_settlement_name(cell);
    }
    if (founder_family_count > 0)
        rebuild_family_influences();
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    rebuild_incremental_audit_shadow();
    _closing_audit_force_full = true;
    if (_worker_enabled && population_store().active_count >= _worker_market_threshold &&
        parallel_has_real_worker_threads()) {
        const int warm_tasks = _worker_tasks_hint > 0 ? _worker_tasks_hint : 16;
        auto warm_worker = [](int32_t begin, int32_t end) {
            volatile uint32_t local = 0;
            for (int32_t i = begin; i < end; ++i) local ^= static_cast<uint32_t>(i);
            (void)local;
        };
        parallel_for_range("pk_economy_warmup", 1024, warm_tasks, 1, warm_worker);
    }
    out["ok"] = true;
    out["cohort_count"] = population_store().active_count.get();
    out["market_count"] = market_store().market_count.get();
    out["good_count"] = market_store().good_count.get();
    write_cadence_report(out);
    out["markets_per_slice"] = _cells_per_slice;
    out["building_cells_per_slice"] = _building_cells_per_slice;
    out["building_output_efficiency_q16"] = _building_output_efficiency_q16;
    out["founder_family_count"] = founder_family_count;
    out["founder_person_count"] = founder_person_count;
    out["economy_high_speed_batching_enabled"] =
        _high_speed_batching_enabled;
    out["market_target_cohorts_per_slice"] = _target_cohorts_per_slice;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
    out["workload_deadline_feasible"] = _workload_deadline_feasible;
    out["workload_cycle_clamped"] = _workload_cycle_clamped;
    out["approximation_model"] =
        "rolling_cell_settlement_v19_class_good_elasticity";
    out["economy_accuracy_preset"] = _accuracy_preset == 0 ? "EXACT" :
        (_accuracy_preset == 1 ? "BALANCED" :
        (_accuracy_preset == 2 ? "FAST" : "CUSTOM"));
    out["economy_approximation_runtime_mode"] =
        _approximation_runtime_mode == 0 ? "OFF" :
        (_approximation_runtime_mode == 1 ? "PROBE" : "ACTIVE");
    // Retained for report compatibility. Household workers are safe on large
    // ACTIVE worlds now that result and staging-touch sinks are thread-local.
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
    out["accuracy_exact_probe_rate_q16"] = _accuracy_exact_probe_rate_q16;
    out["accuracy_fallback_cooldown_epochs"] =
        _accuracy_fallback_cooldown_epochs;
    out["employment_mobility_daily_q16"] = _employment_mobility_daily_q16.get();
    out["employment_understaffed_reallocation_hurdle_mult_q16"] =
        _employment_understaffed_reallocation_hurdle_mult_q16.get();
    out["employment_choice_temperature_q16"] =
        _employment_choice_temperature_q16.get();
    out["merchant_count"] = static_cast<int64_t>(_merchant_slots.size());
    out["merchant_repairs"] = merchant_repairs;
    out["building_group_count"] = static_cast<int64_t>(building_count());
    out["family_runtime_mode"] = _family_runtime_mode.get() == 0 ? "OFF" :
        (_family_runtime_mode.get() == 1 ? "PROBE" : "ACTIVE");
    out["family_count"] = families_store().active_count.get();
    out["family_membership_edge_count"] = static_cast<int64_t>(
        family_memberships().size());
    out["family_ownership_edge_count"] = static_cast<int64_t>(
        family_ownerships().size());
    out["family_trait_roll_count"] = static_cast<int64_t>(
        family_trait_rolls().size());
    out["family_branch_count"] = static_cast<int64_t>(std::count(
        family_influences().active.begin(), family_influences().active.end(),
        uint8_t{1}));
    out["family_modifier_binding_count"] = static_cast<int64_t>(
        _family_modifier_bindings.size());
    out["family_effect_binding_count"] = static_cast<int64_t>(
        _family_effect_bindings.size());
    out["family_owned_output_row_count"] = static_cast<int64_t>(
        _family_owned_output_rows.size());
    out["family_industry_stat_count"] = static_cast<int64_t>(
        _family_industry_stats.size());
    out["family_trigger_binding_count"] = static_cast<int64_t>(
        _family_trigger_bindings.size());
    out["family_membership_edges_processed"] =
        _family_membership_edges_processed;
    out["family_ownership_edges_processed"] =
        _family_ownership_edges_processed;
    out["families_formed"] = _families_formed;
    out["family_offers_opened"] = _family_offers_opened;
    out["family_offers_auto_resolved"] = _family_offers_auto_resolved;
    out["family_offer_choice_rejected"] = _family_offer_choice_rejected;
    out["family_offers_voided"] = _family_offers_voided;
    out["family_offers_pending"] = static_cast<int64_t>(_family_founding_offers.size());
    out["families_dissolved"] = _families_dissolved;
    out["family_owner_jobs_filled"] = _family_owner_jobs_filled;
    out["family_owner_jobs_vacant"] = _family_owner_jobs_vacant;
    out["family_births_attributed"] = _family_births_attributed;
    out["family_deaths_attributed"] = _family_deaths_attributed;
    out["family_reconcile_corrections"] = _family_reconcile_corrections;
    out["family_ledger_clamps"] = _family_ledger_clamps;
    out["family_people_recruited"] = _family_people_recruited;
    out["family_units_released"] = _family_units_released;
    out["family_release_deferred"] = _family_release_deferred;
    out["family_owner_seats_guarded"] = _family_owner_seats_guarded;
    out["family_demography_rows"] = static_cast<int64_t>(_family_demography_rows.size());
    out["family_demography_weights_ms"] = _family_demography_weights_ms;
    out["notable_person_runtime_mode"] = _person_runtime_mode.get() == 0 ? "OFF" :
        (_person_runtime_mode.get() == 1 ? "PROBE" : "ACTIVE");
    out["notable_person_count"] = persons_store().active_count.get();
    out["person_need_edge_count"] = static_cast<int64_t>(person_needs().size());
    out["persons_promoted"] = _persons_promoted;
    out["persons_died"] = _persons_died;
    out["persons_migrated"] = _persons_migrated;
    out["person_jobs_bound"] = _person_jobs_bound;
    out["person_need_edges_processed"] = _person_need_edges_processed;
    out["memory_bytes"] = memory_bytes();
    return out;
}

} // namespace pk
