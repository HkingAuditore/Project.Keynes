#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <cmath>

namespace pk {

void NativeEconomyRuntime::record_cohort_fiscal(int32_t slot,
                                                int64_t signed_amount) {
    // Attribution only: apply_fiscal_tax already moved the money, so this never
    // mints, burns, or rebalances anything. It shares the lazy epoch reset with
    // epoch_income/epoch_expense so callers may record before or after the
    // corresponding funds mutation.
    if (signed_amount == 0 || slot < 0 ||
        slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0) return;
    touch_accounting_slot(slot);
    if (signed_amount > 0) {
        _population.epoch_tax_paid[slot] = saturating_add(
            _population.epoch_tax_paid[slot], signed_amount, _saturation_count);
    } else {
        _population.epoch_subsidy_received[slot] = saturating_add(
            _population.epoch_subsidy_received[slot], -signed_amount,
            _saturation_count);
    }
}

int8_t NativeEconomyRuntime::frozen_tax_rate(int32_t cell, int32_t kind,
                                              int32_t item) const {
    if (kind < 0 || kind >= NativeCountryRuntime::TAX_KIND_COUNT ||
        (_epoch_active_tax_mask & static_cast<uint8_t>(1U << kind)) == 0)
        return 0;
    if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
        item < 0) return 0;
    if (!_epoch_cell_active_tax_mask.empty() &&
        (_epoch_cell_active_tax_mask[static_cast<size_t>(cell)] &
         static_cast<uint8_t>(1U << kind)) == 0)
        return 0;
    const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
    if (country < 0 || country >= _epoch_country_count) return 0;
    const std::vector<int8_t> *rates = nullptr;
    size_t item_count = 0;
    switch (kind) {
        case NativeCountryRuntime::TAX_INCOME:
            rates = &_epoch_income_tax_rates;
            item_count = _profession_ids.size();
            break;
        case NativeCountryRuntime::TAX_CONSUMPTION:
            rates = &_epoch_consumption_tax_rates;
            item_count = _good_ids.size();
            break;
        case NativeCountryRuntime::TAX_BUSINESS:
            rates = &_epoch_business_tax_rates;
            item_count = _building_types.size();
            break;
        case NativeCountryRuntime::TAX_IMPORT:
            rates = &_epoch_import_tax_rates;
            item_count = _good_ids.size();
            break;
        case NativeCountryRuntime::TAX_EXPORT:
            rates = &_epoch_export_tax_rates;
            item_count = _good_ids.size();
            break;
        default:
            return 0;
    }
    const size_t index = static_cast<size_t>(country) * item_count +
        static_cast<size_t>(item);
    if (item >= static_cast<int32_t>(item_count) || index >= rates->size())
        return 0;
    if (_epoch_has_cell_tax_policies &&
        cell < static_cast<int32_t>(
            _epoch_cell_compiled_tax_policy.size())) {
        const uint32_t compiled_id =
            _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)];
        if (compiled_id > 0 &&
            compiled_id < _epoch_compiled_cell_tax_policies.size()) {
            const CompiledCellTaxPolicy &compiled =
                _epoch_compiled_cell_tax_policies[compiled_id];
            const int32_t slice_begin =
                compiled.override_begin[static_cast<size_t>(kind)];
            const int32_t slice_end =
                compiled.override_end[static_cast<size_t>(kind)];
            const int32_t slice_size = slice_end - slice_begin;
            if (slice_size <= 8) {
                for (int32_t cursor = slice_begin; cursor < slice_end;
                     ++cursor) {
                    const CompiledCellTaxOverride &entry =
                        _epoch_compiled_cell_tax_overrides[
                            static_cast<size_t>(cursor)];
                    if (entry.item == item) return entry.rate;
                    if (entry.item > item) break;
                }
            } else {
                const auto begin =
                    _epoch_compiled_cell_tax_overrides.begin() + slice_begin;
                const auto end =
                    _epoch_compiled_cell_tax_overrides.begin() + slice_end;
                const auto found = std::lower_bound(
                    begin, end, item,
                    [](const CompiledCellTaxOverride &entry, int32_t key) {
                        return entry.item < key;
                    });
                if (found != end && found->item == item) return found->rate;
            }
            const int32_t row_id =
                compiled.default_row_ids[static_cast<size_t>(kind)];
            if (row_id >= 0 && row_id < static_cast<int32_t>(
                    _epoch_compiled_cell_tax_default_rows.size())) {
                const CompiledCellTaxDefaultRow &row =
                    _epoch_compiled_cell_tax_default_rows[
                        static_cast<size_t>(row_id)];
                if (item < row.count) {
                    const size_t local_index =
                        static_cast<size_t>(row.offset + item);
                    if (local_index <
                        _epoch_compiled_cell_tax_default_rates.size())
                        return _epoch_compiled_cell_tax_default_rates[
                            local_index];
                }
            }
        }
    }
    return (*rates)[index];
}

