#include "economy_runtime_fiscal_includes.inc"

namespace pk {

void NativeEconomyRuntime::record_cohort_fiscal(int32_t slot,
                                                int64_t signed_amount) {
    // Attribution only: apply_fiscal_tax already moved the money, so this never
    // mints, burns, or rebalances anything. It shares the lazy epoch reset with
    // epoch_income/epoch_expense so callers may record before or after the
    // corresponding funds mutation.
    if (signed_amount == 0 || slot < 0 ||
        slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0) return;
    touch_accounting_slot(slot);
    if (signed_amount > 0) {
        population_store().epoch_tax_paid.write_scalar(slot, saturating_add(
            population_store().epoch_tax_paid[slot], signed_amount, _saturation_count), market_mutation_sink());
    } else {
        population_store().epoch_subsidy_received.write_scalar(slot, saturating_add(
            population_store().epoch_subsidy_received[slot], -signed_amount,
            _saturation_count), market_mutation_sink());
    }
}

int32_t NativeEconomyRuntime::frozen_tax_rate(int32_t cell, int32_t kind,
                                               int32_t item) const {
    if (kind < 0 || kind >= CountryApi::TAX_KIND_COUNT ||
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
    const std::vector<int32_t> *rates = nullptr;
    size_t item_count = 0;
    switch (kind) {
        case CountryApi::TAX_INCOME:
            rates = &_epoch_income_tax_rates;
            item_count = _profession_ids.size();
            break;
        case CountryApi::TAX_CONSUMPTION:
            rates = &_epoch_consumption_tax_rates;
            item_count = _good_ids.size();
            break;
        case CountryApi::TAX_BUSINESS:
            rates = &_epoch_business_tax_rates;
            item_count = _building_types.size();
            break;
        case CountryApi::TAX_IMPORT:
            rates = &_epoch_import_tax_rates;
            item_count = _good_ids.size();
            break;
        case CountryApi::TAX_EXPORT:
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
            for (int32_t cursor = slice_begin; cursor < slice_end; ++cursor) {
                const CompiledCellTaxOverride &entry =
                    _epoch_compiled_cell_tax_overrides[
                        static_cast<size_t>(cursor)];
                if (entry.item == item) return entry.rate;
                if (entry.item > item) break;
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

int32_t NativeEconomyRuntime::frozen_tax_mode(int32_t cell, int32_t kind,
                                               int32_t item) const {
    if (kind < 0 || kind >= CountryApi::TAX_KIND_COUNT ||
        (_epoch_active_tax_mask & static_cast<uint8_t>(1U << kind)) == 0)
        return CountryApi::TAX_MODE_PERCENT_BP;
    if (cell < 0 || cell >= static_cast<int32_t>(_epoch_cell_country.size()) ||
        item < 0)
        return CountryApi::TAX_MODE_PERCENT_BP;
    if (!_epoch_cell_active_tax_mask.empty() &&
        (_epoch_cell_active_tax_mask[static_cast<size_t>(cell)] &
         static_cast<uint8_t>(1U << kind)) == 0)
        return CountryApi::TAX_MODE_PERCENT_BP;
    const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
    if (country < 0 || country >= _epoch_country_count)
        return CountryApi::TAX_MODE_PERCENT_BP;
    const std::vector<int32_t> *modes = nullptr;
    size_t item_count = 0;
    switch (kind) {
        case CountryApi::TAX_INCOME:
            modes = &_epoch_income_tax_modes;
            item_count = _profession_ids.size();
            break;
        case CountryApi::TAX_CONSUMPTION:
            modes = &_epoch_consumption_tax_modes;
            item_count = _good_ids.size();
            break;
        case CountryApi::TAX_BUSINESS:
            modes = &_epoch_business_tax_modes;
            item_count = _building_types.size();
            break;
        case CountryApi::TAX_IMPORT:
            modes = &_epoch_import_tax_modes;
            item_count = _good_ids.size();
            break;
        case CountryApi::TAX_EXPORT:
            modes = &_epoch_export_tax_modes;
            item_count = _good_ids.size();
            break;
        default:
            return CountryApi::TAX_MODE_PERCENT_BP;
    }
    const size_t index = static_cast<size_t>(country) * item_count +
        static_cast<size_t>(item);
    if (item >= static_cast<int32_t>(item_count) || modes == nullptr ||
        index >= modes->size())
        return CountryApi::TAX_MODE_PERCENT_BP;
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
            for (int32_t cursor = slice_begin; cursor < slice_end; ++cursor) {
                const CompiledCellTaxOverride &entry =
                    _epoch_compiled_cell_tax_overrides[
                        static_cast<size_t>(cursor)];
                if (entry.item == item) return entry.mode;
                if (entry.item > item) break;
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
                        _epoch_compiled_cell_tax_default_modes.size())
                        return _epoch_compiled_cell_tax_default_modes[
                            local_index];
                    return row.base_mode;
                }
            }
        }
    }
    return (*modes)[index];
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
    if (cell < 0 || cell >= _cell_count.get() || tariff_kind < 0 || tariff_kind >= 2)
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

void NativeEconomyRuntime::settle_income_subsidies_for_cell(
        int32_t cell, int64_t &saturation_count) {
    if (cell < 0 || cell >= _cell_count.get() ||
        (_epoch_negative_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_INCOME)) == 0)
        return;
    if ((_epoch_cell_negative_tax_mask[static_cast<size_t>(cell)] &
         static_cast<uint8_t>(1U << CountryApi::TAX_INCOME)) == 0)
        return;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + CountryApi::TAX_INCOME;
    if (lane >= _fiscal_current_requests.size() ||
        lane >= _fiscal_remaining.size()) return;

    thread_local std::vector<int32_t> subsidy_slots;
    thread_local std::vector<int64_t> subsidy_requests;
    subsidy_slots.clear();
    subsidy_requests.clear();
    int64_t total_base = 0;
    int64_t total_request = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        if (slot < 0 ||
            slot >= static_cast<int32_t>(_income_taxable_base_by_slot.size()) ||
            slot >= static_cast<int32_t>(_income_subsidy_floor_by_slot.size()) ||
            population_store().population[slot] <= 0) return;
        const int32_t signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const int32_t rate = frozen_tax_rate(
            cell, CountryApi::TAX_INCOME, profession);
        const int32_t mode = frozen_tax_mode(
            cell, CountryApi::TAX_INCOME, profession);
        if (mode == CountryApi::TAX_MODE_ABSOLUTE || rate >= 0)
            return;
        const int64_t base = std::max(
            std::max<int64_t>(0, _income_taxable_base_by_slot[slot]),
            std::max<int64_t>(0, _income_subsidy_floor_by_slot[slot]));
        const int64_t request = mul_div_sat(
            base, std::abs(static_cast<int64_t>(rate)), 10000,
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

    const int32_t fulfillment = lane < _fiscal_fulfillment_q16.size()
        ? std::clamp<int32_t>(_fiscal_fulfillment_q16[lane], 0, Q16_ONE)
        : 0;
    const int64_t paid_total = std::min(
        mul_div_sat(total_request, fulfillment, Q16_ONE, saturation_count),
        std::max<int64_t>(0, _fiscal_remaining[lane]));
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
        population_store().funds.write_scalar(slot, saturating_add(
            population_store().funds[slot], paid, saturation_count), market_mutation_sink());
        trace_record_cashflow(
            cell, population_store().handle_for_slot(slot),
            CASHFLOW_INCOME_SUBSIDY, paid, 0);
    }
    _fiscal_remaining[lane] -= paid_total;
    _fiscal_epoch_paid[lane] = saturating_add(
        _fiscal_epoch_paid[lane], paid_total, saturation_count);
}

void NativeEconomyRuntime::settle_absolute_daily_taxes_for_cell(
        int32_t cell, int64_t &saturation_count) {
    if (cell < 0 || cell >= _cell_count.get() ||
        _epoch_absolute_tax_mask == 0) return;
    const uint8_t absolute_mask =
        _epoch_cell_absolute_tax_mask[static_cast<size_t>(cell)];
    const int64_t days = std::max(1, _epoch_days.get());

    if ((absolute_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_INCOME)) != 0) {
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            if (slot < 0 ||
                slot >= static_cast<int32_t>(population_store().population.size()) ||
                population_store().population[slot] <= 0) return;
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            const int32_t profession = signature >= 0 &&
                    signature < static_cast<int32_t>(_signatures.size())
                ? _signatures[signature].profession_id : -1;
            if (frozen_tax_mode(cell, CountryApi::TAX_INCOME,
                                profession) !=
                CountryApi::TAX_MODE_ABSOLUTE)
                return;
            const int32_t value = frozen_tax_rate(
                cell, CountryApi::TAX_INCOME, profession);
            if (value == 0) return;
            const int64_t units = saturating_mul(
                population_store().population[slot], days, saturation_count);
            if (value > 0) {
                const int64_t assessed = saturating_mul(
                    units, static_cast<int64_t>(value), saturation_count);
                const int64_t collected = std::min(
                    assessed, std::max<int64_t>(0, population_store().funds[slot]));
                if (collected <= 0) {
                    const size_t lane = static_cast<size_t>(cell) *
                        ACTIVE_TAX_KIND_COUNT + CountryApi::TAX_INCOME;
                    if (lane < _fiscal_epoch_assessed.size()) {
                        _fiscal_epoch_assessed[lane] = saturating_add(
                            _fiscal_epoch_assessed[lane], assessed,
                            saturation_count);
                        _fiscal_epoch_bases[lane] = saturating_add(
                            _fiscal_epoch_bases[lane], assessed,
                            saturation_count);
                    }
                    return;
                }
                touch_accounting_slot(slot);
                population_store().funds.write_scalar(slot, population_store().funds[slot] - (collected), market_mutation_sink());
                record_cohort_fiscal(slot, collected);
                const size_t lane = static_cast<size_t>(cell) *
                    ACTIVE_TAX_KIND_COUNT + CountryApi::TAX_INCOME;
                if (lane < _fiscal_epoch_assessed.size()) {
                    _fiscal_epoch_bases[lane] = saturating_add(
                        _fiscal_epoch_bases[lane], assessed, saturation_count);
                    _fiscal_epoch_assessed[lane] = saturating_add(
                        _fiscal_epoch_assessed[lane], assessed,
                        saturation_count);
                    _fiscal_epoch_collected[lane] = saturating_add(
                        _fiscal_epoch_collected[lane], collected,
                        saturation_count);
                }
                trace_record_cashflow(
                    cell, population_store().handle_for_slot(slot),
                    CASHFLOW_INCOME_TAX, 0, collected);
                return;
            }
            const int64_t transfer = apply_fiscal_tax(
                cell, CountryApi::TAX_INCOME, units, value,
                CountryApi::TAX_MODE_ABSOLUTE, saturation_count);
            if (transfer >= 0) return;
            touch_accounting_slot(slot);
            record_cohort_fiscal(slot, transfer);
            population_store().funds.write_scalar(slot, saturating_add(
                population_store().funds[slot], -transfer, saturation_count), market_mutation_sink());
            trace_record_cashflow(
                cell, population_store().handle_for_slot(slot),
                CASHFLOW_INCOME_SUBSIDY, -transfer, 0);
        });
    }

    if ((absolute_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_BUSINESS)) == 0)
        return;
    if (cell + 1 >= static_cast<int32_t>(_building_cell_offsets.size()))
        return;
    const int32_t begin = _building_cell_offsets[static_cast<size_t>(cell)];
    const int32_t end = _building_cell_offsets[static_cast<size_t>(cell + 1)];
    for (int32_t group_index = begin; group_index < end; ++group_index) {
        auto group = building_at(static_cast<size_t>(static_cast<size_t>(group_index)));
        if (group.count <= 0) continue;
        if (frozen_tax_mode(cell, CountryApi::TAX_BUSINESS,
                            group.type_id) !=
            CountryApi::TAX_MODE_ABSOLUTE)
            continue;
        const int32_t value = frozen_tax_rate(
            cell, CountryApi::TAX_BUSINESS, group.type_id);
        if (value == 0) continue;
        const int64_t units = saturating_mul(
            static_cast<int64_t>(group.count), days, saturation_count);
        const int32_t owner_slot =
            find_cohort_slot(cell, group.owner_signature_id);
        if (value > 0) {
            const int64_t assessed = saturating_mul(
                units, static_cast<int64_t>(value), saturation_count);
            int64_t collected = 0;
            if (owner_slot >= 0 &&
                owner_slot < static_cast<int32_t>(population_store().funds.size())) {
                collected = std::min(
                    assessed,
                    std::max<int64_t>(0, population_store().funds[owner_slot]));
                if (collected > 0) {
                    touch_accounting_slot(owner_slot);
                    population_store().funds.write_scalar(owner_slot, population_store().funds[owner_slot] - (collected), market_mutation_sink());
                    record_cohort_fiscal(owner_slot, collected);
                    trace_record_cashflow(
                        cell, population_store().handle_for_slot(owner_slot),
                        CASHFLOW_BUSINESS_TAX, 0, collected);
                }
            }
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + CountryApi::TAX_BUSINESS;
            if (lane < _fiscal_epoch_assessed.size()) {
                _fiscal_epoch_bases[lane] = saturating_add(
                    _fiscal_epoch_bases[lane], assessed, saturation_count);
                _fiscal_epoch_assessed[lane] = saturating_add(
                    _fiscal_epoch_assessed[lane], assessed, saturation_count);
                _fiscal_epoch_collected[lane] = saturating_add(
                    _fiscal_epoch_collected[lane], collected, saturation_count);
            }
            group.last_business_tax_paid = saturating_add(
                group.last_business_tax_paid, collected, saturation_count);
        } else {
            // Absolute business subsidy needs a living owner cohort. Paying the
            // escrow with nowhere to credit would burn treasury cash.
            if (owner_slot < 0 ||
                owner_slot >= static_cast<int32_t>(population_store().funds.size()))
                continue;
            const int64_t transfer = apply_fiscal_tax(
                cell, CountryApi::TAX_BUSINESS, units, value,
                CountryApi::TAX_MODE_ABSOLUTE, saturation_count);
            if (transfer < 0) {
                touch_accounting_slot(owner_slot);
                record_cohort_fiscal(owner_slot, transfer);
                population_store().funds.write_scalar(owner_slot, saturating_add(
                    population_store().funds[owner_slot], -transfer,
                    saturation_count), market_mutation_sink());
                group.last_business_subsidy_received = saturating_add(
                    group.last_business_subsidy_received, -transfer,
                    saturation_count);
                trace_record_cashflow(
                    cell, population_store().handle_for_slot(owner_slot),
                    CASHFLOW_BUSINESS_SUBSIDY, -transfer, 0);
            }
        }
    }
}

