#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_persistence_codec.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace persistence_codec;

Dictionary NativeEconomyRuntime::begin_save(int32_t chunk_bytes) {
    Dictionary out;
    if (!_bootstrapped || _epoch_active || _fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                         : (_epoch_active ? "save_requires_committed_boundary"
                         : (_fatal ? "economy_fatal" : "save_restore_already_active"));
        return out;
    }
    if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
        _country_runtime->should_run(_last_committed_day)) {
        out["ok"] = false;
        out["reason"] = "save_requires_idle_country_runtime";
        return out;
    }
    const size_t cells = static_cast<size_t>(_cell_count);
    if (_market.cell_to_market.size() != cells ||
        _environment_temperature_q16.size() != cells ||
        _environment_temperature_30d_q16.size() != cells ||
        _environment_moisture_q16.size() != cells ||
        _environment_plant_available_water_q16.size() != cells ||
        _environment_snow_q16.size() != cells ||
        _environment_weather_q16.size() != cells ||
        _cell_last_settlement_day.size() != cells ||
        _birth_residual_q32.size() != cells * _ethnicity_ids.size() ||
        _cell_settlement_generation.size() != cells ||
        _cell_price_stock_gen.size() != cells ||
        _cell_owner_cash_gen.size() != cells ||
        _cell_population_gen.size() != cells ||
        _cell_building_structure_gen.size() != cells ||
        _cell_technology_gen.size() != cells ||
        _cell_resource_gen.size() != cells ||
        _cell_trade_gen.size() != cells) {
        out["ok"] = false;
        out["reason"] = "economy_save_state_shape_invalid";
        return out;
    }
    // A capture must not serialize need rows whose person was already retired,
    // because restore would prune them and change the row count.
    compact_person_needs();
    _save = {};
    _save.active = true;
    _save.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    std::string modifier_error;
    if (_modifier_runtime != nullptr &&
        !_modifier_runtime->serialize_domain(ModifierRuntime::ECONOMY,
                                              _save.modifier_bytes,
                                              modifier_error)) {
        _save = {};
        out["ok"] = false;
        out["reason"] = String(modifier_error.c_str());
        return out;
    }
    out["ok"] = true;
    out["chunk_bytes"] = _save.chunk_bytes;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash;
    out["committed_day"] = _last_committed_day;
    return out;
}

Dictionary NativeEconomyRuntime::end_save() {
    Dictionary out;
    if (!_save.active) {
        out["ok"] = false;
        out["reason"] = "save_not_active";
        return out;
    }
    if (!_save.end_emitted) {
        out["ok"] = false;
        out["reason"] = "save_stream_not_fully_read";
        return out;
    }
    _save = {};
    out["ok"] = true;
    return out;
}

Dictionary NativeEconomyRuntime::begin_restore() {
    Dictionary out;
    if (!_configured || _epoch_active || _save.active || _restore.active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "configure_catalog_before_restore"
                         : (_epoch_active ? "restore_requires_committed_boundary"
                                          : "save_restore_already_active");
        return out;
    }
    _restore = {};
    _restore.active = true;
    _bootstrapped = false;
    _population.clear(_cell_count);
    _birth_residual_q32.assign(
        static_cast<size_t>(_cell_count) * _ethnicity_ids.size(), 0);
    _settlements.clear(_cell_count);
    _market.clear();
    _market_signals.clear(_cell_count);
    _labor_signals.clear(_cell_count);
    _trade_plan.clear_transient();
    _trade_signal_clock_keys.clear();
    _trade_signal_bulk_keys_scratch.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    _trade_orders.clear();
    _trade_flows.clear();
    _pending_commands.clear();
    _epoch_commands.clear();
    _structural_commands.clear();
    _buildings.clear();
    _building_handle_index_clean = false;
    _building_groups_rebuild_scratch.clear();
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
    _pending_construction.clear();
    _committed_cells.assign(_cell_count, {});
    _cell_last_settlement_day.assign(_cell_count, -ROLLING_PHASE_COUNT);
    _cell_settlement_generation.assign(_cell_count, 0);
    _cell_price_stock_gen.assign(_cell_count, 0);
    _cell_owner_cash_gen.assign(_cell_count, 0);
    _cell_population_gen.assign(_cell_count, 0);
    _cell_building_structure_gen.assign(_cell_count, 0);
    _cell_technology_gen.assign(_cell_count, 0);
    _cell_resource_gen.assign(_cell_count, 0);
    _cell_trade_gen.assign(_cell_count, 0);
    _fiscal_previous_country_handles.assign(
        static_cast<size_t>(_cell_count), 0);
    _fiscal_previous_requests.assign(
        static_cast<size_t>(_cell_count) * ACTIVE_TAX_KIND_COUNT, 0);
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    return out;
}