int64_t NativeEconomyRuntime::fiscal_escrow_total() const {
    int64_t total = 0;
    int64_t ignored_saturation = 0;
    for (const int64_t value : _fiscal_escrow_by_country)
        total = saturating_add(total, std::max<int64_t>(0, value),
                               ignored_saturation);
    return total;
}

int32_t NativeEconomyRuntime::tariff_epoch_lane_index(
        int32_t cell, int32_t tariff_kind, bool create) {
    if (cell < 0 || cell >= _cell_count || tariff_kind < 0 || tariff_kind >= 2)
        return -1;
    const size_t key = static_cast<size_t>(cell) * 2U +
        static_cast<size_t>(tariff_kind);
    if (key >= _tariff_lane_stamp.size() || key >= _tariff_lane_index.size())
        return -1;
    if (_tariff_lane_stamp[key] == _tariff_lane_generation) {
        const int32_t lane = _tariff_lane_index[key];
        return lane >= 0 && lane < static_cast<int32_t>(_tariff_epoch_cells.size())
            ? lane : -1;
    }
    if (!create) return -1;
    const int32_t lane = static_cast<int32_t>(_tariff_epoch_cells.size());
    _tariff_lane_stamp[key] = _tariff_lane_generation;
    _tariff_lane_index[key] = lane;
    _tariff_epoch_cells.push_back(cell);
    _tariff_epoch_kinds.push_back(static_cast<uint8_t>(tariff_kind));
    _tariff_epoch_bases.push_back(0);
    _tariff_epoch_assessed.push_back(0);
    _tariff_epoch_collected.push_back(0);
    _tariff_epoch_requests.push_back(0);
    _tariff_epoch_reserved.push_back(0);
    _tariff_epoch_paid.push_back(0);
    _tariff_epoch_events.push_back(0);
    return lane;
}

int64_t NativeEconomyRuntime::prospective_business_subsidy_request(
        int32_t cell, int32_t country) {
    if (cell < 0 || cell >= _cell_count || country < 0 ||
        country + 1 >= static_cast<int32_t>(
            _epoch_country_building_type_offsets.size()) ||
        _market.cell_to_market.size() != static_cast<size_t>(_cell_count))
        return 0;
    const int32_t market = _market.cell_to_market[static_cast<size_t>(cell)];
    if (market < 0 || market >= _market.market_count) return 0;
    const int32_t type_begin = _epoch_country_building_type_offsets[country];
    const int32_t type_end = _epoch_country_building_type_offsets[country + 1];
    const int64_t days = std::max(1, _epoch_days);
    int64_t best = 0;
    for (int32_t cursor = type_begin; cursor < type_end; ++cursor) {
        if (cursor < 0 || cursor >= static_cast<int32_t>(
                _epoch_country_building_type_indices.size())) continue;
        const int32_t type_id = _epoch_country_building_type_indices[cursor];
        if (type_id < 0 ||
            type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const int8_t rate = frozen_tax_rate(
            cell, NativeCountryRuntime::TAX_BUSINESS, type_id);
        if (rate >= 0) continue;
        const BuildingType &type = _building_types[type_id];
        int64_t daily_revenue = 0;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &output =
                _building_outputs[type.output_begin + i];
            if (output.good_id < 0 || output.quantity <= 0 ||
                output.good_id >= static_cast<int32_t>(_good_ids.size()))
                continue;
            // Nameplate quantity on purpose: the effective-output helper
            // interns a modifier identity for a building that does not exist
            // yet, and this only needs a bounded escrow scale. A low quote
            // cannot under-fund the greenfield quote itself, because
            // expected_fiscal_transfer clamps at the budget/request ratio and
            // a fully covered lane still reports the whole rate.
            const int64_t quantity = output.quantity;
            const int64_t issue_value =
                _good_monetary_issue_values[output.good_id];
            const int64_t settlement = issue_value > 0
                ? issue_value
                : mul_div_sat(
                    _market.price[_market.index(market, output.good_id)],
                    _good_merchant_buy_factor_q16[output.good_id], Q16_ONE,
                    _saturation_count);
            daily_revenue = saturating_add(daily_revenue, mul_div_sat(
                quantity, settlement, GOODS_SCALE, _saturation_count),
                _saturation_count);
        }
        if (daily_revenue <= 0) continue;
        best = std::max(best, mul_div_sat(
            saturating_mul(daily_revenue, days, _saturation_count),
            std::abs(static_cast<int32_t>(rate)), 100, _saturation_count));
    }
    return best;
}

