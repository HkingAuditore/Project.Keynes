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
    return item < static_cast<int32_t>(item_count) && index < rates->size()
        ? (*rates)[index] : 0;
}

int64_t NativeEconomyRuntime::fiscal_escrow_total() const {
    int64_t total = 0;
    int64_t ignored_saturation = 0;
    for (const int64_t value : _fiscal_escrow_by_country)
        total = saturating_add(total, std::max<int64_t>(0, value),
                               ignored_saturation);
    return total;
}

bool NativeEconomyRuntime::prepare_fiscal_budgets(std::string &error) {
    if (_country_runtime == nullptr) {
        error = "country_runtime_required";
        return false;
    }
    const size_t lane_count = static_cast<size_t>(_cell_count) *
        ACTIVE_TAX_KIND_COUNT;
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
    if ((_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << NativeCountryRuntime::TAX_INCOME) |
            (1U << NativeCountryRuntime::TAX_CONSUMPTION) |
            (1U << NativeCountryRuntime::TAX_BUSINESS))) == 0) {
        std::fill(_fiscal_previous_requests.begin(),
                  _fiscal_previous_requests.end(), 0);
        std::fill(_fiscal_previous_country_handles.begin(),
                  _fiscal_previous_country_handles.end(), uint64_t{0});
        _fiscal_reservation_requests.clear();
        _fiscal_current_requests.clear();
        _fiscal_budgets.clear();
        _fiscal_remaining.clear();
        _fiscal_epoch_bases.clear();
        _fiscal_epoch_assessed.clear();
        _fiscal_epoch_collected.clear();
        _fiscal_epoch_paid.clear();
        _fiscal_escrow_by_country.assign(
            static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
        return true;
    }
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
    for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
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
                _population.for_each_in_cell(cell, [&](int32_t slot) {
                    const int32_t signature = static_cast<int32_t>(
                        _population.signature_id[slot]);
                    const int32_t profession = signature >= 0 &&
                            signature < static_cast<int32_t>(_signatures.size())
                        ? _signatures[signature].profession_id : -1;
                    const int8_t rate = frozen_tax_rate(
                        cell, NativeCountryRuntime::TAX_INCOME, profession);
                    if (rate >= 0 ||
                        _population.population[slot] <= 0) return;
                    const int64_t per_person_daily = living_cost_for_signature(
                        cell, signature, _living_cost_base_plan_id,
                        _saturation_count);
                    const int64_t floor_base = saturating_mul(
                        saturating_mul(
                            per_person_daily,
                            std::max<int64_t>(0, _population.population[slot]),
                            _saturation_count),
                        std::max(1, _epoch_days), _saturation_count);
                    _income_subsidy_floor_by_slot[slot] = floor_base;
                    baseline_request = saturating_add(
                        baseline_request,
                        mul_div_sat(
                            floor_base,
                            std::abs(static_cast<int32_t>(rate)), 100,
                            _saturation_count),
                        _saturation_count);
                });
                reservation_request = std::max(
                    reservation_request, baseline_request);
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
        for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
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
    _fiscal_last_unmet.assign(summary_count, 0);
    _fiscal_cumulative_bases.resize(summary_count, 0);
    _fiscal_cumulative_collected.resize(summary_count, 0);
    _fiscal_cumulative_requests.resize(summary_count, 0);
    _fiscal_cumulative_paid.resize(summary_count, 0);
    if ((_epoch_active_tax_mask & static_cast<uint8_t>(
            (1U << NativeCountryRuntime::TAX_INCOME) |
            (1U << NativeCountryRuntime::TAX_CONSUMPTION) |
            (1U << NativeCountryRuntime::TAX_BUSINESS))) == 0) {
        std::fill(_fiscal_escrow_by_country.begin(),
                  _fiscal_escrow_by_country.end(), 0);
        return true;
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        int64_t collected_total = 0;
        int64_t unused_total = 0;
        for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
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
    }
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        const int32_t country = _epoch_cell_country[cell];
        _fiscal_previous_country_handles[cell] =
            country >= 0 && country < _epoch_country_count
            ? _epoch_country_handles[country] : 0;
    }
    return true;
}

} // namespace pk