int64_t NativeEconomyRuntime::apply_fiscal_tax(
        int32_t cell, int32_t kind, int64_t base, int32_t rate,
        int64_t &saturation_count) {
    return apply_fiscal_tax(cell, kind, base, rate,
                            CountryApi::TAX_MODE_PERCENT_BP,
                            saturation_count);
}

int64_t NativeEconomyRuntime::apply_fiscal_tax(
        int32_t cell, int32_t kind, int64_t base, int32_t rate, int32_t mode,
        int64_t &saturation_count) {
    if (cell < 0 || cell >= _cell_count.get() || kind < 0 ||
        kind >= ACTIVE_TAX_KIND_COUNT || base <= 0 || rate == 0) return 0;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + kind;
    if (lane >= _fiscal_epoch_bases.size()) return 0;
    const int64_t amount = mode == CountryApi::TAX_MODE_ABSOLUTE
        ? saturating_mul(base, std::abs(static_cast<int64_t>(rate)),
                         saturation_count)
        : mul_div_sat(base, std::abs(static_cast<int64_t>(rate)), 10000,
                      saturation_count);
    const int64_t accounting_base =
        mode == CountryApi::TAX_MODE_ABSOLUTE ? amount : base;
    _fiscal_epoch_bases[lane] = saturating_add(
        _fiscal_epoch_bases[lane], accounting_base, saturation_count);
    if (rate > 0) {
        _fiscal_epoch_assessed[lane] = saturating_add(
            _fiscal_epoch_assessed[lane], amount, saturation_count);
        _fiscal_epoch_collected[lane] = saturating_add(
            _fiscal_epoch_collected[lane], amount, saturation_count);
        return amount;
    }
    _fiscal_current_requests[lane] = saturating_add(
        _fiscal_current_requests[lane], amount, saturation_count);
    const int32_t fulfillment = lane < _fiscal_fulfillment_q16.size()
        ? std::clamp<int32_t>(_fiscal_fulfillment_q16[lane], 0, Q16_ONE)
        : 0;
    const int64_t promised = mul_div_sat(
        amount, fulfillment, Q16_ONE, saturation_count);
    const int64_t paid = std::min(
        promised, std::max<int64_t>(0, _fiscal_remaining[lane]));
    _fiscal_remaining[lane] -= paid;
    _fiscal_epoch_paid[lane] = saturating_add(
        _fiscal_epoch_paid[lane], paid, saturation_count);
    return -paid;
}