bool NativeEconomyRuntime::prepare_fiscal_budgets(int64_t day_index,
                                                  std::string &error) {
    if (_country_runtime == nullptr) {
        error = "country_runtime_required";
        return false;
    }
    const size_t lane_count = static_cast<size_t>(_cell_count) *
        ACTIVE_TAX_KIND_COUNT;
    const size_t tariff_lookup_count = static_cast<size_t>(_cell_count) * 2U;
    if (_tariff_lane_index.size() != tariff_lookup_count) {
        _tariff_lane_index.assign(tariff_lookup_count, -1);
        _tariff_lane_stamp.assign(tariff_lookup_count, 0);
        _tariff_lane_generation = 0;
    }
    if (++_tariff_lane_generation == 0) {
        std::fill(_tariff_lane_stamp.begin(), _tariff_lane_stamp.end(), 0);
        _tariff_lane_generation = 1;
    }
    _tariff_epoch_cells.clear();
    _tariff_epoch_kinds.clear();
    _tariff_epoch_bases.clear();
    _tariff_epoch_assessed.clear();
    _tariff_epoch_collected.clear();
    _tariff_epoch_requests.clear();
    _tariff_epoch_reserved.clear();
    _tariff_epoch_paid.clear();
    _tariff_epoch_events.clear();
    const size_t country_tariff_count = static_cast<size_t>(
        std::max(0, _epoch_country_count)) * 2U;
    _tariff_country_requests.assign(country_tariff_count, 0);
    _tariff_country_budgets.assign(country_tariff_count, 0);
    _tariff_country_remaining.assign(country_tariff_count, 0);
    if (_fiscal_previous_requests.size() != lane_count)
        _fiscal_previous_requests.assign(lane_count, 0);
    if (_fiscal_previous_country_handles.size() !=
            static_cast<size_t>(_cell_count))
        _fiscal_previous_country_handles.assign(
            static_cast<size_t>(_cell_count), 0);
    if (_income_taxable_base_by_slot.size() < _population.active.size())
        _income_taxable_base_by_slot.resize(_population.active.size(), 0);
    if (_income_subsidy_floor_by_slot.size() < _population.active.size())
        _income_subsidy_floor_by_slot.resize(_population.active.size(), 0);
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            _income_taxable_base_by_slot[slot] = 0;
            _income_subsidy_floor_by_slot[slot] = 0;
        });
    }
    const bool domestic_fiscal_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << NativeCountryRuntime::TAX_INCOME) |
            (1U << NativeCountryRuntime::TAX_CONSUMPTION) |
            (1U << NativeCountryRuntime::TAX_BUSINESS))) != 0;
    _fiscal_reservation_requests.assign(lane_count, 0);
    _fiscal_current_requests.assign(lane_count, 0);
    _fiscal_budgets.assign(lane_count, 0);
    _fiscal_remaining.assign(lane_count, 0);
    _fiscal_epoch_bases.assign(lane_count, 0);
    _fiscal_epoch_assessed.assign(lane_count, 0);
    _fiscal_epoch_collected.assign(lane_count, 0);
    _fiscal_epoch_paid.assign(lane_count, 0);
    _fiscal_escrow_by_country.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    std::vector<int64_t> requested_by_country(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    // Tariff subsidy intents are the only negative tariff amounts eligible for
    // the next batch. Positive tax collected later in this epoch is therefore
    // deliberately absent from this reservation pass.
    for (size_t row = 0; row < _tariff_history.countries.size(); ++row) {
        const int32_t country = _tariff_history.countries[row];
        const int32_t kind = _tariff_history.kinds[row];
        if (country < 0 || country >= _epoch_country_count ||
            kind < NativeCountryRuntime::TAX_IMPORT ||
            kind > NativeCountryRuntime::TAX_EXPORT) continue;
        const size_t tariff_kind = static_cast<size_t>(
            kind - NativeCountryRuntime::TAX_IMPORT);
        const size_t index = static_cast<size_t>(country) * 2U + tariff_kind;
        _tariff_country_requests[index] = saturating_add(
            _tariff_country_requests[index],
            std::max<int64_t>(0, _tariff_history.requests[row]),
            _saturation_count);
        // Per-batch fields are rebuilt by dispatch. Cumulative fields remain
        // the persistent audit history used by fiscal_snapshot and PKEC.
        _tariff_history.bases[row] = 0;
        _tariff_history.assessed[row] = 0;
        _tariff_history.collected[row] = 0;
        _tariff_history.requests[row] = 0;
        _tariff_history.reserved[row] = 0;
        _tariff_history.paid[row] = 0;
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const size_t index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            requested_by_country[country] = saturating_add(
                requested_by_country[country], _tariff_country_requests[index],
                _saturation_count);
        }
    }
    for (int32_t kind = 0; domestic_fiscal_active &&
            kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
        for (const int32_t cell : _epoch_settlement_cells) {
            if (cell < 0 || cell >= _cell_count) continue;
            const int32_t country = _epoch_cell_country[cell];
            if (country < 0 || country >= _epoch_country_count) continue;
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + kind;
            const bool history_matches =
                _fiscal_previous_country_handles[cell] ==
                    _epoch_country_handles[country];
            if (!history_matches)
                _fiscal_previous_requests[lane] = 0;
            int64_t reservation_request = history_matches
                ? std::max<int64_t>(0, _fiscal_previous_requests[lane]) : 0;
            if (kind == NativeCountryRuntime::TAX_INCOME) {
                int64_t baseline_request = 0;
                // Reserve a bounded floor for occupations that can be entered
                // during this epoch even when their cohort is currently empty.
                // Investment and employment use the same fiscal lane, so a
                // negative income rate on a newly opened owner/employee role
                // must have budget behind it before it can attract population.
                thread_local std::vector<int64_t>
                    prospective_subsidy_by_ethnicity;
                prospective_subsidy_by_ethnicity.assign(
                    _ethnicity_ids.size(), 0);
                if (country >= 0 && country + 1 < static_cast<int32_t>(
                        _epoch_country_building_type_offsets.size())) {
                    const int32_t type_begin =
                        _epoch_country_building_type_offsets[country];
                    const int32_t type_end =
                        _epoch_country_building_type_offsets[country + 1];
                    auto consider_profession = [&](int32_t profession) {
                        if (profession < 0 || profession >=
                                static_cast<int32_t>(_profession_ids.size()))
                            return;
                        const size_t profession_available_index =
                            static_cast<size_t>(country) * _profession_ids.size() +
                            static_cast<size_t>(profession);
                        if (profession_available_index >=
                                _epoch_country_profession_available.size() ||
                            _epoch_country_profession_available[
                                profession_available_index] == 0)
                            return;
                        const int8_t rate = frozen_tax_rate(
                            cell, NativeCountryRuntime::TAX_INCOME, profession);
                        if (rate >= 0) return;
                        for (int32_t ethnicity = 0; ethnicity <
                                static_cast<int32_t>(_ethnicity_ids.size());
                             ++ethnicity) {
                            const int32_t signature =
                                signature_for_profession_ethnicity(
                                    profession, ethnicity);
                            if (signature < 0) continue;
                            const int64_t floor_base = saturating_mul(
                                living_cost_for_signature(
                                    cell, signature, _living_cost_base_plan_id,
                                    _saturation_count),
                                std::max(1, _epoch_days), _saturation_count);
                            const int64_t subsidy = mul_div_sat(
                                floor_base, std::abs(static_cast<int32_t>(rate)),
                                100, _saturation_count);
                            prospective_subsidy_by_ethnicity[
                                static_cast<size_t>(ethnicity)] = std::max(
                                    prospective_subsidy_by_ethnicity[
                                        static_cast<size_t>(ethnicity)],
                                    subsidy);
                        }
                    };
                    for (int32_t cursor = type_begin; cursor < type_end;
                         ++cursor) {
                        if (cursor < 0 || cursor >= static_cast<int32_t>(
                                _epoch_country_building_type_indices.size()))
                            continue;
                        const int32_t type_id =
                            _epoch_country_building_type_indices[cursor];
                        if (type_id < 0 || type_id >= static_cast<int32_t>(
                                _building_types.size())) continue;
                        const BuildingType &type = _building_types[type_id];
                        consider_profession(type.owner_profession_id);
                        for (int32_t role = 0; role < type.employee_count;
                             ++role) {
                            consider_profession(_building_employee_roles[
                                type.employee_begin + role].profession_id);
                        }
                    }
                }
                _population.for_each_in_cell(cell, [&](int32_t slot) {
                    const int32_t signature = static_cast<int32_t>(
                        _population.signature_id[slot]);
                    const int32_t profession = signature >= 0 &&
                            signature < static_cast<int32_t>(_signatures.size())
                        ? _signatures[signature].profession_id : -1;
                    const int8_t rate = frozen_tax_rate(
                        cell, NativeCountryRuntime::TAX_INCOME, profession);
                    if (_population.population[slot] <= 0) return;
                    const int64_t per_person_daily = living_cost_for_signature(
                        cell, signature, _living_cost_base_plan_id,
                        _saturation_count);
                    const int64_t floor_base_per_person = saturating_mul(
                        per_person_daily, std::max(1, _epoch_days),
                        _saturation_count);
                    const int64_t population = std::max<int64_t>(
                        0, _population.population[slot]);
                    const int64_t floor_base = saturating_mul(
                        floor_base_per_person, population, _saturation_count);
                    if (rate < 0) {
                        _income_subsidy_floor_by_slot[slot] = floor_base;
                        baseline_request = saturating_add(
                            baseline_request,
                            mul_div_sat(
                                floor_base,
                                std::abs(static_cast<int32_t>(rate)), 100,
                                _saturation_count),
                            _saturation_count);
                    }
                    const int32_t ethnicity = signature >= 0 && signature <
                            static_cast<int32_t>(_signatures.size())
                        ? _signatures[signature].ethnicity_id : -1;
                    if (ethnicity >= 0 && ethnicity < static_cast<int32_t>(
                            prospective_subsidy_by_ethnicity.size())) {
                        const int64_t current_subsidy = rate < 0
                            ? mul_div_sat(
                                floor_base_per_person,
                                std::abs(static_cast<int32_t>(rate)), 100,
                                _saturation_count)
                            : 0;
                        const int64_t incremental = std::max<int64_t>(
                            0, prospective_subsidy_by_ethnicity[
                                static_cast<size_t>(ethnicity)] -
                                current_subsidy);
                        baseline_request = saturating_add(
                            baseline_request,
                            saturating_mul(
                                incremental,
                                std::max<int64_t>(0,
                                    _population.population[slot]),
                                _saturation_count),
                            _saturation_count);
                    }
                });
                reservation_request = std::max(
                    reservation_request, baseline_request);
            } else if (kind == NativeCountryRuntime::TAX_BUSINESS &&
                       cell_due_investment_review(cell, day_index)) {
                // Without this the business lane can only ever budget what a
                // previous epoch actually requested, so a cell with no
                // subsidised producer yet quotes zero to a greenfield
                // entrant: expected_fiscal_transfer needs both a reservation
                // request and a budget before it returns anything. Seed the
                // review cells this epoch will actually evaluate, bounded by
                // one building of the single most valuable subsidised type so
                // the escrow stays proportional to what investment can start.
                const int64_t prospective =
                    prospective_business_subsidy_request(cell, country);
                if (prospective > reservation_request) {
                    ++_fiscal_business_prospective_lanes;
                    _fiscal_business_prospective_request = saturating_add(
                        _fiscal_business_prospective_request,
                        prospective - reservation_request, _saturation_count);
                    reservation_request = prospective;
                }
            }
            _fiscal_reservation_requests[lane] = reservation_request;
            requested_by_country[country] = saturating_add(
                requested_by_country[country],
                reservation_request,
                _saturation_count);
        }
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const int64_t requested = requested_by_country[country];
        if (requested <= 0) continue;
        const int64_t reserved = _country_runtime->reserve_fiscal_cash(
            static_cast<int64_t>(_epoch_country_handles[country]), requested);
        _fiscal_escrow_by_country[country] = reserved;
        int64_t prefix = 0;
        int64_t allocated = 0;
        for (int32_t kind = 0; domestic_fiscal_active &&
                kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
            for (const int32_t cell : _epoch_settlement_cells) {
                if (cell < 0 || cell >= _cell_count ||
                    _epoch_cell_country[cell] != country) continue;
                const size_t lane = static_cast<size_t>(cell) *
                    ACTIVE_TAX_KIND_COUNT + kind;
                prefix = saturating_add(prefix,
                    std::max<int64_t>(0, _fiscal_reservation_requests[lane]),
                    _saturation_count);
                const int64_t next = mul_div_sat(
                    reserved, prefix, requested, _saturation_count);
                const int64_t share = std::max<int64_t>(0, next - allocated);
                allocated = next;
                _fiscal_budgets[lane] = share;
                _fiscal_remaining[lane] = share;
            }
        }
        // Continue the same stable reservation order with import then export
        // tariff intents. Their budget is tracked per country because an
        // intent is country-level history while the active endpoint lane is
        // discovered later by trade dispatch.
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const size_t tariff_index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            const int64_t request = _tariff_country_requests[tariff_index];
            prefix = saturating_add(prefix, request, _saturation_count);
            const int64_t next = requested > 0
                ? mul_div_sat(reserved, prefix, requested, _saturation_count)
                : 0;
            const int64_t share = std::max<int64_t>(0, next - allocated);
            allocated = next;
            _tariff_country_budgets[tariff_index] = share;
            _tariff_country_remaining[tariff_index] = share;
        }
    }
    return true;
}