Dictionary NativeEconomyRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    Dictionary out;
    if (!_restore.active || _restore.failed || _restore.end_seen || chunk.is_empty()) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                                            : (_restore.end_seen ? "restore_end_already_seen"
                                                                 : "restore_chunk_empty"));
        return out;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(chunk.size()));
    std::memcpy(bytes.data(), chunk.ptr(), bytes.size());
    std::string error;
    if (!decode_restore_chunk(bytes, error)) {
        _restore.failed = true;
        _restore.error = error;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    out["ok"] = true;
    out["header_seen"] = _restore.header_seen;
    out["end_seen"] = _restore.end_seen;
    out["restored_pages"] = _restore.restored_pages;
    out["restored_markets"] = _restore.restored_markets;
    out["restored_cells"] = _restore.restored_cells;
    out["restored_commands"] = _restore.restored_commands;
    out["restored_audits"] = _restore.restored_audits;
    out["restored_signals"] = _restore.restored_signals;
    out["restored_labor_signals"] = _restore.restored_labor_signals;
    out["restored_trade_orders"] = _restore.restored_trade_orders;
    out["restored_trade_flows"] = _restore.restored_trade_flows;
    out["restored_persons"] = _restore.restored_persons;
    out["restored_person_needs"] = _restore.restored_person_needs;
    return out;
}