NativeEconomyRuntime::FiscalLaneSnapshot
NativeEconomyRuntime::snapshot_fiscal_lane(int32_t cell, int32_t kind) const {
    FiscalLaneSnapshot snapshot;
    if (cell < 0 || cell >= _cell_count.get() || kind < 0 ||
        kind >= ACTIVE_TAX_KIND_COUNT) return snapshot;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + kind;
    if (lane >= _fiscal_epoch_bases.size() ||
        lane >= _fiscal_epoch_assessed.size() ||
        lane >= _fiscal_epoch_collected.size() ||
        lane >= _fiscal_current_requests.size() ||
        lane >= _fiscal_remaining.size() ||
        lane >= _fiscal_epoch_paid.size()) return snapshot;
    snapshot.lane = lane;
    snapshot.bases = _fiscal_epoch_bases[lane];
    snapshot.assessed = _fiscal_epoch_assessed[lane];
    snapshot.collected = _fiscal_epoch_collected[lane];
    snapshot.current_requests = _fiscal_current_requests[lane];
    snapshot.remaining = _fiscal_remaining[lane];
    snapshot.paid = _fiscal_epoch_paid[lane];
    return snapshot;
}

void NativeEconomyRuntime::restore_fiscal_lane(
        const FiscalLaneSnapshot &snapshot) {
    const size_t lane = snapshot.lane;
    if (lane == SIZE_MAX) return;
    _fiscal_epoch_bases[lane] = snapshot.bases;
    _fiscal_epoch_assessed[lane] = snapshot.assessed;
    _fiscal_epoch_collected[lane] = snapshot.collected;
    _fiscal_current_requests[lane] = snapshot.current_requests;
    _fiscal_remaining[lane] = snapshot.remaining;
    _fiscal_epoch_paid[lane] = snapshot.paid;
}