void NativeEconomyRuntime::settle_income_subsidies_for_cell(
        int32_t cell, int64_t &saturation_count) {
    if (cell < 0 || cell >= _cell_count ||
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << NativeCountryRuntime::TAX_INCOME)) == 0)
        return;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + NativeCountryRuntime::TAX_INCOME;
    if (lane >= _fiscal_current_requests.size() ||
        lane >= _fiscal_remaining.size()) return;

    thread_local std::vector<int32_t> subsidy_slots;
    thread_local std::vector<int64_t> subsidy_requests;
    subsidy_slots.clear();
    subsidy_requests.clear();
    int64_t total_base = 0;
    int64_t total_request = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        if (slot < 0 ||
            slot >= static_cast<int32_t>(_income_taxable_base_by_slot.size()) ||
            slot >= static_cast<int32_t>(_income_subsidy_floor_by_slot.size()) ||
            _population.population[slot] <= 0) return;
        const int32_t signature = static_cast<int32_t>(
            _population.signature_id[slot]);
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const int8_t rate = frozen_tax_rate(
            cell, NativeCountryRuntime::TAX_INCOME, profession);
        if (rate >= 0) return;
        const int64_t base = std::max(
            std::max<int64_t>(0, _income_taxable_base_by_slot[slot]),
            std::max<int64_t>(0, _income_subsidy_floor_by_slot[slot]));
        const int64_t request = mul_div_sat(
            base, std::abs(static_cast<int32_t>(rate)), 100,
            saturation_count);
        subsidy_slots.push_back(slot);
        subsidy_requests.push_back(request);
        total_base = saturating_add(total_base, base, saturation_count);
        total_request = saturating_add(
            total_request, request, saturation_count);
    });
    _fiscal_epoch_bases[lane] = saturating_add(
        _fiscal_epoch_bases[lane], total_base, saturation_count);
    _fiscal_current_requests[lane] = saturating_add(
        _fiscal_current_requests[lane], total_request, saturation_count);
    if (total_request <= 0) return;

    const int64_t paid_total = std::min(
        total_request, std::max<int64_t>(0, _fiscal_remaining[lane]));
    int64_t prefix = 0;
    int64_t allocated = 0;
    for (size_t i = 0; i < subsidy_slots.size(); ++i) {
        prefix = saturating_add(
            prefix, subsidy_requests[i], saturation_count);
        const int64_t next = mul_div_sat(
            paid_total, prefix, total_request, saturation_count);
        const int64_t paid = std::max<int64_t>(0, next - allocated);
        allocated = next;
        if (paid <= 0) continue;
        const int32_t slot = subsidy_slots[i];
        touch_accounting_slot(slot);
        record_cohort_fiscal(slot, -paid);
        _population.funds[slot] = saturating_add(
            _population.funds[slot], paid, saturation_count);
        trace_record_cashflow(
            cell, _population.handle_for_slot(slot),
            CASHFLOW_INCOME_SUBSIDY, paid, 0);
    }
    _fiscal_remaining[lane] -= paid_total;
    _fiscal_epoch_paid[lane] = saturating_add(
        _fiscal_epoch_paid[lane], paid_total, saturation_count);
}