Dictionary NativeEconomyRuntime::end_restore() {
    Dictionary out;
    if (!_restore.active || _restore.failed || !_restore.header_seen || !_restore.end_seen) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                         : (!_restore.header_seen ? "restore_header_missing" : "restore_end_missing"));
        return out;
    }
    if (_restore.restored_pages != _restore.expected_pages ||
        _restore.restored_markets != _market.market_count ||
        _restore.restored_cells != _cell_count ||
        _restore.restored_commands != _restore.expected_commands ||
        _restore.restored_buildings != _restore.expected_buildings ||
        _restore.restored_construction != _restore.expected_construction ||
        _restore.restored_audits != _restore.expected_audits ||
        _restore.restored_signals != _restore.expected_signals ||
        _restore.restored_labor_signals != _restore.expected_labor_signals ||
        _restore.restored_trade_orders != _restore.expected_trade_orders ||
        _restore.restored_trade_flows != _restore.expected_trade_flows ||
        (_restore.schema_version >= 20 && !_restore.modifier_seen) ||
        (_restore.schema_version >= 23 && !_restore.fiscal_seen) ||
        (_restore.schema_version >= 24 &&
         !_restore.settlement_names_seen) ||
        (_restore.schema_version >= 26 &&
         (!_restore.family_records_seen || !_restore.family_membership_seen ||
          !_restore.family_ownership_seen)) ||
        (_restore.schema_version >= 27 &&
         (!_restore.person_records_seen || !_restore.person_needs_seen ||
           _restore.restored_persons != _restore.expected_persons ||
           _restore.restored_person_needs !=
               _restore.expected_person_needs)) ||
        (_restore.schema_version >= 29 &&
         (!_restore.family_traits_seen || !_restore.family_influences_seen ||
          !_restore.family_trait_commands_seen ||
          _restore.restored_family_traits !=
              _restore.expected_family_traits ||
          _restore.restored_family_influences !=
              _restore.expected_family_influences ||
          _restore.restored_family_trait_commands !=
              _restore.expected_family_trait_commands))) {
        out["ok"] = false;
        out["reason"] = "restore_section_incomplete";
        return out;
    }
    uint64_t restored_environment_hash = 1469598103934665603ULL;
    auto mix_environment_q16 = [&](uint32_t value) {
        for (int32_t byte = 0; byte < 4; ++byte) {
            restored_environment_hash ^= static_cast<uint8_t>(
                (value >> (byte * 8)) & 0xffU);
            restored_environment_hash *= 1099511628211ULL;
        }
    };
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t values[] = {
            _environment_temperature_q16[cell],
            _environment_temperature_30d_q16[cell],
            _environment_moisture_q16[cell],
            _environment_plant_available_water_q16[cell],
            _environment_snow_q16[cell],
            _environment_weather_q16[cell],
        };
        for (int32_t value : values) {
            if (value < 0 || value > Q16_ONE) {
                out["ok"] = false;
                out["reason"] = "restore_environment_value_invalid";
                return out;
            }
            mix_environment_q16(static_cast<uint32_t>(value));
        }
    }
    const int64_t computed_environment_hash = static_cast<int64_t>(
        (restored_environment_hash & 0x7fffffffffffffffULL) | 1ULL);
    if (computed_environment_hash != _environment_hash) {
        out["ok"] = false;
        out["reason"] = "restore_environment_hash_mismatch";
        out["expected_environment_hash"] = _environment_hash;
        out["computed_environment_hash"] = computed_environment_hash;
        return out;
    }
    std::vector<uint8_t> referenced(_population.page_next.size(), 0);
    int64_t actual_active = 0;
    for (int32_t page = 0; page < static_cast<int32_t>(_population.page_next.size()); ++page) {
        const int32_t cell = _population.page_cell[page];
        const int32_t next = _population.page_next[page];
        if (cell < -1 || cell >= _cell_count || next < -1 ||
            next >= static_cast<int32_t>(_population.page_next.size()) ||
            (next >= 0 && _population.page_cell[next] != cell)) {
            out["ok"] = false;
            out["reason"] = "restore_page_chain_invalid";
            return out;
        }
        if (next >= 0) referenced[next] = 1;
        if (cell < 0) _population.free_pages.push_back(page);
        const int32_t base = page * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (_population.active[slot] == 0) continue;
            if (cell < 0 || _population.signature_id[slot] >= _signatures.size() ||
                _population.generation[slot] == 0 || _population.population[slot] <= 0 ||
                _population.funds[slot] < 0) {
                out["ok"] = false;
                out["reason"] = "restore_cohort_record_invalid";
                return out;
            }
            ++actual_active;
        }
    }
    _population.cell_first_page.assign(_cell_count, -1);
    for (int32_t page = 0; page < static_cast<int32_t>(_population.page_next.size()); ++page) {
        const int32_t cell = _population.page_cell[page];
        if (cell < 0 || referenced[page] != 0) continue;
        if (_population.cell_first_page[cell] >= 0) {
            out["ok"] = false;
            out["reason"] = "restore_multiple_page_chain_heads";
            return out;
        }
        _population.cell_first_page[cell] = page;
    }
    std::vector<uint8_t> visited(_population.page_next.size(), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        int32_t steps = 0;
        for (int32_t page = _population.cell_first_page[cell]; page >= 0;
             page = _population.page_next[page]) {
            if (++steps > static_cast<int32_t>(_population.page_next.size()) || visited[page] != 0) {
                out["ok"] = false;
                out["reason"] = "restore_page_chain_cycle";
                return out;
            }
            visited[page] = 1;
        }
    }
    for (int32_t page = 0; page < static_cast<int32_t>(_population.page_next.size()); ++page) {
        if (_population.page_cell[page] >= 0 && visited[page] == 0) {
            out["ok"] = false;
            out["reason"] = "restore_unreachable_page";
            return out;
        }
    }
    if (actual_active != _population.active_count) {
        out["ok"] = false;
        out["reason"] = "restore_active_count_mismatch";
        return out;
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_market.cell_to_market[cell] < 0 || _market.cell_to_market[cell] >= _market.market_count) {
            out["ok"] = false;
            out["reason"] = "restore_cell_market_invalid";
            return out;
        }
        std::vector<uint32_t> signatures;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            signatures.push_back(_population.signature_id[slot]);
        });
        std::sort(signatures.begin(), signatures.end());
        if (std::adjacent_find(signatures.begin(), signatures.end()) != signatures.end()) {
            out["ok"] = false;
            out["reason"] = "restore_duplicate_cell_signature";
            return out;
        }
    }
    for (int32_t market = 0; market < _market.market_count; ++market) {
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            if (_market.stock[idx] < 0 || _market.demand_ema[idx] < 0 ||
                _market.price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                _market.price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                out["ok"] = false;
                out["reason"] = "restore_market_value_invalid";
                return out;
            }
        }
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    int64_t restore_merchant_repairs = 0;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (!ensure_merchant_invariant(cell, restore_merchant_repairs, market_range_error)) {
            out["ok"] = false;
            out["reason"] = String(market_range_error.c_str());
            return out;
        }
    }
    if (!rebuild_merchant_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    for (const Command &cmd : _pending_commands) {
        int32_t slot = -1;
        const bool market_target = cmd.opcode == COMMAND_ADD_STOCK ||
            cmd.opcode == COMMAND_REMOVE_STOCK ||
            cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
            cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY;
        const bool family_reward =
            cmd.opcode == COMMAND_FAMILY_FREE_BUILDING ||
            cmd.opcode == COMMAND_FAMILY_POPULATION_REWARD;
        int32_t branch = -1;
        const bool target_ok = family_reward
            ? (_family_influences.valid_handle(cmd.target_handle, branch) &&
               cmd.i32_0 >= 0 && cmd.i32_0 <= 1 && cmd.i64_0 > 0 &&
               (cmd.opcode != COMMAND_FAMILY_FREE_BUILDING ||
                (cmd.i32_1 >= 0 && cmd.i32_1 < static_cast<int32_t>(
                    _building_types.size()))))
            : market_target
            ? (cmd.i32_0 >= 0 && cmd.i32_0 < _market.market_count &&
               cmd.i32_1 >= 0 && cmd.i32_1 < _market.good_count &&
               ((cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                 cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY) ||
                (_country_runtime != nullptr && _country_runtime->valid_handle(
                    static_cast<int64_t>(cmd.target_handle)))))
            : _population.valid_handle(cmd.target_handle, slot);
        if (cmd.opcode < COMMAND_TRANSFER_TO_COHORT ||
            cmd.opcode > COMMAND_FAMILY_POPULATION_REWARD ||
            !target_ok || cmd.effective_day < 0 || cmd.sequence < 0 ||
            (cmd.i64_0 < 0 && cmd.opcode != COMMAND_ADD_POPULATION)) {
            out["ok"] = false;
            out["reason"] = "restore_command_invalid";
            return out;
        }
    }
    for (const BuildingGroup &group : _buildings) {
        if (_signatures[group.owner_signature_id].profession_id !=
                _building_types[group.type_id].owner_profession_id ||
            group.filled_owner < 0 || group.filled_owner >
                group.count * _building_types[group.type_id].owner_slots_per_building ||
            group.last_input_cost < 0 || group.last_wages_paid < 0 ||
            group.last_wages_due < 0 || group.last_expected_revenue < 0 ||
            group.last_operating_cost < 0 || group.planned_utilization_q16 < 0 ||
            group.planned_utilization_q16 > Q16_ONE ||
            group.last_resource_generated < 0 ||
            group.last_base_wages_paid < 0 || group.last_base_wages_due < 0 ||
            group.last_bonus_paid < 0 || group.last_bonus_due < 0 ||
            group.last_base_wages_paid > group.last_base_wages_due ||
            group.last_bonus_paid > group.last_bonus_due ||
            group.wage_suspended > 1 || group.operating_state > 2 ||
            (group.pending_operating_state > 2 && group.pending_operating_state != 255) ||
            group.merchant_debt_principal < 0 || group.merchant_debt_premium < 0 ||
            group.last_in_kind_livelihood_value < 0 ||
            group.last_temperature_fit_q16 < 0 ||
            group.last_temperature_fit_q16 > Q16_ONE ||
            group.last_water_fit_q16 < 0 ||
            group.last_water_fit_q16 > Q16_ONE ||
            group.last_climate_capacity_q16 < 0 ||
            group.last_climate_capacity_q16 > Q16_ONE ||
            group.last_climate_lost_output < 0 ||
            ((group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) &&
             group.merchant_debt_term_cycles_left == 0 &&
             group.merchant_debt_delinquent_cycles == 0) ||
            group.purchase_intent_capacity_q16 < 0 ||
            group.purchase_intent_capacity_q16 > Q16_ONE) {
            out["ok"] = false;
            out["reason"] = "restore_building_owner_or_job_invalid";
            return out;
        }
        const BuildingType &type = _building_types[group.type_id];
        if (group.last_input_selection_begin < 0 ||
            static_cast<size_t>(group.last_input_selection_begin) +
                    static_cast<size_t>(type.input_count) >
                _building_last_input_selected_goods.size()) {
            out["ok"] = false;
            out["reason"] = "restore_building_input_selection_span_invalid";
            return out;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            if (role_index < 0 ||
                role_index >= static_cast<int32_t>(_building_role_contract_wage.size()) ||
                _building_role_contract_wage[role_index] < 0 ||
                _building_role_base_living_cost[role_index] < 0 ||
                _building_role_living_cost[role_index] < 0 ||
                _building_role_local_average_wage[role_index] < 0 ||
                _building_role_base_wage_paid[role_index] < 0 ||
                _building_role_base_wage_due[role_index] <
                    _building_role_base_wage_paid[role_index] ||
                _building_role_bonus_paid[role_index] < 0 ||
                _building_role_bonus_due[role_index] <
                    _building_role_bonus_paid[role_index]) {
                out["ok"] = false;
                out["reason"] = "restore_building_role_wage_invalid";
                return out;
            }
            const int64_t filled = _building_employee_filled[role_index];
            const int64_t required = group.count *
                _building_employee_roles[type.employee_begin + r].slots_per_building;
            if (filled < 0 || filled > required) {
                out["ok"] = false;
                out["reason"] = "restore_building_employee_job_invalid";
                return out;
            }
        }
    }
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        if (_population.active[slot] == 0) continue;
        if (_population.owner_employed[slot] < 0 || _population.employee_employed[slot] < 0 ||
            _population.owner_employed[slot] + _population.employee_employed[slot] >
                _population.population[slot]) {
            out["ok"] = false;
            out["reason"] = "restore_cohort_employment_invalid";
            return out;
        }
    }
    rebuild_building_cell_offsets();
    if (_auto_slice_by_scale)
        _cells_per_slice = std::clamp(_market.market_count, 1, 128);
    if (_auto_building_slice_by_scale)
        _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    choose_epoch_days(_population.active_count);
    _epoch_days = ROLLING_PHASE_COUNT;
    _commit_lag_budget_days = ROLLING_PHASE_COUNT - 1;
    if (_restore.schema_version < 15) {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            const int64_t phase = cell % ROLLING_PHASE_COUNT;
            const int64_t delta = ((_last_committed_day - phase) %
                ROLLING_PHASE_COUNT + ROLLING_PHASE_COUNT) %
                ROLLING_PHASE_COUNT;
            _cell_last_settlement_day[cell] = _last_committed_day - delta;
        }
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _market_signals.cell_offsets[cell + 1] += _market_signals.cell_offsets[cell];
    rebuild_market_signals();
    {
        int64_t investment_mask_saturation = 0;
        for (int32_t market = 0; market < _market.market_count; ++market)
            refresh_investment_active_goods_for_market(
                market, investment_mask_saturation);
        if (investment_mask_saturation > 0) {
            out["ok"] = false;
            out["reason"] = "restore_investment_active_mask_saturated";
            return out;
        }
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _labor_signals.cell_offsets[cell + 1] += _labor_signals.cell_offsets[cell];
    rebuild_labor_signals();
    std::string country_restore_error;
    if (!capture_country_epoch(country_restore_error)) {
        out["ok"] = false;
        out["reason"] = country_restore_error.c_str();
        return out;
    }
    if ((!_trade_orders.ids.empty() &&
         _trade_orders.next_id <= _trade_orders.ids.back()) ||
        _trade_orders.line_offsets.size() != _trade_orders.ids.size() + 1 ||
        _trade_orders.seller_offsets.size() != _trade_orders.ids.size() + 1) {
        out["ok"] = false;
        out["reason"] = "restore_trade_order_index_invalid";
        return out;
    }
    if (_restore.schema_version >= 20 && !_restore.modifier_bytes.empty()) {
        if (_modifier_runtime == nullptr) {
            out["ok"] = false;
            out["reason"] = "economy_restore_modifier_runtime_unavailable";
            return out;
        }
        std::string modifier_restore_error;
        if (!_modifier_runtime->restore_domain(ModifierRuntime::ECONOMY,
                                               _restore.modifier_bytes,
                                               modifier_restore_error,
                                               _restore.schema_version == 22)) {
            out["ok"] = false;
            out["reason"] = String(("economy_restore_modifier_failed:" +
                                    modifier_restore_error).c_str());
            return out;
        }
    } else if (_modifier_runtime != nullptr) {
        _modifier_runtime->clear_domain(ModifierRuntime::ECONOMY);
    }
    if (_modifier_runtime != nullptr) refresh_building_modifier_factors();
    {
        std::unordered_set<int64_t> stable_family_ids;
        std::unordered_set<uint64_t> visible_family_names;
        for (int32_t i = 0; i < static_cast<int32_t>(_families.active.size()); ++i) {
            if (_families.active[i] == 0) continue;
            const uint64_t visible_key =
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    _families.surname_id[i])) << 32) |
                _families.surname_disambiguator[i];
            if (!stable_family_ids.insert(_families.stable_id[i]).second ||
                !visible_family_names.insert(visible_key).second) {
                out["ok"] = false;
                out["reason"] = "restore_family_identity_duplicate";
                return out;
            }
        }
        std::vector<int64_t> member_people(_population.active.size(), 0);
        std::vector<int64_t> member_cash(_population.active.size(), 0);
        for (const FamilyMembershipEdge &edge : _family_memberships) {
            int32_t slot = -1;
            if (!_population.valid_handle(edge.cohort_handle, slot)) {
                out["ok"] = false;
                out["reason"] = "restore_family_cohort_handle_invalid";
                return out;
            }
            if (edge.people > _population.population[slot] -
                    member_people[slot] ||
                edge.cash_claim > _population.funds[slot] -
                    member_cash[slot]) {
                out["ok"] = false;
                out["reason"] = "restore_family_claim_exceeds_cohort";
                return out;
            }
            member_people[slot] += edge.people;
            member_cash[slot] += edge.cash_claim;
        }
        std::vector<int64_t> owned(_buildings.size(), 0);
        for (const FamilyBuildingOwnership &edge : _family_ownerships) {
            const int32_t group = building_index_for_handle(edge.building_handle);
            if (group < 0) {
                out["ok"] = false;
                out["reason"] = "restore_family_building_handle_invalid";
                return out;
            }
            if (edge.owned_count > _buildings[group].count - owned[group]) {
                out["ok"] = false;
                out["reason"] = "restore_family_ownership_exceeds_building";
                return out;
            }
            owned[group] += edge.owned_count;
            int64_t capacity_sat = 0;
            const int64_t owner_capacity = saturating_mul(edge.owned_count,
                _building_types[_buildings[group].type_id].owner_slots_per_building,
                capacity_sat);
            if (capacity_sat != 0 ||
                edge.filled_owner > owner_capacity) {
                out["ok"] = false;
                out["reason"] = "restore_family_ownership_exceeds_building";
                return out;
            }
        }
        for (const PendingConstruction &pending : _pending_construction) {
            int32_t family = -1;
            if (pending.sponsor_family_handle != 0 &&
                !_families.valid_handle(pending.sponsor_family_handle, family)) {
                out["ok"] = false;
                out["reason"] = "restore_construction_family_handle_invalid";
                return out;
            }
        }
        std::unordered_map<uint64_t, std::unordered_set<int32_t>> traits_by_family;
        std::unordered_map<uint64_t, int32_t> core_traits_by_family;
        uint64_t previous_trait_family = 0;
        int32_t previous_trait = -1;
        bool first_trait = true;
        for (const FamilyTraitRoll &roll : _family_traits) {
            if (!first_trait &&
                (roll.family_handle < previous_trait_family ||
                 (roll.family_handle == previous_trait_family &&
                  roll.trait_id <= previous_trait))) {
                out["ok"] = false;
                out["reason"] = "restore_family_trait_order_or_duplicate_invalid";
                return out;
            }
            first_trait = false;
            previous_trait_family = roll.family_handle;
            previous_trait = roll.trait_id;
            traits_by_family[roll.family_handle].insert(roll.trait_id);
            if (roll.core != 0) {
                if (_family_trait_core_eligible[roll.trait_id] == 0) {
                    out["ok"] = false;
                    out["reason"] = "restore_family_core_trait_ineligible";
                    return out;
                }
                ++core_traits_by_family[roll.family_handle];
            }
        }
        for (int32_t family = 0; family < static_cast<int32_t>(
                 _families.active.size()); ++family) {
            if (_families.active[family] == 0) continue;
            const uint64_t family_handle = _families.handle_for_index(family);
            const int32_t core_count = core_traits_by_family[family_handle];
            if (core_count < _family_core_trait_min ||
                core_count > _family_core_trait_max) {
                out["ok"] = false;
                out["reason"] = "restore_family_core_trait_count_invalid";
                return out;
            }
            const auto found_traits = traits_by_family.find(family_handle);
            if (found_traits == traits_by_family.end()) continue;
            const std::unordered_set<int32_t> &family_traits =
                found_traits->second;
            for (int32_t trait_id : family_traits) {
                for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                     p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p) {
                    if (family_traits.find(_family_trait_prerequisites[p]) ==
                            family_traits.end()) {
                        out["ok"] = false;
                        out["reason"] =
                            "restore_family_trait_prerequisite_missing";
                        return out;
                    }
                }
                for (int32_t p = _family_trait_exclusion_offsets[trait_id];
                     p < _family_trait_exclusion_offsets[trait_id + 1]; ++p) {
                    if (family_traits.find(_family_trait_exclusions[p]) !=
                            family_traits.end()) {
                        out["ok"] = false;
                        out["reason"] = "restore_family_trait_conflict";
                        return out;
                    }
                }
            }
        }
        std::unordered_set<uint64_t> family_cells;
        std::unordered_set<int64_t> branch_stable_ids;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                 _family_influences.active.size()); ++branch) {
            if (_family_influences.active[branch] == 0) continue;
            int32_t family = -1;
            if (!_families.valid_handle(
                    _family_influences.family_handle[branch], family)) {
                out["ok"] = false;
                out["reason"] = "restore_family_influence_family_invalid";
                return out;
            }
            const uint64_t family_cell =
                (static_cast<uint64_t>(static_cast<uint32_t>(family)) << 32) |
                static_cast<uint32_t>(_family_influences.cell[branch]);
            uint64_t expected_hash = 1469598103934665603ULL;
            expected_hash = trace_hash_mix(expected_hash, static_cast<uint64_t>(
                _families.stable_id[family]));
            expected_hash = trace_hash_mix(expected_hash, static_cast<uint32_t>(
                _family_influences.cell[branch]));
            const int64_t expected_stable_id = static_cast<int64_t>(
                (expected_hash & 0x7fffffffffffffffULL) | 1ULL);
            if (!family_cells.insert(family_cell).second ||
                !branch_stable_ids.insert(
                    _family_influences.stable_id[branch]).second ||
                _family_influences.stable_id[branch] != expected_stable_id) {
                out["ok"] = false;
                out["reason"] =
                    "restore_family_influence_identity_duplicate_or_invalid";
                return out;
            }
        }
    }
    if (_restore.schema_version >= 27) {
        std::unordered_set<int64_t> stable_person_ids;
        std::unordered_set<std::string> visible_person_names;
        std::vector<int64_t> claimed_by_membership(
            _family_memberships.size(), 0);
        std::vector<int64_t> people_by_membership(
            _family_memberships.size(), 0);
        for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i) {
            if (_persons.active[i] == 0) continue;
            int32_t family = -1, cohort = -1;
            const int32_t membership = family_membership_index(
                _persons.family_handle[i], _persons.cohort_handle[i]);
            if (!_families.valid_handle(_persons.family_handle[i], family) ||
                !_population.valid_handle(_persons.cohort_handle[i], cohort) ||
                membership < 0 ||
                !stable_person_ids.insert(_persons.stable_id[i]).second) {
                out["ok"] = false;
                out["reason"] = "restore_person_identity_or_membership_invalid";
                return out;
            }
            const std::string family_name_key =
                std::to_string(_persons.family_handle[i]) + ":" +
                std::to_string(_persons.given_name_id[i]) + ":" +
                std::to_string(_persons.name_disambiguator[i]);
            if (!visible_person_names.insert(family_name_key).second ||
                _persons.cash_claim[i] >
                    _family_memberships[membership].cash_claim -
                    claimed_by_membership[membership] ||
                people_by_membership[membership] >=
                    _family_memberships[membership].people) {
                out["ok"] = false;
                out["reason"] = "restore_person_name_or_claim_invalid";
                return out;
            }
            claimed_by_membership[membership] += _persons.cash_claim[i];
            ++people_by_membership[membership];
            if (_persons.job_kind[i] != 0) {
                const int32_t group = building_index_for_handle(
                    _persons.building_handle[i]);
                if (group < 0 || _buildings[group].cell !=
                        _population.page_cell[cohort / COHORT_PAGE_SIZE]) {
                    out["ok"] = false;
                    out["reason"] = "restore_person_building_invalid";
                    return out;
                }
                if (_persons.job_kind[i] == 2) {
                    const BuildingType &type =
                        _building_types[_buildings[group].type_id];
                    if (_persons.employee_role_index[i] >= type.employee_count) {
                        out["ok"] = false;
                        out["reason"] = "restore_person_role_invalid";
                        return out;
                    }
                }
            }
        }
        // Canonical order is by person slot, matching how _person_need_offsets
        // is indexed. Handle order would be generation-major and would not
        // agree with the CSR once slots have been recycled.
        int32_t previous_person = -1;
        int32_t previous_need = -1;
        for (const PersonNeedState &state : _person_needs) {
            int32_t person = -1;
            if (!_persons.valid_handle(state.person_handle, person)) {
                out["ok"] = false;
                out["reason"] = "restore_person_need_handle_invalid";
                return out;
            }
            if (person < previous_person ||
                (person == previous_person &&
                 state.stable_need_id <= previous_need)) {
                out["ok"] = false;
                out["reason"] = "restore_person_need_order_invalid";
                return out;
            }
            previous_person = person;
            previous_need = state.stable_need_id;
        }
    }
    rebuild_family_indices();
    _family_modifier_bindings.clear();
    for (int32_t branch = 0; branch < static_cast<int32_t>(
             _family_influences.active.size()); ++branch) {
        if (_family_influences.active[branch] == 0) continue;
        reconcile_family_branch_effects(
            _family_influences.handle_for_index(branch), false);
    }
    rebuild_person_indices();
    _bootstrapped = true;
    _fatal = false;
    _fatal_reason.clear();
    _epoch_active = false;
    _stage = Stage::AGGREGATE_PUBLISH;
    _trade_topology.clear();
    _trade_plan.clear_transient();
    rebuild_trade_arrival_buckets();
    rebuild_committed_summaries();
    if (_restore.schema_version < 24) {
        initialize_settlements_from_population();
    } else {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            const bool should_have_name =
                _settlements.tier[cell] >= _settlement_named_tier ||
                _settlements.name_forced[cell] != 0;
            if (should_have_name !=
                (_settlements.name_active[cell] != 0)) {
                out["ok"] = false;
                out["reason"] =
                    "restore_settlement_name_activity_mismatch";
                return out;
            }
        }
        _settlements.revision = 1;
    }
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    rebuild_incremental_audit_shadow();
    _closing_audit_force_full = true;
    _settlement_watermark = _last_committed_day;
    _settlement_newest_day = _last_committed_day;
    bool have_populated = false;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_committed_cells[cell].population <= 0) continue;
        if (!have_populated) {
            _settlement_watermark = _cell_last_settlement_day[cell];
            _settlement_newest_day = _cell_last_settlement_day[cell];
            have_populated = true;
        } else {
            _settlement_watermark = std::min(
                _settlement_watermark, _cell_last_settlement_day[cell]);
            _settlement_newest_day = std::max(
                _settlement_newest_day, _cell_last_settlement_day[cell]);
        }
    }
    _settlement_max_age_days = have_populated
        ? std::max<int64_t>(0, _last_committed_day - _settlement_watermark) : 0;
    const int32_t restored_pages = _restore.restored_pages;
    const int32_t restored_commands = _restore.restored_commands;
    const int32_t restored_buildings = _restore.restored_buildings;
    const int32_t restored_schema = _restore.schema_version;
    _restore = {};
    trace_begin_epoch();
    trace_append(EVENT_RESTORE_BOUNDARY,
                 static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id, SCHEMA_VERSION, -1,
                 restored_pages, restored_commands, restored_buildings,
                 _last_committed_day, nullptr);
    trace_commit_epoch(0, 0, 0);
    out["ok"] = true;
    out["restored_pages"] = restored_pages;
    out["restored_commands"] = restored_commands;
    out["restored_buildings"] = restored_buildings;
    out["restored_trade_orders"] = _trade_orders.size();
    out["restored_trade_flows"] = static_cast<int64_t>(_trade_flows.cells.size());
    out["cohort_count"] = _population.active_count;
    out["state_hash_catalog"] = _catalog_hash;
    out["restored_families"] = _families.active_count;
    out["restored_persons"] = _persons.active_count;
    out["restored_person_needs"] = static_cast<int64_t>(_person_needs.size());
    out["migration"] = restored_schema == 27
        ? "v27_empty_birth_residual_bootstrap"
        : (restored_schema == 25
        ? "v25_empty_family_bootstrap"
        : (restored_schema == 26
        ? "v26_empty_notable_person_bootstrap"
        : (restored_schema == 22 || restored_schema == 23
        ? "legacy_settlement_bootstrap"
        : (restored_schema == 14
            ? "v14_rolling_phase_bootstrap" : "none"))));
    return out;
}


} // namespace pk