int64_t NativeEconomyRuntime::expected_fiscal_transfer(
        int32_t cell, int32_t kind, int64_t base, int32_t rate,
        int64_t &saturation_count) const {
    return expected_fiscal_transfer(
        cell, kind, base, rate, CountryApi::TAX_MODE_PERCENT_BP,
        saturation_count);
}

int64_t NativeEconomyRuntime::expected_fiscal_transfer(
        int32_t cell, int32_t kind, int64_t base, int32_t rate, int32_t mode,
        int64_t &saturation_count) const {
    if (cell < 0 || cell >= _cell_count.get() || kind < 0 ||
        kind >= ACTIVE_TAX_KIND_COUNT || base <= 0 || rate == 0 ||
        (_epoch_active_tax_mask & static_cast<uint8_t>(1U << kind)) == 0)
        return 0;
    const size_t lane = static_cast<size_t>(cell) *
        ACTIVE_TAX_KIND_COUNT + kind;
    if (lane >= _fiscal_previous_requests.size() ||
        lane >= _fiscal_budgets.size()) return 0;
    const int64_t amount = mode == CountryApi::TAX_MODE_ABSOLUTE
        ? saturating_mul(base, std::abs(static_cast<int64_t>(rate)),
                         saturation_count)
        : mul_div_sat(base, std::abs(static_cast<int64_t>(rate)), 10000,
                      saturation_count);
    if (rate > 0) return amount;
    const int32_t fulfillment = lane < _fiscal_fulfillment_q16.size()
        ? std::clamp<int32_t>(_fiscal_fulfillment_q16[lane], 0, Q16_ONE)
        : 0;
    if (amount <= 0 || fulfillment <= 0) return 0;
    const int64_t expected_paid = mul_div_sat(
        amount, fulfillment, Q16_ONE, saturation_count);
    return -expected_paid;
}