int64_t NativeEconomyRuntime::apply_fiscal_tax(
        int32_t cell, int32_t kind, int64_t base, int8_t rate,
        int64_t &saturation_count) {
    if (cell < 0 || cell >= _cell_count || kind < 0 ||
        kind >= ACTIVE_TAX_KIND_COUNT || base <= 0 || rate == 0) return 0;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + kind;
    if (lane >= _fiscal_epoch_bases.size()) return 0;
    const int64_t amount = mul_div_sat(
        base, std::abs(static_cast<int32_t>(rate)), 100, saturation_count);
    _fiscal_epoch_bases[lane] = saturating_add(
        _fiscal_epoch_bases[lane], base, saturation_count);
    if (rate > 0) {
        _fiscal_epoch_assessed[lane] = saturating_add(
            _fiscal_epoch_assessed[lane], amount, saturation_count);
        _fiscal_epoch_collected[lane] = saturating_add(
            _fiscal_epoch_collected[lane], amount, saturation_count);
        return amount;
    }
    _fiscal_current_requests[lane] = saturating_add(
        _fiscal_current_requests[lane], amount, saturation_count);
    const int64_t paid = std::min(
        amount, std::max<int64_t>(0, _fiscal_remaining[lane]));
    _fiscal_remaining[lane] -= paid;
    _fiscal_epoch_paid[lane] = saturating_add(
        _fiscal_epoch_paid[lane], paid, saturation_count);
    return -paid;
}

