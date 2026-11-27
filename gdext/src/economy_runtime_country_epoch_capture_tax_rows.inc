    const auto cell_tax_compile_started = Clock::now();
    _epoch_cell_compiled_tax_policy.assign(
        static_cast<size_t>(_cell_count.get()), 0);
    _epoch_cell_active_tax_mask.assign(static_cast<size_t>(_cell_count.get()), 0);
    _epoch_cell_negative_tax_mask.assign(static_cast<size_t>(_cell_count.get()), 0);
    _epoch_cell_absolute_tax_mask.assign(static_cast<size_t>(_cell_count.get()), 0);
    _epoch_compiled_cell_tax_policies.assign(1, CompiledCellTaxPolicy{});
    _epoch_compiled_cell_tax_overrides.clear();
    _epoch_compiled_cell_tax_default_rows.clear();
    _epoch_compiled_cell_tax_default_rates.clear();
    _epoch_compiled_cell_tax_default_modes.clear();
    _epoch_has_cell_tax_policies = false;
    std::unordered_map<uint64_t, uint32_t> compiled_policy_ids;
    std::unordered_map<uint64_t, int32_t> default_row_ids;
    const auto item_count_for_kind = [&](int32_t kind) -> size_t {
        switch (kind) {
            case CountryApi::TAX_INCOME:
                return _profession_ids.size();
            case CountryApi::TAX_BUSINESS:
                return _building_types.size();
            case CountryApi::TAX_CONSUMPTION:
            case CountryApi::TAX_IMPORT:
            case CountryApi::TAX_EXPORT:
                return _good_ids.size();
            default: return 0;
        }
    };
    const auto &stat_ids_for_kind = [&](int32_t kind)
            -> const std::vector<int32_t> & {
        switch (kind) {
            case CountryApi::TAX_INCOME:
                return _income_tax_stat_ids;
            case CountryApi::TAX_CONSUMPTION:
                return _consumption_tax_stat_ids;
            case CountryApi::TAX_BUSINESS:
                return _business_tax_stat_ids;
            case CountryApi::TAX_IMPORT:
                return _import_tax_stat_ids;
            case CountryApi::TAX_EXPORT:
                return _export_tax_stat_ids;
            default: {
                static const std::vector<int32_t> empty;
                return empty;
            }
        }
    };
    const auto ensure_default_row = [&](int32_t country, int32_t kind,
                                        int32_t base_rate,
                                        int32_t base_mode) -> int32_t {
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 40U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(kind)) << 32U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(base_mode & 0xff))
             << 24U) |
            static_cast<uint32_t>(base_rate);
        const auto found = default_row_ids.find(key);
        if (found != default_row_ids.end()) return found->second;
        const size_t item_count = item_count_for_kind(kind);
        CompiledCellTaxDefaultRow row;
        row.kind = kind;
        row.country = country;
        row.base_rate = base_rate;
        row.base_mode = base_mode;
        row.offset = static_cast<int32_t>(
            _epoch_compiled_cell_tax_default_rates.size());
        row.count = static_cast<int32_t>(item_count);
        _epoch_compiled_cell_tax_default_rates.resize(
            _epoch_compiled_cell_tax_default_rates.size() + item_count,
            base_rate);
        _epoch_compiled_cell_tax_default_modes.resize(
            _epoch_compiled_cell_tax_default_modes.size() + item_count,
            base_mode);
        if (_modifier_runtime != nullptr && item_count > 0 &&
            base_mode != CountryApi::TAX_MODE_ABSOLUTE) {
            const auto &stat_ids = stat_ids_for_kind(kind);
            modifier_api::effective_values(*_modifier_runtime,
                ModifierApi::COUNTRY, stat_ids.data(),
                _epoch_country_handles[static_cast<size_t>(country)],
                _epoch_compiled_cell_tax_default_rates.data() + row.offset,
                _epoch_compiled_cell_tax_default_rates.data() + row.offset,
                item_count);
        }
        const int32_t row_id = static_cast<int32_t>(
            _epoch_compiled_cell_tax_default_rows.size());
        _epoch_compiled_cell_tax_default_rows.push_back(row);
        default_row_ids.emplace(key, row_id);
        return row_id;
    };
    const std::vector<int32_t> &tax_cells = _economy_live_cells.empty()
        ? std::vector<int32_t>() : _economy_live_cells;
    const bool scan_all_tax_cells = tax_cells.empty();
    const int32_t tax_scan_count = scan_all_tax_cells
        ? _cell_count.get() : static_cast<int32_t>(tax_cells.size());
    for (int32_t i = 0; i < tax_scan_count; ++i) {
        const int32_t cell = scan_all_tax_cells ? i : tax_cells[static_cast<size_t>(i)];
        const uint32_t authority_id =
            snapshot_cell_tax_policy_ids[static_cast<size_t>(cell)];
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (authority_id == 0 ||
            authority_id >= snapshot_cell_tax_policies.size() ||
            country < 0 || country >= _epoch_country_count)
            continue;
        _epoch_has_cell_tax_policies = true;
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32U) |
            authority_id;
        auto compiled_found = compiled_policy_ids.find(key);
        if (compiled_found == compiled_policy_ids.end()) {
            const auto &authority = snapshot_cell_tax_policies[authority_id];
            CompiledCellTaxPolicy compiled;
            for (int32_t kind = 0;
                 kind < CountryApi::TAX_KIND_COUNT; ++kind) {
                compiled.override_begin[static_cast<size_t>(kind)] =
                    static_cast<int32_t>(
                        _epoch_compiled_cell_tax_overrides.size());
                for (const auto &entry : authority.overrides) {
                    if (entry.kind != kind) continue;
                    int32_t effective = entry.rate;
                    const int32_t mode =
                        entry.mode == CountryApi::TAX_MODE_INHERIT
                            ? CountryApi::TAX_MODE_PERCENT_BP
                            : entry.mode;
                    if (_modifier_runtime != nullptr &&
                        mode != CountryApi::TAX_MODE_ABSOLUTE) {
                        const auto &stat_ids = stat_ids_for_kind(kind);
                        modifier_api::effective_values(*_modifier_runtime,
                            ModifierApi::COUNTRY,
                            stat_ids.data() + entry.item,
                            _epoch_country_handles[static_cast<size_t>(country)],
                            &effective, &effective, 1);
                    }
                    _epoch_compiled_cell_tax_overrides.push_back(
                        {entry.item, effective, mode});
                    if (effective != 0)
                        compiled.active_mask |= static_cast<uint8_t>(1U << kind);
                }
                compiled.override_end[static_cast<size_t>(kind)] =
                    static_cast<int32_t>(
                        _epoch_compiled_cell_tax_overrides.size());
                const int32_t local_default =
                    authority.defaults[static_cast<size_t>(kind)];
                const int32_t local_default_mode =
                    authority.default_modes[static_cast<size_t>(kind)];
                if (local_default != CountryApi::TAX_RATE_INHERIT ||
                    local_default_mode !=
                        CountryApi::TAX_MODE_INHERIT) {
                    const int32_t resolved_mode =
                        local_default_mode ==
                                CountryApi::TAX_MODE_INHERIT
                            ? CountryApi::TAX_MODE_PERCENT_BP
                            : local_default_mode;
                    const int32_t resolved_rate =
                        local_default == CountryApi::TAX_RATE_INHERIT
                            ? 0
                            : local_default;
                    const int32_t row_id = ensure_default_row(
                        country, kind, resolved_rate, resolved_mode);
                    compiled.default_row_ids[static_cast<size_t>(kind)] = row_id;
                    const CompiledCellTaxDefaultRow &row =
                        _epoch_compiled_cell_tax_default_rows[
                            static_cast<size_t>(row_id)];
                    if (std::any_of(
                            _epoch_compiled_cell_tax_default_rates.begin() +
                                row.offset,
                            _epoch_compiled_cell_tax_default_rates.begin() +
                                row.offset + row.count,
                            [](int32_t rate) { return rate != 0; })) {
                        compiled.active_mask |=
                            static_cast<uint8_t>(1U << kind);
                    }
                }
            }
            compiled.active_mask = 0;
            compiled.negative_mask = 0;
            compiled.absolute_mask = 0;
            const auto national_rates_for_kind = [&](int32_t kind)
                    -> const std::vector<int32_t> & {
                switch (kind) {
                    case CountryApi::TAX_INCOME:
                        return _epoch_income_tax_rates;
                    case CountryApi::TAX_CONSUMPTION:
                        return _epoch_consumption_tax_rates;
                    case CountryApi::TAX_BUSINESS:
                        return _epoch_business_tax_rates;
                    case CountryApi::TAX_IMPORT:
                        return _epoch_import_tax_rates;
                    default: return _epoch_export_tax_rates;
                    }
            };
            const auto national_modes_for_kind = [&](int32_t kind)
                    -> const std::vector<int32_t> & {
                switch (kind) {
                    case CountryApi::TAX_INCOME:
                        return _epoch_income_tax_modes;
                    case CountryApi::TAX_CONSUMPTION:
                        return _epoch_consumption_tax_modes;
                    case CountryApi::TAX_BUSINESS:
                        return _epoch_business_tax_modes;
                    case CountryApi::TAX_IMPORT:
                        return _epoch_import_tax_modes;
                    default: return _epoch_export_tax_modes;
                }
            };
            for (int32_t kind = 0;
                 kind < CountryApi::TAX_KIND_COUNT; ++kind) {
                const size_t item_count = item_count_for_kind(kind);
                const auto &national = national_rates_for_kind(kind);
                const auto &national_modes = national_modes_for_kind(kind);
                int32_t override_cursor =
                    compiled.override_begin[static_cast<size_t>(kind)];
                const int32_t override_end =
                    compiled.override_end[static_cast<size_t>(kind)];
                const int32_t row_id =
                    compiled.default_row_ids[static_cast<size_t>(kind)];
                for (int32_t item = 0;
                     item < static_cast<int32_t>(item_count); ++item) {
                    int32_t rate = 0;
                    int32_t mode = CountryApi::TAX_MODE_PERCENT_BP;
                    while (override_cursor < override_end &&
                           _epoch_compiled_cell_tax_overrides[
                               static_cast<size_t>(override_cursor)].item < item)
                        ++override_cursor;
                    if (override_cursor < override_end &&
                        _epoch_compiled_cell_tax_overrides[
                               static_cast<size_t>(override_cursor)].item == item) {
                        const CompiledCellTaxOverride &entry =
                            _epoch_compiled_cell_tax_overrides[
                                static_cast<size_t>(override_cursor)];
                        rate = entry.rate;
                        mode = entry.mode;
                    } else if (row_id >= 0) {
                        const CompiledCellTaxDefaultRow &row =
                            _epoch_compiled_cell_tax_default_rows[
                                static_cast<size_t>(row_id)];
                        rate = _epoch_compiled_cell_tax_default_rates[
                            static_cast<size_t>(row.offset + item)];
                        mode = _epoch_compiled_cell_tax_default_modes[
                            static_cast<size_t>(row.offset + item)];
                    } else {
                        rate = national[
                            static_cast<size_t>(country) * item_count +
                            static_cast<size_t>(item)];
                        mode = national_modes[
                            static_cast<size_t>(country) * item_count +
                            static_cast<size_t>(item)];
                    }
                    if (rate != 0) {
                        compiled.active_mask |=
                            static_cast<uint8_t>(1U << kind);
                        if (rate < 0)
                            compiled.negative_mask |=
                                static_cast<uint8_t>(1U << kind);
                        if (mode == CountryApi::TAX_MODE_ABSOLUTE)
                            compiled.absolute_mask |=
                                static_cast<uint8_t>(1U << kind);
                    }
                }
            }
            const uint32_t compiled_id = static_cast<uint32_t>(
                _epoch_compiled_cell_tax_policies.size());
            _epoch_compiled_cell_tax_policies.push_back(compiled);
            compiled_policy_ids.emplace(key, compiled_id);
            compiled_found = compiled_policy_ids.find(key);
        }
        _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)] =
            compiled_found->second;
    }
    const size_t country_count = static_cast<size_t>(
        std::max(0, _epoch_country_count));
    std::vector<uint8_t> country_tax_masks(country_count, 0);
    std::vector<uint8_t> country_negative_tax_masks(country_count, 0);
    std::vector<uint8_t> country_absolute_tax_masks(country_count, 0);
    const auto mark_country_tax = [&](int32_t kind,
                                      const std::vector<int32_t> &rates,
                                      const std::vector<int32_t> &modes,
                                      size_t item_count) {
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const size_t offset = static_cast<size_t>(country) * item_count;
            for (size_t item = 0; item < item_count; ++item) {
                const int32_t rate = rates[offset + item];
                if (rate == 0) continue;
                const uint8_t bit = static_cast<uint8_t>(1U << kind);
                country_tax_masks[static_cast<size_t>(country)] |= bit;
                if (rate < 0)
                    country_negative_tax_masks[static_cast<size_t>(country)] |= bit;
                if (modes[offset + item] == CountryApi::TAX_MODE_ABSOLUTE)
                    country_absolute_tax_masks[static_cast<size_t>(country)] |= bit;
            }
        }
    };
    mark_country_tax(CountryApi::TAX_INCOME,
                     _epoch_income_tax_rates, _epoch_income_tax_modes,
                     _profession_ids.size());
    mark_country_tax(CountryApi::TAX_CONSUMPTION,
                     _epoch_consumption_tax_rates, _epoch_consumption_tax_modes,
                     _good_ids.size());
    mark_country_tax(CountryApi::TAX_BUSINESS,
                     _epoch_business_tax_rates, _epoch_business_tax_modes,
                     _building_types.size());
    mark_country_tax(CountryApi::TAX_IMPORT,
                     _epoch_import_tax_rates, _epoch_import_tax_modes,
                     _good_ids.size());
    mark_country_tax(CountryApi::TAX_EXPORT,
                     _epoch_export_tax_rates, _epoch_export_tax_modes,
                     _good_ids.size());
    _epoch_active_tax_mask = 0;
    _epoch_negative_tax_mask = 0;
    _epoch_absolute_tax_mask = 0;
    const std::vector<int32_t> &tax_mask_cells = _economy_live_cells.empty()
        ? std::vector<int32_t>() : _economy_live_cells;
    const bool mask_all_cells = tax_mask_cells.empty();
    const int32_t tax_mask_count = mask_all_cells
        ? _cell_count.get() : static_cast<int32_t>(tax_mask_cells.size());
    for (int32_t i = 0; i < tax_mask_count; ++i) {
        const int32_t cell = mask_all_cells ? i : tax_mask_cells[static_cast<size_t>(i)];
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        uint8_t mask = 0;
        const uint32_t compiled_id =
            _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)];
        uint8_t negative_mask = 0;
        uint8_t absolute_mask = 0;
        if (compiled_id > 0 &&
            compiled_id < _epoch_compiled_cell_tax_policies.size()) {
            mask = _epoch_compiled_cell_tax_policies[compiled_id].active_mask;
            negative_mask = _epoch_compiled_cell_tax_policies[compiled_id].negative_mask;
            absolute_mask = _epoch_compiled_cell_tax_policies[compiled_id].absolute_mask;
        } else if (country >= 0 && country < _epoch_country_count) {
            mask = country_tax_masks[static_cast<size_t>(country)];
            negative_mask = country_negative_tax_masks[static_cast<size_t>(country)];
            absolute_mask = country_absolute_tax_masks[static_cast<size_t>(country)];
        }
        _epoch_cell_active_tax_mask[static_cast<size_t>(cell)] = mask;
        _epoch_cell_negative_tax_mask[static_cast<size_t>(cell)] = negative_mask;
        _epoch_cell_absolute_tax_mask[static_cast<size_t>(cell)] = absolute_mask;
        _epoch_active_tax_mask |= mask;
        _epoch_negative_tax_mask |= negative_mask;
        _epoch_absolute_tax_mask |= absolute_mask;
    }
    _epoch_cell_tax_cache_bytes = static_cast<int64_t>(
        _epoch_cell_compiled_tax_policy.size() * sizeof(uint32_t) +
        _epoch_cell_active_tax_mask.size() * sizeof(uint8_t) +
        _epoch_cell_negative_tax_mask.size() * sizeof(uint8_t) +
        _epoch_cell_absolute_tax_mask.size() * sizeof(uint8_t) +
        _epoch_compiled_cell_tax_policies.size() *
            sizeof(CompiledCellTaxPolicy) +
        _epoch_compiled_cell_tax_overrides.size() *
            sizeof(CompiledCellTaxOverride) +
        _epoch_compiled_cell_tax_default_rows.size() *
            sizeof(CompiledCellTaxDefaultRow) +
        _epoch_compiled_cell_tax_default_rates.size() * sizeof(int32_t));
    _epoch_cell_tax_compile_ms = elapsed_ms(cell_tax_compile_started);
    record_phase("country_capture.cell_tax");