int64_t NativeEconomyRuntime::expected_resolved_fiscal_transfer(
        int32_t cell, int32_t kind, int32_t item, int64_t percent_base,
        int64_t absolute_units, int64_t &saturation_count) const {
    const int32_t rate = frozen_tax_rate(cell, kind, item);
    const int32_t mode = frozen_tax_mode(cell, kind, item);
    const int64_t base =
        mode == CountryApi::TAX_MODE_ABSOLUTE
            ? absolute_units : percent_base;
    return expected_fiscal_transfer(
        cell, kind, base, rate, mode, saturation_count);
}

int64_t NativeEconomyRuntime::producer_support_receipt_value(
        int32_t cell, int32_t good, int64_t quantity,
        int64_t &saturation_count) const {
    if (quantity <= 0 || cell < 0 || cell >= _cell_count.get() || good < 0 ||
        good >= market_store().good_count.get()) return 0;
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count.get()) return 0;
    const int64_t issue_value = good < static_cast<int32_t>(
            _good_monetary_issue_values.size())
        ? _good_monetary_issue_values[good] : 0;
    const int32_t lane = market_store().index(market, good);
    if (lane < 0 || lane >= static_cast<int32_t>(market_store().price.size()))
        return 0;
    const int64_t unit_value = issue_value > 0 ? issue_value :
        mul_div_sat(market_store().price[lane],
            PRODUCER_SUPPORT_PRICE_NUMERATOR,
            PRODUCER_SUPPORT_PRICE_DENOMINATOR, saturation_count);
    return mul_div_sat(quantity, unit_value, GOODS_SCALE, saturation_count);
}