int64_t NativeEconomyRuntime::expected_fiscal_transfer(
        int32_t cell, int32_t kind, int64_t base, int8_t rate,
        int64_t &saturation_count) const {
    if (cell < 0 || cell >= _cell_count || kind < 0 ||
        kind >= ACTIVE_TAX_KIND_COUNT || base <= 0 || rate == 0 ||
        (_epoch_active_tax_mask & static_cast<uint8_t>(1U << kind)) == 0)
        return 0;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + kind;
    if (lane >= _fiscal_previous_requests.size() ||
        lane >= _fiscal_budgets.size()) return 0;
    const int64_t amount = mul_div_sat(
        base, std::abs(static_cast<int32_t>(rate)), 100, saturation_count);
    if (rate > 0) return amount;
    const int64_t reservation_request =
        lane < _fiscal_reservation_requests.size()
        ? std::max<int64_t>(0, _fiscal_reservation_requests[lane]) : 0;
    const int64_t budget = std::max<int64_t>(0, _fiscal_budgets[lane]);
    if (amount <= 0 || reservation_request <= 0 || budget <= 0) return 0;
    const int64_t expected_paid = std::min(
        amount, mul_div_sat(amount, budget, reservation_request,
                            saturation_count));
    return -expected_paid;
}

int64_t NativeEconomyRuntime::expected_after_tax_income(
        int32_t cell, int32_t profession, int64_t gross_income,
        int64_t &saturation_count) const {
    if (gross_income <= 0) return 0;
    const int8_t income_rate = frozen_tax_rate(
        cell, NativeCountryRuntime::TAX_INCOME, profession);
    int64_t subsidy_base = gross_income;
    if (income_rate < 0) {
        const int32_t signal = labor_signal_index(cell, profession);
        const int64_t living_floor = signal >= 0 &&
                signal < static_cast<int32_t>(
                    _labor_signals.role_living_cost.size())
            ? std::max<int64_t>(
                _labor_signals.base_living_cost[signal],
                _labor_signals.role_living_cost[signal])
            : 0;
        subsidy_base = std::max(subsidy_base, living_floor);
    }
    return saturating_sub(gross_income, expected_fiscal_transfer(
        cell, NativeCountryRuntime::TAX_INCOME, subsidy_base, income_rate,
        saturation_count), saturation_count);
}