NativeEconomyRuntime::BuildingTaxQuote
NativeEconomyRuntime::expected_building_tax_quote(
        int32_t cell, int32_t type_id, int32_t owner_profession,
        int64_t merchant_cash, int64_t producer_support_cash,
        int64_t business_eligible_cost, int64_t operating_cost,
        int64_t owner_living_cost, int64_t building_days,
        int64_t owner_days, int64_t &saturation_count) const {
    BuildingTaxQuote result;
    const int32_t business_rate = frozen_tax_rate(
        cell, CountryApi::TAX_BUSINESS, type_id);
    const int64_t business_base = business_rate < 0
        ? std::max<int64_t>(0, business_eligible_cost)
        : std::max<int64_t>(0, merchant_cash);
    result.business_transfer = expected_resolved_fiscal_transfer(
        cell, CountryApi::TAX_BUSINESS, type_id, business_base,
        std::max<int64_t>(1, building_days), saturation_count);
    const int64_t taxable_owner_income = std::max<int64_t>(0,
        saturating_sub(saturating_sub(merchant_cash, operating_cost,
            saturation_count), std::max<int64_t>(0,
                result.business_transfer), saturation_count));
    const int32_t income_rate = frozen_tax_rate(
        cell, CountryApi::TAX_INCOME, owner_profession);
    const int64_t income_base = income_rate < 0
        ? std::max(taxable_owner_income, std::max<int64_t>(0,
            owner_living_cost)) : taxable_owner_income;
    result.income_transfer = expected_resolved_fiscal_transfer(
        cell, CountryApi::TAX_INCOME, owner_profession, income_base,
        std::max<int64_t>(1, owner_days), saturation_count);
    result.after_tax_cash = saturating_add(
        saturating_sub(saturating_sub(merchant_cash,
            result.business_transfer, saturation_count),
            result.income_transfer, saturation_count),
        producer_support_cash, saturation_count);
    return result;
}