bool NativeEconomyRuntime::commit_fiscal(std::string &error) {
    if (_country_runtime == nullptr) {
        error = "country_runtime_required";
        return false;
    }
    const size_t summary_count = static_cast<size_t>(
        std::max(0, _epoch_country_count)) * NativeCountryRuntime::TAX_KIND_COUNT;
    _fiscal_last_bases.assign(summary_count, 0);
    _fiscal_last_assessed.assign(summary_count, 0);
    _fiscal_last_collected.assign(summary_count, 0);
    _fiscal_last_requests.assign(summary_count, 0);
    _fiscal_last_reserved.assign(summary_count, 0);
    _fiscal_last_paid.assign(summary_count, 0);
    _fiscal_last_events.assign(summary_count, 0);
    _fiscal_last_unmet.assign(summary_count, 0);
    _fiscal_cumulative_bases.resize(summary_count, 0);
    _fiscal_cumulative_collected.resize(summary_count, 0);
    _fiscal_cumulative_requests.resize(summary_count, 0);
    _fiscal_cumulative_paid.resize(summary_count, 0);
    const bool domestic_fiscal_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << NativeCountryRuntime::TAX_INCOME) |
            (1U << NativeCountryRuntime::TAX_CONSUMPTION) |
            (1U << NativeCountryRuntime::TAX_BUSINESS))) != 0;
    const size_t tariff_lane_count = _tariff_epoch_cells.size();
    if (_tariff_epoch_kinds.size() != tariff_lane_count ||
        _tariff_epoch_bases.size() != tariff_lane_count ||
        _tariff_epoch_assessed.size() != tariff_lane_count ||
        _tariff_epoch_collected.size() != tariff_lane_count ||
        _tariff_epoch_requests.size() != tariff_lane_count ||
        _tariff_epoch_reserved.size() != tariff_lane_count ||
        _tariff_epoch_paid.size() != tariff_lane_count ||
        _tariff_epoch_events.size() != tariff_lane_count) {
        error = "tariff_epoch_lane_shape_invalid";
        return false;
    }
    for (size_t lane = 0; lane < tariff_lane_count; ++lane) {
        const int32_t cell = _tariff_epoch_cells[lane];
        const int32_t tariff_kind = _tariff_epoch_kinds[lane];
        if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            tariff_kind < 0 || tariff_kind >= 2) {
            error = "tariff_epoch_lane_key_invalid";
            return false;
        }
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) continue;
        const size_t summary = static_cast<size_t>(country) *
            NativeCountryRuntime::TAX_KIND_COUNT +
            NativeCountryRuntime::TAX_IMPORT + tariff_kind;
        _fiscal_last_bases[summary] = saturating_add(
            _fiscal_last_bases[summary], _tariff_epoch_bases[lane],
            _saturation_count);
        _fiscal_last_assessed[summary] = saturating_add(
            _fiscal_last_assessed[summary], _tariff_epoch_assessed[lane],
            _saturation_count);
        _fiscal_last_collected[summary] = saturating_add(
            _fiscal_last_collected[summary], _tariff_epoch_collected[lane],
            _saturation_count);
        _fiscal_last_requests[summary] = saturating_add(
            _fiscal_last_requests[summary], _tariff_epoch_requests[lane],
            _saturation_count);
        _fiscal_last_reserved[summary] = saturating_add(
            _fiscal_last_reserved[summary], _tariff_epoch_reserved[lane],
            _saturation_count);
        _fiscal_last_paid[summary] = saturating_add(
            _fiscal_last_paid[summary], _tariff_epoch_paid[lane],
            _saturation_count);
        _fiscal_last_events[summary] = saturating_add(
            _fiscal_last_events[summary], _tariff_epoch_events[lane],
            _saturation_count);
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        int64_t collected_total = 0;
        int64_t unused_total = 0;
        for (int32_t kind = 0; domestic_fiscal_active &&
             kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
            const size_t summary = static_cast<size_t>(country) *
                NativeCountryRuntime::TAX_KIND_COUNT + kind;
            for (const int32_t cell : _epoch_settlement_cells) {
                if (cell < 0 || cell >= _cell_count ||
                    _epoch_cell_country[cell] != country) continue;
                const size_t lane = static_cast<size_t>(cell) *
                    ACTIVE_TAX_KIND_COUNT + kind;
                _fiscal_last_bases[summary] = saturating_add(
                    _fiscal_last_bases[summary], _fiscal_epoch_bases[lane],
                    _saturation_count);
                _fiscal_last_assessed[summary] = saturating_add(
                    _fiscal_last_assessed[summary], _fiscal_epoch_assessed[lane],
                    _saturation_count);
                _fiscal_last_collected[summary] = saturating_add(
                    _fiscal_last_collected[summary], _fiscal_epoch_collected[lane],
                    _saturation_count);
                _fiscal_last_requests[summary] = saturating_add(
                    _fiscal_last_requests[summary], _fiscal_current_requests[lane],
                    _saturation_count);
                _fiscal_last_reserved[summary] = saturating_add(
                    _fiscal_last_reserved[summary], _fiscal_budgets[lane],
                    _saturation_count);
                _fiscal_last_paid[summary] = saturating_add(
                    _fiscal_last_paid[summary], _fiscal_epoch_paid[lane],
                    _saturation_count);
                unused_total = saturating_add(
                    unused_total, _fiscal_remaining[lane], _saturation_count);
                _fiscal_previous_requests[lane] = _fiscal_current_requests[lane];
            }
            _fiscal_last_unmet[summary] = std::max<int64_t>(
                0, _fiscal_last_requests[summary] - _fiscal_last_paid[summary]);
            _fiscal_cumulative_bases[summary] = saturating_add(
                _fiscal_cumulative_bases[summary], _fiscal_last_bases[summary],
                _saturation_count);
            _fiscal_cumulative_collected[summary] = saturating_add(
                _fiscal_cumulative_collected[summary],
                _fiscal_last_collected[summary], _saturation_count);
            _fiscal_cumulative_requests[summary] = saturating_add(
                _fiscal_cumulative_requests[summary],
                _fiscal_last_requests[summary], _saturation_count);
            _fiscal_cumulative_paid[summary] = saturating_add(
                _fiscal_cumulative_paid[summary], _fiscal_last_paid[summary],
                _saturation_count);
            collected_total = saturating_add(
                collected_total, _fiscal_last_collected[summary],
                _saturation_count);
        }
        // Tariff lanes are sparse cell x {import, export} and are folded into
        // the country x 5 fiscal summary only after all dispatches settle.
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const int32_t kind = NativeCountryRuntime::TAX_IMPORT + tariff_kind;
            const size_t summary = static_cast<size_t>(country) *
                NativeCountryRuntime::TAX_KIND_COUNT + kind;
            const size_t tariff_budget_index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            if (tariff_budget_index < _tariff_country_budgets.size()) {
                _fiscal_last_reserved[summary] = saturating_add(
                    _fiscal_last_reserved[summary],
                    _tariff_country_budgets[tariff_budget_index],
                    _saturation_count);
                if (tariff_budget_index < _tariff_country_remaining.size()) {
                    unused_total = saturating_add(
                        unused_total,
                        _tariff_country_remaining[tariff_budget_index],
                        _saturation_count);
                }
            }
            _fiscal_last_unmet[summary] = std::max<int64_t>(
                0, _fiscal_last_requests[summary] - _fiscal_last_paid[summary]);
            _fiscal_cumulative_bases[summary] = saturating_add(
                _fiscal_cumulative_bases[summary], _fiscal_last_bases[summary],
                _saturation_count);
            _fiscal_cumulative_collected[summary] = saturating_add(
                _fiscal_cumulative_collected[summary],
                _fiscal_last_collected[summary], _saturation_count);
            _fiscal_cumulative_requests[summary] = saturating_add(
                _fiscal_cumulative_requests[summary],
                _fiscal_last_requests[summary], _saturation_count);
            _fiscal_cumulative_paid[summary] = saturating_add(
                _fiscal_cumulative_paid[summary], _fiscal_last_paid[summary],
                _saturation_count);
            collected_total = saturating_add(
                collected_total, _fiscal_last_collected[summary],
                _saturation_count);
        }
        const int64_t handle = static_cast<int64_t>(_epoch_country_handles[country]);
        if (unused_total > 0) {
            const int64_t returned =
                _country_runtime->return_fiscal_cash(handle, unused_total);
            if (returned != unused_total) {
                error = "fiscal_escrow_return_drift";
                return false;
            }
        }
        if (collected_total > 0) {
            const int64_t collected =
                _country_runtime->collect_fiscal_cash(handle, collected_total);
            if (collected != collected_total) {
                error = "fiscal_tax_collection_drift";
                return false;
            }
        }
        _fiscal_escrow_by_country[country] = 0;
        for (int32_t tariff_kind = 0; tariff_kind < 2; ++tariff_kind) {
            const size_t index = static_cast<size_t>(country) * 2U +
                static_cast<size_t>(tariff_kind);
            if (index < _tariff_country_remaining.size())
                _tariff_country_remaining[index] = 0;
        }
    }
    for (size_t row = 0; row < _tariff_history.countries.size(); ++row) {
        _tariff_history.cumulative_bases[row] = saturating_add(
            _tariff_history.cumulative_bases[row],
            std::max<int64_t>(0, _tariff_history.bases[row]),
            _saturation_count);
        _tariff_history.cumulative_collected[row] = saturating_add(
            _tariff_history.cumulative_collected[row],
            std::max<int64_t>(0, _tariff_history.collected[row]),
            _saturation_count);
        _tariff_history.cumulative_requests[row] = saturating_add(
            _tariff_history.cumulative_requests[row],
            std::max<int64_t>(0, _tariff_history.requests[row]),
            _saturation_count);
        _tariff_history.cumulative_paid[row] = saturating_add(
            _tariff_history.cumulative_paid[row],
            std::max<int64_t>(0, _tariff_history.paid[row]),
            _saturation_count);
    }
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        const int32_t country = _epoch_cell_country[cell];
        _fiscal_previous_country_handles[cell] =
            country >= 0 && country < _epoch_country_count
            ? _epoch_country_handles[country] : 0;
    }
    ++_country_trade_revision;
    return true;
}

} // namespace pk