int64_t NativeEconomyRuntime::expected_after_tax_income(
        int32_t cell, int32_t profession, int64_t gross_income,
        int64_t &saturation_count) const {
    if (gross_income <= 0) return 0;
    const int32_t income_rate = frozen_tax_rate(
        cell, CountryApi::TAX_INCOME, profession);
    const int32_t income_mode = frozen_tax_mode(
        cell, CountryApi::TAX_INCOME, profession);
    if (income_mode == CountryApi::TAX_MODE_ABSOLUTE) {
        // Absolute income tax is a per-person daily levy. Predictions of daily
        // take-home therefore subtract one unit of the absolute amount.
        return saturating_sub(
            gross_income,
            expected_fiscal_transfer(
                cell, CountryApi::TAX_INCOME, 1, income_rate,
                income_mode, saturation_count),
            saturation_count);
    }
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
        cell, CountryApi::TAX_INCOME, subsidy_base, income_rate,
        income_mode, saturation_count), saturation_count);
}

NativeEconomyRuntime::TransactionQuote
NativeEconomyRuntime::quote_transaction(
        int32_t cell, int32_t good, int64_t base_value, bool settle,
        bool subsidy_eligible, int64_t &saturation_count,
        int64_t filled_quantity) {
    TransactionQuote quote;
    quote.base_value = std::max<int64_t>(0, base_value);
    quote.seller_receipt = quote.base_value;
    if (quote.base_value <= 0 || cell < 0 || cell >= _cell_count.get() || good < 0 ||
        good >= static_cast<int32_t>(_good_ids.size())) {
        quote.buyer_outlay = quote.base_value;
        return quote;
    }
    int32_t rate = frozen_tax_rate(
        cell, CountryApi::TAX_TRANSACTION, good);
    const int32_t mode = frozen_tax_mode(
        cell, CountryApi::TAX_TRANSACTION, good);
    // Inventory-only merchant procurement is outside the transaction-tax
    // boundary in both directions. Household orders, enterprise inputs and
    // inter-cell trade pass subsidy_eligible=true and absorb the wedge at the
    // final buyer endpoint.
    if (!subsidy_eligible) rate = 0;
    const int64_t tax_base =
        mode == CountryApi::TAX_MODE_ABSOLUTE
            ? std::max<int64_t>(0, filled_quantity)
            : quote.base_value;
    // Absolute transaction tax needs filled quantity. Without it, quotes stay
    // flat so callers cannot invent a money-base percentage wedge.
    if (mode == CountryApi::TAX_MODE_ABSOLUTE &&
        filled_quantity < 0) {
        quote.fiscal_transfer = 0;
        quote.buyer_outlay = quote.base_value;
        return quote;
    }
    if (tax_base <= 0 || rate == 0) {
        quote.fiscal_transfer = 0;
        quote.buyer_outlay = quote.base_value;
        return quote;
    }
    quote.fiscal_transfer = settle
        ? apply_fiscal_tax(cell, CountryApi::TAX_TRANSACTION,
                           tax_base, rate, mode, saturation_count)
        : expected_fiscal_transfer(cell, CountryApi::TAX_TRANSACTION,
                                   tax_base, rate, mode, saturation_count);
    quote.buyer_outlay = saturating_add(
        quote.base_value, quote.fiscal_transfer, saturation_count);
    return quote;
}

int32_t NativeEconomyRuntime::epoch_country_index(uint64_t handle) const {
    if (handle == 0) return -1;
    const auto found = std::find(_epoch_country_handles.begin(),
                                 _epoch_country_handles.end(), handle);
    return found == _epoch_country_handles.end()
        ? -1 : static_cast<int32_t>(found - _epoch_country_handles.begin());
}

void NativeEconomyRuntime::note_non_tax_outflow(uint64_t country_handle,
                                                int32_t kind, int64_t cash) {
    if (country_handle == 0 || kind < 0 || kind >= NON_TAX_KIND_COUNT ||
        cash <= 0) return;
    for (PendingNonTaxOutflow &entry : _pending_non_tax_outflow) {
        if (entry.country_handle != country_handle) continue;
        entry.cash[static_cast<size_t>(kind)] = saturating_add(
            entry.cash[static_cast<size_t>(kind)], cash, _saturation_count);
        return;
    }
    PendingNonTaxOutflow entry;
    entry.country_handle = country_handle;
    entry.cash[static_cast<size_t>(kind)] = cash;
    _pending_non_tax_outflow.push_back(entry);
}

} // namespace pk
